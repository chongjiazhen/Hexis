# M4 Decision Gate — Real Merge into `home-rig-local`

## State

Trial branch `trial-merge-port-2026-05-23` in worktree `C:/Users/User/.claude/jobs/f3783d2d/hexis-upstream` holds:

```
5d00116 feat(recmem): bd106a8 PR-B propagate source_identity to derived memories
2ad5a94 feat(recmem): bd106a8 PR-A sender-scoped recmem_recall_context
feba84b merge(trial): home-rig-local into origin/main RecMem+DB-runtime
```

Pre-merge anchor on live: tag `pre-upstream-merge-2026-05-23` at `51c65f2` (the current head of `home-rig-local`).

## What "real merge" means

Real merge = `git checkout home-rig-local && git merge trial-merge-port-2026-05-23 --ff-only` (or equivalent) in the LIVE checkout at `C:/hexis`. After that:
- The 21 upstream commits (RecMem + DB-runtime) land in working tree.
- Local's bd106a8 sender-scoping is retained, augmented onto RecMem.
- 71 NEW SQL functions exist in `db/31`–`db/38` that the live brain has never seen.
- Live workers reference Python module shapes that ARE compatible (imports verified) but pytest hasn't run end-to-end.

## What follows mechanically

A real merge into `home-rig-local` does NOT change the live brain's schema by itself — SQL files are baked into the Docker image at build time (per CLAUDE.md). To make the schema take effect:

```bash
docker compose down -v
docker compose build db
docker compose up -d
hexis init   # or re-apply persona SQL per persona
```

This is the **fleet bounce** (M5). Cost:
- All in-memory subconscious / recent recall caches lost (recoverable, but persona "feels" colder)
- All 18+ persona workers need explicit `docker restart` after brain comes back up (heartbeat-worker wedge trap per CLAUDE.md)
- ~10-15 minutes of fleet downtime
- Risk: untested SQL functions (PR-A + PR-B) blow up at function-creation time during `docker compose build db` (`psql` runs all `db/*.sql` on init). If `mode() WITHIN GROUP` or the `DROP FUNCTION` syntax has a typo, schema init fails, hexis_brain comes up empty, no personas restorable until fixed.

## Risk profile

| Risk | Probability | Mitigation |
|---|---|---|
| `db/31` PR-A SQL has syntax error → schema init fails | Medium | Test in throwaway DB first (see below). Rollback via `git reset --hard pre-upstream-merge-2026-05-23` + rebuild. |
| `db/31` PR-B propagates wrong sender on multi-sender consolidations | Low | `mode()` returns most common; mixed = NULL. Conservative. Worst case: an episodic memory inherits one partner's id when both contributed; cross_partner marker treats it as confidential for the OTHER partner — fail-safe in the privacy direction. |
| `core/cognitive_memory_api.py` _recall_recmem caller doesn't pass `current_sender` | Medium | Caller may be `services/chat.py::chat_turn` indirectly. Need to verify post-merge that sender_id flows: `prepare_channel_turn → chat_turn → hydrate_recmem → _recall_recmem(current_sender=...)`. Conflict resolution kept the param wiring, but worth a grep before bounce. |
| Upstream's `record_chat_turn_memory` SQL function (db/34:61) doesn't carry sender into legacy `create_episodic_memory` direct-promotion path | Low (today) | Currently in dual-write, `chat.eager_memory_enabled=true`. The eager path uses `source_attribution.ref = source_identity` so sender is recoverable from JSONB even without explicit column. After Phase 3 (eager off), only RecMem path matters and PR-B handles it. |
| Persona collapse after cold-bounce (no `channel_sessions.history`, generic greeting) | Medium-High | Per CLAUDE.md known issue. Re-apply persona SQL after bounce: `for p in $personas; do docker exec -i hexis_brain psql -U hexis_user -d hexis_$p -f - < characters/set_persona_prompt.$p.sql; done` |

## Validation before fleet bounce (recommended)

**Throwaway DB test** before committing to live merge:

