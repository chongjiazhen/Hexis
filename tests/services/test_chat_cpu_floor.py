"""ADR-020 phase 6: the slim chat path is driven by LIVE SERVING CAPABILITY
(is the :8090 upstream the 1B CPU floor?), not by the retired agent.power_mode
DB flag.

The slim path exists because the 1B cannot parse the heavy tool template — it
emits code-REPL garbage and leaks the prompt template (fleet probe, tools/probe-eco).
That is a property of the live backend, so the live backend is what decides.
"""
from contextlib import asynccontextmanager
from uuid import uuid4

import pytest

import services.chat as chat

pytestmark = pytest.mark.asyncio


class _Mem:
    """Records the persisted turn so we can assert the origin tag survives."""

    def __init__(self):
        self.record_chat_turn_memory_calls = []

    async def record_chat_turn_memory(self, *args, **kwargs):
        self.record_chat_turn_memory_calls.append((args, kwargs))
        return {"direct_promoted": True, "raw": {"status": "stored"}}

    async def remember(self, *args, **kwargs):
        return uuid4()


def _patch_slim_stack(monkeypatch, *, mem, reply):
    @asynccontextmanager
    async def fake_connect(_dsn, **_kwargs):
        yield mem

    async def fake_slim(**_kwargs):
        return reply

    async def fake_decline_enabled(*_a, **_k):
        return False

    monkeypatch.setattr(chat.CognitiveMemory, "connect", fake_connect)
    monkeypatch.setattr(chat, "_eco_slim_chat", fake_slim)
    monkeypatch.setattr(chat, "_read_decline_enabled", fake_decline_enabled)


async def test_chat_turn_on_cpu_floor_takes_slim_path(monkeypatch):
    mem = _Mem()
    _patch_slim_stack(monkeypatch, mem=mem, reply="slim floor reply")

    async def fake_floor():
        return True
    monkeypatch.setattr(chat, "on_cpu_floor", fake_floor)

    result = await chat.chat_turn(
        user_message="hi",
        history=[],
        llm_config={"provider": "openai", "model": "nano"},
        dsn="postgresql://unused",
        pool=None,
    )

    assert result["assistant"] == "slim floor reply"
    _args, kwargs = mem.record_chat_turn_memory_calls[0]
    assert kwargs["context"]["metadata"]["origin"] == "eco"


async def test_stream_chat_turn_on_cpu_floor_takes_slim_path(monkeypatch):
    mem = _Mem()
    _patch_slim_stack(monkeypatch, mem=mem, reply="slim stream reply")

    async def fake_floor():
        return True
    monkeypatch.setattr(chat, "on_cpu_floor", fake_floor)

    chunks = [
        chunk
        async for chunk in chat.stream_chat_turn(
            user_message="hi",
            history=[],
            llm_config={"provider": "openai", "model": "nano"},
            dsn="postgresql://unused",
            pool=None,
        )
    ]

    assert "".join(chunks) == "slim stream reply"
    _args, kwargs = mem.record_chat_turn_memory_calls[0]
    assert kwargs["context"]["metadata"]["origin"] == "eco"


async def test_chat_turn_off_floor_does_not_take_slim_path(monkeypatch):
    """GPU backend live -> the slim path must NOT fire. Proven by making the
    slim call explode: if the heavy path is taken, it is never reached."""
    async def fake_floor():
        return False
    monkeypatch.setattr(chat, "on_cpu_floor", fake_floor)

    async def boom(**_kwargs):
        raise AssertionError("slim path must not fire while the GPU backend is live")
    monkeypatch.setattr(chat, "_eco_slim_chat", boom)

    async def fake_decline_enabled(*_a, **_k):
        return False
    monkeypatch.setattr(chat, "_read_decline_enabled", fake_decline_enabled)

    # The heavy path needs a pool; the unreachable DSN makes asyncpg raise. Either
    # way we must NOT get an AssertionError from `boom` — that would mean the slim
    # path fired.
    with pytest.raises(Exception) as exc:
        await chat.chat_turn(
            user_message="hi",
            history=[],
            llm_config={"provider": "openai", "model": "big"},
            dsn="postgresql://nope:0/none",
            pool=None,
        )
    assert not isinstance(exc.value, AssertionError)


async def test_router_unreachable_fails_open_to_heavy_path(monkeypatch):
    """Fail-open: a dead router probe must not route chat onto the slim path.
    Mirrors the retired _read_power_mode's fail-to-'prime' posture."""
    from core import serving

    async def dead_health(_url, timeout=2.0):
        return None
    monkeypatch.setattr(serving, "fetch_router_health", dead_health)

    async def boom(**_kwargs):
        raise AssertionError("probe failure must not fire the slim path")
    monkeypatch.setattr(chat, "_eco_slim_chat", boom)

    async def fake_decline_enabled(*_a, **_k):
        return False
    monkeypatch.setattr(chat, "_read_decline_enabled", fake_decline_enabled)

    with pytest.raises(Exception) as exc:
        await chat.chat_turn(
            user_message="hi",
            history=[],
            llm_config={"provider": "openai", "model": "big"},
            dsn="postgresql://nope:0/none",
            pool=None,
        )
    assert not isinstance(exc.value, AssertionError)
