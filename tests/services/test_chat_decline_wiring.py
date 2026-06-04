import pytest

import services.chat as chat
from services.decline import Decline

pytestmark = pytest.mark.asyncio


async def test_apply_decline_disabled_passes_through(monkeypatch):
    called = {}

    async def _spy(**kwargs):
        called["hit"] = True

    monkeypatch.setattr(chat, "_remember_decline", _spy)
    text, declined = await chat._apply_decline(
        assistant_text="[DECLINE:plain:x]", user_message="hi", decline_enabled=False,
        session_id=None, history=[], sender_id=None, pool=None, dsn="noop", origin="prime",
    )
    assert declined is False
    assert text == "[DECLINE:plain:x]"   # untouched
    assert "hit" not in called          # no memory write


async def test_apply_decline_normal_reply_passes_through(monkeypatch):
    async def _spy(**kwargs):
        raise AssertionError("should not record a non-decline")

    monkeypatch.setattr(chat, "_remember_decline", _spy)
    text, declined = await chat._apply_decline(
        assistant_text="a normal answer", user_message="hi", decline_enabled=True,
        session_id=None, history=[], sender_id=None, pool=None, dsn="noop", origin="prime",
    )
    assert declined is False
    assert text == "a normal answer"


async def test_apply_decline_honors_marker_and_records(monkeypatch):
    captured = {}

    async def _spy(*, user_message, decline, **kwargs):
        captured["decline"] = decline
        captured["origin"] = kwargs.get("origin")

    monkeypatch.setattr(chat, "_remember_decline", _spy)
    text, declined = await chat._apply_decline(
        assistant_text="[DECLINE:blunt:private]", user_message="hi", decline_enabled=True,
        session_id="s1", history=[], sender_id="u1", pool=None, dsn="noop", origin="eco",
    )
    assert declined is True
    assert text == "[DECLINED]"
    assert isinstance(captured["decline"], Decline)
    assert captured["decline"].reason == "private"
    assert captured["origin"] == "eco"


async def test_read_decline_enabled_failure_returns_false(monkeypatch):
    # No pool, bad dsn -> connection fails -> fail toward replying (False).
    val = await chat._read_decline_enabled(None, "postgresql://nope:0/none")
    assert val is False


async def test_chat_turn_eco_path_declines(monkeypatch):
    """ECO path: a decline marker from the slim call is honored + rendered."""
    async def _fake_power_mode(*a, **k):
        return "eco"
    monkeypatch.setattr(chat, "_read_power_mode", _fake_power_mode)

    async def _fake_decline_enabled(*a, **k):
        return True
    monkeypatch.setattr(chat, "_read_decline_enabled", _fake_decline_enabled)

    async def _fake_slim(**kwargs):
        return "[DECLINE:plain:napping]"
    monkeypatch.setattr(chat, "_eco_slim_chat", _fake_slim)

    recorded = {}
    async def _fake_remember(*, decline, origin, **kwargs):
        recorded["origin"] = origin
        recorded["register"] = decline.register
    monkeypatch.setattr(chat, "_remember_decline", _fake_remember)

    async def _no_eco_remember(**kwargs):
        raise AssertionError("declined turn must not call _eco_remember")
    monkeypatch.setattr(chat, "_eco_remember", _no_eco_remember)

    out = await chat.chat_turn(
        user_message="you up?", history=[], llm_config={"model": "x"},
        dsn="noop", session_id="s", pool=None,
    )
    assert out["assistant"] == "[DECLINED: napping]"
    assert recorded["origin"] == "eco"


async def test_stream_chat_turn_eco_path_declines(monkeypatch):
    """Streaming ECO path: a decline marker is honored + rendered in the yielded chunk."""
    async def _fake_power_mode(*a, **k):
        return "eco"
    monkeypatch.setattr(chat, "_read_power_mode", _fake_power_mode)

    async def _fake_decline_enabled(*a, **k):
        return True
    monkeypatch.setattr(chat, "_read_decline_enabled", _fake_decline_enabled)

    async def _fake_slim(**kwargs):
        return "[DECLINE:blunt:busy]"
    monkeypatch.setattr(chat, "_eco_slim_chat", _fake_slim)

    recorded = {}
    async def _fake_remember(*, decline, origin, **kwargs):
        recorded["origin"] = origin
        recorded["register"] = decline.register
    monkeypatch.setattr(chat, "_remember_decline", _fake_remember)

    async def _no_eco_remember(**kwargs):
        raise AssertionError("declined stream turn must not call _eco_remember")
    monkeypatch.setattr(chat, "_eco_remember", _no_eco_remember)

    chunks = []
    async for c in chat.stream_chat_turn(
        user_message="you up?", history=[], llm_config={"model": "x"},
        dsn="noop", session_id="s", pool=None,
    ):
        chunks.append(c)

    assert chunks == ["[DECLINED]"]          # blunt render
    assert recorded["origin"] == "eco"
    assert recorded["register"] == "blunt"


async def test_decline_prompt_loads_and_mentions_marker():
    # async def so it doesn't trip the module-level pytest.mark.asyncio on a sync test
    from services.prompt_resources import load_decline_prompt
    text = load_decline_prompt()
    assert "[DECLINE:" in text
    assert "gentle" in text and "plain" in text and "blunt" in text
