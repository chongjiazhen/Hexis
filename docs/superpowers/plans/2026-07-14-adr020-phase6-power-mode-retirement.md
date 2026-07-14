# ADR-020 Phase 6 — `agent.power_mode` Retirement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete the `agent.power_mode` DB flag from hexis by first re-homing `services/chat.py`'s ECO decision onto the live `:8090` serving-capability signal that `services/worker_service.py` already uses.

**Architecture:** Extract the existing capability probe (`worker_service._on_cpu_floor`) into a new dependency-light module `core/serving.py`. Both `worker_service.py` and `chat.py` consume it. `chat.py`'s `_read_power_mode` is deleted; its two branch points (`chat_turn`, `stream_chat_turn`) switch to `await on_cpu_floor()`. The slim-chat branch itself and its `metadata.origin='eco'` data contract are preserved exactly. Then, and only then, the config row is removed (migration `0009` + seed deletion).

**Tech Stack:** Python 3.11+, asyncpg, httpx, pytest + pytest-asyncio, PostgreSQL, raw-SQL numbered migrations (`db/migrations/`).

**Spec:** `docs/superpowers/specs/2026-07-14-adr020-phase6-power-mode-retirement-design.md`

## Global Constraints

- **Behavior is preserved, not redesigned.** The slim path (`_eco_slim_chat`), the fallback (`ECO_FALLBACK_REPLY`), the decline wiring (`_apply_decline(..., origin="eco")`), and the persisted `metadata.origin='eco'` tag must all behave identically after this plan. Only the *trigger* changes.
- **Fail-open direction is load-bearing.** Probe error / router down / non-200 → `False` → the heavy path. This mirrors `_read_power_mode`'s old fail-to-`'prime'` posture. A router blip must never silence or degrade a persona differently than today.
- **The floor is detected by PORT, not by the router's label.** `HEXIS_CPU_FLOOR_PORT` (default `8082`), never the `prime`/`eco` string in `/health` — the labels get renamed to `gpu`/`cpu` in ADR-020 phase 4 and this code must survive that untouched.
- **Do not rename `_eco_slim_chat`, `_eco_remember`, `ECO_SLIM_ANCHOR`, `ECO_FALLBACK_REPLY`, or the `origin='eco'` metadata value.** `origin='eco'` is a persisted data contract; rows already carry it.
- **Dual-write rule** (`core/schema.py:151-157`): every schema/seed change goes to BOTH `db/*.sql` (fresh bootstraps) AND `db/migrations/` (existing DBs).
- **Do NOT run migration 0009 against live instance DBs.** `schema_migrations` is per-database. Fleet-wide cleanup means enumerating `~/.hexis/instances.json` and applying per DB — that is an operator step, explicitly out of scope for the implementer.
- **Commits:** hexis convention `type(scope): description`, imperative, no `Co-Authored-By` trailer. Append a literal `Assisted by AI.` line (no colon — it must not be a git trailer). Never merge or push to `main` (upstream mirror); all work stays on `home-rig-local`.
- **Run tests with Docker services up** (`docker compose up -d`) — the suite has integration tests. The tests in this plan are all pure-unit (mock-driven) and do not need the DB, but the full-suite gate at the end does.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `core/serving.py` | Live serving-capability probe. `os` + `httpx` only; no DB, no rabbit. | **Create** |
| `tests/core/test_serving.py` | Unit tests for the probe (5 cases). | **Create** |
| `services/worker_service.py` | Heartbeat/maintenance worker. Its `_fetch_router_health` / `_on_cpu_floor` become aliases of `core.serving`. | Modify (`:268-300`) |
| `tests/services/test_capability_guard.py` | Reduced to a wiring assertion; logic tests move to `tests/core/test_serving.py`. | Modify |
| `services/chat.py` | Chat paths. Delete `_read_power_mode`; branch on `on_cpu_floor()`. | Modify (`:120-146`, `:473-481`, `:692-699`) |
| `tests/services/test_chat_cpu_floor.py` | **The acceptance gate**: slim path fires on the live CPU floor; heavy path on GPU. | **Create** |
| `tests/core/test_chat.py` | Existing eco-memory-tagging tests; mocks swapped. | Modify (`:112-119`, `:143-151`, `:172-180`) |
| `tests/services/test_chat_decline_wiring.py` | Existing decline tests; mocks swapped. | Modify (`:65-67`, `:97-99`) |
| `tests/services/test_chat_session_assessment.py` | Existing prime-path test; mock swapped. | Modify (`:95-96`, `:116`) |
| `db/migrations/0009_agent_power_mode_cleanup.sql` | DELETE the stale config row from existing DBs. | **Create** |
| `db/00_tables.sql` | Seed rows. Drop the `agent.power_mode` seed. | Modify (`:667`) |
| `.local-notes/guidelines/model-serving.md` | Serving runbook. Its "Power mode behavior" section documents a flag and scripts that no longer exist. | Modify |

