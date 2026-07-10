# resume-fleet.ps1 - undo pause-fleet.ps1: clear heartbeat_state.is_paused on
# exactly the DBs pause-fleet flipped (per the logs/paused-fleet.json snapshot),
# so an agent self-pause / terminated agent is never disturbed. Serving is not
# touched here either (it was never changed by the pause).
#
# On resume, an overdue last_heartbeat_at is staggered into the jitter window so
# the fleet does not burst-fire simultaneously behind the --parallel 1 GPU slot.
#
# Usage: .\resume-fleet.ps1
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

$ProfilePath = Join-Path $Root "power-profiles.psd1"
if (-not (Test-Path $ProfilePath)) { throw "power-profiles.psd1 not found at $ProfilePath" }
$P = Import-PowerShellDataFile -Path $ProfilePath

$LogDir = Join-Path $Root "logs"
$Snapshot = Join-Path $LogDir "paused-fleet.json"

$py = Join-Path $Root "venv\Scripts\python.exe"
if (-not (Test-Path $py)) { throw "venv python not found at $py" }

$eapPrev = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & $py (Join-Path $Root "scripts\pause_fleet.py") --action resume --dsn-base $P.PgDsnBase --snapshot $Snapshot 2>&1 |
        ForEach-Object { Write-Host $_ }
    $rc = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $eapPrev
}
if ($rc -ne 0) { throw "pause_fleet.py resume failed (exit $rc) - snapshot kept: $Snapshot" }

Write-Host ""
Write-Host "[done] heartbeats resumed fleet-wide. Next cycle staggered to avoid GPU burst."
