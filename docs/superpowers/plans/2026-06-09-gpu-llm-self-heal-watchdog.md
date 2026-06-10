# gpu-llm self-heal watchdog (F1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-arm a silently-dead `:8080` (gpu-llm) by folding a liveness self-heal into the existing `hexis-vram-guard.ps1` poll loop.

**Architecture:** A pure decision function `Get-GpuHealDecision` (own file, Pester-tested) maps the current poll state to an action (`rearm` / `none`) plus the next counter/budget. `hexis-vram-guard.ps1` dot-sources it and supplies the impure inputs (mode marker, eco-flag, `:8080` TCP probe, resume + cooldown timers) and executes the side effect (`Invoke-Prime`). One power-mode authority (the guard); recovery layer complementing the 2026-06-09 ctx-checkpoint prevention pair.

**Tech Stack:** PowerShell (pwsh 7 / Windows PowerShell 5.1), Pester 3.4 (pure-function unit tests, no mocks).

**Spec:** `docs/superpowers/specs/2026-06-09-gpu-llm-self-heal-watchdog-design.md`

---

## File Structure

> **Note:** `guard-decisions.ps1` + `guard-decisions.Tests.ps1` already exist (created by the 2026-06-09 eco-retry hotfix, commit `9053a25`) and the guard already dot-sources `guard-decisions.ps1`. F1 extends them rather than creating new files.

- **Modify** `guard-decisions.ps1` — append pure `Get-GpuHealDecision` (no side effects).
- **Modify** `guard-decisions.Tests.ps1` — append the gpu-heal truth-table Describe block (its top already dot-sources `guard-decisions.ps1`).
- **Modify** `hexis-vram-guard.ps1` — add config; add loop state; add the liveness self-heal block. (Dot-source line already present.)

No other files change (`set-power-mode.ps1`, `ensure-guard.ps1`, `start-all.ps1`, the scheduled task all untouched — the guard is already auto-started and kept alive).

---

### Task 1: Pure decision function `Get-GpuHealDecision`

**Files:**
- Modify: `guard-decisions.ps1` (append `Get-GpuHealDecision`)
- Test: `guard-decisions.Tests.ps1` (append the gpu-heal `Describe` block)

**Decision contract (returns a PSCustomObject):**
- `Action` — `'rearm'` or `'none'`
- `NewDownHits` — updated consecutive-down counter
- `NewBudget` — updated remaining re-arm budget
- `Reason` — one of `out-of-window | resume-reset | healthy | down-debouncing | down-threshold | budget-exhausted`

- [ ] **Step 1: Write the failing test (full truth table)**

Append to `guard-decisions.Tests.ps1` (the dot-source of `guard-decisions.ps1` is already at the top of that file — do not repeat it):

