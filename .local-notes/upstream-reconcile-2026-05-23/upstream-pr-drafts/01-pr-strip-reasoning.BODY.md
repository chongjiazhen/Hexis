## Context

Hexis already supports `provider=openai_compatible` against any OpenAI-shape endpoint. A common deployment for that is `llama.cpp` (or another local server) hosting a community open-weights fine-tune. Hosted cloud APIs (OpenAI / Anthropic / etc) sanitize reasoning channels server-side; local servers serving fine-tunes generally do not. This PR adds a small defensive cleaner for the class of output-noise that surfaces specifically in that combination.

## The leak

Some community fine-tunes leak their chain-of-thought into visible `content` instead of a separate reasoning channel. Three patterns observed in practice:

- `<think>...</think>` tags (DeepSeek/Qwen-style if they surface inline in `content`)
- `<|channel>thought ... <channel|>` (Gemma 4 native special tokens that llama.cpp does not parse out)
- ```` ```thought ... ``` ```` markdown fence (the form actually observed on some fine-tunes whose special-token adherence degrades; the thought channel ends up as a plaintext fence)

Without a backstop, that text — including any recited internal scaffolding like persona prompt or memory context — reaches the user. The `enable_thinking=false` chat-template kwarg helps on some templates (Qwen3, Gemma 4) but is unreliable across community derivatives.

## The fix

Adds `strip_reasoning()` in `core/llm.py` as the load-bearing backstop:

- Model-agnostic — pattern-based on the three forms above
- Applied at both OpenAI-compatible content-extraction sites (`chat_completion` and `stream_chat_completion` return paths), so chat / RLM / heartbeat are all covered
- No-op when content is already clean (early-return guard checks for `` ``` ``, `<think>`, `channel` substrings before running the regex pass)
- Logs INFO with chars removed on strip; WARNING when content was entirely reasoning trace

Cloud-API users see no behavior change (the early-return guard fires immediately on clean content).

## Files

`core/llm.py` — new `strip_reasoning()` function + 2 callsite hookups. +56 / -2.

## Test plan

- Existing tests in `tests/core/test_llm.py` and `tests/core/test_chat.py` still pass
- Manual: chat with a Gemma 4 community fine-tune via `provider=openai_compatible` against a local `llama.cpp` serving the model — confirm reply text no longer contains a ```` ```thought ```` fence
- No-op confirmation: chat with `gpt-4o` (or any model that does not leak reasoning) — verify output is unchanged byte-for-byte

## Future work (NOT in this PR)

A sibling helper `strip_leading_divider()` for a different output-noise pattern (lone `---` horizontal rule at the start of a reply, observed on the same family of fine-tunes). Same general bug shape; kept separate to keep this PR focused on the reasoning-trace fix.
