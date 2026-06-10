. (Join-Path $PSScriptRoot 'guard-decisions.ps1')

Describe 'Get-EcoTriggerDecision' {
    It 'waits when not armed' {
        (Get-EcoTriggerDecision -Armed $false -Hits 99 -Threshold 2 -Mode 'prime').Action | Should Be 'wait'
    }
    It 'waits when below the debounce threshold' {
        (Get-EcoTriggerDecision -Armed $true -Hits 1 -Threshold 2 -Mode 'prime').Action | Should Be 'wait'
    }
    It 'attempts eco when armed, debounced, and GPU armed (prime)' {
        (Get-EcoTriggerDecision -Armed $true -Hits 2 -Threshold 2 -Mode 'prime').Action | Should Be 'attempt-eco'
    }
    It 'treats a model-key mode as GPU-armed (attempts eco)' {
        (Get-EcoTriggerDecision -Armed $true -Hits 5 -Threshold 2 -Mode 'q36').Action | Should Be 'attempt-eco'
    }
    It 'is a no-op when already in eco' {
        (Get-EcoTriggerDecision -Armed $true -Hits 5 -Threshold 2 -Mode 'eco').Action | Should Be 'already-eco'
    }
}

Describe 'Get-ArmedAfterEco' {
    It 'disarms after a SUCCESSFUL eco switch' {
        Get-ArmedAfterEco -Action 'attempt-eco' -EcoSucceeded $true | Should Be $false
    }
    It 'STAYS ARMED after a FAILED eco switch so the next poll retries (regression guard)' {
        Get-ArmedAfterEco -Action 'attempt-eco' -EcoSucceeded $false | Should Be $true
    }
    It 'disarms when already in eco (nothing to retry)' {
        Get-ArmedAfterEco -Action 'already-eco' -EcoSucceeded $true | Should Be $false
    }
}

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
