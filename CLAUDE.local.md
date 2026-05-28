# Local rig notes (this box — not team-shared)

## Serving topology (CRITICAL — misreading this caused a full q36 outage)
- Chat = per-character `llama-server` fleet, per-port: chat :8080, embed :8081
  (ALWAYS-ON), nano :8082. Managed by `set-power-mode.ps1 prime` (arms :8080
  only) + `start-all.ps1` (full stack incl :8081). NOT llama-swap.
- llama-swap is a SEPARATE stack — "two stacks, do not merge"
  (C:\llm-serve\docs\HEXIS-INTEGRATION.md).
- Recover: `.\start-all.ps1` (idempotent, won't double-bind :8080). NEVER kill
  `llama-server.exe` to force-reload — no supervisor; embed:8081 always-on,
  killing it breaks ALL hydration → generic replies.
- `.\hexis-status.ps1` = fleet/server/character status.

## Generic/empty persona replies — two causes
- embed :8081 down → `hydrate()` fails → no persona injected → generic. Fix: `.\start-all.ps1`.
- q36 = Qwen3 reasoning model: eats token budget on reasoning_content. Fixed
  `core/llm.py` (openai-compat path): `extra_body={"chat_template_kwargs":
  {"enable_thinking":False}}`. `--reasoning-budget 0` NOT accepted by this
  llama.cpp build. Rebuild channels image + recreate workers to activate.

## hexis-native persona bring-up
- Proper recipe: `.local-notes/hexis-native-onboard.prompt.md`. Use real
  `hexis init` (`MSYS_NO_PATHCONV=1 docker compose run --rm … --entrypoint
  hexis`), NOT the SQL shortcut (skips consent/emotion/llm.heartbeat).
- Fresh DB = DB-scoped `DROP/CREATE DATABASE hexis_<P>` + apply db/*.sql in
  filename order. NEVER `docker compose down -v` / `db-manage.sh reset` /
  `hexis reset` (shared Postgres → wipes ALL personas).
- Consent is a real LLM gate; agent can decline — one clean retry max, never
  SQL-override. Vet cards fully (payloads hide past head + in lorebooks).

## NSFW / persona system-prompt injection
- `agent.persona_system_prompt` config key (per-persona DB) prepends card's
  `data.system_prompt`+`post_history_instructions` to LLM system prompt.
  Set via `set_persona_prompt.<P>.sql` (canonical re-seed; keep after DB wipe).
  Apply: `docker exec -i hexis_brain psql -U hexis_user -d hexis_<P> < set_persona_prompt.<P>.sql`
- Without it: `conversation.md` "honor your values/bounds" → model infers SFW
  posture → Qwen3 refuses in thinking → streaming yields "" → history poisoned.
- Empty-response guard in `channels/conversation.py` (stream_channel_message)
  prevents "" from being stored. If missing → perpetual silence after first refusal.
- Full NSFW onboard: `.local-notes/hexis-native-onboard-nsfw.prompt.md`.

## Throwaway DB for migration / schema validation
- Spin: `docker compose -p hexistrial -f docker-compose.yml -f docker-compose.trial.yml up -d db` with a `docker-compose.trial.yml` override pinning `container_name: hexis_brain_trial`, port `43816:5432` (43815 = live, 43817 = api, 43818 = anchor-test). Embedding URL stays `host.docker.internal:8081/v1/embeddings` (shared with live).
- Tear: `docker compose -p hexistrial -f docker-compose.yml -f docker-compose.trial.yml down -v` — `-p` namespace isolates volumes from live.
- Use for: validating migrations on anchor schema, building from a worktree at an old tag, running `pytest tests/db` against an isolated brain without touching live fleet.

## Compose ops
- `docker-compose.newchars.yml` = single source for ALL hexis-native personas
  (eni, mira, nines, death, cassiel, joje, monika). Per-persona files deprecated.
- `hexis_brain` = Docker container for shared Postgres (`db` service); holds all
  `hexis_<P>` databases. Port 43815→5432.
- `hexis_brain` container may be recreated by `up --build` when compose config
  changes — data is safe (volume persists without `-v`).

## Heartbeat liveness (verify autonomous loop ACTUALLY runs)
- Ground truth = `heartbeat_state` table per `hexis_<P>` DB (NOT config keys):
  `cnt`/`heartbeat_count`, `last_heartbeat_at`, `next_heartbeat_at`,
  `current_energy` (10=never ran, regens →20), `is_paused`, `init_stage`.
- "Promoted" = container Up AND per-DB gate (`agent.is_configured=true` +
  `agent.consent_status="consent"`) AND `heartbeat_count` climbing. First two
  are necessary-not-sufficient; only a rising cnt proves the loop runs.
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

## Windows / git-bash
- Native python: `C:/...` paths (git-bash `/c/...` fails) + `python -X utf8`.
- `MSYS_NO_PATHCONV=1` for docker `-v` mounts in git-bash (else "Character not found").
- Same `MSYS_NO_PATHCONV=1` for `docker exec hexis_X /app/...` — git-bash
  rewrites `/app/...` to `C:/Program Files/Git/app/...` and the exec fails.
- Don't pass huge values via psql `-v` argv (docker arg limit) — embed via stdin.
- `& script.ps1` in-session; don't use `powershell -ExecutionPolicy Bypass` (blocked).

## Fast Python iteration (no image rebuild)
- `docker cp local/file.py hexis_X_worker:/app/path/file.py && docker restart hexis_X_worker`
  — Python reloads from disk on restart (worker images set
  `PYTHONDONTWRITEBYTECODE=1` so no .pyc cache to bust). Use to test a
  1-file change on one container before full fleet rebuild + roll-out to all 11.

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
