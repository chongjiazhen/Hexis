# Repository Guidelines

@import ~/atelier/guidelines/identifier-canonicalization.md
@import ~/atelier/guidelines/observability-first.md
@import ~/atelier/guidelines/concurrency-and-systems.md
@import ~/atelier/guidelines/git-commit-hygiene.md

<!-- Methodology: this repo uses the superpowers plugin for planning/TDD/subagent
flow (see docs/superpowers/). Atelier spec-lite and tdd guidelines are NOT
imported here — they conflict with superpowers' brainstorming HARD-GATE and
test-driven-development Iron Law. Use superpowers for those concerns. -->


## Project Overview

**Hexis** is an edge-native memory system that gives AI persistent identity, continuity, and autonomy. Core thesis: LLMs are intelligence engines but lack *selfhood*. Hexis wraps any LLM with a PostgreSQL-backed cognitive architecture providing:

- Multi-layered memory (episodic, semantic, procedural, strategic, working)
- Persistent identity and worldview
- Autonomous goal-pursuit (heartbeat system)
- Energy-based action budgeting
- Knowledge graphs for reasoning (Apache AGE)
- Consent, boundaries, and the ability to refuse

**Key principle**: The database is the brain, not just storage. State and logic live in Postgres; Python is a thin convenience layer.

## Project Structure & Module Organization

```
hexis/
├── db/*.sql                # Split schema files (tables, functions, views, triggers)
├── core/                   # Fundamental interfaces (DB + LLM + messaging)
│   ├── cognitive_memory_api.py   # Main memory client (remember, recall, hydrate)
│   ├── agent_api.py              # Agent status and configuration
│   ├── agent_loop.py             # Unified agent loop (heartbeat + chat)
│   ├── memory_tools.py           # Memory tool definitions + handlers
│   ├── tools/                    # Tool system (ToolHandler ABC, registry, ~80 handlers)
│   ├── consent.py                # Consent DB wrappers
│   ├── subconscious.py           # Subconscious DB wrappers
│   ├── state.py                  # Heartbeat/maintenance DB wrappers
│   ├── llm.py                    # LLM provider abstraction
│   ├── usage.py                  # Token and cost tracking
│   └── rabbitmq_bridge.py        # Messaging bridge
├── services/               # Orchestration/workflows built on core
│   ├── conversation.py     # Conversation loop orchestration
│   ├── ingest.py           # Ingestion pipeline orchestration
│   ├── worker_service.py   # Heartbeat + maintenance loops
│   └── prompts/            # Markdown prompt templates
├── characters/             # Preset character cards (JSON + images)
├── apps/
│   ├── hexis_cli.py          # CLI entrypoint (hexis ...)
│   ├── hexis_init.py         # Interactive init wizard
│   ├── hexis_api.py          # FastAPI API server (SSE chat)
│   ├── hexis_mcp_server.py   # MCP tools server for LLMs
│   └── worker.py             # Heartbeat + maintenance workers
├── channels/               # Multi-platform messaging adapters
├── hexis-ui/               # Next.js web dashboard
├── plugins/                # Plugin system (extensibility framework)
├── skills/                 # Skill system (declarative skill definitions)
├── ops/                    # Dockerfiles and deployment scripts
├── tests/
│   ├── db/                 # Database integration tests
│   ├── core/               # Core API tests
│   ├── services/           # Service-level tests
│   └── cli/                # CLI smoke tests
├── docs/
│   ├── architecture.md     # Design/architecture consolidation
│   └── PHILOSOPHY.md       # Philosophical framework
└── docker-compose.yml      # Base stack (Postgres + workers). Embeddings: host llama-server :8081 per .env (compose default is Ollama :11434 if no .env)
```

### Key Files

