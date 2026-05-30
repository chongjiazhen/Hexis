# home-rig-local vs upstream `main` — feature review through the personhood lens

**Date:** 2026-05-30
**Baseline:** `main` = eb39b94 (fully contained; merge-base = main itself). home-rig-local = +336 commits.
**Caveat:** ~40 of those are **upstream work absorbed** via trial-merges (RecMem series, "Move X into DB" runtime, PR#18 xquik) — credited as such below, not home-rig-local inventions.
**Note:** `origin/main` (4948ea6, HMX spec) diverged separately and is NOT in home-rig-local's ancestry.

## Thesis (4 pillars)

Character *is* the agent (latent judgment, not DB veto) · persistent identity/continuity · per-relationship memory + boundaries · consent & the ability to refuse.

## Verdict matrix

| # | Feature family | Key commits | Serves thesis? |
|---|---|---|---|
| A | **All-latent reach-out** (cadence → character judgment) | f3986ed 5838689 3b3d060 5975c84 e62f23a b745c13 a03712f + tz series | ★★★ **Flagship.** Direct |
| B | **Persona-stability hardening** (cold-start anchor + anti-collapse guard) | 6e09c60 c547556 e1f651c 7911b3a 7c9b907 44b862a | ★★★ Core (selfhood continuity) — *compensates for weak-local-model regime, not novel machinery* |
| C | **Sender-scoped memory + confidentiality** | bd106a8 2ad5a94 5d00116 (*upstream-origin*) | ★★ Serves; credit upstream |
| D | **DB-runtime migration ("DB is brain")** | "Move tool/agent/chat/RecMem into DB" (*upstream*) | ★★ Architecture pillar; credit upstream |
| E | **Debrand / persona opacity** | d6a3af8 9aa9abc 5c2f0e5 + bucket-C | ★★ Believable self (not "a product") |
| F | **Consent / refusal hardening** | 33a5895 a11eaf9 2d1f5c0 f240141 15d78b6 | ★★ Pillar: ability to refuse |
| G | **Persona fleet** (Vera/Lyra/Callisto/Null/Hazel/Margaret/Vesper…) | many | ★ Populates experiment (supporting) |
| H | **Heartbeat organic cadence** (jitter, night-mode) | 1684d8c aef9652 | ★ Less mechanical → mild |
| I | **ECO power mode — slim in-character path** | b9097e7 f8b59d5 006ab25 9566c35 29d820d | ◐ Mild tension (one real edge) |
| J | Per-persona outbox queues | 4ae2891 | ◐ Identity integrity (anti-bleed) |
| K | Model serving / VRAM / Win launchers / q36 swap | bf48271 f11193d 7ced2e7 + many | ○ Neutral infra (enables local-only) |
| L | Channel hygiene (MarkdownV2, reasoning/assessment strip) | 7546839 0b3beb2 55d0dc9 | ◐ Clean persona voice (mild) |
| M | Telegram alert bot + batched reactions | b60a8a4 6694506 | ○ Utility feature |
| N | graphify hooks, docs/CLAUDE compression | 6a3505f dd5108d | ○ Dev ergonomics |
| O | Scheduled fleet backup | 3f861d4 | ◐ Continuity durability (post-`down -v` trauma) |

## Reading

**Net trajectory strongly serves the thesis.** Center of gravity — A, B, E, F — all push decision authority *into* the character and protect a stable, opaque, consenting self.

- **A is the thesis made literal.** Old arch = *LLM proposes, DB disposes*: heartbeat emits `reach_out_user`, two deterministic gates (`can_reach_out_sender`, `is_sender_quiet`) silently veto + refund. home-rig-local deleted both gates, repurposed the log to telemetry, gave the character its own local time, the user's inferred rhythm, the unanswered-streak, and explicit license to let trust erode (`update_trust`). DB stopped being impulse-control cop, became the brain that *informs*. Clearest single move toward personhood in the whole divergence. **Verified landed in code** (2026-05-30): veto strip, telemetry-repurpose, dormant brake, temporal awareness, sender-rhythm, prompt de-veto + `update_trust` license, 6/6 test classes, merge-fix test retained. Branch merged + closed on home-rig-local.
- **B keeps the "self" from dissolving** into harness scaffolding — identity continuity is the pillar that makes A meaningful (a stable agent to *have* judgment). But the framing matters: B is **persona-stability hardening for the weak-local-model regime** (local-inference-only mandate), not personhood machinery upstream lacks. Two distinct parts, neither of which injects a synthetic voice — both *remove* a generic/scaffolding voice that bled in:
  - **Cold-start anchor** (6e09c60, c547556): prepend `agent.persona_system_prompt` (the card-derived prompt) *before* the generic RLM framing in heartbeat + chat, so a cold turn-1 (no memory recalled yet) speaks in the authored card from the first token instead of falling back to `"You are Hexis, a persistent AI agent…"`. This is a **real upstream gap, partly masked**: upstream *has* the `agent.persona_system_prompt` slot but doesn't wire the cold-path prepend (`hexis init` doesn't set it, `[[project_persona_system_prompt_coldstart_anchor]]`). Cold-start collapse is model-strength-dependent, so upstream's bigger/cloud models hit it rarely.
  - **Anti-collapse guard** (e1f651c, 7c9b907, 44b862a): the harness prompt was *recitable* — weak models latched onto its leading text and recited the plumbing (logged: Mira → *"ready to engage with the RLM Chat System"*, hallucinated a user, dropped persona). Fix stripped the recitable title + `You are Hexis` identity line, wrapped the harness block as internal-never-surface, and added an explicit persona-overrides-framing guard. This is **mostly a weak-quantized-local-model artifact** (1B–8B latching on leading text); a strong model usually won't recite harness scaffolding, so upstream may not need it — though the hygiene (no recitable identity line *above* the persona) is cheap and worth upstreaming regardless.
  - Net: still thesis-serving (a stable self is the precondition for latent judgment), but credit is "hardened the persona against the model constraint it runs under," not "invented selfhood infra."