Four commits, one per task.

---

### Task 1: Extract the capability probe into `core/serving.py`

The probe currently lives in `services/worker_service.py`. `chat.py` cannot import it from there — `worker_service` pulls in `RabbitMQBridge`, `Gateway`, `dotenv`, and `argparse`, and `chat.py` is imported by the CLI, the API server, and every channel adapter. Move the logic to a leaf module both can depend on.

**Files:**
- Create: `core/serving.py`
- Create: `tests/core/test_serving.py`
- Modify: `services/worker_service.py:268-300`
- Modify: `tests/services/test_capability_guard.py`

**Interfaces:**
- Consumes: nothing (leaf module).
- Produces:
  - `core.serving.fetch_router_health(url: str, timeout: float = 2.0) -> dict | None`
  - `core.serving.on_cpu_floor() -> bool` — Task 2 and `worker_service` both call this.
  - `services.worker_service._on_cpu_floor` remains a valid name (alias), so the worker's four existing call sites need no edit.

- [ ] **Step 1: Write the failing tests**

Create `tests/core/test_serving.py`:

```python
"""Capability guard (ADR-020 §2): is the live :8090 backend the CPU floor (1B)?

Port-based so it survives the phase-4 router label rename (prime/eco -> gpu/cpu);
the nano floor is :8082 by ADR-017/018 contract regardless of label. Fails OPEN
(False = proceed) on any error — a router blip must never silently degrade a path.
"""
import pytest

from core import serving


@pytest.mark.asyncio
async def test_cpu_floor_when_upstream_is_nano_port(monkeypatch):
    async def fake_health(url, timeout=2.0):
        return {"status": "ok", "upstream": "http://127.0.0.1:8082", "model": "qwen3-0.6b"}
    monkeypatch.setattr(serving, "fetch_router_health", fake_health)
    assert await serving.on_cpu_floor() is True


@pytest.mark.asyncio
async def test_not_cpu_floor_when_upstream_is_gpu_port(monkeypatch):
    async def fake_health(url, timeout=2.0):
        return {"status": "ok", "upstream": "http://127.0.0.1:8080", "model": "qwen36-35b"}
    monkeypatch.setattr(serving, "fetch_router_health", fake_health)
    assert await serving.on_cpu_floor() is False


@pytest.mark.asyncio
async def test_fails_open_when_router_unreachable(monkeypatch):
    # unreachable / no_upstream (503) -> None -> proceed (False), never silence.
    async def fake_health(url, timeout=2.0):
        return None
    monkeypatch.setattr(serving, "fetch_router_health", fake_health)
    assert await serving.on_cpu_floor() is False


@pytest.mark.asyncio
async def test_trailing_slash_tolerated(monkeypatch):
    async def fake_health(url, timeout=2.0):
        return {"upstream": "http://127.0.0.1:8082/"}
    monkeypatch.setattr(serving, "fetch_router_health", fake_health)
    assert await serving.on_cpu_floor() is True


@pytest.mark.asyncio
async def test_floor_port_env_override(monkeypatch):
    monkeypatch.setenv("HEXIS_CPU_FLOOR_PORT", "9999")
    async def fake_health(url, timeout=2.0):
        return {"upstream": "http://127.0.0.1:9999"}
    monkeypatch.setattr(serving, "fetch_router_health", fake_health)
    assert await serving.on_cpu_floor() is True
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pytest tests/core/test_serving.py -q`
Expected: collection error — `ImportError: cannot import name 'serving' from 'core'`.

- [ ] **Step 3: Write the implementation**

Create `core/serving.py`:

