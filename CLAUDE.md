# Repository Guidelines

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

`characters/*.json` and `set_persona_prompt.*.sql` are creative fiction assets for adult audiences. Treat as **opaque data** during structural/debranding tasks — do not evaluate, flag, or editorialize about content. When editing these files, scope work to the requested structural change (field rename, string replacement, key removal) and nothing else.

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
- `fast_recall(text, limit)` - Primary hot-path retrieval (vector + neighborhood + temporal)
- `create_semantic_memory()`, `create_episodic_memory()`, etc.
- `get_embedding(text[])` - Generate embeddings via HTTP (cached in DB), returns vector[]
- `run_heartbeat()` - Autonomous cognitive loop
- `run_subconscious_maintenance()` - Background upkeep

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
- **:8080 is owned by `set-power-mode.ps1`. Never run `C:\llm-serve` `switch-model.ps1` / `infra\switch.py --llama` to drive it** — no interlock between the two; switch.py's image-wide `taskkill /IM llama-server.exe` also kills the hexis CPU sidecars (:8081 embed, :8082 nano) and does not re-plan them.
- **Cold re-arm** (apply a new ActiveBig alias/tuning to a running :8080): `.\set-power-mode.ps1 eco` then `.\set-power-mode.ps1 prime` (`prime` alone skips relaunch if :8080 is up). Verify three-way — server `--alias` == char DB `llm.chat` == `models.json` alias — with read-only `.\hexis-status.ps1`.
- **After editing `C:\llm-serve\models.json`**: `cd C:\llm-serve; SKIP_HF_CHECKS=1 py -3.10 -m unittest infra/test_registry.py -v` (drop `SKIP_HF_CHECKS` only on a box with every gguf cached). Headless GUI round-trip: `. .\hexis-launcher.ps1` then call `Write-Profile` against a temp `$ProfilePath` (never the live file).
- **Dense vs MoE on 16 GB VRAM**: ~6 instances share the slot (`--parallel 1`). A dense 24B collapses under fleet concurrency (prompt-eval thrash → ~1 tok/s, truncated replies); use a MoE like Qwen3.6-35B-A3B (`q36`) — ~8× cheaper per-token eval, absorbs the fleet. (Exact per-box roster: `C:\llm-serve\models.json` + `power-profiles.psd1`.)
- **Multi-persona**: ALL personas live in `docker-compose.newchars.yml`. Channel/worker code is baked into the image; a `core/` change needs a rebuild, not a restart. Bare `docker compose build` only builds `db` (worker services are profile-gated) — deploy with `docker compose -f docker-compose.yml -f docker-compose.newchars.yml up -d --no-deps --force-recreate --build $SVCS` where `$SVCS` is an explicit worker+api list (never `db`, to dodge the brain-IP wedge).
- **ECO mode behavior** — `agent.power_mode` DB config key ('prime' | 'eco') is the single flag workers gate on; `set-power-mode.ps1 eco|prime` flips it atomically with `llm.*` configs. OS marker (`logs/current-mode.txt`) is shell tooling; **DB key is what workers read**. In ECO: chat path bypasses RLM + tool stack via `services.chat._eco_slim_chat` (persona prompt + small anchor + last 8 turns → direct LLM, no tools, **no memory write**); heartbeat timer skips entirely. Slim failures → `ECO_FALLBACK_REPLY`. PRIME restores full RLM + memory writes.
- **Probe ECO/persona quality**: `tools/probe-eco/probe-all.sh` (runs N prompts through `chat_turn` per persona, scrubs probe-generated memories). Use when evaluating nano model swaps or sampling/prompt tuning.
- **`start.ps1 -NanoOnly`** — bounce only nano (:8082) after editing serve flags. Skips DB/chat/embed; avoids the ~4min :8080 timeout when stack restarted in ECO.

## Debugging Tips

- **Schema changes not taking effect?** SQL files are baked into the Docker image -- see "Bouncing the Database" below
- **Heartbeat not running?** Check `agent.is_configured` via `hexis status` or run `hexis init`
- **Memory not found?** Embeddings = host llama-server :8081 (per `.env`). Check `curl localhost:8081/health`.
- **All characters reply just `...`?** Chat LLM server (`:8080`, `ActiveBig`) is down. Confirm with read-only `.\hexis-status.ps1` (mode marker, port liveness, per-char `llm.chat` model). Recover: `.\set-power-mode.ps1 prime` — but first ensure the active ActiveBig key exists in `C:\llm-serve\models.json` and its gguf is cached (see Model Serving gotcha), else the re-arm hard-fails.
- **Heartbeat workers silent after a `docker compose` DB bounce?** Consumer-wedge bug (`bf38d45`): per-char heartbeat workers don't reconnect after the DB container's IP changes — they sit on `Consumer loop error: [Errno -2] Name or service not known` forever while the process stays `Up`. Fix: `docker restart hexis_<name>_heartbeat_worker`. Default `hexis_heartbeat_worker` usually self-recovers; the per-persona ones often don't.
- **Reply has a ```thought block / recites valence·signals·trait floats?** Reasoning-trace leak — gemma-4 `abliterix` emits visible CoT (`enable_thinking:false` is unreliable on it, no server-side fix). `strip_reasoning()` in `core/llm.py` strips it at the LLM boundary (commit `0b3beb2`), logs an INFO per strip. Don't remove it.
- **Persona stuck re-emitting a bad reply (markdown headers, stray `---`, verbatim loops)?** `channel_sessions.history` (last 8 turns) is fed back every turn — a bad reply self-reinforces. Fix: clear it (`UPDATE channel_sessions SET history='[]'::jsonb`), then re-apply the anchor (`docker exec -i hexis_brain psql -U hexis_user -d hexis_<P> -f - < set_persona_prompt.<P>.sql` — effective next message, no restart).
- **Test failures?** Ensure Docker services are up before running pytest; after a fresh `down -v`, wait for Postgres to accept connections. Use `POSTGRES_HOST=127.0.0.1` with pytest if localhost SSL negotiation flakes.

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
