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
- **(b) no origin/quality gate** — final WHERE (`db/04:237-239`) filters only `status='active'`,
  `valid_until`, `trust_level >= min_trust`. No lever to down-weight low-quality memories (the
  eco-tagged nano writes) except the dormant trust floor (`memory.recall_min_trust_level`,
  default 0.0).
- **(c) hand-tuned weights, never evaluated** — can't know 0.5/0.2/0.15/… is right.

**Correction (2026-05-30):** an earlier draft of this spec proposed a "Patch 1" to exclude
`superseded_by IS NOT NULL` from recall. **Dropped** — grep proves `superseded_by` (`db/00:185`)
is *declared but never written* anywhere in `db/` `core/` `services/`. Supersession is aspirational
schema, not wired machinery, so the exclusion would guard a state that never occurs (no-op).
Wiring supersession (pick a writer: reconsolidation / contradiction-resolution / explicit
"corrects" path) is a separate **parked design item**, not a recall fix.

## Scope — measure first, reuse existing trust machinery

### Patch — eco-poisoning: measure, don't pre-fix ⏳ gated on data (the only live recall work)

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

### Optional, larger — hybrid lexical seed channel 🔲 defer

Only if real use shows recall *missing* keyword-exact memories (gap (a)). Add a `to_tsvector` GIN
index on `memories.content` + union a `ts_rank`/BM25 seed set into the `seeds` CTE so lexical
matches enter candidates alongside cosine seeds. Bigger surface; not justified until observed.

### Parked design item — wire supersession

`superseded_by` is dead schema (never written). If memory correction/dedup is wanted, pick a
writer (reconsolidation verdict, contradiction-resolution, or an explicit "this corrects that"
path) that sets `superseded_by`, *then* add the recall exclusion. Real feature, not a patch —
out of scope here; recorded so the unwired column isn't mistaken for working machinery.

### NOT in scope — tuning the 7 weights

Don't blind-tune 0.5/0.2/0.15/…. Tuning needs measurement: use the RecMem eval harness to get a
recall baseline first (ties to W4). Weight-tuning without an eval is guessing.

## Tests (`tests/db/`)

1. `trust_level < memory.recall_min_trust_level` excludes a memory when the floor is raised >0.
   (may already be covered — verify, else add)
2. (later, after eco data) eco-origin recall measured / down-weighted via lowered trust.

## Propagation

All DB-function changes: `CREATE OR REPLACE`, live, no `down -v`, no worker rebuild (DB
functions propagate immediately; cf. split rule — prompts need rebuild, DB functions don't).
