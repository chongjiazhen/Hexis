"""Apply an ECO/PRIME power-mode plan: flip llm.* config for each instance DB.

Dumb applier. The PowerShell layer (set-power-mode.ps1) resolves the plan from
power-profiles.psd1 and hands it here as JSON. This only writes config via the
DB's own set_config() function (same mechanism as scripts/bootstrap_instance.py).

Plan JSON shape:
  {
    "dsn_base": "postgresql://user:pass@127.0.0.1:43815",
    "instances": [
      {
        "db": "hexis_memory",
        "entries": {
          "llm.chat":        {"model": "...", "endpoint": "...", "provider": "...", "api_key_env": "..."},
          "llm.heartbeat":   {...},
          "llm.subconscious":{...}
        }
      },
      ...
    ]
  }

Usage:
  python scripts/set_power_mode.py --plan plan.json
"""
from __future__ import annotations

import argparse
import asyncio
import json
import sys

import asyncpg


async def apply_instance(dsn: str, db: str, entries: dict) -> None:
    conn = await asyncpg.connect(dsn)
    try:
        for key, cfg in entries.items():
            await conn.execute(
                "SELECT set_config($1, $2::jsonb)", key, json.dumps(cfg)
            )
        print(f"[set-power-mode] {db}: {', '.join(entries.keys())} -> "
              f"{entries.get('llm.chat', {}).get('model', '?')}")
    finally:
        await conn.close()


async def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan", required=True, help="path to plan JSON")
    args = ap.parse_args()

    with open(args.plan, "r", encoding="utf-8") as fh:
        plan = json.load(fh)

    dsn_base = plan["dsn_base"].rstrip("/")
    instances = plan["instances"]
    if not instances:
        print("[set-power-mode] empty plan, nothing to do")
        return 0

    errors = 0
    for inst in instances:
        db = inst["db"]
        dsn = f"{dsn_base}/{db}"
        try:
            await apply_instance(dsn, db, inst["entries"])
        except Exception as e:  # noqa: BLE001 - report per-DB, keep going
            errors += 1
            print(f"[set-power-mode] ERROR {db}: {type(e).__name__}: {e}",
                  file=sys.stderr)

    if errors:
        print(f"[set-power-mode] {errors} instance(s) failed", file=sys.stderr)
        return 1
    print("[set-power-mode] all instances flipped OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
