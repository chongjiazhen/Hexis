# Spec: recall quality guard (W3)

**Date:** 2026-05-30
**Status:** scoped, not implemented
**Origin:** personhood-review §Framework-weaknesses W3 + the eco-tagged-memory experiment.

## What's actually wrong (corrected)

`fast_recall` (`db/04_functions_core.sql:75`) is **not** naive cosine. It blends 7 signals:

```
final_score = vector 0.5 + graph-association 0.2 + temporal 0.15
            + (importance×decay×recency) 0.05 + trust 0.1
            + affective-congruence 0.05 + own-sender +0.1
```

Candidate gen: seeds = cosine top-K (`LIMIT GREATEST(p_limit,5)`) → graph-expand via
`memory_neighborhoods` (associations) + episode graph (temporal). Final filter:
`status='active'` AND `valid_until` AND `trust_level >= min_trust`
(`memory.recall_min_trust_level`, default **0.0** = dormant).

So recall is a real reranker. The gaps are narrow:

- **(a) cosine-only seed gate** — no lexical/hybrid entry; a keyword-exact, semantically-distant
  memory never seeds. Recall ceiling = embedding quality.
- **(b) no supersession/quality exclusion** — final WHERE (`db/04:237-239`) ignores
  `superseded_by IS NOT NULL`. Superseded memories surface; `superseded_by` / `CONTRADICTS`
  machinery is honored at write time, ignored at read time.
- **(c) hand-tuned weights, never evaluated** — can't know 0.5/0.2/0.15/… is right.

## Scope — measure first, smallest patch that honors stored signals

### Patch 1 — exclude superseded (correctness, do regardless) ✅ ship

Add to `fast_recall`:
- seeds CTE WHERE (`db/04:135-138`): `AND m.superseded_by IS NULL` — so superseded rows don't
  consume the ~10-row cosine seed gate.
- final WHERE (`db/04:237-239`): `AND m.superseded_by IS NULL` — belt-and-suspenders (graph
  expansion can pull a superseded id in via associations/temporal).

Audit the sibling recall paths for the same gap (do NOT assume; grep + read each):
`db/31_functions_recmem.sql`, `db/35_functions_recmem_ops.sql`, any `recall_memories*`.
Apply the same exclusion where they surface memories to the model.

This is a pure-correctness fix: the system already *declares* a memory dead via `superseded_by`
but keeps recalling it. Live-propagatable (`CREATE OR REPLACE`), no `down -v`, no worker rebuild.

### Patch 2 — eco-poisoning: measure, don't pre-fix ⏳ gated on data

The eco-write change (`handoff-eco-memory-write-tagged.md`) writes nano-origin memories tagged
`metadata.origin='eco'` at **normal trust** (deliberate: no thumb on scale). Do NOT add an origin
filter yet. First measure whether eco memories actually poison recall:

```sql
-- how many eco memories exist
SELECT count(*) FROM memories WHERE metadata->>'origin'='eco';
-- are eco memories being recalled? (run fast_recall on representative queries,
-- check whether origin=eco ids appear in the top-K, and at what rank)
```

**If** the data shows eco memories surfacing and degrading replies, the fix reuses existing
machinery — **no new fast_recall code**:
- write eco memories at a marked-lower `trust_level` (e.g. 0.5 via the `context.trust` arg to
  `record_chat_turn_memory`), and/or
- raise `memory.recall_min_trust_level` off its dormant 0.0 floor.

The existing trust factor (×0.1) + trust floor then down-weight/exclude eco memories
automatically. This keeps the experiment honest (write normal, observe, then dial) and avoids
hard-coding an origin special-case.

### Patch 3 — hybrid lexical seed channel (optional, larger) 🔲 defer

Only if Patch-1 + real use show recall *missing* keyword-exact memories. Add a `to_tsvector` GIN
index on `memories.content` + union a `ts_rank`/BM25 seed set into the `seeds` CTE so lexical
matches enter candidates alongside cosine seeds. Bigger surface; not justified until observed.

### NOT in scope — tuning the 7 weights

Don't blind-tune 0.5/0.2/0.15/…. Tuning needs measurement: use the RecMem eval harness to get a
recall baseline first (ties to W4). Weight-tuning without an eval is guessing.

## Tests (`tests/db/`)

1. A memory with `superseded_by` set is **excluded** from `fast_recall` even when its cosine
   similarity would otherwise rank it top-K. (new)
2. `trust_level < memory.recall_min_trust_level` excludes a memory when the floor is raised >0.
   (may already be covered — verify, else add)
3. (later, after Patch 2 data) eco-origin recall measured / down-weighted.

## Propagation

All DB-function changes: `CREATE OR REPLACE`, live, no `down -v`, no worker rebuild (DB
functions propagate immediately; cf. split rule — prompts need rebuild, DB functions don't).
