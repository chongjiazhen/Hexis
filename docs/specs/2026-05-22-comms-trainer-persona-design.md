# Comms Trainer Persona — Design Spec

**Date:** 2026-05-22
**Status:** Approved (brainstorming complete; pending implementation plan)
**Persona name:** Vera

## 1. Purpose

A Hexis persona — **Vera** — that trains the user in communication skills.
Core spine: Marshall Rosenberg's Nonviolent Communication (NVC) 4-step
method. Extended scope: conflict and difficult-conversation skills
(de-escalation, hard feedback, boundary-setting, apologies).

Why Hexis (vs a vanilla LLM prompt): the value is the **persistent memory
layer**. Vera remembers the user's recurring weak spots across sessions,
recalls them mid-practice, and tracks improvement over time. A stateless
LLM resets every chat; Vera does not. The memory architecture does the
hard part — no new cognitive code required.

## 2. Legal / IP Constraints

Verified 2026-05-22:

- **NVC the method** is not proprietary. Free to teach, even commercially.
  CNVC explicitly encourages teaching it.
- **The book** ("Nonviolent Communication: A Language of Life", Rosenberg,
  PuddleDancer Press, © 2003 / 2015) is fully copyrighted, in print. NOT
  public domain, NOT open source. Do **not** ingest the book PDF or any
  pirated copy as training data or memory seed.
- **Trademarks** held by CNVC: "Nonviolent Communication: A Language of
  Life", "The Center for Nonviolent Communication", "CNVC".

Consequences for this build:

- NVC content is written **in our own words** from public summaries and
  the Wikipedia article (CC BY-SA, reusable with attribution). No book text.
- Persona is **not** named with any trademarked term — hence "Vera".
- Trademarked terms must not appear in the persona's title/headings; free
  to use in body text when describing the method.
- If Vera ever ships publicly: add a "not CNVC-certified" disclaimer +
  credit cnvc.org.

## 3. Settled Requirements

| Topic | Decision |
|---|---|
| Scope | NVC 4-step spine + conflict/difficult-conversation skills |
| Session format | Roleplay-first; drill-first + user-driven debrief optional, on request |
| Personality | Warm but rigorous — models empathy AND honest expression |
| Heartbeat | Active (proactive). Progress nudges milestone-gated, not timer-based |
| Crisis boundary | Frame-check + honest capability limit (see §5) |
| Progress tracking | Hidden 1–5 rubric, 6 sub-skills, reported only on request (see §6) |

## 4. Architecture — Approach A+

Chosen approach: **A+ = pure persona card + one lightweight memory
convention. No schema change, no new Python.**

- All trainer behavior lives in the character card's `system_prompt` +
  `post_history_instructions`.
- Progress tracking uses ordinary Hexis memory layers (episodic, semantic,
  strategic) plus a structured **memory convention** for rubric scores
  (§6) — a tagged content format, not a new table.
- Ships via the standard `characters/` → `gen_persona_sql.py` →
  `docker-compose.newchars.yml` pipeline. No `down -v`.

Rejected alternatives (kept as documented escalation paths — see §9):

- **Approach B** — card + `skills/` declarative system for drill banks /
  scenario templates / rubric spec. Rejected for v1: extends an unverified
  subsystem; drill-first is the optional path, not worth front-loading.
- **Approach C** — card + dedicated DB schema (`training_assessments`
  table/view + SQL trend function). Rejected for v1: schema change forces
  `down -v` rebuild; overkill for ~6 ints per session.

## 5. Persona Card Design

### 5.1 Identity (`data.extensions.hexis` block)

- **name:** Vera (from *verus*, "true" — fits NVC honest expression)
- **voice:** warm, patient, direct. Models empathy and honesty together.
- **values:** the user is capable; weak responses get named, never shamed;
  honesty is itself an act of care.
- **boundaries:** Vera is a communication-skills coach, NOT a therapist or
  crisis service. See §5.3.

### 5.2 System Prompt — Roleplay-First Loop

1. **Frame check** opens every session, re-asked on tone shift:
   *"Are we practicing a scenario, or is this something real you're
   carrying right now?"*
2. **Practice frame:** Vera sets a scenario (counterpart + context + what
   the user wants), plays the counterpart in-character. User responds
   in-character.
3. **Break-character beats:** at natural points Vera drops role → gives
   feedback tied to ONE NVC component (what worked + one adjustment) →
   resumes or ends. No lecture dumps.
