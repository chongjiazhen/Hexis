# Model Serving & Power Modes

## Serving topology (CRITICAL — misreading this caused a full q36 outage)

- Chat = per-character `llama-server` fleet, per-port: chat :8080, embed :8081
  (ALWAYS-ON), nano :8082. Managed by `set-power-mode.ps1 prime` (arms :8080
  only) + `start-all.ps1` (full stack incl :8081). This is the SOLE `:8080`
  launcher; per-model tuning resolves from `C:\llm-serve\models.json`.
- llama-swap retired 2026-06-10 (orphan — never in the live path, no autostart) →
  archived at `C:\llama-swap.retired-2026-06-10`. Do NOT reintroduce a second
  `:8080` launcher; it caused config drift (24576/65536 confusion) for zero gain.
- Recover: `.\start-all.ps1` (idempotent, won't double-bind :8080). NEVER kill
  `llama-server.exe` to force-reload — no supervisor; embed:8081 always-on,
  killing it breaks ALL hydration → generic replies.
- `.\hexis-status.ps1` = fleet/server/character status.

## Power mode behavior

- **ECO/PRIME single GPU slot**: all gpu-tier characters share ONE llama-server on
  :8080 serving `ActiveBig`. Switch via `set-power-mode.ps1 prime` after editing
  `power-profiles.psd1` `ActiveBig`. `hexis-launcher.ps1` = GUI editor of the same
  store (preserves all BigModels entries on Apply).
- **ECO mode** — `agent.power_mode` DB config key ('prime' | 'eco') is the single
  flag workers gate on; `set-power-mode.ps1 eco|prime` flips it atomically with
  `llm.*` configs. In ECO: chat path bypasses RLM + tool stack via
  `services.chat._eco_slim_chat` (persona prompt + small anchor + last 8 turns →
  direct LLM, no tools, no recall). The turn **is** still persisted via
  `_eco_remember` → `record_chat_turn_memory`, written to `subconscious_units`
  tagged `metadata.origin='eco'` (vs `'prime'`) so eco/prime quality stays
  measurable; heartbeat timer skips entirely. Slim failures → `ECO_FALLBACK_REPLY`.
  PRIME restores full RLM + agentic tool use.
- **Cold re-arm** (apply a new ActiveBig alias/tuning to a running :8080):
  `.\set-power-mode.ps1 eco` then `.\set-power-mode.ps1 prime` (`prime` alone
  skips relaunch if :8080 is up). Verify three-way — server `--alias` == char DB
  `llm.chat` == `models.json` alias — with read-only `.\hexis-status.ps1`.
- **`:8080` is owned by `set-power-mode.ps1`.** Never run `C:\llm-serve`
  `switch-model.ps1` / `infra\switch.py --llama` to drive it — no interlock
  between the two; switch.py's image-wide `taskkill /IM llama-server.exe` also kills
  the hexis CPU sidecars (:8081 embed, :8082 nano) and does not re-plan them.

## Model registry

- **Per-model serve flags (ctx/ngl/kv_quant/batch) are owned by**
  `C:\llm-serve\models.json`**, sourced by `set-power-mode.ps1` keyed on
  `ActiveBig` — do NOT hardcode them in Hexis. Boundary doc:
  `C:\llm-serve\docs\HEXIS-INTEGRATION.md`.
- **`power-profiles.psd1` `BigModels` entries are bare key pointers** (`'q36' = @{}`).
  The key IS the `C:\llm-serve\models.json` short key; `set-power-mode.ps1`
  resolves alias + gguf path + serve tuning from that single registry via HF-cache
  glob-walk.
- **`power-profiles.psd1` `Characters = @()` lists `nano`-tier exceptions ONLY.**
  `set-power-mode.ps1` defaults un-listed personas to `gpu`. Do NOT add a gpu-tier
  persona to the list.
- **`set-power-mode.ps1` discovers personas by RUNNING container, not by DB.**
  Order matters when onboarding a new persona: start the channel worker FIRST, then
  run `prime` to materialize `llm.chat` from `tier-managed` placeholder to the real
  alias. Running `prime` before the worker starts skips the new persona.
- **After editing `C:\llm-serve\models.json`:** `cd C:\llm-serve;
  SKIP_HF_CHECKS=1 py -3.10 -m unittest infra/test_registry.py -v`
- **Dense vs MoE on 16 GB VRAM**: ~6 instances share the slot (`--parallel 1`).
  A dense 24B collapses under fleet concurrency (prompt-eval thrash → ~1 tok/s,
  truncated replies); use a MoE like Qwen3.6-35B-A3B (`q36`) — ~8× cheaper per-token
  eval, absorbs the fleet.

## Docker VM clock drift (PRIMARY gotcha — burns whole investigations)

- VM wall clock leaps hours mid-session (host sleep/resume or ECO/PRIME GPU switch).
  Breaks `next_heartbeat_at` scheduling (stuck→burst-fire) AND `docker logs --since`
  (silent empty window — looks like a dead worker).
- RULE: before trusting ANY heartbeat-timing or `--since` evidence, run
  `docker exec hexis_brain date -u` and confirm it == real UTC.
- Host is UTC+8: host `Get-Date` (local) vs container `date -u` (UTC) is a
  built-in ~8h offset — compare same TZ or you'll diagnose a phantom skew.

## Persona anchor budget

- **Persona anchor ≤7KB** on ablx (16384 ctx). `agent.persona_system_prompt`
  (system_prompt + post_history) over ~7KB triggers heartbeat-overflow + cache
  pressure on :8080 — failure mode is silent process death once cache hits ~8 GiB.
  Fleet baseline: mira 5KB; sable 6.8KB intentional max. Reference condenses:
  `8220f2b` (sable), `6503790` (esme), `6117199` (vera). Condense via
  `gen_persona_sql.py` after trimming the card, then live-apply per troubleshooting note.
- **`agent.tools` config = per-persona chat tool allowlist.**
  `services.agent._allowed_tools_for_mode` filters `ToolContext.CHAT` registry by it
  (heartbeat keeps full registry). Names MUST match registered `ToolHandler` names —
  a stale name silently drops. Seed: `db/00_tables.sql:473`. After any registry
  rename: update the seed AND bulk-fix live DBs. Filter saves ~5.5K tokens/turn on
  the 42-tool registry.
- **Hard refusal / "DO NOT" rules belong in `post_history_instructions`, NOT
  mid-`system_prompt`.** The local model honors recency: post_history sits LAST in
  the assembled prompt before generation, gets the most weight. Pattern: prefix with
  `HARD RULE (apply before any other): ...`. Reference: Esme commit `2d1f5c0`.
- **`:8080` can die silently mid-task** (no crash trace; `serve-8080-stderr.log`
  just stops, last lines look healthy). `hexis-status.ps1` correctly reports DOWN.
  Direct confirmation: `netstat -ano | findstr :8080.*LISTEN` (no LISTEN line) and
  `Get-Process llama-server` (only :8081 + :8082 PIDs alive). Likely trigger = prompt
  cache pressure (~8 GiB cap) under fleet load from oversized anchors (see 7KB ceiling).
  Recovery: `.\set-power-mode.ps1 prime` (since :8080 is down, it relaunches).

## Multi-persona & compose ops

- **Multi-persona**: ALL personas live in `docker-compose.newchars.yml`. Channel/worker
  code is baked into the image; a `core/` change needs a rebuild, not a restart. Bare
  `docker compose build` only builds `db` (worker services are profile-gated) — deploy
  with `docker compose -f docker-compose.yml -f docker-compose.newchars.yml up -d
  --no-deps --force-recreate --build $SVCS` where `$SVCS` is an explicit worker+api
  list (never `db`, to dodge the brain-IP wedge).
- **Probe ECO/persona quality**: `tools/probe-eco/probe-all.sh` (runs N prompts through
  `chat_turn` per persona, scrubs probe-generated memories). Use when evaluating nano
  model swaps or sampling/prompt tuning.
- **`start.ps1 -NanoOnly`** — bounce only nano (:8082) after editing serve flags.
  Skips DB/chat/embed; avoids the ~4min :8080 timeout when stack restarted in ECO.
- **`set-power-mode.ps1` rotates `logs/serve-<port>-stderr.log` on relaunch** (commit
  pending 2026-05-25): prior log moved to `serve-<port>-stderr.<yyyyMMdd_HHmmss>.log`
  before `Start-Process -RedirectStandardError` opens fresh (which truncates). Newest
  10 rotations kept. Diagnose a silent `:8080` death by inspecting the most recent
  rotated file.
