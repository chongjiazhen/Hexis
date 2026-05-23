# 2026-05-20 — heartbeat (+chat +subconscious) to GPU :8080

## Why
- Live fleet 24h showed `tool_calls=0` on every heartbeat across 6 personas. Root
  cause was not parser blindness (RLM controller dispatches `tool_use(...)` via
  REPL bridge, confirmed `services/hexis_rlm.py:39-41` + `services/rlm_repl.py:190-192`).
- Real cause: nano `:8082` has `--ctx-size 4096`. Persona cold-start anchor +
  recall blows past 4K (e.g. `hexis_death_heartbeat_worker`: `6047 tokens exceed
  4096 ctx`; `ao`: 4102). Loop never finalizes → iterations=10 cap → 0 tool use.
- Sam (`hexis_memory`) already on :8080 / q36 (131K ctx) and heartbeats land cleanly.

## Scope
11 live DBs currently pinned at nano `:8082`:

`hexis_ao  hexis_cassiel  hexis_charlotte  hexis_death  hexis_eni  hexis_ichika
hexis_joje  hexis_lovesick  hexis_mira  hexis_monika  hexis_nines`

Skip:
- `hexis_memory` (Sam) — already on :8080.
- `hexis_baymax / hexis_rocky / hexis_tars` — frozen 2026-05-19 per global VRAM
  policy.

## Apply (worst-first, signoff-gated)

Pick first persona, apply, observe 1–2 heartbeat cycles, then continue.
Recommended order (worst log evidence first): `death` → `ao` → `eni` → `ichika`
→ `cassiel` → `monika` → `nines` → `joje` → `mira` → `charlotte` → `lovesick`.

```powershell
$persona = "death"
Get-Content .\migrate.sql | docker exec -i hexis_brain psql -U hexis_user -d "hexis_$persona"
docker restart "hexis_${persona}_channel_worker" `
               "hexis_${persona}_heartbeat_worker" `
               "hexis_${persona}_maintenance_worker"
```

Verify next heartbeat finishes with FINAL (not "RLM loop exhausted 10 iterations")
and ideally non-zero `tool_calls=` in the `rlm_heartbeat_complete` line:

```powershell
docker logs "hexis_${persona}_heartbeat_worker" --since 30m | Select-String "rlm_heartbeat_complete"
```

## Watch-outs

1. **VRAM**: :8080 already `--parallel 1` under 6-persona load. Adding 11 chat +
   11 heartbeat + 11 subconscious clients = same fleet (each persona was already
   counted, just on the wrong port). Net VRAM delta = 0. Concurrency on :8080
   goes up; q36 MoE can absorb it per CLAUDE.md guidance, but a saturated big
   model may degrade response latency. Monitor `hexis-status.ps1` after first
   3–4 personas migrate.
2. **No `--no-deps` issue**: this migration is DB-only + per-worker `docker
   restart`. No `compose up --build` here, so the brain-IP wedge trap from the
   outbox migration doesn't apply.
3. **Cold-start collapse**: confirm each persona's `agent.persona_system_prompt`
   is set (memory `persona_system_prompt_coldstart_anchor`) — if it was missing
   under nano, it'll still be missing under q36. Check via `hexis status`
   pre-flip.
4. **Don't preheat**: don't restart all 11 personas in parallel. q36 cold-prompt
   eval is the most expensive moment; staggered ≥30 s apart.

## Rollback per-persona

```powershell
$persona = "death"
Get-Content .\rollback.sql | docker exec -i hexis_brain psql -U hexis_user -d "hexis_$persona"
docker restart "hexis_${persona}_channel_worker" `
               "hexis_${persona}_heartbeat_worker" `
               "hexis_${persona}_maintenance_worker"
```

Use only if GPU :8080 measurably degrades that persona (latency tail, OOM, q36
chat tone unfit). Nano floor remains live until start.ps1 patch ships.

## After all 11 migrated → companion patch

`start.ps1` gates nano launch on ECO mode marker (`logs/current-mode.txt`). With
the fleet on :8080, PRIME boots no longer load nano — saves ~1.5 GB RAM + 4 CPU
threads. `set-power-mode.ps1 eco` needs a matching ensure-launch step (separate
patch, out of this migration's scope).
