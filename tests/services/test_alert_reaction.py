"""Tests for services.alert_reaction."""
from __future__ import annotations

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