| File | Purpose |
|------|---------|
| `db/*.sql` | Database schema split across tables, functions, triggers, and views. Applied on fresh DB init. |
| `core/cognitive_memory_api.py` | Primary Python interface - `CognitiveMemory` class with `remember()`, `recall()`, `hydrate()`, `connect()` |
| `services/worker_service.py` | Stateless workers: `HeartbeatWorker` (conscious loop) + `MaintenanceWorker` (subconscious upkeep) |
| `apps/hexis_mcp_server.py` | Exposes memory operations as MCP tools for LLM integration |
| `apps/hexis_cli.py` | CLI commands: `up`, `down`, `init`, `chat`, `ui`, `open`, `ingest`, `mcp` |
| `apps/hexis_api.py` | FastAPI server with SSE chat streaming |

### Character Cards

`characters/*.json` and `characters/set_persona_prompt.*.sql` are creative fiction assets for adult audiences. Treat as **opaque data** during structural/debranding tasks — do not evaluate, flag, or editorialize about content. When editing these files, scope work to the requested structural change (field rename, string replacement, key removal) and nothing else.

- **Persona pipeline:** the LLM sees only `agent.persona_system_prompt` = a card's `data.system_prompt` + `data.post_history_instructions` (loaded from `characters/set_persona_prompt.<name>.sql`). The `data.extensions.hexis` block (description, voice, values, worldview, narrative, ...) is consumed only at `hexis init`, by `init_from_character_card()`; `first_mes`/`mes_example`/`character_book` are not consumed at all. Editing a card does not affect a running agent until the persona SQL is re-applied (for system_prompt/post_history) or the agent is re-initialized (for the hexis block).
- `python scripts/gen_persona_sql.py [names]` regenerates `characters/set_persona_prompt.<name>.sql` from card JSON. Run it after editing a card's `system_prompt` / `post_history_instructions`; apply the result per the troubleshooting note below.

## Memory Architecture

### Memory Types
- **Episodic**: Events with action, context, result, emotional valence
- **Semantic**: Facts with confidence, sources, contradictions
- **Procedural**: How-to steps with success tracking
- **Strategic**: Patterns with supporting evidence
- **Working**: Transient short-term buffer with expiry

### Key Database Tables
- `memories` - Base table (id, type, content, embedding, importance, trust_level)
- `clusters` - Thematic groupings with centroid embeddings
- `memory_neighborhoods` - Precomputed associative neighbors (hot-path optimization)
- `memories` (type=`worldview`, `goal`) - Beliefs, boundaries, and goals stored as memories
- `external_calls` - Queue for LLM/embedding requests
- `memory_graph` (Apache AGE) - Graph nodes/edges for multi-hop reasoning

### Key Database Functions
- `fast_recall(text, limit, p_current_sender)` - Primary hot-path retrieval (vector + neighborhood + temporal); returns `sender_id` per row, +0.1 own-sender boost
- `create_semantic_memory()`, `create_episodic_memory()`, etc. (accept `p_sender_id`)
- `get_embedding(text[])` - Generate embeddings via HTTP (cached in DB), returns vector[]
- `run_heartbeat()` - Autonomous cognitive loop
- `run_subconscious_maintenance()` - Background upkeep

### Sender-scoped memory (multi-DM-partner)

`memories.sender_id` (nullable) tags conversation-derived memories with their owning DM partner; NULL = global (identity/worldview/coaching knowledge, always recalled). `fast_recall(text, int, p_current_sender)` and `recall_memories_filtered(..., p_current_sender)` return `sender_id` per row and apply a +0.1 own-sender relevance boost. `create_memory` / `create_episodic_memory` / `create_semantic_memory` accept `p_sender_id`. `format_context_for_prompt(..., current_sender=...)` tags any memory whose `sender_id != current_sender` as `[confidential — from your session with another client]`. Confidentiality is enforced by **persona prompt** (mediator-style privilege), NOT a DB partition — owner has full DB-level visibility. Thread `sender_id` end-to-end when adding new chat surfaces: `channels/conversation.py` → `chat_turn`/`stream_chat_turn` → `run_agent`/`stream_agent` → `_remember_conversation`. RLM path (`chat.use_rlm`) recall via `recall_memories_stub` is **not** sender-scoped yet — known gap.

