# probe-eco — persona reply-quality probe

Brackets model tiers to confirm the Companion-SKU VRAM floor.
See `.local-notes/strategy-local-llm-positioning.md` §4.

## One-tier run

1. Re-arm `ActiveBig` to the tier under test: edit `power-profiles.psd1`,
   then `set-power-mode.ps1 eco` then `set-power-mode.ps1 prime`.
2. Confirm with `hexis-status.ps1` (server alias == char DB `llm.chat`).
3. Run: `./probe-all.sh --model <label>`  (label e.g. 1b | 3b | 4b | 7b)
   Output: `probes/<label>/<persona>.json` + `probes/<label>/_vram.txt`.

## Aggregate after all tiers are run

`python aggregate.py`  ->  writes `.local-notes/probe-tier-matrix.md`.

## Floor verdict

The floor model is the largest tier that is clean fleet-wide AND whose
measured peak VRAM is <= ~5500 MiB. If only 7b clears quality but busts
VRAM, the Companion floor moves from 8GB to 12GB — revisit the SKU market %.
