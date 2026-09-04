# Telegram Alert Bot + Hexis Persona Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a hexis persona inhabit the user's consolidated Telegram alert bot — delivering alerts verbatim, optionally reacting in character (tiered by priority), and recording every alert as a memory.

**Architecture:** Personal scripts `POST /api/webhook/alert` (endpoint already exists). The worker's gateway webhook handler, for `source=alert`, sends the alert text verbatim to a configured Telegram chat via the durable outbox, records it as an episodic memory, and routes a reaction: `high` priority → immediate bounded LLM turn; `normal` → batched on the next heartbeat. All reaction logic lives in one new module, `services/alert_reaction.py`.

**Tech Stack:** Python 3.12, asyncpg, pytest + pytest-asyncio, PostgreSQL, RabbitMQ outbox, llama.cpp-served LLM via `core.llm.chat_completion`.

---

## Background — read before starting

This is an existing codebase. Key facts:

- **The webhook endpoint already exists.** `apps/hexis_api.py:157` — `POST /api/webhook/{source}` calls `Gateway.submit(EventSource.WEBHOOK, "webhook:{source}", payload)`. No API change is needed; this plan only changes how the *worker* handles the queued event.
- **The webhook handler to modify** is `create_webhook_handler` in `services/worker_service.py:578`. It currently records every webhook payload as a 0.4-importance episodic memory and does nothing else.
- **The outbox** is a RabbitMQ-backed durable send queue. To send a message you build a dict `{"kind": ..., "payload": {...}}` and call `bridge.publish_outbox_payloads([msg])`. The outbox consumer (`channels/outbox.py`) routes a `payload` with `delivery_mode="direct"`, `target_channel`, `target_id` straight to that channel via `ChannelManager.send`. The outbox does **not** support reply-threading — reactions are sent as standalone follow-up messages.
- **`RabbitMQBridge`** is created once in `_amain` (`services/worker_service.py:636`) as `bridge`. It is already passed to `create_heartbeat_handler`. This plan also threads it into `create_webhook_handler`.
- **Persona prompt loader:** `services.chat._load_persona_system_prompt(pool, dsn)` returns the persona system prompt string.
- **LLM config:** `core.llm_config.resolve_llm_config(pool, "llm.chat", fallback_key="llm")` (async) returns a dict with `provider`, `model`, `endpoint`, `api_key_env`.
- **LLM call:** `core.llm.chat_completion(provider=, model=, endpoint=, api_key=, messages=, tools=None, temperature=, max_tokens=)` (async) returns `{"content": str, "tool_calls": [...], "raw": ...}`.
- **ECO mode:** `_is_eco_mode(conn)` exists at `services/worker_service.py:273`. In ECO the heartbeat timer skips entirely, so batched reactions pause automatically; the only explicit ECO guard needed is in the immediate (high-priority) path.
- **Config setter (tests):** `SELECT set_config('key', '<json>'::jsonb)`. Reader: `SELECT get_config_text('key')`.
- **Memory `context` lives under `metadata`.** The `memories` table has no bare `context` column. `create_episodic_memory(p_context := ...)` nests the value at `metadata->'context'` (see `db/05_functions_provenance_trust.sql`). All queries against the alert context flag use `metadata->'context'->>'kind'` / `->>'reacted'`, and the reacted-flag update is `jsonb_set(metadata, '{context,reacted}', 'true')`.
- **Test conventions:** async tests using the `db_pool` fixture (defined `tests/conftest.py:110`) must declare `pytestmark = [pytest.mark.asyncio(loop_scope="session")]`. Run pytest with Docker services up.

**File structure after this plan:**

| File | Responsibility |
|------|----------------|
| `services/alert_reaction.py` (new) | Outbox-message builder, the bounded reaction LLM turn, the batched heartbeat scan. |
| `services/worker_service.py` (modify) | `create_webhook_handler` gains a `bridge` param and an `alert`-source branch; `handle_heartbeat` calls the batched scan; `_amain` passes `bridge`. |
| `tests/services/test_alert_reaction.py` (new) | Unit + DB tests for the new module. |
| `tests/services/test_worker_webhook_alert.py` (new) | DB tests for the alert webhook handler. |
| `docs/specs/2026-05-22-telegram-alert-persona-design.md` (exists) | The approved design. |
| `README.md` (modify) | Short operator section: webhook contract + scheduled-ritual note. |

