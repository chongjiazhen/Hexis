# PR-4 Draft: sender-scoped recmem_recall_context

**Source commit (trial):** `2ad5a94 feat(recmem): bd106a8 PR-A sender-scoped recmem_recall_context`

**Branch name:** `feat/recmem-sender-scoped-recall`

**Base:** `main`

## Title

`feat(recmem): sender-scoped recall via subconscious_units.source_identity`

## Body

`subconscious_units.source_identity` is already a first-class concept on the canonical raw memory log (set via `recmem_ingest_turn`, present in indexes, used for idempotency). But `recmem_recall_context` doesn't currently surface it or use it for ranking.

This PR completes the round-trip:

- Adds `p_current_sender TEXT DEFAULT NULL` to `recmem_recall_context`. When provided, raw and derived hits whose `source_identity` matches receive a +0.1 own-sender boost on relevance score.
- Returns two new columns per row:
  - `source_identity TEXT` — null for global / never-tagged memories
  - `confidentiality TEXT` — `'own' | 'cross_partner' | NULL`, derived after the inter-tier union
- For derived memories (`epi_hits`, `sem_hits`), `source_identity` is derived via `mode() WITHIN GROUP` over the linked `subconscious_units.source_identity`, with `COALESCE(m.sender_id, ...)` for memories that already carry it inline (see companion PR for source propagation at consolidation time).

## Motivation

Use case: one persona, multiple DM partners (Discord/Telegram channels with distinct senders). With this change, recall favors the current partner's own history, and the caller can render a "from another session" marker for cross-partner hits — supporting mediator-style privilege where the persona is aware of cross-partner facts but doesn't disclose them. Enforcement is by persona prompt, not DB partition.

This aligns with the project's stated thesis of consent, boundaries, and the ability to refuse: a persona without sender-scoping leaks one user's context into another user's session by default.

## Files

- `db/31_functions_recmem.sql` — `recmem_recall_context` signature + body
- (companion PR adds `memories.sender_id` indexing + propagation; this PR works with or without it)

## Test plan

- [ ] `pytest tests/db/test_recmem_*.py` — existing tests pass with new columns added
- [ ] New test: ingest 3 turns from sender A + 2 from sender B; recall with `p_current_sender='A'` returns A turns scored higher, B turns marked `confidentiality='cross_partner'`, NULL-source turns marked `confidentiality=NULL`
- [ ] Backward-compat: callers that omit `p_current_sender` see no behavior change beyond the two new columns appended to the row shape

## Notes on signature change

Adding columns to RETURNS TABLE requires `DROP FUNCTION` before `CREATE OR REPLACE`. Migration is the standard `db/*.sql` re-run on schema rebuild; no separate migration script needed.
