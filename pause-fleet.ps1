# pause-fleet.ps1 - pause the autonomous heartbeat loop fleet-wide WITHOUT
# touching serving. Leaves the :8080 GPU model armed (power mode unchanged) so
# your OWN work (coding agent / vibe-coding) gets the GPU, while personas'
# heartbeats go quiet instead of competing for the single --parallel 1 slot.
#
# Decouple axis: set-power-mode.ps1 = serving + cognition bundle (eco kills :8080).
# This = cognition only (heartbeat_state.is_paused). Power mode is NOT touched.
# maintenance_state is left alone (CPU/embedding housekeeping keeps running;
# subconscious LLM is off by default).
#
# Reverse with .\resume-fleet.ps1. The snapshot (logs/paused-fleet.json) records
# which DBs were actually flipped, so resume never clobbers an agent self-pause.
#
# Usage: .\pause-fleet.ps1
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

# DSN base for the instance DBs (power-profiles.psd1 retired per ADR-020;
# override with HEXIS_PG_DSN_BASE if the port/creds ever move).
$PgDsnBase = if ($env:HEXIS_PG_DSN_BASE) { $env:HEXIS_PG_DSN_BASE }
             else { 'postgresql://hexis_user:hexis_password@127.0.0.1:43815' }

$LogDir = Join-Path $Root "logs"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
$Snapshot = Join-Path $LogDir "paused-fleet.json"

$py = Join-Path $Root "venv\Scripts\python.exe"
if (-not (Test-Path $py)) { throw "venv python not found at $py" }

# PS 5.1: native stderr under EAP=Stop is a terminating error. pause_fleet.py
# prints per-DB progress/errors to stderr; demote EAP so we reach the rc check.
$eapPrev = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & $py (Join-Path $Root "scripts\pause_fleet.py") --action pause --dsn-base $PgDsnBase --snapshot $Snapshot 2>&1 |
        ForEach-Object { Write-Host $_ }
    $rc = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $eapPrev
}
if ($rc -ne 0) { throw "pause_fleet.py pause failed (exit $rc) - snapshot: $Snapshot" }

Write-Host ""
Write-Host "[done] heartbeats paused fleet-wide. :8080 GPU model still armed (power mode unchanged)."
Write-Host "  Resume with .\resume-fleet.ps1"
