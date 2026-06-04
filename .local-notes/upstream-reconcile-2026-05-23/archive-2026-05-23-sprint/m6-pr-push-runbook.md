# M6 PR Push Runbook — Operator Only

**Status:** GATED ON OPERATOR PER EXPLICIT DIRECTIVE ("gate for operator final say on PR"). Forking + pushing creates public artifacts visible to anyone watching upstream.

**Decision required from operator:**
1. Fork now, or wait?
2. Start with PR-1 (`ec9e1ec`, 8 lines) as engagement signal? Or hold all PRs until Phase A merge is stable in live fleet?

Per `upstream-pr-drafts/00-engagement-strategy.md` recommendation: ship PR-1 first. If it merges, ship the rest sequentially with 1-2 week gaps.

## Step 0 — fork upstream (one-time, reversible via repo delete)

```bash
gh auth status  # confirm chongjiazhen is active
gh repo fork QuixiAI/Hexis --clone=false  # creates github.com/chongjiazhen/Hexis
cd C:/hexis
git remote add personal https://github.com/chongjiazhen/Hexis.git
git remote -v  # verify origin = upstream QuixiAI; personal = your fork
```

## PR-1 — agent.tools seed correction (smallest, recommended first)

```bash
cd C:/hexis
git checkout main  # ensure on a branch tracked to origin/main; create if needed
git pull origin main  # only the merge resolution part; NOT PR-A/B yet
git checkout -b fix/agent-tools-seed
git cherry-pick ec9e1ec
# Verify the cherry-pick is JUST the SQL seed change:
git show --stat HEAD
# Should be: db/00_tables.sql, ~8 lines, no other files

git push -u personal fix/agent-tools-seed

gh pr create --repo QuixiAI/Hexis \
  --base main \
  --head chongjiazhen:fix/agent-tools-seed \
  --title "fix(db): align agent.tools seed with current registry names" \
  --body-file C:/hexis/.local-notes/upstream-reconcile-2026-05-23/upstream-pr-drafts/01-pr-agent-tools-seed.md
```

**Watch:** PR URL output. Then wait 1-2 weeks. If no review activity, recalibrate; don't ship PR-2/3/4/5/6.

## PR-2 — chat hydrated context → system prompt (after PR-1 lands)

```bash
cd C:/hexis
git checkout main
git pull origin main
git checkout -b fix/chat-context-in-system-prompt
git cherry-pick 3bf21cd
# Verify single-file change in services/agent.py
git show --stat HEAD
git push -u personal fix/chat-context-in-system-prompt
gh pr create --repo QuixiAI/Hexis \
  --base main \
  --head chongjiazhen:fix/chat-context-in-system-prompt \
  --title "fix(agent): place hydrated chat context in system prompt, not user turn" \
  --body-file C:/hexis/.local-notes/upstream-reconcile-2026-05-23/upstream-pr-drafts/02-pr-chat-context-system-prompt.md
```

## PR-3 — channel history cap (re-ported, NOT a clean cherry-pick)

Local `4661566` was a Python-side patch. Upstream moved this logic into SQL (`db/34_functions_chat_channel.sql::finalize_channel_turn`). PR-3 is a new write against the SQL function, NOT a cherry-pick.

```bash
cd C:/hexis
git checkout main
git pull origin main
git checkout -b feat/channel-history-cap-config
# Manually edit db/34_functions_chat_channel.sql per the PR-3 draft body
# Specifically replace the hardcoded trim_to=30 / max_history=40 with get_config_int reads
# Test in throwaway DB before pushing (recommended)
git add db/34_functions_chat_channel.sql
git commit -m "feat(channel): configurable session history cap and trim window"
git push -u personal feat/channel-history-cap-config
gh pr create --repo QuixiAI/Hexis \
  --base main \
  --head chongjiazhen:feat/channel-history-cap-config \
  --title "feat(channel): configurable session history cap and trim window" \
  --body-file C:/hexis/.local-notes/upstream-reconcile-2026-05-23/upstream-pr-drafts/03-pr-history-cap.md
```

