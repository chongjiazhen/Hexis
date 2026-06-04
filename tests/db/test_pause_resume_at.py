import pytest


pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.db]


async def test_pause_minutes_sets_future_resume_and_stays_paused(db_pool):
    """pause_minutes sets a future resume_at; the agent stays paused until it arrives."""
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.fetchval(
                "SELECT pause_heartbeat('resting', jsonb_build_object('pause_minutes', 60))"
            )
            row = await conn.fetchrow("SELECT is_paused, resume_at FROM heartbeat_state WHERE id = 1")
            assert row["is_paused"] is True
            assert row["resume_at"] is not None

            # Wake time is in the future -> a due-check does not resume it.
            await conn.fetchval("SELECT should_run_heartbeat()")
            assert await conn.fetchval("SELECT is_paused FROM heartbeat_state WHERE id = 1") is True
        finally:
            await tr.rollback()


async def test_resume_at_in_past_auto_clears_pause(db_pool):
    """A wake time already elapsed -> should_run_heartbeat auto-resumes and clears resume_at."""
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.fetchval(
                "SELECT pause_heartbeat('short nap', jsonb_build_object('resume_at', now() - interval '1 minute'))"
            )
            assert await conn.fetchval("SELECT is_paused FROM heartbeat_state WHERE id = 1") is True

            await conn.fetchval("SELECT should_run_heartbeat()")
            assert await conn.fetchval("SELECT is_paused FROM heartbeat_state WHERE id = 1") is False
            assert await conn.fetchval("SELECT resume_at FROM heartbeat_state WHERE id = 1") is None
        finally:
            await tr.rollback()


async def test_indefinite_pause_has_no_resume_at(db_pool):
    """No duration/timestamp -> indefinite pause (operator return), no stale wake time."""
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.fetchval("SELECT pause_heartbeat('away indefinitely', '{}'::jsonb)")
            assert await conn.fetchval("SELECT resume_at FROM heartbeat_state WHERE id = 1") is None

            await conn.fetchval("SELECT should_run_heartbeat()")
            assert await conn.fetchval("SELECT is_paused FROM heartbeat_state WHERE id = 1") is True
        finally:
            await tr.rollback()
