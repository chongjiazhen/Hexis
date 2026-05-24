# Trial-Merge Conflicts — origin/main ← home-rig-local

Performed 2026-05-23 in throwaway worktree `C:/Users/User/.claude/jobs/f3783d2d/hexis-upstream`. Merge aborted cleanly; worktree returned to detached `origin/main`. Live `home-rig-local` untouched.

## Conflict summary

6 files conflicted. All in expected collision zones — no surprises.

| File | Regions | LOC | Severity | Resolution path |
|---|---:|---:|---|---|
| `.gitignore` | 1 | 81 | trivial | Union both ignore lists |
| `channels/conversation.py` | 3 | 709 | MEDIUM | Re-port sender_id into upstream's `_finalize_channel_turn_db` + compaction call to `remember_turn_raw` |
| `core/agent_loop.py` | 1 | 794 | LOW | Likely single-line context-attach reordering |
| `core/cognitive_memory_api.py` | 4 | 1607 | HIGH | Memory dataclass merge + hydrate signature + format_context wrap |
| `core/tools/registry.py` | 3 | 857 | MEDIUM | Tool-registration deltas (upstream moved registry into DB; local added tool entries) |
| `services/chat.py` | 8 | 770 | HIGH | Re-port sender_id thread + assessment strip into upstream's RecMem-rollout-instrumented shape |

## Concrete conflict patterns

### `core/cognitive_memory_api.py` — instructive case

**1. Memory dataclass (line 76):**
```
HEAD (upstream):              home-rig-local (local):
+ tier: str | None            + sender_id: str | None
+ source_unit_ids: list[UUID]
+ valid_until: datetime
```
**Resolution:** keep BOTH. All 4 fields are orthogonal. Merge = additive union.

**2. hydrate signature (line 225):**
```
HEAD:  session_id: UUID | str | None = None
LOCAL: current_sender: str | None = None
```
**Resolution:** keep BOTH params. Both are forward-passed downstream.

**3. hydrate body (line 251):**
```
HEAD:
    if use_recmem:
        return await self._recall_recmem(conn, query, memory_limit, session_id=session_id)
    return await self._recall_memories(conn, query, memory_limit)

LOCAL:
    return await self._recall_memories(conn, query, memory_limit, current_sender=current_sender)
```
**Resolution:** thread `current_sender` into `_recall_recmem` (this IS PR-A from port-shape-bd106a8.md — `recmem_recall_context` gets a sender param). Both branches accept current_sender:
```python
if use_recmem:
    return await self._recall_recmem(conn, query, memory_limit, session_id=session_id, current_sender=current_sender)
return await self._recall_memories(conn, query, memory_limit, current_sender=current_sender)
```

**4. format_context_for_prompt (line 1495):**
```
HEAD: tier-aware grouping (Subconscious / Episodic / Semantic sections)
LOCAL: confidentiality marker per row
```
**Resolution:** the confidentiality marker is a per-row decoration; tier grouping is structural. Marker decoration applies inside the per-row loop within each tier section. Combine:
```python
for tier in ("subconscious", "episodic", "semantic", None):
    group = [m for m in context.memories[:max_memories] if m.tier == tier]
    if not group: continue
    parts.append(tier_titles.get(tier, "## Relevant Memories"))
    for m in group:
        confidential = ""
        if m.sender_id is not None and m.sender_id != current_sender:
            confidential = "[confidential — from your session with another client] "
        # ... existing rendering
        parts.append(f"- {confidential}{m.content}{score}{trust}{src_kind}")
```

### `channels/conversation.py` — compaction flush

```
HEAD:
    if recmem_enabled:
        await mem.remember_turn_raw(... source_identity=f"compaction:{session_id}:{idx}:{digest}", ...)
    else:
        await mem.remember(... source_attribution={kind:"compaction_flush", ref:session_id, ...})

LOCAL:
    await mem.remember(... sender_id=sender_id, source_attribution={...})
```
**Resolution:** thread `sender_id` into BOTH branches. RecMem branch uses `source_identity={real_sender}:compaction:{idx}:{digest}` (PR-C from port-shape doc). Eager branch keeps `sender_id=sender_id`.

### `services/chat.py` — most surface area

8 regions. Pattern: every `_remember_conversation` callsite, every `chat_turn`/`stream_chat_turn` signature, every memory-write hook gets touched on BOTH sides for different reasons (upstream: RecMem rollout instrumentation; local: sender_id thread + assessment strip).

**Strategy for M3:** start from HEAD (upstream), re-apply local's changes as a CONCEPTUAL re-port (don't try to git cherry-pick). Read local's chat.py side-by-side, identify each local feature, port atop upstream's new shape.

Localfeatures to re-apply in services/chat.py:
- sender_id param on `chat_turn`/`stream_chat_turn` signatures
- sender_id forwarded into `run_agent`/`stream_agent`
- sender_id forwarded into `_remember_conversation` (now likely 1-line delegate to upstream's `record_chat_turn_memory` SQL function — needs sender as param)
- session-assessment block extraction on streaming path (Vera-specific, **keep local only**)
- chat hydrated context → system prompt (3bf21cd, separate patch)

### `core/tools/registry.py` — UNEXPECTED zone

Investigator didn't flag this. Cause: upstream `27eb5e2` moved tool handlers into `db/38_functions_db_native_tools.sql`, restructured registry. Local has additions to tool registry (per-persona tool allowlist `54651e7`, etc).

**Resolution path:** read upstream's new registry shape; re-add local tool allowlist logic in new structure. May need to consult `db/36_functions_tool_runtime.sql` to understand new policy model.

## Files that auto-merged cleanly (no conflict)

These had textual overlap but git resolved them:
- `db/00_tables.sql`, `db/01_indices.sql`, `db/04_functions_core.sql`, `db/05_functions_provenance_trust.sql` — additive merges (upstream added RecMem tables/indexes/columns; local added sender_id column + boost; no contested lines)
- `services/agent.py`, `services/worker_service.py` — additive

**Risk:** auto-merge doesn't mean SEMANTIC merge. Local's `fast_recall(text, int, p_current_sender)` and upstream's RecMem changes both modify `db/04_functions_core.sql` / `db/05_functions_provenance_trust.sql`. Need to read merged SQL output to verify:
- `fast_recall` still has 3-param sender-aware signature
- `create_*_memory` functions still accept `p_sender_id`
- No shadow/duplicate function definitions

This is the **silent-merge trap**. M3 must read merged SQL files and run pytest, not just trust git's "auto-merging" output.

## Estimated M3 effort

Re-port + verify, against new SQL surface:

| Patch | Hours |
|---|---:|
| Resolve 6 file conflicts (manual) | 2 |
| Port bd106a8 PR-A into db/31 `recmem_recall_context` | 1.5 |
| Port bd106a8 PR-B into db/31 apply_* functions | 2 |
| Port bd106a8 PR-C into db/34 `flush_channel_history_to_memory` | 0.5 |
| Re-port 4661566 history-cap into db/34 `finalize_channel_turn` | 1 |
| Re-port 55d0dc9 assessment strip (local-only, no upstream PR) | 1 |
| pytest tests/db tests/core | 0.5 (+ debug time TBD) |
| Verify silent-merge SQL (fast_recall, create_*) | 0.5 |
| **Total** | ~9 hours focused work |

Not a sit-down-and-finish job. Recommend M3 split across 2-3 sessions.
