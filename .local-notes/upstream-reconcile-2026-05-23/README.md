# Upstream Reconcile — 2026-05-23

Upstream `QuixiAI/Hexis@origin/main` shipped 21 commits today: massive RecMem (recoverable-memory) architecture + DB-runtime migration. Moved chat-turn lifecycle, recall, tool runtime, agent state from Python → Postgres functions. ~3000 lines of new SQL across `db/31`–`db/38`.

Local `home-rig-local` branch is **216 ahead / 21 behind** of `origin/main` from merge base `eb39b94`. Anchor tagged: `pre-upstream-merge-2026-05-23`.

## Files

- `port-shape-bd106a8.md` — sender-scoped recall, HIGH collision, full port plan
- `port-shape-medium-low.md` — 4661566, 55d0dc9, 3bf21cd, ec9e1ec port notes
- `trial-merge-conflicts.md` — actual conflict text + resolution recipes from M2
- `m3-progress.md` — M3 work log; conflict resolution complete, PR-A drafted
- `m3-validation-results.md` — throwaway DB pytest: 433 passed / 8 failed; PR-A + PR-B compile clean; no failure in sender/recmem paths
- `m4-decision-gate.md` — staggered Phase A / Phase B merge recommendation, throwaway DB test plan, rollback path
- `m5-bounce-runbook.md` — exact copy-paste PowerShell commands for live fleet bounce (operator-only; destructive — DELETES MEMORIES)
- `migrate-additive.sql` + `migrate-additive-build.sh` — memory-preserving alternative to M5 bounce; build with sh script
- `migrate-additive.full.sql` — assembled 9055-line migration, validated against anchor DB
- `migrate-validation.md` — anchor-DB test results, idempotency proof, overload fix, live apply procedure
- `m6-pr-push-runbook.md` — exact copy-paste shell commands for fork + per-PR push (operator-only; public)
- `upstream-pr-drafts/` — 6 PR descriptions ready for review before any public push
  - `00-engagement-strategy.md` — reality check on upstream maintainer cadence + recommended PR order
  - `01-pr-agent-tools-seed.md` — engagement signal PR (smallest, lowest risk)
  - `02-pr-chat-context-system-prompt.md`
  - `03-pr-history-cap.md`
  - `04-pr-sender-scoped-recmem-recall.md` — main sender-scoping pitch
  - `05-pr-sender-propagation-derived.md` — companion to PR-4
  - `06-pr-compaction-sender-preservation.md` — independent bug fix

## Trial branch state

Worktree: `C:/Users/User/.claude/jobs/f3783d2d/hexis-upstream`
Branch: `trial-merge-port-2026-05-23`
Commits:
- `feba84b merge(trial): home-rig-local into origin/main RecMem+DB-runtime`
- `2ad5a94 feat(recmem): bd106a8 PR-A sender-scoped recmem_recall_context`
- `5d00116 feat(recmem): bd106a8 PR-B propagate source_identity to derived memories`

All Python parses + imports cleanly. SQL untested in DB (live fleet is up; throwaway DB test plan in `m4-decision-gate.md`).

Live `home-rig-local` UNCHANGED. Rollback anchor: tag `pre-upstream-merge-2026-05-23` at `51c65f2`.

## Freeze policy (in effect)

Hard freeze: `services/chat.py`, `core/cognitive_memory_api.py`, recall SQL, new chat features.
OK to keep editing: persona content (`characters/*`), compose/infra, critical fleet bugfixes (with collision-aware commit messages), `.local-notes/`.
