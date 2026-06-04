# Upstream Reconcile — 2026-05-23

Upstream `QuixiAI/Hexis@origin/main` shipped 21 commits today: massive RecMem (recoverable-memory) architecture + DB-runtime migration. Moved chat-turn lifecycle, recall, tool runtime, agent state from Python → Postgres functions. ~3000 lines of new SQL across `db/31`–`db/38`.

Local `home-rig-local` branch is **216 ahead / 21 behind** of `origin/main` from merge base `eb39b94` (figures as of 2026-05-23). Anchor tagged: `pre-upstream-merge-2026-05-23`.

---

## 2026-06-04 Status Refresh

**Divergence now: 346 ahead / 3 behind** `origin/main` (was 216/21). Re-triaged full 346-commit delta (`origin/main..home-rig-local`):

| count | bucket | upstream verdict |
|---:|---|---|
| 179 | fleet-only | never PR (matches Tier D) |
| 72 | core-candidate | the PR pool — re-validates `00-engagement-strategy.md` Tier A/B/C |
| 50 | other (root/config) | skim |
| 24 | docs+tests | only with a code PR |
| 16 | mixed-split | candidate logic tangled w/ fleet files — `git` surgery needed (matches Tier B "split") |
| 5 | empty/merge | — |

**Upstream reconcile state — 3 commits still not ancestors of `home-rig-local`** (`merge-base 27eb5e2` ≠ `origin/main 4948ea6`, so NOT a clean descendant):
- `4948ea6` HMX v1.7 memory exchange spec — **cherry-picked** earlier as `4c61aa6` (content present, hash not ancestor → shows as "behind").
- `1e6183e` Anthropic PKCE OAuth + Claude Code cred auto-detect — **DECLINED (low-value), not ported.** We already have working Anthropic auth via `core/auth/anthropic_setup_token.py` (shared w/ upstream); `1e6183e` is an additive 2nd method, low value on local-only rig. See [[project_upstream_reconcile_2026_05_30]].
- `244ba5c` Adopt pure RecMem (drop A/B + eager paths) — **reconciled locally** as `936224d chore(reconcile): integrate upstream 244ba5c pure-RecMem` (22f). Hash differs → still shows behind.

> Action before any new PR off true `origin/main`: decide OAuth (`1e6183e`) — port or formally drop — and re-tag a clean base. Other 2 are content-reconciled, just hash-divergent.

**PR pipeline live state (gh):**
- **PR #19** `fix(llm): strip leaked reasoning traces` (= PR-1, `0b3beb2`) is **OPEN** on `QuixiAI/Hexis`, mergeable, +56/-2, branch `chongjiazhen:fix/llm-strip-reasoning`. Created 2026-05-23.
  - **Only engagement = CodeRabbit bot. ZERO maintainer (Eric) signal in 12 days.**
  - Per cadence step 3 (wait 1-2wk) + step 8 (stop if stale 3wk): **HOLD PR-2/PR-3.** 3-week stale gate = **~2026-06-13**. If no human signal by then → stop upstreaming, keep local, re-eval after Eric's next drop.
- `strip_reasoning` confirmed still absent from `origin/main:core/llm.py` (PR still relevant; not superseded).
- No other PRs open from `chongjiazhen`.

**Today's triage re-confirmed Tier-A openers all still clean candidates:** `036e840` (httpx token-leak, security), `4ff607e` (strip divider, PR-2), `7897c72` (gateway timedelta bug), `54253d9` (goal-priority enum), `b987e32` (telegram restart queue), `48d8d99` (init --endpoint), `dc4766c` (telegram not-modified no-op). All gated behind PR #19 getting a human signal.

### Suitability screen + flagships (2026-06-04) → `pr-suitability-2026-06-04.md`

Full conceptual PR-suitability screen of the candidate pool: `pr-suitability-2026-06-04.md`. Highlights:
- **`a50c7e7` reply/quote context = TOP flagship.** VALIDATED: clean cherry-pick on `origin/main`, 42/42 channel tests green. Completes upstream's own captured-but-unused `reply_to_id`. Lowest rejection risk. Not yet staged as a branch.
- **`7ead8fe` recmem compaction = flagship #2.** BUILT + tested at `C:\hexis-pr-recmem` (see `upstream-pr-drafts/READY-02-recmem-compaction.md`).
- **`3b3d060` time-aware = NOT portable.** Depends on `resolve_sender_timezone()` (absent upstream); needs a fresh decoupled `db/09` patch, not a cherry-pick. Low priority.
- Recommended gate order: reply/quote → recmem → Tier-A bug fixes (security `036e840` first) → `4ff607e` after PR #19 lands → Tier C never cold.

## Layout (reorganized 2026-06-04)

**ACTIVE — the live PR-contribution workspace:**
- `README.md` — this index (start here)
- `pr-suitability-2026-06-04.md` — body-read suitability screen + scrub table
- `upstream-pr-drafts/` — the PR pipeline; **`STATUS.md` is its index**
  - `00-engagement-strategy.md` — maintainer reality check, tone, never-push checklist (HOW to ship)
  - `SHIPPED-01-strip-reasoning.md` · `READY-01-reply-quote.md` · `READY-02-recmem-compaction.md`
  - `DRAFT-tierA-bugfixes.md` · `DRAFT-chat-context.md`
  - `TIERB-history-cap.md` · `TIERC-01-sender-scoped-recall.md` · `TIERC-02-sender-propagation.md`
  - `DROPPED-agent-tools-seed.md`

**`archive-2026-05-23-sprint/` — historical** (the original RecMem reconcile sprint, done):
- `migration-additive-SUPERSEDED/` — the 2026-05-23 memory-preserving additive migration (`migrate-additive.*` + validation). **OBSOLETE**: fleet wiped 2026-05-29 (no data to preserve), pure-RecMem merged `936224d`, and the actual reconcile lives in `.local-notes/migrations/2026-05-30-pure-recmem-reconcile/`. Pure-RecMem is **live-confirmed** (rollout/dual-write functions absent from all 11 DBs, 2026-06-04). Kept for provenance only.
- `m3-progress.md`, `m3-validation-results.md` — M3 work log + throwaway-DB pytest (433 pass / 8 pre-existing fail)
- `m4-decision-gate.md` — staggered Phase A/B merge plan + rollback
- `m5-bounce-runbook.md` — live fleet bounce (destructive — DELETES MEMORIES; superseded by additive migration)
- `m6-pr-push-runbook.md` — generic fork+push commands (superseded by per-PR runbooks in the drafts)
- `port-shape-bd106a8.md`, `port-shape-medium-low.md` — port analyses
- `trial-merge-conflicts.md` — conflict text + resolution recipes from M2

## Historical (2026-05-23 sprint — superseded)

> These sections describe the original reconcile sprint. The RecMem reconcile is DONE
> (pure-RecMem merged `936224d` 2026-05-30, see [[project_upstream_reconcile_2026_05_30]]).
> Kept for provenance; the trial worktree below is gone and the freeze is lifted.

**Trial branch state:** worktree `C:/Users/User/.claude/jobs/f3783d2d/hexis-upstream` (removed),
branch `trial-merge-port-2026-05-23` (`feba84b` merge + `2ad5a94` PR-A + `5d00116` PR-B). Work
landed in `home-rig-local`. Rollback anchor: tag `pre-upstream-merge-2026-05-23` at `51c65f2`.

**Freeze policy (LIFTED):** during the sprint, hard-froze `services/chat.py`,
`core/cognitive_memory_api.py`, recall SQL, new chat features. No longer in effect —
`home-rig-local` has advanced past the merge.
