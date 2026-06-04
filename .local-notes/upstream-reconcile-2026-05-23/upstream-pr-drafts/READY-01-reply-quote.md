# READY (flagship #1) — Telegram reply/quote context

**Status: VALIDATED, not yet staged as a branch.** Source `a50c7e7` (branch tip).
Recommended LEAD PR for the gate — lowest rejection risk because it *completes
upstream's own half-built field* (`reply_to_id` captured at `telegram_adapter.py:218`
+ `ChannelMessage.reply_to_id` base.py:48, never consumed for model context).

## Validation (2026-06-04)
- Clean cherry-pick onto `origin/main` (auto-merged `conversation.py`, `telegram_adapter.py`; no conflicts).
- `pytest tests/core/test_channels.py` → **42 passed** on the cherry-picked tree.
- Self-contained, additive +94 / 4 files, no fleet/persona coupling, no scrub needed.

## PR metadata
- **Title:** `feat(channels): surface reply/quote context to the model`
- **Base:** `QuixiAI/Hexis:main`  **Head:** `chongjiazhen:fix/telegram-reply-quote` (stage branch)
- **Files:** `channels/base.py` (+6), `channels/conversation.py` (+29), `channels/telegram_adapter.py` (+20), `tests/core/test_channels.py` (+39)

## PR body (terse, Eric-voice)

```
The adapter already captures reply_to_id (telegram_adapter.py) and ChannelMessage
already carries it, but nothing consumes it — when a user replies to or quotes an
earlier message, the model never sees what they replied to.

This surfaces the quoted snippet above the incoming turn, the same context a human
participant sees. The quoted text comes from the platform update (reply_to_message /
message.quote), not a DB lookup, so it works for quotes of messages we never logged
and preserves partial-quote slices. Attribution distinguishes the user, the agent
itself (self-quote -> "your earlier message"), and other senders.

ChannelMessage gains reply_to_text / reply_to_sender / reply_to_is_self; the Telegram
adapter populates them; conversation.py prepends a quote block to the LLM-facing
user_content in both the chunked and streaming paths (transcript/history keep raw text).

Not in this PR: no other adapter wired (Telegram only); helper is unit-tested.
```

## FIRE RUNBOOK (gate day)
```powershell
# stage a clean branch off origin/main and cherry-pick the commit
git worktree add -b fix/telegram-reply-quote C:\hexis-pr-replyquote origin/main
git -C C:\hexis-pr-replyquote cherry-pick a50c7e7      # clean (verified 2026-06-04)
git -C C:\hexis-pr-replyquote push personal fix/telegram-reply-quote
gh pr create --repo QuixiAI/Hexis --base main `
  --head chongjiazhen:fix/telegram-reply-quote `
  --title "feat(channels): surface reply/quote context to the model"
# cleanup after: git worktree remove C:\hexis-pr-replyquote
```
