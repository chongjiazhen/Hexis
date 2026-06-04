# Per-message response autonomy (C2) — Design

**Date:** 2026-06-04
**Status:** Design approved, pending implementation plan.
**Origin:** Spun out of pause-autonomy (A/B/C1). See
`.local-notes/upstream-reconcile-2026-05-23/upstream-pr-drafts/READY-03-pause-autonomy.md`
and the idea note `.local-notes/ideas/per-message-response-autonomy.md`.

## 1. Concept

Persona decides, per inbound chat message, whether to substantively engage or
**decline**. Currently the chat path replies to 100% of inbound — coded policy,
no agent choice. C2 maps the thesis "ability to refuse" (ETHICS.md) onto every
chat turn.

Key constraints:

- **Never silent.** Pure silence is bad UX: the operator cannot distinguish a
  refusal from a crash. Decline always emits a *visible marker*.
- **One LLM call, in-band.** The persona decides as part of its normal turn —
  no separate pre-gate call. Purpose is agency, not cost saving.
- **Seen + remembered.** A declined message stays logged and the refusal
  (reason + register) is written to memory, honoring "preserves all state."

This supersedes the earlier "pause modes" framing (respond / read-only /
silent): hard-coded modes just relocate policy, and there is no principled line
between the pause "small exit" and a per-message posture. Per-message refusal is
the general case; "paused read-and-ignore" is a special case of it.

## 2. Register spectrum

The persona picks how warm or cold the decline reads:

| Register | Visible output                       | Source                       |
|----------|--------------------------------------|------------------------------|
| `warm`   | friendly in-character line           | persona-supplied `message`   |
| `cool`   | `[DECLINED: <reason>]`               | system-rendered from `reason`|
| `ice`    | `[DECLINED]`                         | system-rendered, reason hidden |

All three are flagged as a decline internally. `reason` and `register` are
always captured — even `ice`, which hides the reason from the user but still
records it to memory.

`warm` example: `decline_response(register='warm', reason='low energy',
message='not now, love — catch you later')` → emits the friendly `message` as
the visible reply, flags the turn as a decline.

## 3. Capture mechanism (two paths)

ECO mode (`_eco_slim_chat`, services/chat.py:101) calls the LLM with
`tools=None`, so a tool-based mechanism cannot fire there. Two paths converge to
the same internal result `{declined: bool, register, reason, visible_text}`.

- **PRIME:** add a `decline_response(register, reason, message?)` tool to the
  chat tool registry. The model calls it instead of emitting normal text.
  `message` is used only for `warm`; `cool`/`ice` render from `reason`.
- **ECO:** regex-parse the model output for a leading marker
  `[DECLINED: <reason>]` or `[DECLINED]`. The persona is prompted to use that
  convention. A `warm` ECO decline is a normal-looking friendly reply carrying
  an inline `[DECLINED]` tag that the parser strips before emit.

## 4. Data flow

The decline rides the EXISTING emit/persist sequence. No new emission plumbing.

```
prepare_channel_turn    inbound logged           (unchanged — already happens)
chat_turn               read chat.decline.enabled (cf. _read_power_mode)
                        PRIME: decline_response tool | ECO: regex parse
                        if declined AND enabled:
                            visible_text = rendered marker (per register)
                            write decline memory (kind='chat_decline')
                        else:
                            normal reply generation
finalize_channel_turn   outbound = visible_text  (logged + history, unchanged)
emit                    adapter.send(visible_text)
```

- Inbound is logged in `prepare_channel_turn` *before* the turn runs, so a
  declined message is recorded regardless.
- `visible_text` is just the turn's output; it flows through
  `finalize_channel_turn` (channel_messages outbound + `channel_sessions.history`
  update) exactly like a normal reply. Continuity preserved — next turn's history
  contains the declined exchange.

## 5. Operator control (Option A)

- **Toggle:** `chat.decline.enabled` config row, default `true`. Read once per
  turn (same `get_config()` pattern as `agent.power_mode`). `false` → the tool
  is not exposed (PRIME) and the parse is ignored (ECO); the persona always
  replies. Per-persona (per DB), so service personas (coaches) can be pinned to
  always-reply.
- **Observability:** every honored decline writes a memory row
  `source_attribution.kind='chat_decline'` (reason, register, timestamp),
  mirroring the pause-reason memory from commit A.
- **Lockout view:** a `chat_decline_log` view over those memories so the
  operator can grep the decline rate and flip the toggle off if a persona locks
  up. No automatic hard cap — operator-driven recovery.

Operator-immune sender (force-reply to owner mid-lockout) is deliberately **not**
included: the toggle already recovers a lockout, and immunity would cost a second
generation per overridden turn plus per-channel owner config (cross-channel
sender_id is not unified in hexis).

## 6. Error handling

- **Empty reason.** A `decline_response` call with an empty/blank reason is
  rejected (mirrors `pause_heartbeat`'s required-reason guard) → fall back to a
  normal reply rather than emit a reasonless decline.
- **ECO parse ambiguity.** Anchor the regex to a *leading* marker only. Content
  that merely contains `[...]` elsewhere is not a decline. No match → treat as a
  normal reply.
- **Fail toward replying, never toward silence.** If `chat.decline.enabled`
  cannot be read (DB blip), default to **disabled** (always reply) so a transient
  failure can never silence a persona. This mirrors `_read_power_mode`'s
  fail-to-prime posture.

## 7. Out of scope (YAGNI)

- **Energy discount for decline.** The LLM call already happened; a decline costs
  the same as a reply. No special energy accounting in v1.
- **Operator-immune sender** (Option B from brainstorming).
- **Per-sender decline policy.** Decision is strictly per-message.

## 8. Testing

**DB (`tests/db/`):**
- `chat_decline` memory write shape — `source_attribution.kind`, reason,
  register present.
- `chat.decline.enabled=false` suppresses the decline (always reply).
- `chat_decline_log` view returns expected rows.

**Python (`tests/services/` or `tests/cli/`):**
- PRIME: `decline_response` tool call → `declined` dict with correct
  register/reason/visible_text.
- ECO: regex parse of `warm` / `cool` / `ice` markers; non-match fails open to a
  normal reply.
- Empty-reason `decline_response` → falls back to normal reply.
- `chat.decline.enabled` read failure → persona replies (no silence).

## 9. Change surface (anticipated)

- `db/34_functions_chat_channel.sql` — decline memory write helper +
  `chat_decline_log` view (DB authority for the memory shape).
- `services/chat.py` — `chat_turn` decline branch, `chat.decline.enabled` read,
  ECO regex parse.
- `core/tools/` (chat registry) — `decline_response` tool definition.
- `services/prompts/*.md` — persona prompting for the decline convention
  (PRIME tool usage + ECO `[DECLINED]` text convention). NOTE: prompt files are
  baked into worker images; any edit needs a worker rebuild.

This is a local "our flavour of the vision" patch (not an upstream PR), per the
pause-autonomy C-series framing.
