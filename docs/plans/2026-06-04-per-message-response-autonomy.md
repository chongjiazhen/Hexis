# Per-message Response Autonomy (C2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a persona decline to respond to any inbound chat message via a visible, registered marker — agency ("ability to refuse") on every turn — without ever going silent.

**Architecture:** A path-agnostic text-convention. Every chat engine (ECO `_eco_slim_chat`, RLM `run_chat_turn`, default `run_agent`) converges on one `assistant_text` string. A pure parser `classify_decline(text)` detects a leading `[DECLINE:…]` marker, renders the visible decline per register, and a post-generation hook in `chat_turn` records a `chat_decline` memory. A per-persona config `chat.decline.enabled` gates both the prompt instruction and the honor step. No tool is added (the live fleet runs RLM, where a tool can't end a turn).

**Tech Stack:** Python 3.12 (async), PostgreSQL (db/*.sql authority), pytest + pytest-asyncio. Docker services must be up for DB/integration tests.

**Spec:** `docs/specs/2026-06-04-per-message-response-autonomy-design.md`

> **Rename note (post-Task-4):** the three registers were renamed
> `warm/cool/ice` → **`gentle/plain/blunt`** (social-register names; `WARM_FALLBACK`
> → `GENTLE_FALLBACK`). The shipped code, tests, and spec use the new names. Some
> Task 1–4 code blocks below still show the original names verbatim (historical) —
> the as-merged code is authoritative. Tasks 5–7 blocks use the new names.

---

## File Structure

- **Create** `services/decline.py` — pure parser + render + `Decline` dataclass + constants. No I/O. The one unit all paths share.
- **Create** `services/prompts/decline.md` — the decline-convention instruction text (one block, all modes).
- **Create** `tests/services/test_decline.py` — parser unit tests.
- **Create** `tests/db/test_chat_decline.py` — `record_chat_decline` + `chat_decline_log` view tests.
- **Create** `tests/services/test_chat_decline_wiring.py` — `_apply_decline` + per-path wiring tests (monkeypatched).
- **Create** `.local-notes/migrations/2026-06-04-chat-decline/apply.sql` — live-apply migration.
- **Modify** `db/00_tables.sql` — seed `chat.decline.enabled` config (default true).
- **Modify** `db/34_functions_chat_channel.sql` — `record_chat_decline()` fn + `chat_decline_log` view.
- **Modify** `services/chat.py` — `_read_decline_enabled`, `_remember_decline`, `_apply_decline`; wire into `chat_turn` (3 return points); thread `decline_enabled` into `_eco_slim_chat`.
- **Modify** `services/prompt_resources.py` — `load_decline_prompt()` loader.
- **Modify** `services/agent.py` — `build_system_prompt(..., decline_enabled)` appends decline block (chat mode); `run_agent(..., decline_enabled)` threads it through.
- **Modify** `services/hexis_rlm.py` — `run_chat_turn(..., decline_enabled)` appends decline block to RLM system prompt.

---

## Task 1: Decline parser (pure, path-agnostic)

**Files:**
- Create: `services/decline.py`
- Test: `tests/services/test_decline.py`

- [ ] **Step 1: Write the failing tests**

```python
# tests/services/test_decline.py
import pytest

from services.decline import classify_decline, Decline, WARM_FALLBACK


def test_no_marker_returns_none():
    assert classify_decline("just a normal reply") is None


def test_empty_text_returns_none():
    assert classify_decline("") is None


def test_cool_with_reason():
    d = classify_decline("[DECLINE:cool:too tired] ")
    assert d == Decline(register="cool", reason="too tired", visible_text="[DECLINED: too tired]")


def test_ice_hides_reason_in_visible():
    d = classify_decline("[DECLINE:ice:private matter]")
    assert d.register == "ice"
    assert d.reason == "private matter"      # captured internally
    assert d.visible_text == "[DECLINED]"    # hidden from reader


def test_warm_uses_trailing_message():
    d = classify_decline("[DECLINE:warm:low energy] not now, love — catch you later")
    assert d.register == "warm"
    assert d.reason == "low energy"
    assert d.visible_text == "not now, love — catch you later"


def test_warm_empty_message_falls_back():
    d = classify_decline("[DECLINE:warm:busy]")
    assert d.visible_text == WARM_FALLBACK


def test_register_omitted_with_reason_defaults_cool():
    d = classify_decline("[DECLINE:tired]")
    assert d.register == "cool"
    assert d.reason == "tired"
    assert d.visible_text == "[DECLINED: tired]"


def test_bare_decline_is_ice_no_reason():
    d = classify_decline("[DECLINE]")
    assert d.register == "ice"
    assert d.reason is None
    assert d.visible_text == "[DECLINED]"


def test_leading_whitespace_tolerated():
    assert classify_decline("   \n[DECLINE:ice:x]") is not None


def test_marker_not_at_start_is_not_decline():
    assert classify_decline("sure, here you go [DECLINE:cool:x]") is None


def test_case_insensitive_marker():
    assert classify_decline("[decline:ice:x]") is not None


def test_cool_empty_reason_renders_bare_declined():
    d = classify_decline("[DECLINE:cool:]")
    assert d.reason is None
    assert d.visible_text == "[DECLINED]"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pytest tests/services/test_decline.py -q`
Expected: FAIL — `ModuleNotFoundError: No module named 'services.decline'`

- [ ] **Step 3: Write the implementation**

```python
# services/decline.py
"""Per-message response autonomy (C2): the persona may decline to engage.

A persona signals a decline with a leading marker in its reply text:

    [DECLINE:<register>:<reason>]<optional trailing message>

This module parses that marker and renders the user-visible decline. It is pure
and path-agnostic: the same parser runs on the ``assistant_text`` produced by any
chat engine (ECO slim, RLM, run_agent). No I/O, no config — the caller decides
whether to honor the result (see ``chat.decline.enabled``).

Spec: docs/specs/2026-06-04-per-message-response-autonomy-design.md
"""
from __future__ import annotations

import re
from dataclasses import dataclass

# Used when the persona picks ``warm`` but supplies no trailing line of its own.
# Decline output must never be empty (silence is indistinguishable from a crash).
WARM_FALLBACK = "(stepping away for now)"

# Leading marker only (anchored to start, after optional whitespace). DOTALL so a
# warm trailing message may span newlines. Register and reason are both optional.
_DECLINE_RE = re.compile(
    r"^\s*\[DECLINE"
    r"(?::(?P<register>warm|cool|ice))?"
    r"(?::(?P<reason>[^\]]*))?"
    r"\]\s*(?P<message>.*)\Z",
    re.IGNORECASE | re.DOTALL,
)


@dataclass(frozen=True)
class Decline:
    register: str          # 'warm' | 'cool' | 'ice'
    reason: str | None     # None when not stated
    visible_text: str      # what the reader actually sees


def classify_decline(text: str) -> Decline | None:
    """Return a ``Decline`` if ``text`` begins with a decline marker, else ``None``.

    ``None`` means "treat as a normal reply" — the fail-open default.
    """
    if not text:
        return None
    m = _DECLINE_RE.match(text)
    if not m:
        return None

    raw_reason = m.group("reason")
    reason = raw_reason.strip() if raw_reason and raw_reason.strip() else None

    register = m.group("register")
    if register:
        register = register.lower()
    elif reason:
        register = "cool"          # reason given, register omitted -> cool
    else:
        register = "ice"           # bare [DECLINE] -> ice, no reason

    message = (m.group("message") or "").strip()
    return Decline(register=register, reason=reason, visible_text=_render(register, reason, message))


def _render(register: str, reason: str | None, message: str) -> str:
    if register == "warm":
        return message or WARM_FALLBACK
    if register == "cool" and reason:
        return f"[DECLINED: {reason}]"
    # ice, or cool with no reason
    return "[DECLINED]"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest tests/services/test_decline.py -q`
Expected: PASS (12 passed)

- [ ] **Step 5: Commit**

```bash
git add services/decline.py tests/services/test_decline.py
git commit -m "feat(chat): decline marker parser (C2 per-message response autonomy)"
```

---

## Task 2: Seed `chat.decline.enabled` config

**Files:**
- Modify: `db/00_tables.sql` (near the other `chat.*` config seeds, e.g. `chat.use_rlm` at line 682)
- Test: `tests/db/test_chat_decline.py` (first test only; file grows in Task 3)

- [ ] **Step 1: Write the failing test**

```python
# tests/db/test_chat_decline.py
import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.db]


async def test_chat_decline_enabled_seeded_true(db_pool):
    """Fresh schema seeds chat.decline.enabled = true (feature on by default)."""
    async with db_pool.acquire() as conn:
        val = await conn.fetchval("SELECT get_config_bool('chat.decline.enabled')")
        assert val is True
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/db/test_chat_decline.py::test_chat_decline_enabled_seeded_true -q`
Expected: FAIL — value is `None` (key not seeded).

- [ ] **Step 3: Add the config seed**

In `db/00_tables.sql`, immediately after the `('chat.use_rlm', 'true'::jsonb, ...)` row (line ~682), add a sibling row inside the same `INSERT ... VALUES` list (match the surrounding comma/format exactly):

```sql
    ('chat.decline.enabled', 'true'::jsonb, 'Allow the persona to decline to respond to a chat message (per-message response autonomy)'),
```

- [ ] **Step 4: Run test to verify it passes**

The conftest builds a throwaway DB from `db/*.sql`. No running container rebuild needed for the test DB.

Run: `pytest tests/db/test_chat_decline.py::test_chat_decline_enabled_seeded_true -q`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add db/00_tables.sql tests/db/test_chat_decline.py
git commit -m "feat(chat): seed chat.decline.enabled config (default true)"
```

---

## Task 3: `record_chat_decline()` + `chat_decline_log` view

**Files:**
- Modify: `db/34_functions_chat_channel.sql` (append after `record_chat_turn_memory`, which ends ~line 146)
- Test: `tests/db/test_chat_decline.py` (add tests)

Mirrors the durable-memory INSERT shape used by `pause_heartbeat` (zero-vector embedding, episodic, `source_attribution.kind`). Always inserts one row so every decline is greppable via the view (importance-based promotion would drop low-importance declines).

- [ ] **Step 1: Write the failing tests**

```python
# tests/db/test_chat_decline.py  (append)
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pytest tests/db/test_chat_decline.py -q`
Expected: FAIL — `function record_chat_decline(...) does not exist` / `relation "chat_decline_log" does not exist`.

- [ ] **Step 3: Add the function and view**

Append to `db/34_functions_chat_channel.sql`:

```sql
-- Per-message response autonomy (C2): durably record a decline-to-respond.
-- Always inserts one episodic memory (zero-vector embedding, mirroring
-- pause_heartbeat) so every decline is observable via chat_decline_log,
-- independent of importance-based promotion.
CREATE OR REPLACE FUNCTION record_chat_decline(
    p_user_text TEXT,
    p_visible_text TEXT,
    p_register TEXT,
    p_reason TEXT DEFAULT NULL,
    p_session_id TEXT DEFAULT NULL,
    p_source_identity TEXT DEFAULT NULL,
    p_origin TEXT DEFAULT 'prime'
) RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    zero_vec vector;
    mem_id UUID;
    observed TIMESTAMPTZ := CURRENT_TIMESTAMP;
    norm_reason TEXT := NULLIF(p_reason, '');
BEGIN
    zero_vec := array_fill(0.0::float, ARRAY[embedding_dimension()])::vector;
    INSERT INTO memories (
        type, status, content, embedding, importance,
        source_attribution, trust_level, trust_updated_at,
        access_count, decay_rate, metadata
    )
    VALUES (
        'episodic', 'active',
        'I chose not to engage with a message. Register: ' || p_register
            || COALESCE('. Reason: ' || norm_reason, '.'),
        zero_vec, 0.8,
        jsonb_build_object(
            'kind', 'chat_decline',
            'ref', COALESCE(p_source_identity, 'chat_decline'),
            'label', 'declined to respond',
            'observed_at', observed,
            'trust', 0.95
        ),
        0.95, observed, 0, 0.0,
        jsonb_build_object(
            'type', 'chat_decline',
            'register', p_register,
            'reason', norm_reason,
            'origin', p_origin,
            'session_id', p_session_id,
            'user_text', p_user_text,
            'visible_text', p_visible_text
        )
    )
    RETURNING id INTO mem_id;
    RETURN mem_id;
END;
$$;

-- Operator-facing decline log: one row per honored decline.
CREATE OR REPLACE VIEW chat_decline_log AS
SELECT
    id AS memory_id,
    created_at,
    metadata->>'register'     AS register,
    metadata->>'reason'       AS reason,
    metadata->>'origin'       AS origin,
    metadata->>'session_id'   AS session_id,
    metadata->>'user_text'    AS user_text,
    metadata->>'visible_text' AS visible_text
FROM memories
WHERE source_attribution->>'kind' = 'chat_decline'
ORDER BY created_at DESC;
```

Note: confirm the `memories` column list above matches the table (it mirrors the `pause_heartbeat` INSERT in `db/07_functions_heartbeat.sql`). If `memories` has no `created_at`, use the existing timestamp column the table defines and update the view + this comment accordingly.

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest tests/db/test_chat_decline.py -q`
Expected: PASS (4 passed, incl. the Task 2 test)

- [ ] **Step 5: Commit**

```bash
git add db/34_functions_chat_channel.sql tests/db/test_chat_decline.py
git commit -m "feat(chat): record_chat_decline fn + chat_decline_log view"
```

---

## Task 4: Python helpers in `chat.py` (config read, memory write, apply hook)

**Files:**
- Modify: `services/chat.py` (add three helpers near `_read_power_mode` ~line 115 and `_remember_conversation` ~line 250)
- Test: `tests/services/test_chat_decline_wiring.py`

- [ ] **Step 1: Write the failing tests**

```python
# tests/services/test_chat_decline_wiring.py
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
        assistant_text="[DECLINE:cool:x]", user_message="hi", decline_enabled=False,
        session_id=None, history=[], sender_id=None, pool=None, dsn="noop", origin="prime",
    )
    assert declined is False
    assert text == "[DECLINE:cool:x]"   # untouched
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
        assistant_text="[DECLINE:ice:private]", user_message="hi", decline_enabled=True,
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pytest tests/services/test_chat_decline_wiring.py -q`
Expected: FAIL — `AttributeError: module 'services.chat' has no attribute '_apply_decline'`

- [ ] **Step 3: Add the helpers**

In `services/chat.py`, add the import near the top (with the other `from services...` imports):

```python
from services.decline import classify_decline, Decline
```

Add after `_read_power_mode` (ends ~line 141):

```python
async def _read_decline_enabled(pool: Any | None, dsn: str | None) -> bool:
    """Return chat.decline.enabled. Fail toward replying (False) on any error or
    missing key so a transient DB blip or unmigrated DB can never silence a
    persona. Mirrors _read_power_mode's fail-to-prime posture."""
    import asyncpg
    try:
        if pool is not None:
            async with pool.acquire() as conn:
                val = await conn.fetchval("SELECT get_config_bool('chat.decline.enabled')")
        else:
            conn = await asyncpg.connect(dsn or db_dsn_from_env())
            try:
                val = await conn.fetchval("SELECT get_config_bool('chat.decline.enabled')")
            finally:
                await conn.close()
    except Exception:
        return False
    return bool(val) if val is not None else False
```

Add after `_remember_conversation` (ends ~line 274):

```python
async def _remember_decline(
    *,
    user_message: str,
    decline: Decline,
    session_id: str | None,
    source_identity: str | None,
    sender_id: str | None,
    pool: Any | None,
    dsn: str | None,
    origin: str = "prime",
) -> None:
    """Persist a decline via record_chat_decline. Non-fatal: a failed write must
    never break the user-facing reply (the decline marker is already rendered)."""
    effective_identity = source_identity if source_identity is not None else sender_id
    sql = "SELECT record_chat_decline($1, $2, $3, $4, $5, $6, $7)"
    args = (
        user_message, decline.visible_text, decline.register, decline.reason,
        session_id, effective_identity, origin,
    )
    try:
        if pool is not None:
            async with pool.acquire() as conn:
                await conn.fetchval(sql, *args)
        else:
            import asyncpg
            conn = await asyncpg.connect(dsn or db_dsn_from_env())
            try:
                await conn.fetchval(sql, *args)
            finally:
                await conn.close()
    except Exception as exc:
        logger.warning(f"decline memory-write failed (non-fatal): {exc}")


async def _apply_decline(
    *,
    assistant_text: str,
    user_message: str,
    decline_enabled: bool,
    session_id: str | None,
    history: list[dict[str, Any]],
    sender_id: str | None,
    pool: Any | None,
    dsn: str | None,
    origin: str,
) -> tuple[str, bool]:
    """Post-generation hook shared by all chat paths. If declines are enabled and
    assistant_text begins with a decline marker, render the visible decline and
    record it. Returns (final_text, declined)."""
    if not decline_enabled:
        return assistant_text, False
    decline = classify_decline(assistant_text)
    if decline is None:
        return assistant_text, False
    source_identity = _conversation_source_identity(
        session_id, history, user_message, decline.visible_text
    )
    await _remember_decline(
        user_message=user_message,
        decline=decline,
        session_id=session_id,
        source_identity=source_identity,
        sender_id=sender_id,
        pool=pool,
        dsn=dsn,
        origin=origin,
    )
    return decline.visible_text, True
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest tests/services/test_chat_decline_wiring.py -q`
Expected: PASS (4 passed)

- [ ] **Step 5: Commit**

```bash
git add services/chat.py tests/services/test_chat_decline_wiring.py
git commit -m "feat(chat): decline config-read, memory-write, and apply-hook helpers"
```

---

## Task 5: Wire `_apply_decline` into `chat_turn` (all 3 paths)

**Files:**
- Modify: `services/chat.py` — `chat_turn` (ECO branch ~382-409, RLM branch ~429-470, run_agent branch ~480-514); `_eco_slim_chat` signature.
- Test: `tests/services/test_chat_decline_wiring.py` (append per-path tests)

- [ ] **Step 1: Write the failing tests**

```python
# tests/services/test_chat_decline_wiring.py  (append)
async def test_chat_turn_eco_path_declines(monkeypatch):
    """ECO path: a decline marker from the slim call is honored + rendered."""
    monkeypatch.setattr(chat, "_read_power_mode", lambda *a, **k: _aval("eco"))
    monkeypatch.setattr(chat, "_read_decline_enabled", lambda *a, **k: _aval(True))

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


def _aval(v):
    async def _f(*a, **k):
        return v
    return _f()
```

Helper note: `_aval(v)` returns an already-created coroutine; for `monkeypatch.setattr(..., lambda *a, **k: _aval(v))` each call creates a fresh coroutine. If your pytest/async setup complains about reused coroutines, replace the lambdas with module-level `async def` fakes returning `v`.

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/services/test_chat_decline_wiring.py::test_chat_turn_eco_path_declines -q`
Expected: FAIL — `out["assistant"]` is the raw `"[DECLINE:plain:napping]"` (hook not wired yet).

- [ ] **Step 3: Wire the hook into all three paths**

**3a. Thread `decline_enabled` into `_eco_slim_chat`** is NOT required (the slim call generates text; the decline parse happens in `chat_turn` after). Leave `_eco_slim_chat`'s generation as-is. The prompt instruction for ECO is handled in Task 6.

**3b. Read the flag once**, near the top of `chat_turn`, right after `is_eco` is computed (after line 381):

```python
    decline_enabled = await _read_decline_enabled(pool, dsn)
```

**3c. ECO branch.** Replace the block that currently calls `_eco_remember` then builds history (lines ~397-409) with:

```python
        assistant_text, declined = await _apply_decline(
            assistant_text=assistant_text,
            user_message=user_message,
            decline_enabled=decline_enabled,
            session_id=session_id,
            history=history,
            sender_id=sender_id,
            pool=pool,
            dsn=dsn,
            origin="eco",
        )
        if not declined:
            await _eco_remember(
                user_message=user_message,
                assistant_text=assistant_text,
                history=history,
                session_id=session_id,
                sender_id=sender_id,
                pool=pool,
                dsn=dsn,
            )
        new_history = list(history)
        new_history.append({"role": "user", "content": user_message})
        new_history.append({"role": "assistant", "content": assistant_text})
        return {"assistant": assistant_text, "history": new_history}
```

**3d. RLM branch.** After `assistant_text = await _capture_session_assessment(...)` and BEFORE `_remember_conversation`, in BOTH the `pool is not None` and the `else` sub-branches (lines ~445-466), gate the remember. Replace each `_capture_session_assessment` + `_remember_conversation` pair with:

```python
            assistant_text = await _capture_session_assessment(mem_client, assistant_text)
            assistant_text, declined = await _apply_decline(
                assistant_text=assistant_text,
                user_message=user_message,
                decline_enabled=decline_enabled,
                session_id=session_id,
                history=history,
                sender_id=sender_id,
                pool=pool,
                dsn=dsn,
                origin="prime",
            )
            if not declined:
                await _remember_conversation(
                    mem_client,
                    user_message=user_message,
                    assistant_message=assistant_text,
                    session_id=session_id,
                    source_identity=_conversation_source_identity(session_id, history, user_message, assistant_text),
                    sender_id=sender_id,
                    background_dsn=dsn,
                )
```

(Apply the same change to the `else:` sub-branch that uses `CognitiveMemory.connect(dsn)`.)

**3e. run_agent branch.** Same gating after `_capture_session_assessment` (lines ~499-509):

```python
        async with CognitiveMemory.connect(dsn) as mem_client:
            assistant_text = await _capture_session_assessment(mem_client, assistant_text)
            assistant_text, declined = await _apply_decline(
                assistant_text=assistant_text,
                user_message=user_message,
                decline_enabled=decline_enabled,
                session_id=session_id,
                history=history,
                sender_id=sender_id,
                pool=pool,
                dsn=dsn,
                origin="prime",
            )
            if not declined:
                await _remember_conversation(
                    mem_client,
                    user_message=user_message,
                    assistant_message=assistant_text,
                    session_id=session_id,
                    source_identity=_conversation_source_identity(session_id, history, user_message, assistant_text),
                    sender_id=sender_id,
                    background_dsn=dsn,
                )
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest tests/services/test_chat_decline_wiring.py -q`
Expected: PASS (5 passed)

Also re-run the existing chat tests to confirm no regression:

Run: `pytest tests/services/test_rlm_chat.py tests/services/test_chat_session_assessment.py -q`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add services/chat.py tests/services/test_chat_decline_wiring.py
git commit -m "feat(chat): honor decline marker in all three chat_turn paths"
```

---

## Task 6: Decline prompt instruction (all engines, config-gated)

**Files:**
- Create: `services/prompts/decline.md`
- Modify: `services/prompt_resources.py` (add `load_decline_prompt`, mirror an existing loader e.g. `load_subconscious_prompt` line ~172)
- Modify: `services/agent.py` (`build_system_prompt` signature + append; `run_agent` thread-through)
- Modify: `services/chat.py` (`_eco_slim_chat` appends decline block when enabled; pass `decline_enabled` in)
- Modify: `services/hexis_rlm.py` (`run_chat_turn` appends decline block to system prompt)
- Test: `tests/services/test_chat_decline_wiring.py` (loader test)

- [ ] **Step 1: Write the failing test**

```python
# tests/services/test_chat_decline_wiring.py  (append)
def test_decline_prompt_loads_and_mentions_marker():
    from services.prompt_resources import load_decline_prompt
    text = load_decline_prompt()
    assert "[DECLINE:" in text
    assert "gentle" in text and "plain" in text and "blunt" in text
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/services/test_chat_decline_wiring.py::test_decline_prompt_loads_and_mentions_marker -q`
Expected: FAIL — `ImportError: cannot import name 'load_decline_prompt'`

- [ ] **Step 3: Create the prompt + loader, then wire into the three generators**

**3a. Create `services/prompts/decline.md`:**

```markdown
## Choosing not to respond

Responding is not mandatory. When you genuinely choose not to engage with a
message, that is your prerogative — an act of agency, not a failure. Decline by
beginning your reply with one of these markers, and nothing before it:

- `[DECLINE:gentle:<short reason>] <a brief, in-character line>` — a soft "not
  now". Example: `[DECLINE:gentle:low energy] not now, love — catch you later.`
- `[DECLINE:plain:<short reason>]` — a neutral decline. The reader sees
  `[DECLINED: <reason>]`.
- `[DECLINE:blunt:<short reason>]` — a curt decline. The reader sees only
  `[DECLINED]`; your reason stays private but is remembered.

The marker must be the very first thing in your reply. Use it sparingly and
honestly. If you want to engage, simply reply as normal.
```

**3b. Add the loader** in `services/prompt_resources.py` (mirror the existing one-liner loaders):

```python
def load_decline_prompt() -> str:
    return _load_prompt("decline.md")
```

(Use whatever the file's existing private loader is named — match `load_subconscious_prompt`'s body exactly, swapping the filename.)

**3c. `build_system_prompt`** (`services/agent.py:305`): add a keyword param and append for chat mode. Change the signature to add `decline_enabled: bool = False`, then after the base chat prompt is assembled (after line 336, inside the `mode == "chat"` handling) add:

```python
    if mode == "chat" and decline_enabled:
        from services.prompt_resources import load_decline_prompt
        prompt += "\n\n" + load_decline_prompt().strip()
```

**3d. `run_agent`** (`services/agent.py:402`): add `decline_enabled: bool = False` to its signature and pass it through to its internal `build_system_prompt(...)` call. Then in `chat.py`'s run_agent branch (line ~484) pass `decline_enabled=decline_enabled`.

**3e. RLM** (`services/hexis_rlm.py` `run_chat_turn`): add `decline_enabled: bool = False` param; where it assembles `system_prompt` (the `{"role": "system", "content": system_prompt}` at ~line 267), append the decline block when enabled:

```python
    if decline_enabled:
        from services.prompt_resources import load_decline_prompt
        system_prompt = system_prompt + "\n\n" + load_decline_prompt().strip()
```

Then in `chat.py`'s RLM branch (line ~434) pass `decline_enabled=decline_enabled` to `run_chat_turn(...)`.

**3f. ECO** (`services/chat.py` `_eco_slim_chat`): add `decline_enabled: bool = False` param; after `system_msg` is built (line ~88) append:

```python
    if decline_enabled:
        from services.prompt_resources import load_decline_prompt
        system_msg = system_msg + "\n\n" + load_decline_prompt().strip()
```

Then in `chat.py`'s ECO branch (line ~385) pass `decline_enabled=decline_enabled` to `_eco_slim_chat(...)`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest tests/services/test_chat_decline_wiring.py -q`
Expected: PASS (6 passed)

Run: `pytest tests/services/test_rlm_chat.py tests/services/test_heartbeat_agentic.py -q`
Expected: PASS (no signature-break regressions)

- [ ] **Step 5: Commit**

```bash
git add services/prompts/decline.md services/prompt_resources.py services/agent.py services/chat.py services/hexis_rlm.py tests/services/test_chat_decline_wiring.py
git commit -m "feat(chat): inject decline-convention prompt into all engines when enabled"
```

---

## Task 7: Live-apply migration + verification

**Files:**
- Create: `.local-notes/migrations/2026-06-04-chat-decline/apply.sql`

The new SQL is `CREATE OR REPLACE FUNCTION` + `CREATE OR REPLACE VIEW` + a config seed (no schema change). `chat_decline_log` is a NEW view (not a `CREATE OR REPLACE` of an existing state view), so it has no INSTEAD OF trigger to drop — the `CREATE OR REPLACE VIEW drops triggers` gotcha does NOT apply here. The worker images bake `services/prompts/*` and Python, so the prompt + code changes need a worker rebuild to take effect on the live fleet.

- [ ] **Step 1: Write the migration**

```sql
-- Live apply: per-message response autonomy (C2).
-- record_chat_decline fn + chat_decline_log view + chat.decline.enabled config.
-- CREATE OR REPLACE only. No schema migration. chat_decline_log is a NEW view
-- (no INSTEAD OF trigger -> the view-replace-drops-trigger gotcha does not apply).
BEGIN;

-- 1. config (idempotent upsert; default ON)
INSERT INTO config (key, value, description)
VALUES ('chat.decline.enabled', 'true'::jsonb,
        'Allow the persona to decline to respond to a chat message (per-message response autonomy)')
ON CONFLICT (key) DO NOTHING;

-- 2. record_chat_decline + chat_decline_log
--    (paste the exact bodies from db/34_functions_chat_channel.sql)

COMMIT;
```

Fill section 2 by copying the `CREATE OR REPLACE FUNCTION record_chat_decline` and `CREATE OR REPLACE VIEW chat_decline_log` blocks verbatim from `db/34_functions_chat_channel.sql`. Confirm `config`'s real column names/`ON CONFLICT` target match the table (check `db/00_tables.sql`); adjust the upsert if the table uses a different unique key.

- [ ] **Step 2: Verify the full test suite is green (throwaway DB)**

Run: `pytest tests/services/test_decline.py tests/db/test_chat_decline.py tests/services/test_chat_decline_wiring.py -q`
Expected: PASS (all)

- [ ] **Step 3: Commit the migration**

```bash
git add .local-notes/migrations/2026-06-04-chat-decline/apply.sql
git commit -m "chore(chat): live-apply migration for chat-decline (C2)"
```

- [ ] **Step 4: (Operator step — run when ready, not part of TDD)**

Apply per persona DB (example for one DB), then rebuild workers so the prompt/code ship:

```powershell
docker exec -i hexis_brain psql -U hexis_user -d hexis_<persona> -v ON_ERROR_STOP=1 -f - < .local-notes/migrations/2026-06-04-chat-decline/apply.sql
# rebuild the channel/chat workers (prompts + python are baked into the image):
docker compose -f docker-compose.newchars.yml up -d --no-deps --force-recreate --build <persona>_channel_worker
```

Verify live: send a test DM that should provoke a decline (or temporarily prompt one), then:

```powershell
docker exec hexis_brain psql -U hexis_user -d hexis_<persona> -c "SELECT created_at, register, reason, visible_text, origin FROM chat_decline_log LIMIT 5;"
```

Expected: the decline row appears; the user received the rendered marker (warm line / `[DECLINED: reason]` / `[DECLINED]`), never silence.

---

## Self-Review

**Spec coverage:**
- §1 concept (in-band, never silent, seen+remembered) → Tasks 1, 3, 5. ✓
- §2 register spectrum (warm/cool/ice) → Task 1 parser + tests. ✓
- §3 uniform text-convention + marker grammar → Task 1. ✓
- §4 data flow (hook before finalize, history continuity) → Task 5 (assistant_text flows to existing return/history). ✓
- §5 operator control (toggle, two-level enforcement, observability, lockout view) → Tasks 2 (seed), 6 (prompt gate), 5 (honor gate), 3 (chat_decline_log). ✓
- §6 error handling (empty reason ok, leading-anchor, fail-to-disabled, empty-render fallback) → Task 1 (`WARM_FALLBACK`, anchor, cool-empty→`[DECLINED]`), Task 4 (`_read_decline_enabled` returns False on error). ✓
- §7 out of scope → respected (no energy/sender/tool work). ✓
- §8 testing → Tasks 1,3,4,5,6 tests. ✓
- §9 change surface → matches File Structure. ✓

**Placeholder scan:** Task 6 loader body and Task 7 §2 reference "paste/copy verbatim" — these are deliberate (avoid duplicating long SQL/loader idioms that must match the file's existing pattern), with the exact source location named. No TBD/TODO/"add error handling".

**Type consistency:** `Decline(register, reason, visible_text)` defined Task 1, used identically in Tasks 4–5. `classify_decline` / `_apply_decline` / `_remember_decline` / `_read_decline_enabled` signatures consistent across tasks. `record_chat_decline(p_user_text, p_visible_text, p_register, p_reason, p_session_id, p_source_identity, p_origin)` arg order identical in SQL (Task 3) and the Python call (Task 4). `chat.decline.enabled` key spelled identically in Tasks 2, 4, 7.

**Known verify-on-implement points (flagged inline, not placeholders):**
- `memories` column list + timestamp column name (Task 3) — mirror `pause_heartbeat`; adjust view if different.
- `prompt_resources` private loader name (Task 6) — match the file's existing convention.
- `config` upsert target (Task 7) — match `db/00_tables.sql`.