---

## Task 1: Outbox message builder

**Files:**
- Create: `services/alert_reaction.py`
- Test: `tests/services/test_alert_reaction.py`

- [ ] **Step 1: Write the failing test**

Create `tests/services/test_alert_reaction.py`:

```python
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/services/test_alert_reaction.py -q`
Expected: FAIL — `ModuleNotFoundError: No module named 'services.alert_reaction'`

- [ ] **Step 3: Write minimal implementation**

Create `services/alert_reaction.py`:

```python
"""Alert reaction — bounded persona reactions to incoming alerts.

An alert webhook (source=alert) delivers raw alert text to Telegram verbatim,
records it as a memory, and may run a short in-character persona reaction.
This module holds the reaction logic so the webhook handler stays thin.
"""
from __future__ import annotations

import json
import logging
import os
from typing import Any

import asyncpg

logger = logging.getLogger(__name__)


def build_alert_outbox_message(text: str, alert_chat_id: Any) -> dict[str, Any]:
    """Build an outbox message that delivers `text` to the Telegram alert chat.

    Uses delivery_mode=direct so the outbox consumer routes it straight to the
    telegram adapter without session lookup.
    """
    return {
        "kind": "alert",
        "payload": {
            "content": text,
            "delivery_mode": "direct",
            "target_channel": "telegram",
            "target_id": str(alert_chat_id),
        },
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/services/test_alert_reaction.py -q`
Expected: PASS (2 passed)

- [ ] **Step 5: Commit**

```bash
git add services/alert_reaction.py tests/services/test_alert_reaction.py
git commit -m "feat(alerts): outbox message builder for alert delivery"
```

---

## Task 2: Bounded reaction LLM turn + config reader

**Files:**
- Modify: `services/alert_reaction.py`
- Test: `tests/services/test_alert_reaction.py`

- [ ] **Step 1: Write the failing tests**

Append to `tests/services/test_alert_reaction.py`:

```python
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pytest tests/services/test_alert_reaction.py -q -k generate_alert_reaction`
Expected: FAIL — `AttributeError: module 'services.alert_reaction' has no attribute 'generate_alert_reaction'`

- [ ] **Step 3: Write the implementation**

Add these imports to the top of `services/alert_reaction.py` (after the existing imports):

```python
from core.llm import chat_completion
from core.llm_config import resolve_llm_config
from services.chat import _load_persona_system_prompt
```

Then append to `services/alert_reaction.py`:

```python
_SILENCE_TOKENS = {"", "[pass]", "pass", "[silent]", "(no comment)", "no comment"}

_REACTION_ANCHOR = (
    "An automated alert just arrived in your Telegram chat. The raw alert was "
    "already delivered to the user verbatim — do NOT repeat it. You may add ONE "
    "short in-character remark (a reaction, a piece of context, or a question) "
    "if you genuinely have something worth saying. If you have nothing to add, "
    "reply with exactly [pass] and nothing else. Keep any remark under 280 "
    "characters."
)


async def generate_alert_reaction(
    pool: asyncpg.Pool | None,
    *,
    alert_text: str,
    title: str | None = None,
) -> str | None:
    """Run one bounded LLM turn reacting to an alert.

    Returns the reaction text, or None if the persona chose silence or the
    LLM call failed (silence is a valid, first-class outcome).
    """
    persona = await _load_persona_system_prompt(pool, None)
    system_msg = (
        persona.strip() + "\n\n---\n\n" + _REACTION_ANCHOR
        if persona
        else _REACTION_ANCHOR
    )

    label = f"[{title}] " if title else ""
    user_msg = f"{label}{alert_text}"

    llm_config = await resolve_llm_config(pool, "llm.chat", fallback_key="llm")
    api_key_env = llm_config.get("api_key_env", "OPENAI_API_KEY")
    api_key = os.environ.get(api_key_env, "noop")

    try:
        result = await chat_completion(
            provider=llm_config.get("provider", "openai_compatible"),
            model=llm_config["model"],
            endpoint=llm_config.get("endpoint"),
            api_key=api_key,
            messages=[
                {"role": "system", "content": system_msg},
                {"role": "user", "content": user_msg},
            ],
            tools=None,
            temperature=0.7,
            max_tokens=256,
        )
    except Exception as exc:
        logger.warning("Alert reaction LLM call failed: %s", exc)
        return None

    reply = (result.get("content") or "").strip()
    if reply.lower() in _SILENCE_TOKENS:
        return None
    return reply


async def _get_alert_chat_id(pool: asyncpg.Pool) -> str | None:
    """Read channel.telegram.alert_chat_id config. Returns None if unset."""
    async with pool.acquire() as conn:
        val = await conn.fetchval(
            "SELECT get_config_text($1)", "channel.telegram.alert_chat_id"
        )
    return str(val).strip() if val else None
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest tests/services/test_alert_reaction.py -q`
Expected: PASS (5 passed)