```powershell
# Defaults mirror the guard config: 15-sample debounce, budget 3.
function New-Args {
    param(
        [string]$Mode = 'prime', [bool]$EcoFlagPresent = $false, [bool]$Trig = $false,
        [bool]$GpuListening = $false, [bool]$Resumed = $false, [bool]$CooldownElapsed = $false,
        [int]$GpuDownHits = 0, [int]$ReArmBudget = 3, [int]$GpuDownSamples = 15, [int]$ReArmBudgetMax = 3
    )
    return @{
        Mode = $Mode; EcoFlagPresent = $EcoFlagPresent; Trig = $Trig;
        GpuListening = $GpuListening; Resumed = $Resumed; CooldownElapsed = $CooldownElapsed;
        GpuDownHits = $GpuDownHits; ReArmBudget = $ReArmBudget;
        GpuDownSamples = $GpuDownSamples; ReArmBudgetMax = $ReArmBudgetMax
    }
}

Describe 'Get-GpuHealDecision' {

    It 'does nothing in ECO and resets the down counter' {
        $a = New-Args -Mode 'eco' -GpuDownHits 9 -GpuListening $false
        $d = Get-GpuHealDecision @a
        $d.Action      | Should Be 'none'
        $d.NewDownHits | Should Be 0
        $d.Reason      | Should Be 'out-of-window'
    }

    It 'does nothing while a guard-caused ECO flag is present' {
        $a = New-Args -EcoFlagPresent $true -GpuDownHits 20
        $d = Get-GpuHealDecision @a
        $d.Action | Should Be 'none'
        $d.Reason | Should Be 'out-of-window'
    }

    It 'does nothing while a game/foreign-GPU trigger is active' {
        $a = New-Args -Trig $true -GpuDownHits 20
        $d = Get-GpuHealDecision @a
        $d.Action | Should Be 'none'
        $d.Reason | Should Be 'out-of-window'
    }

    It 'on resume resets hits and refreshes budget' {
        $a = New-Args -Resumed $true -GpuDownHits 9 -ReArmBudget 0
        $d = Get-GpuHealDecision @a
        $d.Action      | Should Be 'none'
        $d.NewDownHits | Should Be 0
        $d.NewBudget   | Should Be 3
        $d.Reason      | Should Be 'resume-reset'
    }

    It 'when :8080 is healthy resets hits and restores budget' {
        $a = New-Args -GpuListening $true -GpuDownHits 9 -ReArmBudget 0
        $d = Get-GpuHealDecision @a
        $d.Action      | Should Be 'none'
        $d.NewDownHits | Should Be 0
        $d.NewBudget   | Should Be 3
        $d.Reason      | Should Be 'healthy'
    }

    It 'increments the counter while down below threshold (no action)' {
        $a = New-Args -GpuDownHits 5
        $d = Get-GpuHealDecision @a
        $d.Action      | Should Be 'none'
        $d.NewDownHits | Should Be 6
        $d.Reason      | Should Be 'down-debouncing'
    }

    It 're-arms when down reaches threshold with budget left' {
        $a = New-Args -GpuDownHits 14 -ReArmBudget 3
        $d = Get-GpuHealDecision @a
        $d.Action      | Should Be 'rearm'
        $d.NewDownHits | Should Be 15
        $d.NewBudget   | Should Be 2
        $d.Reason      | Should Be 'down-threshold'
    }

    It 'gives up (no action) when at threshold but budget exhausted and no cooldown' {
        $a = New-Args -GpuDownHits 20 -ReArmBudget 0 -CooldownElapsed $false
        $d = Get-GpuHealDecision @a
        $d.Action    | Should Be 'none'
        $d.NewBudget | Should Be 0
        $d.Reason    | Should Be 'budget-exhausted'
    }

    It 'grants a single retry when budget exhausted but cooldown elapsed' {
        $a = New-Args -GpuDownHits 20 -ReArmBudget 0 -CooldownElapsed $true
        $d = Get-GpuHealDecision @a
        $d.Action    | Should Be 'rearm'
        $d.NewBudget | Should Be 0
        $d.Reason    | Should Be 'down-threshold'
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path .\guard-decisions.Tests.ps1"`
Expected: FAIL — `Get-GpuHealDecision` is not recognized (function not yet added).

- [ ] **Step 3: Write the minimal implementation**

Append to `guard-decisions.ps1`:

