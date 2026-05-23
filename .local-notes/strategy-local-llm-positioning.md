# Strategy — local-LLM sovereignty as Hexis's differentiator

**Date:** 2026-05-21
**Status:** direction agreed; first build (model-tier probe) specced below, not yet executed.
**Companion read:** `research-persona-memory-systems.md` (field survey + threat read).

---

## 1. Thesis

Hexis (this fork) is downstream of `github.com/QuixiAI/Hexis` (MIT). Upstream is cloud-capable
(OpenAI / Anthropic / Ollama). The cognitive architecture — typed memory, energy, consent,
heartbeat — is QuixiAI's and is public + MIT. Cribbing more upstream ideas makes the fork
*better*; it does not make it *ours*.

What is genuinely ours is the divergence already built: a **persona fleet that runs on local
LLMs on consumer hardware** — `set-power-mode.ps1`, the single-GPU-slot `ActiveBig` schema,
ECO/PRIME power modes, the `C:\llm-serve` interlock, the nano sidecar, `--parallel 1` fleet
sharing, the ECO canned-reply graceful-degradation gate. That is months of systems work
upstream does not have and a clone-the-upstream competitor cannot get in a weekend.

**Differentiator:** not "local" (upstream already does Ollama; any frontend bolts on
llama.cpp). The moat is **fleet-grade local orchestration + graceful degradation across the
consumer hardware curve.**

**Positioning line:** *"Not your hardware, not your waifu."* Sovereignty / ownership framing
— private, local, data never leaves the box. The market for this is live (PersonAi, OpenHuman
both local-first and trending; Character.ai/Replika refugees who want private + uncensored).

## 2. Two-SKU model

"Both" (companion + agent platform) resolves as a wedge + platform, not a compromise.

| | Companion SKU | Platform / Fleet SKU |
|---|---|---|
| VRAM floor | **8 GB** | **16 GB** |
| Steam GPU market (Apr 2026) | ~75-80% (8+12+16+24 GB) | ~23%, rising ~2pp/month |
| Model | one tuned persona, 4B-class | MoE A3B (`q36`), 6-8 personas/slot |
| Pitch | "your private waifu, runs on the GPU you have" | "a persona fleet on one card" |
| Role | mass-market wedge — acquire users now | platform — grows as 16GB becomes the floor |

The 16GB tier is not a long shot: 16GB is ~23% of Steam GPUs and rising, RTX 50-series
mainstream is 16GB. The curve is arriving through 2026, not someday.

## 3. VRAM floors — the numbers

Q4_K_M quant ≈ ~4.5 bits/weight (llama.cpp constant). Model VRAM = params × 4.5 / 8.

| Model | Weights (Q4) | + KV cache (8-16K ctx) | Total |
|---|---|---|---|
| 1B | ~0.6 GB | ~0.3 GB | ~1 GB |
| 4B | ~2.3 GB | ~1-2 GB | ~3.5-4.5 GB |
| 7-8B | ~4.5-5 GB | ~1.5-2 GB | ~6.5-7 GB |
| 30-35B MoE A3B | — | — | fits 16GB fleet box (`q36`, CLAUDE.md) |

Raw VRAM ≠ usable VRAM. On an 8GB card that also drives the desktop:
- Windows desktop + browser resident: ~1.5-2 GB
- llama.cpp compute buffers + CUDA context: ~0.5-1 GB
- **Usable headroom ≈ 5-5.5 GB**

Therefore:
- **4B (~4 GB total) fits comfortably in 5.5 GB** — with room for context + the PRIME-path
  prompt bloat (memory + tools inflate the prompt). This is the genuinely-comfortable 8GB tier.
- **7-8B (~7 GB) does not fit** alongside the desktop — works only with display on an iGPU
  or a cramped context. Marginal; not a floor that can be promised.
- **1B** is the graceful-degradation floor (ECO `_eco_slim_chat`), not a product tier.

**Source honesty:** 4.5 bpw is a hard llama.cpp constant. The KV / compute-buffer / desktop
figures are deployment rules-of-thumb, NOT measured on a real 8GB box. The floor claim must
be confirmed by measurement (see §4), not shipped on arithmetic.

## 4. The gate — model-tier probe

