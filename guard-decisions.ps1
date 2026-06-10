# guard-decisions.ps1 - pure decision functions for hexis-vram-guard.ps1.
#
# No side effects: each takes the current poll state and returns a decision. Kept
# separate so the guard's state machine is unit-testable (guard-decisions.Tests.ps1)
# without a running fleet. The guard supplies the impure inputs (Get-Mode, the
# process scan, timers) and performs the side effects (Invoke-Eco / Invoke-Prime).
#
# F1 gpu-llm self-heal: Get-GpuHealDecision (below) maps poll state -> rearm/none.

function Get-EcoTriggerDecision {
    # Decide what the eco-trigger path should do THIS poll, given the debounced
    # trigger state. Pure. Returns Action:
    #   'attempt-eco' - armed, debounce met, GPU still armed -> caller runs Invoke-Eco
    #   'already-eco' - armed, debounce met, but already ECO  -> nothing to switch
    #   'wait'        - not armed yet, or debounce not met    -> no action
    [CmdletBinding()]
    param(
        [bool]$Armed,
        [int]$Hits,
        [int]$Threshold,
        [AllowEmptyString()][string]$Mode
    )
    if (-not $Armed)          { return [pscustomobject]@{ Action = 'wait' } }
    if ($Hits -lt $Threshold) { return [pscustomobject]@{ Action = 'wait' } }
    # GPU-armed = any mode other than 'eco' (the 'prime' alias or a specific
    # BigModels key like 'q36'); all of them must flip to ECO under a trigger.
    if ($Mode -eq 'eco')      { return [pscustomobject]@{ Action = 'already-eco' } }
    return [pscustomobject]@{ Action = 'attempt-eco' }
}

function Get-ArmedAfterEco {
    # Compute the new $armed flag after an eco decision was acted on. THE fix:
    # a FAILED eco switch must keep the guard ARMED so the next poll retries. The
    # prior loop disarmed unconditionally, so one transient set-power-mode failure
    # (e.g. an Import-PowerShellDataFile module-autoload glitch) wedged the box in
    # PRIME until the trigger cleared - the GPU kept serving through an entire game
    # session. Pure.
    [CmdletBinding()]
    param(
        [ValidateSet('attempt-eco','already-eco')][string]$Action,
        [bool]$EcoSucceeded
    )
    switch ($Action) {
        'attempt-eco' { return (-not $EcoSucceeded) }  # success -> disarm; failure -> stay armed (retry)
        'already-eco' { return $false }                # already ECO; nothing to retry
    }
}

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
