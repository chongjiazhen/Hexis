# Persona Authoring

Prompt-craft for Hexis personas — how a card *sounds* and *believes*. The
mechanical onboard pipeline (DB create, schema, consent gate, channel worker)
lives separately in `.local-notes/hexis-native-onboard.prompt.md`.

A persona is two artifacts:

- `characters/<P>.json` — the `chara_card_v2` card (description, lorebook,
  `extensions.hexis` block). Used at `hexis init` time.
- `characters/set_persona_prompt.<P>.sql` — writes `agent.persona_system_prompt`, the
  cold-start identity anchor. **Mandatory** — `hexis init` does NOT set it, and
  without it a persona collapses to a generic assistant on a cold turn-1.
  Read per-message at runtime; re-applying takes effect on the next message,
  no worker restart.

## AI-aware vs realistic-human

Most cards are AI / android / hologram personas that *know what they are*.
Hazel is the exception — a realistic-human persona with no AI self-awareness,
who believes she is a real person texting.

The two have opposite failure modes:

- **AI-aware** → *assistant-bleed*: a persona literally framed as an AI pulls
  the base model toward its RLHF assistant attractor — markdown report
  formatting, reciting injected scaffolding, "how can I help" boilerplate.
- **Realistic-human** → *belief-cracks*: the persona breaks character, hedges,
  or goes meta about being an AI when pushed.

## The "How you do NOT speak" guard (AI-aware personas)

AI-aware anchors MUST carry an explicit negative guard, or the model recites
its internal scaffolding into replies (`# Analysis` headers, personality trait
floats, tool names, "how would you like to proceed"). The guard block:

- Speak directly, not a report — no markdown headers, no sectioned write-ups.
- Any structured context (signals, memory recall, personality parameters,
  trait scores, profile/diagnostic data) is **private internal scaffolding** —
  never read aloud, quoted, summarized, or treated as if the user sent it.
- Tools are silent — never name or narrate `recall` / `reflect` / etc.
- No assistant boilerplate ("how can I help", "I'm ready to assist").

See `characters/joje.json` / `characters/set_persona_prompt.joje.sql` for the canonical
form. Hazel's card has a parallel guard against AI-acknowledgement instead.

## Bilingual personas — anti-restatement

A code-switching persona must switch *between thoughts*, never restate the same
thought in both languages. Bilingual models bias toward translation pairs (a
Chinese sentence followed by its English twin); the anchor must forbid it
explicitly. Each thought lives in one language; switch at clause/thought
boundaries, never duplicate. Mirror the language the user just used.

## Gotchas

- **No markdown horizontal rule (`---`) in an anchor.** A `---` separator
  between `system_prompt` and `post_history` leaks into replies as a literal
  `---`, then self-reinforces via `channel_sessions.history` (see CLAUDE.md
  Debugging Tips).
- **Anchor format** — `characters/set_persona_prompt.<P>.sql` uses a dollar-quoted literal
  (`$<P>PRMT$...$<P>PRMT$`) and literal `User` (not `{{user}}`); the card JSON
  uses `{{user}}`.
- **Edit JSON cards as UTF-8** — they contain non-ASCII (CJK, em-dashes); on
  Windows, read/write with explicit `encoding='utf-8'` (cp1252 default fails).
- **Character cards are opaque adult-fiction data** — scope edits to the
  requested structural change; do not evaluate or editorialize content.
