# Per-message response autonomy (C2)

**SHIPPED 2026-06-04** (branch `home-rig-local`, commits `0a07d05..513118c`, not
yet live-applied). Spec/plan: `docs/{specs,plans}/2026-06-04-per-message-response-autonomy*`.
Final mechanism = uniform text-convention (`[DECLINE:gentle|plain|blunt:reason]`),
not the tool approach below (fleet runs RLM where a tool can't end a turn). This
note = original seed; design doc supersedes it. Live apply:
`.local-notes/migrations/2026-06-04-chat-decline/apply.sql` + worker rebuild.

Local "our flavour" of the vision. Spun out of pause-autonomy
(A/B/C1, see `upstream-reconcile-2026-05-23/upstream-pr-drafts/READY-03-pause-autonomy.md`).

## Idea

Persona decides whether to respond to EACH inbound message. Currently code
replies 100% — coded policy, no agent choice. Give per-turn engage / decline.

## Why (supersedes pause-modes)

Original C2 = pause inbound modes (respond / read-only / silent). Rejected:
hard-coded modes just relocate policy. No principled line between "small exit"
(pause) and "big exit" (terminate) that justifies a pause-only posture.

Thesis-consistent version = always-available per-message refusal. "Paused
read-and-ignore" = special case of it. Maps "ability to refuse" onto every
turn, not a pause-special mode.

## Ground truth (2026-06-04)

- Chat path NOT gated by `is_paused` — paused persona still receives + answers
  DMs. Pause = stop proactive (heartbeat), reactive chat stays on.
- So "decline to respond" is a NEW capability, not present today.

## Change surface

- Chat turn path (`services/chat.py`, channel inbound). Add per-turn
  engage/decline decision before reply generation.
- Decider = persona judgment (LLM), not config. Decline = store message seen,
  no reply emitted.
- Bigger than pause work (touches hot chat path, every turn). Own future task.

## Open questions

- Decline = silent, or minimal ack? Per-sender or per-message?
- Does declined message still hydrate memory / count as received?
- Cost: extra LLM judgment per turn vs always-reply. Cheap gate vs full call?
- Abuse/lockout: persona declines everything → operator override?