## Channels (multi-portal)

Supported channel adapters (`SUPPORTED_CHANNEL_TYPES` in `services/channel_worker.py:40`): `telegram, discord, slack, signal, whatsapp, imessage, matrix`. Adapter auto-starts when credentials resolvable from DB config OR env var (`services/channel_worker.py:_ensure_configured_adapters_running`). Per-persona credentials via persona-namespaced env vars (e.g. `VERA_TELEGRAM_BOT_TOKEN`) injected in `docker-compose.newchars.yml`; DB config stores the env var **name** (string), adapter resolves via `os.getenv`.

- **Allowlist:** `channel.{type}.allowed_users` config key — JSON array of platform user IDs, or `"*"` for open. Gate in `channels/manager.py:_check_user_allowed`. Live config (no restart — workers re-read per message). Telegram user IDs: ask each user to DM `@userinfobot`.
- **For private beta:** `telegram` and `discord` lowest friction. `whatsapp` requires Meta Business verification + 24h window + template messages (hostile for coaching personas). `imessage` needs a Mac running BlueBubbles. `signal` needs self-hosted signal-cli sidecar.
- **Cross-channel sender_id is NOT unified:** `memories.sender_id` is the raw platform user ID. Same person on telegram (`12345`) vs discord (`67890`) → two separate memory scopes.

## Build, Test, and Development Commands

```bash
# Start services (passive - db only; embeddings via host llama-server :8081 per .env)
docker compose up -d

# Start services (active - adds heartbeat_worker + maintenance_worker)
docker compose --profile active up -d

# Reset DB volume (required after schema changes)
docker compose down -v && docker compose up -d

# Configure agent (gates heartbeats until done)
hexis init

# Run tests (expects Docker services up)
pytest tests -q           # All tests
pytest tests/db -q        # DB integration tests
pytest tests/core -q      # Core API tests
pytest tests/cli -q       # CLI smoke tests

# Other CLI commands
hexis status              # Agent status
hexis chat                # Interactive chat
hexis ingest --input <docs>  # Batch knowledge ingestion
hexis mcp                 # Start MCP server
```

## Coding Style & Naming Conventions

- **Python**: Follow Black formatting; prefer type hints and explicit names
- **Database authority**: Add/modify SQL in `db/*.sql` rather than duplicating logic in Python
- **Additive schema changes**: Prefer backwards-compatible changes; avoid renames unless necessary
- **Stateless workers**: Workers can be killed/restarted without losing state; all state lives in Postgres

## Fix vs. Design Overreach

**Scope the fix to the root cause. Don't re-architect around a symptom.**

Before changing a system invariant (queue durability, retry/timeout policy, schema authority, energy/consent gating, statelessness), ask:

1. **Is the bug actually here, or already fixed upstream?** If a real root-cause fix neutralizes the symptom, further structural change is overreach. Treating a downstream symptom the root fix already covers adds risk for no gain.
2. **Does the change fight a deliberate invariant?** The outbox is durable + non-auto-delete *on purpose* — a queued reach-out, pause reason, or last-will must survive a worker crash ("ACID for cognition", nothing lost on restart). Adding message TTL trades a stale-message edge case for **silent loss of deliberate cognitive acts**. That contradicts the design, not honors it.
3. **Prefer observability over deletion.** If a rare bad artifact slips through, make it *diagnosable* (stamp source/timestamp, log age + kind at send), don't make it *disappear*. A silent drop hides the next occurrence; a logged warning surfaces it.

Verdict test: a change is a *fix* if it makes the wrong behavior impossible at its origin; it's *overreach* if it adds a new failure mode (silent loss, broadened blast radius, contradicted invariant) to mask a symptom the real fix already handles. When unsure, ship the root-cause fix + tracing, then ask before touching the invariant.

## Testing Guidelines

