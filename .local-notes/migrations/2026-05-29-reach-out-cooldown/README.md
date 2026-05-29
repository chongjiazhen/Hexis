# 2026-05-29 reach-out cooldown

Companion migration for `feat(heartbeat): per-sender reach-out cooldown`.

Adds `heartbeat.user_contact_cooldown_hours` gating (default 24h) and the
`reach_out_sender_log` JSONB key on `heartbeat_state`. A fresh DB initialised
from `db/*.sql` already includes everything — this is only for **live-bouncing
an existing database**.

## Apply (live DB)

```bash
# functions (idempotent CREATE OR REPLACE) come from the canonical schema:
psql "$DSN" -f db/07_functions_heartbeat.sql
psql "$DSN" -f db/17_functions_subconscious_observations.sql
# then the view + state-key change:
psql "$DSN" -f .local-notes/migrations/2026-05-29-reach-out-cooldown/migrate.sql
```

`migrate.sql` is transactional: seeds the `reach_out_sender_log` state key, then
`DROP ... CASCADE` + recreates `heartbeat_state` with the new column and its
dependent views (`heartbeat_health`, `current_emotional_state`,
`cognitive_health`).

## Smoke

```sql
SELECT reach_out_sender_log FROM heartbeat_state;          -- '{}'
SELECT can_reach_out_sender('someone');                    -- TRUE (no prior reach-out)
```