```powershell
function Get-GpuHealDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Mode,
        [bool]$EcoFlagPresent,
        [bool]$Trig,
        [bool]$GpuListening,
        [bool]$Resumed,
        [bool]$CooldownElapsed,
        [int]$GpuDownHits,
        [int]$ReArmBudget,
        [int]$GpuDownSamples,
        [int]$ReArmBudgetMax
    )

    # Out-of-window: deliberate/guard ECO or a game/CUDA trigger present. The
    # liveness path stays out (the trigger path owns eco<->prime here). Reset the
    # down counter so a future in-window death starts fresh.
    if ($Mode -eq 'eco' -or $EcoFlagPresent -or $Trig) {
        return [pscustomobject]@{ Action='none'; NewDownHits=0; NewBudget=$ReArmBudget; Reason='out-of-window' }
    }

    # Resume from sleep / long switch: do not count the gap as downtime; refresh
    # budget so a pre-sleep give-up does not strand the guard.
    if ($Resumed) {
        return [pscustomobject]@{ Action='none'; NewDownHits=0; NewBudget=$ReArmBudgetMax; Reason='resume-reset' }
    }

    # In-window and :8080 healthy: reset counter, restore budget (covers external
    # recovery - manual `set-power-mode prime`, boot).
    if ($GpuListening) {
        return [pscustomobject]@{ Action='none'; NewDownHits=0; NewBudget=$ReArmBudgetMax; Reason='healthy' }
    }

    # In-window and :8080 down: advance the debounce counter.
    $hits   = $GpuDownHits + 1
    $budget = $ReArmBudget
    # Budget exhausted but the cooldown elapsed: grant exactly one retry.
    if ($budget -le 0 -and $CooldownElapsed) { $budget = 1 }

    if ($hits -ge $GpuDownSamples -and $budget -gt 0) {
        return [pscustomobject]@{ Action='rearm'; NewDownHits=$hits; NewBudget=($budget - 1); Reason='down-threshold' }
    }
    if ($hits -ge $GpuDownSamples) {
        return [pscustomobject]@{ Action='none'; NewDownHits=$hits; NewBudget=$budget; Reason='budget-exhausted' }
    }
    return [pscustomobject]@{ Action='none'; NewDownHits=$hits; NewBudget=$budget; Reason='down-debouncing' }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path .\guard-decisions.Tests.ps1"`
Expected: PASS — all tests passing (the pre-existing eco-trigger tests plus the 9 new gpu-heal tests), 0 failed.

- [ ] **Step 5: Commit**

```bash
git add guard-decisions.ps1 guard-decisions.Tests.ps1
git commit -m "feat(ops): pure gpu-llm self-heal decision fn + Pester tests"
```

---

### Task 2: Dot-source helper + add config and loop state to the guard

**Files:**
- Modify: `hexis-vram-guard.ps1` (top-of-file dot-source + CONFIG block + loop-state init)

This task adds wiring only — no behavior change yet. Verified by a parse check.

- [ ] **Step 1: Confirm the helper is dot-sourced (already present)**

The eco-retry hotfix already added this line after `$Root = ...`:

```powershell
. (Join-Path $Root "guard-decisions.ps1")   # pure decision fns (testable)
```

No change needed — `Get-GpuHealDecision` (added in Task 1) lives in the same file, so it is already in scope. Skip to Step 2.

- [ ] **Step 2: Add F1 config to the CONFIG block**

In the `# ----------------- CONFIG (hand-edit) -----------------` block, after the
`$PrimeRearmMinutes = 15` line, add:

```powershell
# --- gpu-llm liveness self-heal (F1) ---
# Re-arm a silently-dead :8080 (gpu-llm crashed post-arm; marker still PRIME).
# Recovery layer; the ctx-checkpoint crash itself is prevented at source (start.ps1
# + models.json `--ctx-checkpoints 0`). $GpuPort is hand-synced to power-profiles.psd1
# BigPort (one constant, like $LlamaExeName - the guard does not import the psd1).
$GpuPort              = 8080   # ActiveBig liveness port (== psd1 BigPort)
$GpuDownSamples       = 15     # ~60s continuous down before re-arm (15 * $PollSeconds)
$ReArmBudget          = 3      # consecutive failed re-arms before giving up
$ReArmCooldownMinutes = 30     # after giving up, grant one more retry this long later
```

- [ ] **Step 3: Initialize loop state**

Find the loop-state init lines (just before `try {` that opens the `while` loop):

```powershell
$armed = $true
$hits  = 0
$clearSince = $null   # timestamp GPU first went clear; $null while triggered
$lastPoll = Get-Date  # for wake detection: a big gap between polls = host slept
```

Immediately after them, add:

```powershell
# F1 gpu-llm liveness state
$gpuDownHits = 0
$reArmBudget = $ReArmBudget
$gaveUpAt    = $null   # set when budget hits 0; drives the cooldown retry window
```

- [ ] **Step 4: Verify the script still parses**

Run:
```bash
pwsh -NoProfile -Command "$null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw .\hexis-vram-guard.ps1), [ref]$null); 'parse-ok'"
```
Expected: prints `parse-ok` with no parse errors.