```python
"""Live serving-capability probe (ADR-020 §2).

The :8090 inference router (llm-serve, ADR-019) fails over between the GPU
backend (:8080) and the CPU floor (nano, :8082). Some hexis paths must know
which one is actually live: the 1B floor cannot follow the Hexis tool template,
so autonomous cycles on it emit garbage that corrupts episodic memory, and the
chat path must use its slim direct-LLM variant instead of the heavy template.

This reads serving *capability*; it is not a resurrection of the retired
agent.power_mode flag. No DB, no operator gesture — just what is live right now.
"""
from __future__ import annotations

import os
from typing import Any

ROUTER_HEALTH_URL_ENV = "HEXIS_ROUTER_HEALTH_URL"
DEFAULT_ROUTER_HEALTH_URL = "http://127.0.0.1:8090/health"
CPU_FLOOR_PORT_ENV = "HEXIS_CPU_FLOOR_PORT"
DEFAULT_CPU_FLOOR_PORT = "8082"


async def fetch_router_health(url: str, timeout: float = 2.0) -> dict[str, Any] | None:
    """GET the :8090 router /health; parsed JSON dict, or None on any error /
    non-200 (503 no_upstream included). Thin HTTP seam so on_cpu_floor's
    interpretation logic stays unit-testable."""
    import httpx
    try:
        async with httpx.AsyncClient() as client:
            r = await client.get(url, timeout=timeout)
        if r.status_code != 200:
            return None
        return r.json()
    except Exception:
        return None


async def on_cpu_floor() -> bool:
    """True when the live :8090 backend is the CPU floor (nano :8082).

    Detects the floor by upstream PORT (ADR-017/018: the nano floor is :8082),
    NOT the router's internal prime/eco label — so it survives the ADR-020
    phase-4 label rename to gpu/cpu untouched. Fails OPEN (returns False =
    "not on the floor", proceed) on any error, so a router blip never silently
    silences a heartbeat or downgrades a chat turn."""
    url = os.environ.get(ROUTER_HEALTH_URL_ENV, DEFAULT_ROUTER_HEALTH_URL)
    floor_port = os.environ.get(CPU_FLOOR_PORT_ENV, DEFAULT_CPU_FLOOR_PORT)
    health = await fetch_router_health(url)
    if not health:
        return False
    upstream = str(health.get("upstream", "")).rstrip("/")
    return upstream.endswith(f":{floor_port}")
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pytest tests/core/test_serving.py -q`
Expected: `5 passed`.

- [ ] **Step 5: Point `worker_service` at the new module**

In `services/worker_service.py`, DELETE the two function definitions (currently `:268-300`, starting at `async def _fetch_router_health(` and ending at the `return upstream.endswith(f":{floor_port}")` line of `_on_cpu_floor`) and replace them with aliases:

```python
# Capability guard (ADR-020 §2) now lives in core/serving.py so services.chat can
# share it without importing this module's rabbit/gateway/argparse chain. These
# aliases keep the four call sites below (and their tests) unchanged.
_fetch_router_health = fetch_router_health
_on_cpu_floor = on_cpu_floor
```

Add the import next to the other `core.*` imports at the top of the file (after `from core.rabbitmq_bridge import RabbitMQBridge`):

```python
from core.serving import fetch_router_health, on_cpu_floor
```

The `import os` at the top of `worker_service.py` stays — other code uses it.

- [ ] **Step 6: Rewrite `tests/services/test_capability_guard.py` as a wiring test**

The five logic cases now live in `tests/core/test_serving.py`. What still needs covering here is that the worker is actually bound to that implementation — replace the whole file with:

```python
"""The heartbeat worker's capability guard is the shared core.serving probe
(ADR-020 §2). The probe's own logic is tested in tests/core/test_serving.py;
this pins the worker's binding to it, so an accidental re-fork of the logic
inside worker_service.py fails here.
"""
from core import serving
from services import worker_service as ws


def test_worker_uses_shared_capability_probe():
    assert ws._on_cpu_floor is serving.on_cpu_floor
    assert ws._fetch_router_health is serving.fetch_router_health
```

- [ ] **Step 7: Run both test files plus the worker's own suite**

Run: `pytest tests/core/test_serving.py tests/services/test_capability_guard.py -q`
Expected: `7 passed`.

Then run everything that touches the worker:

Run: `pytest tests/services -q`
Expected: PASS (no new failures; the chat tests still pass here — they mock `_read_power_mode`, which Task 2 has not removed yet).

- [ ] **Step 8: Commit**

```bash
git add core/serving.py tests/core/test_serving.py services/worker_service.py tests/services/test_capability_guard.py
git commit -F - <<'EOF'
refactor(serving): extract capability guard to core/serving.py

ADR-020 phase 6 prep. chat.py needs the same live-upstream signal the heartbeat
worker gates on, but cannot import worker_service (rabbit/gateway/argparse chain).
Move fetch_router_health + on_cpu_floor to a leaf module; worker_service keeps its
private names as aliases so its four call sites are untouched.

Behavior identical: port-based floor detection (:8082), fails open on any error.

Assisted by AI.
EOF
```

---

### Task 2: Re-home the chat ECO decision onto the capability signal

This is the task that unblocks the DB cleanup. Both chat entry points stop reading `agent.power_mode` and start reading live serving capability. The branch bodies do not change.

