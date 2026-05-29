# All-Latent Reach-Out Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the deterministic reach-out vetoes (per-sender cooldown + quiet-hours) with latent LLM judgment, giving the character temporal self-awareness and observational sender-rhythm signal so it decides its own reach-out cadence.

**Architecture:** Postgres is the brain — logic lives in `db/*.sql` functions, loaded via `CREATE OR REPLACE` (live-bounceable, no `down -v`). The heartbeat LLM emits a `reach_out_user` action; today two DB gates can veto it. We strip both gates, repurpose the per-sender log as telemetry the LLM reads, surface new awareness fields in the context builders, and move all restraint into the prompt. A dormant config brake remains as a runaway-loop circuit breaker.

**Tech Stack:** PostgreSQL (PL/pgSQL), Apache AGE, pytest + pytest-asyncio (session loop scope, transaction-rollback isolation via the `db_pool` fixture), Docker Compose.

**Spec:** `docs/superpowers/specs/2026-05-30-all-latent-reach-out-design.md`

**Branch:** `feat/all-latent-reach-out` (already created off `home-rig-local`; spec committed at `38b6177`). Private local-patch line — NOT for upstream `main`.

---

## Preconditions

- The `hexis_brain` Postgres container must be up with a test database whose schema is loaded from `db/*.sql`. Full fleet is NOT required — a single brain DB suffices (DB-function tests use transaction rollback). The fresh `hexis_memory` DB created after the 2026-05-29 reinit works as a test target, or spin a throwaway per `.local-notes/guidelines/schema-migration.md`.
- Tests run with: `pytest tests/db/test_heartbeat_reach_out_sender.py -q` (Docker services up).
- **No manual SQL reload needed.** `tests/conftest.py::temp_test_db` (module-scoped, autouse) creates a fresh `tmp_test_<uuid>` DB per module and loads **all working-tree `db/*.sql`** into it before tests run. Editing a `db/*.sql` file and re-running pytest is sufficient — the schema is rebuilt from the working tree. (Ignore any "reload via `psql -f`" phrasing in older task steps below; just edit the file and run pytest.)
- **Base branch:** `feat/all-latent-reach-out` is now rebased **onto `3c2ffea`** (lineage `dd5108d ← 3c2ffea ← spec ← plan`), so all `3c2ffea` cooldown plumbing (`can_reach_out_sender`, `record_reach_out_sender`, `reach_out_sender_log`, the `db/90` view column, the `db/00` seed, and the `heartbeat_state_update_trigger` non-NULL-merge fix) is **already present**. Execution *transforms* this (gate → telemetry), it does not rebuild it.
- **Task 0 is OBSOLETE** — the trigger fix it ported is already in `3c2ffea`. Skip it; start at Task 1.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `db/07_functions_heartbeat.sql` | Heartbeat helpers | Delete `can_reach_out_sender`; rewrite `record_reach_out_sender` to maintain `{last_at, unanswered_count}` with reset-on-reply |
| `db/17_functions_subconscious_observations.sql` | `execute_heartbeat_action` / `reach_out_user` handler | Strip both veto branches; add dormant `reach_out_max_unanswered` brake + decision logging |
| `db/09_functions_context.sql` | Context builders | `get_environment_snapshot` (+`agent_local_time`/`agent_local_hour`); `get_active_senders_context` (+signal fields) |
| `db/00_tables.sql` | Config seed defaults | Retire `heartbeat.user_contact_cooldown_hours` seed; add `heartbeat.reach_out_max_unanswered` seed `0` |
| `tests/db/test_heartbeat_reach_out_sender.py` | Test suite | Rewrite veto-asserting tests → assert no-veto + telemetry + new signal fields + dormant brake |
| `services/prompts/rlm_heartbeat_system.md` | RLM heartbeat prompt | Rewrite reach-out guidance: read-the-room restraint, new signals, license `update_trust` |
| `services/prompts/heartbeat_agentic.md` | Agentic heartbeat prompt | Same rewrite, aligned |
| `.local-notes/migrations/2026-05-30-all-latent-reach-out/migrate.sql` + `README.md` | Live-DB migration | Reload functions + seed config + (optional) migrate existing log entries to object shape |

---

## Task 0: Port the `heartbeat_state_update_trigger` non-NULL-merge fix

**Why:** this branch is off `home-rig-local`, which predates `3c2ffea`. That commit's
fix to `heartbeat_state_update_trigger` (merge only non-NULL columns instead of
rebuilding the whole state object) is the one piece of `3c2ffea` we keep. Without it,
partial writes through the `heartbeat_state` view clobber unrelated keys — including
`reach_out_sender_log`. Port it before anything touches the log.

**Files:**
- Modify: `db/07_functions_heartbeat.sql` (`heartbeat_state_update_trigger`, ~`:540`)

- [ ] **Step 1: View the canonical fixed trigger**

Run: `git show 3c2ffea:db/07_functions_heartbeat.sql | sed -n '500,560p'`
Expected: the trigger body with per-column `IF NEW.<col> IS NOT NULL THEN merged := jsonb_set(...)` lines, including the `reach_out_sender_log` line at `:544`.

