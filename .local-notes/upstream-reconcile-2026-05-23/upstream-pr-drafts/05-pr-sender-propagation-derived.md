# PR-5 Draft: sender propagation to derived memories

**Source commit (trial):** `5d00116 feat(recmem): bd106a8 PR-B propagate source_identity to derived memories`

**Branch name:** `feat/recmem-sender-propagation`

**Base:** `main` (sequencing: ship after PR-4, or combine into one PR if maintainer prefers)

## Title

`feat(recmem): propagate source_identity to derived episodic and semantic memories`

## Body

Companion to PR-4 ("sender-scoped recall"). PR-4 derives a derived memory's primary sender on the fly via `mode() WITHIN GROUP` over linked source units at retrieval time. That works but joins through `memory_source_units` on every recall. This PR stores the primary sender at consolidation time so retrieval can read it directly off `memories.sender_id`.

Changes:

- `create_memory_with_embedding` (db/05): add `p_sender_id TEXT DEFAULT NULL` as the 8th positional param. Backwards-compatible — existing callers passing 7 args see no change.
- `apply_recmem_episode_create` (db/31): compute `v_primary_sender` once per task via `mode() WITHIN GROUP (ORDER BY source_identity)` filtering NULL. Pass to each created episode.
- `apply_recmem_semantic_facts` (db/31): same.
- `apply_recmem_episode_merge` (db/31): COALESCE-backfill the target memory's `sender_id` only when currently NULL. Conservative — never overwrites an established identity, even if the new merge units belong to a different sender.

Mixed-sender consolidations (rare) get `NULL`, which sender-scoped recall treats as global (no boost, no confidentiality marker). Fail-safe in the privacy direction.

## Pre-req

This PR assumes `memories.sender_id TEXT` exists. If upstream doesn't have it, the prep schema migration is small (single `ALTER TABLE memories ADD COLUMN sender_id TEXT;` + nullable, no backfill). Happy to fold it into this PR if preferred.

## Files

- `db/05_functions_provenance_trust.sql` — `create_memory_with_embedding` signature
- `db/31_functions_recmem.sql` — `apply_recmem_episode_create`, `apply_recmem_episode_merge`, `apply_recmem_semantic_facts`

## Test plan

- [ ] `pytest tests/db/test_recmem_*.py` — existing tests pass
- [ ] New test: ingest raw turns from sender A; trigger `episode_create` consolidation; verify derived `memories(type='episodic').sender_id = 'A'`
- [ ] New test: same with mixed senders → `sender_id IS NULL`
- [ ] New test: pre-existing memory with `sender_id = 'A'` merged with raw units from sender B; verify `memories.sender_id` stays `'A'` (conservative backfill)
