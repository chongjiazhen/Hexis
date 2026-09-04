# ADR-020 Phase 6 — retire `agent.power_mode` from hexis

Date: 2026-07-14
Status: Approved (design)
Implements: ADR-020 phase 3 (chat half) + phase 6 (DB cleanup),
`C:\ai-workspace\decisions\020_power_mode_retirement.md`

## Problem

ADR-020 phase 6 is written as a pure DB cleanup — "code reads already removed,
key inert, safe DELETE." That premise is false.

`services/worker_service.py` did migrate: its heartbeat gate now reads live
serving capability (`_on_cpu_floor`, `worker_service.py:283-300`) instead of the
DB flag. But `services/chat.py` still reads `agent.power_mode` live:

- `chat.py:120` — `_read_power_mode(pool, dsn)` → `SELECT get_config('agent.power_mode')`
- `chat.py:478` (`chat_turn`) and `chat.py:696` (`stream_chat_turn`) —
  `is_eco = (await _read_power_mode(pool, dsn) == 'eco')`, gating the slim ECO
  chat path.

Deleting the config row while those reads exist silently flips any instance
sitting at `'eco'` onto the prime fallback (`_read_power_mode` returns `'prime'`
on a missing key). So the key removal is **blocked on re-homing the chat reads
first**.

## Correction to ADR-020 §4

ADR-020 §4 ("Interactive chat when the GPU is claimed") says: *drop the canned
"resting" reply; deletes the `chat.py` eco branch + `_read_power_mode`.* That is
stale. §4 was written when the eco branch returned a **canned** reply. It has
since become the **slim direct-LLM path** (`_eco_slim_chat` + `ECO_SLIM_ANCHOR`,
`chat.py:22-35`): persona system prompt + a tiny anchor, no RLM, no tools, no
recall — the turn still persists, tagged `metadata.origin='eco'`.

That slim path *is* what ADR-020 §2 calls "the 1B's competent envelope." Deleting
the branch would route CPU-floor chat through the heavy tool template — the exact
REPL-confusion + prompt-template-leak failure the fleet probe proved unviable
(`memory: project_eco_floor_unviable`). §2 and §4 contradict; §2 is correct.

**This spec preserves the branch and re-homes its trigger.** The ADR gets a §4
amendment recording the correction.

## Decision

The ECO branch's true predicate was never "the operator flipped a mode." It was
"the live upstream is the 1B CPU floor, which can't parse the heavy template."
That is exactly what `_on_cpu_floor` already expresses. Re-home the chat decision
onto that same live signal, then delete the flag.

### 1. `core/serving.py` — new module, sole owner of the capability probe

Extracted verbatim from `worker_service.py:268-300`, public-named since it is now
a cross-module interface:

```python
async def fetch_router_health(url: str, timeout: float = 2.0) -> dict | None
async def on_cpu_floor() -> bool
```

- Reads `HEXIS_ROUTER_HEALTH_URL` (default `http://127.0.0.1:8090/health`).
- Detects the floor by upstream **port** — `HEXIS_CPU_FLOOR_PORT`, default
  `8082` — not the router's `prime`/`eco` label, so it survives the ADR-020
  phase-4 label rename to `gpu`/`cpu`.
- **Fails OPEN**: any error, non-200, or 503 `no_upstream` → `None` → `False`
  (not on the floor → proceed on the heavy path).
- Dependencies: `os` + `httpx` only. No DB, no rabbit, no gateway.

Home is `core/` not `services/` because it is a fundamental serving-interface
primitive with no orchestration in it, consumed by two services.

### 2. Consumers

**`services/worker_service.py`** — `_fetch_router_health` / `_on_cpu_floor` become
thin aliases of the `core.serving` functions. Its four call sites (`:123`, `:140`,
`:524`, `:714`) are unchanged. The heartbeat + subconscious gates keep their exact
behavior.

**`services/chat.py`** — `_read_power_mode` is deleted. Both branch points become:

```python
on_floor = await on_cpu_floor()
```

Everything downstream of the branch is untouched: `_eco_slim_chat`,
`_apply_decline(..., origin="eco")`, `_eco_remember`, `ECO_FALLBACK_REPLY`. The
`_read_decline_enabled` call stays where it is (it gates the decline feature,
which applies on both paths).

### 3. Vocabulary

