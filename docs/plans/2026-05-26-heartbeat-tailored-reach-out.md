# Heartbeat Tailored Reach-Out Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Heartbeat reach-out targets a specific person (sender_id) chosen by the persona's REPL reasoning; one heartbeat may emit multiple per-recipient tailored DMs in a single LLM call.

**Architecture:** Today `apply_heartbeat_action('reach_out_user', ...)` queues an outbox message with no `sender_id` and no `delivery_mode`, so `channels/outbox.py` falls through to `last_active` and picks the globally most-recent `channel_session` (LIMIT 1) — i.e. whichever chat last pinged the bot. This plan threads `sender_id` from the action params into the outbox payload (the channel-side `_deliver_last_active` already reads `payload.sender_id`, so no consumer code change is required) and surfaces a recent-active-senders list into the heartbeat turn context so the persona can choose who to reach for. Cost: one heartbeat REPL call already reasons over all relationships; emitting multiple `reach_out_user` actions in one `FINAL` payload — each with its own `sender_id` + tailored `message` — adds output tokens, not new LLM calls. Energy stays charged per recipient (5 each), capping naturally at ~3–4 reach-outs per cycle.

**Tech Stack:** PostgreSQL (plpgsql, Apache AGE for graph), Python 3.10+ asyncio (services/worker_service.py, channels/outbox.py), pytest-asyncio, RabbitMQ (management HTTP), Docker Compose. Local LLM via llama-server :8080.

---

## File Structure

**Modify:**
- `db/09_functions_context.sql` — add `get_active_senders_context()`, wire into `gather_turn_context()` output JSON (~lines 320–352).
- `db/17_functions_subconscious_observations.sql:1208-1219` — `reach_out_user` branch: thread `sender_id` from `p_params` into outbox payload.
- `services/prompts/rlm_heartbeat_system.md` — Action Types section + Guidelines: note `reach_out_user` requires `sender_id`, can be emitted multiple times in one cycle.
- `services/prompts/heartbeat_system.md` — legacy/non-RLM path: same nudge.

**Create:**
- `tests/db/test_heartbeat_reach_out_sender.py` — DB unit tests for the new context func + action handler payload.
- `tests/services/test_outbox_reach_out_routing.py` — integration: synthetic outbox msg carrying `sender_id` routes to that user's most-recent session, not the globally most-recent one.
- `.local-notes/migrations/2026-05-26-heartbeat-tailored-reach-out/migrate.sql` — live re-apply SQL for the fleet (idempotent CREATE OR REPLACE only; no schema ALTERs needed).
- `.local-notes/migrations/2026-05-26-heartbeat-tailored-reach-out/README.md` — runbook (per-persona DB loop, post-apply verification queries).

**No change required:**
- `channels/outbox.py` — `_deliver_last_active` at line 235 already reads `payload.get("sender_id") or payload.get("target_user")`. The fix is upstream (DB now stamps `sender_id` into the payload).
- `db/00_tables.sql` — no new enum value, no new column. `reach_out_user` enum entry already exists.
- `services/worker_service.py` — already loops over `outbox_messages` and publishes each (`_publish_outbox` at :316, :464). Multiple `reach_out_user` actions producing multiple outbox entries already fans out correctly.

---

## Task 1: Add `get_active_senders_context()` SQL function

**Files:**
- Modify: `db/09_functions_context.sql` (add new function above `gather_turn_context`, around line 320)
- Test: `tests/db/test_heartbeat_reach_out_sender.py`

- [ ] **Step 1: Write the failing test**

Create `tests/db/test_heartbeat_reach_out_sender.py`:

