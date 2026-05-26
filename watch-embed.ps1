# watch-embed.ps1 - background watchdog for embed llama-server (:8081).
# Polls http://127.0.0.1:8081/health every $PollSec. On $FailThreshold
# consecutive failures, kills any PID on :8081 and re-invokes
# `start.ps1 -EmbedOnly` to relaunch. Logs each transition to
# logs\watch-embed.log.
#
# Usage:
#   .\watch-embed.ps1                 # foreground, Ctrl-C to exit
#   .\start.ps1                       # auto-launches this script detached
#
# Manual stop (when auto-launched):
#   Stop-Process -Id (Get-Content logs\watch-embed.pid)
#   .\start.ps1 -Stop                 # also kills the watchdog
#
# Why this exists: :8081 can die silently (no stderr capture, host process).
# When it does, every channel worker's embed call times out at 30s, surfacing
# "error processing message" across the fleet. Watchdog catches it within
# ~$PollSec * $FailThreshold of the death.

param(
    [int]$PollSec = 30,
    [int]$FailThreshold = 3,
    [int]$HealthTimeoutSec = 5
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogDir = Join-Path $Root "logs"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
$LogFile = Join-Path $LogDir "watch-embed.log"
$PidFile = Join-Path $LogDir "watch-embed.pid"
$StartScript = Join-Path $Root "start.ps1"

# Write own PID so start.ps1 -Stop and idempotency check can find us.
$PID | Out-File -FilePath $PidFile -Encoding ascii -Force

function Write-Log([string]$Msg) {
    $ts = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    $line = "[$ts] $Msg"
    Add-Content -Path $LogFile -Value $line
    Write-Host $line
}

function Test-EmbedHealth {
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:8081/health" `
             -UseBasicParsing -TimeoutSec $HealthTimeoutSec -ErrorAction Stop
        return ($r.StatusCode -eq 200)
    } catch {
        return $false
    }
}

function Invoke-Relaunch {
    Write-Log "[heal] invoking start.ps1 -EmbedOnly"
    try {
        # Run in-process so we get the exit code; -EmbedOnly is short and
        # blocks until health passes (or 120s timeout).
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $StartScript -EmbedOnly 2>&1 |
            ForEach-Object { Write-Log "[heal>] $_" }
        $rc = $LASTEXITCODE
        if ($rc -eq 0) {
            Write-Log "[heal] embed back up"
        } else {
            Write-Log "[heal] start.ps1 -EmbedOnly exited $rc"
        }
        return ($rc -eq 0)
    } catch {
        Write-Log "[heal] relaunch error: $($_.Exception.Message)"
        return $false
    }
}

# Cleanup PID file on exit (Ctrl-C, terminate). Best-effort.
$null = Register-EngineEvent PowerShell.Exiting -Action {
    try { Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue } catch {}
}

Write-Log "[start] watch-embed PID $PID poll=${PollSec}s threshold=$FailThreshold"

$fails = 0
$wasHealthy = $true

while ($true) {
    $healthy = Test-EmbedHealth
    if ($healthy) {
        if (-not $wasHealthy) {
            Write-Log "[ok] embed recovered after $fails fail(s)"
        }
        $fails = 0
        $wasHealthy = $true
    } else {
        $fails++
        Write-Log "[warn] embed health fail $fails/$FailThreshold"
        $wasHealthy = $false
        if ($fails -ge $FailThreshold) {
            Write-Log "[fail] embed down ${fails} consecutive checks; healing"
            $ok = Invoke-Relaunch
            if ($ok) {
                $fails = 0
                $wasHealthy = $true
            } else {
                # Back off but keep trying. Don't pile up relaunches.
                Write-Log "[backoff] relaunch failed; sleeping 60s before next attempt"
                Start-Sleep -Seconds 60
                $fails = 0  # reset so we re-evaluate fresh after backoff
            }
        }
    }
    Start-Sleep -Seconds $PollSec
}