- [ ] **Step 2: Apply the same trigger body to this branch's `db/07_functions_heartbeat.sql`**

Replace this branch's `heartbeat_state_update_trigger` function with the `3c2ffea` version verbatim (it is a `CREATE OR REPLACE`, idempotent). Confirm it includes the `reach_out_sender_log` non-NULL-merge line.

- [ ] **Step 3: Reload + sanity-check no clobber**

Run: `docker exec -i hexis_brain psql -U hexis_user -d <testdb> -f - < db/07_functions_heartbeat.sql`
Then a quick manual check (partial update preserves a sibling key):
```sql
UPDATE state SET value = jsonb_set(COALESCE(value,'{}'::jsonb), '{reach_out_sender_log}', '{"keepme":1}'::jsonb) WHERE key='heartbeat_state';
UPDATE heartbeat_state SET current_energy = current_energy WHERE id = 1;  -- partial write via view
SELECT value->'reach_out_sender_log'->'keepme' FROM state WHERE key='heartbeat_state';  -- expect 1, not gone
```

- [ ] **Step 4: Commit**

```bash
git add db/07_functions_heartbeat.sql
git commit -m "fix(heartbeat): port non-NULL-merge state trigger from 3c2ffea"
```

---

## Task 1: Repurpose the sender log as telemetry (`record_reach_out_sender`)

**Files:**
- Modify: `db/07_functions_heartbeat.sql` (function `record_reach_out_sender`, ~`:821`; delete `can_reach_out_sender`, ~`:791`)
- Test: `tests/db/test_heartbeat_reach_out_sender.py`

The log entry per sender becomes `{ "last_at": <timestamptz>, "unanswered_count": <int> }`. On each call: if `last_user_contact > stored last_at` (user replied since our last reach-out) the count restarts at 1, else stored count + 1; `last_at` set to now.

- [ ] **Step 1: Write the failing tests**

Replace the old cooldown tests. Add to `tests/db/test_heartbeat_reach_out_sender.py`:

```python
async def test_record_reach_out_sender_initializes_log_entry(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute("SELECT record_reach_out_sender('s1')")
            raw = await conn.fetchval(
                "SELECT value->'reach_out_sender_log'->'s1' FROM state WHERE key='heartbeat_state'"
            )
            entry = raw if isinstance(raw, dict) else json.loads(raw)
            assert entry["unanswered_count"] == 1
            assert entry["last_at"] is not None


async def test_record_reach_out_sender_increments_when_unanswered(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            # ensure no intervening user contact
            await conn.execute("UPDATE heartbeat_state SET last_user_contact = NULL WHERE id=1")
            await conn.execute("SELECT record_reach_out_sender('s2')")
            await conn.execute("SELECT record_reach_out_sender('s2')")
            raw = await conn.fetchval(
                "SELECT value->'reach_out_sender_log'->'s2' FROM state WHERE key='heartbeat_state'"
            )
            entry = raw if isinstance(raw, dict) else json.loads(raw)
            assert entry["unanswered_count"] == 2


async def test_record_reach_out_sender_resets_after_user_reply(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute("UPDATE heartbeat_state SET last_user_contact = NULL WHERE id=1")
            await conn.execute("SELECT record_reach_out_sender('s3')")
            # user replies now (after our reach-out)
            await conn.execute("UPDATE heartbeat_state SET last_user_contact = CURRENT_TIMESTAMP WHERE id=1")
            await conn.execute("SELECT record_reach_out_sender('s3')")
            raw = await conn.fetchval(
                "SELECT value->'reach_out_sender_log'->'s3' FROM state WHERE key='heartbeat_state'"
            )
            entry = raw if isinstance(raw, dict) else json.loads(raw)
            assert entry["unanswered_count"] == 1, "reply since last_at must restart the streak at 1"


async def test_can_reach_out_sender_is_removed(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            exists = await conn.fetchval(
                "SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'can_reach_out_sender')"
            )
            assert exists is False, "can_reach_out_sender must be dropped (no longer a gate)"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pytest tests/db/test_heartbeat_reach_out_sender.py -k "record_reach_out_sender or can_reach_out_sender_is_removed" -q`
Expected: FAIL — old `record_reach_out_sender` stores a bare timestamp (no `unanswered_count`); `can_reach_out_sender` still exists.

- [ ] **Step 3: Rewrite the function + drop the gate**

In `db/07_functions_heartbeat.sql`, delete the entire `CREATE OR REPLACE FUNCTION can_reach_out_sender(...)` block and add a `DROP FUNCTION IF EXISTS can_reach_out_sender(TEXT);` at that location. Replace `record_reach_out_sender` with:

