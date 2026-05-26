# Power Modes: ECO / PRIME — PARKED DESIGN

**Status:** ENGINE BUILT + RUNTIME-TESTED 2026-05-16 (engine `f11193d`; fixes
`9512102` native-stderr/`$pid`, `fbc37f2` Invoke-Docker `$args`, + plan BOM
utf-8-sig). Full PRIME->ECO->PRIME round-trip verified: GPU servers
killed/relaunched, embed `:8081` + nano `:8082` untouched, all 4 instance DBs
flipped consistently (chat/heartbeat/subconscious). Desktop buttons live
(`Hexis ECO`/`Hexis PRIME`). **Phase-2 GUI launcher BUILT** (`dd8d4d9`),
then **rewritten to the ActiveBig single-GPU-slot schema** (`a1ce053`
engine + this commit GUI): `hexis-launcher.ps1` WinForms now has ONE
`ActiveBig` selector (dropdown of `BigModels` keys, shows alias + on-disk/-hf
source) plus a per-character `gpu`/`nano` `Tier` toggle, PRIME/ECO +
Sam-piggyback. Apply rewrites `power-profiles.psd1` in the FULL ActiveBig
schema (every `BigModels` entry preserved, `Repo` never dropped; the chosen
entry's empty `Path` is filled from the HF cache when the gguf is present so
`-m` beats the `-hf` fallback), then calls the engine. `Hexis Launcher`
desktop shortcut. Engine `Ensure-GpuServer` takes a disk `Path` (-m) or
`Repo` (-hf). Write-Profile round-trip headless-verified (dot-source the
launcher = no GUI): psd1 parses, `BigModels[ActiveBig]` resolves, tiers/keys
preserved, `set-power-mode prime`+`eco` consume it clean (arm/kill BigPort).
The old per-char-Path Apply hazard is resolved; the hazard-warning header is
gone. Canonical editable source is `power-profiles.psd1` (this doc is
rationale/history).

Engine artifacts: `power-profiles.psd1` (source of truth), `set-power-mode.ps1`
`<eco|prime>`, `scripts/set_power_mode.py` (asyncpg flip), nano `:8082` added to
`start.ps1`, PRIME-normalize in `start-all.ps1`, `make-power-shortcuts.ps1`
(Desktop ECO/PRIME buttons). Per-char: Sam=Vesper-12B `:8080`,
Baymax=Qwen2.5-3B `:8083`, Rocky/TARS=nano `:8082`. ECO kills 8080+8083.

Phase 2 GUI (ActiveBig rewrite): PowerShell WinForms — a single `ActiveBig`
combo (the GPU model all gpu-tier chars share on `BigPort`) + a per-character
`gpu`/`nano` `Tier` grid; disk-scan of `*.gguf` (HF cache
`C:\Users\User\.cache\huggingface\hub`) is repurposed to back-fill the chosen
entry's empty `Path`. Apply writes the full ActiveBig `power-profiles.psd1`
then calls `set-power-mode.ps1`. GUI never holds logic; psd1 stays canonical +
hand-editable (the redundancy). `Write-Profile` is single-sourced and
dot-source-testable without rendering the form.

Original design analysis below (kept for the why).

**Decisions (2026-05-16):**
- PRIME shape = **Mode-A (concurrent)**: Sam-12B `:8080` + Baymax-3B `:8083`
  both VRAM-resident. Confirm GPU VRAM fits 12B Q6_K + 3B + embed; fall back to
  Mode-B only on OOM.
- Sam-exception detection = **NO daemon/poller** (rejected: flaky, races,
  mispoint risk, always-on process for a human-known trigger). Use manual
  `-SamEndpoint`/`-SamModel` arg, OR a one-shot probe of a known port list at
  switch time only (`-AutoSam`). Choose manual vs one-shot at build.

## Purpose

Free GPU VRAM on demand for VRAM-heavy host work (video editing, games, image-gen
models) **without killing the agents**. Agents stay alive on a tiny CPU model;
optionally one agent (Sam) piggybacks whatever heavy model is already loaded for
your own use. A second mode restores full per-character models.

## Naming

`eco` (low-power) / `prime` (full). NOTE collision: Hexis already has an internal
**"energy"** concept (per-agent action budget — observe/recall/reach-out costs).
Do NOT name these "energy mode" — it will confuse logs, docs, and agent reasoning.
`eco`/`prime` are deliberately distinct from "energy".

## Verified fact (decides the whole mechanism)

Workers read LLM config **live, per call** — no worker-startup cache:
- Heartbeat: `services/external_calls.py:152` (`load_llm_config(conn, "llm.heartbeat")`)
  immediately before each LLM call. Same per-op pattern at :179, :219, :260, etc.
- Chat: `services/agent.py:351,530`. Subconscious: `services/subconscious.py:171`.
- `load_llm_config` = live `SELECT get_config($1)` per call (`core/llm_config.py:111`).

**Implication:** rewriting `config.llm.{chat,heartbeat,subconscious}` in an
instance DB takes effect on the **next** heartbeat/chat. **No `docker compose
restart` needed.** In-flight calls finish on old config (transient, stateless/ACID
— acceptable). Mode switch = pure SQL flip + GPU server arm/kill.

