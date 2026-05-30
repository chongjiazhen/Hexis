# Research note — persistent-memory persona/agent landscape (2026-05-30)

**Revises:** `research-persona-memory-systems.md` (2026-05-21). That file's deep-dives
on OpenPersona/Hermes/OpenHuman/PersonAi are still useful background, but several
headline claims are now **stale or disproved** — corrected here. Read this one first.

**Method:** deep-research workflow (23 sources fetched, mostly primary) + manual
`gh api` star checks + targeted WebFetch verify. NOTE: the workflow's adversarial
*verify* phase crashed (all verifier subagents abstained / never emitted
StructuredOutput → false "all refuted"). So architecture claims below are
**single-source primary, not adversarially cross-checked** unless marked verified.

**Confidence:** ⬛ verified (`gh api` / direct issue read) · 🟫 primary-source fetch, unverified.

---

## Traction — VERIFIED (`gh api`, 2026-05-30) ⬛

| Repo | Stars | Forks | Last push | Note |
|---|---|---|---|---|
| NousResearch/hermes-agent | **172,636** | 29,060 | 2026-05-29 | massive; the prior "172k" was REAL, not a hallucination |
| tinyhumansai/openhuman | **29,495** | 2,787 | 2026-05-29 | GitHub-trending; the real rising star |
| **QuixiAI/Hexis** | **580** | 73 | 2026-05-24 | us |
| scrypster/muninndb | **298** | 72 | 2026-05-26 | NEW — direct philosophical rival (see below) |
| 0xAdafang/PersonAi | 29 | 4 | 2025-08-25 | dormant ~9mo |
| acnlabs/OpenPersona | 27 | 3 | 2026-04-27 | slowing |

---

## Prior-claim ledger — hold vs disproved

| 2026-05-21 claim | Verdict | Why |
|---|---|---|
| "DB is the brain (state AND logic) — Hexis alone" | ❌ **DISPROVED** | **MuninnDB** does exactly this (cognition primitives engine-native). See below. |
| "OpenPersona has fewer stars than Hexis despite more polish" | ✅ **HOLDS** ⬛ | 27 vs 580 (~21×). |
| "OpenPersona has no memory store of its own (Faculty only declares)" | ❌ **DISPROVED** 🟫 | Now ships `local` default + pluggable Mem0/Zep. Still app-layer, not DB-as-authority. |
| "OpenPersona = highest threat" | ❌ **STALE** ⬛ | 27 stars, slowing. Not credible by traction. Survey aimed at the wrong target. |
| "Hexis alone in autonomy + multi-portal + persistent identity" | ⚠️ **UNDERCUT** 🟫 | Hermes has multi-channel + self-improve loop + SOUL.md + user-modeling + 172k stars. But its memory models the USER (file+plugins), no energy/consent/heartbeat-as-cognition. Narrow claim breaks; core thesis intact. |
| "Field converging on Hexis epi/sem/proc/strat taxonomy" | ↔️ partial | RetainDB (7 memory types) + OpenHuman tiers echo it; not universal. |
| "SillyTavern memory wedge saturated; heartbeat/consent/energy still unique inside ST" | ↔️ holds (unre-verified) | ST sources fetched, no fresh contradicting claim. |

---

## NEW + most important: MuninnDB (scrypster/muninndb) 🟫 + ⬛ traction

**The direct philosophical rival to "database is the brain."** Self-described "cognitive
database for AI... a database where the intelligence is the engine, not a wrapper above
dumb storage." Explicitly anti-Postgres: *"No Redis. No Pinecone. No Postgres."*

- **Logic IN the engine** (deterministic, not LLM): ACT-R / Ebbinghaus temporal-decay
  scoring, Hebbian auto-learning on every query, Bayesian confidence gating, semantic
  push triggers. "Memories evolve on their own."
- Hybrid retrieval (BM25 + vector + graph) in one engine. Single static Go binary.
  REST / gRPC / binary / MCP-native. Python SDK. Free now, Apache-2.0 slated 2030.
- Created 2026-02-22, 298⭐ — young + fast.

**Hexis vs MuninnDB — the line that still holds:**
- MuninnDB = cognition-DB as *memory infrastructure*. Purpose-built engine, primitives
  baked into Go. No persona, no selfhood, no autonomous loop, no consent/refusal,
  no energy budget. It is a brain-in-a-box you bolt onto an agent.
- Hexis = cognition-DB as *a whole being*. Postgres-functions cognition + typed memory
  + **energy budgeting + consent/refusal/self-term + autonomous heartbeat + persona/worldview**.
- So "DB-as-brain" is **no longer Hexis-unique as a memory philosophy** — but Hexis's
  *full stack* (cognition-substrate + selfhood + autonomy + consent) still has no twin.
- Architectural irony: MuninnDB is *more* committed to brain-as-engine (custom engine)
  while Hexis is *more* committed to brain-as-being. Different axes of the same thesis.

**IP / patent (added 2026-05-30) ⬛ README + muninndb.com:**
- **US Provisional Patent No. 63/991,402**, filed **2026-02-26** (4 days after repo
  created 2026-02-22). By MJ Bonanno / Scrypster. Confers "patent pending" only —
  provisional = unexamined 12-month placeholder, not a granted patent.
