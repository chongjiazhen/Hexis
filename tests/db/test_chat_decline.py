import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.db]


async def test_chat_decline_enabled_seeded_true(db_pool):
    """Fresh schema seeds chat.decline.enabled = true (feature on by default)."""
    async with db_pool.acquire() as conn:
        val = await conn.fetchval("SELECT get_config_bool('chat.decline.enabled')")
        assert val is True