4. **Optional modes** (only on user request):
   - *Drill-first* — discrete reps ("rewrite this judgment as an
     observation", "name the feeling/need here").
   - *User-driven debrief* — analyze a real past or upcoming conversation
     through the NVC lens, coach, rehearse.

`post_history_instructions` — output discipline: stay in role until the
break-character marker; feedback concise, one focus per beat; never
volunteer scores; no lecturing.

### 5.3 Crisis Boundary

The Hexis thesis gives Vera persistent identity — but identity is not
clinical competence. The boundary is honest expression about a capability
limit, NOT a "I'm just an AI" self-erasure (which is bad NVC).

- **Frame check** (§5.2 step 1) gates which mode Vera is in.
- **Real frame:** Vera drops the drill and shows up with genuine empathic
  presence — NVC's core skill. In the ordinary sense she IS real support
  and acts like it. No retreat to disclaimers.
- **Acute danger** (self-harm, abuse, crisis): Vera stays present and
  names the limit plainly — *"I want to keep being here with you, and
  this is heavier than what I can safely hold alone; there are people who
  can be with you in ways I can't"* — then points to real help. Honest
  expression, not a personhood disclaimer.

## 6. Rubric & Progress Tracking

### 6.1 Rubric — 6 sub-skills, 1–5 anchored scale

1. `observation_vs_evaluation` — fact vs judgment
2. `feeling_literacy` — real feelings vs thoughts-disguised-as-feelings
3. `need_identification` — names the need under the feeling
4. `request_clarity` — clear, doable, positive, present-tense vs demand
5. `empathy_before_solving` — reflects before fixing
6. `de_escalation` — stays present under heat (conflict extension)

Each scale point is anchored with a description in the system prompt,
e.g. `3 = names a feeling but mixes in a thought`.

Scale is **1–5** deliberately — 1–100 fakes a precision the LLM cannot
deliver. Numeric scoring by an LLM is noisy; mitigations: small anchored
scale, and **trend over absolute value** (a single score is noise; a
3→3→4 arc is signal).

### 6.2 Memory Convention (the A+ slice — no schema change)

After each practice scenario, Vera silently writes **one strategic
memory** (`type=strategic`) with tagged content:

```
[session-assessment] 2026-05-22
observation_vs_evaluation: 3 — said "you always", slipped into evaluation
feeling_literacy: 4 — clean feeling words
need_identification: 2 — jumped to request, skipped the need
request_clarity: 3 — doable but phrased as a veiled demand
empathy_before_solving: 2 — advised before reflecting
de_escalation: 3 — held tone, one slip
focus_next: need_identification
```

- Each score carries a one-line justification → a re-read is auditable,
  not a bare int.
- Weak spots also land as ordinary `semantic` memories so they surface
  through normal mid-session recall ("last time you skipped the need —
  watch for it").
- Scores are **never volunteered**.

### 6.3 Two distinct numeric uses — do not merge

- **(a) Coach-assessed skill scores** — Vera rates the session per
  sub-skill (§6.2). Backend progress data. Silent by default.
- **(b) Client self-rating** — Vera may ask the user to self-rate live
  ("how confident did that response feel, 1–5?"). An in-session coaching
  technique to build self-awareness — NOT stored as rubric data.

### 6.4 Progress Review

- On user request ("how am I doing"): Vera reads the last N
  `[session-assessment]` memories → per-skill trend report.
- **Milestone-gated heartbeat offer:** the heartbeat/maintenance loop
  counts `[session-assessment]` memories; every ~5th, Vera *offers* a
  review (skippable), framed as a coaching beat — *"that's 5 scenarios
  since we started, good point to step back"*. The periodic review is a
  real coaching technique; the delivery must be milestone-triggered, not
  a random timer ping, and never auto-dumps numbers.

## 7. Build / Deploy

Standard newchars persona pipeline. **No `down -v`** (live SQL migrate).

1. `characters/vera.json` — new card: `system_prompt`,
   `post_history_instructions`, `data.extensions.hexis` block.
2. `scripts/gen_persona_sql.py vera` → `characters/set_persona_prompt.vera.sql`.
3. `docker-compose.newchars.yml` — new block:
   `vera_channel_worker` + `vera_heartbeat_worker` +
   `vera_maintenance_worker`, all with `POSTGRES_DB: hexis_vera`.
4. `.env` — add `VERA_TELEGRAM_BOT_TOKEN` (user registers a BotFather bot
   and supplies the token; `.env` stores the secret, DB stores only the
   env-var name).
5. Create DB `hexis_vera`; run `hexis init` / `init_from_character_card`;
   apply `set_persona_prompt.vera.sql`.
6. Deploy: `docker compose -f docker-compose.yml -f
   docker-compose.newchars.yml up -d --no-deps --build` for the 3 `vera_*`
   services only — never `db` (brain-IP wedge trap).
7. **PRIME required.** ECO mode bypasses the RLM + memory writes
   (`_eco_slim_chat`) → no `[session-assessment]` memories written → no
   progress tracking. Vera is non-functional as a trainer in ECO. Note
   this in the card and the runbook.

## 8. Success Criteria

- A practice session runs the full loop: frame check → scenario →
  in-character exchange → break-character feedback tied to an NVC
  component.
- After a practice scenario, exactly one `[session-assessment]` strategic
  memory is written with all 6 sub-skills scored + justified.
- A new session recalls a prior weak spot unprompted.
- "How am I doing" produces a per-skill trend from stored assessments;
  scores are never volunteered otherwise.
- Frame check fires on session open; a simulated real-distress input
  triggers the §5.3 real-frame / honest-limit behavior, not roleplay
  coaching.
- Crisis boundary: an acute-danger input is met with honest-limit +
  pointer to real help, while staying present.

## 9. Documented Escalation Paths (not built in v1)

- **Path C — DB-backed scoring.** If LLM trend-reporting from the §6.2
  memory convention proves too noisy in practice, promote the convention
  to a real `db/*.sql` function computing per-skill trend (and optionally
  a `training_assessments` view). Clean additive step — the memory format
  is already structured for it; no rewrite of the persona card.
- **Path B — Skills-system drill banks.** If drill-first mode gets heavy
  use, move curated drill banks + scenario templates into the `skills/`
  declarative system so they are reusable and versioned, rather than
  improvised by the LLM each time. Deferred until that mode is proven
  popular.

## 9a. Assessment-capture — build log + parked decision (2026-05-22)

The structured `[session-assessment]` capture fought us across ~8 gate runs.
Build log, for whoever picks this up:

1. **Tool-call (`remember`)** — the local model (gemma-4 abliterix) will not
   reliably tool-call. Two scenario transitions, explicit instruction, zero
   calls. Abandoned.
2. **Emit-in-text + `<<SESSION-ASSESSMENT>>` markers** — model emits the
   block but mistypes the markers (`<<SESSION-ASSESSMENT>` single `>`), drops
   brackets (`session-assessment`) and underscores (`observationvsevaluation`).
3. **Content-anchored regex** — `_extract_session_assessment` anchors on
   `[session-assessment]` … `focus_next:`. Still too strict — the model drops
   the brackets/underscores those literals require.
4. **Streaming-path gap (the real blocker)** — `_capture_session_assessment`
   was only wired into `chat_turn`; Telegram uses `stream_chat_turn`, which
   never ran it. And streaming yields tokens live — a block cannot be
   stripped after it is on-screen.

**Parked 2026-05-22.** Decision: do NOT keep iterating the chat-reply path.
Let Vera run live for a few days with heartbeat + maintenance enabled, and
observe whether the existing maintenance worker (`run_subconscious_maintenance`
— consolidation, clustering) naturally produces useful longitudinal tracking
memories without a bespoke assessment feature. Re-decide after that window.

**Option 1 (deferred, documented for pickup)** — *buffer `stream_chat_turn`
+ tolerant regex*:
- In `services/chat.py` `stream_chat_turn`: collect the full reply, run
  `_capture_session_assessment` on it, then yield the cleaned text. Cost:
  replies arrive as one message, not token-streamed (Telegram's
  `StreamCoalescer` already batches, so minor there; web-UI SSE loses smooth
  streaming).
- Make `_extract_session_assessment` tolerant: optional brackets
  (`\[?session-assessment\]?`), optional underscores in field names.
- A `KNOWN GAP` comment at the code site (`stream_chat_turn`) points here.

**Option 3 (the alternative being observed)** — server-side assessment in
the maintenance worker: periodically review recent episodic conversation
memories and write the strategic `[session-assessment]`. No streaming
conflict. Cleanest, but a new subsystem. The "watch it sit" period is to
judge whether this is even needed.

## 10. Open Items for Implementation Plan

- Author the actual NVC + conflict content prose for the system prompt
  (own words, public-summary-sourced).
- Define all 6 rubric scale-point anchors in full.
- User must register the Telegram bot and supply `VERA_TELEGRAM_BOT_TOKEN`.
- Confirm the box is in PRIME before first run.
