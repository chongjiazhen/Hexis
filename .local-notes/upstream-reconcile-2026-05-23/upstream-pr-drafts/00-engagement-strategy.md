# Upstream Engagement Strategy

## Maintainer reality check

- Upstream `QuixiAI/Hexis` solo-maintained by **Eric Hartford** (`ehartford@gmail.com` + `eric@quixi.ai` + twitter `quixiai`). Bio: "I make AI models like Dolphin and Samantha." Uncensored fine-tune lineage.
- 579 ★, 71 forks, very active (today's RecMem drop).
- **Discussions DISABLED.** Issues + PRs only.
- 3 open Issues from Feb 2026 (incl. architecture proposal #17) — all stale, no maintainer reply.
- 1 community PR merged recently (`kriptoburak/xquik`, 3 days ago, drive-by fix).
- **Pattern:** maintainer ships own architecture aggressively; merges small drive-by PRs occasionally; ignores Issues and architecture proposals.

Implication: ship code, not Issues. Small + obviously-correct PRs more likely to land than big architecture pitches.

## Full sweep of 248 local commits

Categorized by upstream-fit:

### TIER A — ship-as-is, clean cherry-picks

Single-purpose, generic, no fleet/persona/local-infra context. These are the openers.

| Commit | Subject | Lines | Notes |
|---|---|---:|---|
| `0b3beb2` | fix(llm): strip leaked reasoning traces | ~64 | **PR-1 opener.** Adds `strip_reasoning()`. VERIFIED absent from `origin/main:core/llm.py`. **Scrub note:** comment references `.local-notes/hexis-native-onboard.prompt.md` — strip when cherry-picking. |
| `4ff607e` | feat(llm): strip leading markdown divider | ~47 | **PR-2 (follow-up).** Sibling to `strip_reasoning` — calls it in chat_completion path. Land 0b3beb2 first. |
| `036e840` | fix(channels): silence httpx INFO logs so telegram bot tokens don't leak | small | **Security fix.** Prevents credential leakage in logs. Easy yes. |
| `54253d9` | fix(db): coerce free-text goal priority to enum in reprioritize | small | Bug fix, generic. |
| `a95c654` | fix(init): use `#>>` for JSONB string extraction in card init | small | Bug fix, generic. |
| `48d8d99` | fix(init): `--endpoint` arg for noninteractive hexis init | small | Generic CLI feature. |
| `a13e7c8` | fix(init): warn when character card extensions are misplaced | small | UX, generic init code. |
| `b987e32` | fix(channels): keep queued telegram updates across worker restarts | medium | Bug fix, generic — anyone running Telegram channel would want this. |
| `3bf21cd` | fix(agent): chat hydrated context into system prompt | ~73 | Architectural cleanup, no schema. |

### TIER B — needs rework before PR

Generic-ish but coupled to local context; split fleet-specific parts out.

| Commit | Why rework needed |
|---|---|
| `4661566` fix(channels): per-persona session-history cap | Drop the Vera-specific assessment-trigger part. Port history cap to `db/34_functions_chat_channel.sql::finalize_channel_turn` config reads (upstream moved logic to SQL today). |
| `aef9652` feat(heartbeat): night-mode throttle + embed to CPU | Split: night-mode throttle is upstream-good; embed-to-CPU is local hardware-specific. Ship night-mode as separate PR. |
| `1684d8c` feat(heartbeat): per-cycle jitter | Useful for anyone running multiple Hexis instances on shared inference backend. Strip fleet-context from message; PR. |
| `0a87f4c` feat(telegram): per-channel `ambient_reply_chance` | Generic Telegram feature. PR-shape needs verification it doesn't depend on local channel adapter shape. |
| `541d78d` feat(chat): wire agent tools into RLM chat + SearXNG | Useful. Need to verify upstream's tool wiring after their DB-runtime migration today doesn't make this redundant. |
| `e1f651c` fix(prompt): stop persona collapse into harness scaffolding | If touches `services/prompts/rlm_*.md`, upstream-portable. If persona-coupled, skip. |
| `7911b3a` fix(prompt): port e1f651c to heartbeat prompt | Companion to e1f651c. |
| `6c530ec` fix(prompt): keep RLM chat replies on-topic | Check if generic prompt file. |
| `d5a20cf` fix(db): bump max_connections 100→300 | Config tweak; too high for solo users. Re-pitch as "configurable cap, raise default to 150." |
| `944b23a` fix(db): bake home-rig schema patches survive hexis reset | **SPLIT.** Part 1 (db/07: `name` field on `get_agent_profile_context`) = Tier A — hand-craft as single-file PR. Part 2 (db/99_local_overrides.sql + start.ps1) = **Tier D, never** (file literally says "do not merge to main"). |

### TIER C — big feature pitches (lots of work, gated on goodwill)

Bundle multiple commits into one feature PR. Only ship after Tier A success.

| Bundle | Commits | Risk |
|---|---|---|
| **Sender-scoped recall** | `ec9e1ec` (schema) + `bd106a8` (logic) + my PR-A + my PR-B | Big. The completion-of-`subconscious_units.source_identity` pitch. See `04-pr-sender-scoped-recmem-recall.md` + `05-pr-sender-propagation-derived.md`. |
| **RecMem compaction sender fix** | New code (PR-C) | Small bug fix on something Eric just shipped today. See `06-pr-compaction-sender-preservation.md`. |

### TIER D — never to upstream

Persona content + fleet ops + local infra. ABSOLUTE drop list:

| Pattern | Commits |
|---|---|
| `*(characters)` | All — adult-audience persona content |
| `*(personas)` `*(persona)` | All — fleet topology |
| `*(compose)` | All — local Docker fleet config |
| `*(alerts)` | All — local alert webhook system |
| `*(eco)` | All — local VRAM-constrained operational mode |
| `*(ops)` `*(scripts)` `*(start)` `*(nano)` `*(vram-guard)` `*(power)` | All — Windows host-rig ops |
| `*(probe)` | All — local model evaluation harness |
| `*(plan)` `*(slop-scan)` `*(inbox)` `*(notes)` `*(local)` | All — working documents |
| `*(claude)` `docs(claude)` | All — CLAUDE.md (per-repo agent instructions) |
| Persona-specific in generic scope (Vera/Esme/Eudora named) | `d9f037a` `55d0dc9` `66123ee` `a7427b6` `54651e7` `5b9a0c0` |
| `*(prompt)` if persona-coupled | Verify each, default skip |
| Local-llm-tuning | `e02cb49` (frequency_penalty), `2a99e60` (llama.cpp patches), `d7d2744` (BigModels), `8f99bbe` (launcher) |

## Recommended cadence

1. **Fork** `QuixiAI/Hexis` under `chongjiazhen`. Reversible via repo delete.
2. **PR-1** = `0b3beb2` strip_reasoning. Solo opener. ~64 lines, pure Python, no schema, model-agnostic. Pre-req for PR-2.
3. Wait **1-2 weeks** for any signal — review activity, label, comment, merge.
4. **If PR-1 lands:** ship **PR-2 = `4ff607e`** strip_leading_divider — sibling to PR-1, ~47 lines, completes the LLM-output-sanitation pair.
5. **If PR-2 lands:** ship **PR-3 = `036e840`** httpx token-leak fix. Different file, different topic, third-test of maintainer engagement.
6. **If PR-3 lands:** ship Tier A backlog one-at-a-time, ~1/week, in size order.
7. **After 3+ landed PRs:** Tier C bundles (sender-scoped recall, etc).
8. **If PR-1 stale 3+ weeks:** stop. Eric not engaging community contribs. Keep everything local, re-evaluate after his next big drop.

## Tone for PR descriptions

Match maintainer's voice (terse, technically direct, no marketing). Examples below.

DON'T:
- "This PR adds the ability to..." (passive corporate)
- Flattery ("amazing work on the RecMem stack!")
- Emojis
- Long "motivation" sections rehashing the README

DO:
- Lead with the observed bug or behavior
- One paragraph technical justification
- "Tested by: ran X against Y, confirmed Z" — show you actually ran it
- Sign off with what's NOT in the PR (scope clarity)

## NEVER push checklist

- `characters/*.json` `characters/set_persona_prompt.*.sql` `characters/SLOP-SCAN.md`
- `docker-compose.newchars.yml` (fleet topology, persona names → DM accounts)
- `.local-notes/**`
- `power-profiles.psd1` `start-all.ps1` `hexis-status.ps1` `hexis-launcher.ps1`
- `CLAUDE.md` (per-box agent instructions)
- Any `_eco_*` or `ECO_*` symbols, `agent.power_mode` config
- Any commit subject containing: `characters`, `personas`, `vera`, `esme`, `eudora`, `monika`, `sable`, `trump`, `null`, `hazel`, `denali`, `cassiel`, `death`, `vesper`, `callisto`, `ennie`, `ao`, `mira`, `baymax`, `charlotte`, `lovesick`, `joje`, `nines`, `tars`, `rocky`, `warden`, `ichika`

The fork-branch-per-PR pattern enforces this naturally: only what's explicitly cherry-picked goes out.

## Draft body files

- `01-pr-agent-tools-seed.md` — **demoted** (ec9e1ec carries sender_id pollution; agent.tools fleet-driven, skip for upstream)
- `02-pr-chat-context-system-prompt.md` — keep, becomes PR-3 or later
- `03-pr-history-cap.md` — keep, Tier B (needs re-port)
- `04-pr-sender-scoped-recmem-recall.md` — keep, Tier C bundle
- `05-pr-sender-propagation-derived.md` — keep, Tier C bundle
- `06-pr-compaction-sender-preservation.md` — keep, can ship anytime

**To write:**
- `01-pr-strip-reasoning.md` (PR-1 = `0b3beb2`) ← writing now
- `01b-pr-strip-leading-divider.md` (PR-2 = `4ff607e`)
- `07-pr-httpx-token-leak-silence.md` (PR-3 = `036e840`)
- `08-pr-agent-profile-name-field.md` (Tier A, hand-crafted from 944b23a part 1)
- `09-pr-telegram-updates-survive-restart.md` (Tier A, `b987e32`)
- `10-pr-heartbeat-jitter.md` (Tier B, re-pitched from `1684d8c`)
- Etc as Tier A rolls out.
