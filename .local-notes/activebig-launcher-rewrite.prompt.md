# Task prompt — rewrite hexis-launcher.ps1 GUI to the ActiveBig schema

Paste the block below to a fresh Claude Code session started in `C:\hexis`.

---

You are working in `C:\hexis` (the Hexis cognitive-architecture project).
Follow this repo's `CLAUDE.md` conventions: conventional commit prefix
(`feat(scripts):` etc.), **never add a Co-Authored-By trailer**, call out any
change to `README.md` / `docker-compose.yml` / `db/*.sql`. Branch is
`home-rig-local`; commit directly there.

## Background (already done — do not redo)

`power-profiles.psd1` and `set-power-mode.ps1` were refactored to an
**ActiveBig single-GPU-slot** model (commit `a1ce053`). The box is a 16 GB
GPU: exactly one ~13 GB model fits in VRAM at a time. So:

- `power-profiles.psd1` now has top-level `BigPort` (8080), `ActiveBig`
  (a key string), and `BigModels` (a hashtable: key → `@{ Alias; Path; Repo }`,
  Path or Repo). Characters now carry only `Prime=@{ Tier='gpu'|'nano' }` —
  no per-character model `Path`/`Alias`/`Port` anymore.
- `set-power-mode.ps1` resolves `$P.BigModels[$P.ActiveBig]`, arms ONE shared
  `llama-server` on `BigPort` when PRIME and any char is `Tier='gpu'` (all
  gpu personas share it; persona is applied by Hexis at the conversation
  layer), and on ECO kills that single port. This consumer is correct — do
  not change it. Read it to learn the exact schema it expects.

## The problem to fix

`hexis-launcher.ps1` (the WinForms GUI) still writes the OLD schema:
per-character model dropdowns and `Write-Profile` emitting per-char
`Prime=@{ Tier; Alias; Path; Port }`. Running its **Apply** would clobber
`BigModels`/`ActiveBig` and break `set-power-mode.ps1`. `power-profiles.psd1`
currently carries a header comment warning operators not to run Apply.

## Your task

Rewrite `hexis-launcher.ps1` so the GUI reads and writes the ActiveBig
schema, removing the hazard. Required behavior:

1. Keep the ECO/PRIME mode radio.
2. Replace the per-character model dropdown with **one `ActiveBig` selector**
   (a single dropdown whose items are the `BigModels` keys; show
   Alias/quant for clarity). Seed it from the current `$P.ActiveBig`.
3. Per-character row becomes a **gpu / nano `Tier` toggle** (combo or
   checkbox), seeded from each char's current `Prime.Tier`.
4. Keep the disk-scan, but repurpose it: when the chosen `ActiveBig`'s
   `BigModels` entry has an empty `Path` and a matching `*.gguf` is found in
   the HF cache, fill that entry's `Path` on Apply (concrete `-m` beats the
   `-hf` Repo fallback). Do not drop `Repo`.
5. `Write-Profile` must emit the FULL new schema: unchanged top keys
   (`LlamaServer`, `PgDsnBase`, `DockerHost`, `Provider`, `ApiKeyEnv`,
   `Nano`, `Embed`), plus `BigPort`, `ActiveBig`, the entire `BigModels`
   table (preserved, with Path possibly filled), and `Characters` as
   `@{ Name; Db; Prime=@{ Tier } }`. Never silently drop a `BigModels` entry.
6. `$DefaultGpuPort` already contains `Warden = 8086`; `BigPort` is the
   single shared GPU port — keep the map only if still referenced, else
   remove dead code.
7. On successful Apply, **remove the hazard-warning lines from the
   `power-profiles.psd1` header** (the "DO NOT run ... Apply" paragraph),
   since the hazard is resolved. Leave the rest of the header.
8. Update `.local-notes/power-modes.md` if it documents the launcher/Apply
   flow.

## Success criteria (verify, show output)

- `Import-PowerShellDataFile -Path .\power-profiles.psd1` parses with no
  error after a GUI Apply, and `$P.BigModels[$P.ActiveBig]` resolves to a
  non-null entry.
- After Apply, `gpu`/`nano` tiers match what was selected; `BigModels` keys
  are all still present; a previously-empty Path is filled iff the file is
  on disk.
- `.\set-power-mode.ps1 prime` then `.\set-power-mode.ps1 eco` both run
  clean against the GUI-written psd1 (one server armed on `BigPort`, then
  killed). Capture the `[arm]`/`[kill]`/`[done]` lines.
- The psd1 header no longer contains the Apply-hazard warning.

Then commit (this repo's convention, no Co-Authored-By).

## Reference files

- `power-profiles.psd1` — current ActiveBig schema (the write target)
- `set-power-mode.ps1` — the consumer contract (read; do not modify)
- `hexis-launcher.ps1` — the file to rewrite
- `.local-notes/power-modes.md` — operator doc
