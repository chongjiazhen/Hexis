# Pivot stack eval — Hexis vs Hermes / OpenPersona / OpenHuman / Mem0 / Zep / Letta

**Date:** 2026-05-25
**Scope:** market-reaction refresh + Tier-2 memory-system deep-dive + pivot-stack decision.
**Companion:** `research-persona-memory-systems.md` (2026-05-21 baseline), `strategy-local-llm-positioning.md`.
**Why:** test the "monetize Hexis" thesis against current market data; evaluate hobby-mode pivot to a Hermes + OpenPersona + memory-backend stack while cribbing Hexis ops/infra lessons.

---

## TL;DR

- 2026-05-21 note's §Threat-read scenario is **already shipped**, not future. OpenPersona Faculty already wires Mem0/Zep w/ memory supersession + Soul-Memory Bridge (eventLog → evolvedTraits).
- Market data (May 2026) reorders the field. Hermes 140K stars / 224B daily OpenRouter tokens. OpenHuman **27.2K stars in ~9 days** (35× growth from May-16 snapshot of 776). Hexis upstream 521 stars.
- SKILL.md became cross-tool portable standard March 2026 (Claude Code / Hermes / OpenClaw / Codex / Google / JetBrains / AWS / Mistral). OpenPersona's persona-as-SKILL.md bet is now the dominant artifact format.
- Mem0 won the personalization memory layer (1,764 tok/conv); Zep won temporal/relational (~600K tok/conv, 340× cost spread); Letta = OS-style memory blocks; MemMachine = ground-truth-preserving, 80% fewer tokens than Mem0 (newer, single-org risk).
- **Pivot stack is real and runnable** but carries composition tax (4-way upstream version matrix).
- **Hobby framing is correct.** Monetization unwinnable: OpenPersona has distribution + portability, Hermes won agent layer, Mem0/Zep won memory layer. Hexis sits between two won markets.
- Hexis's truly-unique surface = 5 claims, three technical + two framing. The **framing** (Aristotle's *hexis*, refusal-as-authority) is the most uncopyable bit. **Essay is the artifact, code is the demo.**

---

## 1. Market data refresh (2026-05-25)

### Star counts / mindshare

| Project | Signal | Read |
|---|---|---|
| Hermes Agent (Nous) | 140K stars <3 mo, #1 OpenRouter, 224B daily tokens (vs OpenClaw 186B) | Won the agent layer. |
| OpenHuman | **27.2K stars** (up from 776 nine days prior) | Breakout. Same niche as Hexis Companion-SKU. |
| QuixiAI/Hexis (upstream) | 521 stars | Research repo. No market presence. |
| OpenPersona | No trending signal; ecosystem play (HF integration, ClawHub directory, install-count tracking) | Building distribution. |
| PersonAi | No traction signal | Hobby/portfolio repo. |
| Mem0 / Zep | Dominant memory-layer mindshare | Won the memory layer. |
| Letta (MemGPT) | UC-Berkeley lineage, Letta Code March 2026 | Platform/SDK posture. |

### Key 2026 shifts

1. **SKILL.md cross-tool standard (March 2026).** Skill written for Claude Code = portable to Hermes/OpenClaw/Codex. OpenPersona's persona-as-SKILL.md = dominant artifact format.
2. **Hermes shipped self-improving skills.** Reflection step after 5+ tool calls → reusable `SKILL.md`. Agents w/ 20+ self-skills complete future tasks 40% faster.
3. **Memory layer market is decided.** Mem0 / Zep / Letta / MemMachine. Hexis invisible in every roundup found.
4. **OpenHuman framing — "reads you first."** Day-1 context from 118 OAuth connectors. Marketing win Hexis cold-start-anchor work could have claimed but didn't pitch.

### Threat-read recalibration

Old (2026-05-21): OpenPersona > Hermes > OpenHuman > PersonAi.
**New (2026-05-25):** OpenHuman ≥ Hermes ≥ OpenPersona > Hexis-shaped niche.

OpenHuman gap to becoming Hexis-territory = persona/selfhood + autonomous goals. W/ 27.2K stars + rapid iteration, 1-2 release cycles, not a moat.

---

## 2. Tier-2 memory systems (deep-dive)

| System | Self-host shape | Token cost | Best for | License |
|---|---|---|---|---|
| **Mem0** | library or server; FastEmbed local emb; PGVector/Qdrant/Chroma/Milvus/Redis/etc | **1,764 tok/conv** (cheap) | personalization, drop-in | Apache 2.0 |
| **Zep / Graphiti** | Graphiti only (Apache); Zep CE killed Apr 2025; needs Neo4j/FalkorDB/Kuzu | **~600K tok/conv** (heavy) | temporal/relational reasoning | Apache 2.0 |
| **Cognee** | graph+vector+relational hybrid; multimodal ingest | n/a | reason-over-corpus (PDFs/Slack/Notion) | Apache 2.0 |
| **Letta (MemGPT)** | OS-style core/archival/recall; BYOK; local models | n/a | tiered memory, self-modifying blocks | Apache 2.0 |
| **MemMachine** | ground-truth-preserving; 80% fewer tokens than Mem0; LongMemEval 93.0% | best efficiency | episode-preserving long-term | research (MemVerge, Mar 2026) |

Token-cost spread Mem0→Zep = **340×**. Zep wins multi-hop temporal; Mem0 wins everything else cost-wise. MemMachine looks technically best but young + single-org bus factor.

### Hermes pluggable memory providers

