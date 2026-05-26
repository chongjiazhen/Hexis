"""Regression test: payload-stamped sender_id routes to that user's session.

Pins the end-to-end behavior that an outbox message carrying
`payload.sender_id` is delivered to the most-recently-active channel session
for THAT user, not the globally most-recent session.

Task 3 of the heartbeat-tailored-reach-out plan made the DB function stamp
`sender_id` into the outbox payload; `channels/outbox.py:_deliver_last_active`
already honors it. This test guards both ends of that contract.
"""

import pytest
from unittest.mock import AsyncMock

from channels.outbox import ChannelOutboxConsumer

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


async def test_payload_sender_id_routes_to_that_users_session(db_pool):
    # Seed outside any transaction so the consumer's pool-acquired connection
    # sees the rows. Clean up in finally.
    async with db_pool.acquire() as conn:
        await conn.execute(
            "DELETE FROM channel_sessions WHERE sender_id IN ('alice', 'bob')"
        )
        await conn.execute(
            """
            INSERT INTO channel_sessions (channel_type, channel_id, sender_id, last_active)
            VALUES
                ('telegram', 'AAA', 'alice', CURRENT_TIMESTAMP - INTERVAL '1 hour'),
                ('telegram', 'BBB', 'bob',   CURRENT_TIMESTAMP - INTERVAL '10 seconds')
            """,
        )

    try:
        manager = AsyncMock()
        manager.send = AsyncMock(return_value="msg-1")
        consumer = ChannelOutboxConsumer(manager, db_pool)

        # `_PERSONA` derivation in channels/outbox.py: POSTGRES_DB starts as
        # "hexis_memory" (or unset) at module-import time, so _PERSONA resolves
        # to "memory". Omit `agent` entirely to take the legacy/back-compat path
        # (msg_agent == "" => allow through), which is robust regardless of
        # what POSTGRES_DB is when channels.outbox is imported.
        body = {
            "kind": "user",
            "payload": {
                "message": "Hey Alice",
                "sender_id": "alice",
            },
        }
        await consumer._process_message(body)

        # Alice should win, despite Bob being globally most-recent.
        assert manager.send.await_count == 1, (
            f"expected exactly one send, got {manager.send.await_count}; "
            f"call_args_list={manager.send.await_args_list}"
        )
        call_args = manager.send.await_args
        # send(channel_type, channel_id, content) per channels/outbox.py:271
        ch_type = call_args.args[0]
        ch_id = call_args.args[1]
        content = call_args.args[2]
        assert ch_type == "telegram"
        assert ch_id == "AAA", f"expected Alice's session AAA, got {ch_id!r}"
        assert content == "Hey Alice"
    finally:
        async with db_pool.acquire() as conn:
            await conn.execute(
                "DELETE FROM channel_sessions WHERE sender_id IN ('alice', 'bob')"
            )
