# M5 Fleet Bounce Runbook — Operator Only

**Status:** GATED ON OPERATOR. Destructive (`down -v` wipes brain volume). ~15 min downtime. Per-persona heartbeat workers must be manually restarted post-bounce (CLAUDE.md wedge trap).

**Pre-req:** decided which Phase to merge (recommend Phase A only per `m4-decision-gate.md`).

## Phase A — merge only (`feba84b`), no PR-A/B

Lower risk. Adopts upstream's RecMem schema + DB-runtime, keeps sender-scoping on legacy `fast_recall` path. Recommended first.

```powershell
# 0. Pre-flight check — operator confirms quiet window
.\hexis-status.ps1
docker ps --filter "name=hexis_" --format "{{.Names}}: {{.Status}}"

# 1. Cherry-pick ONLY the merge resolution commit onto home-rig-local
cd C:\hexis
git fetch
git status   # MUST be clean. Stash if dirty (.local-notes/ etc.)
git cherry-pick C:/Users/User/.claude/jobs/f3783d2d/hexis-upstream  feba84b
# If cherry-pick conflicts (shouldn't, but if), abort and revisit.

# 2. Tag pre-bounce state (safety)
git tag pre-m5-bounce-$(Get-Date -Format yyyy-MM-dd-HHmm)

# 3. Brain rebuild (destructive: wipes all memories, channel sessions, consent)
docker compose down -v
docker compose build db
docker compose up -d

# 4. Wait for brain ready
$timeout = 60
$elapsed = 0
while (-not (docker exec hexis_brain pg_isready -U hexis_user -d hexis_memory 2>$null)) {
    if ($elapsed -ge $timeout) { Write-Error "brain not ready in ${timeout}s"; exit 1 }
    Start-Sleep -Seconds 2; $elapsed += 2
}
Write-Host "brain ready in ${elapsed}s"

# 5. Re-init agent + apply persona SQL fleet-wide
# (assumes characters/ already present with persona JSON + set_persona_prompt SQL)
hexis init   # or per-persona variant

# Per-persona DB anchor re-apply
$personas = @('vera','hazel','esme','sable','vesper','denali','callisto','ennie','death','cassiel','trump','milena','baymax','monika','lovesick','charlotte')  # adjust to current fleet
foreach ($p in $personas) {
    $sqlPath = "characters\set_persona_prompt.$p.sql"
    if (Test-Path $sqlPath) {
        Write-Host "Applying $p anchor..."
        docker exec -i hexis_brain psql -U hexis_user -d "hexis_$p" -f - < $sqlPath
    }
}

# 6. Start workers + restart per-persona heartbeat workers (consumer-wedge bug per CLAUDE.md)
docker compose --profile active up -d
foreach ($p in $personas) {
    docker restart "hexis_${p}_heartbeat_worker" 2>$null
    docker restart "hexis_${p}_channel_worker" 2>$null
}

# 7. Verify
.\hexis-status.ps1
# Expect: power-mode marker, :8080/:8081 alive, every persona shows configured+consent+llm.chat model
```

## Phase B — cherry-pick PR-A + PR-B too (`2ad5a94` + `5d00116`)

Run **only after** Phase A is stable AND you intend to flip `memory.recmem_hydrate_enabled = true` for at least one persona.

```powershell
cd C:\hexis
git cherry-pick C:/Users/User/.claude/jobs/f3783d2d/hexis-upstream  2ad5a94 5d00116
# Bounce brain again (same as Phase A step 3-7)
```

Phase B bounce can be `docker compose down && docker compose build db && docker compose up -d` (NO `-v` — schema is additive via CREATE OR REPLACE + DROP FUNCTION IF EXISTS, doesn't require volume wipe).

## Rollback (any phase, before persona data accumulates on new schema)

```powershell
cd C:\hexis
git reset --hard pre-upstream-merge-2026-05-23
docker compose down -v
docker compose build db
docker compose up -d
# Then re-init + persona anchor (same as Phase A steps 5-7)
```

Rollback window: until heartbeat / chat starts writing to `subconscious_units`. Once memory accumulates there, rollback loses those memories.

## Smoke test post-bounce

```powershell
# Chat one persona via Telegram or web UI; verify reply is in-character (not generic-greeting persona-collapse)
# Check one persona's heartbeat fires within ~jitter window
docker exec hexis_brain psql -U hexis_user -d hexis_vera -c "SELECT key, value FROM config WHERE key IN ('llm.chat', 'agent.power_mode', 'agent.is_configured') ORDER BY key;"
```

## When things go wrong

- **Schema init fails (docker compose up shows db exited):** check `docker logs hexis_brain | tail -50`. If a `db/*.sql` errors out, the brain volume is half-populated. Fix: `docker compose down -v && docker compose build db && docker compose up -d` after fixing the SQL.
- **Persona generic-greeting collapse:** re-apply persona SQL (step 5). If still collapsing, check `channel_sessions.history` per CLAUDE.md troubleshooting.
- **Heartbeat workers silent:** consumer wedge bug. `docker restart hexis_<persona>_heartbeat_worker` (CLAUDE.md known issue, not auto-recoverable post DB-IP change).