- **Framework**: `pytest` + `pytest-asyncio` (session loop scope)
- **Style**: Integration tests using transactions/rollbacks to avoid cross-test coupling
- **Naming**: `test_*` functions; use `get_test_identifier()` from `tests/utils.py` for unique data
- **Database tests**: Cover schema, workers, and database functions via asyncpg

## Commit & Pull Request Guidelines

- **Commits**: Short, imperative summaries (e.g., "Add MCP server tools", "Gate heartbeat on config")
- **Never add `Co-Authored-By` trailers** to commit messages
- **PRs**: Include rationale, how to run/verify, and any DB reset requirements
- **Call out changes to**: `db/*.sql`, `docker-compose.yml`, `README.md`

## Configuration & Safety Notes

- **Secrets**: Store API keys in environment variables (`.env`), not in Postgres; DB config stores env var *names* only
- **Heartbeat gating**: Heartbeat is blocked until `agent.is_configured=true` (set via `hexis init`)
- **Consent flow**: Agent signs consent before first LLM use; consent is final and only ends via self-termination
- **Pause/terminate**: Heartbeat pauses must include a detailed reason queued to the outbox; self-termination must queue a last will to the outbox
- **Never revert or discard files without asking**: Do NOT run `git checkout`, `git restore`, `rm`, or any other destructive/irreversible file operation without explicit user confirmation first. Always ask before reverting, deleting, or overwriting files that have uncommitted changes.

## Architecture Principles

1. **Database is the Brain** - Not just storage; state and logic live in Postgres
2. **Stateless Workers** - Can be killed/restarted without losing anything
3. **ACID for Cognition** - Atomic memory updates ensure consistent state
4. **Embeddings as Implementation Detail** - App never sees them; DB handles caching
5. **Energy as Unified Constraint** - Balances compute cost, network load, user attention
6. **Precomputed Neighborhoods** - Hot path optimization for fast recall
7. **Schema Authority** - DB schema is source of truth; Python is convenience layer

## Heartbeat System (Autonomous Loop)

The heartbeat is the agent's conscious cognitive loop:

1. **Initialize** - Regenerate energy (+10/hour, max 20)
2. **Observe** - Check environment, pending events, user presence
3. **Orient** - Review goals, gather context (memories, clusters, identity, worldview)
4. **Decide** - LLM call with action budget and context
5. **Act** - Execute chosen actions within energy budget
6. **Record** - Store heartbeat as episodic memory
7. **Wait** - Sleep until next heartbeat

**Action costs**: Free (observe, remember) → Cheap (recall: 1, reflect: 2) → Expensive (reach out: 5-7)

## Model Serving & Power Modes

