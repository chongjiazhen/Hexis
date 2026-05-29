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
