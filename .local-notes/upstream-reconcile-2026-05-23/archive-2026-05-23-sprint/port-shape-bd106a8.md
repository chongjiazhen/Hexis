# Port Shape: bd106a8 (sender-scoped recall) onto upstream RecMem

**Local patch:** `bd106a8 feat(memory): sender-scoped recall with confidentiality marker`
**Risk:** HIGH (textual conflict on every touched file) — but **STRUCTURALLY HALF-DONE BY UPSTREAM**.

## What bd106a8 does (current local shape)

- Adds `memories.sender_id` (nullable) column. NULL = global / identity / worldview / coaching knowledge.
- Threads `sender_id` end-to-end: `channels/conversation.py` → `chat_turn`/`stream_chat_turn` → `run_agent`/`stream_agent` → `_remember_conversation`.
- `fast_recall(text, int, p_current_sender)` returns `sender_id` per row + applies +0.1 own-sender boost.
- `recall_memories_filtered(..., p_current_sender)` same boost + filter shape.
- `create_memory` / `create_episodic_memory` / `create_semantic_memory` accept `p_sender_id`.
- `format_context_for_prompt(..., current_sender=...)` tags cross-partner memories `[confidential — from your session with another client]`. **Confidentiality enforced by persona prompt** (mediator-style privilege), not DB partition.
- Known gap: RLM path (`chat.use_rlm`) via `recall_memories_stub` not sender-scoped.

## Upstream's shape (after origin/main today)

### Already handled (good news)

- **`subconscious_units.source_identity TEXT`** = upstream's direct analog of `sender_id`. Stored on raw turn ingest.
- **End-to-end plumbing exists** on ingest path:
  - `prepare_channel_turn(p_message JSONB)` reads `message->>'sender_id'` for session lookup + rate-limit (db/34:220).
  - Caller passes sender into `record_chat_turn_memory(... p_source_identity, ...)` (db/34:65).
  - Which passes into `recmem_ingest_turn(... p_source_identity, ...)` (db/31:55).
  - Which INSERTs into `subconscious_units.source_identity`.
- Sender identity is a **first-class concept on the canonical memory log**.

### Gaps (where bd106a8's intent doesn't exist upstream)

1. **`recmem_recall_context(p_query, p_k_sub, p_k_epi, p_k_sem, p_session_id)`** — NO sender param. No own-sender boost. No cross-partner labeling on returned rows (db/31:925).
2. **Derived memories** (`memories.episodic` / `semantic` created by `apply_recmem_episode_create` / `apply_recmem_episode_merge` / `apply_recmem_semantic_facts`) **do NOT propagate source_identity** from their source units. Sender lineage is implicit only via `memory_source_units` → `subconscious_units.source_identity` (must JOIN to recover).
3. **`flush_channel_history_to_memory`** synthesizes its own `source_identity` string: `'compaction:' || p_session_id::text || ':' || stored::text || ':' || digest` (db/34:336). **Loses the real sender_id.** Compaction-flushed turns won't be sender-scoped. Bug pre-existing upstream.
4. **Eager / direct-promotion path** (`record_chat_turn_memory` calls `create_episodic_memory(...)` at db/34:132, 150) doesn't pass sender_id into the derived memory at all.

## Port shape (3 patches, upstream-PR-shaped)

### PR-A: feat(recmem): sender-scoped recall via source_identity

Augment `recmem_recall_context` in `db/31_functions_recmem.sql`:

```sql
CREATE OR REPLACE FUNCTION recmem_recall_context(
    p_query TEXT,
    p_k_sub INT DEFAULT 10,
    p_k_epi INT DEFAULT 5,
    p_k_sem INT DEFAULT 10,
    p_session_id UUID DEFAULT NULL,
    p_current_sender TEXT DEFAULT NULL  -- NEW
) RETURNS TABLE (
    tier TEXT,
    item_id UUID,
    content TEXT,
    memory_type TEXT,
    score FLOAT,
    source_unit_ids UUID[],
    source_attribution JSONB,
    created_at TIMESTAMPTZ,
    trust_level FLOAT,
    source_identity TEXT,           -- NEW
    confidentiality TEXT             -- NEW: 'own'|'cross_partner'|NULL
)
```

