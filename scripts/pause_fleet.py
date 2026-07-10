"""Pause / resume the autonomous heartbeat loop fleet-wide, WITHOUT touching serving.

Decouples cognition from serving. set-power-mode.ps1 bundles the GPU-server
arm/kill WITH the heartbeat gate (eco kills :8080). This flips ONLY
heartbeat_state.is_paused across every hexis_* instance DB, leaving the power
mode -- and the :8080 GPU model -- exactly as-is. Use when you want the shared
GPU model armed for your OWN work (coding agent / vibe-coding) but the personas'
autonomous heartbeats quiet so they don't compete for the single --parallel 1
GPU slot.

Scope: only heartbeat_state is touched (the GPU competitor). maintenance_state is
left alone -- subconscious LLM work is off by default (maintenance.subconscious_
enabled), and the rest of maintenance (recmem embed/route, reconsolidation,
neighborhoods) is CPU/embedding-only, so housekeeping keeps running while
heartbeats are quiet.

Provenance via snapshot: pause records ONLY the DBs it actually flipped (those
that were is_paused=FALSE). resume un-pauses exactly that set, so an agent
self-pause (pause_heartbeat) or a terminated agent is never clobbered.

Usage:
  python scripts/pause_fleet.py --action pause  --dsn-base <dsn> --snapshot <path>
  python scripts/pause_fleet.py --action resume --dsn-base <dsn> --snapshot <path>
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
from datetime import datetime, timezone

import asyncpg

_CONNECT_TIMEOUT_S = 30.0


# Mirror of scripts/set_power_mode.py STAGGER_HEARTBEAT_SQL. After a long pause
# every persona's last_heartbeat_at is stale, so should_run_heartbeat() returns
# true for the whole fleet on the first post-resume poll tick and all ~26 workers
# submit simultaneously behind the single --parallel 1 GPU slot. Roll overdue
# last_heartbeat_at into the jitter window so the first post-resume cycle lands at
# last + interval + per-cycle jitter, spread across personas. Gated on being
# actually overdue (> interval old) so a not-really-stale state is left untouched.
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


async def list_hexis_dbs(dsn_base: str) -> list[str]:
    """All hexis_* instance DBs (hexis_memory + hexis_<persona>), templates excluded."""
    conn = await asyncpg.connect(f"{dsn_base}/postgres", timeout=_CONNECT_TIMEOUT_S)
    try:
        rows = await conn.fetch(
            r"SELECT datname FROM pg_database "
            r"WHERE datname LIKE 'hexis\_%' AND NOT datistemplate "
            r"ORDER BY datname"
        )
    finally:
        await conn.close()
    return [r["datname"] for r in rows]


async def pause_db(dsn: str) -> bool:
    """Flip heartbeat_state.is_paused FALSE->TRUE. Return True only if WE flipped it.

    Returns False (and leaves the DB untouched) when the state singleton is missing
    (uninitialized DB) or already paused -- an already-paused DB is someone else's
    pause (agent self-pause / terminated), so we must not claim it on the snapshot.
    """
    conn = await asyncpg.connect(dsn, timeout=_CONNECT_TIMEOUT_S)
    try:
        cur = await conn.fetchval("SELECT is_paused FROM heartbeat_state WHERE id = 1")
        if cur is None:   # no state singleton -> uninitialized DB
            return False
        if cur:           # already paused -> not ours, leave it for resume to skip
            return False
        await conn.execute("UPDATE heartbeat_state SET is_paused = TRUE WHERE id = 1")
        return True
    finally:
        await conn.close()


async def resume_db(dsn: str) -> None:
    """Clear is_paused and stagger an overdue last_heartbeat_at to avoid burst-fire."""
    conn = await asyncpg.connect(dsn, timeout=_CONNECT_TIMEOUT_S)
    try:
        await conn.execute("UPDATE heartbeat_state SET is_paused = FALSE WHERE id = 1")
        await conn.fetchrow(STAGGER_HEARTBEAT_SQL)
    finally:
        await conn.close()


async def do_pause(dsn_base: str, snapshot: str) -> int:
    if os.path.exists(snapshot):
        print(f"[pause-fleet] snapshot exists ({snapshot}) -- fleet already paused. "
              f"Run resume-fleet first (or delete the snapshot to re-pause).",
              file=sys.stderr)
        return 1

    try:
        dbs = await list_hexis_dbs(dsn_base)
    except Exception as e:  # noqa: BLE001 - brain unreachable: clean error, not a traceback
        print(f"[pause-fleet] cannot reach Postgres at {dsn_base} to enumerate DBs: "
              f"{type(e).__name__}: {e}\n"
              f"[pause-fleet] check `docker ps` for hexis_brain and that the published "
              f"host port is live (Docker Desktop port-proxy can wedge after a brain bounce).",
              file=sys.stderr)
        return 1
    if not dbs:
        print("[pause-fleet] no hexis_* databases found, nothing to do", file=sys.stderr)
        return 1

    paused: list[str] = []
    skipped = 0
    errors = 0
    for db in dbs:
        try:
            if await pause_db(f"{dsn_base}/{db}"):
                paused.append(db)
                print(f"[pause-fleet] {db}: heartbeat paused")
            else:
                skipped += 1
                print(f"[pause-fleet] {db}: skipped (already paused / uninitialized)")
        except Exception as e:  # noqa: BLE001 - report per-DB, keep going
            errors += 1
            print(f"[pause-fleet] ERROR {db}: {type(e).__name__}: {e}", file=sys.stderr)

    snap = {"paused_at": datetime.now(timezone.utc).isoformat(), "dbs": paused}
    with open(snapshot, "w", encoding="utf-8") as fh:
        json.dump(snap, fh, indent=2)

    print(f"[pause-fleet] paused {len(paused)}, skipped {skipped}, errors {errors}")
    print(f"[pause-fleet] snapshot -> {snapshot}")
    return 1 if errors else 0


async def do_resume(dsn_base: str, snapshot: str) -> int:
    if not os.path.exists(snapshot):
        print(f"[resume-fleet] no snapshot at {snapshot} -- nothing to resume "
              f"(fleet not operator-paused).")
        return 0

    # utf-8-sig: tolerate a BOM if the file was ever hand-edited on Windows.
    with open(snapshot, "r", encoding="utf-8-sig") as fh:
        snap = json.load(fh)
    dbs = snap.get("dbs", [])
    if not dbs:
        print("[resume-fleet] snapshot empty -- nothing to resume.")
        os.remove(snapshot)
        return 0

    resumed = 0
    errors = 0
    for db in dbs:
        try:
            await resume_db(f"{dsn_base}/{db}")
            resumed += 1
            print(f"[resume-fleet] {db}: heartbeat resumed")
        except Exception as e:  # noqa: BLE001 - report per-DB, keep going
            errors += 1
            print(f"[resume-fleet] ERROR {db}: {type(e).__name__}: {e}", file=sys.stderr)

    if errors:
        # Keep the snapshot so a re-run retries the rest. resume_db is idempotent
        # (set FALSE again is a no-op; the stagger is gated on being overdue).
        print(f"[resume-fleet] {errors} failed -- snapshot KEPT for retry: {snapshot}",
              file=sys.stderr)
        return 1

    os.remove(snapshot)
    print(f"[resume-fleet] resumed {resumed} -- snapshot cleared")
    return 0


async def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--action", required=True, choices=("pause", "resume"))
    ap.add_argument("--dsn-base", required=True,
                    help="postgresql://user:pass@host:port (no trailing db)")
    ap.add_argument("--snapshot", required=True, help="path to the pause snapshot JSON")
    args = ap.parse_args()

    dsn_base = args.dsn_base.rstrip("/")
    if args.action == "pause":
        return await do_pause(dsn_base, args.snapshot)
    return await do_resume(dsn_base, args.snapshot)


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
