# Model Serving & Capability Guard

> ECO/PRIME power modes are **retired** (ADR-020, `C:\ai-workspace\decisions\020_power_mode_retirement.md`).
> `set-power-mode.ps1`, `scripts/set_power_mode.py`, `power-profiles.psd1`,
> `hexis-launcher.ps1`, `make-power-shortcuts.ps1`, `hexis-vram-guard.ps1`, and the
> `agent.power_mode` DB key are all **gone**. If a note tells you to run one, the note
> is stale. Serving is owned by llm-serve; hexis is a pure consumer of the `:8090`
> router (ADR-019) and never picks a backend.

## Serving topology (CRITICAL — misreading this caused a full q36 outage)

- Ports: GPU chat :8080, embed :8081 (hexis-launched, ALWAYS-ON), CPU floor (nano)
  :8082. hexis consumes **`:8090`** (the inference router), which fails over between
  :8080 and :8082 — hexis never talks to :8080 directly and never chooses.
- **`:8080` is llm-serve's**, armed with `py infra\serve.py gpu <key>` (per-model
  tuning resolves from `C:\llm-serve\models.json`). hexis owns zero GPU-slot
  automation. `start-all.ps1` / `start.ps1` bring up the hexis-side stack (embed
  :8081; nano via `serve.py ensure-cpu`).
- llama-swap retired 2026-06-10 (orphan — never in the live path, no autostart) →
  archived at `C:\llama-swap.retired-2026-06-10`. Do NOT reintroduce a second
  `:8080` launcher; it caused config drift (24576/65536 confusion) for zero gain.
- NEVER kill `llama-server.exe` to force-reload — no supervisor; embed :8081 is
  always-on, and killing it breaks ALL hydration → generic replies.
- `.\hexis-status.ps1` = fleet/server/character status.

## GPU slot — claim / release (llm-serve owns the lock)

- Free the GPU (for a game, or your own model): `fleetctl gpu claim` → llm-serve takes
  a durable host-claim lock and swaps to the CPU floor. `fleetctl gpu release` drops
  the lock; the next request lazy-arms :8080 (ADR-017/018). Under the hood these shell
  `serve.py claim <owner>` / `serve.py release`.
- Every `:8080` arm path honors the lock — including the cron wake. That is the
  load-bearing invariant: if an arm path skips it, cron re-arms the 35B into your game.
- **Piggyback** (share a heavy model you loaded for yourself): prepend it to
  `INFERENCE_ROUTER_UPSTREAMS` at top priority and restart the router. Every persona's
  `hexis-active` resolves to it via the existing probe; no per-persona DB write.

## Capability guard — how hexis reacts to the backend it gets

`core/serving.py: on_cpu_floor()` GETs `:8090/health` and asks one question: is the
live upstream the CPU floor? It matches by **port** (`:8082`; override
`HEXIS_CPU_FLOOR_PORT`), never the router's label — the labels were renamed
prime/eco → gpu/cpu. **Fails open** (proceed) on any error, so a router blip never
silences the fleet.

- **CPU floor live → autonomous cycles are skipped**: heartbeat, subconscious
  maintenance, and alert reactions (`services/worker_service.py`). The 1B cannot follow
  the tool template; letting it run writes garbage into episodic memory (`tools/probe-eco`).
- **CPU floor live → interactive chat still works**, on the slim path
  (`services.chat._eco_slim_chat`): persona prompt + small anchor + last 8 turns →
  direct LLM, no tools, no recall. The turn **is** persisted (`_eco_remember` →
  `record_chat_turn_memory` → `subconscious_units`, tagged `metadata.origin='eco'` vs
  `'prime'`) so floor-vs-GPU reply quality stays measurable. Slim failure →
  `ECO_FALLBACK_REPLY`. The `origin='eco'` tag keeps its name on purpose: it is a
  persisted data contract and existing rows carry it.
- **Heartbeat on/off is a SEPARATE axis** — the manual `heartbeat_state.is_paused`
  switch (`scripts/pause_fleet.py`). Freeing the GPU does not pause cognition; pausing
  cognition does not free the GPU. Do not re-couple them.

## Model registry

- **Per-model serve flags (ctx/ngl/kv_quant/batch) are owned by**
  `C:\llm-serve\models.json`, keyed on the model's short key and consumed by
  `serve.py gpu <key>` — do NOT hardcode them in Hexis. Boundary doc:
  `C:\llm-serve\docs\HEXIS-INTEGRATION.md`.
- **After editing `C:\llm-serve\models.json`:** `cd C:\llm-serve;
  SKIP_HF_CHECKS=1 py -3.10 -m unittest infra/test_registry.py -v`
- **Dense vs MoE on 16 GB VRAM**: ~6 instances share the slot (`--parallel 1`).
  A dense 24B collapses under fleet concurrency (prompt-eval thrash → ~1 tok/s,
  truncated replies); use a MoE like Qwen3.6-35B-A3B (`q36`) — ~8× cheaper per-token
  eval, absorbs the fleet.

## Docker VM clock drift (PRIMARY gotcha — burns whole investigations)

- VM wall clock leaps hours mid-session (host sleep/resume, or a GPU claim/release
  swap). Breaks `next_heartbeat_at` scheduling (stuck→burst-fire) AND `docker logs --since`
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
  Recovery is llm-serve's: `serve.py watchdog <key>` re-arms a dead :8080 (ADR-020 §6B);
  the router meanwhile fails over to the CPU floor, so chat degrades rather than dying.

## Multi-persona & compose ops

- **Multi-persona**: ALL personas live in `docker-compose.newchars.yml`. Channel/worker
  code is baked into the image; a `core/` change needs a rebuild, not a restart. Bare
  `docker compose build` only builds `db` (worker services are profile-gated) — deploy
  with `docker compose -f docker-compose.yml -f docker-compose.newchars.yml up -d
  --no-deps --force-recreate --build $SVCS` where `$SVCS` is an explicit worker+api
  list (never `db`, to dodge the brain-IP wedge).
- **Probe CPU-floor/persona quality**: `tools/probe-eco/probe-all.sh` (runs N prompts
  through `chat_turn` per persona, scrubs probe-generated memories). Use when evaluating
  nano model swaps or sampling/prompt tuning. (Directory keeps its `probe-eco` name; the
  `origin='eco'` memory tag it filters on is unchanged.)
- **`start.ps1 -NanoOnly`** — bounce only the CPU floor (:8082, via `serve.py ensure-cpu`)
  after editing serve flags. Skips DB/chat/embed; avoids the ~4min :8080 arm timeout.
- **`logs/serve-<port>-stderr.log` is rotated on relaunch** by whichever launcher armed
  the port: prior log moved to `serve-<port>-stderr.<yyyyMMdd_HHmmss>.log` before the
  fresh handle truncates it. Newest 10 rotations kept. Diagnose a silent `:8080` death by
  inspecting the most recent rotated file.
