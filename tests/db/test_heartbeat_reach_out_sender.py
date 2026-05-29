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



async def test_record_reach_out_sender_initializes_log_entry(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute("SELECT record_reach_out_sender('s1')")
            raw = await conn.fetchval(
                "SELECT value->'reach_out_sender_log'->'s1' FROM state WHERE key='heartbeat_state'"
            )
            entry = raw if isinstance(raw, dict) else json.loads(raw)
            assert entry["unanswered_count"] == 1
            assert entry["last_at"] is not None


async def test_record_reach_out_sender_increments_when_unanswered(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute("UPDATE heartbeat_state SET last_user_contact = NULL WHERE id=1")
            await conn.execute("SELECT record_reach_out_sender('s2')")
            await conn.execute("SELECT record_reach_out_sender('s2')")
            raw = await conn.fetchval(
                "SELECT value->'reach_out_sender_log'->'s2' FROM state WHERE key='heartbeat_state'"
            )
            entry = raw if isinstance(raw, dict) else json.loads(raw)
            assert entry["unanswered_count"] == 2


async def test_record_reach_out_sender_resets_after_user_reply(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute("UPDATE heartbeat_state SET last_user_contact = NULL WHERE id=1")
            await conn.execute("SELECT record_reach_out_sender('s3')")
            await conn.execute("UPDATE heartbeat_state SET last_user_contact = CURRENT_TIMESTAMP WHERE id=1")
            await conn.execute("SELECT record_reach_out_sender('s3')")
            raw = await conn.fetchval(
                "SELECT value->'reach_out_sender_log'->'s3' FROM state WHERE key='heartbeat_state'"
            )
            entry = raw if isinstance(raw, dict) else json.loads(raw)
            assert entry["unanswered_count"] == 1, "reply since last_at must restart the streak at 1"


async def test_can_reach_out_sender_is_removed(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            exists = await conn.fetchval(
                "SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'can_reach_out_sender')"
            )
            assert exists is False, "can_reach_out_sender must be dropped (no longer a gate)"


async def test_reach_out_not_blocked_by_prior_unanswered(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute("UPDATE heartbeat_state SET current_energy = 20, is_paused = FALSE WHERE id=1")
            await conn.execute("UPDATE heartbeat_state SET last_user_contact = NULL WHERE id=1")
            await conn.execute("SELECT record_reach_out_sender('p1')")  # already 1 unanswered
            raw = await conn.fetchval(
                """
                SELECT execute_heartbeat_action(
                    gen_random_uuid(), 'reach_out_user',
                    jsonb_build_object('sender_id','p1','message','still thinking of you','intent','check_in')
                )
                """
            )
            res = raw if isinstance(raw, dict) else json.loads(raw)
            assert res["result"].get("queued") is True, "prior unanswered reach-out must NOT veto a new one"


async def test_reach_out_not_blocked_during_quiet_hours(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute("UPDATE heartbeat_state SET current_energy = 20, is_paused = FALSE WHERE id=1")
            cur_utc_hour = await conn.fetchval(
                "SELECT extract(hour FROM CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::INT"
            )
            offset = (23 - cur_utc_hour) % 24
            tz_name = f"Etc/GMT{('+' if offset == 0 else '-')}{offset if offset else 0}"
            await conn.execute("SELECT set_config('channel.sender.q9.timezone', $1::jsonb)", f'"{tz_name}"')
            await conn.execute("SELECT set_config('channel.sender.q9.quiet_start_hour', '22'::jsonb)")
            await conn.execute("SELECT set_config('channel.sender.q9.quiet_end_hour', '6'::jsonb)")
            assert await conn.fetchval("SELECT is_sender_quiet('q9')") is True
            raw = await conn.fetchval(
                """
                SELECT execute_heartbeat_action(
                    gen_random_uuid(), 'reach_out_user',
                    jsonb_build_object('sender_id','q9','message','late night thought','intent','check_in')
                )
                """
            )
            res = raw if isinstance(raw, dict) else json.loads(raw)
            assert res["result"].get("queued") is True, "quiet hours must NOT veto; it is context only"


async def test_environment_snapshot_exposes_agent_local_time(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute("SELECT set_config('heartbeat.timezone', '\"Asia/Singapore\"'::jsonb)")
            raw = await conn.fetchval("SELECT get_environment_snapshot()")
            snap = raw if isinstance(raw, dict) else json.loads(raw)
            assert "agent_local_time" in snap
            assert "agent_local_hour" in snap
            utc_hour = await conn.fetchval("SELECT extract(hour FROM CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::INT")
            assert snap["agent_local_hour"] == (utc_hour + 8) % 24


async def test_environment_snapshot_invalid_timezone_falls_back_to_utc(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute("SELECT set_config('heartbeat.timezone', '\"Not/AZone\"'::jsonb)")
            # Must NOT raise even though the configured zone is invalid.
            raw = await conn.fetchval("SELECT get_environment_snapshot()")
            snap = raw if isinstance(raw, dict) else json.loads(raw)
            assert snap["agent_timezone"] == "UTC"
            utc_hour = await conn.fetchval("SELECT extract(hour FROM CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::INT")
            assert snap["agent_local_hour"] == utc_hour


async def test_active_senders_context_exposes_reach_out_signal(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            # Ensure a valid fallback timezone so AT TIME ZONE doesn't blow up for
            # senders without a per-sender timezone config (prior test may have set
            # heartbeat.timezone to an invalid value).
            await conn.execute("SELECT set_config('heartbeat.timezone', '\"UTC\"'::jsonb)")
            await conn.execute(
                """
                INSERT INTO channel_sessions (channel_type, channel_id, sender_id, last_active)
                VALUES ('telegram', 'sig1', 'sig1', CURRENT_TIMESTAMP - INTERVAL '10 minutes')
                ON CONFLICT (channel_type, channel_id, sender_id) DO UPDATE SET last_active = EXCLUDED.last_active
                """
            )
            await conn.execute("UPDATE heartbeat_state SET last_user_contact = NULL WHERE id=1")
            await conn.execute("SELECT record_reach_out_sender('sig1')")  # 1 unanswered

            raw = await conn.fetchval("SELECT get_active_senders_context(50, 7)")
            senders = raw if isinstance(raw, list) else json.loads(raw)
            row = next(s for s in senders if s["sender_id"] == "sig1")
            assert row["unanswered_reach_out_count"] == 1
            assert row["replied_since"] is False
            assert row["hours_since_my_last_reach_out"] is not None
            assert "recent_user_message_times" in row


async def test_active_senders_count_reconciles_to_zero_after_reply(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            # Ensure a valid fallback timezone (same reason as previous test).
            await conn.execute("SELECT set_config('heartbeat.timezone', '\"UTC\"'::jsonb)")
            await conn.execute(
                """
                INSERT INTO channel_sessions (channel_type, channel_id, sender_id, last_active)
                VALUES ('telegram', 'sig2', 'sig2', CURRENT_TIMESTAMP - INTERVAL '5 minutes')
                ON CONFLICT (channel_type, channel_id, sender_id) DO UPDATE SET last_active = EXCLUDED.last_active
                """
            )
            await conn.execute("UPDATE heartbeat_state SET last_user_contact = NULL WHERE id=1")
            await conn.execute("SELECT record_reach_out_sender('sig2')")
            # user replies AFTER the reach-out (persisted count still 1, but display must reconcile)
            await conn.execute("UPDATE heartbeat_state SET last_user_contact = CURRENT_TIMESTAMP WHERE id=1")
            raw = await conn.fetchval("SELECT get_active_senders_context(50, 7)")
            senders = raw if isinstance(raw, list) else json.loads(raw)
            row = next(s for s in senders if s["sender_id"] == "sig2")
            assert row["replied_since"] is True
            assert row["unanswered_reach_out_count"] == 0, "displayed count must reconcile to 0 after a reply"


async def test_brake_off_by_default_allows_repeated_reach_out(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute("DELETE FROM config WHERE key='heartbeat.reach_out_max_unanswered'")
            await conn.execute("UPDATE heartbeat_state SET current_energy = 20, is_paused = FALSE WHERE id=1")
            await conn.execute("UPDATE heartbeat_state SET last_user_contact = CURRENT_TIMESTAMP - INTERVAL '2 days' WHERE id=1")
            for _ in range(5):
                await conn.execute("SELECT record_reach_out_sender('b1')")
            raw = await conn.fetchval(
                """
                SELECT execute_heartbeat_action(
                    gen_random_uuid(), 'reach_out_user',
                    jsonb_build_object('sender_id','b1','message','hi again','intent','check_in')
                )
                """
            )
            res = raw if isinstance(raw, dict) else json.loads(raw)
            assert res["result"].get("queued") is True


async def test_brake_suppresses_when_streak_exceeds_threshold(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute("SELECT set_config('heartbeat.reach_out_max_unanswered', '2'::jsonb)")
            await conn.execute("UPDATE heartbeat_state SET current_energy = 20, is_paused = FALSE WHERE id=1")
            await conn.execute("UPDATE heartbeat_state SET last_user_contact = CURRENT_TIMESTAMP - INTERVAL '2 days' WHERE id=1")
            await conn.execute("SELECT record_reach_out_sender('b2')")
            await conn.execute("SELECT record_reach_out_sender('b2')")  # streak now 2 (>= N)
            raw = await conn.fetchval(
                """
                SELECT execute_heartbeat_action(
                    gen_random_uuid(), 'reach_out_user',
                    jsonb_build_object('sender_id','b2','message','hi again','intent','check_in')
                )
                """
            )
            res = raw if isinstance(raw, dict) else json.loads(raw)
            assert res["result"].get("queued") is False
            assert res["result"].get("reason") == "reach_out_max_unanswered"


async def test_brake_allows_when_streak_just_below_threshold(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute("SELECT set_config('heartbeat.reach_out_max_unanswered', '2'::jsonb)")
            await conn.execute("UPDATE heartbeat_state SET current_energy = 20, is_paused = FALSE WHERE id=1")
            await conn.execute("UPDATE heartbeat_state SET last_user_contact = CURRENT_TIMESTAMP - INTERVAL '2 days' WHERE id=1")
            await conn.execute("SELECT record_reach_out_sender('b3')")  # streak now 1 (< 2)
            raw = await conn.fetchval(
                """
                SELECT execute_heartbeat_action(
                    gen_random_uuid(), 'reach_out_user',
                    jsonb_build_object('sender_id','b3','message','hi again','intent','check_in')
                )
                """
            )
            res = raw if isinstance(raw, dict) else json.loads(raw)
            assert res["result"].get("queued") is True, "streak below threshold must NOT be braked (>= boundary)"


async def test_brake_suppression_refunds_energy(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute("SELECT set_config('heartbeat.reach_out_max_unanswered', '2'::jsonb)")
            await conn.execute("UPDATE heartbeat_state SET current_energy = 20, is_paused = FALSE WHERE id=1")
            await conn.execute("UPDATE heartbeat_state SET last_user_contact = CURRENT_TIMESTAMP - INTERVAL '2 days' WHERE id=1")
            await conn.execute("SELECT record_reach_out_sender('b4')")
            await conn.execute("SELECT record_reach_out_sender('b4')")  # streak now 2 (>= N)
            energy_before = await conn.fetchval("SELECT current_energy FROM heartbeat_state WHERE id=1")
            raw = await conn.fetchval(
                """
                SELECT execute_heartbeat_action(
                    gen_random_uuid(), 'reach_out_user',
                    jsonb_build_object('sender_id','b4','message','hi again','intent','check_in')
                )
                """
            )
            res = raw if isinstance(raw, dict) else json.loads(raw)
            assert res["result"].get("queued") is False
            energy_after = await conn.fetchval("SELECT current_energy FROM heartbeat_state WHERE id=1")
            assert energy_after == energy_before, "suppressed reach-out must refund action_cost (cost-neutral)"


async def test_brake_reconcile_clears_streak_allows_send(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute("SELECT set_config('heartbeat.reach_out_max_unanswered', '2'::jsonb)")
            await conn.execute("UPDATE heartbeat_state SET current_energy = 20, is_paused = FALSE WHERE id=1")
            await conn.execute("UPDATE heartbeat_state SET last_user_contact = CURRENT_TIMESTAMP - INTERVAL '2 days' WHERE id=1")
            await conn.execute("SELECT record_reach_out_sender('b5')")
            await conn.execute("SELECT record_reach_out_sender('b5')")  # streak now 2 (>= N)
            # user replies after the reach-out — reconcile must clear the streak
            await conn.execute("UPDATE heartbeat_state SET last_user_contact = CURRENT_TIMESTAMP WHERE id=1")
            raw = await conn.fetchval(
                """
                SELECT execute_heartbeat_action(
                    gen_random_uuid(), 'reach_out_user',
                    jsonb_build_object('sender_id','b5','message','hi again','intent','check_in')
                )
                """
            )
            res = raw if isinstance(raw, dict) else json.loads(raw)
            assert res["result"].get("queued") is True, "a reply since last_at must reconcile the streak below threshold (brake not permanent)"
