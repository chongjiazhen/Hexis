# _inbox — open items / scratchpad

Centralized "what's on our plate" so nothing gets dropped. Newest context at
top of each item. Untracked scratch (lives in `.local-notes/`).

Last updated: 2026-05-22

---

## ACTIVE — needs a decision or action

### 1. Vera — assessment capture (PARKED, watching)
- **State:** parked 2026-05-22 after ~8 gate runs. Vera (comms-trainer
  persona) is LIVE on Telegram — coaching is good, leak fixed, fits context.
- **The unsolved bit:** structured `[session-assessment]` capture. Vera emits
  the block but it is NOT captured/stripped on the Telegram (streaming) path
  → user sees a raw `<<SESSION-ASSESSMENT>` block at each scenario end.
- **Decision:** let Vera sit live a few days with heartbeat+maintenance on;
  watch whether `run_subconscious_maintenance` produces useful longitudinal
  tracking on its own before building a bespoke feature.
- **Re-decide ~2026-05-26.** Check `hexis_vera` memories: did maintenance
  cluster/consolidate the coaching episodics into anything strategic?
- **If a build is needed:** Option 1 (buffer `stream_chat_turn` + tolerant
  regex) is fully documented — `docs/superpowers/specs/2026-05-22-comms-trainer-persona-design.md`
  §9a + a `KNOWN GAP` comment in `services/chat.py` `stream_chat_turn`.
  Operator: how does SillyTavern do streaming but still regex (more flexible text editor? not messenging app)

### 2. Fleet rollout — agent.py context-assembly fix
- **State:** `fix(agent): move chat hydrated context into system prompt`
  is committed + live ONLY on `hexis_vera_channel_worker` (rebuilt).
- **Pending:** the fix is fleet-wide-correct but other personas still run the
  old image. Before rolling out: regression-test 2–3 personas (mira/death/
  ennie — operator DMs them), then rebuild all `*_channel_worker` images.
- **Heartbeat/maintenance images do NOT need rebuilding** — the fix is
  chat-mode only; heartbeat assembly was deliberately left unchanged.

### 3. CLAUDE.md staleness
- Debugging section says `channel_sessions.history` = "last 8 turns". Wrong:
  actual cap is `MAX_SESSION_HISTORY=40` → trim to `30` (`channels/
  conversation.py`), now config-overridable via `channel.history.max` /
  `channel.history.trim`. Fix the CLAUDE.md line when convenient.

---

## LOW PRIORITY / NOTES

### Vera bot identity
- Vera runs as Telegram `@industrious_incisors_bot` (TARS's old bot — token
  reuse, operator-confirmed intentional). Recommend renaming the bot's
  display name/handle to "Vera" in BotFather. Cosmetic.

### Vera scenario recycling
- Minor glitch: Vera reused an earlier scenario verbatim (Sam/spreadsheet)
  from recall. Low priority, model-ish. Watch if it persists.

---

## DONE THIS SESSION (2026-05-22)

- Froze Lovesick / Monika / Joje / Ichika (commit `0679b46`) — superseded by
  a forthcoming unified AI-type character. DBs preserved.
- Froze Nines / Charlotte (commit `b0f1af0`) — superseded by a forthcoming
  unified android character. DBs preserved.
- Vera comms-trainer persona: brainstormed → spec → plan → built + onboarded
  live (card, persona SQL, compose, DB `hexis_vera`, consent, anchor, all 3
  workers running). Plan tasks 1–13 effectively done; gate passed on coaching
  quality, assessment capture parked (see item 1).
- `fix(agent)` context-leak fix, `fix(channels)` per-persona history cap,
  session-assessment capture helper + 9 unit tests — all committed.

---

## WAITING ON / EXTERNAL

- **Unified AI-type character** — to supersede Lovesick/Monika/Joje/Ichika.
  Not started; awaiting design.
- **Unified android character** — to supersede Nines/Charlotte. Not started.