## Architecture

- **Always-on base stack** (add nano to `start.ps1`; `start-all.ps1` inherits via
  delegation):
  - `:8080` chat-GPU llama-server (heavy; Sam's model in PRIME)
  - `:8081` embed llama-server (embeddinggemma-300M) — **SACRED, never un-armed
    in any mode.** Killing it blinds all 4 agents: no recall, `memories` insert
    fails (embedding NOT NULL). ~0.5GB, negligible vs games.
  - `:8082` **nano CPU-1B** llama-server, `--n-gpu-layers 0 --parallel 1
    --ctx-size 4096`. Always resident. Cost ~1-2GB RAM, ~0 GPU, idle CPU ~0
    (spikes only on inference). This is the floor every agent can always fall to.
- Embeddings are a Postgres GUC (`app.embedding_service_url`, baked at db-container
  start) — NOT in `llm.*`, not per-call swappable, and never needs to be. Constant
  both modes.
- **Mode switch never touches the nano.** It only (a) arms/kills GPU servers and
  (b) SQL-flips the 4 instance DBs' `llm.*`. Config flip alone does NOT free VRAM
  — a resident-but-unused 12B still holds it — so ECO must explicitly *kill* the
  GPU server(s).

## Per-character default model map (EDITABLE — source of truth)

Tweak this table; the switch script reads a profile file derived from it.

| Instance (DB)        | Character | PRIME model    | Tier | Where it runs (PRIME) | ECO model        |
|----------------------|-----------|----------------|------|-----------------------|------------------|
| `hexis_memory`       | Sam       | Vesper-12B     | 12B  | GPU `:8080`           | nano-1B (or Sam-exception, see below) |
| `hexis_baymax`       | Baymax    | llama-3B       | 3B   | GPU `:8083` (new)     | nano-1B          |
| `hexis_rocky`        | Rocky     | nano_imp-1B    | 1B   | CPU `:8082` (= nano)  | nano-1B          |
| `hexis_tars`         | TARS      | nano_imp-1B    | 1B   | CPU `:8082` (= nano)  | nano-1B          |

Notes:
- Rocky/TARS default = the always-on CPU nano in BOTH modes → they need no GPU
  server ever. Only Sam (12B) and Baymax (3B) consume GPU in PRIME.
- Exact GGUF repos TBD at implement time: Vesper-12B =
  `mradermacher/Hexis-Vesper-12B-i1-GGUF:Q6_K` (already in `start.ps1`); llama-3B
  repo = TBD; nano_imp-1B repo = TBD.
- File format for the switch script: a flat human-editable profile file
  (JSON, or `.psd1`/INI for inline comments — decide at build). One block per
  instance: `{ db, prime: {endpoint, model}, eco: {endpoint, model} }`.

## ECO behavior

1. Kill GPU server(s) (`:8080`, `:8083`) → VRAM freed for games/video/imggen.
2. SQL: for all 4 DBs, `set_config('llm.chat'|'llm.heartbeat'|'llm.subconscious',
   <nano :8082 cfg>)`.
3. Nano already running → agents keep heartbeating on CPU-1B. Slow tok/s, fine at
   60-min cadence.

### ECO + Sam-exception (opportunistic piggyback)

If a heavy model is **already loaded for your own use** (vibe-coding model,
SillyTavern RP-tuned model) on some port, Sam rides it — ≈0 marginal VRAM since
it's resident anyway; others stay on nano.

- Mechanism: `set-power-mode.ps1 eco -SamEndpoint http://127.0.0.1:<port>/v1
  -SamModel <name>` → flips ONLY `hexis_memory` `llm.*` to that endpoint/model;
  the other 3 → nano.
- Use a **manual arg**, not autoprobe — autodetecting "what model is loaded" on a
  random port is flaky and can mispoint Sam at the wrong server.
- Omit the arg → Sam also drops to nano (pure ECO).

## PRIME: Mode-A vs Mode-B — plain UX difference

Only Sam (12B `:8080`) + Baymax (3B `:8083`) are GPU-resident in PRIME; Rocky/TARS
are always nano. So the choice is really "do Sam's 12B and Baymax's 3B live in
VRAM at the same time?"

| | **Mode-A (concurrent)** | **Mode-B (serial / swap)** |
|---|---|---|
| Servers | Sam-12B + Baymax-3B both resident | One heavy model loaded at a time |
| UX | All characters responsive **at any moment**. Message any of them, no wait. True simultaneous presence. | Only the currently-loaded heavy character answers fast. Switching to the other heavy character = a **model-load delay** (unload + load GGUF, ~seconds to ~1 min). |
| Continuity | All heartbeats fire on schedule. | The not-loaded heavy character's heartbeat **stalls/fails** while its model is unloaded → it loses wall-clock continuity (time-froze gaps) until reloaded. |
| VRAM | Sum: Vesper-12B (~10GB Q6_K) + llama-3B (~2-3GB Q4) + embed (~0.5GB). Risks OOM if it doesn't all fit. | Only the largest single model + embed. Cheapest. |
| Feel | "Household of people all awake together." | "One person awake, others nap; waking another takes a beat." |

**Recommendation:** PRIME = **Mode-A** if VRAM fits (it's the whole point of
PRIME — everyone present). Fallback to Mode-B only if GPU can't hold 12B+3B+embed
concurrently. **OPEN: confirm GPU VRAM** — `start.ps1` already loads Vesper-12B
Q6_K + embed, implying >=12GB; need to confirm headroom for the extra 3B. If
tight: drop Baymax to Q4/smaller, or accept Mode-B for Baymax only (Sam stays
resident, Baymax swap-in on demand).

## Switch script spec (when resumed)

`set-power-mode.ps1 <eco|prime> [-SamEndpoint <url> -SamModel <name>]`:
1. Read editable profile file (per-instance prime/eco endpoints).
2. `prime`: ensure GPU servers up (`:8080` Sam-12B, `:8083` Baymax-3B per chosen
   Mode-A/B); SQL-flip 4 DBs to PRIME map.
3. `eco`: kill GPU servers; SQL-flip 4 DBs to nano `:8082` (Sam → SamEndpoint if
   given).
4. Never touch `:8081` embed or `:8082` nano.
5. No worker restart (verified). Idempotent. Log to `logs\`.

`set_config` call shape per DB (asyncpg, like `bootstrap_instance.py`):
`SELECT set_config('llm.chat', $cfg::jsonb)` for each of chat/heartbeat/subconscious.

## Open items before implement

1. Confirm GPU VRAM → PRIME Mode-A vs Mode-B (Baymax concurrent or swap).
2. GGUF repos: llama-3B, nano_imp-1B.
3. Profile file format: JSON vs `.psd1`/INI (inline comments for human edit).
4. Optional extra knob: in ECO, also raise non-Sam heartbeat interval
   (60→240min) / pause maintenance workers to cut CPU churn while gaming.

## Bottom line

Low-risk, ~2 scripts + 1 editable profile file + a one-line `start.ps1` addition
(nano `:8082`). No schema change, no worker restart. Blocked only on the 4 open
items above (mostly your model/VRAM choices). Related: `.local-notes/multi-char-modes.md`
(Mode A/B/C deployment shapes), `.local-notes/wsl2-docker-migration.md`.

## `power-profiles.psd1` provenance (moved here 2026-05-26)

`hexis-launcher.ps1` Apply rewrites `power-profiles.psd1` end-to-end (the GUI
is just another editor of the same store), so any prose comments inside the
psd1 evaporate on the next Apply. Provenance that survives launcher
overwrites lives here.

### Schema history

- **2026-05-19, commit `d7d2744`** — collapsed `BigModels` from per-entry
  hashtables (`Alias`/`Path`/`Repo`) to bare key pointers (`@{}`). KEY is now
  the `C:\llm-serve\models.json` short key; `set-power-mode.ps1`
  (`Resolve-BigModel` / `Resolve-RegistryGguf`) resolves alias + gguf path +
  serve tuning from that single registry via HF-cache glob-walk
  (re-snapshot-safe). A key with no `models.json` entry, or whose gguf is
  absent from the HF cache, hard-fails cleanly. Legacy `Alias`/`Path`/`Repo`
  accepted only as fallback for un-backfilled keys. Motivation: pre-collapse
  entries hardcoded a frozen snapshot `Path` that Xet-hung on stale revs.

### `ActiveBig` history

- `ablx` (gemma-4-26B-A4B abliterix V6, IQ4_XS) — active 2026-05-20.
- `q36` (Qwen3.6-35B-A3B MoE) — active 2026-05-2X. Reason: dense 24B collapsed
  under fleet concurrency on `--parallel 1` (~6 instances share the slot,
  prompt-eval thrash → ~1 tok/s, truncated replies); MoE is ~8× cheaper
  per-token eval, absorbs the fleet. See CLAUDE.md "Dense vs MoE on 16 GB
  VRAM".

### Retired models (2026-05-19)

GGUFs offloaded for disk space; snapshot lifecycle owned by `llm-serve`:
`worldsim`, `pure-soul`, `sentient-mind`, `aeon27`.

To re-promote any of these: re-add the short-key to `BigModels`, ensure a
live `models.json` entry, ensure the gguf is in the HF cache, THEN flip
`ActiveBig`. Skipping any of those = hard-fail on next `set-power-mode prime`.

Remaining on disk: `ablx`, `q36`, `cydonia`.

### `Characters` — per-persona Tier overrides

`set-power-mode.ps1` defaults any running persona DB not listed in
`Characters` to `gpu` tier (shared `ActiveBig` on `BigPort`). Add an entry
ONLY when a new persona must be pinned to `nano` (CPU `:8082`) instead of
the GPU slot.

Convention violation = no-op at best, obscures the convention. The list is
exception-only.

Pruned 2026-05-20: Baymax / Rocky / TARS (frozen 2026-05-19, no containers),
Warden (inactive), Sam / ENI (default tier matched, entries were no-ops).

Currently empty (all live personas are `gpu`).
