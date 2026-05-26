import json
import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


async def test_get_active_senders_context_returns_recent_distinct_senders(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute(
                """
                INSERT INTO channel_sessions (channel_type, channel_id, sender_id, last_active)
                VALUES
                    ('telegram', '111', '111', CURRENT_TIMESTAMP - INTERVAL '2 hours'),
                    ('telegram', '222', '222', CURRENT_TIMESTAMP - INTERVAL '1 day'),
                    ('telegram', '333', '333', CURRENT_TIMESTAMP - INTERVAL '30 days'),
                    ('telegram', '111', '111', CURRENT_TIMESTAMP - INTERVAL '10 minutes')
                ON CONFLICT DO NOTHING
                """,
            )

            raw = await conn.fetchval("SELECT get_active_senders_context(5, 7)")
            senders = raw if isinstance(raw, list) else json.loads(raw)

            ids = [s["sender_id"] for s in senders]
            assert "111" in ids
            assert "222" in ids
            assert "333" not in ids  # outside 7-day window
            # Most-recent first
            assert ids.index("111") < ids.index("222")
            for s in senders:
                assert "channel_type" in s
                assert "last_active" in s

            await conn.execute("ROLLBACK")
