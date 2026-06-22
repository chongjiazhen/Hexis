#!/usr/bin/env python
"""Rebuild ~/.hexis/instances.json to match the live Postgres fleet.

The registry drifts when DBs are created/dropped out-of-band from the
instance API (dead entries linger, live DBs go unregistered). This rebuilds
it from ground truth: every ``hexis_*`` database becomes an instance named by
its suffix (``hexis_callisto`` -> ``callisto``).

- Descriptions come from ``characters/<name>.json`` creator_notes, but an
  existing registry description is preserved (don't clobber hand edits).
- ``created_at`` is preserved per surviving instance; new ones are stamped now.
- Dead instances (DB no longer exists) are dropped.
- The previous file is backed up to instances.json.bak before writing.

Usage:
    python scripts/rebuild_registry.py            # rebuild + back up
    python scripts/rebuild_registry.py --dry-run  # show diff, write nothing

Needs POSTGRES_PASSWORD (and the usual POSTGRES_* env) to enumerate databases.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path

import asyncpg

from core.agent_api import db_dsn_from_env
from core.instance import InstanceRegistry
from core.schema import get_admin_dsn

CHARACTERS_DIR = Path(__file__).resolve().parents[1] / "characters"
DB_PREFIX = "hexis_"


def _card_description(name: str) -> str:
    card = CHARACTERS_DIR / f"{name}.json"
    if not card.exists():
        return ""
    try:
        data = json.loads(card.read_text(encoding="utf-8")).get("data", {})
    except (json.JSONDecodeError, OSError):
        return ""
    src = (data.get("creator_notes") or data.get("description") or "").strip()
    line = src.splitlines()[0].strip() if src else data.get("name", name)
    return line[:100]


async def _live_databases() -> list[str]:
    admin_dsn = await get_admin_dsn(db_dsn_from_env())
    conn = await asyncpg.connect(admin_dsn)
    try:
        rows = await conn.fetch(
            "SELECT datname FROM pg_database "
            "WHERE datname LIKE $1 ORDER BY datname",
            DB_PREFIX + "%",
        )
    finally:
        await conn.close()
    return [r["datname"] for r in rows]


async def _build() -> dict:
    registry_path = InstanceRegistry.CONFIG_FILE
    existing = {}
    if registry_path.exists():
        existing = json.loads(registry_path.read_text(encoding="utf-8")).get("instances", {})

    now = datetime.now(timezone.utc).isoformat()
    instances: dict[str, dict] = {}
    for dbname in await _live_databases():
        name = dbname[len(DB_PREFIX):]
        prev = existing.get(name, {})
        instances[name] = {
            "database": dbname,
            "host": prev.get("host", "localhost"),
            "port": prev.get("port", 43815),
            "user": prev.get("user", "hexis_user"),
            "password_env": prev.get("password_env", "POSTGRES_PASSWORD"),
            "created_at": prev.get("created_at", now),
            # preserve a hand-edited description; fall back to the card
            "description": prev.get("description") or _card_description(name),
        }
    return {"version": 1, "current": None, "instances": instances}


async def _run(args) -> int:
    registry_path = InstanceRegistry.CONFIG_FILE
    old = {}
    if registry_path.exists():
        old = json.loads(registry_path.read_text(encoding="utf-8")).get("instances", {})

    new_reg = await _build()
    new = new_reg["instances"]

    added = sorted(set(new) - set(old))
    dropped = sorted(set(old) - set(new))
    print(f"{len(new)} instances (live), +{len(added)} added, -{len(dropped)} dropped")
    if added:
        print("  added:   " + ", ".join(added))
    if dropped:
        print("  dropped: " + ", ".join(dropped))

    if args.dry_run:
        print("dry-run: registry not written")
        return 0

    if registry_path.exists():
        shutil.copy2(registry_path, registry_path.with_suffix(".json.bak"))
        print(f"backed up -> {registry_path.with_suffix('.json.bak')}")
    registry_path.parent.mkdir(parents=True, exist_ok=True)
    registry_path.write_text(json.dumps(new_reg, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"wrote {registry_path}")
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="show changes, write nothing")
    args = parser.parse_args()
    sys.exit(asyncio.run(_run(args)))


if __name__ == "__main__":
    main()