- [ ] **Step 5: Commit**

```bash
git add services/alert_reaction.py tests/services/test_alert_reaction.py
git commit -m "feat(alerts): bounded persona reaction turn + alert-chat config reader"
```

---

## Task 3: Batched heartbeat scan

**Files:**
- Modify: `services/alert_reaction.py`
- Test: `tests/services/test_alert_reaction.py`

- [ ] **Step 1: Write the failing test**

Add a module-level marker at the top of `tests/services/test_alert_reaction.py` (just below the imports — the DB test needs the session loop scope; the pure/monkeypatched tests above are unaffected by it):

```python
pytestmark_db = pytest.mark.asyncio(loop_scope="session")
```

Then append this DB test:

```python
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
```

Add `import json` to the test file's imports if not already present.

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/services/test_alert_reaction.py -q -k react_to_pending`
Expected: FAIL — `AttributeError: module 'services.alert_reaction' has no attribute 'react_to_pending_alerts'`

- [ ] **Step 3: Write the implementation**

Append to `services/alert_reaction.py`:

```python
async def react_to_pending_alerts(
    pool: asyncpg.Pool,
    bridge: Any | None,
    *,
    limit: int = 10,
) -> int:
    """Heartbeat batch: react to unreacted alert memories from the last 24h.

    Called once per heartbeat. Picks up alert memories left unreacted by the
    webhook handler (normal-priority alerts), runs one reaction turn each,
    publishes any non-silent reaction, and marks every scanned memory reacted.

    Returns the number of memories processed.
    """
    alert_chat_id = await _get_alert_chat_id(pool)
    if not alert_chat_id:
        return 0

    async with pool.acquire() as conn:
        rows = await conn.fetch(
            """
            SELECT id, content, metadata->'context' AS context
            FROM memories
            WHERE metadata->'context'->>'kind' = 'alert'
              AND metadata->'context'->>'reacted' = 'false'
              AND created_at > CURRENT_TIMESTAMP - INTERVAL '24 hours'
            ORDER BY created_at
            LIMIT $1
            """,
            limit,
        )
    if not rows:
        return 0

    reacted_ids: list = []
    for row in rows:
        ctx = row["context"]
        if isinstance(ctx, str):
            try:
                ctx = json.loads(ctx)
            except Exception:
                ctx = {}
        ctx = ctx or {}
        alert_text = ctx.get("alert_text") or row["content"]
        title = ctx.get("title")
        comment = await generate_alert_reaction(
            pool, alert_text=alert_text, title=title
        )
        if comment and bridge:
            try:
                await bridge.publish_outbox_payloads(
                    [build_alert_outbox_message(comment, alert_chat_id)]
                )
            except Exception as exc:
                logger.warning("Failed to publish batched reaction: %s", exc)
        reacted_ids.append(row["id"])

    async with pool.acquire() as conn:
        await conn.execute(
            "UPDATE memories SET metadata = "
            "jsonb_set(metadata, '{context,reacted}', 'true') "
            "WHERE id = ANY($1::uuid[])",
            reacted_ids,
        )
    return len(reacted_ids)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/services/test_alert_reaction.py -q`
Expected: PASS (6 passed)

- [ ] **Step 5: Commit**

```bash
git add services/alert_reaction.py tests/services/test_alert_reaction.py
git commit -m "feat(alerts): batched heartbeat scan for unreacted alerts"
```

---

## Task 4: Alert webhook handler

**Files:**
- Modify: `services/worker_service.py` (`create_webhook_handler`, lines 578-619)
- Test: `tests/services/test_worker_webhook_alert.py` (new)

- [ ] **Step 1: Write the failing tests**

Create `tests/services/test_worker_webhook_alert.py`:

```python
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pytest tests/services/test_worker_webhook_alert.py -q`
Expected: FAIL — `AttributeError: module 'services.worker_service' has no attribute '_handle_alert_webhook'`

- [ ] **Step 3: Write the implementation**

In `services/worker_service.py`, add this import near the other `from services...` imports at the top of the file (around line 27-30):

```python
from services.alert_reaction import (
    build_alert_outbox_message,
    generate_alert_reaction,
    react_to_pending_alerts,
    _get_alert_chat_id,
)
```

Then replace the entire `create_webhook_handler` function (currently `services/worker_service.py:578-619`) with:

```python
async def _handle_alert_webhook(
    pool: asyncpg.Pool,
    bridge: RabbitMQBridge | None,
    event: GatewayEvent,
    payload: dict[str, Any],
) -> dict[str, Any]:
    """Handle a source=alert webhook: raw delivery, memory, tiered reaction.

    Raises ValueError (→ gateway marks the event failed) on a missing alert
    body or an unconfigured alert chat — both are surfaced, not silent.
    """
    text = str(payload.get("text") or "").strip()
    if not text:
        raise ValueError("alert webhook payload missing 'text'")

    priority = str(payload.get("priority") or "normal").lower()
    if priority not in ("high", "normal"):
        priority = "normal"
    title = payload.get("title")
    tags = payload.get("tags") if isinstance(payload.get("tags"), list) else []

    alert_chat_id = await _get_alert_chat_id(pool)
    if not alert_chat_id:
        raise ValueError("channel.telegram.alert_chat_id is not configured")

    # 1. Raw delivery — verbatim, no LLM. Runs first and unconditionally.
    if bridge:
        await bridge.publish_outbox_payloads(
            [build_alert_outbox_message(text, alert_chat_id)]
        )

    # 2. Memory. Importance keyed to priority. reacted=false for the heartbeat
    #    batch to find it (the high-priority branch flips it below).
    context = {
        "type": "alert",
        "kind": "alert",
        "source": "alert",
        "priority": priority,
        "title": title,
        "tags": tags,
        "alert_text": text,
        "reacted": False,
    }
    importance = 0.7 if priority == "high" else 0.4
    memory_id = None
    try:
        async with pool.acquire() as conn:
            memory_id = await conn.fetchval(
                """
                SELECT create_episodic_memory(
                    p_content := $1,
                    p_importance := $2,
                    p_emotional_valence := 0.0,
                    p_context := $3::jsonb,
                    p_source_attribution := $4::jsonb,
                    p_trust_level := 0.8
                )
                """,
                f"Alert ({priority}): {text}",
                importance,
                json.dumps(context),
                json.dumps({
                    "kind": "alert",
                    "ref": str(event.correlation_id),
                    "label": "webhook:alert",
                    "trust": 0.8,
                }),
            )
    except Exception as exc:
        logger.warning("Failed to record alert memory: %s", exc)

    # 3. Reaction routing.
    #    high  -> immediate: react now (skipped in ECO), mark reacted either way
    #             so the heartbeat never produces a stale late reaction.
    #    normal -> leave reacted=false; the heartbeat batch picks it up.
    reacted = False
    if priority == "high":
        reacted = True
        async with pool.acquire() as conn:
            eco = await _is_eco_mode(conn)
        if not eco:
            comment = await generate_alert_reaction(
                pool, alert_text=text, title=title
            )
            if comment and bridge:
                await bridge.publish_outbox_payloads(
                    [build_alert_outbox_message(comment, alert_chat_id)]
                )

    if reacted and memory_id:
        try:
            async with pool.acquire() as conn:
                await conn.execute(
                    "UPDATE memories SET metadata = "
                    "jsonb_set(metadata, '{context,reacted}', 'true') WHERE id = $1",
                    memory_id,
                )
        except Exception as exc:
            logger.warning("Failed to mark alert memory reacted: %s", exc)

    return {"source": "alert", "priority": priority,
            "delivered": True, "reacted": reacted}


