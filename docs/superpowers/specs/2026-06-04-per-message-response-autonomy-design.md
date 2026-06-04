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

The persona picks the social register of the refusal (a gradient from friendly
to curt):

| Register | Visible output             | Marker the persona emits           |
|----------|----------------------------|------------------------------------|
| `gentle` | friendly in-character line | `[DECLINE:gentle:<reason>] <line>` |
| `plain`  | `[DECLINED: <reason>]`     | `[DECLINE:plain:<reason>]`         |
| `blunt`  | `[DECLINED]`               | `[DECLINE:blunt:<reason>]`         |

All three are flagged as a decline internally. `reason` and `register` are
always captured — even `blunt`, which hides the reason from the user but still
records it to memory.

`gentle` example: persona emits `[DECLINE:gentle:low energy] not now, love —
catch you later`. The parser strips the marker, emits the friendly remainder as
the visible reply, records register=`gentle` reason=`low energy`.

## 3. Capture mechanism (uniform text-convention)

The fleet runs the **RLM path** by default (`chat.use_rlm=true`, db/00_tables.sql:682),
where a structured tool cannot cleanly end a turn — an RLM tool is a *mid-reasoning
REPL syscall*, not a turn terminator; only `run_agent` ends a turn on a tool call.
All three chat paths (ECO `_eco_slim_chat`, RLM `run_chat_turn`, default
`run_agent`) converge on a single `assistant_text` string. So decline is captured
by **one text-convention parser run on `assistant_text` in every path** — no tool,
no path-specific code.

**Marker grammar (one leading token, persona emits in all modes):**

```
[DECLINE:<register>:<reason>]<optional trailing message>
```

- `register` ∈ {`gentle`, `plain`, `blunt`}; omitted with a reason → defaults to
  `plain`; bare `[DECLINE]` (no register, no reason) → `blunt`.
- `reason` is free text up to the closing `]`; may be empty.
- Trailing message after `]` is used only for `gentle` (the visible friendly line).
- Bare `[DECLINE]` → register `blunt`, reason `NULL`.

**Parser `classify_decline(text) -> Decline | None`:**
- Anchored to the START of `text` (after optional leading whitespace). A `[...]`
  elsewhere in the body is NOT a decline.
- No leading marker → returns `None` (normal reply).
- Match → returns `{register, reason, visible_text}` where `visible_text` is:
  - `gentle` → the stripped trailing message (or `GENTLE_FALLBACK` if empty)
  - `plain`  → `[DECLINED: <reason>]` (system-rendered; if reason empty, `[DECLINED]`)
  - `blunt`  → `[DECLINED]`

The persona is prompted (in the chat system prompt, all modes) to use this marker
when it chooses not to engage.

## 4. Data flow

The decline rides the EXISTING emit/persist sequence. No new emission plumbing.

```
prepare_channel_turn    inbound logged              (unchanged — already happens)
chat_turn               generate assistant_text     (ECO | RLM | run_agent — unchanged)
                        read chat.decline.enabled   (cf. _read_power_mode)
                        decline = classify_decline(assistant_text)
                        if decline AND enabled:
                            assistant_text = decline.visible_text  (rendered per register)
                            write decline memory (kind='chat_decline', reason, register)
                        # else: assistant_text passes through unchanged
finalize_channel_turn   outbound = assistant_text   (logged + history, unchanged)
emit                    adapter.send(assistant_text)
```

The parse + render + decline-memory step is a single post-generation hook applied
to `assistant_text` after each path produces its text and before
`_remember_conversation`/return. Insertion points:
- `chat_turn`: ECO, RLM (×2 sub-branches), run_agent.
- `stream_chat_turn`: ECO single-chunk, and the buffered agent path. **The
  streaming variant buffers the full reply (`full_text`) before yielding a single
  chunk** (session-assessment capture needs the complete reply; Telegram's
  StreamCoalescer batches anyway), so the same post-generation hook applies — no
  token-level decline handling needed. This path is load-bearing: the channel
  manager uses streaming for any adapter with `edit_message` capability
  (**Telegram included**), so the live fleet's reactive chat flows through here.

