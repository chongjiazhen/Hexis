# _inbox — open items / scratchpad

Centralized "what's on our plate" so nothing gets dropped. Newest context at
top of each item. Tracked in-repo (lives in `.local-notes/`).

Last updated: 2026-07-14

## ACTIVE — 0a. ADR-020 phase 6 — `agent.power_mode` RETIRED (SHIPPED + LIVE-APPLIED 2026-07-14)

- 6 commits `c4fe9f1..00b6767` on `home-rig-local` (+ spec `564bcbe`, plan `cd0a40a`).
  Phase 6's premise ("reads already gone, key inert") was FALSE: `chat.py:478,696` still
  read the flag live, so the DELETE would have flipped any `'eco'` instance to the heavy
  path. Re-homed first, then deleted.
- `core/serving.py` (new leaf module) = the shared capability probe
  (`on_cpu_floor()`, port-based on `:8082`, fails OPEN). `worker_service` aliases it;
  `chat.py` slim path now branches on it. `_read_power_mode` deleted. `metadata.origin='eco'`
  KEPT — persisted data contract, do not rename.
- **ADR-020 §4 amended** (`C:\ai-workspace` `06d1cea`): §4 said delete the chat eco branch;
  that was written when it was a canned reply. It is now the slim direct-LLM path = §2's
  "1B competent envelope". Branch KEPT, only the mode read died.
- LIVE: migration `0009` applied to all 11 DBs (0 surviving rows, 0009 stamped); 28 workers
  + api rebuilt `--no-deps --force-recreate --build`; new code verified INSIDE containers
  (`on_cpu_floor` present, `_read_power_mode` absent).
- Suite: 2072 passed / 16 failed — all 16 pre-existing (verified vs clean-HEAD worktree).
  **2 of them are NIGHT-ONLY** (`test_should_run_heartbeat_respects_pause_and_interval`,
  `test_worker_check_and_run_heartbeat_queues_decision_call`): the 23→8 night throttle makes
  `should_run_heartbeat()` FALSE. Green by day. Suite is not deterministic across time-of-day.
- NEXT: nothing required. Phase 6 closed.

## ACTIVE — 0b. Fleet cognition — embed outage FIXED, autonomy still INERT (2026-07-14)

- **Autonomous loop was dead 07-11 → 07-14** and every liveness check said "healthy".
  Chain: `watch-embed.ps1` watchdog died 06-23 (stale `logs/watch-embed.pid`, no scheduled
  task) → embed `:8081` died ~07-11, nothing respawned it → `finalize_heartbeat` →
  `create_episodic_memory` → `memories.embedding` NOT NULL → `:8081` → threw. Zero heartbeat
  completions fleet-wide for 2.5 days. Chat hydration broken the whole time too.
