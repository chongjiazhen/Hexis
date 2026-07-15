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

# DSN base for the instance DBs (power-profiles.psd1 retired per ADR-020;
# override with HEXIS_PG_DSN_BASE if the port/creds ever move).
$PgDsnBase = if ($env:HEXIS_PG_DSN_BASE) { $env:HEXIS_PG_DSN_BASE }
             else { 'postgresql://hexis_user:hexis_password@127.0.0.1:43815' }

$LogDir = Join-Path $Root "logs"
$Snapshot = Join-Path $LogDir "paused-fleet.json"

$py = Join-Path $Root "venv\Scripts\python.exe"
if (-not (Test-Path $py)) { throw "venv python not found at $py" }

$eapPrev = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & $py (Join-Path $Root "scripts\pause_fleet.py") --action resume --dsn-base $PgDsnBase --snapshot $Snapshot 2>&1 |
        ForEach-Object { Write-Host $_ }
    $rc = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $eapPrev
}
if ($rc -ne 0) { throw "pause_fleet.py resume failed (exit $rc) - snapshot kept: $Snapshot" }

Write-Host ""
Write-Host "[done] heartbeats resumed fleet-wide. Next cycle staggered to avoid GPU burst."