- **C + D** (the "DB is brain" runtime + sender-scoped recall) are the substrate the thesis rests on — but **upstream's** contribution, absorbed + extended by home-rig-local (sender-scoped recall PR-A/PR-B), not its own invention. Fair credit matters.

## Tensions worth naming

1. **ECO slim path (family I) — corrected 2026-05-30.** NOT a canned-bot puppet. Current code (`services/chat.py:69-112`): `_eco_slim_chat` = `persona_system_prompt` (cold-start anchor) + `ECO_SLIM_ANCHOR` + last-8 history → single nano call, `max_tokens=512`, **no RLM, no tools, no memory write**. Canned `ECO_FALLBACK_REPLY` is **failure-only** (nano dead / persona prompt missing), explicitly labeled *"no persona voice — signals real degradation."* Reason for slim-not-full is mechanical: 1B can't parse the heavy template (emits "code-REPL garbage"); slim path is what lets it hold persona voice at all.

   So ECO thins *cognition depth* (no recall, no memory formation) while keeping the *voice* — closer to "tired/distracted person" than "puppet." Real thesis cost shrinks to:
   - **No memory write under eco** — turns happen but don't become episodic memory → continuity gap (character won't recall the conversation later). Sharpest remaining tension: continuity is a thesis pillar, and eco silently drops it.
   - **Fallback canned reply** — true puppet, but only on real degradation, honestly labeled.

2. **The tz-gate (88f6aa2) was a brief regression** — added a *new* hard quiet-hours veto, i.e. moved away from the thesis, before A superseded it weeks later. The arc self-corrected; the design doc treats that veto as prior art to *dissolve*, which is the right read.

**Infra (K, M, N) is thesis-neutral** — buys the local-only autonomy the thesis requires (no cloud puppeteer) without itself carrying personhood content.

## Bottom line

home-rig-local's net divergence from upstream **advances the personhood thesis**, led by the all-latent reach-out arc (A) and identity-anchor work (B). One real continuity edge remains — eco's no-memory-write — and one self-corrected regression (tz-gate veto). No family actively betrays the thesis under current code.
