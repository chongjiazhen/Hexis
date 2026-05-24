# start-all.ps1 - full Hexis reboot recovery: Docker engine + llama-servers + db + ALL workers/instances
#
# Brings up the Hexis base stack (db + default workers + api).
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

# Compose files: base stack + newchars persona fleet. The newchars file only
# adds persona worker services (active-profile); frozen personas stay gated out
# by their own `profiles: ["frozen"]` override and won't start.
$Compose = @(
    "-f", "docker-compose.yml",
    "-f", "docker-compose.newchars.yml"
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

function Invoke-Docker {
    # PS 5.1 turns native-command stderr into a terminating error under
    # $ErrorActionPreference='Stop' - even benign docker warnings ("Found
    # orphan containers") on exit 0. Demote EAP, surface stderr as text,
    # return docker's real exit code.
    #
    # Simple (non-advanced) function on purpose: $args captures dash-prefixed
    # tokens like -d / -f / --profile verbatim; an advanced param([...]) would
    # try to bind them as parameters.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & docker @args 2>&1 | ForEach-Object { Write-Host $_ }
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Test-StackPrereqs {
    $dbHealth = (docker inspect hexis_brain --format '{{.State.Health.Status}}' 2>$null)
    $ok = $true
    if ($dbHealth -ne "healthy") { Write-Host "[verify] db not healthy (status: $dbHealth)"; $ok = $false }
    # Mode-gated: in ECO, set-power-mode.ps1 owns :8080 and start.ps1 skips launching it.
    # Don't require :8080 here or verify always fails on ECO boots.
    $markerFile = Join-Path $Root "logs\current-mode.txt"
    $lastMode = if (Test-Path $markerFile) { (Get-Content $markerFile -ErrorAction SilentlyContinue | Select-Object -First 1).Trim() } else { "" }
    if ($lastMode -ne "eco") {
        if (-not (Test-Port 8080)) { Write-Host "[verify] chat llama-server :8080 not listening"; $ok = $false }
    } else {
        Write-Host "[verify] chat :8080 check skipped (mode=eco)"
    }
    if (-not (Test-Port 8081))   { Write-Host "[verify] embed llama-server :8081 not listening"; $ok = $false }
    return $ok
}

# ---- STOP ----
if ($Stop) {
    if (Test-DockerEngine) {
        Push-Location $Root
        Invoke-Docker compose @Compose --profile active stop | Out-Null
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

# 3. rabbitmq + default workers/api + newchars persona fleet (`profile: active`)
Write-Host "[start] rabbitmq + default workers/api + newchars persona fleet"
Push-Location $Root
$composeRc = Invoke-Docker compose @Compose --profile active up -d
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

# 4b. VRAM guard: auto-fallback to ECO if a game/heavy GPU app appears.
#     Single-instance (own lockfile); spawn hidden if not already running.
$guard = Join-Path $Root "hexis-vram-guard.ps1"
if (Test-Path $guard) {
    $guardLock = Join-Path $LogDir "vram-guard.lock"
    $running = $false
    if (Test-Path $guardLock) {
        $gpid = (Get-Content $guardLock -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($gpid -and (Get-Process -Id $gpid -ErrorAction SilentlyContinue)) { $running = $true }
    }
    if ($running) {
        Write-Host "[guard] vram-guard already running (PID $gpid)"
    } else {
        Write-Host "[guard] starting vram-guard (auto-ECO on heavy GPU app)"
        Start-Process powershell `
            -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File","`"$guard`"") `
            -WorkingDirectory $Root -WindowStyle Hidden | Out-Null
    }
} else {
    Write-Host "[guard] hexis-vram-guard.ps1 not present - no auto-fallback"
}

# 5. Summary
Write-Host ""
Write-Host "[ready] Hexis full stack up"
docker ps --format "{{.Names}}`t{{.Status}}" 2>$null | Sort-Object | ForEach-Object { Write-Host "  $_" }
Write-Host ""
Write-Host "  chat   http://127.0.0.1:8080"
Write-Host "  embed  http://127.0.0.1:8081"
Write-Host "  nano   http://127.0.0.1:8082  (CPU-1B, ECO floor)"
Write-Host "  db     127.0.0.1:43815"
Write-Host "  api    http://127.0.0.1:43817"
Write-Host ""
Write-Host "  Default character + newchars persona fleet online via Telegram bots."
Stop-Transcript | Out-Null
exit 0
