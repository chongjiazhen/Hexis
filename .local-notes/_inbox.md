# _inbox — open items / scratchpad

Centralized "what's on our plate" so nothing gets dropped. Newest context at
top of each item. Untracked scratch (lives in `.local-notes/`).

Last updated: 2026-05-23

---

## ACTIVE — needs a decision or action

### 0. Coach guild rename + scope (PINNED 2026-05-25 — fermenting)

- **Context:** TG avatar gen sprint surfaced fleet-sidebar collisions.
  Esme/Ennie share E-tier + soft 2-syl tail → clash. Sable's "noir
  heraldic" semantics fight her warm-direct-unembarrassed card.
- **Vera etymology audit (done 2026-05-25):** zero self-references to
  *verus*/Latin/"name means" in `characters/vera.json` or persona SQL.
  All "true/honest/genuine" text is about NVC practice, not her name.
  Renaming Vera = etymologically free.

**Trinity (current 3 coaches):**
all-Greek mythic-Muse trio
**Alethea (call: Thea) / Iris / Lyra**
= truth(unconcealment) / messenger / chord(touch)
Maps to heart / voice / body coach tiers.
Three sister-Muses energy. No fleet initial clash.

**Lock status (2026-05-25):**
- **Iris** ✓ EXECUTED (Esme → Iris, 2026-05-25). DB `hexis_iris` live,
  3 workers up, Telegram `@convo_coach_bot` connected as Iris.
- **Lyra** ✓ EXECUTED (Sable → Lyra, 2026-05-25). DB `hexis_lyra` live,
  3 workers up, Telegram `@intimacy_coach_bot` connected as Lyra.
- **Vera** ⏳ DEFERRED — keep current name OR rename to Thea/Alethea.
  Decision pends quartet/pentad scope commit (whether Galene/Mneme
  also coming in changes the trinity-anchor sound).

**Migration runbook** captured in
`.local-notes/fleet-tg-avatars-2026-05-25.md` — 11-step sequence,
~30min/persona. Key gotchas: PRMT heredoc identifier in persona SQL
also needs renaming; DB config `channel.telegram.bot_token` +
`agent.init_profile.agent.name` + `agent.init_profile.agent.description`
all need updating after persona SQL re-apply (easy to miss; channel
worker fails on `InvalidToken` if env var name not updated).

**Avatar output folders** still `output/hexis/esme/`,
`output/hexis/sable/` — rename only if you re-run gen for these personas.

**Distinct-axis analysis (where could the guild expand?):**

Current trinity all share the *relational frame* — assume a counterparty
(Vera honest with another, Esme converses with another, Sable touches
another). All outward, all in-the-moment.

