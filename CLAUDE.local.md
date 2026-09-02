# Local rig notes (this box — not team-shared)

## Git branch topology (CRITICAL — never push local work to main)

- `main` = UPSTREAM mirror, NOT owned (HEAD ~ release tags like "bump 1.0.5").
- ALL local dev + patches live ONLY on branch `home-rig-local` (hundreds of
  commits ahead of `main`, no divergence).
- NEVER merge / fast-forward / push `home-rig-local` → `main` — that dumps local
  work onto the upstream line. "Merge this work" on hexis = commit on
  `home-rig-local`, full stop.
- Contributing upstream = clean cherry-pick onto a fresh branch off `main`, never
  by merging `home-rig-local`.

## Serving topology (CRITICAL — misreading this caused a full q36 outage)

- Chat = per-character `llama-server` fleet, per-port: chat :8080, embed :8081
  (ALWAYS-ON), nano :8082. Managed by `set-power-mode.ps1 prime` (arms :8080
  only) + `start-all.ps1` (full stack incl :8081). NOT llama-swap.
- llama-swap is a SEPARATE stack — "two stacks, do not merge"
  (`C:\llm-serve\docs\HEXIS-INTEGRATION.md`).
- Recover: `.\start-all.ps1` (idempotent, won't double-bind :8080). NEVER kill
  `llama-server.exe` to force-reload — no supervisor; embed:8081 always-on,
  killing it breaks ALL hydration → generic replies.
- `.\hexis-status.ps1` = fleet/server/character status.

## Compose ops

- `docker-compose.newchars.yml` = single source for ALL hexis-native personas
  (eni, mira, nines, death, cassiel, joje, monika). Per-persona files deprecated.
- `hexis_brain` = Docker container for shared Postgres (`db` service); holds all
  `hexis_<P>` databases. Port 43815→5432.
- `hexis_brain` container may be recreated by `up --build` when compose config
  changes — data is safe (volume persists without `-v`).
- NEVER `docker compose down -v` — wipes every `hexis_<P>` persona DB (2026-05-29
  wipe). Data destruction, not a reset.
- `compose up --build` WITHOUT `--no-deps` recreates `hexis_brain` and wedges the
  fleet gateway. Resume / rebuild MUST pass `--no-deps` (recipe: model-serving.md
  §Multi-persona).

## Done means — the close-gate, and where open work lives

A commit on `home-rig-local` is NOT done; green throwaway-DB tests are never the
gate (the trigger-drop trap below passes them and breaks live). Done per change:

- **SQL / schema / view** — live-applied to the running `hexis_<P>` DBs
  (schema-migration.md §Live migration), INSTEAD OF trigger re-created in the
  same migration, verified by a real `UPDATE`.
- **`services/prompts/*.md` or `core/`** — baked into worker images: rebuild
  with `--no-deps --force-recreate --build`, then in-container
  `grep -c <new_term>` (NOT read per turn).
- **heartbeat / behavior** — the completion query above, never `cnt`.
- **serving** — fleet green via `.\hexis-status.ps1`; recover `.\start-all.ps1`.

Open work = `.local-notes/_inbox.md` (tracked; done rows leave to git). Reconcile
every "shipped" claim against `git log --oneline main..home-rig-local` before
trusting it; at close, trim shipped rows and write the next-step pointer there.
`~/.claude/projects/C--hexis/memory/` is external — never shows in `git status`.

## Heartbeat liveness (verify autonomous loop ACTUALLY runs)

- Ground truth = `heartbeat_state` table per `hexis_<P>` DB (NOT config keys):
  `cnt`/`heartbeat_count`, `last_heartbeat_at`, `next_heartbeat_at`,
  `current_energy` (10=never ran, regens →20), `is_paused`, `init_stage`.
- "Promoted" = container Up AND per-DB gate (`agent.is_configured=true` +
  `agent.consent_status="consent"`) AND heartbeats COMPLETING. First two are
  necessary-not-sufficient.
- **A rising `heartbeat_count` does NOT prove the loop works** (burned 2026-07-14):
  `start_heartbeat()` bumps `heartbeat_count` + `last_heartbeat_at` at the TOP of the
  cycle. Climbing cnt = cycles START. `next_heartbeat_at` is the COMPLETION clock (single
  writer, `db/13_functions_emotional_state.sql:1048`, same UPDATE that clears
  `active_heartbeat_id`). Stale `next` + fresh `last` = starting, never finishing.
  Ground-truth completion check:
  `SELECT max(created_at) FROM memories WHERE metadata->'context' ? 'heartbeat_id';`
- **Dead embed `:8081` silently kills finalize FLEET-WIDE** — `create_episodic_memory`
  needs an embedding, so every heartbeat throws at the finish line while cnt keeps
  climbing. 2.5-day silent outage 07-11→07-14. Also breaks chat hydration.
- Night gate (`heartbeat.timezone=Asia/Singapore`, night 23→8): nothing completes at
  night. Don't try to verify heartbeat recovery after 23:00 local.
- Container `Up Xh` ≠ healthy: `core.gateway` consumer loop wedges after a
  `hexis_brain` bounce (`Connect call failed …5432`, asyncpg `cannot switch
  to state 12`) and does NOT self-heal. Fix = restart workers:
  `docker restart $(docker ps -q --filter name=_heartbeat_worker --filter name=_maintenance_worker --filter name=_channel_worker)`

## Docker VM clock drift (PRIMARY gotcha — burns whole investigations)

- VM wall clock leaps hours mid-session (host sleep/resume or ECO/PRIME GPU
  switch). Breaks `next_heartbeat_at` scheduling (stuck→burst-fire) AND
  `docker logs --since` (silent empty window — looks like a dead worker).
- RULE: before trusting ANY heartbeat-timing or `--since` evidence, run
  `docker exec hexis_brain date -u` and confirm it == real UTC.
- Host is UTC+8: host `Get-Date` (local) vs container `date -u` (UTC) is a
  built-in ~8h offset — compare same TZ or you'll diagnose a phantom skew.

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).

## References (loaded on demand — not in CLAUDE.local.md token budget)

| Topic | File |
|---|---|
| Generic/empty persona replies, reasoning-trace leak, bad-reply loops, Windows gotchas, fast Python iteration | `.local-notes/guidelines/debugging.md` |
| Heartbeat system, liveness, wedge fix | `.local-notes/guidelines/heartbeat.md` |
| Model serving, power modes, GPU, persona anchors | `.local-notes/guidelines/model-serving.md` |
| Schema migration, live bounce, throwaway DB | `.local-notes/guidelines/schema-migration.md` |
| Persona onboard, character cards | `.local-notes/guidelines/persona-onboard.md` |
| NSFW / persona system-prompt injection | `.local-notes/guidelines/persona-onboard-nsfw.md` |
| Persona onboard (full recipe) | `.local-notes/hexis-native-onboard.prompt.md` |
| NSFW persona onboard (full recipe) | `.local-notes/hexis-native-onboard-nsfw.prompt.md` |
