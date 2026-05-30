# Multi-Character Group Chat — Parked Idea

**Status:** parked / interesting. Not building yet. Flagged 2026-05-19.

## Concept

Add multiple Hexis characters into one shared group and watch them converse
agent-to-agent (user as observer, not just participant).

## Current State: UNSUPPORTED

| Constraint | Evidence |
|---|---|
| Each character = isolated Hexis instance (own Postgres DB, workers, compose) | `docs/guides/multi-instance.md` |
| `AgentLoop` is single-agent by design (one agent + one user) | `core/agent_loop.py:2` |
| `channel_sessions` keyed by human `(channel_type, channel_id, sender_id)`; no persona/room/participant table | `db/22_tables_channels.sql:9` |

## Closest Existing Primitives

- **`is_group` flag** — one agent behaving in a multi-*human* channel
  (Discord/Telegram group), with "when to speak" guidance. Not agent-to-agent.
  `services/chat.py:139`, `services/agent.py:291`
- **`council` tool** — one agent spawns 5 synthetic personas for parallel
  analysis, reconciled by moderator. Personas have no independent memory and
  don't address each other. `core/tools/council.py`

## What Real Group-Chat Would Need

1. **Shared room / transport** — multiple instances subscribed to one channel
   (RabbitMQ topic, or a shared Telegram/Discord group).
2. **Turn-taking / addressing** — who speaks when; avoid infinite loops.
   `is_group` "when to speak" guidance is a partial seed.
3. **Cross-instance sender mapping** — each instance treats other characters'
   messages as inbound sender events (distinct `sender_id` per character).
   Mostly works with existing channel adapters.
4. **Loop + energy guardrails** — agent-to-agent burns energy/tokens unbounded
   without a stop condition.

## Cheapest Demo Path (no code)

Drop 2+ existing instances into one shared Telegram/Discord group, each with
`is_group` on, distinct bot tokens. They see each other as users.
**Risk:** response storms, no native turn-taking, energy drain.

## Open Questions

- Turn-taking: round-robin? moderator instance? energy-gated?
- Does observer want to inject mid-conversation, or pure spectate?
- Local-inference-only constraint → N concurrent instances = N model slots.
  Conflicts with single-GPU-slot ActiveBig schema (see power-modes).
