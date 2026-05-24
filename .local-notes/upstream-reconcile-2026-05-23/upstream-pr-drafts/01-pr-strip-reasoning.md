# PR-1 Draft: strip_reasoning

**Source commit (local):** `0b3beb2 fix(llm): strip leaked reasoning traces from model output`

**Branch name:** `fix/llm-strip-reasoning`

**Base:** `main`

**Cherry-pick scrub:** the original commit message and code comment reference `.local-notes/hexis-native-onboard.prompt.md` (a local working note). Strip both references before pushing — replace with a plain statement of behavior.

## Title

`fix(llm): strip leaked reasoning traces from model output`

## Body

Some community fine-tunes — abliterated Gemma 4 merges in particular — leak their chain-of-thought into visible `content` instead of a separate reasoning channel. Three patterns observed in production:

- `<think>...</think>` tags (DeepSeek/Qwen-style if they surface inline)
- `<|channel>thought ... <channel|>` (Gemma 4 native special tokens that llama.cpp does not parse out)
- ```` ```thought ... ``` ```` markdown fence (the form actually observed: abliterated merges degrade special-token adherence and approximate the thought channel as a plaintext fence)

Without a backstop, that text — including any recited internal scaffolding like persona prompt or memory context — reaches the user. The `enable_thinking=false` chat-template kwarg helps on some templates (Qwen3, Gemma 4) but is unreliable on abliterated derivatives.

This PR adds `strip_reasoning()` in `core/llm.py` as the load-bearing backstop:
- Model-agnostic — pattern-based on the three forms above
- Applied at both OpenAI-compatible content-extraction sites (`chat_completion` and `stream_chat_completion` return paths), so chat / RLM / heartbeat are all covered
- No-op when content is already clean (early-return guard checks for `` ``` ``, `<think>`, `channel` substrings before running regex)
- Logs INFO on strip with chars removed; WARNING when content was entirely reasoning trace

Also corrects a stale comment near the `extra_body` setup that claimed `enable_thinking` is Qwen-only.

## Files

- `core/llm.py` — new `strip_reasoning()` + 2 callsite hookups + comment correction

## Test plan

- Existing chat tests pass (`pytest tests/services/test_chat.py -q` if applicable, or relevant existing harness)
- Manual: chat with an abliterated Gemma fine-tune (e.g., gemma-2-it-abliterated) at `provider=openai_compatible` against `llama.cpp` serving the model; confirm reply text no longer contains a ```` ```thought ```` fence
- Strip is no-op on clean output: chat with `gpt-4o` or any model that does not leak reasoning — verify output unchanged byte-for-byte

## Future work (NOT in this PR)

A sibling helper `strip_leading_divider()` for a different output-noise pattern (lone `---` horizontal rule at start of reply) — same family of bugs, separate PR to keep this one focused on the reasoning-trace fix.