def create_webhook_handler(*, pool: asyncpg.Pool, bridge: RabbitMQBridge | None = None):
    """Factory that returns a webhook event handler for the GatewayConsumer.

    source=alert events go through the full alert pipeline (raw delivery +
    memory + tiered reaction). Every other webhook source keeps the legacy
    behavior: recorded as an episodic memory so the agent is aware of it.
    """

    async def handle_webhook(event: GatewayEvent) -> dict[str, Any] | None:
        payload = event.payload
        source_name = event.session_key.removeprefix("webhook:")
        logger.info("Processing webhook event: %s (id=%d)", source_name, event.id)

        if source_name == "alert":
            return await _handle_alert_webhook(pool, bridge, event, payload)

        # Legacy path: record the webhook as an episodic memory.
        try:
            async with pool.acquire() as conn:
                summary = json.dumps(payload)[:500] if payload else "{}"
                await conn.fetchval(
                    """
                    SELECT create_episodic_memory(
                        p_content := $1,
                        p_importance := 0.4,
                        p_emotional_valence := 0.0,
                        p_context := $2::jsonb,
                        p_source_attribution := $3::jsonb,
                        p_trust_level := 0.7
                    )
                    """,
                    f"Received webhook from {source_name}: {summary}",
                    json.dumps({"type": "webhook", "source": source_name}),
                    json.dumps({
                        "kind": "webhook",
                        "ref": str(event.correlation_id),
                        "label": f"webhook:{source_name}",
                        "trust": 0.7,
                    }),
                )
        except Exception as exc:
            logger.warning("Failed to record webhook memory: %s", exc)

        return {"source": source_name, "recorded": True}

    return handle_webhook
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest tests/services/test_worker_webhook_alert.py -q`
Expected: PASS (4 passed)

- [ ] **Step 5: Commit**

```bash
git add services/worker_service.py tests/services/test_worker_webhook_alert.py
git commit -m "feat(alerts): alert-source webhook handler — raw delivery + tiered reaction"
```

---

## Task 5: Wire the bridge and the heartbeat batch call

**Files:**
- Modify: `services/worker_service.py` (`_amain` call site ~line 673; `handle_heartbeat` ~line 318)

- [ ] **Step 1: Pass the bridge into the webhook handler**

In `services/worker_service.py`, find the `_amain` call site (currently line 673):

```python
    consumer.register(EventSource.WEBHOOK, create_webhook_handler(pool=consumer_pool))
