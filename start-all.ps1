# start-all.ps1 - full Hexis reboot recovery: Docker engine + llama-servers + db + ALL workers/instances
#
# Brings up everything needed for default/Sam + baymax + rocky + tars to be online.
#
# Usage: .\start-all.ps1          # bring full stack up
#        .\start-all.ps1 -Stop    # tear full stack down
#
# Idempotent. Runs headless-safe (logs to .\logs\). Designed to be run by a
# Scheduled Task at logon and by a desktop shortcut.

param(
    [switch]$Stop
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

$LogDir = Join-Path $Root "logs"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
$LogFile = Join-Path $LogDir ("start-all_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
Start-Transcript -Path $LogFile -Append | Out-Null

# All compose files: base + the 3 character overlays.
$Compose = @(
    "-f", "docker-compose.yml",
    "-f", "docker-compose.baymax.yml",
    "-f", "docker-compose.rocky.yml",
    "-f", "docker-compose.tars.yml"
)

function Test-DockerEngine {
    try {
        docker info *> $null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Wait-DockerEngine([int]$TimeoutSec = 300) {
    if (Test-DockerEngine) {
        Write-Host "[docker] engine already up"
        return $true
    }
    $exe = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
    if (Test-Path $exe) {
        Write-Host "[docker] launching Docker Desktop"
        Start-Process -FilePath $exe -WindowStyle Hidden
    } else {
        Write-Host "[docker] '$exe' not found - waiting for engine to come up by other means"
    }
    Write-Host -NoNewline "[wait] docker engine "
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-DockerEngine) { Write-Host "OK"; return $true }
        Write-Host -NoNewline "."
        Start-Sleep -Seconds 3
    }
    Write-Host "TIMEOUT"
    return $false
}

function Test-Port([int]$Port) {
    $c = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    return [bool]$c
}

function Test-StackPrereqs {
    $dbHealth = (docker inspect hexis_brain --format '{{.State.Health.Status}}' 2>$null)
    $ok = $true
    if ($dbHealth -ne "healthy") { Write-Host "[verify] db not healthy (status: $dbHealth)"; $ok = $false }
    if (-not (Test-Port 8080))   { Write-Host "[verify] chat llama-server :8080 not listening"; $ok = $false }
    if (-not (Test-Port 8081))   { Write-Host "[verify] embed llama-server :8081 not listening"; $ok = $false }
    return $ok
}

# ---- STOP ----
if ($Stop) {
    if (Test-DockerEngine) {
        Push-Location $Root
        docker compose @Compose --profile active stop
        Pop-Location
    } else {
        Write-Host "[stop] docker engine down - skipping container stop"
    }
    & "$Root\start.ps1" -Stop
    Write-Host "[done] Hexis full stack stopped"
    Stop-Transcript | Out-Null
    exit 0
}

# ---- UP ----

# 1. Docker engine. At a boot-triggered run the engine may not exist yet (no
# session) - wait long; the scheduled task also retries, and the AtLogOn
# trigger is the backstop.
if (-not (Wait-DockerEngine 600)) {
    Write-Host "[fail] Docker engine never came up"
    Stop-Transcript | Out-Null
    exit 1
}

# 2. Host llama-servers (chat :8080, embed :8081) + db. Delegates to start.ps1,
#    which waits for db healthy + both servers healthy.
& "$Root\start.ps1"
$startRc = $LASTEXITCODE

# start.ps1 only `exit`s on failure; success path falls through with no exit,
# so don't trust a 0 - verify prerequisites independently.
if ($startRc -eq 1 -or -not (Test-StackPrereqs)) {
    Write-Host "[fail] host LLM/embed/db prerequisites not satisfied - aborting before workers"
    Stop-Transcript | Out-Null
    exit 1
}

# 3. rabbitmq + default workers/api + baymax/rocky/tars overlays (all `profile: active`)
Write-Host "[start] rabbitmq + all workers + baymax/rocky/tars overlays"
Push-Location $Root
docker compose @Compose --profile active up -d
$composeRc = $LASTEXITCODE
Pop-Location
if ($composeRc -ne 0) {
    Write-Host "[fail] compose up failed (exit $composeRc)"
    Stop-Transcript | Out-Null
    exit 1
}

# 4. Normalize to PRIME so every boot lands in a known mode (non-fatal:
#    stack is up regardless; this only sets each character's llm.* config).
$setMode = Join-Path $Root "set-power-mode.ps1"
if (Test-Path $setMode) {
    Write-Host "[mode] normalizing to PRIME"
    try {
        & $setMode prime
        if ($LASTEXITCODE -ne 0) { Write-Host "[warn] set-power-mode prime exited $LASTEXITCODE - stack still up, config not normalized" }
    } catch {
        Write-Host "[warn] set-power-mode prime failed: $($_.Exception.Message) - stack still up"
    }
} else {
    Write-Host "[mode] set-power-mode.ps1 not present - skipping mode normalize"
}

# 5. Summary
Write-Host ""
Write-Host "[ready] Hexis full stack up"
docker ps --format "{{.Names}}`t{{.Status}}" | Sort-Object | ForEach-Object { Write-Host "  $_" }
Write-Host ""
Write-Host "  chat   http://127.0.0.1:8080"
Write-Host "  embed  http://127.0.0.1:8081"
Write-Host "  nano   http://127.0.0.1:8082  (CPU-1B, ECO floor)"
Write-Host "  db     127.0.0.1:43815"
Write-Host "  api    http://127.0.0.1:43817"
Write-Host ""
Write-Host "  Characters (Sam/Baymax/Rocky/Tars) are online via their Telegram bots."
Stop-Transcript | Out-Null
exit 0