- [ ] **Step 5: Commit**

```bash
git add hexis-vram-guard.ps1
git commit -m "feat(ops): wire gpu-heal helper + config/state into vram-guard"
```

---

### Task 3: Add the liveness self-heal block to the poll loop

**Files:**
- Modify: `hexis-vram-guard.ps1` (inside the `while ($true)` loop, after the existing trigger/clear if/else, before `Start-Sleep`)

- [ ] **Step 1: Insert the liveness block**

In the loop, locate the end of the existing trigger handling — the block that
closes the big `if ($trig) { ... } else { ... }` — immediately before:

```powershell
        Start-Sleep -Seconds $PollSeconds
```

Insert this block just above that `Start-Sleep`:

```powershell
        # ---- gpu-llm liveness self-heal (F1) ----
        # Runs every poll regardless of $trig. Acts only in-window (mode != eco,
        # no eco-flag, no game trigger). The pure Get-GpuHealDecision owns the
        # truth table; here we gather impure inputs and run the side effect.
        $modeNow = Get-Mode
        $ecoFlagPresent = Test-Path $EcoFlag
        $gpuUp = [bool](Get-NetTCPConnection -LocalPort $GpuPort -State Listen -ErrorAction SilentlyContinue)
        $cooldownElapsed = $false
        if ($gaveUpAt) {
            $cooldownElapsed = (((Get-Date) - $gaveUpAt).TotalMinutes -ge $ReArmCooldownMinutes)
        }

        $decision = Get-GpuHealDecision -Mode $modeNow -EcoFlagPresent $ecoFlagPresent `
            -Trig $trig -GpuListening $gpuUp -Resumed $resumed -CooldownElapsed $cooldownElapsed `
            -GpuDownHits $gpuDownHits -ReArmBudget $reArmBudget `
            -GpuDownSamples $GpuDownSamples -ReArmBudgetMax $ReArmBudget

        $gpuDownHits = $decision.NewDownHits
        $reArmBudget = $decision.NewBudget

        if ($decision.Action -eq 'rearm') {
            # A cooldown-granted retry comes in with the give-up clock already set;
            # restart it so a failed retry waits another full cooldown, not re-fires
            # every poll.
            if ($cooldownElapsed -and $gaveUpAt) { $gaveUpAt = Get-Date }
            Log ("[gpu-heal] :{0} down >= {1} samples (mode={2}) - re-arming (budget left {3})" -f $GpuPort, $GpuDownSamples, $modeNow, $reArmBudget)
            Invoke-Prime
            # Invoke-Prime blocks ~4min (-Wait through set-power-mode's health gate).
            # Reset the poll baseline so that gap is NOT misread as a host-sleep
            # resume next iteration (which would wrongly reset hits + budget).
            $lastPoll = Get-Date
        }
        elseif ($decision.Reason -eq 'budget-exhausted') {
            if (-not $gaveUpAt) {
                $gaveUpAt = Get-Date
                Log ("[gpu-heal] re-arm failed {0}x; giving up until :{1} recovers or {2}m cooldown" -f $ReArmBudget, $GpuPort, $ReArmCooldownMinutes)
            }
        }
        elseif ($decision.Reason -in @('healthy','resume-reset')) {
            if ($gaveUpAt) {
                $gaveUpAt = $null
                Log ("[gpu-heal] :{0} recovered ({1}) - budget reset, give-up cleared" -f $GpuPort, $decision.Reason)
            }
        }
```

- [ ] **Step 2: Verify the script still parses**

Run:
```bash
pwsh -NoProfile -Command "$null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw .\hexis-vram-guard.ps1), [ref]$null); 'parse-ok'"
```
Expected: prints `parse-ok` with no parse errors.

- [ ] **Step 3: Re-run the pure-function tests (no regression)**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path .\guard-decisions.Tests.ps1"`
Expected: PASS — all tests passing (eco-trigger + gpu-heal; the helper is unchanged; this confirms the dot-source path still resolves).

- [ ] **Step 4: Live verification — re-arm a hand-killed :8080**