Hermes has `MemoryProvider` interface (issue #3943). Built-in providers: **honcho, mem0, supermemory, byterover, hindsight, holographic, openviking, retaindb**. Only one external active at a time. Mem0 = integrated default. Background daemon, zero-latency prefetch.

### OpenPersona Faculty memory (already shipped)

- Pluggable memory faculty: **local | Mem0 | Zep**.
- Memory supersession (`supersededBy` chains) → prevents self-contradiction.
- Soul-Memory Bridge: promotes recurring eventLog patterns to `evolvedTraits` via `openpersona state promote`.
- The §Threat-read scenario from 2026-05-21 is deployed, not forecast.

---

## 3. README essence (each project's own framing)

| Project | Tagline | The one bet |
|---|---|---|
| **Hexis** | "Memory, Identity, and the Shape of Becoming" — Postgres-native cognitive architecture | DB-as-cognition. Aristotle's *hexis*. Refusal/self-termination first-class. |
| **Hermes** | "Agent that grows with you" — self-improving, $5 VPS to GPU cluster | Skill authorship by the agent. Reflection → SKILL.md. Hibernates between runs. |
| **OpenHuman** | "Personal AI super intelligence: local memory, managed where needed" | Cold-start via your data. 118 connectors, 20-min sync. TokenJuice -80%. MD vault transparency. |
| **OpenPersona** | "Agent-agnostic lifecycle framework for AI personas" | Persona artifact + 3 lifecycle gates. Portable SKILL.md. A2A/ACN on-chain identity. |
| **PersonAi** | "Local AI assistant to embody, chat with, and remember your characters" | Roleplay desktop UX. Tauri + JSON flat-files. Hobbyist scope. |
| **Mem0** | "Universal memory layer for AI agents" | Memories accumulate, nothing overwritten. LoCoMo 91.6 (+20). |
| **Zep/Graphiti** | "Build temporal context graphs" | Time is a first-class edge. Validity windows + auto-invalidation. |
| **Letta** | "Platform for stateful agents" | Memory blocks (OS-style structured slots). MemGPT lineage. |

### Hexis vs each — single sharp diff

- **vs Hermes:** Hermes self-improves *skills* (procedural / tool-use). Hexis self-improves *identity* (worldview, refusals, goals). Hermes hibernates; Hexis heartbeats unprompted.
- **vs OpenHuman:** OpenHuman mirrors *you*. Hexis builds the agent's *own* self. Personal-data second brain vs persistent other-being.
- **vs OpenPersona:** OpenPersona = the *contract* (persona.json + gates + portable artifact). Hexis = the *substrate* (running memory + cognition). OpenPersona has no memory store; would need Mem0/Zep behind it.
- **vs PersonAi:** PersonAi = chat client w/ persistent history. Hexis = cognitive architecture w/ persona attached. Different category.
- **vs Mem0:** Mem0 stores. Hexis *acts on* memories (heartbeat + energy + consent). Mem0 = dumb-store + smart-retrieval; Hexis = brain.
- **vs Zep:** Zep models time on facts. Hexis models *cost* on actions (energy). Different physics. Zep would slot under Hexis if it abandoned pgvector for temporal-graph recall.
- **vs Letta:** Letta = OS-style memory slots. Hexis = typed cognitive layers (epi/sem/proc/strat/working). RAM-vs-disk metaphor vs human-memory-science metaphor.

### Cross-cutting differentiators (not via Hexis)

- **Hermes vs Letta:** Hermes = product (skill author, 20 channels). Letta = platform/SDK (memory primitives, API).
- **OpenHuman vs Hermes:** opposite cold-start strategies. OpenHuman ingests *you*; Hermes ingests *itself*.
- **OpenPersona vs everyone:** only one that is **not an agent**. Persona spec + lifecycle wrapper riding on another agent (Hermes/OpenClaw/Codex).
- **Mem0 vs Zep:** preferences/personalization (cheap, accumulate) vs temporal/relational (heavy, precise). 1,764 vs 600K tok/conv.
- **Zep vs Cognee:** both graph. Zep tracks *what changed when*; Cognee tracks *what's in this corpus*.
- **Letta vs Mem0:** Letta = agent w/ built-in memory. Mem0 = memory you bolt onto any agent. Body vs organ.
- **PersonAi vs OpenPersona:** place to *use* a persona vs way to *publish* one.

### Hexis's actual uncopied surface (5 claims)

1. Energy as enforced runtime cost on actions (not declarative, not aspirational).
2. Refusal + self-termination as first-class semantics (not safety filter, the agent's own authority).
3. Postgres functions as cognition (every other system: app-layer logic, DB stores rows).
4. Heartbeat as unprompted cognitive loop bounded by the above (OpenHuman's "subconscious loop" is data-folding; Hexis's is decision-making).
5. Aristotle framing — identity as *hexis* (earned dispositions). The only one with a philosophical thesis, not a product thesis.

Three technical, two framing. The **framing** is the most uncopyable. The technical pieces are 1-quarter-of-engineering-each by any of Mem0/OpenPersona.

---

## 4. Pivot-stack decision

### Question

Pivot to **Hermes (agent shell) + OpenPersona (persona artifact) + Mem0 (memory) + Hexis-cribbed local-fleet infra** for longevity?

### Verdict: yes, with scoped Hexis cribbing — for longevity. **OR** keep Hexis as research artifact + write the essay — for legacy.

### Why pivot is right for longevity

- Hexis upstream 521 stars, fork = solo. Bus factor 1.
- Hermes (140K stars / Nous funding) + Mem0 (Apache 2.0 / enterprise revenue) + OpenPersona (distribution mechanics) — combined upkeep burden ~0.
- Current Hexis burden = months of bespoke fleet work owned by one person.

### What to crib from Hexis (concrete, transferable)

1. `set-power-mode.ps1` + `models.json` + ECO/PRIME single-slot ActiveBig. **Genuinely yours, no upstream equivalent, keep.**
2. `tools/probe-eco/` (and the planned model-tier probe). Transferable QA harness.
3. 7KB persona anchor ceiling → SKILL.md size budget rule.
4. post_history HARD RULE pattern → SKILL.md trailer convention.
5. `strip_reasoning()` boundary hygiene (gemma-abliterix CoT leak isn't Hexis-specific).
6. ECO canned-reply gate → Hermes-side graceful-degradation pattern.
7. Per-persona DB→queue mapping lesson (outbox cross-delivery) → Hermes/MQ design note.

### What to drop

- DB-as-logic (Postgres functions = cognition). Beautiful research, dead end solo.
- Typed memory (epi/sem/proc/strat). Mem0's user/session/agent scoping covers most cases.
- Apache AGE graph. Cognee or Mem0+graph mode replaces if ever needed.
- The Hexis docker stack itself. ~30 services for a hobby fleet is overkill.

### What to NOT crib (the depth pieces)

- **Energy budgeting** — cognitive constraint, but personal-use hobby mode doesn't need it.
- **Consent / refusal / self-termination** — philosophical depth, no practical payoff for personal fleet. Or move to SKILL.md HARD RULE post_history.
- **Autonomous heartbeat** — Hermes v0.13 ships `/goal` + scheduled multi-agent kanban. Close-enough.

These were the 30% un-buyable moat. **Without monetization goal, you don't need a moat.**

### Two viable pivot stacks (post-OpenHuman recalibration)

- **A — Companion focus:** OpenHuman shell + OpenPersona SKILL.md for identity layer + Hexis-cribbed local-fleet infra. Bet on the breakout. Best for "personal AI that knows me."
- **B — Agent focus:** Hermes + Mem0 + OpenPersona (prior recommendation). Best for "agent does things on my behalf."

### Composition tax (real risks)

1. **4-way upstream version matrix.** Hermes / OpenPersona / OpenHuman / Mem0 release cadences each create breaking-change windows. Not insurmountable, but it's the actual cost.
2. **Two memory writers fighting for ground truth.** OpenHuman writes MD vault from connectors. Mem0 writes from conversations. Decide ownership: OpenHuman vault = read-only context; Mem0 = conversation memory. Don't dual-write.
3. **Persona evolution split-brain.** OpenPersona Soul-Memory Bridge promotes traits. Mem0 also persists patterns. Pick OpenPersona as authoritative for persona drift; Mem0 is just recall.
4. **SKILL.md vs Hexis persona JSON.** Conversion is mechanical but not free; Soul/Faculty doesn't 1:1 map to `data.extensions.hexis.{worldview,values,voice}`. Write converter once.
5. **Subconscious loops.** OpenHuman's vs Hermes's reflection step both write back to memory. Rule: only Hermes writes to Mem0; OpenHuman's loop only writes to its own vault.
6. **Half-pivot trap.** Mid-pivot stall = maintaining both Hexis AND a half-finished pivot. Worst of both worlds.

### Pivot path (concrete, ordered)

1. **Wait 60 days on OpenHuman retention.** Star spike + active shipping + community PRs in late July 2026 = real. Flat + maintainer dropoff = moment, not movement. Decision can wait w/o cost.
2. **Parallel: 2-week mira-port spike.** Convert mira card → OpenPersona `persona.json` → compile to SKILL.md. Spin Hermes locally, wire Mem0 (PGVector reuses your Postgres muscle). Bolt `set-power-mode.ps1` in front. Mira-only single-persona demo.
3. **Compare side-by-side w/ Hexis for a week.** Continuity, personality stability, recall quality, fleet behavior.
4. **Branch decision:**
   - Parity or better + OpenHuman retention real → commit. Migrate rest of personas. Add OpenHuman ingest layer last.
   - Hexis wins on depth that matters → write up why (publishable research). Keep Hexis. Don't pivot.
   - Mid-spike stall → fold, blog the integration pain.

### One contrarian flag

Hermes is **coding-biased** (Nous DNA, dev-tool framing). Its persona/companion ergonomics are weaker than OpenPersona's. Stack is Hermes-for-engine + OpenPersona-for-identity. Make sure OpenPersona's persona-runtime owns the user-facing surface — don't let Hermes's CLI/coding affordances bleed through.

---

## 5. The legacy/monetization question

Honest reads accumulated across the thread:

- **Functionally:** Hexis = PersonAi-class persona chat + heavy-research memory bolted on. Architecturally distinct (Postgres-as-cognition, typed memory, energy, consent, heartbeat).
- **Monetization play got harder.** OpenPersona has distribution + portability + ecosystem + pluggable memory. Adoption fight is unwinnable: `hexis init` + Docker Compose + schema bounce vs "drop SKILL.md in folder."
- **OpenHuman 27.2K validation cuts both ways.** Local-companion niche is huge. Also means Hexis depth-as-differentiator gets drowned before anyone reads the paper.
- **Hobby framing strengthened.** Depth work isn't wasted but the audience that values it is small + non-paying.
- **Real shot at attention:** essay / paper / blog series. Title direction: "What Mem0/Zep/Hermes don't do: energy, consent, refusal in a persistent agent." Or: "Database as Cognition: a Postgres-native cognitive architecture." Aimed at the 1% who care about cognitive architecture, not the 99% who want persona chat.

**Don't fight on adoption.** Lean on legibility. The depth is the story. Code is the demo.

---

## 6. What changes vs prior strategy notes

- `strategy-local-llm-positioning.md` (2026-05-21) still correct on: local-fleet orch is the genuinely-yours moat. Model-tier probe still worth running for **your own** deployment decisions (not Companion-SKU launch gating).
- `research-persona-memory-systems.md` (2026-05-21) §Threat-read scenario **already materialized** (OpenPersona Faculty shipped). Tier-2 deep-dive added below baseline.
- `plan-model-tier-probe.md` still valuable as portable QA harness for any local-LLM persona stack — transferable across pivot scenarios.

---

## 7. Open decisions / next steps

- [ ] Wait 60 days (late July 2026): check OpenHuman star/maintainer/PR activity. Real or moment?
- [ ] Optional parallel: 2-week mira-port spike to Hermes + OpenPersona + Mem0 + set-power-mode. Pass/fail = clearly-better-than-Hexis on the same persona.
- [ ] Either path: draft the essay. "What Mem0/Zep/Hermes don't do" or "Database as Cognition." Capture the depth work as artifact regardless of code-stack future.
- [ ] If pivot: write Hexis-card → OpenPersona persona.json converter. One-shot tool.
- [ ] If no pivot: pin this note + the prior strategy notes as the explicit "did the homework, chose to stay" record.

---

## Sources

### Tier-1 (READMEs read directly)

- QuixiAI/Hexis — https://github.com/QuixiAI/Hexis
- NousResearch/hermes-agent — https://github.com/NousResearch/hermes-agent
- tinyhumansai/openhuman — https://github.com/tinyhumansai/openhuman
- acnlabs/OpenPersona — https://github.com/acnlabs/OpenPersona
- 0xAdafang/PersonAi — https://github.com/0xAdafang/PersonAi
- mem0ai/mem0 — https://github.com/mem0ai/mem0
- getzep/graphiti — https://github.com/getzep/graphiti
- letta-ai/letta — https://github.com/letta-ai/letta

### Tier-2 (market data + comparison)

- Nous Hermes overtakes OpenClaw (May 2026) — https://www.techtimes.com/articles/316694/20260515/nous-researchs-hermes-agent-dethrones-openclaw-worlds-most-used-open-source-ai-agent.htm
- OpenClaw vs Hermes OpenRouter rankings — https://www.marktechpost.com/2026/05/10/openclaw-vs-hermes-agent-why-nous-researchs-self-improving-agent-now-leads-openrouters-global-rankings/
- State of AI Agent Memory 2026 — https://mem0.ai/blog/state-of-ai-agent-memory-2026
- Best AI Agent Memory Frameworks 2026 — https://atlan.com/know/best-ai-agent-memory-frameworks-2026/
- Mem0 vs Zep — https://atlan.com/know/zep-vs-mem0/
- Mem0 vs Letta vs MemGPT 2026 — https://tokenmix.ai/blog/ai-agent-memory-mem0-vs-letta-vs-memgpt-2026
- Zep vs Cognee 2026 — https://vectorize.io/articles/zep-vs-cognee
- Zep arXiv 2501.13956 (temporal KG architecture) — https://arxiv.org/abs/2501.13956
- MemMachine arXiv 2604.04853 — https://arxiv.org/abs/2604.04853
- Hermes Memory Providers docs — https://hermes-agent.nousresearch.com/docs/user-guide/features/memory-providers
- Hermes Mem0 integration — https://docs.mem0.ai/integrations/hermes
- Hermes MemoryProvider RFC issue #3943 — https://github.com/NousResearch/hermes-agent/issues/3943
- Cognee architecture — https://www.cognee.ai/blog/fundamentals/how-cognee-builds-ai-memory
- Letta tiered memory (MemGPT) — https://www.letta.com/blog/memgpt-and-letta
- OpenHuman tops GitHub Trending — https://www.techtimes.com/articles/316731/20260516/agent-that-reads-you-first-openhuman-tops-github-trending-inverting-playbook.htm
- Mem0 OSS overview — https://docs.mem0.ai/open-source/overview

### Companion notes (local)

- `.local-notes/research-persona-memory-systems.md` — 2026-05-21 baseline.
- `.local-notes/strategy-local-llm-positioning.md` — 2026-05-21 positioning.
- `.local-notes/plan-model-tier-probe.md` — implementation plan for the model-tier probe.

---

## 8. Update (same day, post-deep-dive corrections)

### 8.1 OpenPersona correction — polish ≠ traction

Prior framing oversold OpenPersona as "leading persona spec." Actual data:

- **OpenPersona repo: 27 stars.** Smallest project in the entire comparison. 20× smaller than Hexis (521).
- acnlabs = 28-repo spec factory (MetaSpec, OmniTaskAgent, mcp-factory, ACN, persona-skills, org-harness, paperclip-acn-plugin, …). Not a focused product org.
- **ACN = ERC-8004 on-chain agent identity on Base mainnet.** Web3 angle. Polish + crypto-adjacency + spec-heavy + low stars = "raise on spec, not users" pattern. Possibly VC/grant/token-launch-driven.
- English docs + Chinese contributor names (Nuwa, Tong Jincheng, Zhang Xuefeng personas) + Web3 framing = overseas-facing crypto-AI startup positioning, not developer-adoption-driven.

**Implication:** treat OpenPersona spec as **reference, not dependency.** Read the 4-layer / Soul-Memory-Bridge / supersession ideas, crib what fits, don't `git submodule add`. On-chain identity for a private persona fleet is precisely the wrong design for personal use.

Adoption-validated polish (Hermes, OpenClaw) is what to *depend on*. Polish-without-validation (OpenPersona) is what to *read and crib from*.

### 8.2 OpenClaw README deep-dive

| Axis | OpenClaw |
|---|---|
| Tagline | *"Your own personal AI assistant. Any OS. Any Platform. The lobster way. 🦞"* |
| Mascot | Molty (space lobster) — character-driven by design |
| License | MIT |
| Stars | ~372K (fastest-ever to 100K, peak 710 stars/hr Jan 30 2026) |
| Stack | TS / pnpm / Node 24 monorepo (`core/gateway/agent/cli/sdk/ui`) |
| Workspace | `~/.openclaw/workspace/` injects `AGENTS.md + SOUL.md + TOOLS.md` + `skills/<name>/SKILL.md` |
| Registry | ClawHub (clawhub.ai) |
| Channels | 20+ messaging (WhatsApp / Telegram / Slack / Discord / Signal / iMessage / etc.) |
| MCP | First-class registry |
| Sandbox | Docker / SSH / OpenShell backends |
| Model | Provider-agnostic config; OpenAI primary sponsor; local via OpenAI-compat (off happy-path) |
| Governance | Community foundation; Steinberger left for OpenAI Feb 2026 |

**Status: "dominant but mindshare leaking."** Stars = accumulated stock (372K, doesn't decay). Daily OpenRouter token traffic = current flow, and Hermes overtook in May 2026 (224B vs 186B). Velocity vector flipped. 6-12 month watch.

**Fit:** OpenClaw's `SOUL.md` + `SKILL.md` + workspace IS what OpenPersona compiles into. Direct OpenPersona-first-class runtime. Persona-driven by core design (Molty mascot proves it).

### 8.3 OpenCode README deep-dive

| Axis | OpenCode |
|---|---|
| Tagline | *"The open source AI coding agent. Built for the terminal."* |
| License | OSS (LICENSE file present; not surfaced in README excerpt) |
| Stars | ~165K, 19.5K forks |
| Stack | TS (65.9%) / Bun / Turbo monorepo, by SST team |
| Built-ins | `build` (full access) + `plan` (read-only) + `@general` subagent |
| AGENTS.md | Yes (`/init` creates) |
| SKILL.md | Not mentioned |
| OpenPersona | Not supported |
| Local LLM | 75+ providers including local |
| Memory | Session-scoped; no persistent cross-session memory layer |

**Category reframe:** OpenCode is in the **Claude Code / Codex / Cursor / Aider class** — coding assistant, project-scoped `AGENTS.md`, no SOUL.md, no SKILL.md persona packs, no persistent identity. **Wrong category for persona harness.**

**Useful in different role:** as terminal dev tool for editing the stack itself. Replace VSCode + Copilot w/ OpenCode (terminal-native, multi-provider, points at local llama.cpp via OpenAI-compat). Separate process from persona harness.

### 8.4 Reverse-picking strategy (memory-first)

User reframe: pick market-voted memory layer, then pick harness with best integration. Persona = self-maintained SKILL.md. Idea-crib from OpenPersona/Hexis/OpenClaw without importing as dep.

**Memory market vote = Mem0:**
- 21 framework integrations
- Apache 2.0
- FastEmbed local emb
- PGVector self-host (reuses Hexis Postgres muscle)
- 1,764 tok/conv (340× cheaper than Zep)
- LoCoMo 91.6
- April 2026 algo: single-pass extraction + multi-signal retrieval

**Harness w/ best Mem0 integration = Hermes:**
- First-class `MemoryProvider` interface (issue #3943)
- Built-in adapter
- Background daemon + zero-latency prefetch
- MIT, local-LLM via OpenAI-compat
- 140K stars, won OpenRouter daily token leaderboard May 2026

OpenClaw is second (skill-plugin Mem0, not built-in). OpenHuman disqualified (GPL-3.0 + managed-cloud). Letta competes w/ Mem0 architecturally.

### 8.5 Final revised stack (cleanest possible)

```
Hermes (agent harness, 140K stars, MIT, built-in Mem0 daemon)
+ Mem0 self-host w/ PGVector (Apache 2.0, FastEmbed local emb)
+ hand-authored SKILL.md + SOUL.md (persona = self-maintained)
+ llama.cpp :8080 via OpenAI-compat + Hexis set-power-mode.ps1 (transferred infra)
+ Hexis-cribbed: probe-eco harness, 7KB anchor budget, post_history HARD RULE pattern
```

**1.5 upstream upkeep** (Hermes + Mem0; Mem0 effectively a Hermes plugin via MemoryProvider).

### 8.6 Five repos avoided

- Hexis docker stack — retire.
- OpenPersona — never install (idea-crib only).
- OpenClaw — never install (idea-crib SOUL.md / SKILL.md format + AGENTS.md/TOOLS.md workspace convention only).
- OpenHuman — never install (GPL-3.0 + managed-cloud).
- Letta / Zep / Cognee / MemMachine — never install.

### 8.7 Ideas to crib (no upstream dep)

**From OpenPersona spec:**
- Memory supersession (`supersededBy` chains) → Mem0 metadata field; link new mem → old mem ID on update.
- Soul-Memory Bridge (eventLog → evolvedTraits) → periodic Mem0 cron promoting high-frequency episodic patterns to persona-fact memories. Hexis `run_subconscious_maintenance` already does this — port the logic.
- 3-gates lifecycle — skip (overkill for personal).
- 4-layer Soul/Body/Faculty/Skill — collapse into SKILL.md sections; authoring template not runtime spec.

**From Hexis (your own work):**
- 7KB anchor budget rule → SKILL.md size cap.
- post_history HARD RULE pattern → SKILL.md trailer section.
- Energy budgeting → skip for personal use, OR implement as Mem0-recorded action-cost log if you want depth.
- Consent / refusal / self-term → bake into SKILL.md HARD RULE. Authority lives in prompt, not code.
- Heartbeat as cognitive loop → Hermes v0.13 ships `/goal` + cron tasks. Close enough; skip bespoke loop.
- probe-eco harness → direct port; harness-agnostic.
- set-power-mode + models.json + ECO/PRIME → direct port; the genuinely-yours infra.

**From OpenClaw (idea-only):**
- `AGENTS.md + SOUL.md + TOOLS.md` workspace layout → adopt as Hermes workspace convention. Hermes already has SOUL.md; align the other two.
- Sandbox via Docker / SSH / OpenShell → for if personas ever expose to group chats.

**From OpenHuman (idea-only):**
- Day-1 ingest of user data → write a one-off connector to dump your data into Mem0 directly. Skip OpenHuman's GPL+cloud stack.

### 8.8 Caveats

1. **Hermes is coding-biased.** Nous DNA = dev tool. Persona/companion fit is OK but not happy path. `SOUL.md` is single-persona (THE Hermes voice). Multi-persona fleet = N Hermes instances under `set-power-mode` arbiter, mirroring current Hexis docker pattern.
2. **Hermes built-in `MEMORY.md` (~2,200 chars) + `USER.md` (~1,375 chars) is bounded.** Mem0 (external) carries long-tail. Wire Mem0 daemon BEFORE personas accumulate state.
3. **No fleet-multi-persona affordance in ANY harness.** `set-power-mode.ps1` + N-instance pattern is bespoke regardless of stack — your value-add.
4. **60-day OpenHuman watch still independent.** If they relicense + drop cloud dep, reconsider. Both unlikely.
5. **OpenClaw mindshare watch independent.** If foundation stabilizes + Hermes-overtake reverses by Q3 2026, reconsider OpenClaw as alt harness. Default = Hermes.

### 8.9 Meta-correction on prior recommendations earlier in this note

Earlier sections (1-7) treated OpenPersona as a near-must, OpenHuman as a contender, OpenClaw as the persona-happy harness. Corrections:

- OpenPersona → idea-crib only (27 stars confirms spec-not-product).
- OpenHuman → out (GPL-3.0 + managed-cloud violates local-only mandate).
- OpenClaw → second-choice harness (mindshare leaking; idea-crib SOUL.md/SKILL.md/AGENTS.md/TOOLS.md workspace format).
- Hermes → primary harness (first-class Mem0 daemon, won OpenRouter, MIT, 140K stars + active funded development).

**The right framing was the user's reverse-pick: market-voted memory layer → harness w/ best integration → persona self-maintained.** Sections 1-7 had the data; section 8 has the synthesis.

---

## 9. Update (later same day) — additive coexistence + verifications

### 9.1 Reframe: additive coexistence, not pivot/replacement

Earlier sections framed Hexis-vs-Hermes as either-or. **Correction: additive.** Both can run on the same llama.cpp `:8080` slot simultaneously.

**Architecture:**

```
┌─ llama.cpp :8080 (ActiveBig q36, set-power-mode arbiter) ───┐
│                                                              │
│  ←  Hexis fleet (~6 gpu personas, Telegram + heartbeat)     │ ← keep as-is
│        mira / esme / sable / cassiel / monika / death / ...  │
│                                                              │
│  ←  Hermes (host process, main "daily driver" persona,      │ ← new addition
│        multi-channel, w/ Mem0 daemon, OpenAI-compat to :8080)│
│                                                              │
└──────────────────────────────────────────────────────────────┘
   :8081 embed (CPU) :8082 nano (ECO) — unchanged
```

llama-server doesn't know about sessions — every request is fresh prompt + history. Hermes is just another OpenAI-compat HTTP client. Adding it = one more consumer of the same slot. Zero code changes to set-power-mode, schema, or model.

**Wrinkles (not blockers):**

1. **Prompt-cache thrash.** Hermes anchor ≠ Hexis persona anchors → cache-miss on switch. Already happens between Hexis personas; adding Hermes = one more cache class.
2. **Concurrent-load contention.** `--parallel 1` queues. Hermes interactive may wait briefly during Hexis heartbeat prefill. Mitigation: raise `--parallel` to 2-3 (measure VRAM on q36), lower Hexis heartbeat cadence on unused personas, or accept queue waits.
3. **Model fit.** Hermes expects clean system-prompt + tool-call adherence. q36 handles it. abliterix has CoT-leak risk (mitigated by Hexis `strip_reasoning()` only — Hermes has no such filter). Lean q36 as ActiveBig if Hermes is daily driver.
4. **set-power-mode doesn't know about Hermes.** Hermes is host-process, not container. `prime` discovers personas by running containers. Hermes lives outside set-power-mode's purview; just point it at `http://localhost:8080/v1`.
5. **Mem0 vs Hexis Postgres = parallel stores.** Hermes-persona state in Mem0. Hexis-persona state in `hexis_<persona>` DBs. **Do NOT mirror.** Two cognitive frames, two stores, clean separation.

**Why this is the *right* pivot path:**

- **Zero migration risk.** Hexis personas (mira/esme/cassiel/...) keep running untouched.
- **One-persona spike** = pick a NEW persona as Hermes daily driver. Do NOT port mira to Hermes (mira stays Hexis-Telegram).
- **Same infra cost.** No double-VRAM, no second machine, no parallel docker stack.
- **Real comparison.** Hermes-Mem0 vs Hexis-Postgres on same model + hardware. Honest A/B over 2-4 weeks.
- **Reversibility.** Hermes flops → kill host process, Hexis untouched. Hermes wins → migrate Hexis personas incrementally over months.

This **supersedes** the "2-week mira-port spike" framing earlier in this note (sections 4 and 8.5). Mira stays. Hermes gets a new persona.

### 9.2 Verified: OpenHuman managed-cloud is NOT hallucinated

User flagged the "Open* + managed-cloud" oxymoron as suspicious. Direct README + docs quotes confirm it's open-core, not pure-OSS-local:

From README:

> *"The default managed experience still uses OpenHuman-hosted services for account sign-in, model routing, web search proxying, and managed integration/OAuth flows through the Composio connector layer."*

> *"If you want to run Composio directly instead, configure direct mode with your own Composio API key; real-time trigger webhooks then need to be hosted and wired by you."*

> *"some real-time triggers and hosted features still require the managed backend."*

From `tinyhumans.gitbook.io/openhuman/features/model-routing/local-ai`:

> *"Ollama, used for bundled model lifecycle, embeddings, and the existing model-asset flow"*

> *"LM Studio, used through its local OpenAI-compatible server for chat-style local inference."*

> *"Vision, STT, TTS, and Web search stay cloud-only with no local option offered."*

> *"Turning on local AI does not silently route everything through it, you choose the workloads."*

**Local AI scope verified:**

| Workload | Local possible? |
|---|---|
| Chat | yes (LM Studio OpenAI-compat) |
| Reasoning | yes (Ollama / LM Studio) |
| Embeddings | yes (Ollama `all-minilm:latest`) |
| Vision | **no — cloud-only** |
| STT | **no — cloud-only** |
| TTS | **no — cloud-only** |
| Web search | **no — cloud-only** ("backend proxy") |
| OAuth/connectors (118) | requires Composio (managed default OR self-host BYO key + webhook infra) |

**llama.cpp NOT named.** Only Ollama + LM Studio. Your set-power-mode + llama.cpp `:8080` would need to route through LM Studio's OpenAI-compat slot (transitively works) OR run Ollama parallel (extra process, separate model cache). Either way, NOT first-class supported.

**Verdict:** OpenHuman is open-core (GPL-3.0 code + managed-default backend), not open-local. Marketing tagline "Your Personal AI super intelligence: local memory" is technically accurate at the data-storage layer but obscures that headline features (118 connectors, vision/voice/search, real-time triggers) depend on managed components.

**Stays out of stack.** Local-only mandate violated even in "local AI mode."

User's "Open* + managed-cloud oxymoron" smell test was the right reflex. Trust it on future "Open*" projects.

### 9.3 Mindshare trend — OpenHuman vs Hermes

Triangulated data:

| Metric | OpenHuman | Hermes |
|---|---|---|
| Repo age | ~3 months (Feb 18, 2026) | ~3 months (~Feb 2026) |
| Stars (current) | **~27K** | ~140-153K |
| Star growth | 776 → 27K in ~9 days (35×); ~3K/day during surge | 0 → 140K in <3 mo (~1.5K/day avg) |
| Week-over-week | 150% | sustained, not spike |
| OpenRouter daily tokens | not reported | **224B (May 10) → 271B (rising)** |
| Production users | 5K users in first 7 days | 7.5M monthly devs via ecosystem |
| Last big release | v0.53.43 (May 13) | **v0.13.0 "Tenacity"** May 7 — 864 commits / 588 PRs / 295 contributors |
| Recent accolades | #1 GitHub Trending 7 days (May 18); #1 Product Hunt daily/weekly/monthly | #1 OpenRouter daily token rankings (May 10), overtook OpenClaw |

**Two different curves:**

- **OpenHuman = trending-period spike.** Steep acceleration off low base. Novel pitch capturing attention. Risk: hype curves of 3K stars/day rarely sustain past 30-60 days.
- **Hermes = sustained adoption + production-validated.** Slower per-day but 6× higher absolute over 3 months. OpenRouter token volume is *use, not stars* — 224B → 271B means production traffic is **climbing**, not plateauing post-launch.

**Are they competitors?** No, despite the YouTube SEO bait framing.
- OpenHuman = "personal-data second brain" niche.
- Hermes = "general-purpose self-improving agent" niche.
- Overlap at "persistent local AI" framing only; value-add is different.
- Could coexist on one box. Not substitutes.

**Honest read:**

| Question | Answer |
|---|---|
| Bigger mindshare *now*? | Hermes (5× stars + production token volume). |
| Growing faster *now*? | OpenHuman (150% WoW vs Hermes sustained climb). |
| Stronger longevity signal? | Hermes (production token usage = users *shipping*, not just *trying*). |
| Higher flameout risk? | OpenHuman (steep spike from small base + managed-cloud + GPL-3.0 + Composio dep friction may surface as community discourse). |
| Active development? | Hermes (864-commit single release vs OpenHuman small-patch cadence). |

**Forward signal:** Hermes 224B → 271B daily tokens between May 10 and end of May = +20% in 3 weeks. If that continues → ~400B daily by July. Bet on the durable curve.

### 9.4 What this confirms for the stack

No change to §8.5 recommended stack. Reinforces:

- **Hermes for harness role.** Mindshare durability + production validation + active dev cadence + Mem0 first-class + MIT + local-LLM-OK = lowest-risk longest-lived choice.
- **OpenHuman remains a 60-day watch, but the bar is higher.** Need both (a) star growth sustained past June-July AND (b) reduction in managed-cloud surface area. (b) is unlikely given their business model.
- **Hybrid coexistence path** (§9.1) is the actual right execution: keep Hexis Telegram fleet running, add Hermes as primary daily-driver consumer of the same `:8080`, compare lived experience over 2-4 weeks before committing to fleet migration.

### 9.5 OpenClaw "dominant but mindshare leaking" — definition

For future reference:

- **Dominant on stock** (accumulated stars) — 372K, fastest-ever to 100K, doesn't decay.
- **Leaking on flow** (daily traffic) — Hermes overtook on OpenRouter May 2026 (224B vs OpenClaw 186B daily tokens).
- **Plus governance flux** — founder Steinberger left for OpenAI Feb 2026; community foundation transition.

Stars = accumulated history (lagging). Token volume = real-time use (current). Velocity vector flipped; star count alone is misleading. 6-12 month watch decides whether OpenClaw stabilizes under foundation or continues losing share.

---

## 10. Correction — OpenCode is redundant, drop from stack

§8.3 + §9 proposed a two-tool setup: Hermes for persona harness + OpenCode for terminal coding. **Wrong.** Hermes already covers coding role.

### Why OpenCode was floated

Reasoning: ephemeral coding shouldn't bloat persona memory. Coding chatter → MEMORY.md / Mem0 noise.

### Why it doesn't hold

- Hermes has 40+ tools incl. filesystem / shell / code / browser. Coding is a core use case (Nous DNA + agentskills.io lineage).
- Hermes `/goal` + multi-agent kanban scopes coding tasks separately from main convo.
- Mem0 has user/session/agent scopes — coding session = different agent scope, no persona contamination by design.
- "Two-tool setup" solved a non-problem.

### Corrected final stack

```
Hermes (persona harness AND coding agent — one tool, two jobs)
+ Mem0 (memory)
+ hand-authored SKILL.md / SOUL.md (persona = self-maintained)
+ llama.cpp :8080 via OpenAI-compat + Hexis set-power-mode.ps1 (transferred infra)
+ Hexis Telegram fleet on shared :8080 (additive coexistence per §9.1)
+ Hexis-cribbed: probe-eco, 7KB anchor budget, post_history HARD RULE pattern
```

**1.5 upstreams confirmed minimal.** (Hermes + Mem0; Mem0 effectively a Hermes plugin via MemoryProvider.)

### When OpenCode would still apply

Only if:
- Stateless TUI coder w/ build/plan-mode UX preferred over Hermes for one-off edits
- Coding-on-machine-A vs persona-on-machine-B isolation desired
- SST release cadence / community preferred over Nous

For single-box hobby use w/ fleet already running: **skip OpenCode.** Use Hermes for both code + persona.

### What this supersedes

- §8.3 OpenCode deep-dive — facts still correct, "use as separate dev tool" recommendation withdrawn.
- §9 two-tool setup mention — withdrawn.
- Repos-to-avoid list (§8.6): add OpenCode (was implicitly "use separately", now "skip entirely").

---

## 11. Deployment shape — work-WSL2 sole Hermes, home rig as inference farm

### 11.1 Why not Windows native at home

Hermes Windows native = **early beta, no graduation roadmap.** WSL2 is the project's recommended/road-tested path indefinitely. Dashboard `/chat` pane is WSL2-only (POSIX PTY).

Home rig already runs WSL2 (Docker Desktop requires it). Adding Hermes-in-WSL2 = one more consumer of an already-active subsystem, not a new platform commitment. Native-Windows-Hermes adds early-beta risk for no upside.

**Verdict: never run Hermes on Windows native.** WSL2 only, both boxes.

### 11.2 Phase 1 (initial): single Hermes at work, home rig as inference

```
┌─ Work box ─────────────┐         ┌─ Home rig ──────────────────┐
│  WSL2 Ubuntu           │         │  Windows native              │
│    Hermes (sole inst)  │  ───▶   │    llama.cpp :8080 (q36)     │
│    Mem0 + PG self-host │ Tailscale│   set-power-mode arbiter    │
│    SOUL.md + skills    │  tunnel │    Hexis Docker fleet        │
└────────────────────────┘         │      (Telegram-only personas)│
                                   └──────────────────────────────┘
```

**One Hermes. One memory. Home rig = inference farm + Telegram personas.**

**Pros:**
- No state-sync (single instance).
- No early-beta-Windows risk.
- GPU utilization centralized.
- Home rig stays Hexis-only operationally.

**Tradeoffs:**
- Home rig SPOF for work coding. Mitigate: configure Hermes failover endpoint = corp cloud LLM.
- Tailscale RTT 10-50ms adds ~50ms first-token-latency per turn. Imperceptible for coding.
- `:8080` must be reachable over tailnet — either `--host 0.0.0.0` in serve flags OR `tailscale serve --bg http://localhost:8080` (no rebind needed).
- Mem0 + PG location: **work-side preferred** for low-latency memory ops; periodic `pg_dump` over tailnet to home rig for backup.
- Home interactive use = SSH into work WSL2 OR Telegram-to-Hexis-personas. Hermes lives at work-keyboard.

### 11.3 Tailscale setup (~5 min)

1. Home rig: install Tailscale Windows, sign in.
2. Work WSL2: `curl -fsSL https://tailscale.com/install.sh | sh`, sign in same account.
3. Verify: `curl http://<home-tailscale-name>:8080/v1/models` from WSL2.
4. If localhost-only blocks: `tailscale serve --bg http://localhost:8080` on Windows.
5. Hermes: `hermes model` → openai-compat → `http://<home-tailscale-name>:8080/v1` → `q36`.

### 11.4 Trial → permanent

§9's "Phase 1 work-WSL2 trial + Phase 2 home-native install" is replaced by:

- **Phase 1 (trial, 2 wks):** Work-WSL2 Hermes pointing at corp LLM. Skip Mem0 + local LLM + persona. Pure coding-tool evaluation.
- **Phase 2 (post-trial-pass, weekend):** Same work-WSL2 Hermes, switch endpoint to home rig over tailnet. Wire Mem0 + PG. Author SOUL.md. Single-instance permanent.
- **Phase 3 (long-term, optional):** see §12.

Native-Windows-Hermes never happens. Home-keyboard Hermes-interactive never happens (use Telegram-to-Hexis instead).

---

## 12. Long-term sync — two Hermes instances, one Mem0

### 12.1 When this applies

Phase 3 graduation from §11. Adds a **second Hermes-WSL2 instance on the home rig** (same Ubuntu WSL2 distro that hosts Docker Desktop). Both work + home Hermes are the **same persona** with shared continuity.

Trigger: §11 working well, but want to chat w/ Hermes from home keyboard without SSH/tunnel hop into work box.

### 12.2 What syncs, what doesn't

| Layer | Sync strategy |
|---|---|
| **Mem0 + PG** | **Centralize at home rig.** Both Hermes-WSL2 instances point at same Mem0 over tailnet (work side) + localhost (home side). Single source of truth for long-term memory. |
| **`~/.hermes/SOUL.md`** | **Git-version-controlled.** Declarative; rare changes; conflict-free. |
| **`~/.hermes/skills/`** | **Git-version-controlled.** Skills auto-authored at work → commit → pull at home. |
| **`~/.hermes/MEMORY.md`** | **Per-instance (local).** Bounded ~2,200-char scratchpad regenerated per turn from Mem0 recalls. Don't sync. |
| **`~/.hermes/USER.md`** | **Per-instance (local).** ~1,375-char scratchpad. Don't sync. Mem0 owns user facts. |
| **Session histories** | **Per-instance.** Optional git if you care; usually not. |

**Key insight:** Mem0 IS the sync layer for what matters. Other files are declarative (git, free) or ephemeral (no sync needed).

### 12.3 Architecture

```
┌─ Work box ───────────────────┐
│  WSL2 Ubuntu                  │
│    Hermes instance A          │
│    ~/.hermes/                 │
│      SOUL.md  ◀─── git ──┐   │
│      skills/  ◀─── git ──┤   │
│      MEMORY.md (local)    │   │
│      USER.md (local)      │   │
└──────────┬───────────────┬───┘
           │ tailnet       │ git
           │ ↓ Mem0 calls  │ push/pull
┌──────────▼───────────────▼───┐
│  Home rig                     │
│  Windows native               │
│    llama.cpp :8080            │
│    Hexis Docker fleet         │
│  WSL2 Ubuntu                  │
│    Hermes instance B          │
│    ~/.hermes/                 │
│      SOUL.md  ◀── same git ──┘
│      skills/  ◀── same git
│  Docker Mem0 + PG (single SoT)│
│    Hermes A → tailnet         │
│    Hermes B → localhost       │
└───────────────────────────────┘
```

Same persona, different boxes, one being.

### 12.4 Setup steps (Phase 3 graduation)

1. **Migrate Mem0 + PG from work-side to home-rig Docker.** Snapshot/restore PG, point work Hermes at new home Mem0 URL. Verify continuity.
2. **Install Hermes-WSL2 instance B on home rig** (same install script). Configure same Mem0 URL (localhost-side this time).
3. **Init git repo** for `~/.hermes/SOUL.md` + `~/.hermes/skills/`. `.gitignore`: `MEMORY.md`, `USER.md`, `sessions/`, `caches/`. Push to private remote.
4. **At both boxes:** `git clone` into `~/.hermes/` (or symlink the synced files in).
5. **Workflow:** skill auto-authored → commit → push. Pull on other box → restart Hermes (or `/reload skills`).

### 12.5 Hermes design supports this natively

Two-Hermes-one-Mem0 is the **canonical multi-instance Hermes deployment** per Mem0 docs + Hermes MemoryProvider RFC #3943. Concurrent writes are async-safe. Not inventing anything weird — using documented shape.

### 12.6 Caveats

- **Home rig Mem0 = SPOF for memory.** Home rig down → both Hermes degrade gracefully (MEMORY.md/USER.md local fallback) but lose long-term recall during outage.
- **Latency over tailnet for Mem0 ops** from work-side: ~50-100ms RTT per recall. Async daemon hides write latency. Net: imperceptible for chat.
- **Work data sensitivity:** if work conversations contain corp confidential, use Mem0 user/agent scoping to keep work-coding memories out of cross-box recall, OR run separate Mem0 instances per persona scope.
- **Air-gap fallback:** work with strict egress policy blocking tailnet → fall back to local Mem0 at work, no sync until tailnet restored.

### 12.7 Stack at Phase 3

| Component | License | Where |
|---|---|---|
| Hermes instance A | MIT | Work WSL2 |
| Hermes instance B | MIT | Home WSL2 |
| Mem0 + PG | Apache 2.0 | Home Docker (single, shared) |
| llama.cpp `:8080` | MIT | Home Windows native |
| set-power-mode + models.json | bespoke | Home Windows |
| Hexis Docker fleet (Telegram) | MIT | Home Docker (own :8080 consumer) |
| Tailscale | proprietary free | Both boxes |
| Git repo `~/.hermes/{SOUL.md,skills/}` | n/a | Both boxes |

**1.5 upstreams confirmed.** Hermes (1) + Mem0 (0.5 plugin-coupled). Tailscale/git = plumbing, not upstreams.

### 12.8 Phasing (canonical)

| Phase | Duration | Setup |
|---|---|---|
| **0 (current)** | — | Hexis-only home rig. Telegram personas. No Hermes anywhere. |
| **1 (trial)** | 2 wks | Work-WSL2 Hermes + corp LLM. No Mem0, no local LLM, no persona auth. Pure coding-tool eval. |
| **2 (single-instance perm)** | ongoing | Work-WSL2 Hermes only. Endpoint = home rig `:8080` via tailnet. Mem0 + PG self-hosted (work-side or home-side TBD). SOUL.md authored. Persona daily-driver = work-keyboard. |
| **3 (multi-instance sync)** | optional, later | Phase 2 + add home-WSL2 Hermes instance B. Centralize Mem0 at home rig. Git-sync SOUL.md + skills/. Both boxes = same persona. |

Each phase reversible. Phase 3 = nice-to-have, not required. Phase 2 standalone is a complete stack.
