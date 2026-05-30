# Card / Persona Prompt Techniques — what works on local Qwen/ablx

Notes for character card + `set_persona_prompt.<P>.sql` authoring on this fleet
(Qwen3 family + gemma-abliterix, served via llama.cpp `llama-server`).

Hexis pipeline consumes only `system_prompt` + `post_history_instructions`
from the card JSON (see CLAUDE.md). Everything below targets those two fields.

## XML tags

**Works on Qwen.** Qwen3 + Qwen2.5-Instruct trained heavy on tool-use /
function-calling with XML-shaped tags (`<tool_call>`, `<thinking>`,
`<answer>`). Attends XML structure measurably better than plain prose rules.

Pattern that lifts adherence:

```
<hard_rules>
- never emit private scaffolding blocks
- never use markdown headers
- ...
</hard_rules>

Follow <hard_rules> before anything else.
```

Wrapping + a one-line directive that *names the tag* is the trick — the model
needs both. Bare tags without the directive often get ignored.

MoE variants (Qwen3-MoE / `q36`) inherit — same tokenizer, same
instruction-tuning recipe family.

Gemma-abliterix: weakest on instruction-following regardless of framing. XML
helps less. Combine with post_history HARD RULE (below).

## HARD RULE prefix

**Universal — not Qwen-specific.** No model trained on the literal string
"HARD RULE". Works via two transformer-general mechanisms:

1. **Recency bias** — last instruction in context wins. `post_history` sits
   LAST in assembled prompt, gets most weight. Universal across decoder LLMs.
2. **Emphasis tokens** — uppercase + imperative ("MUST", "NEVER", "HARD
   RULE") raise instruction salience because RLHF data over-represents that
   register for safety-critical rules.

Folk technique exploiting training-data regularities. Stacks with XML.

Reference application: Esme commit `2d1f5c0` — moved hard refusal from
mid-`system_prompt` to `post_history_instructions` with `HARD RULE (apply
before any other): ...` prefix; rule started landing.

Caveat: model finds synonym loopholes (banning "the way you talk to her" →
model says "the conversational side"). Don't expect literal-phrase bans to
be airtight; the spirit lands, the letter doesn't always.

## Standards

**No cross-vendor standard exists.** Closest:

- **ChatML** (OpenAI → adopted by Qwen, Mistral, others) —
  `<|im_start|>system/user/assistant<|im_end|>`. Structural framing, not
  semantic rule emphasis. llama.cpp handles this at template layer.
- **Anthropic XML convention** — `<instructions>`, `<example>`,
  `<thinking>`. Claude-specific training signal, documented best-practice.
  Copied informally into Qwen / DeepSeek training data → partially
  transfers.
- **Tool-call schemas** — OpenAI function-calling JSON, Anthropic tool_use
  blocks. Formal but tool-only, not rule-emphasis.

So: XML attention is a *training-data echo*, not a spec. Works because
Anthropic-style examples leaked into Qwen training corpus.

## Stacking recipe (default for new cards)

In `post_history_instructions`:

```
HARD RULE (apply before any other): <one critical rule>

<hard_rules>
- <rule 1>
- <rule 2>
...
</hard_rules>

Follow <hard_rules> strictly. <persona stay-in-character reminder>.
```

Cheap, stacks, both mechanisms fire. Keep total anchor (`system_prompt` +
`post_history`) ≤7KB on `ablx` 16384 ctx slot (CLAUDE.md gotcha — over ~7KB
triggers heartbeat overflow + cache pressure → silent :8080 death once
cache hits ~8 GiB).

## What does NOT port from rentry/SillyTavern

Hexis pipeline ignores: `mes_example`, `alternate_greetings`,
`character_book` / lorebook, `{{random:}}`, `{{idle_duration}}`,
`{{roll:}}`, HTML/CSS, invisible-text `[](#'...')`, `<marquee>`, embedded
images, depth_prompt, CYOA scaffold, stats-tracking headers.

Only `system_prompt` + `post_history_instructions` reach the LLM. Card JSON
extras are documentation / future-tooling, not behavior.

## See also

- `CLAUDE.md` — anchor ≤7KB ceiling, post_history recency rule, persona
  cold-start anchor requirement
- `characters/PORT-CANDIDATES.md` — triage method, A/B/C grading
- `scripts/gen_persona_sql.py` — regenerates
  `set_persona_prompt.<P>.sql` from card JSON