```python
import json
import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


async def test_get_active_senders_context_returns_recent_distinct_senders(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute(
                """
                INSERT INTO channel_sessions (channel_type, channel_id, sender_id, last_active)
                VALUES
                    ('telegram', '111', '111', CURRENT_TIMESTAMP - INTERVAL '2 hours'),
                    ('telegram', '222', '222', CURRENT_TIMESTAMP - INTERVAL '1 day'),
                    ('telegram', '333', '333', CURRENT_TIMESTAMP - INTERVAL '30 days'),
                    ('telegram', '111', '111', CURRENT_TIMESTAMP - INTERVAL '10 minutes')
                ON CONFLICT DO NOTHING
                """,
            )

            raw = await conn.fetchval("SELECT get_active_senders_context(5, 7)")
            senders = raw if isinstance(raw, list) else json.loads(raw)

            ids = [s["sender_id"] for s in senders]
            assert "111" in ids
            assert "222" in ids
            assert "333" not in ids  # outside 7-day window
            # Most-recent first
            assert ids.index("111") < ids.index("222")
            for s in senders:
                assert "channel_type" in s
                assert "last_active" in s

            await conn.execute("ROLLBACK")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/db/test_heartbeat_reach_out_sender.py::test_get_active_senders_context_returns_recent_distinct_senders -v`

Expected: FAIL with `function get_active_senders_context(integer, integer) does not exist`.

- [ ] **Step 3: Add the function**

In `db/09_functions_context.sql`, insert this above `CREATE OR REPLACE FUNCTION gather_turn_context` (~line 290):

```sql
CREATE OR REPLACE FUNCTION get_active_senders_context(
    p_limit INT DEFAULT 8,
    p_recency_days INT DEFAULT 7
)
RETURNS JSONB AS $$
DECLARE
    lim INT := GREATEST(0, LEAST(50, COALESCE(p_limit, 8)));
    win INT := GREATEST(1, LEAST(90, COALESCE(p_recency_days, 7)));
    out_json JSONB;
BEGIN
    SELECT COALESCE(jsonb_agg(row_to_json(t)::jsonb ORDER BY t.last_active DESC), '[]'::jsonb)
    INTO out_json
    FROM (
        SELECT DISTINCT ON (cs.sender_id)
            cs.sender_id,
            cs.channel_type,
            cs.channel_id,
            cs.last_active,
            (
                SELECT COUNT(*)
                FROM memories m
                WHERE m.sender_id = cs.sender_id
                  AND m.status = 'active'
            ) AS memory_count
        FROM channel_sessions cs
        WHERE cs.sender_id IS NOT NULL
          AND cs.last_active > CURRENT_TIMESTAMP - (win || ' days')::interval
        ORDER BY cs.sender_id, cs.last_active DESC
        LIMIT lim
    ) t;

    RETURN COALESCE(out_json, '[]'::jsonb);
EXCEPTION
    WHEN OTHERS THEN
        RETURN '[]'::jsonb;
END;
$$ LANGUAGE plpgsql STABLE;
```

- [ ] **Step 4: Re-apply to test DB**

```bash
docker exec -i hexis_brain psql -U hexis_user -d hexis_memory -v ON_ERROR_STOP=1 -f - < db/09_functions_context.sql
```

Expected: `CREATE FUNCTION` (or `CREATE OR REPLACE`) for each function in the file, no errors.

- [ ] **Step 5: Run test, verify pass**

