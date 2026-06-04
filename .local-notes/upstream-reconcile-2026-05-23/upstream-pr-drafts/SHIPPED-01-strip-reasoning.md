# SHIPPED — strip_reasoning (PR #19)

**Status: OPEN on `QuixiAI/Hexis` since 2026-05-23.** PR **#19**, branch
`chongjiazhen:fix/llm-strip-reasoning`, mergeable, +56/-2. Source `0b3beb2`.
**Only CodeRabbit has touched it — zero maintainer signal in 12 days.** Stale gate
(per `00-engagement-strategy.md`): **~2026-06-13**. This is the canary; everything
else is sequenced behind it getting a human signal.

> Scrub applied at push: original commit message/comment referenced
> `.local-notes/hexis-native-onboard.prompt.md` — stripped. PR framed on the general
> case, not abliterated-Gemma specifically.

---

## Context

Hexis already supports `provider=openai_compatible` against any OpenAI-shape endpoint.
A common deployment is `llama.cpp` hosting a community open-weights fine-tune. Hosted
cloud APIs sanitize reasoning channels server-side; local servers serving fine-tunes
generally do not. This PR adds a small defensive cleaner for the output-noise that
surfaces specifically in that combination.

## The leak

Some community fine-tunes leak chain-of-thought into visible `content` instead of a
separate reasoning channel. Three patterns observed:

- `<think>...</think>` tags (DeepSeek/Qwen-style if they surface inline)
- `<|channel>thought ... <channel|>` (Gemma 4 native special tokens llama.cpp doesn't parse out)
- ```` ```thought ... ``` ```` markdown fence (form actually observed when special-token adherence degrades)

Without a backstop, that text — including recited internal scaffolding like persona
prompt or memory context — reaches the user. `enable_thinking=false` helps on some
templates (Qwen3, Gemma 4) but is unreliable across community derivatives.

## The fix

Adds `strip_reasoning()` in `core/llm.py` as the load-bearing backstop:

- Model-agnostic — pattern-based on the three forms above
- Applied at both OpenAI-compatible content-extraction sites (`chat_completion` and
  `stream_chat_completion` return paths), so chat / RLM / heartbeat are all covered
- No-op when content is already clean (early-return guard before regex)
- Logs INFO with chars removed on strip; WARNING when content was entirely reasoning trace

Cloud-API users see no behavior change (early-return guard fires immediately on clean content).

## Files
`core/llm.py` — `strip_reasoning()` + 2 callsite hookups. +56 / -2.

## Test plan
- Existing `tests/core/test_llm.py` / `tests/core/test_chat.py` pass
- Manual: chat a Gemma 4 community fine-tune via `provider=openai_compatible` against local `llama.cpp` — reply no longer contains a ```` ```thought ```` fence
- No-op: chat `gpt-4o` — output unchanged byte-for-byte

## Sibling (NOT in this PR)
`strip_leading_divider()` (`4ff607e`) — lone leading `---` rule. Same family, separate
PR = **PR-2, gated on this one landing.** See `DRAFT-tierA-bugfixes.md`.
