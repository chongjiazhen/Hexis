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

### 3. Persona pipeline — `.sql` files vs native `data.*` consumption (DESIGN, undecided)
- **Origin:** `characters/set_persona_prompt.<name>.sql` is fork-only. Upstream
  (QuixiAI/Hexis) has no `agent.persona_system_prompt` key AT ALL — confirmed
  `git grep` on `origin/main` finds it in zero `*.py`/`*.sql`. No GitHub issue
  on persona collapse either; upstream genuinely doesn't hit it.
- **Why we diverged:** upstream builds the system prompt per-turn from a
  generic base + `agent_profile` JSON + hydrated identity/worldview memories
  (`build_system_prompt`, `services/agent.py:234`). Adequate for a mild
  assistant persona. Our ST RP/NSFW cards carry their character in
  `data.system_prompt` / `data.post_history_instructions` — fields upstream's
  pipeline NEVER reads (only `extensions.hexis` consumed at init). Flattened
  to a JSON profile → generic-assistant collapse on cold turns.
- **The `.sql` file does TWO jobs:** (1) translate card prose → the config
  row; (2) live re-apply to a running DB without destructive `hexis init` /
  `down -v` (idempotent `INSERT ON CONFLICT DO UPDATE`, effect next turn).
- **Proposed alt:** patch `init_from_character_card()` to set
  `persona_system_prompt` from `data.system_prompt`+`data.post_history_instructions`
  natively + add `hexis persona apply <name>` CLI for job (2); delete the 16
  `.sql` files + `gen_persona_sql.py`.
- **Why NOT light:** this is a fork-vs-upstream architecture call, not a
  refactor. (a) Deepens divergence from upstream's "persona emergent from
  memory" invariant — every future rebase pays. (b) QuixiAI won't take the
  patch → permanent maintenance tax, chosen on purpose. (c) Touches a DB
  function + CLI + 16 live DBs → fleet migration, worst-first, signoff-gated.
- **Real decision:** keep `.sql` (ugly, working, rebase-cheap) vs invest in
  the fork (cleaner, single source of truth, permanently parted from upstream
  on persona architecture). Picking the latter = admitting the fork has
  already left upstream — which, given NSFW pipeline / power modes /
  per-persona outbox / ECO gate, it arguably has.
- **Next:** no code. When ready to decide, write a `.local-notes/` RFC
  stating options + costs + the divergence question plainly.

### 4. CLAUDE.md staleness
- Debugging section says `channel_sessions.history` = "last 8 turns". Wrong:
  actual cap is `MAX_SESSION_HISTORY=40` → trim to `30` (`channels/
  conversation.py`), now config-overridable via `channel.history.max` /
  `channel.history.trim`. Fix the CLAUDE.md line when convenient.

### 5. Per-user memory — one persona, many DM partners (DESIGN, undecided)
- **Question:** can a single Vera DMing several people remember each one
  individually?
- **Today — half:** `channel_sessions` is keyed by `sender_id` → recent
  conversation history IS per-partner. But the `memories` table has NO
  sender/subject column — one shared pool per `hexis_vera` DB.
  `_remember_conversation` writes untagged; `hydrate`/`fast_recall` query
  DB-wide. So the persistent layer (episodic/semantic/strategic — Vera's
  actual value) is NOT per-user: recalling for Alice can surface Bob's
  memories. Hexis is architecturally single-self / single-relationship
  (one `agent` row, one identity, one memory pool).
- **Two paths to multi-client:**
  - **A. DB per client** (`hexis_vera_alice`, …) — zero new code, but N DBs +
    N channel workers, not "one Vera" (N clones, no shared Vera-growth),
    doesn't scale.
  - **B. Per-subject scoping in one DB** — tag each memory with `sender_id`
    (column or `metadata`), scope `hydrate`/`fast_recall` to the current
    sender. One Vera, one identity, per-client memory partition. Correct
    model. Real work: schema + hot-path `fast_recall` (`db/*.sql`) + memory
    API + thread `sender_id` through the chat path. Fleet-wide schema change.
- **Next:** no code. Genuine architecture project, not a tweak. If pursued,
  write a `.local-notes/` RFC (B is the right design; cost is the question).

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