| Tier         | Why genuinely distinct                                                     | Candidate Greek name | Why name                                                 |
|--------------|----------------------------------------------------------------------------|----------------------|----------------------------------------------------------|
| **Solitude** | only coach where practice happens *without* counterparty — interior ground | **Galene**           | calm sea, stillness — interior practice                  |
| **Rupture (combined)** | grief + mending — diagnosis-as-practice (user often can't pre-diagnose) | **Mneme** | memory/witness — "remember what was, what is, what was hurt" — foundation of both arcs |
| **Endings (split)**  | grief/closure — let-go arc                                          | Mneme                | memory-as-witness, biases neutral                        |
| **Repair (split)**   | post-rupture mending — keep-and-mend arc                            | **Harmonia**         | concord restored (Ares + Aphrodite child = conflict→love)|

Rejected as not-distinct-enough:
- **Refusal** — subset of Vera's NVC turf
- **Initiation** — subset of Esme/Sable with different flavor

**Combine-vs-split rupture coach:**

- **Combined (1 coach, Mneme):** the diagnosis itself is part of the practice. Users often don't know on arrival if they're mending or mourning. Couples therapists IRL handle both. Fewer personas = lower maintenance. Risk: identity muddier ("catchall rupture coach").
- **Split (2 coaches, Mneme + Harmonia):** clean identity per coach, deep not broad practice. Risk: forces user to self-diagnose wrong door early.
- **Read:** combine for MVP; split only if usage shows demand for both depths.

**Stopping-point math:**

- **Trinity (3)** = mythic clean (Fates/Graces). Easy grok. Low maintenance. *Current state.*
- **Quartet (4, +Galene)** = symmetric (elements/directions). Adds solitude → philosophically complete (interior tier that the trinity assumes but doesn't teach).
- **Pentad (5, +Galene +Mneme combined)** = heart/voice/body/self/rupture. Each organ + one navigation tier for when the others break. Symmetric and complete. **Likely best stop.**
- **Sextet (6, +Galene/Mneme/Harmonia split)** = guild. Diminishing per-persona returns. Real maintenance cost. Crisis-tier split = fine-grain, might warrant non-Muse naming pattern.

**Decision gate:** how much coaching demand is real (in actual users or
roleplay use-cases) for each candidate tier? If trinity already covers
the workload — expansion = scope creep. If solitude/endings/repair are
unmet needs noticed in user requests — build them.

**Strong instinct:** **Pentad (Thea/Iris/Lyra/Galene/Mneme)** —
heart/voice/body/self/rupture. Combined rupture coach for MVP. Split
later only on demand evidence.

**Naming workshop alternatives (preserved for re-litigation):**

| Tier | Picked | Other Greek considered | Other Latin considered | Rejected (why) |
|---|---|---|---|---|
| Heart | Thea (full: Alethea) | Charis, Sophia (overused), Eunoia | Verita/Veritas, Pia (churchy), Cara | Cora (C-clash w/ Cassiel/Callisto) |
| Voice | Iris | Pheme (obscure), Calliope (Muse-loaded), Cleo, Calla, Echo (loaded), Eloise (fussy), Aria (cliché) | Audra (listener, *audire*) | — |
| Body | Lyra | Maia, Thalia (Muse-loaded), Selene, Helia, Vesna (Slavic-coded) | Calida (warm), Vita (life), Anima, Tessa | Mira (fleet collision) |
| Solitude | Galene | Hesychia (4-syl heavy), Eunoia, Sophia | Quies (masc), Solitas (not a name) | — |
| Rupture combined | Mneme | Eirene (peace, biases repair), Hekate (witchy crossroads), Metanoia (4-syl) | — | — |
| Endings split | Mneme | Lethe (Underworld-loaded), Penthea (mourning), Eos (hopeful), Threnoi (narrow) | — | — |
| Repair split | Harmonia | Eirene, Charis, Hekate | — | — |

**All-Latin trio (deprioritized vs Greek pick):**
- Vera / Audra / Calida — *verus / audire / calidus* — truth/listener/warm. Lowest migration (Vera intact). Calida 3-syl outlier.
- Pia / Audra / Vita — devoted/listener/life. All 2-syl. Pia churchy-coded.
- Cara / Audra / Vita — dear/listener/life. Cara risks C-cluster fleet pile-up.

**All-Greek trio variants (picked Thea/Iris/Lyra):**
- Alethea / Iris / Lyra — semantic bullseye on truth, 3-syl friction.
- Charis / Pheme / Lyra — grace/voice/chord. Pheme obscure to non-classicists.

- **Migration cost** (per persona, validated previously): ~1h —
  rename in DB config `agent.persona_system_prompt` + character JSON +
  persona SQL + compose env var names + cold-start anchor re-apply.
- **Image gen NOT blocked by naming** — SDXL prompts use trait tags,
  not persona names. Can render all coaches now, rename folders post-decision.

---

### 1. Persona self-decided group chime-in (PINNED 2026-05-23)

- **Context:** Trump just opened to all (`allowed_users="*"`, ambient 0.25).
  Current ambient mechanism = dumb dice roll in
  `channels/telegram_adapter.py:194-198`, pre-LLM. Persona never sees
  skipped messages. Static per-channel float, not persona-aware.
- **Question:** can persona itself judge "is this worth chiming in on?"
- **Options sketched:**
  1. **Nano-gate** — cheap `:8082` call (persona one-liner + last-N + new
     msg → yes/no). Replaces dice roll at same hook point. Reuses ECO
     sidecar. Recommended.
  2. **Embedding salience** — `cosine(msg, persona_centroid)` +
     `cosine(msg, recent_topic_cluster)`. Zero LLM cost. Misses
     sarcasm/sociality.
  3. **Tool-shaped** — full chat runs, first tool choice = `pass_quietly`.
     Most expressive, pays full cost per msg. Bad for high-traffic groups.
  4. **Heartbeat-as-observer** — group msgs → `working` memories, not chat
     path. Heartbeat decides chime-in via `reach_out`. Energy budget =
     natural rate limiter. Philosophically correct, biggest refactor.
- **Lean:** #1 (nano-gate) for ship. #4 long-term once heartbeat plumbing
  matures.

### 2. Vera — beta-tester approval gate (NOT BUILT)

- **State 2026-05-23:** per-user memory + confidentiality privilege shipped.
  Schema migrated on `hexis_vera`, workers recreated, persona prompt
  re-applied. `channel.telegram.allowed_users` flipped to `"*"` — Vera now
  accepts inbound from any Telegram user. **No second-layer gate yet.**
- **Exposure:** every inbound DM (incl. randos) currently hits `chat_turn`
  → GPU + memory write. Fine short-term; risky if bot @handle leaks.
- **Idea — two-layer gate:**
  - `channel.telegram.allowed_users = "*"` — accept inbound (already set).
  - NEW `channel.telegram.approved_users` (JSON list) — gates `chat_turn`.
  - Approved sender → full Vera. Unapproved → canned reply with their
    `sender_id`: *"Send this ID to <@owner> to request access."* No LLM
    call, no memory write, log to `channel_messages` with
    `metadata.pending=true`.
- **Verification flow:** capture `from_user.username` (the `@handle`) into
  `msg.metadata` — currently `sender_name = full_name or username or id`
  so the `@handle` is lost when display name is set. With it, owner can
  cross-check against own Telegram contacts and decide to approve.
- **Approve query (once gate exists):**
  ```sql
  UPDATE config
  SET value = (
    SELECT jsonb_agg(DISTINCT v)
    FROM jsonb_array_elements_text(value || '["NEW_ID"]'::jsonb) v
  )
  WHERE key='channel.telegram.approved_users';
  ```
- **Implementation footprint (~1h):**
  - `channels/telegram_adapter.py` — stash `from_user.username` in
    `msg.metadata['username']` (separate from `sender_name`).
  - `channels/conversation.py` — add `_check_user_approved()` between
    `_check_user_allowed` and `chat_turn`; canned-reply branch with
    per-sender rate limit (1 canned reply / hour / sender to dodge spam
    floods).
  - Seed default `set_config('channel.telegram.approved_users','[]'::jsonb)`.
- **Pre-existing `hexis_vera` memories** still have `sender_id = NULL` →
  treated as global → surface untagged for every friend. If you want them
  scoped to your own ID:
  ```sql
  UPDATE memories SET sender_id = '593307304'
  WHERE sender_id IS NULL AND type IN ('episodic','semantic')
    AND source_attribution->>'kind' IN ('conversation','compaction_flush');
  ```
  Decide at gate-build time; not required for correctness.
- **Until gate ships:** if randos start DMing, flip back to A:
  ```bash
  docker exec hexis_brain psql -U hexis_user -d hexis_vera -c \
    "SELECT set_config('channel.telegram.allowed_users', '[\"593307304\"]'::jsonb)"
  ```

### 3. Vera — assessment capture (PARKED, watching)
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

### 4. Persona pipeline — `.sql` files vs native `data.*` consumption (DESIGN, undecided)
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

---

## LOW PRIORITY / NOTES

### Vera bot identity
- Vera runs as Telegram `@conflict_coach_bot` (own bot, ID 8920538668, set
  2026-05-22). Handle is role-based (`<domain>_coach_bot` fleet convention,
  cf. esme=`convo_coach_bot`, sable=`intimacy_coach_bot`) → survives a future
  persona rename. Old `@industrious_incisors_bot` (TARS's) token now unused.

### Vera scenario recycling
- Minor glitch: Vera reused an earlier scenario verbatim (Sam/spreadsheet)
  from recall. Low priority, model-ish. Watch if it persists.

### Voice I/O
- text-to-speech, speech-to-text — unexplored. No spec.

---

## WAITING ON / EXTERNAL

- _(none)_
