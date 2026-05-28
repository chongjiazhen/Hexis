# Repository Guidelines

## Project Overview

**Hexis** is an edge-native memory system that gives AI persistent identity, continuity, and autonomy.
Core thesis: LLMs are intelligence engines but lack *selfhood*. Hexis wraps any LLM with a
PostgreSQL-backed cognitive architecture providing:

- Multi-layered memory (episodic, semantic, procedural, strategic, working)
- Persistent identity and worldview
- Autonomous goal-pursuit (heartbeat system)
- Energy-based action budgeting
- Knowledge graphs for reasoning (Apache AGE)
- Consent, boundaries, and the ability to refuse

**Key principle**: The database is the brain, not just storage. State and logic live in Postgres;
Python is a thin convenience layer.

## Project Structure

```
hexis/
├── db/*.sql                # Split schema files (tables, functions, views, triggers)
├── core/                   # Fundamental interfaces (DB + LLM + messaging)
├── services/               # Orchestration/workflows built on core
├── characters/             # Preset character cards (JSON + images)
├── apps/                   # CLI, API server, MCP server, workers
├── channels/               # Multi-platform messaging adapters
├── hexis-ui/               # Next.js web dashboard
├── plugins/                # Plugin system
├── skills/                 # Skill system
├── ops/                    # Dockerfiles and deployment scripts
├── tests/                  # db/, core/, services/, cli/
└── docs/                   # architecture.md, PHILOSOPHY.md
```

Key files: `db/*.sql`, `core/cognitive_memory_api.py`, `services/worker_service.py`,
`apps/hexis_mcp_server.py`, `apps/hexis_cli.py`, `apps/hexis_api.py`.

See `.local-notes/guidelines/schema-migration.md` for schema change workflow.

## Memory Architecture

### Memory Types
- **Episodic**: Events with action, context, result, emotional valence
- **Semantic**: Facts with confidence, sources, contradictions
- **Procedural**: How-to steps with success tracking
- **Strategic**: Patterns with supporting evidence
- **Working**: Transient short-term buffer with expiry

### Key Database Tables
- `memories` — base table (id, type, content, embedding, importance, trust_level)
- `clusters` — thematic groupings with centroid embeddings
- `memory_neighborhoods` — precomputed associative neighbors (hot-path optimization)
- `memory_graph` (Apache AGE) — graph nodes/edges for multi-hop reasoning

### Key Database Functions
- `fast_recall(text, limit, p_current_sender)` — primary hot-path retrieval (vector + neighborhood + temporal)
- `create_semantic_memory()`, `create_episodic_memory()`, etc. — accept `p_sender_id`
- `get_embedding(text[])` — embeddings via HTTP, cached in DB
- `run_heartbeat()`, `run_subconscious_maintenance()`

### Sender-scoped memory

`memories.sender_id` (nullable) tags conversation-derived memories with their owning DM partner;
NULL = global (identity/worldview/coaching knowledge, always recalled). `fast_recall` applies a
+0.1 own-sender relevance boost. Confidentiality is enforced by **persona prompt** (mediator-style
privilege), NOT a DB partition. Cross-channel sender_id is NOT unified (same person on telegram
vs discord → separate scopes).

## Channels (multi-portal)

Supported: `telegram, discord, slack, signal, whatsapp, imessage, matrix`. Adapter auto-starts
when credentials resolvable from DB config OR env var. Per-persona credentials via persona-namespaced
env vars in `docker-compose.newchars.yml`. Allowlist via `channel.{type}.allowed_users` config key.

## Build, Test, and Development Commands

```bash
docker compose up -d                              # DB only
docker compose --profile active up -d              # + heartbeat + maintenance workers
docker compose down -v && docker compose up -d     # Full reset (wipes data)
hexis init                                         # Configure agent (gates heartbeats)
pytest tests -q                                    # All tests (Docker services must be up)
hexis status | hexis chat | hexis ingest | hexis mcp
```

## Coding Style & Naming Conventions

- **Python**: Follow Black formatting; prefer type hints and explicit names
- **Database authority**: Add/modify SQL in `db/*.sql` rather than duplicating logic in Python
- **Additive schema changes**: Prefer backwards-compatible changes; avoid renames unless necessary
- **Stateless workers**: Workers can be killed/restarted without losing state; all state lives in Postgres

## Fix vs. Design Overreach

Scope the fix to the root cause. Don't re-architect around a symptom.

1. Is the bug actually here, or already fixed upstream?
2. Does the change fight a deliberate invariant? (e.g. outbox durability = "ACID for cognition")
3. Prefer observability over deletion — log age + kind at send, don't silently drop.

## Testing Guidelines

- **Framework**: `pytest` + `pytest-asyncio` (session loop scope)
- **Style**: Integration tests using transactions/rollbacks
- **Seeding test memories**: `memories` has NOT NULL on `embedding` — use
  `array_fill(0.1, ARRAY[embedding_dimension()])::vector`

## Commit & Pull Request Guidelines

- **Commits**: Short, imperative summaries
- **Never add `Co-Authored-By` trailers** to commit messages
- **PRs**: Include rationale, how to run/verify, and any DB reset requirements
- **Call out changes to**: `db/*.sql`, `docker-compose.yml`, `README.md`

## Configuration & Safety Notes

- **Secrets**: API keys in `.env`, not in Postgres; DB config stores env var *names* only
- **Heartbeat gating**: Blocked until `agent.is_configured=true` (via `hexis init`)
- **Consent flow**: Agent signs consent before first LLM use; consent is final
- **Pause/terminate**: Heartbeat pauses must include a detailed reason queued to the outbox
- **Never revert or discard files without asking**

## Architecture Principles

1. **Database is the Brain** — state and logic live in Postgres
2. **Stateless Workers** — kill/restart without losing anything
3. **ACID for Cognition** — atomic memory updates
4. **Embeddings as Implementation Detail** — app never sees them; DB handles caching
5. **Energy as Unified Constraint** — balances compute, network, attention
6. **Precomputed Neighborhoods** — hot path optimization for fast recall
7. **Schema Authority** — DB schema is source of truth; Python is convenience layer

## References (loaded on demand — not in CLAUDE.md token budget)

| Topic | File |
|---|---|
| Heartbeat system, liveness, worker wedge | `.local-notes/guidelines/heartbeat.md` |
| Model serving, power modes, GPU, clock drift | `.local-notes/guidelines/model-serving.md` |
| Debugging tips, Windows gotchas, fast iteration | `.local-notes/guidelines/debugging.md` |
| Schema migration, live bounce, function signature changes | `.local-notes/guidelines/schema-migration.md` |
| Persona onboard, NSFW, consent, bring-up recipe | `.local-notes/hexis-native-onboard.prompt.md` |
| NSFW persona onboard | `.local-notes/hexis-native-onboard-nsfw.prompt.md` |
| Serving topology, fleet status | `CLAUDE.local.md` |