```bash
# Spin a throwaway compose project on different ports
cd C:/Users/User/.claude/jobs/f3783d2d/hexis-upstream
docker compose -p hexistrial -f docker-compose.yml \
  --env-file <(echo "POSTGRES_HOST_PORT=43816") \
  up -d db

# Wait for ready, then run pytest against it
POSTGRES_HOST=127.0.0.1 POSTGRES_PORT=43816 \
  C:/hexis/venv/Scripts/python.exe -m pytest tests/db -q

# Specifically exercise:
#   tests/db/test_recmem_*.py
#   any tests touching recmem_recall_context, apply_recmem_*
# Add new test if missing: sender-scoped recall returns 'own' / 'cross_partner'

# Teardown
docker compose -p hexistrial down -v
```

Cost: ~10 min setup. Uses host port 43816 (no conflict with live :43815). RAM cost = one extra Postgres container + a transient embeddings server. Live fleet unaffected.

If throwaway pytest passes → live merge low-risk.
If pytest fails → fix on trial branch, retest, only then merge.

## Recommendation

**Stagger the rollout into 2 phases:**

### Phase A: Phase 1 conflict resolution only (low-risk, can do anytime)

Cherry-pick or re-merge ONLY `feba84b` (the conflict resolution commit) into `home-rig-local`. Skip PR-A + PR-B for now.

Effect: home-rig-local consumes upstream's RecMem schema + DB-runtime migration. Sender-scoping works via legacy `fast_recall` path (unchanged). RecMem retrieval is OFF by default (`memory.recmem_hydrate_enabled = false` per upstream rollout plan), so the missing PR-A augmentation doesn't break anything live.

Validation: throwaway DB pytest still recommended, but the surface tested is the 21-commit upstream import + your conflict resolutions. PR-A/B SQL not in the pipe.

Then resume local feature dev on top of merged base. Plenty of time to validate PR-A/B separately before they're load-bearing.

### Phase B: PR-A + PR-B (gated on Phase A stability + RecMem hydration intent)

Cherry-pick `2ad5a94 + 5d00116` only when you're ready to flip `memory.recmem_hydrate_enabled = true` on at least one persona (i.e., real users will hit the new code path). Until then, PR-A is dormant.

This also aligns naturally with upstream PR timing: M6's PR-A/B target upstream's RecMem hydration path, which they'll only ship to users in their own Phase 5.

### Alternative: monolithic merge (all 3 commits at once)

Acceptable if throwaway DB pytest passes for the whole stack. Simpler to reason about. Risk: PR-A/B bugs invisible until someone flips `recmem_hydrate_enabled = true`, then bite at the worst time.

## Recommended sequence

1. Spin throwaway DB (Phase A scope: just the merge commit, RecMem schema only).
2. Run pytest. Fix anything that breaks.
3. Merge `feba84b` into `home-rig-local` in live checkout.
4. Fleet bounce (M5) per CLAUDE.md procedure.
5. Validate via `.\hexis-status.ps1` + smoke-chat 2-3 personas.
6. Resume local dev.
7. Later, when PR-A/B is needed: spin throwaway DB again with all 3 commits, validate, cherry-pick `2ad5a94 + 5d00116`, bounce again.

## Rollback path

```bash
# At any time before persona work resumes on the new schema:
cd C:/hexis
git reset --hard pre-upstream-merge-2026-05-23
docker compose down -v
docker compose build db
docker compose up -d
# Re-apply persona SQL fleet-wide
```

This works as long as you don't generate new memories on the new schema that depend on RecMem tables. Once heartbeat/chat starts writing to `subconscious_units`, rollback = lose those memories.

## Open questions for user

1. **Phase A only, or A + B?** Recommendation: A only for now, B later. Saves test surface.
2. **Throwaway DB pytest before merge, or merge-and-pray?** Strong recommendation: throwaway. ~10 min cost, eliminates schema-init crash risk.
3. **When to fleet-bounce?** Aim for a quiet window. Per CLAUDE.md, per-persona heartbeat workers don't auto-recover from DB IP change — every worker needs explicit `docker restart`. That's a chore.