> Prereq: fleet up in PRIME (`logs\current-mode.txt` line 1 = `prime`), guard
> running (`ensure-guard.ps1` reports a live PID), `:8080` healthy.

Kill the GPU server by hand, then watch the guard heal it (~60s debounce + ~4min cold load):

```bash
pwsh -NoProfile -Command "Stop-Process -Id (Get-NetTCPConnection -LocalPort 8080 -State Listen).OwningProcess -Force"
pwsh -NoProfile -Command "Get-Content .\logs\vram-guard.log -Wait -Tail 5"
```

Expected log sequence:
- `[gpu-heal] :8080 down >= 15 samples (mode=prime) - re-arming (budget left 2)`
- (after cold load) next poll observes `:8080` listening — no further `[gpu-heal]` re-arm lines.

Confirm `:8080` is back:
```bash
pwsh -NoProfile -Command "(Invoke-WebRequest http://127.0.0.1:8080/health -UseBasicParsing -TimeoutSec 5).StatusCode"
```
Expected: `200`.

- [ ] **Step 5: Live verification — never fights ECO**

With the fleet in ECO (`set-power-mode.ps1 eco` by hand → marker=eco, no flag),
confirm the guard does NOT re-arm:

```bash
pwsh -NoProfile -Command "Get-Content .\logs\vram-guard.log -Wait -Tail 5"
```
Expected: no `[gpu-heal] ... re-arming` line appears (mode=eco is out-of-window).
Restore with `set-power-mode.ps1 prime` when done.

- [ ] **Step 6: Commit**

```bash
git add hexis-vram-guard.ps1
git commit -m "feat(ops): gpu-llm self-heal re-arm in vram-guard loop (F1)"
```

---

## Self-Review

**Spec coverage:**
- Extend `hexis-vram-guard.ps1`, single authority → Task 2/3 (no new daemon). ✓
- Loop integration with `mode!=eco AND !flag AND !trig` window → Task 1 (`out-of-window`) + Task 3 wiring. ✓
- Debounce 15 samples → `$GpuDownSamples`, Task 1 threshold tests. ✓
- Budget 3, decrement on rearm, restore on healthy/resume → Task 1 tests + Task 3 edges. ✓
- Cooldown 30m single retry → Task 1 `CooldownElapsed` test + Task 3 clock + clock-restart. ✓
- Resume resets hits + budget; clock-drift safety via shared `$resumed` → Task 1 `resume-reset` + Task 3 `$lastPoll` reset after `Invoke-Prime`. ✓
- TCP probe not HTTP → Task 3 `Get-NetTCPConnection`. ✓
- Logging `[gpu-heal]` to `vram-guard.log` → Task 3. ✓
- Scope: `hexis-vram-guard.ps1` modified; `guard-decisions.ps1`/tests extended (pre-existing from the eco-retry hotfix) → File Structure. ✓
- Success criteria (re-arm hand-killed :8080; never re-arm manual/game ECO; give up after 3 + retry) → Task 3 Steps 4-5 live + Task 1 unit. ✓

**Placeholder scan:** none — every step has concrete code/commands.

**Type/name consistency:** `Get-GpuHealDecision` params (`Mode/EcoFlagPresent/Trig/GpuListening/Resumed/CooldownElapsed/GpuDownHits/ReArmBudget/GpuDownSamples/ReArmBudgetMax`) match the Task 3 call site exactly. Return fields (`Action/NewDownHits/NewBudget/Reason`) match consumers. Config names (`$GpuPort/$GpuDownSamples/$ReArmBudget/$ReArmCooldownMinutes`) and state (`$gpuDownHits/$reArmBudget/$gaveUpAt`) consistent across Tasks 2-3.

**Note on test execution:** Pester 3.4 syntax (`Should Be`; splat a hashtable variable — `$a = New-Args ...; Get-GpuHealDecision @a`). pwsh 7.6 resolves Pester 3.4.0 on this box. If a worker's pwsh resolves a Pester 5.x instead, run under Windows PowerShell 5.1: `powershell -NoProfile -Command "Invoke-Pester -Path .\guard-decisions.Tests.ps1"` (3.4 is the 5.1 built-in).