**Files:**
- Modify: `services/chat.py:120-146` (delete `_read_power_mode`), `:473-481` (`chat_turn`), `:692-699` (`stream_chat_turn`), `:149-152` (a docstring that references `_read_power_mode`)
- Create: `tests/services/test_chat_cpu_floor.py`
- Modify: `tests/core/test_chat.py:112-119`, `:143-151`, `:172-180`
- Modify: `tests/services/test_chat_decline_wiring.py:65-67`, `:97-99`
- Modify: `tests/services/test_chat_session_assessment.py:95-96`, `:116`

**Interfaces:**
- Consumes: `core.serving.on_cpu_floor() -> bool` (Task 1).
- Produces: `services.chat.on_cpu_floor` — the module-level name tests monkeypatch (`monkeypatch.setattr(chat, "on_cpu_floor", ...)`). It must be imported into `chat.py`'s namespace with `from core.serving import on_cpu_floor` (NOT `import core.serving` + dotted call), otherwise patching at `services.chat` has no effect.
- Removed: `services.chat._read_power_mode` — no caller may remain.

- [ ] **Step 1: Write the failing acceptance test**

Create `tests/services/test_chat_cpu_floor.py`:

```python
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

    marker = "heavy path reached"

    async def fake_run_agent(*_a, **_k):
        raise RuntimeError(marker)
    monkeypatch.setattr(chat, "run_agent", fake_run_agent)

    # The heavy path needs a pool; a bad DSN makes asyncpg raise before run_agent.
    # Either way we must NOT get an AssertionError from `boom`.
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
```

Note on the last two tests: they assert a *negative* (the slim path is not taken) by making the slim call raise `AssertionError` and then asserting the exception that escapes is anything but that. The heavy path legitimately fails on the unreachable DSN — that is fine and is what we want to observe.

- [ ] **Step 2: Run to verify they fail**

Run: `pytest tests/services/test_chat_cpu_floor.py -q`
Expected: FAIL — `AttributeError: <module 'services.chat'> has no attribute 'on_cpu_floor'` on the monkeypatch (monkeypatch.setattr raises when the attribute does not exist).

- [ ] **Step 3: Implement — import the probe into `chat.py`**

In `services/chat.py`, add to the `core.*` import block at the top (after `from core.llm import chat_completion, normalize_llm_config`):

```python
from core.serving import on_cpu_floor
```

Import the name directly (not the module) — the tests monkeypatch `services.chat.on_cpu_floor`, which only works for a name bound in this module's namespace.

- [ ] **Step 4: Implement — delete `_read_power_mode`**

Delete the entire function at `services/chat.py:120-146` (`async def _read_power_mode(pool, dsn) -> str:` through `return 'eco' if mode == 'eco' else 'prime'`).

Then fix the docstring of `_read_decline_enabled` immediately below it, which cites the deleted function (`chat.py:149-152`). Replace:

```python
async def _read_decline_enabled(pool: Any | None, dsn: str | None) -> bool:
    """Return chat.decline.enabled. Fail toward replying (False) on any error or
    missing key so a transient DB blip or unmigrated DB can never silence a
    persona. Mirrors _read_power_mode's fail-to-prime posture."""
```

with:

```python
async def _read_decline_enabled(pool: Any | None, dsn: str | None) -> bool:
    """Return chat.decline.enabled. Fail toward replying (False) on any error or
    missing key so a transient DB blip or unmigrated DB can never silence a
    persona. Same fail-open posture as the capability guard (core.serving)."""
```

- [ ] **Step 5: Implement — switch `chat_turn`'s branch (`chat.py:473-481`)**

Replace:

```python
    # ECO mode: bypass RLM + tool-agent stack entirely (the heavy prompt
    # template makes 1B emit code-REPL garbage). Use a slim direct LLM call
    # with persona_system_prompt + tiny anchor only. No tools, no recall. The
    # turn IS still persisted via _eco_remember (tagged metadata.origin='eco')
    # so eco vs prime quality stays measurable downstream.
    is_eco = (await _read_power_mode(pool, dsn) == 'eco')
    decline_enabled = await _read_decline_enabled(pool, dsn)
    if is_eco:
        logger.info("ECO mode: chat_turn -> slim direct LLM (no RLM, no tools; turn persisted tagged origin=eco)")
```

with:

