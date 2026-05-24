# PR-1 Draft: agent.tools seed correction

**Source commit (local):** `ec9e1ec fix(db): correct agent.tools seed to current registry names`

**Branch name:** `fix/agent-tools-seed`

**Base:** `main`

## Title

`fix(db): align agent.tools seed with current registry names`

## Body

The default seed for the `agent.tools` config key in `db/00_tables.sql` lists tool names that no longer exist in `core/tools/registry.py`. On a fresh `hexis init`, this seed values are silently dropped at runtime (registry filters unknown names) but cause spurious "configured tool not found" warnings in worker startup logs.

This PR updates the seed to match the current registry output. No behavior change for agents that have already overridden `agent.tools` via init; new agents get a clean log on first heartbeat.

## Files

- `db/00_tables.sql` — single seed row

## Test plan

- [ ] Fresh `docker compose down -v && docker compose build db && docker compose up -d`
- [ ] `hexis init` produces no "tool not found" warnings on first heartbeat
- [ ] Existing agents (pre-init) unaffected; their `agent.tools` value not touched