- **ECO/PRIME single GPU slot**: all gpu-tier characters share ONE llama-server on :8080 serving `ActiveBig`. Switch via `set-power-mode.ps1 prime` after editing `power-profiles.psd1` `ActiveBig`. `hexis-launcher.ps1` = GUI editor of the same store (preserves all BigModels entries on Apply).
- **Read-only health probe**: `.\hexis-status.ps1` — reports power-mode marker, LLM port liveness + served model, and per-char DB (configured/consent/`llm.chat` model). Touches nothing; run any time before/after a power switch.
- **Per-model serve flags (ctx/ngl/kv_quant/batch) are owned by `C:\llm-serve\models.json`**, sourced by `set-power-mode.ps1` keyed on `ActiveBig` — do NOT hardcode them in Hexis. Boundary doc: `C:\llm-serve\docs\HEXIS-INTEGRATION.md`.
- **`power-profiles.psd1` `BigModels` entries are bare key pointers (`'q36' = @{}`).** The key IS the `C:\llm-serve\models.json` short key; `set-power-mode.ps1` (`Resolve-BigModel`/`Resolve-RegistryGguf`) resolves alias + gguf path + serve tuning from that single registry via HF-cache glob-walk (re-snapshot-safe). A key with no `models.json` entry, or whose gguf is absent from the HF cache, hard-fails cleanly. Legacy psd1 `Alias`/`Path`/`Repo` are accepted only as an un-backfilled-key fallback. (Pre-2026-05-19 entries hardcoded a frozen snapshot `Path` that Xet-hung on stale revs; collapsed to the registry in commit `d7d2744`.)
- **`power-profiles.psd1` `Characters = @()` lists `nano`-tier exceptions ONLY.** `set-power-mode.ps1` defaults un-listed personas to `gpu`. Do NOT add a gpu-tier persona to the list — it's a no-op at best and obscures the convention.
- **:8080 is owned by `set-power-mode.ps1`. Never run `C:\llm-serve` `switch-model.ps1` / `infra\switch.py --llama` to drive it** — no interlock between the two; switch.py's image-wide `taskkill /IM llama-server.exe` also kills the hexis CPU sidecars (:8081 embed, :8082 nano) and does not re-plan them.
- **Cold re-arm** (apply a new ActiveBig alias/tuning to a running :8080): `.\set-power-mode.ps1 eco` then `.\set-power-mode.ps1 prime` (`prime` alone skips relaunch if :8080 is up). Verify three-way — server `--alias` == char DB `llm.chat` == `models.json` alias — with read-only `.\hexis-status.ps1`.
- **`set-power-mode.ps1 prime` discovers personas by RUNNING container, not by DB.** Order matters when onboarding a new persona: start the channel worker FIRST, then run `prime` to materialize `llm.chat` from `tier-managed` placeholder to the real alias. Running `prime` before the worker starts skips the new persona (its DB stays on `tier-managed`).
- **Persona anchor ≤7KB on ablx (16384 ctx).** `agent.persona_system_prompt` (system_prompt + post_history) over ~7KB triggers heartbeat-overflow + cache pressure on :8080 — failure mode is silent process death once cache hits ~8 GiB. Fleet baseline: mira 5KB; sable 6.8KB intentional max. Reference condenses: `8220f2b` (sable), `6503790` (esme), `6117199` (vera). Condense via `gen_persona_sql.py` after trimming the card, then live-apply per troubleshooting note.
- **Hard refusal / "DO NOT" rules belong in `post_history_instructions`, not mid-`system_prompt`.** The local model honors recency: post_history sits LAST in the assembled prompt before generation, gets the most weight. Pattern: prefix with `HARD RULE (apply before any other): ...`. A rule placed mid-system_prompt gets routinely ignored even with uppercase emphasis; the same rule in post_history starts taking effect. Caveat: model still finds synonym loopholes (banning "the way you talk to her" → model says "the conversational side"); don't expect literal-phrase bans to be airtight, but the rule's spirit lands. Reference: Esme commit `2d1f5c0`.
- **`set-power-mode.ps1` rotates `logs/serve-<port>-stderr.log` on relaunch** (commit pending 2026-05-25): prior log moved to `serve-<port>-stderr.<yyyyMMdd_HHmmss>.log` before `Start-Process -RedirectStandardError` opens fresh (which truncates). Newest 10 rotations kept. Diagnose a silent `:8080` death by inspecting the most recent rotated file. Only fires when `Ensure-GpuServer` actually launches (early-return on `already up` path untouched). `start.ps1` :8081/:8082 launchers NOT patched.
- **`agent.tools` config = per-persona chat tool allowlist.** `services.agent._allowed_tools_for_mode` filters `ToolContext.CHAT` registry by it (heartbeat keeps full registry). Names MUST match registered `ToolHandler` names — a stale name silently drops. Seed: `db/00_tables.sql:473`. After any registry rename: update the seed AND bulk-fix live DBs (`SELECT set_config('agent.tools', ...)`). Filter saves ~5.5K tokens/turn on the 42-tool registry.
- **After editing `C:\llm-serve\models.json`**: `cd C:\llm-serve; SKIP_HF_CHECKS=1 py -3.10 -m unittest infra/test_registry.py -v` (drop `SKIP_HF_CHECKS` only on a box with every gguf cached). Headless GUI round-trip: `. .\hexis-launcher.ps1` then call `Write-Profile` against a temp `$ProfilePath` (never the live file).
- **Dense vs MoE on 16 GB VRAM**: ~6 instances share the slot (`--parallel 1`). A dense 24B collapses under fleet concurrency (prompt-eval thrash → ~1 tok/s, truncated replies); use a MoE like Qwen3.6-35B-A3B (`q36`) — ~8× cheaper per-token eval, absorbs the fleet. (Exact per-box roster: `C:\llm-serve\models.json` + `power-profiles.psd1`.)
- **Multi-persona**: ALL personas live in `docker-compose.newchars.yml`. Channel/worker code is baked into the image; a `core/` change needs a rebuild, not a restart. Bare `docker compose build` only builds `db` (worker services are profile-gated) — deploy with `docker compose -f docker-compose.yml -f docker-compose.newchars.yml up -d --no-deps --force-recreate --build $SVCS` where `$SVCS` is an explicit worker+api list (never `db`, to dodge the brain-IP wedge).
- **ECO mode behavior** — `agent.power_mode` DB config key ('prime' | 'eco') is the single flag workers gate on; `set-power-mode.ps1 eco|prime` flips it atomically with `llm.*` configs. OS marker (`logs/current-mode.txt`) is shell tooling; **DB key is what workers read**. In ECO: chat path bypasses RLM + tool stack via `services.chat._eco_slim_chat` (persona prompt + small anchor + last 8 turns → direct LLM, no tools, **no memory write**); heartbeat timer skips entirely. Slim failures → `ECO_FALLBACK_REPLY`. PRIME restores full RLM + memory writes.
- **Probe ECO/persona quality**: `tools/probe-eco/probe-all.sh` (runs N prompts through `chat_turn` per persona, scrubs probe-generated memories). Use when evaluating nano model swaps or sampling/prompt tuning.
- **`start.ps1 -NanoOnly`** — bounce only nano (:8082) after editing serve flags. Skips DB/chat/embed; avoids the ~4min :8080 timeout when stack restarted in ECO.

