# 2026-05-26 — heartbeat tailored reach-out, fleet migration

Re-applies idempotent `CREATE OR REPLACE FUNCTION` for three touched files to every `hexis_<persona>` database. No `down -v`; no compose recreate.

## What this changes

- `db/09_functions_context.sql` — new function `get_active_senders_context(p_limit, p_recency_days)` returning recent distinct senders from `channel_sessions`.
- `db/13_functions_emotional_state.sql` — `gather_turn_context()` now emits an `active_senders` key (sourced from the new function) into the heartbeat turn snapshot.
- `db/17_functions_subconscious_observations.sql` — `execute_heartbeat_action`'s `WHEN 'reach_out_user' THEN` branch now stamps `sender_id` into the outbox payload (sourced from `p_params->>'sender_id'`, `NULLIF`-coerced).

## Apply

```powershell
$dbs = docker exec hexis_brain psql -U hexis_user -d postgres -tAc `
  "SELECT datname FROM pg_database WHERE datname LIKE 'hexis_%' ORDER BY 1"
foreach ($db in ($dbs -split "`n" | Where-Object { $_ })) {
  Write-Host ">>> $db"
  docker exec -i hexis_brain psql -U hexis_user -d $db -v ON_ERROR_STOP=1 -f - `
    < db/09_functions_context.sql
  docker exec -i hexis_brain psql -U hexis_user -d $db -v ON_ERROR_STOP=1 -f - `
    < db/13_functions_emotional_state.sql
  docker exec -i hexis_brain psql -U hexis_user -d $db -v ON_ERROR_STOP=1 -f - `
    < db/17_functions_subconscious_observations.sql
}
```

Use the three explicit `psql` calls (above) rather than `\ir migrate.sql` because `\ir` requires the file to be visible inside the container's filesystem, and the simplest robust path is to stream each file from the host into the container's stdin.

## Verify per DB

```sql
-- Active senders surface exists
SELECT pg_get_function_identity_arguments('get_active_senders_context'::regproc);
-- expected: p_limit integer DEFAULT 8, p_recency_days integer DEFAULT 7

-- Gather-turn-context exposes the new key
SELECT gather_turn_context() ? 'active_senders' AS has_active_senders;
-- expected: t

-- Reach-out handler threads sender_id (rolled back; no real action recorded)
BEGIN;
SELECT execute_heartbeat_action(
    gen_random_uuid(),
    'reach_out_user',
    jsonb_build_object(
        'sender_id', '12345',
        'message',   'verify probe',
        'intent',    'probe'
    )
);
ROLLBACK;
-- expected payload: result.outbox_message.payload.sender_id = '12345'
```

## No worker restart required

Functions are read fresh per call. Prompts in `services/prompts/` (RLM heartbeat + legacy) are read per turn. Three function-only changes propagate without bouncing any container.

## ACID-for-cognition invariant intact

Outbox payloads now carry `sender_id` but the per-persona queue isolation contract from [[project_outbox_per_persona_queues]] is unchanged — `build_outbox_message` still stamps `agent`, consumer still gates on it. Per-persona DB still in charge of which queue is published to.

## Compatibility window

- Personas running the OLD handler version are still safe: their outbox payloads have no `sender_id` (back-compat tested in `tests/db/test_heartbeat_reach_out_sender.py::test_reach_out_user_without_sender_id_stays_backward_compat`), and `channels/outbox.py:_deliver_last_active` falls through to the globally most-recent session for unsender'd messages — i.e., the prior behavior.
- Personas running the NEW handler but on the OLD `gather_turn_context` (i.e., partial migration) will not see `active_senders` in their REPL context. The persona's reasoning will still emit `reach_out_user` with no `sender_id`, again falling through to the globally most-recent session. No data corruption, just no tailored routing.
- Therefore: rolling per-persona migration is safe; no ordering constraint between personas.

## Smoke procedure

Run after applying the migration to a chosen test persona. Pick a low-traffic persona (e.g. `monika`, `nines`, or a designated probe persona) with at least two recent `channel_sessions` rows from different `sender_id`s in the last 7 days.

### 1. Confirm test persona has multiple active senders

```bash
docker exec hexis_brain psql -U hexis_user -d hexis_<persona> -c \
  "SELECT sender_id, channel_id, last_active FROM channel_sessions WHERE last_active > CURRENT_TIMESTAMP - INTERVAL '7 days' ORDER BY last_active DESC LIMIT 10"
```

Expected: ≥2 distinct `sender_id` values.

### 2. Confirm the persona's heartbeat REPL sees `active_senders`

```bash
docker exec hexis_brain psql -U hexis_user -d hexis_<persona> -c \
  "SELECT jsonb_pretty(gather_turn_context()->'active_senders')"
```

Expected: pretty-printed JSON array with at least the two senders from step 1.

### 3. Watch the heartbeat worker

```bash
docker logs -f hexis_<persona>_heartbeat_worker
```

Leave running.

### 4. Wait for a natural heartbeat cycle

DO NOT manually advance `next_heartbeat_at` — see `.local-notes/BUG-heartbeat-clock-drift-consumer-wedge.md` for why fabricated timing evidence is untrustworthy. Heartbeats fire at `last_heartbeat_at + interval + jitter`; check current state with:

```bash
docker exec hexis_brain psql -U hexis_user -d hexis_<persona> -c \
  "SELECT last_heartbeat_at, current_energy, should_run_heartbeat() FROM heartbeat_state WHERE id = 1"
```

When `should_run_heartbeat()` returns `t`, the next worker tick (≤60s) will fire it.

### 5. Inspect emitted outbox messages

After the cycle completes, look for sender-tagged routing in the channel worker logs:

```bash
docker logs hexis_<persona>_channel_worker --tail 100 | grep -E "outbox|reach_out|deliver|sender_id"
```

Expected success indicators:
- One or more `_deliver_last_active` calls referencing distinct `sender_id` values from `active_senders`.
- Telegram `send` calls to the matching `channel_id` for each `sender_id`.
- NO unsendable "No active session found" warnings unless the persona reached out to a stranger.

If the persona emitted multiple `reach_out_user` actions in one cycle, expect multiple Telegram sends to different chats.

### 6. Inspect the heartbeat's episodic memory

```sql
SELECT id, created_at, sender_id, left(content, 160)
FROM memories
WHERE type = 'episodic'
  AND source_attribution->>'kind' = 'heartbeat'
ORDER BY created_at DESC
LIMIT 5;
```

The most recent episodic should contain the `reach_out_user` action(s) emitted, including the chosen `sender_id`(s) in its content.

## Smoke result

<!-- Operator fills in below -->

Persona:
Datetime (UTC):
active_senders observed (step 2):
Heartbeat fire time:
Sender(s) reached:
Telegram delivery confirmed?:
Episodic memory captured?:
Anomalies / notes:
