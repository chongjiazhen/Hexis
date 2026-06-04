# PR-6: compaction sender preservation — BUILT & VERIFIED 2026-06-04

**Status: READY TO FIRE.** Chosen as the "high-value seriousness signal" PR for the
~2026-06-13 gate (deepest signal — bug fix in Eric's newest RecMem code, vision-aligned
on memory fidelity). Built, tested green, committed. NOT pushed.

## Build location
- Worktree: `C:\hexis-pr-recmem` (off `origin/main` @ `4948ea6`, clean base).
- Branch: `fix/recmem-compaction-sender`.
- Commit: `7ead8fe fix(recmem): preserve real sender identity through compaction flush`.
- Diff: `db/34_functions_chat_channel.sql` (+8/-1) + `tests/db/test_chat_channel_compaction_sender.py` (new, 103 lines).

## Verification (proof, not claim)
- Bug confirmed present in `origin/main:db/34` (synthetic `source_identity := 'compaction:' || ...`, no sender).
- `channel_sessions.sender_id TEXT NOT NULL` confirmed in `origin/main:db/22_tables_channels.sql:13` → derive is valid, never NULL.
- Test passes WITH fix (`1 passed in 14.79s`), FAILS WITHOUT (`assert 0 > 0`) → genuine regression test.
- Throwaway-DB run via conftest (`tmp_test_*`, built from worktree `db/*.sql`) against `hexis_brain`. No live data touched.
- Comments/test reference nothing local — no scrub needed.

## The fix
`db/34_functions_chat_channel.sql::flush_channel_history_to_memory`:
- add `real_sender TEXT;` declare
- `SELECT sender_id INTO real_sender FROM channel_sessions WHERE id = p_session_id;` before loop
- `source_identity := COALESCE(real_sender, 'session') || ':compaction:' || p_session_id::text || ':' || stored::text || ':' || digest;`

## PR metadata
- **Title:** `fix(recmem): preserve real sender identity through compaction flush`
- **Base:** `QuixiAI/Hexis:main`  **Head:** `chongjiazhen:fix/recmem-compaction-sender`

## PR body (terse, Eric-voice — lead with bug, one-para why, show test, scope)

```
`flush_channel_history_to_memory` (db/34) stamps every compaction-flushed unit
with a synthetic `source_identity` of the form `compaction:<session>:<idx>:<digest>`.
That guarantees idempotency but drops the real conversation partner. Hot-path
units (record_chat_turn_memory) keep the partner, so once a session's history
exceeds max_history and flushes, the flushed units silently lose symmetry with
everything ingested live — anything keying off subconscious_units.source_identity
to identify the partner sees a sessionful of identityless units.

Fix derives the sender from channel_sessions.sender_id (NOT NULL) and uses it as
the identity prefix; the synthetic suffix stays as the idempotency disambiguator.
Strictly more information, idempotency unchanged.

Tested by: new tests/db/test_chat_channel_compaction_sender.py — drives a session
past max_history through finalize_channel_turn, asserts every flushed
subconscious_unit carries `<sender>:compaction:%` and none use the old
sender-less form. Passes with the fix, fails without it.

Not in this PR: no change to hot-path ingestion or the idempotency key; no schema
change (column already exists).
```

## FIRE RUNBOOK (gate day — run only after deciding to ship)
```powershell
# 1. Rebase onto latest upstream in case origin/main moved
git -C C:\hexis-pr-recmem fetch origin
git -C C:\hexis-pr-recmem rebase origin/main   # resolve if db/34 moved upstream

# 2. Push to personal fork
git -C C:\hexis-pr-recmem push personal fix/recmem-compaction-sender

# 3. Open PR (body-file = this file's PR-body block, or inline)
gh pr create --repo QuixiAI/Hexis --base main `
  --head chongjiazhen:fix/recmem-compaction-sender `
  --title "fix(recmem): preserve real sender identity through compaction flush"
```

## Cleanup when done (merged or abandoned)
```powershell
git worktree remove C:\hexis-pr-recmem      # add --force if dirty
git branch -D fix/recmem-compaction-sender  # only if abandoning
```
