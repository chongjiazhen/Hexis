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