```

Replace it with:

```python
    consumer.register(
        EventSource.WEBHOOK,
        create_webhook_handler(pool=consumer_pool, bridge=bridge),
    )
```

- [ ] **Step 2: Add the batched scan to the heartbeat handler**

In `create_heartbeat_handler`'s `handle_heartbeat`, locate this block (currently lines 315-318):

```python
        # Publish outbox messages from initialization
        outbox_messages = payload.get("outbox_messages")
        if isinstance(outbox_messages, list):
            await _publish_outbox(outbox_messages)
```

Immediately after it, add:

```python
        # Batched alert reactions: comment on normal-priority alerts that
        # arrived since the last heartbeat. The heartbeat timer skips entirely
        # in ECO, so no explicit ECO guard is needed here.
        try:
            await react_to_pending_alerts(pool, bridge)
        except Exception as exc:
            logger.warning("Batched alert reaction failed: %s", exc)
```

- [ ] **Step 3: Verify no regression in the existing webhook + worker tests**

Run: `pytest tests/core/test_gateway.py tests/core/test_gateway_consumer.py tests/services -q`
Expected: PASS — all existing gateway/consumer tests plus the new alert tests pass.

- [ ] **Step 4: Verify the module imports cleanly**

Run: `python -c "import services.worker_service; print('ok')"`
Expected: prints `ok` with no ImportError (catches a broken import or a typo in the new wiring).

- [ ] **Step 5: Commit**

```bash
git add services/worker_service.py
git commit -m "feat(alerts): wire outbox bridge + batched reaction into worker"
```

---

## Task 6: Operator documentation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add the alert-webhook operator section**

In `README.md`, add a new section (place it after whatever section documents channels / messaging; if no obvious spot exists, add it before the final section). Insert exactly:

```markdown
## Consolidated Alerts via the Persona's Telegram Bot

