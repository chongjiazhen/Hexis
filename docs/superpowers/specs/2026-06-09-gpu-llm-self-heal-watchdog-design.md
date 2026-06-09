# gpu-llm self-heal watchdog (F1) — design

**Date:** 2026-06-09
**Status:** approved, ready for writing-plans
**Scope:** one file — `hexis-vram-guard.ps1`

## Problem

On 2026-06-09 `:8080` (gpu-llm / ActiveBig) sat **dead for ~7.5h** while
`logs\current-mode.txt` said `prime`. `set-power-mode.ps1` had armed it
successfully at 09:59 (the marker is written only *after* the `/health` gate
passes — line 372→471), then the server **crashed silently** and nothing
re-armed it. embed (`:8081`) has `watch-embed.ps1`; gpu-llm had no equivalent.

Root cause (found same day, fixed by a separate commit pair — see below): a CUDA
`MUL_MAT_ID` crash on the 5060 Ti (Blackwell sm_120, PTX-JIT) triggered by
ctx-checkpoint restore feeding partial-prompt MoE batches on the A3B model.

## Relationship to the prevention pair (already shipped)

Two commits landed 2026-06-09 ~20:31 that fix the **root cause** at source:

- **llm-serve `0f69d5a`** — `models.json` `q36`: `extra_flags="--ctx-checkpoints 0"`
  (flows through `Build-RegistryFlags` into set-power-mode's GPU launch) +
  repoint heretic→APEX (kills model drift).
- **hexis `2457598`** — `start.ps1`: `--ctx-checkpoints 0` literal on its :8080
  launch + `$ChatRepo` sourced from `models.json` q36 + `-RedirectStandardError`.

Both :8080 launch paths (start.ps1 literal; set-power-mode via registry
`extra_flags`) now disable the crash trigger.

**This watchdog is the complementary RECOVERY layer**, not a duplicate:

| Layer | Owner |
|---|---|
| Prevention — stop the specific ctx-checkpoint crash | the pair above (done) |
| Recovery — re-arm `:8080` if it dies for **any** reason (OOM, driver TDR, other crash) | **this design** |

The known recurrence vector is plugged at source, so F1 is defense-in-depth, not
the primary fix. It still closes a real gap: not every future `:8080` death is a
ctx-checkpoint crash.

## Decision: extend `hexis-vram-guard.ps1` (not a standalone watchdog)

The guard is **already the power-mode authority**: polls every 4s, reads the mode
marker + `guard-triggered-eco.flag`, has resume detection, a single-instance
lock, and is kept alive by `ensure-guard.ps1` + the Hexis Guard Watchdog task. It
already calls `set-power-mode.ps1 prime`.

A standalone `watch-gpu.ps1` would be a **second actor** calling
`set-power-mode.ps1 prime`, racing the guard during its eco↔prime switches.
Folding the liveness check into the guard keeps **one** power-mode authority and
inherits all the guard's lifecycle plumbing for free. (Matches the
"invoke existing authority first / overreach check" rule.)

Re-arm authority is **single** — the guard. The watchdog re-arms (does not merely
surface).

## Loop integration

The liveness check is a **third concern** in the guard loop, evaluated every poll
*regardless* of the game/foreign-GPU trigger, but acting only in a safe window:

```
each poll (every $PollSeconds = 4s):
  ... existing trigger / re-arm-cooldown logic UNCHANGED ...

  # NEW: gpu-llm liveness self-heal
  mode = Get-Mode
  if mode != 'eco' AND NOT (Test-Path $EcoFlag) AND NOT $trig:
      if :8080 NOT listening:  $gpuDownHits++   else  $gpuDownHits = 0
      if $gpuDownHits >= $GpuDownSamples AND $reArmBudget > 0:
          Invoke-Prime               # existing func, -Wait, blocks ~4min
          # success: marker stays prime, :8080 healthy next poll -> hits reset, budget restored
          # failure: $reArmBudget--, log loud, backoff
  else:
      $gpuDownHits = 0               # eco / guard-managed / game present -> not our job
```

### Guards against fighting existing paths
- `mode != 'eco'` — never touch a deliberate or guard-caused ECO.
- `NOT $EcoFlag` — guard is mid eco-switch or owns the current ECO; back off (the
  flag is written *before* the switch in `Invoke-Eco`).
- `NOT $trig` — a game / CUDA app is present; the trigger path will win and switch
  to ECO. Liveness stays out.

## Debounce, cap, cooldown

