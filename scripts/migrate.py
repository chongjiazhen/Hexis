#!/usr/bin/env python
"""Apply pending db/migrations/*.sql deltas to existing Hexis databases.

Fresh instances are migrated automatically by core.schema.apply_schema (it runs
the bootstrap, then baseline-stamps every migration). This script is for DBs
that already hold data and need to catch up to new schema deltas.

Usage:
    python scripts/migrate.py --all              # every registered instance
    python scripts/migrate.py --instance ada     # one named instance
    python scripts/migrate.py --dsn postgresql://user:pw@host:port/db
    python scripts/migrate.py --all --dry-run    # list pending, apply nothing

With no target flag, migrates the current instance from the registry.
"""
from __future__ import annotations

import argparse
import asyncio
import sys

from core.instance import InstanceRegistry
from core.schema import apply_migrations, pending_migrations


def _resolve_targets(args) -> list[tuple[str, str]]:
    """Return [(label, dsn), ...] for the requested target(s)."""
    if args.dsn:
        return [(args.dsn, args.dsn)]

    registry = InstanceRegistry()
    if args.all:
        instances = registry.list_all()
        if not instances:
            sys.exit("No instances registered.")
        return [(c.name, c.dsn()) for c in instances]

    name = args.instance or registry.get_current()
    if not name:
        sys.exit("No instance specified and no current instance set. "
                 "Use --instance, --all, or --dsn.")
    cfg = registry.get(name)
    if not cfg:
        sys.exit(f"Instance '{name}' not found in registry.")
    return [(cfg.name, cfg.dsn())]


async def _run(args) -> int:
    failures = 0
    for label, dsn in _resolve_targets(args):
        try:
            if args.dry_run:
                pending = await pending_migrations(dsn)
                if pending:
                    print(f"[{label}] {len(pending)} pending: {', '.join(pending)}")
                else:
                    print(f"[{label}] up to date")
            else:
                applied = await apply_migrations(dsn)
                if applied:
                    print(f"[{label}] applied {len(applied)}: {', '.join(applied)}")
                else:
                    print(f"[{label}] up to date")
        except Exception as exc:  # noqa: BLE001 — report per-instance, keep going
            failures += 1
            print(f"[{label}] ERROR: {exc}", file=sys.stderr)
    return 1 if failures else 0


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    target = parser.add_mutually_exclusive_group()
    target.add_argument("--instance", help="migrate one named instance")
    target.add_argument("--all", action="store_true", help="migrate every registered instance")
    target.add_argument("--dsn", help="migrate an explicit DSN")
    parser.add_argument("--dry-run", action="store_true", help="list pending migrations, apply nothing")
    args = parser.parse_args()
    sys.exit(asyncio.run(_run(args)))


if __name__ == "__main__":
    main()