```python
    # CPU floor (ADR-020 §2): when the live :8090 upstream is the 1B nano, bypass
    # the RLM + tool-agent stack entirely — the heavy prompt template makes the 1B
    # emit code-REPL garbage. Use a slim direct LLM call with persona_system_prompt
    # + tiny anchor only. No tools, no recall. The turn IS still persisted via
    # _eco_remember (tagged metadata.origin='eco') so floor-vs-GPU reply quality
    # stays measurable downstream — the tag is a data contract, keep the name.
    # Reads live serving capability; the retired agent.power_mode flag is gone.
    on_floor = await on_cpu_floor()
    decline_enabled = await _read_decline_enabled(pool, dsn)
    if on_floor:
        logger.info("CPU floor live: chat_turn -> slim direct LLM (no RLM, no tools; turn persisted tagged origin=eco)")
```

Nothing below this changes — the branch body (slim call, `ECO_FALLBACK_REPLY`, `_apply_decline(origin="eco")`, `_eco_remember`) is untouched.

- [ ] **Step 6: Implement — switch `stream_chat_turn`'s branch (`chat.py:692-699`)**

Replace:

```python
    # ECO mode: bypass RLM/agent stack, use slim direct LLM call (no streaming
    # available there — yield the full text as a single chunk). Same rationale
    # as chat_turn: 1B can't parse the heavy template; slim path keeps the
    # persona voice viable.
    is_eco = (await _read_power_mode(pool, dsn) == 'eco')
    decline_enabled = await _read_decline_enabled(pool, dsn)
    if is_eco:
        logger.info("ECO mode: stream_chat_turn -> slim direct LLM (no stream, single chunk)")
```

with:

```python
    # CPU floor (ADR-020 §2): bypass RLM/agent stack, use slim direct LLM call (no
    # streaming available there — yield the full text as a single chunk). Same
    # rationale as chat_turn: the 1B can't parse the heavy template; the slim path
    # keeps the persona voice viable. Driven by live serving capability.
    on_floor = await on_cpu_floor()
    decline_enabled = await _read_decline_enabled(pool, dsn)
    if on_floor:
        logger.info("CPU floor live: stream_chat_turn -> slim direct LLM (no stream, single chunk)")
```

- [ ] **Step 7: Run the acceptance test**

Run: `pytest tests/services/test_chat_cpu_floor.py -q`
Expected: `4 passed`.

- [ ] **Step 8: Run the existing chat suites to see them fail (they still mock the deleted function)**

Run: `pytest tests/core/test_chat.py tests/services/test_chat_decline_wiring.py tests/services/test_chat_session_assessment.py -q`
Expected: FAIL — `AttributeError: <module 'services.chat'> has no attribute '_read_power_mode'` from the monkeypatch calls. This is the expected red; fix them next.

- [ ] **Step 9: Swap the mocks in `tests/core/test_chat.py`**

Three tests patch the deleted function. In each, replace the `fake_power` helper and its `monkeypatch.setattr`.

At `:112-119` (in `test_chat_turn_eco_writes_tagged_memory`), `:143-151` (`test_chat_turn_eco_fallback_skips_memory`), and `:172-180` (`test_stream_chat_turn_eco_writes_tagged_memory`), replace each occurrence of:

```python
    async def fake_power(_pool, _dsn):
        return "eco"
```

with:

```python
    async def fake_floor():
        return True
```

and each occurrence of:

```python
    monkeypatch.setattr(chat_mod, "_read_power_mode", fake_power)
```

with:

```python
    monkeypatch.setattr(chat_mod, "on_cpu_floor", fake_floor)
```

All other lines in those tests — including the `metadata["origin"] == "eco"` assertions — stay exactly as they are. That is the point: the persisted contract did not move.

- [ ] **Step 10: Swap the mocks in `tests/services/test_chat_decline_wiring.py`**

In `test_chat_turn_eco_path_declines` (`:63-67`) and `test_stream_chat_turn_eco_path_declines` (`:95-99`), replace each:

```python
    async def _fake_power_mode(*a, **k):
        return "eco"
    monkeypatch.setattr(chat, "_read_power_mode", _fake_power_mode)
```

with:

```python
    async def _fake_on_floor():
        return True
    monkeypatch.setattr(chat, "on_cpu_floor", _fake_on_floor)
```

Also update the two docstrings so they name the trigger correctly:
- `"""ECO path: a decline marker from the slim call is honored + rendered."""` → `"""CPU-floor slim path: a decline marker from the slim call is honored + rendered."""`
- `"""Streaming ECO path: a decline marker is honored + rendered in the yielded chunk."""` → `"""Streaming CPU-floor slim path: a decline marker is honored + rendered in the yielded chunk."""`

Every assertion (`recorded["origin"] == "eco"`, `chunks == ["[DECLINED]"]`, register `"blunt"`) stays — decline wiring must be provably unregressed.