**Down-confirm (`$GpuDownSamples = 15`)** — ~60s continuous down (15 × 4s) before
acting. Why 60s:
- Much longer than the trigger debounce (`$ConsecutiveSamples = 2` ≈ 8s), so a
  concurrent game-trigger **always preempts** a re-arm (eco switch wins the race).
- Rides out a transient blip; still beats the old 7.5h gap by orders of magnitude.
- No cold-load false positive: `marker=prime` is written only *after* `:8080`
  passes `/health`, so `mode!=eco` means it was alive at marker-write — a later
  down is real death, not a slow load.

**Re-arm budget (`$ReArmBudget = 3`)** — consecutive *failed* re-arms:
- Each `Invoke-Prime` runs `-Wait` (blocks the loop ~4min through its own health
  gate), so attempts serialize — no double-arm / CUDA-OOM stack.
- Success → `:8080` healthy next poll → reset budget to 3, `$gpuDownHits = 0`.
- Failure (set-power-mode throws / health timeout) → `budget--`, log loud,
  `Start-Sleep` backoff (60s) before the loop can retry.
- Budget 0 → **stop re-arming**, log
  `[gpu-heal] re-arm failed 3x; giving up until :8080 recovers or 30m cooldown`.

Because re-arm goes through `set-power-mode prime` — which now launches with
`--ctx-checkpoints 0` via the registry — a re-arm resurrects a **hardened**
server, so the budget is far more likely to succeed instead of re-crashing on the
same trigger.

**Budget reset (escape the gave-up state)** — restore budget to 3 when *either*:
- `:8080` comes back healthy by any means (manual `set-power-mode prime`, boot), or
- `$ReArmCooldownMinutes = 30` elapsed since giving up — retry once more in case
  the OOM cleared.

**Resume interaction** — existing resume detection (`$resumed`, poll-gap > 180s)
already skips the PRIME re-arm cooldown for guard-caused ECO. For liveness, a
resume also resets `$gpuDownHits` (don't count the sleep gap as downtime) and
refreshes the budget. **Clock-drift safety:** the cooldown timer and resume both
use wall-clock `Get-Date`, which leaps on host sleep / GPU-mode switch — the
guard already absorbs this via the `$resumed` poll-gap check, so routing the
cooldown reset through the same resume path means a clock leap can't strand the
guard in the gave-up state. No new clock dependency.

## Config block (hand-edit, in the guard's CONFIG section)

```powershell
$GpuPort              = 8080   # ActiveBig liveness port. Hand-synced to psd1
                              # BigPort (single constant, like $LlamaExeName) -
                              # the guard does not re-read power-profiles.psd1.
$GpuDownSamples       = 15     # ~60s continuous down before re-arm (15 * $PollSeconds)
$ReArmBudget          = 3      # consecutive failed re-arms before giving up
$ReArmCooldownMinutes = 30     # after giving up, retry once more this long later
```

`$PollSeconds` (4s) is reused.

## New loop state (init near `$armed` / `$hits`)

```powershell
$gpuDownHits = 0
$reArmBudget = $ReArmBudget
$gaveUpAt    = $null
```

## Liveness probe

TCP-listen check on `:8080` via `Get-NetTCPConnection` (same pattern already in
`Get-Mode`), **not** HTTP `/health`. Rationale: the 7.5h gap was *not listening at
all*; a wedged-but-listening server is a different failure out of scope here. TCP
is cheap and avoids a 5s HTTP timeout inside a 4s loop.

## Logging

Reuse the guard's `Log()` → `logs\vram-guard.log`, prefix `[gpu-heal]`.
Transitions logged: down-detected, re-arm-firing, re-arm-ok, re-arm-failed (n/3),
gave-up, budget-reset. (start.ps1 + set-power-mode already write
`logs\serve-8080-stderr.log` for the crash stderr itself — F1 adds no stderr
capture.)

## Scope boundary

Zero changes to `set-power-mode.ps1`, `ensure-guard.ps1`, `start-all.ps1`, or the
scheduled task. The guard is already auto-started + kept alive; folding in means
F1 inherits all of that. **One file touched: `hexis-vram-guard.ps1`.**

## Success criteria

- With `mode=prime` and `:8080` killed by hand, the guard re-arms it within
  ~60s + cold-load, and `logs\vram-guard.log` shows the `[gpu-heal]` transition.
- A manual `set-power-mode.ps1 eco` (marker=eco, no flag) is **never** re-armed.
- A guard-caused ECO (game running, flag present) is **never** re-armed by the
  liveness path while the game runs.
- Repeated re-arm failure stops after 3 attempts and logs the give-up, then
  retries after 30m or on `:8080` recovery.
