# chat-with.ps1 - one-arg terminal chat launcher for any fleet character.
#
# Maps a friendly character name to its DB and launches chat_repl.py
# (plain stdin/stdout client). Deliberately NOT `hexis chat` - that path
# prefers the Textual TUI, which has an unfixed streaming bug that drops
# most of the response (see commit 8f99bbe). chat_repl.py bypasses it via
# stream_agent. Pane-per-char.
#
#   .\chat-with.ps1 warden
#   .\chat-with.ps1 eni
#   .\chat-with.ps1 sam
#   .\chat-with.ps1            # no arg -> list available characters
#
# Source of truth: power-profiles.psd1 Characters array.
# chat_repl.py routes by POSTGRES_DB env (no instance-registry awareness).

param(
    [Parameter(Position = 0)]
    [string]$Character
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

$ProfilePath = Join-Path $Root "power-profiles.psd1"
if (-not (Test-Path $ProfilePath)) { throw "power-profiles.psd1 not found at $ProfilePath" }
$P = Import-PowerShellDataFile -Path $ProfilePath

$Py = Join-Path $Root "venv\Scripts\python.exe"
if (-not (Test-Path $Py)) { throw "venv python not found at $Py (venv not set up?)" }
$ReplScript = Join-Path $Root "chat_repl.py"
if (-not (Test-Path $ReplScript)) { throw "chat_repl.py not found at $ReplScript" }

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

# chat_repl.py reads the target DB from POSTGRES_DB. Scope the override to
# this launch only - restore the caller's value on exit (the .ps1 runs in
# the calling pane's process, so an unscoped change would leak).
$prevDb = $env:POSTGRES_DB
$env:POSTGRES_DB = $match.Db
Write-Host "[chat] $($match.Name) (db: $($match.Db)) - chat_repl.py, Ctrl+C to exit" -ForegroundColor Cyan
try {
    & $Py $ReplScript
} finally {
    if ($null -eq $prevDb) { Remove-Item Env:\POSTGRES_DB -ErrorAction SilentlyContinue }
    else { $env:POSTGRES_DB = $prevDb }
}