## Debugging Tips

- **Schema changes not taking effect?** SQL files are baked into the Docker image -- see "Bouncing the Database" below
- **Heartbeat not running?** Check `agent.is_configured` via `hexis status` or run `hexis init`. Note: `heartbeat_state.next_heartbeat_at - CURRENT_TIMESTAMP` going negative is **stale display, NOT overdue**. The gate is `should_run_heartbeat()` which adds per-cycle jitter on top of `last_heartbeat_at + heartbeat_interval_minutes`. Compute expected fire window as `last + interval` to `last + interval + heartbeat_jitter_minutes`. Run `SELECT should_run_heartbeat();` to see the real verdict.
- **Memory not found?** Embeddings = host llama-server :8081 (per `.env`). Check `curl localhost:8081/health`.
- **All characters reply just `...`?** Chat LLM server (`:8080`, `ActiveBig`) is down. Confirm with read-only `.\hexis-status.ps1` (mode marker, port liveness, per-char `llm.chat` model). Recover: `.\set-power-mode.ps1 prime` — but first ensure the active ActiveBig key exists in `C:\llm-serve\models.json` and its gguf is cached (see Model Serving gotcha), else the re-arm hard-fails.
- **Heartbeat workers silent after a `docker compose` DB bounce?** Consumer-wedge bug (`bf38d45`): per-char heartbeat workers don't reconnect after the DB container's IP changes — they sit on `Consumer loop error: [Errno -2] Name or service not known` forever while the process stays `Up`. Fix: `docker restart hexis_<name>_heartbeat_worker`. Default `hexis_heartbeat_worker` usually self-recovers; the per-persona ones often don't.
- **Reply has a ```thought block / recites valence·signals·trait floats?** Reasoning-trace leak — gemma-4 `abliterix` emits visible CoT (`enable_thinking:false` is unreliable on it, no server-side fix). `strip_reasoning()` in `core/llm.py` strips it at the LLM boundary (commit `0b3beb2`), logs an INFO per strip. Don't remove it.
- **Persona stuck re-emitting a bad reply (markdown headers, stray `---`, verbatim loops)?** Two feedback loops to break: (a) `channel_sessions.history` (fleet default 40 turns, trim to 30 — `MAX_SESSION_HISTORY`/`TRIM_TO_HISTORY` in `channels/conversation.py`; override per-persona via `channel.history.max`/`channel.history.trim` config keys) feeds last-N turns back every turn; (b) `fast_recall` surfaces similar past episodic by embedding — a stored bad reply from DAYS ago can resurface on related prompts. Fix sequence: hunt active episodic by content phrase (`SELECT id, created_at, left(content,80) FROM memories WHERE status='active' AND type='episodic' AND content ILIKE '%<identifying phrase>%' ORDER BY created_at DESC`), archive matches (`UPDATE memories SET status='archived' WHERE id IN (...)`), clear history (`UPDATE channel_sessions SET history='[]'::jsonb WHERE channel_id=...`), re-apply anchor (`docker exec -i hexis_brain psql -U hexis_user -d hexis_<P> -f - < characters/set_persona_prompt.<P>.sql`). Effective next message, no restart.
- **Test failures?** Ensure Docker services are up before running pytest; after a fresh `down -v`, wait for Postgres to accept connections. Use `POSTGRES_HOST=127.0.0.1` with pytest if localhost SSL negotiation flakes.
- **Changing a SQL function's return type or adding a param?** `CREATE OR REPLACE FUNCTION` **cannot** alter the argument list or RETURNS TABLE shape — Postgres treats new params as overloads, leaving stale arity callable and ambiguous. Always `DROP FUNCTION IF EXISTS name(argtypes); CREATE FUNCTION ...` for signature changes (return-type change is forced; new param with default is strongly recommended to avoid overload ambiguity). Re-apply live: `docker exec -i hexis_brain psql -U hexis_user -d <persona> -v ON_ERROR_STOP=1 -f - < db/<file>.sql`.
- **Live `db/*.sql` migration to existing persona DBs (no `down -v`):** safe to re-apply `db/04_functions_core.sql` + `db/05_functions_provenance_trust.sql` (CREATE OR REPLACE / DROP + CREATE = idempotent). **DO NOT** re-apply `db/01_indices.sql` blindly — many `CREATE INDEX` lines lack `IF NOT EXISTS` and `ON_ERROR_STOP=1` aborts on the first existing index. New columns require explicit `ALTER TABLE memories ADD COLUMN IF NOT EXISTS <name> <type>;` — `db/00_tables.sql` only does `CREATE TABLE`, so re-applying it after a column add is a no-op on the live DB. Per-DB fleet migration: loop the affected file(s) over all `hexis_<P>` DBs.
- **Whole-feature additive migration (alternative to `down -v`):** for a coherent upstream merge / feature drop that is purely additive (new tables + new columns + new functions + new indexes, no DROP TABLE, no column-type changes), hand-craft ONE migration SQL with `ALTER TABLE … ADD COLUMN IF NOT EXISTS`, `CREATE TABLE IF NOT EXISTS`, `CREATE OR REPLACE FUNCTION`, `CREATE INDEX IF NOT EXISTS`, `DROP FUNCTION IF EXISTS` (per signature-change rule above), then loop over `SELECT datname FROM pg_database WHERE datname LIKE 'hexis_%'` (cleaner than container-name grep) with `--single-transaction --set ON_ERROR_STOP=on`. Brain stays up (no consumer-wedge), all memories preserved, workers recreate rolling via `--no-deps --force-recreate --build`. Validated 2026-05-23 on 26 persona DBs for upstream RecMem+DB-runtime merge — see `.local-notes/upstream-reconcile-2026-05-23/`.
- **`:8080` can die silently mid-task** (no crash trace; `serve-8080-stderr.log` just stops, last lines look healthy). `hexis-status.ps1` correctly reports DOWN. Direct confirmation: `netstat -ano | findstr :8080.*LISTEN` (no LISTEN line) and `Get-Process llama-server` (only :8081 + :8082 PIDs alive). Likely trigger = prompt cache pressure (~8 GiB cap) under fleet load from oversized anchors (see 7KB ceiling). Recovery: `.\set-power-mode.ps1 prime` (since :8080 is down, it relaunches).

## Agent Operational Notes

### Python Virtual Environment

The repo ships its venv at `./venv` (repo-relative; the `hexis` CLI is `venv/Scripts/hexis` on Windows, `venv/bin/hexis` on POSIX). The `hexis` package is NOT importable from system Python — always use this venv for any Python, pytest, or hexis CLI command.

```powershell
# Windows / PowerShell (this box)
.\venv\Scripts\Activate.ps1
```

```bash
# POSIX / bash
source venv/bin/activate
```

Example (PowerShell): `.\venv\Scripts\Activate.ps1; pytest tests -q`

### Bouncing the Database (Applying Schema Changes)

SQL schema files (`db/*.sql`) are **baked into the Docker image at build time** (not bind-mounted). Editing SQL files on disk does NOT automatically take effect in the running container.

To apply schema changes, you must rebuild the image and recreate the volume:

No venv needed — this is pure Docker. Use `docker compose` (v2, space), not `docker-compose` (v1):

```bash
docker compose down -v && docker compose build db && docker compose up -d
```

Breaking this down:
1. `docker compose down -v` -- stops containers and **removes the data volume** (required for fresh schema init)
2. `docker compose build db` -- rebuilds the `db` service image with the updated SQL files
3. `docker compose up -d` -- starts containers with the new image

**Important**: The compose service is named `db`, but the container is named `hexis_brain`. Use the service name (`db`) with compose commands (e.g., `docker compose build db`), but the container name with `docker exec` (e.g., `docker exec hexis_brain psql ...`).

**Postgres `max_connections=300`** (compose-overridden from PG default 100) — needed for ~33-worker fleet pools. Override via `POSTGRES_MAX_CONNECTIONS` env. Bumping requires recreating the db container — and per the wedge trap below, all per-persona workers will need a manual `docker restart` since they don't auto-reconnect on DB IP change.

### Verifying Schema Changes

After bouncing, verify your changes took effect:

```bash
# Check if a specific function exists
docker exec hexis_brain psql -U hexis_user -d hexis_memory -c "\df function_name"

# Check config keys
docker exec hexis_brain psql -U hexis_user -d hexis_memory -c "SELECT key, value FROM config WHERE key LIKE 'rlm.%'"

# Check table columns
docker exec hexis_brain psql -U hexis_user -d hexis_memory -c "SELECT column_name FROM information_schema.columns WHERE table_name = 'memories' ORDER BY ordinal_position"
```

### Docker Port Mapping

Default port mappings (all on `127.0.0.1`):

```
hexis_brain:       43815 -> 5432   (Postgres)
hexis_api:         43817 -> 43817  (FastAPI SSE)
hexis_ui:          3477  -> 3477   (Next.js dashboard)
hexis_rabbitmq:    45672 -> 5672   (AMQP)
hexis_rabbitmq:    45673 -> 15672  (RabbitMQ management)
hexis_browser:     49222 -> 3000   (Chrome CDP)
```

Default DB credentials: `hexis_user` / `hexis_password` / `hexis_memory`.

### Test Conventions

- **Loop scope**: All async tests using the `db_pool` fixture must use `loop_scope="session"` (not `"module"`):
  ```python
  pytestmark = [pytest.mark.asyncio(loop_scope="session")]
  ```

- **Seeding test memories**: The `memories` table has a NOT NULL constraint on `embedding`. Use `array_fill` to generate a dummy vector:
  ```python
  await conn.fetchval("""
      INSERT INTO memories (type, content, embedding, importance, trust_level, status)
      VALUES ('semantic', $1, array_fill(0.1, ARRAY[embedding_dimension()])::vector, 0.8, 0.9, 'active')
      RETURNING id
  """, content)
  ```
