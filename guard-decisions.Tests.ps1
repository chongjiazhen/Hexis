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