- Claimed scope = the *cognitive primitives*: Ebbinghaus decay, Hebbian learning,
  Bayesian confidence, semantic triggers. README ties patent auto-Apache-2.0 to
  2030-02-26 (same date as code license flip).
- **Not a Hexis crib.** No reference to Hexis in README/docs/patent; no code lineage;
  no shared naming. Convergent DB-as-brain idea, independent build. The claimed
  primitives are decades-old prior art (Ebbinghaus 1885, Hebb 1949, Bayes 1763) —
  Hexis never claimed them either, so nothing of Hexis's was annexed.
- **No threat to Hexis.** Hexis runs Postgres + pgvector + AGE, not Muninn's engram
  engine. Hexis differentiators (energy, consent, heartbeat, persona) sit outside the
  claimed scope. Generic-primitive provisional invites heavy prior-art challenge if
  ever prosecuted to a full filing.
- **Defensive note:** if Hexis ever needs prior-art ammunition, public Hexis commit
  dates / posts pre-2026-02-26 are the lever. No action needed now.

---

## Hermes Agent memory model (corrected) 🟫

- **Default = file-based**: `MEMORY.md` (agent notes) + `USER.md` (user profile) in
  `~/.hermes/memories/`, injected as a frozen snapshot at session start. (Same shape as
  this Claude harness's `~/.claude/memory/`.)
- **External providers, additive, one active at a time**: Honcho, OpenViking, Mem0,
  Hindsight, Holographic, RetainDB, ByteRover, Supermemory, Memori. **Zep NOT listed**
  (corrects prior Mem0/Zep/Honcho assumption).
- Heterogeneous architectures: Hindsight=graph; OpenViking/ByteRover=hierarchical
  filesystem trees w/ tiered retrieval (L0~100 tok→L2 full); Holographic=SQLite+FTS5+HRR;
  Honcho=dialectic two-layer user-model; Mem0=vector+server-side LLM extraction;
  RetainDB=Vector+BM25+rerank, 7 memory types.
- Issue #3943 ("MemoryProvider interface") **closed not_planned** ⬛ (2026-05-03) — BUT
  56 `MemoryProvider` code matches exist ⬛. Resolution: the *formal Protocol proposal*
  was rejected; providers exist in code regardless. Enumeration is real; "Honcho sole
  backend" was a proposal-time snapshot, now superseded.

## OpenHuman (tinyhumansai) 🟫 — 29.5k⭐, different niche

- **Memory Tree**: per-source rolling buffer (L0) seals → L1/L2 as it fills; lazy
  per-entity topic trees; one daily global digest.
- Ingest = deterministic, LLM-free hot path: deterministic chunk IDs (dedup), state
  machine `pending_extraction→admitted→buffered→sealed`, atomic txns. Chunks ≤3k tok.
- Store = SQLite (`memory_tree/chunks.db`) + Obsidian-compatible Markdown `wiki/` under
  `~/.openhuman`.
- **Confirmed: memory OF the user** (personal-data aggregator, 118+ integrations,
  "become you, controlled by you"). Not an autonomous self. Borrow the deterministic
  ingest pipeline; don't fear the niche.

---

## Differentiators that survive scrutiny (post-MuninnDB)

1. **Whole-being stack**, not memory infra: cognition-DB + persona + energy + consent + heartbeat. No competitor has all.
2. **Energy budgeting** as enforced runtime constraint — unmatched.
3. **Consent / refusal / self-termination** first-class — unmatched (MuninnDB is a DB, has no will).
4. **Heartbeat = unprompted agency** — OpenHuman fold-loop + Hermes self-improve are *maintenance*, not agency.

**Dropped from the moat list:** "only one putting logic in the DB" — MuninnDB took that.
Lean the pitch on *whole-being* (substrate + selfhood + autonomy + consent), not on
DB-as-brain alone.

**Strategic read:** depth bet still sound, but the gap to close is **inspectability
ergonomics** (Hermes markdown, OpenHuman editable vault) — not architecture. Postgres
is the least legible store in the field; that's the adoption tax, not the cognition.

## Threads to follow
- MuninnDB as a *substrate option* — could a Hexis persona run on Muninn instead of
  hand-rolled Postgres functions? (Philosophically aligned; would trade Postgres
  authority for a younger engine. Probably no — but worth understanding the engine.)
- RetainDB's "7 memory types" — closest external echo of Hexis typed memory.
- Re-run the deep-research verify phase once the StructuredOutput-abstain bug is fixed;
  architecture claims here are single-source.

## Sources
- Hermes docs: hermes-agent.nousresearch.com/docs/user-guide/features/{memory,memory-providers,honcho}
- Hermes issue #3943 (closed not_planned) ; repo NousResearch/hermes-agent
- MuninnDB: muninndb.com ; github.com/scrypster/muninndb
- OpenHuman: tinyhumans.gitbook.io/openhuman/features/obsidian-wiki/memory-tree ; github.com/tinyhumansai/openhuman
- OpenPersona: github.com/acnlabs/OpenPersona
- Field surveys: glukhov.org/ai-systems/memory/agent-memory-providers ; atlan.com/know/best-ai-agent-memory-frameworks-2026 ; vectorize.io/articles/best-ai-agent-memory-systems