Run: `pytest tests/db/test_heartbeat_reach_out_sender.py::test_get_active_senders_context_returns_recent_distinct_senders -v`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add db/09_functions_context.sql tests/db/test_heartbeat_reach_out_sender.py
git commit -m "feat(heartbeat): get_active_senders_context() for tailored reach-out"
```

---

## Task 2: Wire `active_senders` into `gather_turn_context()`

**Files:**
- Modify: `db/09_functions_context.sql:330-343` (the `RETURN jsonb_build_object` of `gather_turn_context`)
- Test: `tests/db/test_heartbeat_reach_out_sender.py` (append)

- [ ] **Step 1: Append the failing test**

In `tests/db/test_heartbeat_reach_out_sender.py`:

```python
async def test_gather_turn_context_exposes_active_senders(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute(
                """
                INSERT INTO channel_sessions (channel_type, channel_id, sender_id, last_active)
                VALUES ('telegram', '4242', '4242', CURRENT_TIMESTAMP - INTERVAL '15 minutes')
                ON CONFLICT DO NOTHING
                """,
            )

            raw = await conn.fetchval("SELECT gather_turn_context()")
            ctx = raw if isinstance(raw, dict) else json.loads(raw)

            assert "active_senders" in ctx
            assert isinstance(ctx["active_senders"], list)
            ids = [s["sender_id"] for s in ctx["active_senders"]]
            assert "4242" in ids

            await conn.execute("ROLLBACK")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/db/test_heartbeat_reach_out_sender.py::test_gather_turn_context_exposes_active_senders -v`

Expected: FAIL with `assert "active_senders" in ctx` (key missing).

- [ ] **Step 3: Add the key to `gather_turn_context()`**

In `db/09_functions_context.sql`, edit the `RETURN jsonb_build_object(...)` block at lines 330–343:

```sql
    RETURN jsonb_build_object(
        'recent_memories', recent,
        'narrative', get_narrative_context(),
        'self_model', get_self_model_context(p_self_limit),
        'relationships', get_relationships_context(p_relationship_limit),
        'active_senders', get_active_senders_context(8, 7),
        'worldview', get_worldview_context(),
        'contradictions', get_contradictions_context(p_contradiction_limit),
        'emotional_patterns', get_emotional_patterns_context(p_emotional_pattern_limit),
        'active_transformations', get_active_transformations_context(5),
        'transformations_ready', check_transformation_readiness(),
        'emotional_state', get_current_affective_state(),
        'emotional_triggers', COALESCE(emotional_triggers, '[]'::jsonb),
        'goals', get_goals_snapshot()
    );
```

- [ ] **Step 4: Re-apply to test DB**

```bash
docker exec -i hexis_brain psql -U hexis_user -d hexis_memory -v ON_ERROR_STOP=1 -f - < db/09_functions_context.sql
```

Expected: function recreated, no errors.

- [ ] **Step 5: Run test, verify pass**

Run: `pytest tests/db/test_heartbeat_reach_out_sender.py::test_gather_turn_context_exposes_active_senders -v`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add db/09_functions_context.sql tests/db/test_heartbeat_reach_out_sender.py
git commit -m "feat(heartbeat): expose active_senders in gather_turn_context"
```

---

## Task 3: Thread `sender_id` into `reach_out_user` outbox payload

**Files:**
- Modify: `db/17_functions_subconscious_observations.sql:1208-1219`
- Test: `tests/db/test_heartbeat_reach_out_sender.py` (append)

- [ ] **Step 1: Append the failing test**

In `tests/db/test_heartbeat_reach_out_sender.py`:

```python
async def test_reach_out_user_carries_sender_id_in_outbox_payload(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            raw = await conn.fetchval(
                """
                SELECT apply_heartbeat_action(
                    'reach_out_user',
                    jsonb_build_object(
                        'sender_id', '99999',
                        'message',   'Thinking about you today.',
                        'intent',    'check_in'
                    ),
                    gen_random_uuid()
                )
                """,
            )
            res = raw if isinstance(raw, dict) else json.loads(raw)

            assert res.get("queued") is True
            outbox = res.get("outbox_message")
            assert isinstance(outbox, dict)
            payload = outbox.get("payload", {})
            assert payload.get("sender_id") == "99999"
            assert payload.get("message") == "Thinking about you today."
            assert payload.get("intent") == "check_in"

            await conn.execute("ROLLBACK")


async def test_reach_out_user_without_sender_id_stays_backward_compat(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            raw = await conn.fetchval(
                """
                SELECT apply_heartbeat_action(
                    'reach_out_user',
                    jsonb_build_object('message', 'hi', 'intent', 'check_in'),
                    gen_random_uuid()
                )
                """,
            )
            res = raw if isinstance(raw, dict) else json.loads(raw)
            assert res.get("queued") is True
            payload = res["outbox_message"]["payload"]
            # sender_id absent or NULL is acceptable; routing falls through to global last_active
            assert payload.get("sender_id") in (None, "")

            await conn.execute("ROLLBACK")
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pytest tests/db/test_heartbeat_reach_out_sender.py::test_reach_out_user_carries_sender_id_in_outbox_payload tests/db/test_heartbeat_reach_out_sender.py::test_reach_out_user_without_sender_id_stays_backward_compat -v`

Expected: first FAILS with `payload.get("sender_id") == "99999"` (None != "99999"); second PASSES already.

- [ ] **Step 3: Modify the `reach_out_user` handler**

In `db/17_functions_subconscious_observations.sql`, replace the `WHEN 'reach_out_user'` block (lines 1208–1219):

```sql
        WHEN 'reach_out_user' THEN
            queued_call := build_outbox_message(
                'user',
                jsonb_build_object(
                    'message',     p_params->>'message',
                    'intent',      p_params->>'intent',
                    'sender_id',   NULLIF(p_params->>'sender_id', ''),
                    'heartbeat_id', p_heartbeat_id
                )
            );
            outbox_messages := outbox_messages || jsonb_build_array(queued_call);
            result := jsonb_build_object('queued', true, 'outbox_message', queued_call);
            PERFORM satisfy_drive('connection', 0.3);
```

- [ ] **Step 4: Re-apply to test DB**

```bash
docker exec -i hexis_brain psql -U hexis_user -d hexis_memory -v ON_ERROR_STOP=1 -f - < db/17_functions_subconscious_observations.sql
```

Expected: `CREATE FUNCTION` lines, no errors.

- [ ] **Step 5: Run tests, verify pass**

Run: `pytest tests/db/test_heartbeat_reach_out_sender.py -v`

Expected: all three tests PASS.

- [ ] **Step 6: Commit**

```bash
git add db/17_functions_subconscious_observations.sql tests/db/test_heartbeat_reach_out_sender.py
git commit -m "feat(heartbeat): thread sender_id into reach_out_user outbox payload"
```

---

## Task 4: Outbox routing integration test

**Files:**
- Create: `tests/services/test_outbox_reach_out_routing.py`

This verifies that a synthetic outbox message carrying `sender_id` is routed by `channels/outbox.py:_deliver_last_active` to that user's most-recent `channel_session`, not the globally most-recent one. No production code change in `channels/outbox.py` — this test pins the existing behavior so a future regression there gets caught.

- [ ] **Step 1: Write the test**

Create `tests/services/test_outbox_reach_out_routing.py`:

```python
import json
import pytest
from unittest.mock import AsyncMock

from channels.outbox import ChannelOutboxConsumer

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


async def test_payload_sender_id_routes_to_that_users_session(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute(
                """
                INSERT INTO channel_sessions (channel_type, channel_id, sender_id, last_active)
                VALUES
                    ('telegram', 'AAA', 'alice', CURRENT_TIMESTAMP - INTERVAL '1 hour'),
                    ('telegram', 'BBB', 'bob',   CURRENT_TIMESTAMP - INTERVAL '10 seconds')
                ON CONFLICT DO NOTHING
                """,
            )

            manager = AsyncMock()
            manager.send = AsyncMock(return_value="msg-1")
            consumer = ChannelOutboxConsumer(manager, db_pool)

            body = {
                "kind": "user",
                "agent": "memory",  # matches the default test DB persona derivation
                "payload": {
                    "message": "Hey Alice",
                    "sender_id": "alice",
                },
            }
            await consumer._process_message(body)

            # Alice should win, despite Bob being globally most-recent
            assert manager.send.await_count == 1
            ch_type, ch_id, content = (
                manager.send.await_args.args[0],
                manager.send.await_args.args[1],
                manager.send.await_args.args[2],
            )
            assert ch_type == "telegram"
            assert ch_id == "AAA"
            assert content == "Hey Alice"

            await conn.execute("ROLLBACK")
```

- [ ] **Step 2: Run test, verify pass**

Run: `pytest tests/services/test_outbox_reach_out_routing.py -v`

Expected: PASS (this exercises existing behavior in `_deliver_last_active`).

If `ChannelOutboxConsumer.__init__` signature has drifted, fix the test's constructor call to match — do not modify production code.

- [ ] **Step 3: Commit**

```bash
git add tests/services/test_outbox_reach_out_routing.py
git commit -m "test(outbox): pin sender_id routing to per-user last_active"
```

---

## Task 5: Update heartbeat prompts for selectivity + multi-recipient

**Files:**
- Modify: `services/prompts/rlm_heartbeat_system.md` (Action Types section + Guidelines)
- Modify: `services/prompts/heartbeat_system.md` (Action list + Guidelines)

- [ ] **Step 1: Edit `services/prompts/rlm_heartbeat_system.md`**

In the **Action Types** section (around line 100), replace the existing **Expensive** bullet:

```markdown
- **Expensive (4-7)**: inquire_shallow, inquire_deep, reach_out_user, reach_out_public, reflect_on_relationship
```

with:

```markdown
- **Expensive (4-7)**: inquire_shallow, inquire_deep, reach_out_user, reach_out_public, reflect_on_relationship

`reach_out_user` params: `{sender_id: str, message: str, intent?: str}`. `sender_id` is REQUIRED — choose a specific person from `context["active_senders"]` (or another partner you have memories with). You MAY emit multiple `reach_out_user` actions in one cycle, each targeting a different `sender_id` with a message tailored to your relationship with that person. Each recipient costs 5 energy.
```

In the **Guidelines** section (around line 113), replace:

```markdown
- Reaching out to the user is expensive (5 energy). Only do it when meaningful.
```

with:

```markdown
- Reaching out is expensive (5 energy per recipient). Only do it when meaningful. Address a specific person — examine `context["active_senders"]` and your sender-scoped memories before deciding. If multiple relationships are alive in you right now, you may reach more than one in this cycle, each with its own tailored message; do not blast generic text.
```

- [ ] **Step 2: Edit `services/prompts/heartbeat_system.md`**

In the action list (line 12), keep the enum entry but append guidance below the existing **Guidelines** list:

```markdown
- For `reach_out_user`, include `sender_id` in params to target a specific person. You may emit multiple `reach_out_user` actions in one heartbeat, each with a distinct `sender_id` + tailored `message`. Each recipient costs 5 energy.
```

- [ ] **Step 3: Live-apply prompts (no rebuild needed)**

Prompts are read from `services/prompts/` on each turn — no container restart needed. Skip ahead to commit.

- [ ] **Step 4: Commit**

```bash
git add services/prompts/rlm_heartbeat_system.md services/prompts/heartbeat_system.md
git commit -m "feat(prompts): heartbeat reach-out picks specific sender_id, multi-recipient"
```

---

## Task 6: Fleet live-migration script

**Files:**
- Create: `.local-notes/migrations/2026-05-26-heartbeat-tailored-reach-out/migrate.sql`
- Create: `.local-notes/migrations/2026-05-26-heartbeat-tailored-reach-out/README.md`

Per CLAUDE.md "Live `db/*.sql` migration" rules: re-apply 09 and 17 only (CREATE OR REPLACE = idempotent; no ALTER TABLE, no new index). Do **not** re-apply 01 (indices) or 00 (tables) — would error on existing objects.

- [ ] **Step 1: Create the migration SQL**

`.local-notes/migrations/2026-05-26-heartbeat-tailored-reach-out/migrate.sql`:

```sql
-- 2026-05-26 heartbeat tailored reach-out
-- Re-applies db/09_functions_context.sql (adds get_active_senders_context + active_senders key
-- in gather_turn_context) and db/17_functions_subconscious_observations.sql (threads sender_id
-- into reach_out_user outbox payload). CREATE OR REPLACE only; safe to re-run.

\set ON_ERROR_STOP on
\ir ../../../db/09_functions_context.sql
\ir ../../../db/17_functions_subconscious_observations.sql

SELECT 'active_senders present in gather_turn_context' AS check_,
       (gather_turn_context() ? 'active_senders') AS ok;
```

- [ ] **Step 2: Create the runbook**

`.local-notes/migrations/2026-05-26-heartbeat-tailored-reach-out/README.md`:

````markdown
# 2026-05-26 — heartbeat tailored reach-out, fleet migration

Re-applies idempotent `CREATE OR REPLACE FUNCTION` for the two touched files
to every `hexis_<persona>` database. No `down -v`; no compose recreate.

## Apply

```powershell
$dbs = docker exec hexis_brain psql -U hexis_user -d postgres -tAc `
  "SELECT datname FROM pg_database WHERE datname LIKE 'hexis_%' ORDER BY 1"
foreach ($db in ($dbs -split "`n" | Where-Object { $_ })) {
  Write-Host ">>> $db"
  docker exec -i hexis_brain psql -U hexis_user -d $db -v ON_ERROR_STOP=1 -f - `
    < db/09_functions_context.sql
  docker exec -i hexis_brain psql -U hexis_user -d $db -v ON_ERROR_STOP=1 -f - `
    < db/17_functions_subconscious_observations.sql
}
```

## Verify per DB

```sql
SELECT gather_turn_context() ? 'active_senders' AS has_active_senders;
-- expected: t

SELECT pg_get_function_identity_arguments('get_active_senders_context'::regproc);
-- expected: p_limit integer DEFAULT 8, p_recency_days integer DEFAULT 7

-- Dry-run the action handler in a rolled-back tx
BEGIN;
SELECT apply_heartbeat_action(
    'reach_out_user',
    jsonb_build_object('sender_id', '12345', 'message', 'test', 'intent', 'probe'),
    gen_random_uuid()
);
ROLLBACK;
-- expected: payload.sender_id = '12345' in outbox_message
```

## No worker restart required

Functions are read fresh per call. Prompts in `services/prompts/` are read
per turn. The two function-only changes propagate without bouncing any
container.

## Companion: ACID-for-cognition invariant intact

Outbox payloads now carry `sender_id` but the queue-isolation contract from
`project_outbox_per_persona_queues` is unchanged — `build_outbox_message`
still stamps `agent`, consumer still gates by it.
````

- [ ] **Step 3: Dry-run the script against one persona DB**

Pick the most active one and verify the SQL applies cleanly:

```powershell
docker exec hexis_brain psql -U hexis_user -d hexis_memory -v ON_ERROR_STOP=1 -f - < db/09_functions_context.sql
docker exec hexis_brain psql -U hexis_user -d hexis_memory -v ON_ERROR_STOP=1 -f - < db/17_functions_subconscious_observations.sql
docker exec hexis_brain psql -U hexis_user -d hexis_memory -c "SELECT gather_turn_context() ? 'active_senders'"
```

Expected: final query returns `t`.

- [ ] **Step 4: Apply to the rest of the fleet**

Follow the PowerShell loop in the runbook. Each persona DB should print the function recreations and end clean.

- [ ] **Step 5: Commit (migration artifacts only — code already committed in earlier tasks)**

```bash
git add .local-notes/migrations/2026-05-26-heartbeat-tailored-reach-out/
git commit -m "docs(migrations): 2026-05-26 heartbeat tailored reach-out runbook"
```

---

## Task 7: End-to-end smoke

**Files:** none modified — verification only.

- [ ] **Step 1: Pick a low-traffic test persona** (e.g. `monika` or a designated probe persona). Confirm it has at least two recent `channel_sessions` rows from different `sender_id`s in the last 7 days.

```bash
docker exec hexis_brain psql -U hexis_user -d hexis_<persona> -c \
  "SELECT sender_id, channel_id, last_active FROM channel_sessions WHERE last_active > CURRENT_TIMESTAMP - INTERVAL '7 days' ORDER BY last_active DESC LIMIT 10"
```

Expected: ≥2 distinct sender_id values.

- [ ] **Step 2: Watch the persona's heartbeat worker logs**

```bash
docker logs -f hexis_<persona>_heartbeat_worker
```

- [ ] **Step 3: Force-trigger or wait for one heartbeat cycle**

Wait until `should_run_heartbeat()` fires naturally (interval + jitter window per `project_heartbeat_jitter_newchars_activated`). Do NOT manually advance `next_heartbeat_at` — the wall-clock-drift trap in `BUG-heartbeat-clock-drift-consumer-wedge.md` warns against trusting forced timing.

- [ ] **Step 4: Inspect emitted outbox messages**

After the cycle, query the persona's outbox queue via RabbitMQ management API or check the consumer log:

```bash
docker logs hexis_<persona>_channel_worker --tail 50 | grep -E "outbox|reach_out|deliver"
```

Expected on success: lines showing `delivery_mode=last_active sender_id=<X>` and a Telegram `send` to that user's chat — not the globally most-recent session. If the persona emitted multiple `reach_out_user` actions, expect multiple sends to different chats.

- [ ] **Step 5: Check episodic memory for the reach-out record**

```sql
SELECT id, created_at, sender_id, left(content, 120)
FROM memories
WHERE type = 'episodic'
  AND source_attribution->>'kind' = 'heartbeat'
  AND content ILIKE '%reach_out%'
ORDER BY created_at DESC
LIMIT 5;
```

Expected: the heartbeat episodic carries the action with the chosen `sender_id`(s).

- [ ] **Step 6: Document the smoke result**

Append a note to `.local-notes/migrations/2026-05-26-heartbeat-tailored-reach-out/README.md` under a `## Smoke result` section: persona, datetime, sender_ids reached, observations.

- [ ] **Step 7: Commit smoke note**

```bash
git add .local-notes/migrations/2026-05-26-heartbeat-tailored-reach-out/README.md
git commit -m "docs(migrations): smoke result for tailored heartbeat reach-out"
```

---

## Deferred (not in this plan)

- **Group chats.** `reach_out_user` resolves via `channel_sessions.sender_id`; in a Telegram group, `sender_id` is the individual user and `channel_id` is the group. Reaching a group requires either `delivery_mode='direct'` + `target_channel`/`target_id`, or a new `reach_out_chat` action keyed on `channel_id`. Spec separately if demand justifies.
- **Sender-scoped memory snippets in `get_active_senders_context()`.** Currently exposes `memory_count` only. A future enhancement could surface a short topic hint per sender (top-1 `fast_recall` with `p_current_sender`) to help the persona's REPL pick targets without an extra search. Skipped here to keep the context payload small (`project_sable_onboard_outcome` 7KB anchor ceiling pressure).
- **Energy pre-check on multi-recipient cycles.** Today the persona is trusted to count energy via `energy_remaining()`. If observed behavior shows over-spending (>4 reach-outs in one cycle on a single 20-energy cap), add a hard cap in `apply_heartbeat_action` that no-ops `reach_out_user` once energy drops below 5.
- **Confidentiality enforcement.** `format_context_for_prompt(..., current_sender=...)` already tags cross-partner memories as `[confidential — from your session with another client]` per CLAUDE.md "Sender-scoped memory". The new flow doesn't change that contract; it just chooses which `current_sender` is in scope per reach-out. No code change needed, but smoke-test a probe that confirms cross-partner content does not leak in tailored messages.

---

## Self-Review

**Spec coverage** — the conversation's design points map as:

| Design point | Task |
|---|---|
| Heartbeat picks specific person, not globally most-recent | 3, 5 |
| Multi-recipient in one cycle, tailored per recipient | 3, 5 |
| Selectivity = emergent from drives/relationships/recall | 2, 5 |
| Cost: one LLM call emits N actions (no N× LLM) | 5 (prompt nudge); architectural, no separate task |
| Energy gate: 5 per recipient | 3, 5 (cost rule already in `00_tables.sql:624` — `heartbeat.cost_reach_out_user=5`; no change) |
| Channel-side routing already understands `sender_id` | 4 (pin test) |
| Live migration, no `down -v` | 6 |
| Smoke + per-DB verification | 6, 7 |
| Group chats | Deferred section |

**Placeholder scan** — all SQL bodies, prompt edits, test bodies, and shell commands are concrete. No "TBD"/"appropriate"/"similar to". The runbook references `docker exec`/`psql` with real flags.

**Type consistency** — `sender_id` is `TEXT` throughout (matches `memories.sender_id`, `channel_sessions.sender_id`, payload string). Action params key is `sender_id` everywhere (tests, SQL handler, prompt docs, outbox consumer). `get_active_senders_context(p_limit, p_recency_days)` — two int args, default 8 / 7 — matches the test and the call site in `gather_turn_context()`.
