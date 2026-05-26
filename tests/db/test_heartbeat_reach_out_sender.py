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


async def test_resolve_sender_timezone_uses_per_sender_config(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute("SELECT set_config('channel.sender.alice.timezone', '\"America/Los_Angeles\"'::jsonb)")
            tz = await conn.fetchval("SELECT resolve_sender_timezone('alice')")
            assert tz == "America/Los_Angeles"


async def test_resolve_sender_timezone_falls_back_to_agent_default(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute("SELECT set_config('heartbeat.timezone', '\"Asia/Singapore\"'::jsonb)")
            tz = await conn.fetchval("SELECT resolve_sender_timezone('unknown-sender')")
            assert tz == "Asia/Singapore"


async def test_resolve_sender_timezone_falls_back_to_utc_when_all_unset(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute("DELETE FROM config WHERE key = 'heartbeat.timezone'")
            tz = await conn.fetchval("SELECT resolve_sender_timezone('whoever')")
            assert tz == "UTC"


async def test_resolve_sender_timezone_handles_null_or_empty_sender(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute("SELECT set_config('heartbeat.timezone', '\"Asia/Singapore\"'::jsonb)")
            assert await conn.fetchval("SELECT resolve_sender_timezone(NULL)") == "Asia/Singapore"
            assert await conn.fetchval("SELECT resolve_sender_timezone('')") == "Asia/Singapore"


async def test_is_sender_quiet_inside_window_returns_true(db_pool):
    """With a fixed quiet window 22-06 and the sender's tz pinned so the current
    local hour falls inside it, returns true."""
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            cur_utc_hour = await conn.fetchval(
                "SELECT extract(hour FROM CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::INT"
            )
            target_local = 23
            offset = (target_local - cur_utc_hour) % 24
            tz_name = f"Etc/GMT{('+' if offset == 0 else '-')}{offset if offset else 0}"

            await conn.execute("SELECT set_config('channel.sender.quiet1.timezone', $1::jsonb)", f'"{tz_name}"')
            await conn.execute("SELECT set_config('channel.sender.quiet1.quiet_start_hour', '22'::jsonb)")
            await conn.execute("SELECT set_config('channel.sender.quiet1.quiet_end_hour', '6'::jsonb)")

            result = await conn.fetchval("SELECT is_sender_quiet('quiet1')")
            assert result is True


async def test_is_sender_quiet_outside_window_returns_false(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            cur_utc_hour = await conn.fetchval(
                "SELECT extract(hour FROM CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::INT"
            )
            target_local = 14
            offset = (target_local - cur_utc_hour) % 24
            tz_name = f"Etc/GMT{('+' if offset == 0 else '-')}{offset if offset else 0}"

            await conn.execute("SELECT set_config('channel.sender.day1.timezone', $1::jsonb)", f'"{tz_name}"')
            await conn.execute("SELECT set_config('channel.sender.day1.quiet_start_hour', '22'::jsonb)")
            await conn.execute("SELECT set_config('channel.sender.day1.quiet_end_hour', '6'::jsonb)")

            result = await conn.fetchval("SELECT is_sender_quiet('day1')")
            assert result is False


async def test_is_sender_quiet_handles_non_wrapping_window(db_pool):
    """Window NOT wrapping midnight (e.g. quiet 13-15 siesta): inside is true,
    before is false."""
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            cur_utc_hour = await conn.fetchval(
                "SELECT extract(hour FROM CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::INT"
            )

            inside_offset = (14 - cur_utc_hour) % 24
            tz_inside = f"Etc/GMT{('+' if inside_offset == 0 else '-')}{inside_offset if inside_offset else 0}"
            await conn.execute("SELECT set_config('channel.sender.siesta_in.timezone', $1::jsonb)", f'"{tz_inside}"')
            await conn.execute("SELECT set_config('channel.sender.siesta_in.quiet_start_hour', '13'::jsonb)")
            await conn.execute("SELECT set_config('channel.sender.siesta_in.quiet_end_hour', '15'::jsonb)")
            assert await conn.fetchval("SELECT is_sender_quiet('siesta_in')") is True

            before_offset = (12 - cur_utc_hour) % 24
            tz_before = f"Etc/GMT{('+' if before_offset == 0 else '-')}{before_offset if before_offset else 0}"
            await conn.execute("SELECT set_config('channel.sender.siesta_before.timezone', $1::jsonb)", f'"{tz_before}"')
            await conn.execute("SELECT set_config('channel.sender.siesta_before.quiet_start_hour', '13'::jsonb)")
            await conn.execute("SELECT set_config('channel.sender.siesta_before.quiet_end_hour', '15'::jsonb)")
            assert await conn.fetchval("SELECT is_sender_quiet('siesta_before')") is False


async def test_is_sender_quiet_fails_open_on_bad_tz(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute("SELECT set_config('channel.sender.badtz.timezone', '\"Not/A/Zone\"'::jsonb)")
            await conn.execute("SELECT set_config('channel.sender.badtz.quiet_start_hour', '0'::jsonb)")
            await conn.execute("SELECT set_config('channel.sender.badtz.quiet_end_hour', '23'::jsonb)")
            result = await conn.fetchval("SELECT is_sender_quiet('badtz')")
            assert result is False


async def test_is_sender_quiet_falls_back_to_agent_window(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute("SELECT set_config('heartbeat.night_start_hour', '22'::jsonb)")
            await conn.execute("SELECT set_config('heartbeat.night_end_hour', '6'::jsonb)")
            cur_utc_hour = await conn.fetchval(
                "SELECT extract(hour FROM CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::INT"
            )
            target_local = 23
            offset = (target_local - cur_utc_hour) % 24
            tz_name = f"Etc/GMT{('+' if offset == 0 else '-')}{offset if offset else 0}"
            await conn.execute("SELECT set_config('channel.sender.fallback1.timezone', $1::jsonb)", f'"{tz_name}"')
            # NOTE: no per-sender quiet_start/end_hour set — uses agent defaults.
            result = await conn.fetchval("SELECT is_sender_quiet('fallback1')")
            assert result is True


async def test_active_senders_context_includes_timezone_localhour_isquiet(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute("SELECT set_config('channel.sender.tzprobe.timezone', '\"Etc/GMT-8\"'::jsonb)")
            await conn.execute(
                """
                INSERT INTO channel_sessions (channel_type, channel_id, sender_id, last_active)
                VALUES ('telegram', 'tzprobe', 'tzprobe', CURRENT_TIMESTAMP - INTERVAL '5 minutes')
                """,
            )

            raw = await conn.fetchval("SELECT get_active_senders_context(8, 7)")
            rows = raw if isinstance(raw, list) else json.loads(raw)
            row = next(r for r in rows if r["sender_id"] == "tzprobe")
            assert row["timezone"] == "Etc/GMT-8"
            assert isinstance(row["local_hour"], int)
            assert 0 <= row["local_hour"] <= 23
            cur_utc_hour = await conn.fetchval(
                "SELECT extract(hour FROM CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::INT"
            )
            assert row["local_hour"] == (cur_utc_hour + 8) % 24
            assert isinstance(row["is_quiet"], bool)
