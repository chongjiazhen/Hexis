import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.db]


async def test_chat_decline_enabled_seeded_true(db_pool):
    """Fresh schema seeds chat.decline.enabled = true (feature on by default)."""
    async with db_pool.acquire() as conn:
        val = await conn.fetchval("SELECT get_config_bool('chat.decline.enabled')")
        assert val is True


async def test_record_chat_decline_inserts_memory(db_pool):
    """record_chat_decline writes one chat_decline memory with reason + register."""
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            mem_id = await conn.fetchval(
                "SELECT record_chat_decline($1, $2, $3, $4, $5, $6, $7)",
                "are you there?",         # user_text
                "[DECLINED: resting]",    # visible_text
                "cool",                   # register
                "resting",                # reason
                None,                     # session_id
                "tester",                 # source_identity
                "prime",                  # origin
            )
            assert mem_id is not None
            row = await conn.fetchrow(
                "SELECT source_attribution->>'kind' AS kind, "
                "metadata->>'register' AS register, metadata->>'reason' AS reason "
                "FROM memories WHERE id = $1",
                mem_id,
            )
            assert row["kind"] == "chat_decline"
            assert row["register"] == "cool"
            assert row["reason"] == "resting"
        finally:
            await tr.rollback()


async def test_chat_decline_log_view_surfaces_decline(db_pool):
    """chat_decline_log exposes register/reason/visible_text for the operator."""
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            await conn.fetchval(
                "SELECT record_chat_decline($1, $2, $3, $4, $5, $6, $7)",
                "ping", "[DECLINED]", "ice", "private", None, "tester", "prime",
            )
            row = await conn.fetchrow(
                "SELECT register, reason, visible_text, origin FROM chat_decline_log "
                "WHERE reason = 'private' ORDER BY created_at DESC LIMIT 1"
            )
            assert row["register"] == "ice"
            assert row["visible_text"] == "[DECLINED]"
            assert row["origin"] == "prime"
        finally:
            await tr.rollback()


async def test_record_chat_decline_null_reason_ok(db_pool):
    """A reasonless decline (ice/bare) is allowed; reason stored NULL."""
    async with db_pool.acquire() as conn:
        tr = conn.transaction()
        await tr.start()
        try:
            mem_id = await conn.fetchval(
                "SELECT record_chat_decline($1, $2, $3, $4, $5, $6, $7)",
                "yo", "[DECLINED]", "ice", None, None, "tester", "prime",
            )
            reason = await conn.fetchval(
                "SELECT metadata->>'reason' FROM memories WHERE id = $1", mem_id
            )
            assert reason is None
        finally:
            await tr.rollback()
