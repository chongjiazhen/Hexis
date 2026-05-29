# Upstream reconcile — 2026-05-30

Reconcile the 3 upstream commits (QuixiAI/Hexis) not in our history, judged
against the axiom: **DB = persistent brain, LLM = instantaneous neurons.
Integrate unless upstream abandoned the personhood vision.**

Baselines: fork-merge-base `27eb5e2` (2026-05-23) · live upstream `4948ea6`.

## Verdict

| Commit | What | Philosophy | Action |
|---|---|---|---|
| `4948ea6` HMX v1.7 | memory-exchange spec (`plans/hmx.md`, doc-only) | **Extends** vision — consent-gated portable selfhood | **DONE** — cherry-picked (`4c61aa6`) |
| `244ba5c` pure RecMem | rip out A/B + eval + dual-write + rollout; RecMem unconditional | **Most aligned** — one canonical brain path, no hedging | **PARTIAL** — DB half drafted (`drop-rollout-eval-functions.sql`); code half = chat.py hand-merge, deferred |
| `1e6183e` PKCE OAuth | Anthropic OAuth + Claude Code cred auto-detect | **Neutral** — neuron-summoning, zero brain-logic in API. NOT a divergence | **DEFERRED** — take or shelf on rig-grounds (local-only is operational, not philosophical) |

## RecMem (`244ba5c`) — collision analysis

Mechanical, not semantic. Upstream removes only scaffolding:
- functions: `record_recmem_rollout_event`, `record_recmem_dual_write_comparison`,
  `get_recmem_eval_*`, `get_recmem_rollout_*`, `apply_recmem_rollout_phase`,
  `infer_recmem_rollout_phase`, `recmem_rollout_phase_config`, `run_recmem_eval_set`
- we modified the **live recall path** (`recmem_recall_context`) — disjoint.

Conflict-free files: `recmem_rollout.py`, `recmem_eval.py` (we never patched),
`worker_service.py`, `cognitive_memory_api.py` (our edits touch no removed symbol).

**One hot file: `services/chat.py`.** Lines 32-149 (`_record_recmem_rollout_event`,
`_log_dual_write_comparison`) = upstream scaffolding we inherited untouched; upstream
deletes exactly those. Our +277 (reach-out/latent enrichment) lives elsewhere →
auto-merge likely, worst case 1-2 hand-resolved hunks.

## Sequence (do NOT reorder)

1. [done] cherry-pick HMX.
2. [todo] hand-merge `244ba5c` chat.py deletions; rebuild+roll out workers.
3. [todo] apply `drop-rollout-eval-functions.sql` to each live `hexis_<P>` DB.
4. [open] OAuth decision (`1e6183e`) — separate, no philosophy block.

Timing: hold step 2 until all-latent reach-out lands — both touch chat.py /
heartbeat; concurrent edits = avoidable conflict storm.
