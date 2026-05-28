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

**Types**: episodic, semantic, procedural, strategic, working.

**Tables**: `memories` (base), `clusters` (thematic, centroid embeddings), `memory_neighborhoods` (precomputed neighbors), `memory_graph` (Apache AGE).

**Functions**: `fast_recall()` (hot-path retrieval), `create_*_memory()` (sender-scoped), `get_embedding()` (HTTP, cached), `run_heartbeat()`, `run_subconscious_maintenance()`.

**Sender scope**: `memories.sender_id` tags DM-partner memories; NULL = global. `fast_recall` gives +0.1 own-sender boost. Cross-channel sender_id is NOT unified.

## Channels (multi-portal)

`telegram, discord, slack, signal, whatsapp, imessage, matrix`. Adapter auto-starts when credentials in DB config or env var. Per-persona creds via `docker-compose.newchars.yml`. Allowlist: `channel.{type}.allowed_users`.

## Build, Test, and Development Commands

```bash
docker compose up -d                              # DB only
docker compose --profile active up -d              # + heartbeat + maintenance workers
docker compose down -v && docker compose up -d     # Full reset (wipes data)
hexis init                                         # Configure agent (gates heartbeats)
pytest tests -q                                    # All tests (Docker services must be up)
hexis status | hexis chat | hexis ingest | hexis mcp
```

## Coding Style

- Python: Black formatting, type hints, explicit names
- DB authority: schema logic in `db/*.sql`, not duplicated in Python
- Stateless workers: all state in Postgres, kill/restart safe

## Fix vs. Design Overreach

Scope the fix to the root cause. Don't re-architect around a symptom.

1. Is the bug actually here, or already fixed upstream?
2. Does the change fight a deliberate invariant? (e.g. outbox durability = "ACID for cognition")
3. Prefer observability over deletion — log age + kind at send, don't silently drop.

## Testing

- `pytest` + `pytest-asyncio` (session loop scope), integration tests with transactions/rollbacks
- Test seed memories: `array_fill(0.1, ARRAY[embedding_dimension()])::vector` (memories.embedding is NOT NULL)

## Commits & PRs

- Commits: short, imperative, **no `Co-Authored-By` trailers**
- PRs: include rationale, verification steps, DB reset requirements if any
- Call out changes to: `db/*.sql`, `docker-compose.yml`, `README.md`

## Config & Safety

- Secrets in `.env`, not DB; DB config stores env var *names* only
- Heartbeat gated until `agent.is_configured=true` (via `hexis init`)
- Never revert or discard files without asking

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
