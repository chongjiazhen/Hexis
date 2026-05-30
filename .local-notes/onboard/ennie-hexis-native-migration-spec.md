# SPEC (hexis worker): migrate eni/Ennie OpenClaw-body → hexis-NATIVE

> Greenlit 2026-05-18. Architecture history + why: auto-memory
> `openclaw-hexis-architecture`. Companion docs (same dir):
> `openclaw-hexis-onboard.prompt.md`, `recall-ctx-cap-spec.md`.

## Why (settled, measured — not re-litigate)

OpenClaw body on q36/16GB = degraded: every continuation turn
`reason=threshold` auto-compaction (~15–25s), continuity shredded, robotic
SOUL re-intro / occasional "I'm a language model" collapse. ~11K immovable
OpenClaw core scaffold + history > ~20K usable. Lever-1
(`contextInjection:"continuation-skip"`) applied + MEASURED-FAILED (continuation
turns 12:27/12:30 still threshold). Config space exhausted, earned by
measurement. hexis-native owns prompt assembly with a hard
`rlm.workspace.max_loaded_chars` budget → the 14,867 external-scaffold tax
does not exist there by design. Same q36, same box.

## Goal

eni/Ennie answers on Telegram (@enigmatic_writer_bot) via hexis-native
runtime, no OpenClaw. Persistent continuity preserved (the entire point).
mira UNTOUCHED throughout (separate agent, shared brain DB + box).

## Step 0 — VERIFY before building (do not assume; session burned 5× on assumed premises)

- Confirm hexis-native **conscious/chat path** is production-usable for eni,
  not just heartbeat. `hexis_ennie_*` heartbeat/maintenance workers already run;
  verify the conversation loop (`services/`/`core/agent_loop.py` /
  `apps/hexis_api.py` SSE / `channels/`) actually serves an eni chat turn
  end-to-end against `hexis_ennie` DB.
- Confirm DB config already correct: `llm.chat` = q36 @
  host.docker.internal:8080/v1 (verified 2026-05-18 — likely no change).
- Confirm `characters/ennie.json` (chara_card_v2 + extensions.hexis) is the
  intended persona source and `hexis_ennie` identity rows match the Ennie voice
  (the OpenClaw `SOUL.md` was hand-tuned; native persona derives from card +
  brain — verify voice parity, don't assume identical).

## Components

1. Persona: `characters/ennie.json` + `hexis_ennie` identity/worldview rows
   (brain already live — OpenClaw used it via MCP; native uses
   `core/cognitive_memory_api` directly).
2. LLM: DB `llm.chat` (q36, unchanged).
3. Telegram: `channels/telegram_adapter.py` via hexis `channel_worker`,
   **reusing the existing @enigmatic_writer_bot token**.
4. Autonomy: native HeartbeatWorker / `agent_loop.py` (already running for
   eni — no OpenClaw heartbeat needed).

## Hard sequencing (avoid downtime + token contention)

Telegram bot token = single-holder. OpenClaw eni currently polls it. Two
pollers on one token = `getUpdates` conflict. Therefore:

1. Build + validate hexis-native eni on a **non-conflicting** path first
   (test chat via `hexis_api`/CLI, or a throwaway test bot token) — do NOT
   touch @enigmatic_writer_bot yet.
2. Validation gate (below) PASSES.
3. **Cutover (brief, atomic-ish):** stop OpenClaw eni polling (OpenClaw side —
   handled separately: remove eni agent/account/binding from openclaw.json,
   keep mira; this is the OpenClaw-owner's step, gated on this point) → start
   hexis `channel_worker` telegram adapter bound to eni with that token.
4. Freeze, do not destroy, OpenClaw eni config (archived for rollback).

## Validation gate (measurement, no pre-claim — same discipline)

Native eni, multi-turn Telegram (or test channel) conversation:
- Loaded context stays within `rlm.workspace.max_loaded_chars` (inspect
  actual loaded chars/turn — prove the budget binds, not just assumed).
- NO threshold-compaction-equivalent overrun; no ~15–25s stall pattern.
- Persona intact across turns; **continuity holds turn-to-turn** (explicitly
  test: reference something from 2–3 turns back — this is the capability
  OpenClaw shredded; it is the pass criterion, not "replies").
- Recall fires (DB row / tool trace), identity correct, no lineage leak.
- mira unaffected (its proxy/DB/turns unchanged).
A reply that's in-voice but fails turn-to-turn continuity = FAIL.

## Risks

- Token contention → strict cutover, never parallel poll (sequencing above).
- hexis chat-path maturity unknown until Step 0 verified — if conversation
  loop isn't production-ready for eni, that's a build task, surface it early.
- Persona drift: card/brain-derived voice vs hand-tuned OpenClaw SOUL — verify
  parity; re-seed `hexis_ennie` identity rows if voice regresses (fix at brain,
  per onboard recipe Gotcha #8).
- Downtime window at cutover — minimize via validate-before-flip.
- Shared brain DB / box — mira isolation must hold; no schema/global change.

## OpenClaw-side (owner-handled, gated on validation PASS — NOT now)

Freeze eni: remove `agents.list[eni]` / `channels.telegram.accounts.eni` /
`bindings[eni]` from `C:\openclaw\data\openclaw.json`; keep mira; archive
config; `openclaw doctor`; gateway recreate. Sequenced strictly AFTER native
validation PASS to avoid an Ennie outage. Do not freeze pre-validation.
