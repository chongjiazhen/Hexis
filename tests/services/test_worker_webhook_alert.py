"""Tests for the alert-source webhook handler in worker_service."""
from __future__ import annotations

import json
import types

import pytest

import services.worker_service as ws

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


class _FakeBridge:
    def __init__(self):
        self.published: list[dict] = []

    async def publish_outbox_payloads(self, messages):
        self.published.extend(messages)
        return len(messages)


def _event(corr="corr-test"):
    return types.SimpleNamespace(correlation_id=corr)


async def test_alert_webhook_missing_text_raises(db_pool):
    async with db_pool.acquire() as conn:
        await conn.execute(
            "SELECT set_config('channel.telegram.alert_chat_id', '\"-100777\"'::jsonb)"
        )
    with pytest.raises(ValueError):
        await ws._handle_alert_webhook(db_pool, _FakeBridge(), _event(), {})


async def test_alert_webhook_unconfigured_chat_raises(db_pool):
    async with db_pool.acquire() as conn:
        await conn.execute(
            "SELECT set_config('channel.telegram.alert_chat_id', 'null'::jsonb)"
        )
    with pytest.raises(ValueError):
        await ws._handle_alert_webhook(
            db_pool, _FakeBridge(), _event(), {"text": "hi"}
        )


async def test_alert_webhook_normal_delivers_and_records(db_pool):
    async with db_pool.acquire() as conn:
        await conn.execute(
            "SELECT set_config('channel.telegram.alert_chat_id', '\"-100777\"'::jsonb)"
        )
    bridge = _FakeBridge()
    result = await ws._handle_alert_webhook(
        db_pool, bridge, _event(),
        {"text": "BTC 70k", "priority": "normal", "title": "price"},
    )
    assert result["delivered"] is True
    assert result["reacted"] is False
    # Raw alert delivered verbatim, exactly once.
    assert len(bridge.published) == 1
    assert bridge.published[0]["payload"]["content"] == "BTC 70k"

    async with db_pool.acquire() as conn:
        row = await conn.fetchrow(
            "SELECT importance, metadata->'context' AS context FROM memories "
            "WHERE metadata->'context'->>'kind' = 'alert' "
            "ORDER BY created_at DESC LIMIT 1"
        )
    assert abs(row["importance"] - 0.4) < 0.001
    ctx = json.loads(row["context"]) if isinstance(row["context"], str) else row["context"]
    assert ctx["reacted"] is False
    assert ctx["priority"] == "normal"

    async with db_pool.acquire() as conn:
        await conn.execute(
            "DELETE FROM memories WHERE metadata->'context'->>'kind' = 'alert'"
        )


async def test_alert_webhook_high_priority_reacts(db_pool, monkeypatch):
    async with db_pool.acquire() as conn:
        await conn.execute(
            "SELECT set_config('channel.telegram.alert_chat_id', '\"-100777\"'::jsonb)"
        )

    async def fake_reaction(pool, *, alert_text, title=None):
        return "On it."

    monkeypatch.setattr(ws, "generate_alert_reaction", fake_reaction)

    bridge = _FakeBridge()
    result = await ws._handle_alert_webhook(
        db_pool, bridge, _event(),
        {"text": "BTC 80k", "priority": "high"},
    )
    assert result["reacted"] is True
    # Two publishes: raw alert + reaction.
    assert len(bridge.published) == 2
    assert bridge.published[0]["payload"]["content"] == "BTC 80k"
    assert bridge.published[1]["payload"]["content"] == "On it."

    async with db_pool.acquire() as conn:
        row = await conn.fetchrow(
            "SELECT importance, metadata->'context' AS context FROM memories "
            "WHERE metadata->'context'->>'kind' = 'alert' "
            "ORDER BY created_at DESC LIMIT 1"
        )
    assert abs(row["importance"] - 0.7) < 0.001
    ctx = json.loads(row["context"]) if isinstance(row["context"], str) else row["context"]
    assert ctx["reacted"] is True

    async with db_pool.acquire() as conn:
        await conn.execute(
            "DELETE FROM memories WHERE metadata->'context'->>'kind' = 'alert'"
        )
