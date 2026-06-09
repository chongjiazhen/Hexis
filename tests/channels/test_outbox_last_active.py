"""Target-sender selection for proactive (heartbeat) reach-outs.

Covers the empty-sender fallback in ChannelOutboxConsumer._deliver_last_active.
A target-less reach-out must NOT silently land on the globally-latest DM when
the persona has more than one active partner (multi-partner personas like
Vera) — that misdelivers to the wrong person. With exactly one partner the
latest-active delivery is unambiguous and preserved.
"""
from __future__ import annotations

import pytest

from channels.outbox import ChannelOutboxConsumer


class _FakeConn:
    """Dispatches queries by SQL fingerprint; records executes."""

    def __init__(self, *, distinct_senders: int, rows_by_sender: dict, latest_row):
        self._distinct = distinct_senders
        self._rows_by_sender = rows_by_sender
        self._latest = latest_row
        self.executed: list[tuple] = []

    async def fetchval(self, query, *args):
        if "COUNT(DISTINCT sender_id)" in query:
            return self._distinct
        return None

    async def fetchrow(self, query, *args):
        if "WHERE sender_id = $1" in query:
            return self._rows_by_sender.get(args[0])
        # globally-latest (no sender filter)
        return self._latest

    async def execute(self, query, *args):
        self.executed.append((query, args))
        return None


class _FakePool:
    def __init__(self, conn: _FakeConn):
        self._conn = conn

    def acquire(self):
        conn = self._conn

        class _Acq:
            async def __aenter__(self):
                return conn

            async def __aexit__(self, *exc):
                return False

        return _Acq()


class _FakeManager:
    def __init__(self):
        self.sends: list[tuple] = []

    async def send(self, channel_type, channel_id, content, thread_id=None):
        self.sends.append((channel_type, channel_id, content))
        return "msg-id"


def _make_consumer(conn: _FakeConn) -> tuple[ChannelOutboxConsumer, _FakeManager]:
    manager = _FakeManager()
    consumer = ChannelOutboxConsumer(manager, _FakePool(conn))  # type: ignore[arg-type]
    return consumer, manager


_LATEST = {"id": "00000000-0000-0000-0000-0000000000aa", "channel_type": "telegram", "channel_id": "111", "sender_id": "alice"}
_BOB = {"id": "00000000-0000-0000-0000-0000000000bb", "channel_type": "telegram", "channel_id": "222", "sender_id": "bob"}


@pytest.mark.asyncio
async def test_targetless_reachout_skips_when_multiple_active_senders():
    """No sender_id + >1 active partner → skip, do not misdeliver to latest DM."""
    conn = _FakeConn(distinct_senders=2, rows_by_sender={}, latest_row=_LATEST)
    consumer, manager = _make_consumer(conn)

    await consumer._deliver_last_active("hey", {"message": "hey"}, "out-1")

    assert manager.sends == [], "must not deliver a target-less reach-out across multiple partners"


@pytest.mark.asyncio
async def test_targetless_reachout_delivers_when_single_active_sender():
    """No sender_id + exactly one partner → unambiguous, deliver to latest."""
    conn = _FakeConn(distinct_senders=1, rows_by_sender={}, latest_row=_LATEST)
    consumer, manager = _make_consumer(conn)

    await consumer._deliver_last_active("hey", {"message": "hey"}, "out-2")

    assert manager.sends == [("telegram", "111", "hey")]


@pytest.mark.asyncio
async def test_explicit_sender_id_delivers_sender_filtered():
    """sender_id present → deliver to that partner regardless of who is latest."""
    conn = _FakeConn(distinct_senders=2, rows_by_sender={"bob": _BOB}, latest_row=_LATEST)
    consumer, manager = _make_consumer(conn)

    await consumer._deliver_last_active("hi bob", {"message": "hi bob", "sender_id": "bob"}, "out-3")

    assert manager.sends == [("telegram", "222", "hi bob")]
