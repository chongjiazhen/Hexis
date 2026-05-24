# PR-2 Draft: chat hydrated context into system prompt

**Source commit (local):** `3bf21cd fix(agent): move chat hydrated context into system prompt, out of user turn`

**Branch name:** `fix/chat-context-in-system-prompt`

**Base:** `main`

## Title

`fix(agent): place hydrated chat context in system prompt, not user turn`

## Body

`services/agent.py::attach_chat_context` currently appends the hydrated memory/identity context to the user's turn, making the prompt look like:

```
system: <persona system>
user: <hydrated context>\n\n<user message>
```

This conflates the user's actual question with retrieved context. Models trained on instruction-tuning data may weight the prepended context as part of the user's intent (e.g., paraphrasing it back), or fail to distinguish context retrieval from user request.

This PR moves the hydrated context into the system role:

```
system: <persona system>\n\n<hydrated context>
user: <user message>
```

Side effects:
- Cleaner downstream prompting (the model sees a clear separation between persona+context vs. user turn)
- Slight tokenizer benefit (system content cached by some providers more aggressively than user turns)

## Files

- `services/agent.py` — `attach_chat_context` function

## Test plan

- [ ] Existing chat tests pass
- [ ] Manual: chat with a persona; verify the model no longer occasionally paraphrases the hydrated context as if it were the user's input

## Note for reviewer

Verify after merging upstream's recent `core/agent_loop.py` changes that the `attach_chat_context` callsite from `agent_loop.py` still applies. The function signature is unchanged; only the routing of returned content differs.
