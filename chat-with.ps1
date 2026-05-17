# chat-with.ps1 - one-arg terminal chat launcher for any fleet character.
#
# Resolves the venv hexis CLI + maps a friendly character name to its
# instance, then drops you into `hexis -i <instance> chat`. Pane-per-char.
#
#   .\chat-with.ps1 warden
#   .\chat-with.ps1 eni
#   .\chat-with.ps1 sam
#   .\chat-with.ps1            # no arg -> list available characters
#
# Source of truth: power-profiles.psd1 Characters array.

param(
    [Parameter(Position = 0)]
    [string]$Character
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

$ProfilePath = Join-Path $Root "power-profiles.psd1"
if (-not (Test-Path $ProfilePath)) { throw "power-profiles.psd1 not found at $ProfilePath" }
$P = Import-PowerShellDataFile -Path $ProfilePath

$Hexis = Join-Path $Root "venv\Scripts\hexis.exe"
if (-not (Test-Path $Hexis)) { throw "hexis CLI not found at $Hexis (venv not set up?)" }

function Show-Roster {
    Write-Host "Available characters:"
    foreach ($c in $P.Characters) {
        $inst = $c.Db -replace '^hexis_', ''
        $tier = $c.Prime.Tier
        Write-Host ("  {0,-8} (instance: {1,-8} tier: {2})" -f $c.Name, $inst, $tier)
    }
    Write-Host ""
    Write-Host "Usage: .\chat-with.ps1 <name>"
}

if (-not $Character) { Show-Roster; return }

# Match arg against Name, instance token, or full Db (case-insensitive).
$match = $P.Characters | Where-Object {
    $inst = $_.Db -replace '^hexis_', ''
    ($_.Name -ieq $Character) -or ($inst -ieq $Character) -or ($_.Db -ieq $Character)
} | Select-Object -First 1

if (-not $match) {
    Write-Host "Unknown character: '$Character'" -ForegroundColor Red
    Write-Host ""
    Show-Roster
    exit 1
}

$instance = $match.Db -replace '^hexis_', ''

# hexis_memory (Sam) is the legacy default DB - not in the instance registry,
# so it must run WITHOUT -i. Registry-backed chars use -i <instance>.
if ($match.Db -ieq 'hexis_memory') {
    Write-Host "[chat] $($match.Name) (default brain: $($match.Db))" -ForegroundColor Cyan
    & $Hexis chat
} else {
    Write-Host "[chat] $($match.Name) (instance: $instance, db: $($match.Db))" -ForegroundColor Cyan
    & $Hexis -i $instance chat
}
