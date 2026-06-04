import json
from uuid import uuid4

import pytest


pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.db]


def _json(value):
    return json.loads(value) if isinstance(value, str) else value


async def _pause(conn, ctx):
    hb = _json(await conn.fetchval("SELECT start_heartbeat()"))
    hb_id = hb.get("heartbeat_id")
    return _json(
        await conn.fetchval(
            "SELECT execute_heartbeat_action($1::uuid, 'pause_heartbeat', $2::jsonb)",
            hb_id,
            json.dumps(ctx),
        )
    )


async def test_pause_notifies_operator_by_default(db_pool):
    async with db_pool.acquire() as conn:
        tx = conn.transaction()
        await tx.start()
        try:
            payload = await _pause(conn, {"reason": f"default notify {uuid4()}"})
            assert payload.get("success") is True
            assert len(payload.get("outbox_messages") or []) == 1
        finally:
            await tx.rollback()


async def test_pause_can_suppress_operator_notification(db_pool):
    """Agent autonomy: {"notify": false} suppresses the outbox notification,
    but the pause still happens and the reason is still durably recorded."""
    async with db_pool.acquire() as conn:
        tx = conn.transaction()
        await tx.start()
        try:
            reason = f"quiet step away {uuid4()}"
            payload = await _pause(conn, {"reason": reason, "notify": False})
            assert payload.get("success") is True

            # No operator notification emitted.
            assert len(payload.get("outbox_messages") or []) == 0

            # But the pause took effect and the reason is still persisted.
            assert await conn.fetchval("SELECT is_paused FROM heartbeat_state WHERE id = 1") is True
            persisted = await conn.fetchval(
                "SELECT content FROM memories WHERE source_attribution->>'kind' = 'heartbeat_pause' "
                "ORDER BY created_at DESC LIMIT 1"
            )
            assert persisted is not None and reason in persisted
        finally:
            await tx.rollback()
