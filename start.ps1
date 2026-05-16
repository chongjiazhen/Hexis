# start.ps1 - bring up Hexis stack: Docker DB + chat + embed + nano llama-servers
# Usage: .\start.ps1            # start services, exit
#        .\start.ps1 -Repl      # start services then drop into chat_repl.py
#        .\start.ps1 -Stop      # stop everything
# Idempotent: re-running won't duplicate processes.

param(
    [switch]$Repl,
    [switch]$Stop
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$LlamaServer = "C:\llama.cpp-cuda\llama-server.exe"

$ChatRepo  = "mradermacher/Hexis-Vesper-12B-i1-GGUF:Q6_K"
$EmbedRepo = "ggml-org/embeddinggemma-300M-GGUF:Q8_0"
# Always-on CPU nano (1B). The floor every character can fall to in ECO mode.
# Kept resident in both modes; mode switches never touch it. See set-power-mode.ps1.
$NanoRepo  = "SicariusSicariiStuff/Nano_Imp_1B_GGUF:Q6_K"

function Get-PortPid([int]$Port) {
    $c = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($c) { return $c[0].OwningProcess }
    return $null
}

function Kill-Port([int]$Port, [string]$Label) {
    # NOTE: do not use $pid - it is a read-only PowerShell automatic variable.
    $procId = Get-PortPid $Port
    if ($procId) {
        Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
        Write-Host "[stop] ${Label}: killed PID $procId on port $Port"
    } else {
        Write-Host "[stop] ${Label}: nothing on port $Port"
    }
}

function Invoke-Docker {
    # Windows PowerShell 5.1 turns ANY native-command stderr into a terminating
    # error when $ErrorActionPreference='Stop' - even benign docker warnings
    # like "Found orphan containers" on exit 0. Run docker with EAP demoted and
    # surface stderr as plain text. Returns docker's real exit code.
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

function Wait-Health([string]$Url, [string]$Label, [int]$TimeoutSec = 120) {
    Write-Host -NoNewline "[wait] $Label "
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
            if ($r.StatusCode -eq 200) {
                Write-Host "OK"
                return $true
            }
        } catch { }
        Write-Host -NoNewline "."
        Start-Sleep -Seconds 2
    }
    Write-Host "TIMEOUT"
    return $false
}

if ($Stop) {
    Kill-Port 8080 "chat"
    Kill-Port 8081 "embed"
    Kill-Port 8082 "nano"
    Push-Location $Root
    Invoke-Docker compose stop db | Out-Null
    Pop-Location
    Write-Host "[done] Hexis stack stopped"
    exit 0
}

# 1. Docker DB
Write-Host "[start] Docker DB"
Push-Location $Root
$dbRc = Invoke-Docker compose up -d db
Pop-Location
if ($dbRc -ne 0) {
    Write-Host "[fail] 'docker compose up -d db' exited $dbRc"
    exit 1
}
Write-Host -NoNewline "[wait] postgres :43815 "
$deadline = (Get-Date).AddSeconds(60)
while ($true) {
    $health = (docker inspect hexis_brain --format '{{.State.Health.Status}}' 2>$null)
    if ($health -eq "healthy") { Write-Host "OK"; break }
    if ((Get-Date) -ge $deadline) { break }
    Write-Host -NoNewline "."
    Start-Sleep -Seconds 2
}
if ($health -ne "healthy") {
    Write-Host "TIMEOUT"
    Write-Host "[fail] DB never went healthy (last status: $health)"
    exit 1
}

# 2. Chat llama-server :8080
if (Get-PortPid 8080) {
    Write-Host "[start] chat :8080 already running"
} else {
    Write-Host "[start] chat llama-server :8080 ($ChatRepo)"
    Start-Process -FilePath $LlamaServer `
        -ArgumentList @("-hf",$ChatRepo,
                        "--host","0.0.0.0","--port","8080",
                        "--ctx-size","8192","--n-gpu-layers","999",
                        "--alias","hexis-vesper-12b","--jinja") `
        -WindowStyle Hidden
}

# 3. Embed llama-server :8081
if (Get-PortPid 8081) {
    Write-Host "[start] embed :8081 already running"
} else {
    Write-Host "[start] embed llama-server :8081 ($EmbedRepo)"
    Start-Process -FilePath $LlamaServer `
        -ArgumentList @("-hf",$EmbedRepo,
                        "--host","0.0.0.0","--port","8081",
                        "--ctx-size","4096",
                        "--batch-size","4096","--ubatch-size","4096",
                        "--n-gpu-layers","999","--embeddings",
                        "--alias","embeddinggemma-300m") `
        -WindowStyle Hidden
}

# 4. Nano CPU-1B llama-server :8082 (always-on; ECO floor). CPU only -> 0 VRAM.
if (Get-PortPid 8082) {
    Write-Host "[start] nano :8082 already running"
} else {
    Write-Host "[start] nano llama-server :8082 ($NanoRepo)"
    Start-Process -FilePath $LlamaServer `
        -ArgumentList @("-hf",$NanoRepo,
                        "--host","0.0.0.0","--port","8082",
                        "--ctx-size","4096","--n-gpu-layers","0",
                        "--parallel","1",
                        "--alias","nano-imp-1b","--jinja") `
        -WindowStyle Hidden
}

# 5. Wait health. chat + embed are fatal; nano is best-effort (CPU load slower,
#    must not block the stack - characters only fall to it in ECO).
$chatOk  = Wait-Health "http://127.0.0.1:8080/health"  "chat :8080" 240
$embedOk = Wait-Health "http://127.0.0.1:8081/health"  "embed :8081" 120
$nanoOk  = Wait-Health "http://127.0.0.1:8082/health"  "nano :8082" 180
if (-not $nanoOk) {
    Write-Host "[warn] nano :8082 not healthy yet - ECO fallback degraded until it loads"
}

if (-not ($chatOk -and $embedOk)) {
    Write-Host "[fail] one or more servers did not become healthy"
    exit 1
}

Write-Host ""
Write-Host "[ready] Hexis stack up"
Write-Host "  chat  http://127.0.0.1:8080"
Write-Host "  embed http://127.0.0.1:8081"
Write-Host "  nano  http://127.0.0.1:8082  (CPU-1B, ECO floor)"
Write-Host "  db    127.0.0.1:43815"
Write-Host ""

if ($Repl) {
    $env:PYTHONIOENCODING = "utf-8"
    $env:PYTHONUTF8 = "1"
    & "$Root\venv\Scripts\python.exe" "$Root\chat_repl.py"
} else {
    Write-Host "Next:  .\venv\Scripts\python.exe chat_repl.py"
}
