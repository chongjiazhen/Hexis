# start.ps1 — bring up Hexis stack: Docker DB + chat llama-server + embed llama-server
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

function Get-PortPid([int]$Port) {
    $c = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($c) { return $c[0].OwningProcess }
    return $null
}

function Kill-Port([int]$Port, [string]$Label) {
    $pid = Get-PortPid $Port
    if ($pid) {
        Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
        Write-Host "[stop] ${Label}: killed PID $pid on port $Port"
    } else {
        Write-Host "[stop] ${Label}: nothing on port $Port"
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
    Push-Location $Root
    docker compose stop db
    Pop-Location
    Write-Host "[done] Hexis stack stopped"
    exit 0
}

# 1. Docker DB
Write-Host "[start] Docker DB"
Push-Location $Root
docker compose up -d db | Out-Null
Pop-Location
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

# 4. Wait both healthy
$chatOk  = Wait-Health "http://127.0.0.1:8080/health"  "chat :8080" 240
$embedOk = Wait-Health "http://127.0.0.1:8081/health"  "embed :8081" 120

if (-not ($chatOk -and $embedOk)) {
    Write-Host "[fail] one or more servers did not become healthy"
    exit 1
}

Write-Host ""
Write-Host "[ready] Hexis stack up"
Write-Host "  chat  http://127.0.0.1:8080"
Write-Host "  embed http://127.0.0.1:8081"
Write-Host "  db    127.0.0.1:43815"
Write-Host ""

if ($Repl) {
    $env:PYTHONIOENCODING = "utf-8"
    $env:PYTHONUTF8 = "1"
    & "$Root\venv\Scripts\python.exe" "$Root\chat_repl.py"
} else {
    Write-Host "Next:  .\venv\Scripts\python.exe chat_repl.py"
}
