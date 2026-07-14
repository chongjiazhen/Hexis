"""Regression test: payload-stamped sender_id routes to that user's session.

Pins the end-to-end behavior that an outbox message carrying
`payload.sender_id` is delivered to the most-recently-active channel session
for THAT user, not the globally most-recent session.

Task 3 of the heartbeat-tailored-reach-out plan made the DB function stamp
`sender_id` into the outbox payload; `channels/outbox.py:_deliver_last_active`
already honors it. This test guards both ends of that contract.
"""

import json

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


async def test_successful_reach_out_is_persisted(db_pool):
    """A delivered reach-out persists three ways via record_reach_out:
    transcript (channel_messages), history continuity, tagged cognitive memory.

    Guards the gap where outbox deliveries bypassed prepare/finalize_channel_turn
    + record_chat_turn_memory, leaving the agent with no record of its outreach.
    """
    async with db_pool.acquire() as conn:
        await conn.execute("DELETE FROM channel_sessions WHERE sender_id = 'carol'")
        await conn.execute("DELETE FROM subconscious_units WHERE source_identity = 'carol'")
        await conn.execute(
            """
            INSERT INTO channel_sessions (channel_type, channel_id, sender_id, last_active)
            VALUES ('telegram', 'CCC', 'carol', CURRENT_TIMESTAMP)
            """,
        )

    try:
        manager = AsyncMock()
        manager.send = AsyncMock(return_value="msg-2")
        consumer = ChannelOutboxConsumer(manager, db_pool)

        body = {
            "kind": "user",
            "payload": {
                "message": "hey, you still around?",
                "sender_id": "carol",
                "intent": "heartbeat",
            },
        }
        await consumer._process_message(body)
        assert manager.send.await_count == 1

        async with db_pool.acquire() as conn:
            # 1. transcript: outbound row tagged kind=reach_out, trigger=heartbeat
            msg = await conn.fetchrow(
                """
                SELECT direction, metadata FROM channel_messages cm
                JOIN channel_sessions cs ON cs.id = cm.session_id
                WHERE cs.sender_id = 'carol' ORDER BY cm.created_at DESC LIMIT 1
                """,
            )
            assert msg is not None, "no channel_messages row persisted"
            meta = msg["metadata"]
            meta = json.loads(meta) if isinstance(meta, str) else meta
            assert msg["direction"] == "outbound"
            assert meta.get("kind") == "reach_out"
            assert meta.get("trigger") == "heartbeat"
            assert meta.get("origin") == "prime"

            # 2. continuity: assistant turn appended to history
            hist = await conn.fetchval(
                "SELECT history FROM channel_sessions WHERE sender_id = 'carol'"
            )
            hist = json.loads(hist) if isinstance(hist, str) else hist
            assert hist and hist[-1]["role"] == "assistant"
            assert hist[-1]["content"] == "hey, you still around?"

            # 3. cognitive memory: tagged reach_out subconscious unit
            unit_kind = await conn.fetchval(
                """
                SELECT metadata->>'kind' FROM subconscious_units
                WHERE source_identity = 'carol' ORDER BY created_at DESC LIMIT 1
                """,
            )
            assert unit_kind == "reach_out", f"expected reach_out memory, got {unit_kind!r}"
    finally:
        async with db_pool.acquire() as conn:
            await conn.execute("DELETE FROM channel_sessions WHERE sender_id = 'carol'")
            await conn.execute("DELETE FROM subconscious_units WHERE source_identity = 'carol'")


async def test_quiet_recipient_is_not_vetoed_in_sql(db_pool):
    """A recipient inside their local night window is NOT vetoed by the schema.

    This pins a DELIBERATE absence. `execute_heartbeat_action` used to veto a
    reach_out_user whose recipient was in quiet hours, returning
    {queued: false, reason: 'recipient_quiet_hours'}. Commit f3986ed (all-latent
    reach-out pivot) stripped that veto: whether 3am is an acceptable hour to
    message someone is a judgment about a relationship, so it belongs to the
    persona's own reasoning, not to a hardcoded SQL window. The schema queues;
    the persona decides whether to reach out at all.

    So: quiet recipient -> still queued, outbox message still emitted. If someone
    re-adds a SQL-level quiet gate, this test fails and they have to come read
    this docstring first.
    """
    async with db_pool.acquire() as conn:
        # Reset energy so this test isn't blocked by prior tests' accumulated charges
        # (asyncpg's connection.transaction() COMMITS on normal exit, so earlier
        # tests' energy debits persist).
        await conn.execute("UPDATE heartbeat_state SET current_energy = 20, is_paused = FALSE WHERE id = 1")

        cur_utc_hour = await conn.fetchval(
            "SELECT extract(hour FROM CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::INT"
        )
        offset = (23 - cur_utc_hour) % 24
        tz_name = f"Etc/GMT{('+' if offset == 0 else '-')}{offset if offset else 0}"
        await conn.execute("SELECT set_config('channel.sender.gated.timezone', $1::jsonb)", f'"{tz_name}"')
        await conn.execute("SELECT set_config('heartbeat.night_start_hour', '22'::jsonb)")
        await conn.execute("SELECT set_config('heartbeat.night_end_hour', '6'::jsonb)")
        await conn.execute(
            """
            INSERT INTO channel_sessions (channel_type, channel_id, sender_id, last_active)
            VALUES ('telegram', 'gated-chat', 'gated', CURRENT_TIMESTAMP - INTERVAL '1 minute')
            ON CONFLICT DO NOTHING
            """,
        )

        raw = await conn.fetchval(
            """
            SELECT execute_heartbeat_action(
                gen_random_uuid(),
                'reach_out_user',
                jsonb_build_object('sender_id','gated','message','x','intent','x')
            )
            """,
        )
        res = raw if isinstance(raw, dict) else json.loads(raw)
        inner = res.get("result", {})
        assert inner.get("queued") is True, (
            f"quiet recipient must still queue (no SQL veto since f3986ed); got {inner}"
        )
        assert inner.get("reason") != "recipient_quiet_hours", (
            "the recipient_quiet_hours veto was removed by the all-latent pivot; "
            "quiet-hours judgment belongs to the persona, not the schema"
        )

        outbox = res.get("outbox_messages") or []
        assert len(outbox) == 1, f"expected one outbox message; got {outbox}"
        assert outbox[0]["payload"]["sender_id"] == "gated"

    try:
        # Channel consumer never sees anything because outbox is empty.
        from unittest.mock import AsyncMock
        from channels.outbox import ChannelOutboxConsumer

        manager = AsyncMock()
        manager.send = AsyncMock(return_value="msg-gated")
        consumer = ChannelOutboxConsumer(manager, db_pool)
        # No body to process — the gated SQL produced no outbox payload.
        assert manager.send.await_count == 0
    finally:
        async with db_pool.acquire() as conn:
            await conn.execute("DELETE FROM channel_sessions WHERE sender_id = 'gated'")
            await conn.execute("DELETE FROM config WHERE key LIKE 'channel.sender.gated.%'")
