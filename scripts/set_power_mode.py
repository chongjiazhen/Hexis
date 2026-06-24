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


# On ECO->PRIME, every persona's last_heartbeat_at is hours stale, so
# should_run_heartbeat() returns true for the whole fleet on the next poll
# tick - all ~26 workers submit simultaneously and queue behind a single
# --parallel 1 GPU slot. Roll last_heartbeat_at into the jitter window so
# the first post-flip cycle lands at last + interval + per-cycle jitter,
# spread across personas via the existing epoch-mod jitter_frac. Gated on
# being actually overdue (> interval old) so a prime->prime re-arm or a
# fresh init does NOT touch a healthy fleet.
STAGGER_HEARTBEAT_SQL = """
UPDATE state
SET value = jsonb_set(
    value,
    '{last_heartbeat_at}',
    to_jsonb(
        CURRENT_TIMESTAMP - (
            random() * COALESCE(
                get_config_float('heartbeat.heartbeat_jitter_minutes'), 20.0
            )
        ) * INTERVAL '1 minute'
    )
)
WHERE key = 'heartbeat_state'
  AND (value->>'last_heartbeat_at') IS NOT NULL
  AND CURRENT_TIMESTAMP - (value->>'last_heartbeat_at')::timestamptz
      > COALESCE(
            get_config_float('heartbeat.heartbeat_interval_minutes'), 60.0
        ) * INTERVAL '1 minute'
RETURNING (value->>'last_heartbeat_at')::timestamptz AS new_last
"""


# Transient failures to retry. On ECO->PRIME the GPU cold-load (~14 GB mmap)
# starves Postgres IO, so the early personas in this serial loop can hit
# asyncpg's connect/command timeout (observed 2026-06-24: 5/9 failed mid
# cold-load, the later 4 passed once IO settled). A bare failure here aborts
# set-power-mode.ps1 before it writes the mode marker AND leaves the fleet
# split-brain (some personas flipped, some not). apply_instance is idempotent
# (set_config overwrites; the stagger is gated on being overdue), so retrying
# is safe — stdlib backoff, no runtime dep added to the serving path.
_TRANSIENT_ERRORS = (asyncio.TimeoutError, OSError, asyncpg.PostgresError)
_APPLY_ATTEMPTS = 3
_CONNECT_TIMEOUT_S = 30.0


async def apply_instance(dsn: str, db: str, entries: dict) -> None:
    for attempt in range(1, _APPLY_ATTEMPTS + 1):
        try:
            conn = await asyncpg.connect(dsn, timeout=_CONNECT_TIMEOUT_S)
            try:
                for key, cfg in entries.items():
                    await conn.execute(
                        "SELECT set_config($1, $2::jsonb)", key, json.dumps(cfg)
                    )
                mode = entries.get("agent.power_mode")
                staggered_to = None
                if isinstance(mode, str) and mode.strip().lower() != "eco":
                    row = await conn.fetchrow(STAGGER_HEARTBEAT_SQL)
                    if row is not None:
                        staggered_to = row["new_last"]
                tag = (
                    f" [stagger: last_heartbeat_at -> {staggered_to.isoformat()}]"
                    if staggered_to is not None
                    else ""
                )
                print(f"[set-power-mode] {db}: {', '.join(entries.keys())} -> "
                      f"{entries.get('llm.chat', {}).get('model', '?')}{tag}")
                return
            finally:
                await conn.close()
        except _TRANSIENT_ERRORS:
            if attempt == _APPLY_ATTEMPTS:
                raise
            await asyncio.sleep(min(2 ** (attempt - 1), 8))


async def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan", required=True, help="path to plan JSON")
    args = ap.parse_args()

    # utf-8-sig: PowerShell 5.1 'Set-Content -Encoding utf8' emits a BOM that
    # plain json.load rejects; utf-8-sig strips an optional BOM (and works
    # fine when there is none).
    with open(args.plan, "r", encoding="utf-8-sig") as fh:
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