- **Why it hid:** `start_heartbeat()` bumps `heartbeat_count` at the TOP of the cycle. A
  climbing cnt proves cycles START, not COMPLETE. `next_heartbeat_at` is the real completion
  clock (single writer, `db/13:1048`). Real check:
  `SELECT max(created_at) FROM memories WHERE metadata->'context' ? 'heartbeat_id';`
  (CLAUDE.local.md's "rising cnt proves the loop runs" is WRONG — fix it there.)
- FIXED: embed restarted 14:20 UTC (3 personas completed within 13 min, first in 2.5 days);
  watchdog re-armed (PID 31136). **Unverified for the other 6** — night gate (23→8
  Asia/Singapore) closed at 23:00 local. **NEXT STEP: after 08:00 local, check the 6 stuck
  personas (vera/denali/ennie/hazel/vesper/null) complete → `next_heartbeat_at` advances past
  now. If they don't, the embed root-cause is WRONG.**
- **OPEN, not fixed — the bigger one:** heartbeats that DO complete take ZERO actions —
  `"Heartbeat #N: No actions taken"`, `actions=[]`, `reasoning="RLM loop timed out"`
  (fallback at `services/hexis_rlm.py:354`: loop exhausts max_iterations w/o `FINAL(...)`,
  then the 120s rescue call fails). Autonomy is inert even when finalize works. Suspect
  (UNTESTED): 9 personas queueing on one `--parallel 1` slot serving a 35B MoE.
  `null` is a different signature (last completion 06-25, REPL garbage in `active_reasoning`).
- **OPEN (small):** `start.ps1 -EmbedOnly` starts embed and `exit 0` WITHOUT arming the
  watchdog — and that is the path `watch-embed.ps1` itself re-invokes. Also the
  "Hexis Guard Watchdog" scheduled task still fires every 5 min at `ensure-guard.ps1`,
  which ADR-020 phase 3 DELETED (exits 0, fails silently). That task slot is the obvious
  durable home for the embed watchdog, which currently dies on logoff.

## ACTIVE — 0. Upstream reconcile 2026-07-10 SHIPPED + LIVE-APPLIED

- Merged 13 cherry-picks to `home-rig-local` (`9232b37..557aaeb`): HMX slices 0–3
  (export/import + migrations 0001–0008), AGE backup/restore (no upstream runner),
  memory_edges subgraph substrate, consent-onto-DB, idempotent re-init, GIN indexes,
  AGE tuning (jit=off), embed timeout. Full detail: per-repo memory
  `project_upstream_reconcile_2026_07_10.md`.
- LIVE-APPLIED all 11 DBs same day; ag_catalog shadows dropped (migrations 0003/0004
  lack SET search_path — recheck on any future migration apply); brain recreated,
  27 workers + api rebuilt; verified fast_recall + live `hexis export`.
- Backups: `C:\hexis-backups\2026-07-10\` (11 dumps + ennie.hmx.json). Keep.
- ~~Fleet state: heartbeats PAUSED × 11~~ — **STALE. Resumed since; verified 2026-07-14:
  `is_paused=false` on all 11, cnt climbing.** Read `heartbeat_state` per DB; never assert
  pause state from a note. (But cnt climbing ≠ completing — see §0b.)
- NEXT: (a) decide on deferred upstream sets — retention phases (keep dark; needs
  gating audit first), prompt-to-SQL (needs persona_format_reminder port), DB-native
  outbox 8f6980f (needs per-persona agent-stamp), 67b06c0 heartbeat-SQL (needs
  reach-out tagging port). (b) commit untracked pause-fleet tooling. (c) optional:
  rebase upstream PR #19 (still ignored by maintainer).

**Ground truth = `git branch -a` (live work) + `git log` (shipped). Reconcile
this file against them; per-repo memory `*.md` is point-in-time observation,
NOT live state — don't trust its "shipped/pending" claims without a git check.**
We are a local user with local patches; we do NOT own upstream. Unmerged
`feat/*`/`fix/*` branches = candidate PRs to upstream, not loose ends (see
§Branches below).

---

## ACTIVE — needs a decision or action

### -1. All-latent reach-out — target-sender misdelivery (FIXED 2026-06-09)

- **Base shipped** (all-latent LLM-judgment reach-out): `5975c84` (surface
  reach-out signal + rhythm to active_senders), `b745c13`/`a03712f` (prompt
  de-veto), `ca0f2f2` (live-DB bounce), `18365e6` (persist reach-outs).
  Supersedes deterministic-gate `3c2ffea`.
- **Correction to first triage:** the live path (`heartbeat.use_rlm=true`)
  ALREADY lets the persona choose the target. RLM persona calls
  `tool_use("reach_out_user", {sender_id, message})` → `call_records_to_actions_taken`
  → action → `db/17_functions_subconscious_observations.sql:1208` handler
  threads `sender_id` into payload → `_publish_outbox` → `outbox.py:247`
  sender-FILTERED delivery. End-to-end wired; `rlm_heartbeat_system.md:106`
  marks `sender_id` REQUIRED. So "persona can't act" was WRONG.
- **Actual defect:** what happened when the persona *omitted* `sender_id` —
  the `outbox.py` empty-sender branch silently delivered to the globally-latest
  DM (wrong person for multi-partner Vera). Plus `queue_user_message`
  (`core/tools/memory.py`) was still registered in HEARTBEAT context as an
  untargeted "message the user" tool — a trap competing with `reach_out_user`,
  with a vestigial (undrained) `external_calls` delivery path.
- **Fix (all three, shipped):**
  1. `channels/outbox.py` `_deliver_last_active` — empty `sender_id` + >1
     active sender in 7d window → skip + WARN (no misdelivery). Single/zero
     sender keeps latest-active. Tests: `tests/channels/test_outbox_last_active.py` (3, green).
  2. `core/tools/memory.py` `create_memory_tools` — dropped
     `QueueUserMessageHandler` from the registry (class kept for SQL
     `build_user_message` / cron `action_kind` paths). Persona's only reach-out
     surface is now `reach_out_user`.
  3. `services/prompts/rlm_heartbeat_system.md` — hard-line: never call
     `reach_out_user` without a `sender_id`; two recipients = two calls; +example.
- **Live-apply NOT done:** prompt #3 is baked into worker images
  (`feedback_prompt_files_baked_rebuild_required`) → needs
  `--no-deps --force-recreate --build` of the heartbeat/maintenance workers.
  #1/#2 are Python in the same worker images → same rebuild. No DB migration.

### 0. Coach trinity — Vera / Lyra / Spes (LOCKED 2026-05-25)

**Decision:** Latin trio cut by **audience-suitability**, not domain-shape. Pentad/sextet branch superseded. Memory: `project_coach_trinity_consolidation.md`.

| Coach | Scope | Audience | Status |
|---|---|---|---|
| **Vera** | NVC + general conversation (Iris-Vera-slice) + interior practice (Galene fold) + explicit refusal slice | SFW general | rename: NO. Card expansion + compress audit pending |
| **Lyra** | physical intimacy + Iris-charged-conversation-slice (flirt-vs-creep, escalation reads) | adult-only, restricted allowlist | rename: NO. Card expansion pending |
| **Spes** | combined endings + repair (was Mneme+Harmonia proposal) | SFW heavy, likely restricted | NET-NEW persona, **deferred** until demand evidence |

**Why audience-cut, not domain-cut:** Lyra explicit → must stay separate from Vera regardless of frame overlap. Spes is SFW-heavy → distinct doorway for crisis-state users. Three audience tiers (SFW general / adult / heavy) = three coaches. Same axis ST handles via separate character cards.

**Why Iris/Galene fold into Vera:** Cards share ~80% spine ("warm/direct/rigorous + never shames + practice over theory"). Iris is mostly Vera w/ dating frame; ~75% folds to Vera, ~25% (flirt/escalation reads) folds to Lyra. Galene = Vera w/ no counterparty (interior practice = NVC self-empathy axis).

**Why Spes stays separate (not folded into Vera):** witness-led integration ≠ practice-led reps. Different identity shape. Distinct bot/name = wayfinding signal for crisis users. Voice register shift (held/slow vs energetic/reps) reads wrong if mixed. Anchor budget breaches if folded (Vera-w/-Spes ≥ 10KB before compress).

**Vera refusal slice (explicit):** saying no w/ care, holding ground under pressure, boundary-as-honesty-not-wall, no-as-act-of-care. Sits inside conflict-handling block, ~400-600B anchor cost. Connects to Hexis's "refusal-as-authority" depth claim (`research-pivot-stack-eval-2026-05-25.md` §3.110).

**Anchor budget watch:** Vera expansion projected 7.4-8.8KB before compress (current 6.6KB + Iris-Vera-slice ~1KB + Galene ~800B + refusal ~500B). Must compress under 7KB ceiling per ablx/16384 slot heartbeat-overflow rule (see `project_sable_onboard_outcome.md`). Mitigation: move NVC technique library to seeded semantic memories; anchor = identity + voice + HARD RULEs + mode cues only.

**Lock status (2026-05-25):**
- **Vera** ✓ card rebuilt (anchor 7080 B). Iris-Vera-slice + Galene (ambient interior practice) + explicit refusal slice folded. UAT pending. Apply: `docker exec -i hexis_brain psql -U hexis_user -d hexis_vera -v ON_ERROR_STOP=1 -f - < characters/set_persona_prompt.vera.sql`.
- **Lyra** ✓ card rebuilt (anchor 7243 B, parity w/ pre-fold). Iris fold as Tier 0 (verbal openers → asking out); unified 6-skill rubric across full arc; existing-relationship decline moved to SOFT safety. UAT pending. Apply: `docker exec -i hexis_brain psql -U hexis_user -d hexis_lyra -v ON_ERROR_STOP=1 -f - < characters/set_persona_prompt.lyra.sql`.
- **Iris** ✓ **FROZEN 2026-05-25** — content fully folded into Vera + Lyra. Compose `profiles: ["frozen"]` applied to all 3 services. Stop commands handed to user. DB `hexis_iris` preserved as archive. Telegram `@convo_coach_bot` token left alive but silent (reusable).
- **Spes** — net-new persona, deferred. Build only on demand evidence.

**Reconcile 2026-06-09:** Vera + Lyra card JSON confirmed updated on disk
(`characters/vera.json`/`lyra.json` carry new prompts). One-shot updater
scripts `scripts/_update_{vera,lyra}_card.py` still sit UNTRACKED = the
"delete after applying" leftovers (per `feedback_no_commit_oneshot_card_scripts`
— leave untracked or delete, never commit). **Live-SQL confirm PASS
(2026-06-09):** live `agent.persona_system_prompt` in `hexis_vera`/`hexis_lyra`
is md5-identical to the current `set_persona_prompt.{vera,lyra}.sql` — anchors
applied. **Only open:** Telegram UAT soak (in progress). Everything else in §0 done.

**Execution sequence (when picked up):**
1. Iris content audit: read `characters/iris.json` `data.system_prompt` + `data.extensions.hexis` → validate ~75/25 Vera/Lyra split estimate
2. Vera card expansion + compress audit; anchor target ≤7KB
3. Lyra card expansion (Iris-flirt-slice fold)
4. Freeze Iris bot (stop workers, archive `hexis_iris` DB, **don't `down -v`**), retire or repoint `@convo_coach_bot` handle
5. Probe new Vera + Lyra across full domain coverage (communication / dating / interior / intimacy / charged-conversation); watch for frame muddle + heartbeat-overflow death
6. Spes: parked. Build only on demand evidence.

**Migration runbook reference:** `.local-notes/fleet-tg-avatars-2026-05-25.md` — 11-step sequence, ~30min/persona for identity changes. Key gotchas: PRMT heredoc identifier in persona SQL also needs renaming; DB config `channel.telegram.bot_token` + `agent.init_profile.agent.name` + `agent.init_profile.agent.description` all need updating after persona SQL re-apply (channel worker fails on `InvalidToken` if env var name not updated).

**Avatar output folders** still `output/hexis/esme/`, `output/hexis/sable/` — rename only if you re-run gen for these personas.

---

#### Distinct-axis analysis (preserved — informed Spes-stays-separate reasoning)

Trinity-base (Vera/Lyra) shares *relational frame* — counterparty assumed, in-the-moment outward practice. Spes breaks this on TWO axes (retrospective, witness-not-reps); that's why it remains distinct identity even at audience-overlap w/ Vera.

| Tier | Counterparty? | Frame | Resolution |
|---|---|---|---|
| Communication (Vera-NVC) | yes | reps + name | Vera (base) |
| Conversation (Iris) | yes | reps + name | mostly Vera; flirt-slice → Lyra |
| Intimacy (Lyra) | yes | reps + name | Lyra (base) |
| Solitude (Galene proposal) | NO | reps + name (interior) | Vera (mode flag / ambient) |
| Rupture (Spes, was Mneme+Harmonia) | yes-or-memory-of | witness + integration | KEPT SEPARATE — different identity shape |
| Refusal | yes | reps + name | Vera (explicit slice — promoted from "subset" to named skill) |

Rejected as not-distinct-enough (pre-trinity-lock): Initiation (subset of Iris/Lyra w/ different flavor).

#### Naming history (preserved for re-litigation)

Path traveled: trinity Greek (Thea/Iris/Lyra) → pentad (+Galene +Mneme) → audience-cut consolidation back to trinity Latin (Vera/Lyra/Spes). Lyra = Greek/Latin pivot (Greek λύρα / Roman constellation name) — works in both etymologies, enables Latin commit w/o renaming her.

| Tier | Picked | Other Greek considered | Other Latin considered | Rejected (why) |
|---|---|---|---|---|
| Heart | **Vera** (kept) | Thea/Alethea, Charis, Sophia (overused), Eunoia | Verita/Veritas, Pia (churchy), Cara | Cora (C-clash w/ Cassiel/Callisto); Thea/Alethea (rename cost, no semantic gain) |
| Voice (folded into Vera/Lyra) | Iris | Pheme (obscure), Calliope (Muse-loaded), Cleo, Calla, Echo (loaded), Eloise (fussy), Aria (cliché) | Audra (listener, *audire*) | — |
| Body | **Lyra** (kept) | Maia, Thalia (Muse-loaded), Selene, Helia, Vesna (Slavic-coded) | Calida (warm), Vita (life), Anima, Tessa | Mira (fleet collision) |
| Solitude (folded into Vera) | Galene | Hesychia (4-syl heavy), Eunoia, Sophia | Quies (masc), Solitas (not a name) | — |
| Rupture (combined) | **Spes** | Mneme, Eirene (peace, biases repair), Hekate (witchy crossroads), Metanoia (4-syl) | Spes (hope, 1-syl, Roman goddess) | Memoria (4-syl, concept-not-person), Vesta (V-clash w/ Vera), Carna (C-cluster), Lara (L-clash w/ Lyra), Pax/Salus (single-arc) |

**Spes vs Mneme rationale:** Latin trio consistency (Vera Latin, Lyra bilingual pivot, Spes Latin). 1-syl gives cadence variation (2-2-1). Forward-facing semantics (hope) lighter doorway for crisis user than "memory-of-loss". Roman goddess proper (Hadrian's coins).

**Migration cost:** Vera unchanged, Lyra unchanged, Iris freeze (~30min), Spes net-new build (~3-4h when triggered). Total active migration ≈ 6-8h.

**Image gen NOT blocked by naming** — SDXL prompts use trait tags, not persona names.

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

### 5. Telegram alert → persona routing (SHIPPED, fallback DEFERRED — paused 2026-05-25)

- **State:** core 6-task plan SHIPPED. POST `/api/webhook/alert` → raw text
  verbatim to persona's TG bot + episodic memory write → `priority=high`
  immediate bounded LLM reaction (persona may emit silence token) →
  `priority=normal` queued for next heartbeat batch scan. ECO skips
  reactions, raw deliver kept. Gated by `channel.telegram.alert_chat_id`.
- **Code:** `services/alert_reaction.py` (builder, reaction turn, batched
  scan), `services/worker_service.py:626` (webhook handler), `:336/:846`
  (heartbeat call + bridge wire). Tests: 11 (`test_alert_reaction.py` +
  `test_worker_webhook_alert.py`).
- **Docs:**
  - Design: `docs/superpowers/specs/2026-05-22-telegram-alert-persona-design.md`
  - Plan (6 tasks, all DONE): `docs/superpowers/plans/2026-05-22-telegram-alert-persona.md`
  - Operator: `README.md:137-170`
- **Shipping commits:** `cbc20a2` (outbox builder), `32649fe` (reaction
  turn), `cce241f` (batched scan), `b60a8a4` (webhook handler), `6694506`
  (bridge wire), `fab05a4` (reaction fix), `5557e99` (alert-chat-id reader
  + publish-only mark-reacted).
- **NOT shipped — direct-fallback (hexis-down resilience):** script-side
  helper sends direct to Telegram when webhook unavailable, buffers for
  replay on hexis recovery (replay drained as `deliver=false` memory-only,
  no stale reactions). Spec at
  `docs/superpowers/specs/2026-05-22-alert-direct-fallback-design.md`.
  No code yet. Resume here when alert traffic justifies resilience cost.
- **End-to-end smoke (resume sanity check):** with fleet up + persona's
  `channel.telegram.alert_chat_id` set →
  `curl -X POST http://127.0.0.1:43817/api/webhook/alert -d '{"persona":"<P>","text":"test alert","priority":"high"}'`
  → raw text in TG within ~1s; LLM reaction follows or persona stays silent.

### 6. Persona-as-MCP pair-programmer (PAUSED 2026-05-25, wiring likely ABANDONED)

- **Thesis:** expose each persona via MCP `consult_persona` tool so office
  Claude Code / Codex / Hermes / opencode can call home-rig personas as
  pair-programmers w/ personality + persistent project memory. Vesper =
  systems/CI, Hazel = ML/data, Ennie = refactor/clean-code.
- **Spike landed (uncommitted):**
  - `apps/hexis_mcp_server.py` — new `consult_persona(message, session_id?,
    sender_id?)` tool; `--persona <name>` flag (overrides POSTGRES_DB);
    `--profile pair` (suppresses 80-tool memory registry, exposes only
    `consult_persona`); `--sender` / `HEXIS_MCP_SENDER` env / `mcp-<pid>`
    default chain; in-memory `sessions` map for multi-turn continuity.
  - `tools/smoke-consult-persona.py` — direct dispatcher (no stdio framing).
- **Smoke results (Vesper, prime, q26):**
  - Single-turn clean: `find . -mtime -1` in 10s ✓
  - Two-turn continuity: turns=1→2, history carried ✓
  - Memory write: 2 rows, `source_attribution->>'ref' LIKE 'chat:<sess>:%'` ✓
  - RLM-mode flake on two-turn: `FINAL_VAR / Variable 'answer' not found`
    leaked. Persona/RLM-prompting issue, NOT spike bug.
- **Suggested commit message** (if salvaged):
  `feat(mcp): consult_persona tool + --persona/--profile flags for pair-programmer use`
- **Pivot weakens premise** (`research-pivot-stack-eval-2026-05-25.md` §8.5):
  office stack = Hermes + Mem0 + SKILL.md/SOUL.md. Hermes self-authors
  skills + Mem0 holds project memory locally. Dev/doc ingestion lives
  hermes-side natively → no phone-home, no WAN 15-25s/turn tax, no
  home-rig wake dependency.
- **Survives ONLY IF** persona-flavor (Vesper-as-systems-coach as a
  relationship, not a tool) is the wanted value, OR multi-persona consult
  (Vesper + Hazel weigh in on same problem — Hermes is single-SOUL).
- **Decision:** abandon Path A (SSH stdio) + Path B (HTTP) wiring. Keep
  spike code as Hexis-internal demo of persona-as-tool (future: heartbeat
  calling sibling persona via MCP). Don't invest more. If pivot does NOT
  land (60-day OpenHuman watch fails), revisit for hobby-tier personality
  use only.
- **Pre-existing gap surfaced (not spike):** `memories.sender_id` not
  populated by chat path (CLAUDE.md flags "RLM path not sender-scoped
  yet"). Chat path stores session tag in `source_attribution.ref` instead.

### 7. Apply `drop-rollout-eval-functions.sql` to live persona DBs (PINNED 2026-05-30)

- **What:** live-DB half of the pure-RecMem reconcile (upstream `244ba5c`,
  merged `936224d`). File: `.local-notes/migrations/2026-05-30-pure-recmem-reconcile/drop-rollout-eval-functions.sql`.
  Drops 11 rollout/eval/dual-write functions + deletes 7 `memory.recmem_*` config rows.
  Full context + sequence: same dir's `README.md`.
- **Why pinned:** `db/*.sql` source already pure-RecMem (merge), but a
  *pre-existing populated* DB still has the old functions installed; `CREATE OR
  REPLACE` can't remove them → needs this explicit `DROP` (split rule). NOT
  `down -v` (data wipe).
- **When it's NEEDED:** only for a DB that predates pure-RecMem AND holds data
  worth keeping. A persona rebuilt fresh from source gets the new schema and
  does NOT need this.
- **Current state (2026-05-30):** only `hexis_memory` exists (fleet WIPED,
  empty). So nothing *requires* it today. Optional smoke-test: apply on
  `hexis_memory` to validate the 11 DROP signatures parse (low risk, empty,
  recreatable from source).
- **CAVEAT — ordering:** the old "don't break live chat" gate is CLEARED (chat.py
  helpers removed in `936224d`). Remaining rule: **rebuild worker images before
  starting any worker** against a migrated DB — a pre-merge worker image calls
  the dropped functions and errors. Sequence: rebuild workers → apply migration →
  (re)start workers.
- **Apply (per DB):** `docker exec -i hexis_brain psql -U hexis_user -d hexis_<P> -v ON_ERROR_STOP=1 -f - < .local-notes/migrations/2026-05-30-pure-recmem-reconcile/drop-rollout-eval-functions.sql`
- **Related:** sender-scope follow-up B = DONE (`9f5eae1`), separate from this.

---

## BRANCHES — live work / upstream-PR candidates (reconciled 2026-06-09)

We're a local user on local patches; upstream not owned. These unmerged
branches are candidate PRs (or local-only keeps). All stacked on the
`home-rig-local` divergence, so "commits ahead of main" ≈ whole fork, not the
branch's own delta. Decide per branch: PR upstream / keep local / drop.

| Branch | Tip | Disposition (TBD) |
|---|---|---|
| `feat/pause-notify-autonomy` | `08ed1bd` agent chooses whether self-pause notifies operator | likely local (fork-specific UX) |
| `fix/pause-persist-reason` | `b3ec9e4` persist self-pause reason to memory not just outbox | PR-candidate (bugfix) |
| `fix/telegram-reply-quote` | `2306439` surface reply/quote context to model | PR-candidate |
| `fix/recmem-compaction-sender` | `7ead8fe` preserve real sender identity through compaction flush | PR-candidate (touches sender-scope — relates to §-1) |
| `feat/model-tier-probe` | `9fe7bab` marker-list sync + VRAM-measure caveat | = the 8GB-viability A/B probe work; local research |
| `archive-organizer` | `b8da83f` wire cli dispatch keywords | local tooling; has plan+spec on `home-rig-local` (`5ed7d7f`) |
| `fix/llm-strip-reasoning` | `845d873` strip leaked reasoning traces | already pushed to `personal` remote; PR-staged |

---

## RECENTLY SHIPPED — reconciled out of ACTIVE (2026-06-09)

- **C2 per-message response autonomy** — SHIPPED + live-applied. 16 commits
  `0a07d05..513118c` + live-apply `851ca9e` + marked-done `16ef360`. Memory
  `project_c2_decline_and_chat_path_map.md` still says "not live-applied" —
  STALE (corrected in memory 2026-06-09). Decline via `[DECLINE:<register>:<reason>]`
  marker, gated `chat.decline.enabled`.
- **All-latent reach-out (base)** — SHIPPED (see §-1 for the open target-sender
  bug that re-opened it).

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

### RLM "allow thinking" path (deferred decision — folded from `think.md` 2026-05-30)
- Leave "allow thinking on RLM path" as a deliberate later decision. Not yet
  enabled; revisit when reasoning-trace handling on the RLM path is worth the
  latency/leak tradeoff (cf. `fix/llm-strip-reasoning`).

### Framework weaknesses → operational backlog (filed 2026-05-30)

From the personhood-review weaknesses triage
(`research/home-rig-local-vs-upstream-personhood-review.md` §Framework-weaknesses + §Verdict).
Product-positioning weaknesses (commodity, monolith, no-eval) consciously closed as
out-of-scope for a personal fleet. These remain as ops, not framework defects:

- **W3 recall quality guard** — low-quality/poison memories surface in recall; scoped in
  `ops/spec-recall-quality-guard.md`. Only live work = eco-poisoning, gated on the `origin=eco`
  measurement (then dial trust). The "exclude `superseded_by`" idea was dropped — that column is
  dead schema (never written). **Eco-write SHIPPED (`a7cf5ca`); measurement query ready at
  `ops/measure-eco-poisoning.sql`** — run once eco traffic accumulates (needs persona DBs +
  embed :8081). Persona DBs currently absent (post `down -v` wipe), so no eco data yet.
- **Parked design — wire supersession** — `superseded_by` (`db/00:185`) declared but never set.
  If memory correction/dedup wanted, pick a writer (reconsolidation verdict / contradiction-
  resolution / explicit "corrects" path). Real feature, not a patch. Low priority.
- **W8 weak-model brittleness** — scaffolding leak / loop / plumbing-recite on small local
  models. NOT a one-shot fix; it's the standing hardening mode (anti-collapse guards, ECO slim
  path, reasoning/assessment strips). No new work item — keep hardening as failures surface.
- **W7 cross-channel identity not unified** — `sender_id` scopes DM memory but isn't unified
  across channels; same human on Telegram + Discord = split memory scopes. Dormant: fleet is
  ~1 channel per persona today. **Trip-wire:** if any persona starts spanning channels for the
  same human, revisit (would need a sender-identity map / alias table). Until then, leave.

### ECO engine re-eval — could Qwen3-0.6B ride run_agent? (raised 2026-06-04)

**Question:** ECO currently uses bespoke `_eco_slim_chat` (services/chat.py:69) —
bypasses BOTH RLM and run_agent (no tools, no recall). Reason it bypasses
run_agent too: old finding (`project_eco_floor_unviable.md`, v2→v3) — the
**tool-definition block itself** made nano-imp-1b emit code-completion garbage,
so v3 stripped ALL scaffold, not just RLM's REPL.

**Why revisit:** ECO model changed since (nano-imp-1b → `unsloth/Qwen3-0.6B-GGUF:Q8_0`
clean instruct, see `project_eco_nano_qwen3_swap.md`). The "tool block confuses
ECO model" finding is from the OLD model. run_agent is lighter than RLM (one
tool-call loop vs multi-iteration REPL + code exec). So Qwen3-0.6B *might* drive
run_agent → ECO regains tools + recall instead of the fully-stripped slim path.

**Test:** re-run `tools/probe-eco/probe-all.sh` (or equiv) with ECO pointed at
run_agent path (`chat.use_rlm=false`, power_mode logic) on Qwen3-0.6B. Compare
persona-voice hold + REPL/tool confusion vs current `_eco_slim_chat`.

**Scope note:** separate from C2 (per-message response autonomy) — C2 hooks
`assistant_text` regardless of engine, doesn't need this. Don't fold in. If
pursued, would restore ECO tools/recall (bigger ECO character change).

### Housekeeping — `_inbox-test` deleted (2026-05-25)
- Scratch file `.local-notes/_inbox-test` (untracked) deleted after
  content-diff vs this inbox. All actionable items either DUP of current
  `_inbox.md` sections, shipped/superseded (per-user memory, agent.py
  context fix, CLAUDE.md staleness, Vera approval gate, etc.), or migrated
  (item 0z → §6 above). "Unified AI-type / Unified android character"
  WAITING items confirmed done + gone. Test pollution (`test hx.`) noise.

---

## WAITING ON / EXTERNAL

- _(none)_
