# M3 Progress — 2026-05-23

## Done

### Phase 1: Conflict resolution (✅ COMPLETE)

Trial-merge branch `trial-merge-port-2026-05-23` exists in worktree `C:/Users/User/.claude/jobs/f3783d2d/hexis-upstream`.

Commit: `feba84b merge(trial): home-rig-local into origin/main RecMem+DB-runtime`

All 6 conflicted files resolved per recipes in `trial-merge-conflicts.md`:

| File | Approach | Notes |
|---|---|---|
| `.gitignore` | Union | trivial |
| `core/agent_loop.py` | Keep both | `allowed_names` (local) + `_start_turn` (upstream) coexist |
| `core/tools/registry.py` | Gate DB fast-path on allowlist | When `allowed_names is not None`, fall through to in-process path (DB fast-path doesn't respect allowlist) |
| `core/cognitive_memory_api.py` | Union all + thread sender | Memory fields union (`tier/source_unit_ids/valid_until + sender_id`); hydrate signature takes both `session_id` and `current_sender`; `_recall_recmem` and `_recall_memories` both accept `current_sender`; `format_context_for_prompt` shares row renderer with confidentiality marker across tier-aware AND legacy paths |
| `channels/conversation.py` | Upstream-collapsed + sender-aware compaction | Adopted `_finalize_channel_turn_db` collapsed call; **PR-C delivered**: compaction flush preserves real sender via `f"{identity_prefix}:compaction:..."` form in RecMem branch |
| `services/chat.py` | Union helpers + merge `_remember_conversation` signatures | ECO helpers + RecMem rollout helpers both kept; `_remember_conversation` accepts BOTH `source_identity` (upstream) and `sender_id` (local), with `sender_id` falling back to source_identity; all 3 callsites pass both params; `_capture_session_assessment` preserved on both chat_turn AND stream_chat_turn paths |

### Verification done
- All Python modules parse + import cleanly (5 modules tested).
- Silent-merge SQL verified: `memories.sender_id` column present; `fast_recall(... p_current_sender)`, `create_memory/episodic/semantic(... p_sender_id)` signatures intact.
- No remaining conflict markers.

### Verification NOT done (needs Docker + DB)
- `pytest tests -q` — requires Docker stack up against trial branch's SQL
- End-to-end persona chat
- DB function compile (would surface signature drift on `create_episodic_memory` if upstream changed its arity in `record_chat_turn_memory` SQL function path)

## Pending — Phase 2: bd106a8 PR-A + PR-B SQL augmentations

These are **net-new code**, not conflict resolution. Different category from Phase 1 — benefits from review before commit because the shape becomes the upstream-PR proposal.

### PR-A: `recmem_recall_context` gets `p_current_sender`

**File:** `db/31_functions_recmem.sql`, function at line 925.

**Add to signature:**
```sql
CREATE OR REPLACE FUNCTION recmem_recall_context(
    p_query TEXT,
    p_k_sub INT DEFAULT 10,
    p_k_epi INT DEFAULT 5,
    p_k_sem INT DEFAULT 10,
    p_session_id UUID DEFAULT NULL,
    p_current_sender TEXT DEFAULT NULL   -- NEW
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
    source_identity TEXT,                 -- NEW (NULL for global)
    confidentiality TEXT                  -- NEW: 'own'|'cross_partner'|NULL
)
```

**Body changes:**
- `raw_hits` CTE: SELECT `s.source_identity`; add `+ CASE WHEN s.source_identity = p_current_sender AND p_current_sender IS NOT NULL THEN 0.1 ELSE 0 END` to score.
- `epi_hits` / `sem_hits` CTEs: aggregate source-unit identities via existing `LEFT JOIN memory_source_units msu`:
  ```sql
  (SELECT mode() WITHIN GROUP (ORDER BY su.source_identity)
   FROM subconscious_units su WHERE su.id = ANY(array_agg(msu.subconscious_unit_id))
     AND su.source_identity IS NOT NULL) AS source_identity
  ```
  Apply same boost.
- `confidentiality` column derived per row:
  - `'own'` if `source_identity = p_current_sender`
  - `'cross_partner'` if both non-null and differ
  - `NULL` otherwise

**Python caller updates** (CMA `_recall_recmem`): pass `current_sender` SQL arg; populate `Memory.sender_id` from `source_identity` column on returned rows.

### PR-B: derived memories carry source_identity

**File:** `db/31_functions_recmem.sql`, functions `apply_recmem_episode_create` (line 723), `apply_recmem_episode_merge` (603), `apply_recmem_semantic_facts` (843).

**Pattern:** before INSERT/UPDATE of derived memory, compute primary sender:
```sql
SELECT mode() WITHIN GROUP (ORDER BY source_identity)
INTO v_primary_sender
FROM subconscious_units
WHERE id = ANY(v_source_unit_ids) AND source_identity IS NOT NULL;
```

Either:
- (a) Stuff into `source_attribution || jsonb_build_object('sender_id', v_primary_sender)` — JSONB-only, no schema change. Cheap.
- (b) Pass to `create_episodic_memory(..., p_sender_id => v_primary_sender)` — leverages existing `memories.sender_id` column from local patch. Better indexability.

**Recommended:** (b). `memories.sender_id` already exists post-merge. `create_episodic_memory` already accepts `p_sender_id`. No new schema.

### PR-C: Compaction sender preservation (✅ ALREADY DONE in Phase 1)

Done in `channels/conversation.py` flush path. SQL `flush_channel_history_to_memory` (db/34:291) also synthesizes its own key — should mirror the fix there for full coverage. Small TODO.

## Decision checkpoint (M4 input)

**Phase 1 (conflict resolution) is mergeable** into `home-rig-local` as-is if user wants to start consuming upstream's RecMem changes. Risk: SQL functions reference each other; without Phase 2 SQL augmentations applied, sender-scoping works on legacy `fast_recall` path but NOT on `recmem_recall_context` path. If `memory.recmem_hydrate_enabled = false` (default per upstream rollout plan Phase 0/1), this is fine — `fast_recall` is the active recall.

**Phase 2 (SQL augmentations) before live merge** is safer. Ports sender-scoping into RecMem so a future `recmem_hydrate_enabled = true` flip doesn't suddenly lose multi-DM-partner isolation.

**Phase 2 before upstream PR** is mandatory — PR-A is the actual proposal, not a side-effect of conflict resolution.

Recommend: Phase 2 SQL next, in a separate commit on the trial branch, then run pytest. After SQL works, decision gate on real merge (M4).

## Files in trial worktree state

- Branch: `trial-merge-port-2026-05-23`
- Commit: `feba84b`
- Working tree: clean
- Pre-merge anchor: `pre-upstream-merge-2026-05-23` (on `home-rig-local`, the rollback point)

Live `home-rig-local` UNCHANGED. Live fleet UNAFFECTED.
