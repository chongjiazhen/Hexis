# Timezone-Aware Heartbeat Reach-Out — Migration Readme

Per-recipient quiet-hours gate on `reach_out_user`. Adds `is_sender_quiet()`,
enriches `get_active_senders_context` with `{timezone, local_hour, is_quiet}`,
and gates the action handler with energy refund + `force` override.

## Apply (per-DB fleet loop)

```powershell
$dbs = docker exec hexis_brain psql -U hexis_user -d postgres -tAc `
  "SELECT datname FROM pg_database WHERE datname LIKE 'hexis_%' ORDER BY 1"
foreach ($db in ($dbs -split "`n" | Where-Object { $_ })) {
  Write-Host ">>> $db"
  docker exec -i hexis_brain psql -U hexis_user -d $db -v ON_ERROR_STOP=1 -f - `
    < db/07_functions_heartbeat.sql
  docker exec -i hexis_brain psql -U hexis_user -d $db -v ON_ERROR_STOP=1 -f - `
    < db/09_functions_context.sql
  docker exec -i hexis_brain psql -U hexis_user -d $db -v ON_ERROR_STOP=1 -f - `
    < db/17_functions_subconscious_observations.sql
}
```

Or run the bundled smoke-inclusive script:

```powershell
$dbs = docker exec hexis_brain psql -U hexis_user -d postgres -tAc `
  "SELECT datname FROM pg_database WHERE datname LIKE 'hexis_%' ORDER BY 1"
foreach ($db in ($dbs -split "`n" | Where-Object { $_ })) {
  docker exec -i hexis_brain psql -U hexis_user -d $db -v ON_ERROR_STOP=1 `
    -f .local-notes/migrations/2026-05-26-timezone-aware-reach-out/migrate.sql
}
```

## Heartbeat-worker rebuild (mandatory — prompt files are baked)

`services/prompts/*.md` are baked into the worker image at build time. Task 6
edited three prompt files; operators must rebuild + recreate every heartbeat
worker before the next cycle:

```powershell
$svcs = docker ps --format '{{.Names}}' `
  | Select-String '_heartbeat_worker$' `
  | ForEach-Object { $_.ToString() -replace '^hexis_','' }
docker compose -f docker-compose.yml -f docker-compose.newchars.yml `
  --profile active up -d --no-deps --force-recreate --build $svcs
```

`--no-deps` is mandatory — without it, `up -d` recreates `hexis_brain` and
triggers a consumer-wedge.

Verify the new prompt landed:

```bash
MSYS_NO_PATHCONV=1 docker exec hexis_<persona>_heartbeat_worker \
  grep -c "is_quiet" /app/services/prompts/rlm_heartbeat_system.md
# expected: >= 1
MSYS_NO_PATHCONV=1 docker exec hexis_<persona>_heartbeat_worker \
  grep -c "is_quiet" /app/services/prompts/heartbeat_system.md
# expected: >= 1
```

## Per-sender timezone setup

Operator-driven; no auto-detection. After identifying a sender's locale:

```sql
SELECT set_config('channel.sender.593307304.timezone', '"Asia/Singapore"'::jsonb);
SELECT set_config('channel.sender.4242.timezone', '"America/Los_Angeles"'::jsonb);

-- Optional per-sender quiet window override (defaults to agent-wide):
SELECT set_config('channel.sender.4242.quiet_start_hour', '22'::jsonb);
SELECT set_config('channel.sender.4242.quiet_end_hour', '7'::jsonb);
```

If unset, `resolve_sender_timezone` falls back to `heartbeat.timezone`
(default `"Asia/Singapore"`).

## Smoke probe (inside a transaction)

```sql
BEGIN;
SELECT set_config('channel.sender.someone.timezone', '"Etc/GMT-8"'::jsonb);
SELECT execute_heartbeat_action(
    gen_random_uuid(),
    'reach_out_user',
    jsonb_build_object('sender_id','someone','message','probe','intent','probe')
);
ROLLBACK;
-- If 'someone'-local hour is in their quiet window:
--   expect result.queued=false, result.reason='recipient_quiet_hours'
-- Otherwise:
--   expect result.queued=true with result.payload.sender_id='someone'
```

Force override check:

```sql
BEGIN;
SELECT set_config('channel.sender.someone.timezone', '"Etc/GMT-8"'::jsonb);
SELECT execute_heartbeat_action(
    gen_random_uuid(),
    'reach_out_user',
    jsonb_build_object('sender_id','someone','message','urgent','force',true)
);
ROLLBACK;
-- Expect result.queued=true regardless of 'someone'-local hour.
```

## Compatibility

- Senders with no per-sender tz set → fall back to agent-wide `heartbeat.timezone`.
  No regression for existing recipients.
- Old persona REPL outputs without `force` key → coerced via
  `COALESCE((p_params->>'force')::boolean, FALSE)` — safe.
- Old untargeted `reach_out_user` (no `sender_id`) → `is_sender_quiet(NULL)` uses
  agent-wide night window. If gating fires, energy is refunded. Use `force:true`
  or migrate to the sender-targeted path.

## Related

- Spec: `docs/specs/2026-05-26-timezone-aware-reach-out-design.md`
- Plan: `docs/plans/2026-05-26-timezone-aware-reach-out.md`
- Heartbeat night throttle (complementary, not replaced): `is_heartbeat_night()` in `db/07_functions_heartbeat.sql`