- Inbound is logged in `prepare_channel_turn` *before* the turn runs, so a
  declined message is recorded regardless.
- `visible_text` is just the turn's output; it flows through
  `finalize_channel_turn` (channel_messages outbound + `channel_sessions.history`
  update) exactly like a normal reply. Continuity preserved — next turn's history
  contains the declined exchange.

## 5. Operator control (Option A)

- **Toggle:** `chat.decline.enabled` config row, default `true`. Read once per
  turn (same `get_config()` pattern as `agent.power_mode`). Per-persona (per DB),
  so service personas (coaches) can be pinned to always-reply.
- **Two-level enforcement when `false`:**
  1. *Prompt gate (primary):* the chat system prompt offers the decline
     convention only when enabled. Disabled → the persona is never told it can
     decline, so it emits no marker. (`build_system_prompt` reads the config.)
  2. *Honor gate (belt):* `chat_turn` skips `classify_decline` entirely when
     disabled → `assistant_text` passes through verbatim and no decline memory is
     written. A stray marker (model hallucinating the convention) would show raw
     rather than be honored — visible, never silent.
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

- **Empty reason.** A marker with an empty reason (`[DECLINE:plain:]` or bare
  `[DECLINE]`) is allowed, not rejected — the persona may decline without stating
  why (`blunt` is exactly that). `reason` is stored `NULL`; `plain` with empty
  reason renders `[DECLINED]`. The decline is never silent regardless.
- **Parse ambiguity.** Anchor the regex to a *leading* marker only (after optional
  whitespace). A `[...]` elsewhere in the body is not a decline. No leading match
  → `classify_decline` returns `None` → normal reply (fail-open to replying).
- **Fail toward replying, never toward silence.** If `chat.decline.enabled`
  cannot be read (DB blip), default to **disabled** (always reply) so a transient
  failure can never silence a persona. This mirrors `_read_power_mode`'s
  fail-to-prime posture.
- **Marker present but render yields empty** (gentle with no trailing message) →
  substitute `GENTLE_FALLBACK` so output is never empty.

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

**Python (`tests/services/`):**
- `classify_decline` unit tests: `gentle`/`plain`/`blunt` markers → correct
  register/reason/visible_text; bare `[DECLINE]` → blunt + reason NULL; default
  register when omitted-with-reason = plain; non-leading `[...]` → None;
  leading-whitespace tolerated; gentle with empty trailing → `GENTLE_FALLBACK`.
- `chat.decline.enabled=false` → `classify_decline` skipped, text verbatim, no
  decline memory.
- `chat.decline.enabled` read failure → treated as disabled, persona replies
  (no silence).

## 9. Change surface (anticipated)

- `services/chat.py` — the post-generation hook applied at every return point of
  BOTH `chat_turn` (ECO, RLM ×2, run_agent) and `stream_chat_turn` (ECO,
  buffered agent path); `chat.decline.enabled` read. (`classify_decline` lives in
  `services/decline.py`.)
- `db/34_functions_chat_channel.sql` — decline memory write helper (or reuse
  `record_chat_turn_memory` with a decline kind) + `chat_decline_log` view
  (DB authority for the memory shape).
- `services/agent.py` / `build_system_prompt` — prompt gate: include the decline
  marker convention only when `chat.decline.enabled`.
- `services/prompts/*.md` — the decline-convention instruction text (one block,
  same for all modes). NOTE: prompt files are baked into worker images; any edit
  needs a worker rebuild (`--no-deps --force-recreate --build`).

No tool registry change — uniform text-convention needs no `decline_response`
tool. (A structured tool remains a possible future enhancement if the fleet ever
moves off RLM to the `run_agent` path.)

This is a local "our flavour of the vision" patch (not an upstream PR), per the
pause-autonomy C-series framing.
