"""Smoke driver for the consult_persona MCP tool.

Drives `_dispatch_tool("consult_persona", ...)` directly (no stdio framing).
Verifies: pool + llm.chat config + chat_turn + memory write + session continuity.

Usage:
    python tools/smoke-consult-persona.py --persona vesper

Defaults to one question; pass --two to run a follow-up that should recall turn 1.
"""

from __future__ import annotations

import argparse
import asyncio
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))


async def run(persona: str, question: str, followup: str | None) -> int:
    from dotenv import load_dotenv

    load_dotenv()
    os.environ["POSTGRES_DB"] = f"hexis_{persona}"

    from apps.hexis_mcp_server import _dispatch_tool, _env_dsn
    from core.cognitive_memory_api import CognitiveMemory
    import asyncpg

    dsn = _env_dsn()
    print(f"[smoke] dsn={dsn}")

    client = await CognitiveMemory.create(dsn)
    pool = await asyncpg.create_pool(dsn, min_size=1, max_size=3)
    sessions: dict[str, list] = {}

    try:
        sender = f"mcp-smoke-{os.getpid()}"
        session = f"smoke-{int(time.time())}"

        print(f"[smoke] persona={persona} sender={sender} session={session}")
        print(f"[smoke] Q1: {question}")
        t0 = time.time()
        r1 = await _dispatch_tool(
            client,
            "consult_persona",
            {"message": question, "session_id": session, "sender_id": sender},
            pool=pool,
            dsn=dsn,
            default_sender=sender,
            sessions=sessions,
        )
        dt1 = time.time() - t0
        print(f"[smoke] reply1 ({dt1:.1f}s, turns={r1['turns']}):")
        print(r1.get("reply", "<empty>"))

        if followup:
            print(f"\n[smoke] Q2: {followup}")
            t0 = time.time()
            r2 = await _dispatch_tool(
                client,
                "consult_persona",
                {"message": followup, "session_id": session, "sender_id": sender},
                pool=pool,
                dsn=dsn,
                default_sender=sender,
                sessions=sessions,
            )
            dt2 = time.time() - t0
            print(f"[smoke] reply2 ({dt2:.1f}s, turns={r2['turns']}):")
            print(r2.get("reply", "<empty>"))

        # Verify memory write. Chat path stores session tag inside
        # source_attribution.ref ("chat:<session_id>:<turn>:<hash>"), not
        # in the sender_id column (known gap: RLM path is not sender-scoped).
        async with pool.acquire() as conn:
            rows = await conn.fetch(
                """
                SELECT id, source_attribution->>'ref' AS ref, left(content, 80) AS snippet
                FROM memories
                WHERE source_attribution->>'ref' LIKE $1
                ORDER BY created_at DESC
                """,
                f"chat:{session}:%",
            )
        print(f"\n[smoke] memories written for session={session}: {len(rows)}")
        for r in rows:
            print(f"  - {r['id']}  ref={r['ref']}  {r['snippet']!r}")
        return 0 if r1.get("reply") else 2
    finally:
        await client.close()
        await pool.close()


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--persona", default="vesper")
    p.add_argument("--question", default="Quick sanity check: what's the one-liner to find files modified in the last 24h on Linux?")
    p.add_argument("--two", action="store_true", help="Run a follow-up turn that depends on Q1.")
    p.add_argument("--followup", default="And the equivalent in PowerShell?")
    args = p.parse_args()
    followup = args.followup if args.two else None
    return asyncio.run(run(args.persona, args.question, followup))


if __name__ == "__main__":
    raise SystemExit(main())
