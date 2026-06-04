import json
from uuid import uuid4

import pytest


pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.db]


def _json(value):
    return json.loads(value) if isinstance(value, str) else value


async def test_pause_heartbeat_persists_reason_to_memory(db_pool):
    """A self-pause must leave a durable record of WHY, not only an ephemeral
    outbox message. Mirrors terminate_agent's last-will persistence so the
    'preserves all state' contract holds even if the outbox is never delivered."""
    async with db_pool.acquire() as conn:
        tx = conn.transaction()
        await tx.start()
        try:
            hb = _json(await conn.fetchval("SELECT start_heartbeat()"))
            hb_id = hb.get("heartbeat_id")
            assert hb_id is not None

            reason = f"Stepping back to consolidate. {uuid4()}"
            payload = _json(
                await conn.fetchval(
                    "SELECT execute_heartbeat_action($1::uuid, 'pause_heartbeat', $2::jsonb)",
                    hb_id,
                    json.dumps({"reason": reason, "details": "detailed justification"}),
                )
            )
            assert payload.get("success") is True

            assert await conn.fetchval("SELECT is_paused FROM heartbeat_state WHERE id = 1") is True

            # The reason is durably persisted as an episodic memory.
            row = await conn.fetchrow(
                """
                SELECT content, importance, metadata
                FROM memories
                WHERE source_attribution->>'kind' = 'heartbeat_pause'
                ORDER BY created_at DESC
                LIMIT 1
                """
            )
            assert row is not None, "self-pause left no durable memory"
            assert reason in row["content"]
            assert _json(row["metadata"]).get("heartbeat_id") == str(hb_id)
        finally:
            await tx.rollback()
