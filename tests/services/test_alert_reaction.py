"""Tests for services.alert_reaction."""
from __future__ import annotations

import json

import pytest

from services.alert_reaction import build_alert_outbox_message


def test_build_alert_outbox_message():
    msg = build_alert_outbox_message("BTC crossed 70k", "-100999")
    assert msg["kind"] == "alert"
    assert msg["payload"]["content"] == "BTC crossed 70k"
    assert msg["payload"]["delivery_mode"] == "direct"
    assert msg["payload"]["target_channel"] == "telegram"
    assert msg["payload"]["target_id"] == "-100999"


def test_build_alert_outbox_message_coerces_chat_id():
    msg = build_alert_outbox_message("x", -100999)
    assert msg["payload"]["target_id"] == "-100999"


import services.alert_reaction as ar

pytestmark_db = pytest.mark.asyncio(loop_scope="session")


class _FakeResult(dict):
    pass


@pytest.mark.asyncio
async def test_generate_alert_reaction_returns_comment(monkeypatch):
    async def fake_persona(pool, dsn):
        return "You are Vera."

    async def fake_resolve(pool, key, fallback_key=None):
        return {"provider": "openai_compatible", "model": "m", "endpoint": "e",
                "api_key_env": "NOOP_KEY"}

    async def fake_completion(**kwargs):
        return {"content": "Watching that level closely."}

    monkeypatch.setattr(ar, "_load_persona_system_prompt", fake_persona)
    monkeypatch.setattr(ar, "resolve_llm_config", fake_resolve)
    monkeypatch.setattr(ar, "chat_completion", fake_completion)

    out = await ar.generate_alert_reaction(None, alert_text="BTC 70k", title="price")
    assert out == "Watching that level closely."


@pytest.mark.asyncio
async def test_generate_alert_reaction_silence(monkeypatch):
    async def fake_persona(pool, dsn):
        return "You are Vera."

    async def fake_resolve(pool, key, fallback_key=None):
        return {"provider": "openai_compatible", "model": "m", "endpoint": "e",
                "api_key_env": "NOOP_KEY"}

    async def fake_completion(**kwargs):
        return {"content": "[pass]"}

    monkeypatch.setattr(ar, "_load_persona_system_prompt", fake_persona)
    monkeypatch.setattr(ar, "resolve_llm_config", fake_resolve)
    monkeypatch.setattr(ar, "chat_completion", fake_completion)

    out = await ar.generate_alert_reaction(None, alert_text="BTC 70k")
    assert out is None


class _FakeBridge:
    def __init__(self):
        self.published: list[dict] = []

    async def publish_outbox_payloads(self, messages):
        self.published.extend(messages)
        return len(messages)


@pytestmark_db
async def test_react_to_pending_alerts_marks_reacted(db_pool, monkeypatch):
    # Configure the alert chat so the scan does not early-return.
    async with db_pool.acquire() as conn:
        await conn.execute(
            "SELECT set_config('channel.telegram.alert_chat_id', '\"-100777\"'::jsonb)"
        )
        memory_id = await conn.fetchval(
            """
            SELECT create_episodic_memory(
                p_content := 'Alert (normal): test alert body',
                p_importance := 0.4,
                p_emotional_valence := 0.0,
                p_context := $1::jsonb,
                p_source_attribution := '{}'::jsonb,
                p_trust_level := 0.8)
            """,
            json.dumps({
                "kind": "alert", "priority": "normal",
                "alert_text": "test alert body", "title": "t", "reacted": False,
            }),
        )

    # Persona stays silent — exercises the mark-reacted path without an LLM.
    async def fake_reaction(pool, *, alert_text, title=None):
        return None

    monkeypatch.setattr(ar, "generate_alert_reaction", fake_reaction)

    bridge = _FakeBridge()
    count = await ar.react_to_pending_alerts(db_pool, bridge)
    assert count == 1

    async with db_pool.acquire() as conn:
        ctx = await conn.fetchval(
            "SELECT metadata->'context' FROM memories WHERE id = $1", memory_id
        )
    ctx = json.loads(ctx) if isinstance(ctx, str) else ctx
    assert ctx["reacted"] is True

    # Clean up so re-runs stay deterministic.
    async with db_pool.acquire() as conn:
        await conn.execute("DELETE FROM memories WHERE id = $1", memory_id)


@pytest.mark.asyncio
async def test_generate_alert_reaction_llm_error_is_silence(monkeypatch):
    async def fake_persona(pool, dsn):
        return "You are Vera."

    async def fake_resolve(pool, key, fallback_key=None):
        return {"provider": "openai_compatible", "model": "m", "endpoint": "e",
                "api_key_env": "NOOP_KEY"}

    async def fake_completion(**kwargs):
        raise RuntimeError("LLM down")

    monkeypatch.setattr(ar, "_load_persona_system_prompt", fake_persona)
    monkeypatch.setattr(ar, "resolve_llm_config", fake_resolve)
    monkeypatch.setattr(ar, "chat_completion", fake_completion)

    out = await ar.generate_alert_reaction(None, alert_text="BTC 70k")
    assert out is None