ADR-020 §7 purges prime/eco vocabulary for serving facts. Inside chat.py that
applies to the **decision**, not the **data**:

- Renamed: `is_eco` → `on_floor`; the "ECO mode:" comments and log lines are
  rewritten to name the live CPU floor.
- Kept: `_eco_slim_chat`, `_eco_remember`, `ECO_SLIM_ANCHOR`, `ECO_FALLBACK_REPLY`,
  and `metadata.origin='eco'`. The origin tag is a **persisted data contract** —
  rows already carry `'eco'` and downstream quality comparison reads it. Renaming
  it would split the series for no gain.

### 4. Semantics preserved

| | Before | After |
|---|---|---|
| Slim path fires when | `agent.power_mode == 'eco'` | live `:8090` upstream is `:8082` |
| DB/probe error | `'prime'` → heavy path | `False` → heavy path |
| Missing key / router down | heavy path | heavy path |
| Memory write on slim turn | `origin='eco'` | `origin='eco'` |
| Decline wiring | both paths | both paths |

Fail-open direction is identical, so a router blip degrades to today's behavior
rather than silencing a persona.

### 5. Cost

One extra localhost `GET :8090/health` per chat turn, replacing one DB
`get_config`. No cache: at localhost latency a TTL cache buys nothing and adds a
staleness window exactly where liveness is the point. The worker already probes
per poll tick.

### 6. DB cleanup (only unblocked once the above lands)

- `db/migrations/0009_agent_power_mode_cleanup.sql` —
  `DELETE FROM config WHERE key = 'agent.power_mode';` Idempotent.
- `db/00_tables.sql:667` — the seed row is removed, else a fresh bootstrap
  re-adds the key the migration just deleted.
- Dual-write rule (`core/schema.py:151-157`) is satisfied: `db/*.sql` for fresh
  instances, `db/migrations/` for existing ones.

**Operator step, not automated.** `schema_migrations` is per-database, so 0009
applies only to the DB of the current DSN. Cleaning the live fleet means
enumerating `~/.hexis/instances.json` and applying per database. This spec does
not loop over live instance DBs; that run is left to the operator.

### 7. Docs

`.local-notes/guidelines/model-serving.md:23` describes `agent.power_mode` as the
single ECO lever. That becomes false; it is rewritten to describe the capability
guard in the same commit (cull-on-touch).

## Testing

TDD — red test before each change.

1. **`tests/core/test_serving.py`** — the five capability-guard cases, moved off
   `worker_service` onto `core.serving`: nano port → True; gpu port → False;
   router unreachable → False (fail open); trailing slash tolerated;
   `HEXIS_CPU_FLOOR_PORT` override honored.
2. **`tests/services/test_capability_guard.py`** — reduced to a wiring assertion
   that `worker_service._on_cpu_floor is core.serving.on_cpu_floor`, so the
   worker's binding stays covered without duplicating the logic tests.
3. **`tests/services/test_chat_cpu_floor.py`** (new — the acceptance gate) —
   patch `chat.on_cpu_floor`:
   - `True` → `chat_turn` and `stream_chat_turn` take the slim path,
     `_eco_slim_chat` is called, the persisted memory carries
     `metadata.origin == 'eco'`.
   - `False` → the heavy agent path is taken (slim path not called).
4. **Rewritten mocks** — `tests/core/test_chat.py:119,150,179`,
   `tests/services/test_chat_decline_wiring.py:65,97`,
   `tests/services/test_chat_session_assessment.py:95,116` swap
   `_read_power_mode → 'eco'/'prime'` for `on_cpu_floor → True/False`. Their
   assertions are unchanged — that is the unregressed-behavior proof for decline
   wiring and session assessment.

## Acceptance

- `grep -rn "agent.power_mode\|_read_power_mode" services/ core/ db/` → zero hits,
  comments included.
- The slim chat path still fires, now driven by the live CPU upstream, proven by
  test 3.
- Prime path + decline wiring unregressed (test 4).
- Full `pytest tests -q` green.
- A fresh bootstrap produces no `agent.power_mode` config row.

## Out of scope

- The remaining ADR-020 conform-list items (vram-guard relocation, `set-power-mode.ps1`
  deletion, dashboard header) — done or tracked separately.
- Running 0009 against the live fleet's instance DBs.
- Any change to the `:8090` router contract.
