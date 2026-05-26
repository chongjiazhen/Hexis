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
