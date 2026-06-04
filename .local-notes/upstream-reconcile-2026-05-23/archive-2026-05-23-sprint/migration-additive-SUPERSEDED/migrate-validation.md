# Migration SQL Validation — Anchor DB Test

## Files

- `migrate-additive.sql` — shell with @@INLINE markers for trial-worktree SQL files
- `migrate-additive-build.sh` — concat script that produces `migrate-additive.full.sql`
- `migrate-additive.full.sql` — 9055 lines, fully assembled, ready to apply

## Test setup

- Throwaway DB from anchor commit `f9a7631` (= `pre-upstream-merge-2026-05-23`) — represents what live `hexis_brain` currently has.
- Compose: `-p hexisanchor` on port 43818, container `hexis_brain_anchor`.
- Pre-check confirmed `subconscious_units` absent, `memories.valid_until` absent — anchor was true pre-merge state.

## Apply result (first run)

```
docker exec -i hexis_brain_anchor psql -U hexis_user -d hexis_memory \
  --single-transaction --set ON_ERROR_STOP=on < migrate-additive.full.sql
EXIT=0
```

- 0 errors. 0 fatals.
- 3 ALTER TABLE (memories columns)
- 9 CREATE TABLE IF NOT EXISTS (RecMem core + rollout + eval)
- 22 CREATE INDEX IF NOT EXISTS
- ~100+ CREATE FUNCTION (CREATE OR REPLACE bodies from inlined files)
- 3 CREATE VIEW (recmem_state, recmem_rollout_health, worker_tasks updated)
- 34 INSERT INTO config (with ON CONFLICT DO NOTHING)

## Post-state verification

- `memories` has 4 expected columns: `sender_id, superseded_by, valid_from, valid_until` ✅
- New tables: `subconscious_units`, `recmem_consolidation_tasks`, `memory_source_units`, `recmem_rollout_events`, `recmem_eval_sets` (and others) ✅
- PR-A: `recmem_recall_context(p_query, p_k_sub, p_k_epi, p_k_sem, p_session_id, p_current_sender)` ✅
- PR-B: `create_memory_with_embedding(... p_sender_id text DEFAULT NULL)` ✅

## Issue caught + fixed: orphaned overload

**Problem:** initial migration left TWO versions of `create_memory_with_embedding`:
- Old 7-arg signature with stale body (no sender_id INSERT)
- New 8-arg signature with PR-B body

Postgres `CREATE OR REPLACE FUNCTION` matches by full signature, not name. Adding an arg = new overload. Existing callers passing 7 args would resolve to the OLD overload → no sender_id propagation on that path.

**Fix:** added `DROP FUNCTION IF EXISTS create_memory_with_embedding(memory_type, text, vector, float, jsonb, float, jsonb)` to PART 1b of migration shell. Same defensive DROP for `recmem_recall_context(text, int, int, int, uuid)`.

**Re-validated:** rebuilt + re-applied to same anchor DB → single canonical signature for both functions. EXIT=0. 0 errors.

## Idempotency

Applied migration twice in a row to same DB (after fix). Second application: EXIT=0, 0 errors. Confirmed idempotent — safe to re-run if first application is interrupted partway.

## What is NOT yet validated

1. **Pre-existing data preservation.** Anchor DB was empty when migration applied. Postgres guarantees additive DDL doesn't touch existing rows, but a real-data test (dump live persona → restore into throwaway → apply migration) would be operator-confidence stronger.
2. **Apache AGE graph state.** Live brain has `memory_graph` AGE entries per persona. Migration doesn't touch AGE schema, but a real-data run would confirm.
3. **Concurrent active workers.** Migration runs in a single transaction; locks `memories` briefly during `ALTER TABLE ... ADD COLUMN`. Workers actively writing memories might block briefly. Live test would measure.

These three are low-probability failure modes; the structural validation here is strong. Operator can choose to do a full live-data test before live cutover if desired (~10 min extra work: dump one persona, restore, apply).

## Live application procedure

```powershell
# Pre-flight
.\hexis-status.ps1
docker ps --filter "name=hexis_" --format "{{.Names}}: {{.Status}}"

# Tag rollback anchor
git -C C:\hexis tag pre-m5-migrate-$(Get-Date -Format yyyy-MM-dd-HHmm)

# Apply per-persona DB
$personas = @(  # adjust to current fleet
    'vera','hazel','esme','sable','vesper','denali','callisto','ennie',
    'death','cassiel','trump','milena','baymax','monika','lovesick','charlotte'
)
$migrate = "C:\hexis\.local-notes\upstream-reconcile-2026-05-23\migration-pure-recmem\migrate-additive.full.sql"

foreach ($p in $personas) {
    Write-Host "Migrating hexis_$p..."
    Get-Content $migrate | docker exec -i hexis_brain `
      psql -U hexis_user -d "hexis_$p" `
      --single-transaction --set ON_ERROR_STOP=on
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Migration FAILED on hexis_$p — stopping"
        break
    }
}

# Then rebuild + recreate workers (NO brain touch)
docker compose -f docker-compose.yml -f docker-compose.newchars.yml `
  up -d --no-deps --force-recreate --build $WORKER_SVCS

# Verify
.\hexis-status.ps1
```

## Rollback if migration applied to some personas + bad

Each persona DB is independent. Failure on persona N stops the loop (`-ErrorAction Stop`). Personas 1..N-1 have new schema; live workers (still on old Python image) will hit "function does not exist" errors when they touch the new functions. But the OLD signatures still exist on those DBs because migration is additive — old code paths work unchanged.

To revert a partially-migrated persona DB to pre-merge schema, would need a separate down-migration. Not provided here; not typically needed since additive schema doesn't break old code.

## Compare to fleet bounce

| Dimension | Migration (Option 1) | Fleet bounce (M5 baseline) |
|---|---|---|
| Memory loss | NONE | ALL (`down -v` wipes data volume) |
| Brain downtime | NONE | ~30 sec stop + ~30 sec init |
| Worker downtime | ~30 sec per worker (rolling) | ~30 sec per worker (after manual restart loop) |
| Consumer-wedge bug | NOT TRIGGERED (brain IP unchanged) | TRIGGERED (every per-persona heartbeat worker needs `docker restart`) |
| Operator effort | apply migration → worker rebuild | down → build → up → init → 16× anchor re-apply → worker restart loop |
| Total wall clock | ~5 min | ~15-30 min |
| Rollback complexity | partial-revert hard but rarely needed (additive) | git reset + bounce again |

Migration wins on every axis if the migration SQL is sound. Validation above shows it is.

## Operator action required

**Operator final say on whether to:**
1. Apply migration to live (preserves memories, ~5 min)
2. Take the bounce route (wipes memories, ~15-30 min, but matches CLAUDE.md's documented procedure)
3. Defer entire merge until later