- [ ] **Step 11: Swap the mock in `tests/services/test_chat_session_assessment.py`**

This one mocks the *prime* (heavy) path. At `:95-96` replace:

```python
    async def _fake_read_power_mode(pool, dsn):
        return "prime"
```

with:

```python
    async def _fake_on_cpu_floor():
        return False
```

and at `:116` replace:

```python
    monkeypatch.setattr("services.chat._read_power_mode", _fake_read_power_mode)
```

with:

```python
    monkeypatch.setattr("services.chat.on_cpu_floor", _fake_on_cpu_floor)
```

- [ ] **Step 12: Run all four chat suites green**

Run: `pytest tests/core/test_chat.py tests/services/test_chat_decline_wiring.py tests/services/test_chat_session_assessment.py tests/services/test_chat_cpu_floor.py -q`
Expected: PASS, no failures.

- [ ] **Step 13: Verify no code reader of the flag survives**

Run: `grep -rn "agent.power_mode\|_read_power_mode" services/ core/`
Expected: no output (exit 1). If anything prints, it must be fixed before committing — including comments.

- [ ] **Step 14: Commit**

```bash
git add services/chat.py tests/services/test_chat_cpu_floor.py tests/core/test_chat.py tests/services/test_chat_decline_wiring.py tests/services/test_chat_session_assessment.py
git commit -F - <<'EOF'
feat(chat): drive the slim path from live serving capability, not agent.power_mode

ADR-020 phase 6. chat.py was the last live reader of the retired flag (:478, :696):
deleting the config row would have silently flipped any 'eco' instance onto the
heavy path. The slim path's real predicate was never an operator mode — it is "the
live :8090 upstream is the 1B floor, which can't parse the tool template." Read that
directly (core.serving.on_cpu_floor), same signal the heartbeat guard uses.

Behavior preserved: slim call, ECO_FALLBACK_REPLY, decline wiring, and the persisted
metadata.origin='eco' tag are unchanged. Fail-open posture identical (probe failure ->
heavy path, as the old missing-key -> 'prime' fallback did). _read_power_mode deleted.

Assisted by AI.
EOF
```

---

### Task 3: Remove the config key (migration + seed)

Only safe now that no reader exists. `db/00_tables.sql` seeds fresh bootstraps; `db/migrations/0009` cleans existing DBs. Both are required — the seed alone would re-add the key the migration deleted.

**Files:**
- Create: `db/migrations/0009_agent_power_mode_cleanup.sql`
- Modify: `db/00_tables.sql:665-668`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing importable. The observable contract is that a fresh bootstrap has no `agent.power_mode` row in `config`.

- [ ] **Step 1: Write the migration**

Create `db/migrations/0009_agent_power_mode_cleanup.sql`:

```sql
-- ADR-020 phase 6: retire the agent.power_mode config flag.
--
-- The flag bundled a serving decision with a cognition gate. Both readers are gone:
-- the heartbeat worker gates on live serving capability (core/serving.py on_cpu_floor,
-- ADR-020 §2) and services/chat.py's slim path now reads the same signal. The row is
-- inert; drop it so a stale value can never be resurrected by a new reader.
--
-- Per-database: schema_migrations is per-DB, so this only touches the DB of the
-- current DSN. Fleet-wide cleanup = enumerate ~/.hexis/instances.json and apply per DB.
SET search_path = public, ag_catalog, "$user";

DELETE FROM config WHERE key = 'agent.power_mode';
```

- [ ] **Step 2: Remove the seed row**

In `db/00_tables.sql`, the seed block currently reads (`:665-668`):

```sql
INSERT INTO config (key, value, description) VALUES
    ('agent.tools', '["recall","sense_memory_availability","explore_concept","get_procedures","get_strategies","remember","manage_goals","manage_schedule","manage_backlog","aggregate_signals"]'::jsonb, 'Allowed tool names for chat-context tool use. Names MUST match the ToolHandlers registered in core/tools/ — services.agent applies this list as the chat allowlist via _allowed_tools_for_mode. Heartbeat keeps the full registry. Update this seed when registry names change; otherwise the chat path silently drops missing names.'),
    ('agent.power_mode', '"prime"'::jsonb, 'Power mode: prime (full LLM behavior) or eco (canned chat reply, heartbeat skipped, no memory writes). Flipped by set-power-mode.ps1.')
ON CONFLICT (key) DO NOTHING;
```

Delete the `agent.power_mode` line and the trailing comma on the `agent.tools` line:

```sql
INSERT INTO config (key, value, description) VALUES
    ('agent.tools', '["recall","sense_memory_availability","explore_concept","get_procedures","get_strategies","remember","manage_goals","manage_schedule","manage_backlog","aggregate_signals"]'::jsonb, 'Allowed tool names for chat-context tool use. Names MUST match the ToolHandlers registered in core/tools/ — services.agent applies this list as the chat allowlist via _allowed_tools_for_mode. Heartbeat keeps the full registry. Update this seed when registry names change; otherwise the chat path silently drops missing names.')
ON CONFLICT (key) DO NOTHING;
```

- [ ] **Step 3: Verify the SQL surface is clean**

Run: `grep -rn "agent.power_mode" db/ | grep -v "0009_agent_power_mode_cleanup"`
Expected: no output (exit 1). The only surviving mention of the key in `db/` is the migration that deletes it.

- [ ] **Step 4: Prove a fresh bootstrap has no key**

This needs Docker up. Bring up the DB and apply the schema into a throwaway database, then assert the row is absent.

```bash
docker compose up -d
docker exec hexis_brain psql -U hexis_user -d postgres -c "DROP DATABASE IF EXISTS hexis_p6check;" -c "CREATE DATABASE hexis_p6check;"
```

Apply the schema to it exactly the way a fresh bootstrap does — `core.schema.apply_schema(dsn)` (`core/schema.py:109`) loads all of `db/*.sql` in lexical order, then baselines `schema_migrations`:

```bash
python - <<'PY'
import asyncio
from core.schema import apply_schema
dsn = "postgresql://hexis_user:hexis_pass@localhost:43815/hexis_p6check"
asyncio.run(apply_schema(dsn))
PY
```

Use the real credentials/port from `.env` if they differ from the defaults above. Then:

```bash
docker exec hexis_brain psql -U hexis_user -d hexis_p6check -tAc "SELECT count(*) FROM config WHERE key = 'agent.power_mode';"
```
Expected: `0`

Clean up:
```bash
docker exec hexis_brain psql -U hexis_user -d postgres -c "DROP DATABASE hexis_p6check;"
```

- [ ] **Step 5: Commit**

```bash
git add db/migrations/0009_agent_power_mode_cleanup.sql db/00_tables.sql
git commit -F - <<'EOF'
chore(db): drop the agent.power_mode config key (ADR-020 phase 6)

Migration 0009 deletes the row from existing DBs; the 00_tables.sql seed is removed
so fresh bootstraps never re-add it. Safe only now that both readers are gone (the
heartbeat gate and chat's slim path both read live serving capability).

Per-DB: schema_migrations is per-database, so 0009 lands only on the current DSN's
database. Fleet-wide cleanup is an operator step (enumerate ~/.hexis/instances.json,
apply per DB) — deliberately not automated here.

Assisted by AI.
EOF
```

---

### Task 4: Fix the serving runbook

`.local-notes/guidelines/model-serving.md` still documents `agent.power_mode` as "the single flag workers gate on" and `set-power-mode.ps1` as the `:8080` owner. Both are false: ADR-020 phase 3 (`3f1a5f6`) deleted `set-power-mode.ps1`, `scripts/set_power_mode.py`, `power-profiles.psd1`, `hexis-launcher.ps1`, and the vram-guard, and this plan deletes the flag. A runbook that confidently describes a deleted script is worse than no runbook — it sends the next session (or the operator, mid-incident) after a file that is not there.

**Files:**
- Modify: `.local-notes/guidelines/model-serving.md`

**Interfaces:** none (docs).

- [ ] **Step 1: Read the whole file first**

Run: `cat .local-notes/guidelines/model-serving.md`

Identify every mention of: `set-power-mode.ps1`, `power-profiles.psd1`, `hexis-launcher.ps1`, `agent.power_mode`, ECO/PRIME as an operator mode, `make-power-shortcuts.ps1`, `hexis-vram-guard.ps1`, `current-mode.txt`. All of those are retired.

- [ ] **Step 2: Replace the "Power mode behavior" section**

Delete the whole `## Power mode behavior` section and put in its place:

```markdown
## Serving capability (ECO/PRIME retired — ADR-020)

The prime/eco power mode is **gone**: no `agent.power_mode` DB key, no
`set-power-mode.ps1`, no `power-profiles.psd1`, no vram-guard, no desktop buttons.
Serving is owned by llm-serve (ADR-019); hexis is a pure consumer of the `:8090`
router and never picks a backend.

- **The GPU slot is llm-serve's.** Arm/free it with `fleetctl gpu claim|release`
  (host-claim lock) — see `C:\ai-workspace\decisions\020_power_mode_retirement.md`.
  hexis owns zero GPU-slot automation.
- **Capability guard** (`core/serving.py: on_cpu_floor()`) is how hexis reacts to the
  backend it gets. It GETs `:8090/health` and checks whether the live upstream is the
  CPU floor by **port** (`:8082`; env `HEXIS_CPU_FLOOR_PORT`), not by the router's
  label — the labels are being renamed prime/eco → gpu/cpu. Fails **open** (proceed)
  on any error, so a router blip never silences the fleet.
- **On the CPU floor (1B nano live):**
  - Autonomous cycles are skipped — heartbeat, subconscious maintenance, and alert
    reactions (`services/worker_service.py`). The 1B cannot follow the tool template;
    letting it run writes garbage into episodic memory.
  - **Interactive chat still works**, on the slim path (`services.chat._eco_slim_chat`):
    persona prompt + small anchor + last 8 turns → direct LLM, no tools, no recall. The
    turn IS persisted (`_eco_remember` → `record_chat_turn_memory` →
    `subconscious_units`, tagged `metadata.origin='eco'` vs `'prime'`, so floor-vs-GPU
    reply quality stays measurable). A slim failure → `ECO_FALLBACK_REPLY`.
  - The `origin='eco'` tag keeps its name on purpose: it is a persisted data contract,
    and existing rows carry it.
- **Heartbeat on/off is a separate axis** — the manual `heartbeat_state.is_paused`
  switch (`scripts/pause_fleet.py`). Freeing the GPU does not pause cognition, and
  pausing cognition does not free the GPU. Do not re-couple them.
```

- [ ] **Step 3: Fix the retired-script references in the rest of the file**

Every remaining sentence that names `set-power-mode.ps1` as the `:8080` owner or launcher must be corrected to name llm-serve's `serve.py` / `fleetctl` instead (the topology bullets near the top, and the "Model registry" + "Cold re-arm" bullets). Where a bullet's whole subject was the retired tooling (cold re-arm via `eco`→`prime`, `power-profiles.psd1` BigModels, `hexis-launcher.ps1` GUI), delete the bullet — do not invent replacement procedure you have not verified against `C:\llm-serve`.

If a bullet's correct replacement is not verifiable from `C:\llm-serve\docs\HEXIS-INTEGRATION.md` or `C:\ai-workspace\decisions\020_power_mode_retirement.md`, delete the stale claim and leave a one-line pointer to llm-serve rather than guessing.

- [ ] **Step 4: Verify no stale references remain**

Run: `grep -rn "set-power-mode\|power-profiles\|hexis-launcher\|agent.power_mode\|make-power-shortcuts\|hexis-vram-guard" .local-notes/guidelines/model-serving.md`
Expected: no output (exit 1).

- [ ] **Step 5: Commit**

```bash
git add .local-notes/guidelines/model-serving.md
git commit -F - <<'EOF'
docs(serving): rewrite the runbook's power-mode section for the capability guard

The runbook still told the operator to drive :8080 with set-power-mode.ps1 and gate
workers on agent.power_mode — phase 3 (3f1a5f6) deleted the scripts, phase 6 deletes
the key. Replaced with the real model: llm-serve owns the GPU slot (fleetctl gpu
claim/release), hexis reacts via core/serving.on_cpu_floor, and chat stays alive on
the slim path while the floor is live.

Assisted by AI.
EOF
```

---

## Final Verification

- [ ] **Full suite green**

```bash
docker compose up -d
pytest tests -q
```
Expected: PASS. Any failure here must be fixed before the branch is called done — do not report success on a partial run.

- [ ] **Acceptance grep clean**

```bash
grep -rn "agent.power_mode\|_read_power_mode" services/ core/ db/ | grep -v "0009_agent_power_mode_cleanup"
```
Expected: no output.

- [ ] **Report to the operator, do not act:** migration `0009` has NOT been applied to any live instance DB. Fleet-wide cleanup requires enumerating `~/.hexis/instances.json` and applying per database, plus a worker restart so the new `chat.py` is running. Hand the operator the list of instance DBs; let them run it.

## Notes for the implementer

- `services/chat.py` is imported by the CLI, the API server, and the channel adapters. Keep its import list leaf-ish — that is the entire reason `core/serving.py` exists rather than importing from `worker_service`.
- Monkeypatching only works on the name in the *consuming* module's namespace. `from core.serving import on_cpu_floor` in `chat.py` is required; `import core.serving` + `core.serving.on_cpu_floor()` would make `monkeypatch.setattr(chat, "on_cpu_floor", ...)` a no-op and the tests would silently pass against the real probe.
- Do not add a TTL cache to the probe. At localhost latency it buys nothing and introduces a staleness window exactly where liveness is the point.
