import json
import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


async def test_get_active_senders_context_returns_recent_distinct_senders(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            # sender 111 active on two channels — same sender_id, different channel rows,
            # so the UNIQUE(channel_type, channel_id, sender_id) constraint allows both.
            # DISTINCT ON must collapse them to a single sender_id=111 entry, dated
            # from the most-recent row (10 minutes ago).
            await conn.execute(
                """
                INSERT INTO channel_sessions (channel_type, channel_id, sender_id, last_active)
                VALUES
                    ('telegram', '111', '111', CURRENT_TIMESTAMP - INTERVAL '2 hours'),
                    ('discord',  'guildX', '111', CURRENT_TIMESTAMP - INTERVAL '10 minutes'),
                    ('telegram', '222', '222', CURRENT_TIMESTAMP - INTERVAL '1 day'),
                    ('telegram', '333', '333', CURRENT_TIMESTAMP - INTERVAL '30 days')
                """,
            )

            raw = await conn.fetchval("SELECT get_active_senders_context(5, 7)")
            senders = raw if isinstance(raw, list) else json.loads(raw)

            ids = [s["sender_id"] for s in senders]
            # DISTINCT ON collapsed 111 to one row
            assert ids.count("111") == 1
            assert "111" in ids
            assert "222" in ids
            assert "333" not in ids  # outside 7-day window
            # Most-recent first
            assert ids.index("111") < ids.index("222")
            for s in senders:
                assert "channel_type" in s
                assert "last_active" in s
                assert "memory_count" in s


async def test_lim_one_returns_most_recent_not_lowest_sender_id(db_pool):
    """Regression: LIMIT must apply after re-ordering by recency, not after
    DISTINCT ON's mandatory sender_id ordering. With sender_id='aaa' active
    days ago and sender_id='zzz' active minutes ago, limit=1 must yield 'zzz'."""
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute(
                """
                INSERT INTO channel_sessions (channel_type, channel_id, sender_id, last_active)
                VALUES
                    ('telegram', 'aaa-chat', 'aaa', CURRENT_TIMESTAMP - INTERVAL '2 days'),
                    ('telegram', 'zzz-chat', 'zzz', CURRENT_TIMESTAMP - INTERVAL '5 minutes')
                """,
            )

            raw = await conn.fetchval("SELECT get_active_senders_context(1, 7)")
            senders = raw if isinstance(raw, list) else json.loads(raw)

            ids = [s["sender_id"] for s in senders]
            assert len(ids) == 1
            assert ids == ["zzz"], (
                f"LIMIT must follow recency re-order; got {ids} "
                "(if 'aaa', the inner DISTINCT ON's sender_id ordering leaked through)"
            )


async def test_gather_turn_context_exposes_active_senders(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute(
                """
                INSERT INTO channel_sessions (channel_type, channel_id, sender_id, last_active)
                VALUES ('telegram', '4242', '4242', CURRENT_TIMESTAMP - INTERVAL '15 minutes')
                """,
            )

            raw = await conn.fetchval("SELECT gather_turn_context()")
            ctx = raw if isinstance(raw, dict) else json.loads(raw)

            assert "active_senders" in ctx
            assert isinstance(ctx["active_senders"], list)
            ids = [s["sender_id"] for s in ctx["active_senders"]]
            assert "4242" in ids


async def test_reach_out_user_carries_sender_id_in_outbox_payload(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            raw = await conn.fetchval(
                """
                SELECT execute_heartbeat_action(
                    gen_random_uuid(),
                    'reach_out_user',
                    jsonb_build_object(
                        'sender_id', '99999',
                        'message',   'Thinking about you today.',
                        'intent',    'check_in'
                    )
                )
                """,
            )
            res = raw if isinstance(raw, dict) else json.loads(raw)

            inner = res.get("result", {})
            assert inner.get("queued") is True
            outbox = inner.get("outbox_message")
            assert isinstance(outbox, dict)
            payload = outbox.get("payload", {})
            assert payload.get("sender_id") == "99999"
            assert payload.get("message") == "Thinking about you today."
            assert payload.get("intent") == "check_in"


async def test_gather_turn_snapshot_exposes_active_senders(db_pool):
    """RLM heartbeat path uses gather_turn_snapshot(), not gather_turn_context().
    active_senders must surface in both."""
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute(
                """
                INSERT INTO channel_sessions (channel_type, channel_id, sender_id, last_active)
                VALUES ('telegram', '7777', '7777', CURRENT_TIMESTAMP - INTERVAL '10 minutes')
                """,
            )

            raw = await conn.fetchval("SELECT gather_turn_snapshot()")
            snap = raw if isinstance(raw, dict) else json.loads(raw)

            assert "active_senders" in snap, (
                f"gather_turn_snapshot() missing active_senders key; "
                f"keys present = {list(snap.keys())[:20]}"
            )
            assert isinstance(snap["active_senders"], list)
            ids = [s["sender_id"] for s in snap["active_senders"]]
            assert "7777" in ids


async def test_reach_out_user_without_sender_id_stays_backward_compat(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            raw = await conn.fetchval(
                """
                SELECT execute_heartbeat_action(
                    gen_random_uuid(),
                    'reach_out_user',
                    jsonb_build_object('message', 'hi', 'intent', 'check_in')
                )
                """,
            )
            res = raw if isinstance(raw, dict) else json.loads(raw)
            inner = res.get("result", {})
            assert inner.get("queued") is True
            payload = inner["outbox_message"]["payload"]
            assert payload.get("sender_id") in (None, "")