A hexis persona can act as your consolidated Telegram alert bot. Point your
alert scripts at the persona's webhook instead of the Telegram API directly:

```bash
curl -X POST http://localhost:43817/api/webhook/alert \
  -H 'Content-Type: application/json' \
  -d '{"text": "BTC crossed 70k", "priority": "high", "title": "price-alert"}'
```

Payload fields:

- `text` (required) — the alert body. Delivered to your Telegram chat verbatim,
  no LLM in the path: numbers, tickers, and links are untouched.
- `priority` — `high` or `normal` (default `normal`). `high` → the persona
  reacts immediately (one short in-character remark, or silence). `normal` →
  the persona may comment on its next heartbeat, batched.
- `title`, `tags` — optional metadata stored on the alert memory.

Configure the destination chat once:

```sql
SELECT set_config('channel.telegram.alert_chat_id', '"<your-chat-id>"'::jsonb);
```

Every alert is also recorded as an episodic memory, so the persona can recall
and discuss it in chat.

**Scheduled rituals.** The persona already has the `manage_schedule` tool — ask
it in chat (e.g. "send me a 7am overnight digest") and it creates a recurring
scheduled task delivered to the alert chat. No extra setup.

In ECO power mode, raw alerts are still delivered; persona reactions are skipped.
```

- [ ] **Step 2: Verify the markdown renders**

Run: `python -c "import pathlib; t = pathlib.Path('README.md').read_text(encoding='utf-8'); assert '/api/webhook/alert' in t; print('ok')"`
Expected: prints `ok`

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs(alerts): operator guide for the alert webhook + scheduled rituals"
```

---

## Final verification

- [ ] **Run the full new test surface**

Run: `pytest tests/services/test_alert_reaction.py tests/services/test_worker_webhook_alert.py -q`
Expected: PASS (10 passed)

- [ ] **Run the gateway regression set**

Run: `pytest tests/core/test_gateway.py tests/core/test_gateway_consumer.py -q`
Expected: PASS (no regressions)

- [ ] **Manual smoke test (requires the stack up + a real Telegram bot token + `alert_chat_id` set)**

```bash
curl -X POST http://localhost:43817/api/webhook/alert \
  -H 'Content-Type: application/json' \
  -d '{"text": "smoke test alert", "priority": "normal"}'
```

Expected: `202 {"status":"accepted","event_id":N}`, and within a few seconds the
text `smoke test alert` appears verbatim in the configured Telegram chat.

---

## Notes for the implementer

- **Reply threading is intentionally not implemented.** The outbox does not
  surface the sent Telegram `message_id` back to the handler, so a reaction is
  a standalone follow-up message, not a threaded reply. This is a known,
  accepted limitation from the design — do not add a reply-threading path.
- **Silence is a first-class outcome.** `generate_alert_reaction` returning
  `None` (persona chose `[pass]`, or the LLM failed) is normal — never
  substitute a canned fallback reply for a reaction.
- **Do not touch `apps/hexis_api.py`.** The generic `POST /api/webhook/{source}`
  endpoint already accepts `source=alert`; routing happens entirely in the
  worker's handler.
- **`_is_eco_mode` and `_get_alert_chat_id` are underscore-prefixed but are
  imported across modules deliberately** — follow the existing pattern
  (`services.chat._load_persona_system_prompt` is already imported the same way).
```