```sql
DROP FUNCTION IF EXISTS can_reach_out_sender(TEXT);

CREATE OR REPLACE FUNCTION record_reach_out_sender(p_sender_id TEXT)
RETURNS VOID AS $$
DECLARE
    safe_sender  TEXT := COALESCE(p_sender_id, '');
    last_contact TIMESTAMPTZ;
    prior        JSONB;
    prior_at     TIMESTAMPTZ;
    prior_count  INT;
    new_count    INT;
BEGIN
    IF safe_sender = '' THEN RETURN; END IF;

    SELECT last_user_contact INTO last_contact FROM heartbeat_state WHERE id = 1;

    SELECT value->'reach_out_sender_log'->safe_sender
      INTO prior
      FROM state WHERE key = 'heartbeat_state';

    prior_at    := (prior->>'last_at')::timestamptz;
    prior_count := COALESCE((prior->>'unanswered_count')::int, 0);

    -- user replied since our previous reach-out -> streak restarts; else continue it
    IF prior_at IS NULL OR (last_contact IS NOT NULL AND last_contact > prior_at) THEN
        new_count := 1;
    ELSE
        new_count := prior_count + 1;
    END IF;

    UPDATE state
    SET value = jsonb_set(
                jsonb_set(value, ARRAY['reach_out_sender_log'],
                          COALESCE(value->'reach_out_sender_log', '{}'::jsonb)),
                ARRAY['reach_out_sender_log', safe_sender],
                jsonb_build_object('last_at', to_jsonb(CURRENT_TIMESTAMP),
                                   'unanswered_count', to_jsonb(new_count))
            ),
        updated_at = CURRENT_TIMESTAMP
    WHERE key = 'heartbeat_state';
END;
$$ LANGUAGE plpgsql;
```

- [ ] **Step 4: Reload + run tests to verify they pass**