Everything above is a bet until the probe turns it into a fact. The probe is the first and
only code deliverable of this strategy round; it gates the 8GB claim.

**Purpose:** answer "is a tuned 4B-class persona good enough to ship — and does it actually
fit 8GB?"

**Build:** extend `tools/probe-eco/probe-all.sh`. Today it runs N prompts through `chat_turn`
per persona on nano only. Change it to **bracket multiple model sizes** (1B / 3B / 4B / 7-8B),
same prompt set, same personas, scrub probe-generated memories after (already does this).

**Components:**
1. **Model-set config** — list of `{size, gguf-key}` to bracket; resolve via the existing
   `C:\llm-serve\models.json` registry. Do not hardcode gguf paths or serve flags.
2. **Probe runner** — loop model-set × persona × prompts; serve each model in turn via the
   existing nano serve path / `set-power-mode`.
3. **Scorer** — classify each reply against the known failure classes from the prior fleet
   probe (`eco_floor_unviable`): template/prompt-template leak, code-REPL confusion, persona
   collapse, incoherence. Cheap regex heuristics first (code blocks, template tokens);
   optional LLM-judge later.
4. **VRAM measurement** — record peak VRAM per model via `nvidia-smi`. Makes the floor a
   measured fact, not a calc.
5. **Report** — markdown matrix (persona × model-size → pass/fail per failure class + peak
   VRAM column), written to `.local-notes/`.

**Floor verdict:** the floor model is the largest that (a) clears the quality bar fleet-wide
AND (b) has measured peak VRAM ≤ ~5.5 GB. If 4B clears → 8GB floor confirmed. If only 7-8B
clears quality but busts VRAM → floor moves to 12GB; revisit the Companion SKU market %.

**Scope cuts (YAGNI):** no GUI, no CI integration, no auto-tier-selection-on-init. Auto-tier
(detect the user's GPU at `hexis init`, pick the model tier) is a *follow-up* once the probe
says what the real floor is.

**Verify:** run the probe, get the matrix. 8GB floor confirmed or moved. That is the pass
condition for this round.

## 5. Competitive wedge

- **Hermes Agent** (Nous, MIT) — local-*capable* but local is an afterthought; real-world
  local experience is poor (confirmed first-hand). Hexis fork makes local first-class and
  tuned: power modes, fleet-on-one-GPU, graceful ECO floor — Hermes has none of it.
- **Upstream QuixiAI/Hexis** — cloud-capable, no fleet orchestration, no power modes. Our
  divergence IS the product.
- **Threat** (per research note §Threat read): the dangerous move is a competitor pairing a
  slick persona/distribution layer (e.g. OpenPersona) with an off-the-shelf memory backend
  (Zep/Cognee). They cannot cheaply replicate fleet-grade local orchestration — keep that
  sharp and make it legible as the differentiator.

---

## Footnote — BYOK ("bring your own key") positioning

BYOK already exists in the codebase (inherited from upstream: OpenAI / Anthropic / Ollama).
The question is visibility, not whether to add it.

- **Keep it in code.** Removing it is work for zero gain.
- **It dilutes only if headlined.** A sovereignty-branded product ("not your hardware") that
  features "paste an OpenAI key" in the onboarding happy-path contradicts its own pitch, and
  pushes the product into the red ocean of generic LLM frontends (LM Studio, OpenWebUI,
  SillyTavern) where it has no edge. For the Companion SKU it also half-breaks — frontier
  clouds content-flag RP/companion traffic.
- **Distinguish two kinds:**
  - *Custom OpenAI-compatible endpoint* (own llama-server, rented GPU, self-host) — on-brand,
    still sovereign; fine to surface.
  - *Managed frontier key* (OpenAI / Anthropic) — the diluting one. Keep, but bury under
    "Advanced → custom provider." Never in the tagline, onboarding, or marketing.
- **Honesty requirement:** if frontier BYOK is used, the UI must state plainly at the point
  of choice: "This sends your conversation to OpenAI — it leaves your machine." A
  sovereignty-branded product must not silently exfiltrate companion data.

Verdict: the feature does not dilute; *promoting* it does. Keep it as an unmarketed escape
hatch. Local is the identity and the default.