## PR-4 + PR-5 — sender-scoped recall + propagation (combined or sequential)

These have the most cognitive weight. Pre-req: PR-A + PR-B validated in throwaway DB (already done — see `m3-validation-results.md`). Also recommended: at least PR-1 landed first so operator knows maintainer is responsive.

Option: combine into one PR for atomicity (maintainer may prefer one ship of the full feature).

```bash
cd C:/hexis
git checkout main
git pull origin main
git checkout -b feat/recmem-sender-scoped
git cherry-pick 2ad5a94 5d00116
# Combined commit message via amend if desired:
# git commit --amend -m "feat(recmem): sender-scoped recall via subconscious_units.source_identity"

git push -u personal feat/recmem-sender-scoped
gh pr create --repo QuixiAI/Hexis \
  --base main \
  --head chongjiazhen:feat/recmem-sender-scoped \
  --title "feat(recmem): sender-scoped recall via subconscious_units.source_identity" \
  --body-file C:/hexis/.local-notes/upstream-reconcile-2026-05-23/upstream-pr-drafts/04-pr-sender-scoped-recmem-recall.md
# (Body covers both PR-A retrieval-side and PR-B propagation; combine the two draft bodies if shipping as one PR.)
```

If shipping as TWO PRs (cleaner review surface), use the 04- and 05- draft bodies separately:

```bash
git checkout -b feat/recmem-sender-scoped-recall
git cherry-pick 2ad5a94
git push -u personal feat/recmem-sender-scoped-recall
gh pr create --base main --head chongjiazhen:feat/recmem-sender-scoped-recall ...

# After PR-A lands, branch from latest main:
git checkout main && git pull origin main
git checkout -b feat/recmem-sender-propagation
git cherry-pick 5d00116
git push -u personal feat/recmem-sender-propagation
gh pr create --base main --head chongjiazhen:feat/recmem-sender-propagation ...
```

## PR-6 — compaction sender preservation (independent, small)

```bash
cd C:/hexis
git checkout main
git pull origin main
git checkout -b fix/recmem-compaction-sender
# Manually edit db/34_functions_chat_channel.sql per PR-6 draft body
# (~5 line change to flush_channel_history_to_memory)
git commit -am "fix(recmem): preserve real sender identity through compaction flush"
git push -u personal fix/recmem-compaction-sender
gh pr create --repo QuixiAI/Hexis \
  --base main \
  --head chongjiazhen:fix/recmem-compaction-sender \
  --title "fix(recmem): preserve real sender identity through compaction flush" \
  --body-file C:/hexis/.local-notes/upstream-reconcile-2026-05-23/upstream-pr-drafts/06-pr-compaction-sender-preservation.md
```

## What NOT to push

Per explicit user directive "especially don't share characters" AND `00-engagement-strategy.md`:

- Never `git push --all personal` or `git push --mirror personal` — would expose:
  - `characters/*.json` (persona content, adult-audience)
  - `characters/set_persona_prompt.*.sql` (persona prompts)
  - `.local-notes/**` (working drafts, fleet ops notes)
  - `docker-compose.newchars.yml` (fleet topology)
  - `power-profiles.psd1`, `start-all.ps1`, `hexis-status.ps1` (local Windows ops scripts)
  - All `feat(characters)` / `fix(characters)` commits

- Push **only named branches** with single cherry-picked commits, per the procedure above. Per `~/.claude/rules/github-workflow.md` Never-Bulk-Push rule.

## Cleanup if a PR is rejected

```bash
gh pr close <PR_NUMBER> --delete-branch
# Local branch:
cd C:/hexis
git branch -D <branch_name>
git push personal --delete <branch_name>
```

## Cleanup if operator changes mind about engaging upstream entirely

```bash
gh repo delete chongjiazhen/Hexis --yes
cd C:/hexis
git remote remove personal
```

Live `home-rig-local` and live fleet unaffected.
