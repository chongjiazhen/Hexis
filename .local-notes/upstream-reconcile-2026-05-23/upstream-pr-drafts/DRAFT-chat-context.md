# DRAFT (strong, port-rework) — chat hydrated context into system prompt

**Status: high-value, NOT a clean cherry-pick.** Source `3bf21cd`. Bug CONFIRMED present
upstream (2026-06-04): `origin/main:services/agent.py:91` formats subconscious output "for
injection into the user message context"; `attach_chat_context` is absent upstream → fix
unlanded. But upstream `agent.py` changed post-RecMem, so this needs a **re-port to the
current assembly**, not a cherry-pick. Promoted from MED to strong on body read.

## Bug
`services/agent.py` builds the chat turn by concatenating subconscious signals + recalled
memory context + the user message into a SINGLE `role=user` string. The hydrated blocks
carry only bare markdown headers, no system-context framing — a leak-prone local model
can't tell them from user input and narrates them aloud ("you provided me with my
Subconscious Signals, Relevant Memories, Identity, Beliefs"), misattributing them to the user.

## Fix
`attach_chat_context()` folds that context into the SYSTEM prompt for chat mode (`run_agent`
+ `stream_agent`). The user turn carries only the user's actual message. Heartbeat mode left
unchanged (no human reads a heartbeat turn; narrower blast radius). Affects every persona's
non-RLM PRIME chat path; RLM + ECO already unaffected.

```
before:  user: <hydrated context>\n\n<user message>
after:   system: <persona system>\n\n<hydrated context>   /   user: <user message>
```

## PR metadata
- **Title:** `fix(agent): place hydrated chat context in system prompt, not user turn`
- **Files:** `services/agent.py`, `tests/services/test_attach_chat_context.py` (test ships with it — good)

## Before pushing
- **Re-port:** rebase onto `origin/main`, reconcile against upstream's current `agent.py`
  assembly (post-RecMem). Verify the system/user split still lands where upstream builds the turn.
- **Scrub:** "Vera onboarding" → generic "diagnosed during a persona onboarding".
- Verify the `attach_chat_context` callsite from upstream's `core/agent_loop.py` still applies.

## Test plan
- Existing chat tests pass; bundled `test_attach_chat_context.py` green
- Manual: persona no longer paraphrases hydrated context as if it were the user's input
