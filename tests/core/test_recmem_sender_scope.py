"""B (sender-scope on RecMem read path): the recmem_recall_context SQL already
implements the +0.1 own-sender boost via its 6th param p_current_sender. These
tests pin that the Python wrappers (_recall_recmem, hydrate_recmem, hydrate)
actually thread current_sender through to that arg — without it the boost never
fires (param defaults NULL).
"""
from __future__ import annotations

import json

import pytest

from core.cognitive_memory_api import CognitiveMemory

pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.core]


class _Acquire:
    def __init__(self, conn):
        self.conn = conn

    async def __aenter__(self):
        return self.conn

    async def __aexit__(self, *_exc):
        return False


class _Pool:
    def __init__(self, conn):
        self.conn = conn

    def acquire(self):
        return _Acquire(self.conn)


class _Conn:
    def __init__(self):
        self.fetch_calls = []
        self.fetchval_result = None
        self.fetch_rows = []

    async def fetchval(self, query, *args):
        return self.fetchval_result

    async def fetch(self, query, *args):
        self.fetch_calls.append((query, args))
        return self.fetch_rows


async def test_recall_recmem_threads_current_sender_as_sixth_arg():
    conn = _Conn()
    mem = CognitiveMemory(_Pool(conn))
    async with mem._pool.acquire() as c:
        await mem._recall_recmem(c, "apples", 10, current_sender="alice")
    query, args = conn.fetch_calls[0]
    assert "recmem_recall_context" in query
    assert len(args) == 6, "current_sender must be passed as the 6th SQL arg"
    assert args[5] == "alice"


async def test_recall_recmem_defaults_sender_to_none():
    conn = _Conn()
    mem = CognitiveMemory(_Pool(conn))
    async with mem._pool.acquire() as c:
        await mem._recall_recmem(c, "apples", 10)
    _query, args = conn.fetch_calls[0]
    assert args[5] is None


async def test_hydrate_recmem_accepts_and_threads_current_sender():
    conn = _Conn()
    mem = CognitiveMemory(_Pool(conn))
    await mem.hydrate_recmem("apples", sub_limit=5, epi_limit=5, sem_limit=5, current_sender="bob")
    _query, args = conn.fetch_calls[0]
    assert args[5] == "bob"


async def test_hydrate_forwards_current_sender_to_recall(monkeypatch):
    conn = _Conn()
    conn.fetchval_result = json.dumps({})  # gather_turn_context() stub
    mem = CognitiveMemory(_Pool(conn))

    captured: dict[str, object] = {}

    async def _fake_recall(c, q, lim, *, session_id=None, current_sender=None, **_kw):
        captured["current_sender"] = current_sender
        return []

    monkeypatch.setattr(mem, "_recall_recmem", _fake_recall)

    await mem.hydrate(
        "apples",
        include_partial=False,
        include_identity=False,
        include_worldview=False,
        include_emotional_state=False,
        include_drives=False,
        current_sender="alice",
    )
    assert captured["current_sender"] == "alice"