Logic changes:
- raw_hits: select `s.source_identity`; apply `+ 0.1` boost where `s.source_identity = p_current_sender AND p_current_sender IS NOT NULL`.
- epi_hits / sem_hits: LEFT JOIN `memory_source_units` → `subconscious_units` → derive `source_identity` as `mode()` (most common) over source units. Apply same own-sender boost.
- `confidentiality` column computed:
  - `'own'` when `source_identity = p_current_sender`
  - `'cross_partner'` when `source_identity IS NOT NULL AND source_identity <> p_current_sender AND p_current_sender IS NOT NULL`
  - `NULL` otherwise (global memory OR no current sender given)

Caller (Python in chat path or, post-DB-runtime migration, the SQL function consuming this) renders the prompt-side `[confidential — from your session with another client]` marker when `confidentiality = 'cross_partner'`. Keeps DB query semantic-pure.

### PR-B: feat(recmem): propagate source_identity to derived memories

In `apply_recmem_episode_create` (db/31:723), `apply_recmem_episode_merge` (db/31:603), `apply_recmem_semantic_facts` (db/31:843):

After determining `source_unit_ids`, compute primary identity:
```sql
SELECT mode() WITHIN GROUP (ORDER BY source_identity)
FROM subconscious_units WHERE id = ANY(p_source_unit_ids) AND source_identity IS NOT NULL
```

Store in derived memory's `source_attribution`:
```sql
source_attribution = source_attribution || jsonb_build_object('sender_id', <primary>)
```

(OPTIONAL upgrade: add `memories.sender_id` column for indexable filtering — but `source_attribution->>'sender_id'` works for v1 with a partial expression index.)

This makes the `recmem_recall_context` join in PR-A unnecessary for derived memories — they'd carry sender inline. Faster + simpler. Keep PR-A's join as fallback for older derived memories pre-dating PR-B.

### PR-C: fix(recmem): preserve real sender through compaction flush

In `flush_channel_history_to_memory` (db/34:291):

Look up real sender from session:
```sql
SELECT sender_id INTO real_sender FROM channel_sessions WHERE id = p_session_id;
```

Replace synthetic-only key with sender + disambiguator:
```sql
source_identity := COALESCE(real_sender, 'session') || ':compaction:' || stored::text || ':' || digest;
```

Or pass `real_sender` separately, append synthetic suffix only as idempotency disambiguator. Result: compaction-flushed raw units carry the actual partner identity, sender-scoped recall works on them.

## Upstream sell

Upstream's model assumes single-DB-per-agent (no multi-partner-in-one-DB design). But:
- `subconscious_units.source_identity` is **first-class already** — the table designer anticipated identity tagging.
- Sender-scoping aligns with stated Hexis thesis: **consent, boundaries, ability to refuse** (PHILOSOPHY.md, CLAUDE.md). A persona that talks to multiple users without leaking session-A facts into session-B is closer to "selfhood with boundaries" than a global-memory persona.
- Mediator-style privilege (DB-owner sees all; persona prompt enforces confidentiality) is a low-cost shape that doesn't fragment the DB or impose row-level security.

Frame PRs as "completing what `subconscious_units.source_identity` already implies."

## Local-only carry-overs (NOT for upstream)

- `recall_memories_stub` / RLM path sender-scoping → keep local until upstream RLM exists.
- `format_context_for_prompt` (legacy, pre-RecMem) → upstream may have removed this; if RecMem retrieval is now sole path, drop the local edit entirely after merge.

## Validation

```bash
# After porting in trial worktree:
pytest tests/db/test_recmem_*.py -q
pytest tests/db/test_chat_channel.py -q
# Add new test: tests/db/test_sender_scoped_recmem_recall.py
#   - ingest 3 turns from sender A, 2 from sender B
#   - recmem_recall_context(query, ..., p_current_sender='A') returns A turns boosted + confidentiality='cross_partner' on B turns
#   - confidentiality NULL on global memory (source_identity IS NULL)
```

## Files touched (upstream PR-A scope)

- `db/31_functions_recmem.sql` (recmem_recall_context signature + body)
- `core/cognitive_memory_api.py` (hydrate_recmem caller wires current_sender param)
- `services/chat.py` (or db/34_functions_chat_channel.sql, depending on where the recall callsite landed)
- `tests/db/test_recmem_recall_sender.py` (new)
