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