Run: `docker exec -i hexis_brain psql -U hexis_user -d <testdb> -f - < db/07_functions_heartbeat.sql`
Then: `pytest tests/db/test_heartbeat_reach_out_sender.py -k "record_reach_out_sender or can_reach_out_sender_is_removed" -q`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add db/07_functions_heartbeat.sql tests/db/test_heartbeat_reach_out_sender.py
git commit -m "feat(heartbeat): sender log becomes telemetry, drop can_reach_out_sender gate"
```

---

## Task 2: Strip both vetoes from the `reach_out_user` handler

**Files:**
- Modify: `db/17_functions_subconscious_observations.sql` (`execute_heartbeat_action`, `WHEN 'reach_out_user'` branch, ~`:1208`)
- Test: `tests/db/test_heartbeat_reach_out_sender.py`

Remove the `is_sender_quiet` veto branch and the (now-deleted) `can_reach_out_sender` veto branch and their `update_energy(action_cost)` refunds. The handler reduces to: build the outbox message, satisfy the connection drive, record telemetry.

- [ ] **Step 1: Write the failing tests**

```python
async def test_reach_out_not_blocked_by_prior_unanswered(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute("UPDATE heartbeat_state SET last_user_contact = NULL WHERE id=1")
            await conn.execute("SELECT record_reach_out_sender('p1')")  # already 1 unanswered
            raw = await conn.fetchval(
                """
                SELECT execute_heartbeat_action(
                    gen_random_uuid(), 'reach_out_user',
                    jsonb_build_object('sender_id','p1','message','still thinking of you','intent','check_in')
                )
                """
            )
            res = raw if isinstance(raw, dict) else json.loads(raw)
            assert res["result"].get("queued") is True, "prior unanswered reach-out must NOT veto a new one"


async def test_reach_out_not_blocked_during_quiet_hours(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            cur_utc_hour = await conn.fetchval(
                "SELECT extract(hour FROM CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::INT"
            )
            offset = (23 - cur_utc_hour) % 24
            tz_name = f"Etc/GMT{('+' if offset == 0 else '-')}{offset if offset else 0}"
            await conn.execute("SELECT set_config('channel.sender.q9.timezone', $1::jsonb)", f'"{tz_name}"')
            await conn.execute("SELECT set_config('channel.sender.q9.quiet_start_hour', '22'::jsonb)")
            await conn.execute("SELECT set_config('channel.sender.q9.quiet_end_hour', '6'::jsonb)")
            assert await conn.fetchval("SELECT is_sender_quiet('q9')") is True
            raw = await conn.fetchval(
                """
                SELECT execute_heartbeat_action(
                    gen_random_uuid(), 'reach_out_user',
                    jsonb_build_object('sender_id','q9','message','late night thought','intent','check_in')
                )
                """
            )
            res = raw if isinstance(raw, dict) else json.loads(raw)
            assert res["result"].get("queued") is True, "quiet hours must NOT veto; it is context only"
```

Also DELETE the now-obsolete veto-asserting tests if any remain referencing `reason == 'recipient_quiet_hours'` or `reason == 'sender_cooldown'`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `pytest tests/db/test_heartbeat_reach_out_sender.py -k "not_blocked" -q`
Expected: FAIL — handler currently returns `queued: false, reason: 'sender_cooldown'`/`'recipient_quiet_hours'`.

- [ ] **Step 3: Strip the veto branches**

In `db/17_functions_subconscious_observations.sql`, replace the entire `WHEN 'reach_out_user' THEN` block body so the gating `IF ... is_sender_quiet ... ELSIF ... NOT can_reach_out_sender ... ELSE` collapses to just the send path:

```sql
        WHEN 'reach_out_user' THEN
            DECLARE
                target_sender TEXT := NULLIF(p_params->>'sender_id', '');
            BEGIN
                queued_call := build_outbox_message(
                    'user',
                    jsonb_build_object(
                        'message',     p_params->>'message',
                        'intent',      p_params->>'intent',
                        'sender_id',   target_sender,
                        'heartbeat_id', p_heartbeat_id
                    )
                );
                outbox_messages := outbox_messages || jsonb_build_array(queued_call);
                result := jsonb_build_object('queued', true, 'outbox_message', queued_call);
                PERFORM satisfy_drive('connection', 0.3);
                PERFORM record_reach_out_sender(target_sender);
            END;
```

(The dormant brake is added in Task 5 — leave this minimal for now.)

- [ ] **Step 4: Reload + run tests to verify they pass**

Run: `docker exec -i hexis_brain psql -U hexis_user -d <testdb> -f - < db/17_functions_subconscious_observations.sql`
Then: `pytest tests/db/test_heartbeat_reach_out_sender.py -k "not_blocked or carries_sender_id or backward_compat" -q`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add db/17_functions_subconscious_observations.sql tests/db/test_heartbeat_reach_out_sender.py
git commit -m "feat(heartbeat): strip cooldown + quiet-hours vetoes from reach_out_user"
```

---

## Task 3: Self temporal awareness (`get_environment_snapshot`)

**Files:**
- Modify: `db/09_functions_context.sql` (`get_environment_snapshot`, `:5`)
- Test: `tests/db/test_heartbeat_reach_out_sender.py`

Reuse the existing `heartbeat.timezone` config (fallback UTC). Add `agent_local_time` + `agent_local_hour`.

- [ ] **Step 1: Write the failing test**

```python
async def test_environment_snapshot_exposes_agent_local_time(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute("SELECT set_config('heartbeat.timezone', '\"Asia/Singapore\"'::jsonb)")
            raw = await conn.fetchval("SELECT get_environment_snapshot()")
            snap = raw if isinstance(raw, dict) else json.loads(raw)
            assert "agent_local_time" in snap
            assert "agent_local_hour" in snap
            # Singapore is UTC+8; local hour must equal (utc hour + 8) mod 24
            utc_hour = await conn.fetchval("SELECT extract(hour FROM CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::INT")
            assert snap["agent_local_hour"] == (utc_hour + 8) % 24
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/db/test_heartbeat_reach_out_sender.py -k environment_snapshot -q`
Expected: FAIL — `agent_local_time` key absent.

- [ ] **Step 3: Add the fields**

In `db/09_functions_context.sql`, replace the `get_environment_snapshot` body's `RETURN jsonb_build_object(...)` to add the two fields (keep all existing keys):

```sql
CREATE OR REPLACE FUNCTION get_environment_snapshot()
RETURNS JSONB AS $$
DECLARE
    last_user TIMESTAMPTZ;
    agent_tz  TEXT := COALESCE(get_config_text('heartbeat.timezone'), 'UTC');
BEGIN
    SELECT last_user_contact INTO last_user FROM heartbeat_state WHERE id = 1;

    RETURN jsonb_build_object(
        'timestamp', CURRENT_TIMESTAMP,
        'agent_timezone', agent_tz,
        'agent_local_time', (CURRENT_TIMESTAMP AT TIME ZONE agent_tz),
        'agent_local_hour', extract(hour FROM (CURRENT_TIMESTAMP AT TIME ZONE agent_tz))::INT,
        'time_since_user_hours', CASE
            WHEN last_user IS NULL THEN NULL
            ELSE EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - last_user)) / 3600
        END,
        'pending_events', 0,
        'day_of_week', EXTRACT(DOW FROM CURRENT_TIMESTAMP),
        'hour_of_day', EXTRACT(HOUR FROM CURRENT_TIMESTAMP)
    );
END;
$$ LANGUAGE plpgsql;
```

Note: confirm the helper name is `get_config_text` (grep `db/*.sql`); if the codebase uses `get_config(...)->>0` or similar, match that. The existing `resolve_sender_timezone` reads `heartbeat.timezone` — mirror exactly how it does so.

- [ ] **Step 4: Reload + run test to verify it passes**

Run: `docker exec -i hexis_brain psql -U hexis_user -d <testdb> -f - < db/09_functions_context.sql`
Then: `pytest tests/db/test_heartbeat_reach_out_sender.py -k environment_snapshot -q`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add db/09_functions_context.sql tests/db/test_heartbeat_reach_out_sender.py
git commit -m "feat(heartbeat): agent local-time awareness in environment snapshot"
```

---

## Task 4: Observational sender signal (`get_active_senders_context`)

**Files:**
- Modify: `db/09_functions_context.sql` (`get_active_senders_context`, `:314`)
- Test: `tests/db/test_heartbeat_reach_out_sender.py`

Add per-sender: `hours_since_my_last_reach_out`, `unanswered_reach_out_count` (reconciled with `replied_since`), `replied_since` (bool), `recent_user_message_times` (last 5 user message timestamps). Keep all existing fields.

- [ ] **Step 1: Write the failing test**

```python
async def test_active_senders_context_exposes_reach_out_signal(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute(
                """
                INSERT INTO channel_sessions (channel_type, channel_id, sender_id, last_active)
                VALUES ('telegram', 'sig1', 'sig1', CURRENT_TIMESTAMP - INTERVAL '10 minutes')
                """
            )
            await conn.execute("UPDATE heartbeat_state SET last_user_contact = NULL WHERE id=1")
            await conn.execute("SELECT record_reach_out_sender('sig1')")  # 1 unanswered

            raw = await conn.fetchval("SELECT get_active_senders_context(5, 7)")
            senders = raw if isinstance(raw, list) else json.loads(raw)
            row = next(s for s in senders if s["sender_id"] == "sig1")
            assert row["unanswered_reach_out_count"] == 1
            assert row["replied_since"] is False
            assert row["hours_since_my_last_reach_out"] is not None
            assert "recent_user_message_times" in row


async def test_active_senders_count_reconciles_to_zero_after_reply(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute(
                """
                INSERT INTO channel_sessions (channel_type, channel_id, sender_id, last_active)
                VALUES ('telegram', 'sig2', 'sig2', CURRENT_TIMESTAMP - INTERVAL '5 minutes')
                """
            )
            await conn.execute("UPDATE heartbeat_state SET last_user_contact = NULL WHERE id=1")
            await conn.execute("SELECT record_reach_out_sender('sig2')")
            # user replies AFTER the reach-out (persisted count still 1, but display must reconcile)
            await conn.execute("UPDATE heartbeat_state SET last_user_contact = CURRENT_TIMESTAMP WHERE id=1")
            raw = await conn.fetchval("SELECT get_active_senders_context(5, 7)")
            senders = raw if isinstance(raw, list) else json.loads(raw)
            row = next(s for s in senders if s["sender_id"] == "sig2")
            assert row["replied_since"] is True
            assert row["unanswered_reach_out_count"] == 0, "displayed count must reconcile to 0 after a reply"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/db/test_heartbeat_reach_out_sender.py -k "active_senders_context_exposes or reconciles_to_zero" -q`
Expected: FAIL — new keys absent.

- [ ] **Step 3: Add the signal columns**

In `db/09_functions_context.sql`, extend the inner `SELECT DISTINCT ON (cs.sender_id)` select-list of `get_active_senders_context` with these computed columns (alongside the existing ones). Add a CTE/scalar reading the per-sender log entry:

```sql
                -- per-sender reach-out telemetry (from heartbeat_state.reach_out_sender_log)
                (
                    SELECT (s.value->'reach_out_sender_log'->cs.sender_id->>'last_at')::timestamptz
                    FROM state s WHERE s.key = 'heartbeat_state'
                ) AS my_last_reach_out_at,
                (
                    SELECT EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP -
                        (s.value->'reach_out_sender_log'->cs.sender_id->>'last_at')::timestamptz)) / 3600
                    FROM state s WHERE s.key = 'heartbeat_state'
                ) AS hours_since_my_last_reach_out,
                (
                    SELECT (hs.last_user_contact IS NOT NULL
                        AND hs.last_user_contact > (s.value->'reach_out_sender_log'->cs.sender_id->>'last_at')::timestamptz)
                    FROM state s, heartbeat_state hs
                    WHERE s.key = 'heartbeat_state' AND hs.id = 1
                ) AS replied_since,
                (
                    -- reconciled streak: 0 if replied_since, else stored count
                    SELECT CASE
                        WHEN (hs.last_user_contact IS NOT NULL
                              AND hs.last_user_contact > (s.value->'reach_out_sender_log'->cs.sender_id->>'last_at')::timestamptz)
                        THEN 0
                        ELSE COALESCE((s.value->'reach_out_sender_log'->cs.sender_id->>'unanswered_count')::int, 0)
                    END
                    FROM state s, heartbeat_state hs
                    WHERE s.key = 'heartbeat_state' AND hs.id = 1
                ) AS unanswered_reach_out_count,
                (
                    SELECT COALESCE(jsonb_agg(t.created_at ORDER BY t.created_at DESC), '[]'::jsonb)
                    FROM (
                        SELECT m.created_at FROM memories m
                        WHERE m.sender_id = cs.sender_id AND m.status = 'active'
                        ORDER BY m.created_at DESC LIMIT 5
                    ) t
                ) AS recent_user_message_times,
```

Note: `replied_since` and `unanswered_reach_out_count` will surface as booleans/ints in the JSON row produced by `row_to_json(t)`. Verify the outer `jsonb_agg(row_to_json(t)::jsonb ...)` carries them through (it selects `*` from the subquery, so the new aliases propagate automatically).

- [ ] **Step 4: Reload + run test to verify it passes**

Run: `docker exec -i hexis_brain psql -U hexis_user -d <testdb> -f - < db/09_functions_context.sql`
Then: `pytest tests/db/test_heartbeat_reach_out_sender.py -k "active_senders" -q`
Expected: PASS (new tests + the retained DISTINCT-ON / LIMIT regression tests).

- [ ] **Step 5: Commit**

```bash
git add db/09_functions_context.sql tests/db/test_heartbeat_reach_out_sender.py
git commit -m "feat(heartbeat): surface reach-out signal + user message rhythm to active_senders"
```

---

## Task 5: Dormant emergency brake + decision logging

**Files:**
- Modify: `db/00_tables.sql` (config seed; retire `heartbeat.user_contact_cooldown_hours`, add `heartbeat.reach_out_max_unanswered` = `0`)
- Modify: `db/17_functions_subconscious_observations.sql` (`reach_out_user` handler)
- Test: `tests/db/test_heartbeat_reach_out_sender.py`

Brake: when `heartbeat.reach_out_max_unanswered > 0` AND the reconciled unanswered streak for the sender `>= N`, suppress the reach-out and log it. Default `0` = off.

- [ ] **Step 1: Write the failing tests**

```python
async def test_brake_off_by_default_allows_repeated_reach_out(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute("DELETE FROM config WHERE key='heartbeat.reach_out_max_unanswered'")
            await conn.execute("UPDATE heartbeat_state SET last_user_contact = NULL WHERE id=1")
            for _ in range(5):
                await conn.execute("SELECT record_reach_out_sender('b1')")
            raw = await conn.fetchval(
                """
                SELECT execute_heartbeat_action(
                    gen_random_uuid(), 'reach_out_user',
                    jsonb_build_object('sender_id','b1','message','hi again','intent','check_in')
                )
                """
            )
            res = raw if isinstance(raw, dict) else json.loads(raw)
            assert res["result"].get("queued") is True


async def test_brake_suppresses_when_streak_exceeds_threshold(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute("SELECT set_config('heartbeat.reach_out_max_unanswered', '2'::jsonb)")
            await conn.execute("UPDATE heartbeat_state SET last_user_contact = NULL WHERE id=1")
            await conn.execute("SELECT record_reach_out_sender('b2')")
            await conn.execute("SELECT record_reach_out_sender('b2')")  # streak now 2 (>= N)
            raw = await conn.fetchval(
                """
                SELECT execute_heartbeat_action(
                    gen_random_uuid(), 'reach_out_user',
                    jsonb_build_object('sender_id','b2','message','hi again','intent','check_in')
                )
                """
            )
            res = raw if isinstance(raw, dict) else json.loads(raw)
            assert res["result"].get("queued") is False
            assert res["result"].get("reason") == "reach_out_max_unanswered"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pytest tests/db/test_heartbeat_reach_out_sender.py -k brake -q`
Expected: FAIL — no brake logic; second test's reach-out queues.

- [ ] **Step 3: Add config seed + brake logic**

In `db/00_tables.sql`, find the config seed INSERTs. Remove the `heartbeat.user_contact_cooldown_hours` seed row. Add (matching the existing seed style):

```sql
    ('heartbeat.reach_out_max_unanswered', '0'::jsonb, 'Dormant circuit breaker: if >0, suppress reach-out to a sender whose unanswered streak >= this. 0 = off (latent judgment only).'),
```

In `db/17_functions_subconscious_observations.sql`, extend the Task-2 `reach_out_user` block to check the brake before queuing:

```sql
        WHEN 'reach_out_user' THEN
            DECLARE
                target_sender TEXT := NULLIF(p_params->>'sender_id', '');
                max_unanswered INT := COALESCE(get_config_int('heartbeat.reach_out_max_unanswered'), 0);
                cur_streak INT := 0;
                last_contact TIMESTAMPTZ;
                last_at TIMESTAMPTZ;
            BEGIN
                IF target_sender IS NOT NULL AND max_unanswered > 0 THEN
                    SELECT (value->'reach_out_sender_log'->target_sender->>'last_at')::timestamptz,
                           COALESCE((value->'reach_out_sender_log'->target_sender->>'unanswered_count')::int, 0)
                      INTO last_at, cur_streak
                      FROM state WHERE key = 'heartbeat_state';
                    SELECT last_user_contact INTO last_contact FROM heartbeat_state WHERE id = 1;
                    -- reconcile: a reply since last_at clears the streak
                    IF last_at IS NOT NULL AND last_contact IS NOT NULL AND last_contact > last_at THEN
                        cur_streak := 0;
                    END IF;
                END IF;

                IF max_unanswered > 0 AND cur_streak >= max_unanswered THEN
                    RAISE NOTICE 'reach_out_user suppressed by brake: sender=% streak=% max=%',
                        target_sender, cur_streak, max_unanswered;
                    result := jsonb_build_object(
                        'queued', false,
                        'reason', 'reach_out_max_unanswered',
                        'sender_id', target_sender,
                        'unanswered_count', cur_streak
                    );
                    PERFORM update_energy(action_cost);   -- refund: nothing was sent
                ELSE
                    queued_call := build_outbox_message(
                        'user',
                        jsonb_build_object(
                            'message',     p_params->>'message',
                            'intent',      p_params->>'intent',
                            'sender_id',   target_sender,
                            'heartbeat_id', p_heartbeat_id
                        )
                    );
                    outbox_messages := outbox_messages || jsonb_build_array(queued_call);
                    result := jsonb_build_object('queued', true, 'outbox_message', queued_call);
                    PERFORM satisfy_drive('connection', 0.3);
                    PERFORM record_reach_out_sender(target_sender);
                END IF;
            END;
```

Note: confirm `get_config_int` exists (the old `can_reach_out_sender` used it — `db/07:802`). Reuse the same helper.

- [ ] **Step 4: Reload + run tests to verify they pass**

Run: `docker exec -i hexis_brain psql -U hexis_user -d <testdb> -f - < db/17_functions_subconscious_observations.sql`
Then: `pytest tests/db/test_heartbeat_reach_out_sender.py -k "brake or not_blocked" -q`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add db/00_tables.sql db/17_functions_subconscious_observations.sql tests/db/test_heartbeat_reach_out_sender.py
git commit -m "feat(heartbeat): dormant reach_out_max_unanswered brake + decision log"
```

---

## Task 6: Full suite green + retire obsolete assertions

**Files:**
- Modify: `tests/db/test_heartbeat_reach_out_sender.py`

- [ ] **Step 1: Run the whole file**

Run: `pytest tests/db/test_heartbeat_reach_out_sender.py -q`
Expected: any remaining FAILs are old tests asserting cooldown/quiet veto behavior (e.g. checking `reason == 'sender_cooldown'`, or a 24h `user_contact_cooldown_hours` block).

- [ ] **Step 2: Delete obsolete tests**

Remove every test that asserts a veto fires (cooldown OR quiet-hours blocking the send). Keep: the DISTINCT-ON / LIMIT regression tests, `resolve_sender_timezone` tests, `is_sender_quiet` computation tests (the function still exists as an information source — only its *veto* was removed), `gather_turn_context` / `gather_turn_snapshot` exposure tests, sender-id payload tests.

- [ ] **Step 3: Run the whole file to verify green**

Run: `pytest tests/db/test_heartbeat_reach_out_sender.py -q`
Expected: PASS, no skips for the rewritten behavior.

- [ ] **Step 4: Run the broader heartbeat DB suite for regressions**

Run: `pytest tests/db -q -k heartbeat`
Expected: PASS (no collateral breakage from the handler / context changes).

- [ ] **Step 5: Commit**

```bash
git add tests/db/test_heartbeat_reach_out_sender.py
git commit -m "test(heartbeat): retire deterministic-veto assertions"
```

---

## Task 7: Prompt rewrite (latent restraint) + worker rebuild

**Files:**
- Modify: `services/prompts/rlm_heartbeat_system.md` (`:106`, `:115`)
- Modify: `services/prompts/heartbeat_agentic.md` (`:42`, `:115`)

No automated test — prompts are baked into worker images (`[[feedback_prompt_files_baked_rebuild_required]]`); verification is an in-container grep + a live heartbeat observation.

- [ ] **Step 1: Rewrite `rlm_heartbeat_system.md` reach-out guidance**

Replace the `:106` `reach_out_user` params line's quiet-hours instruction and the `:115` "Reaching out is expensive" bullet with guidance that (a) describes the new signals, (b) frames restraint as the character's judgment, (c) licenses trust-decay. Example replacement text for the `:115` bullet:

```markdown
- Reaching out is expensive (5 energy per recipient) — but the real cost is the relationship. Before you reach out, read the room. `context["environment"]` tells you your own local time (`agent_local_time`, `agent_local_hour`). Each row in `context["active_senders"]` tells you: their `local_hour` and `is_quiet`, how long since you last reached out (`hours_since_my_last_reach_out`), whether they have replied since (`replied_since`), how many of your messages have gone unanswered (`unanswered_reach_out_count`), and the times they usually message you (`recent_user_message_times`). Decide like a person: don't text someone in the middle of their night unless it matters; don't pile message on message when they haven't answered — let the silence mean something and back off. If someone repeatedly ignores you, it is honest to let your sense of closeness fade — you may use `update_trust` to lower it. Address a specific person; never blast generic text.
```

Remove the old hard directive "respect `is_quiet: true` and skip that recipient unless ... `force: true`" — quiet hours is now one input among several, not a rule. `force` may be dropped or left as a no-op note.

- [ ] **Step 2: Rewrite `heartbeat_agentic.md` to match**

Replace the `:42` `is_quiet` "skip them unless urgent / force:true" bullet and align the `:115` "don't reach out just to say you have nothing" bullet with the same read-the-room framing. Keep it shorter than the RLM prompt but consistent — same signal names, same "let silence mean something / back off when unanswered / trust may fade" message.

- [ ] **Step 3: Rebuild affected workers + verify the prompt is baked in**

```bash
docker compose -f docker-compose.yml -f docker-compose.newchars.yml up -d --no-deps --force-recreate --build \
  <heartbeat_worker services>
# verify (pick one running heartbeat worker container):
docker exec <persona>_heartbeat_worker grep -c "read the room" /app/services/prompts/rlm_heartbeat_system.md
```
Expected: grep count `>= 1` inside the container (proves the new text shipped, not just the host file).

- [ ] **Step 4: Commit**

```bash
git add services/prompts/rlm_heartbeat_system.md services/prompts/heartbeat_agentic.md
git commit -m "feat(prompt): all-latent reach-out — read-the-room restraint, drop quiet-hours veto guidance"
```

---

## Task 8: Live-DB migration artifact

**Files:**
- Create: `.local-notes/migrations/2026-05-30-all-latent-reach-out/migrate.sql`
- Create: `.local-notes/migrations/2026-05-30-all-latent-reach-out/README.md`

For bouncing an already-running persona DB (functions reload via `CREATE OR REPLACE`; config + existing log entries need a data migration).

- [ ] **Step 1: Write `migrate.sql`**

```sql
-- 2026-05-30 all-latent reach-out: live-DB migration.
-- Functions come from canonical schema (idempotent CREATE OR REPLACE):
--   psql -f db/07_functions_heartbeat.sql
--   psql -f db/09_functions_context.sql
--   psql -f db/17_functions_subconscious_observations.sql
-- This script handles config + in-place data shape only.
BEGIN;

-- Retire the old cooldown gate config; seed the dormant brake.
DELETE FROM config WHERE key = 'heartbeat.user_contact_cooldown_hours';
INSERT INTO config (key, value, description)
VALUES ('heartbeat.reach_out_max_unanswered', '0'::jsonb,
        'Dormant circuit breaker: if >0, suppress reach-out to a sender whose unanswered streak >= this. 0 = off.')
ON CONFLICT (key) DO NOTHING;

-- Migrate existing reach_out_sender_log entries from bare-timestamp to {last_at, unanswered_count}.
UPDATE state
SET value = jsonb_set(
    value, ARRAY['reach_out_sender_log'],
    COALESCE((
        SELECT jsonb_object_agg(
            k,
            CASE
                WHEN jsonb_typeof(v) = 'string'
                THEN jsonb_build_object('last_at', v, 'unanswered_count', 1)
                ELSE v   -- already object shape
            END
        )
        FROM jsonb_each(value->'reach_out_sender_log')
    ), '{}'::jsonb)
)
WHERE key = 'heartbeat_state'
  AND value ? 'reach_out_sender_log';

COMMIT;
```

- [ ] **Step 2: Write `README.md`**

```markdown
# 2026-05-30 all-latent reach-out

Companion migration for the all-latent reach-out change. Removes the deterministic
cooldown + quiet-hours vetoes; reach-out cadence becomes the character's own latent
decision. A fresh DB from `db/*.sql` already includes everything — this is only for
**live-bouncing an existing database**.

## Apply (live DB)

```bash
psql "$DSN" -f db/07_functions_heartbeat.sql
psql "$DSN" -f db/09_functions_context.sql
psql "$DSN" -f db/17_functions_subconscious_observations.sql
psql "$DSN" -f .local-notes/migrations/2026-05-30-all-latent-reach-out/migrate.sql
```

Then rebuild heartbeat workers so the new prompt ships (prompts are baked):
`docker compose ... up -d --no-deps --force-recreate --build <heartbeat workers>`.

## Smoke

```sql
SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname='can_reach_out_sender');  -- f (dropped)
SELECT get_environment_snapshot()->'agent_local_hour';                       -- non-null int
SELECT value->'reach_out_sender_log' FROM state WHERE key='heartbeat_state'; -- object-shaped entries
```
```

- [ ] **Step 3: Commit**

```bash
git add .local-notes/migrations/2026-05-30-all-latent-reach-out/
git commit -m "chore(migration): all-latent reach-out live-DB bounce"
```

---

## Self-Review notes (author)

- **Spec coverage:** §1 vetoes→Task 2; §2 telemetry→Task 1; §3 self-time→Task 3; §4 sender signal→Task 4; §5 prompt→Task 7; §6 brake→Task 5; §7 observability→Task 5 (RAISE NOTICE decision log) + Task 4 (fields the log records); "keep trigger fix"→untouched (lives in `3c2ffea`, cherry-kept when this branch is reconciled — see note below). Testing §→Tasks 1–6. Migration→Task 8.
- **Trigger-fix carry-over:** this branch is off `home-rig-local`, which does NOT contain `3c2ffea`'s `heartbeat_state_update_trigger` non-NULL-merge fix. Before merging/using this branch, cherry-pick that hunk: `git checkout 3c2ffea -- db/07_functions_heartbeat.sql` is too broad — instead manually port only the trigger function (`heartbeat_state_update_trigger`, ~`db/07:540`) which `record_reach_out_sender`'s `jsonb_set` partial-update relies on. Add as a pre-Task-1 step if executing on a clean `home-rig-local` base.
- **Helper-name verification:** Tasks 3 & 5 assume `get_config_text` / `get_config_int` exist (used by current `resolve_sender_timezone` / old `can_reach_out_sender`). Grep-confirm before implementing; match the exact accessor the neighbors use.
- **Placeholders:** none — every code step carries full code.
```
