# start.ps1 - bring up Hexis stack: Docker DB + embed + nano llama-servers.
#   Chat :8080 is NOT launched here. Per ADR 019 (serving ownership
#   consolidation) llm-serve serve.py is the SOLE :8080 launcher; hexis is a
#   pure consumer. set-power-mode.ps1 prime arms :8080 via `serve.py arm`
#   (health-gated, idempotent). start-all.ps1 runs it right after this script.
# Usage: .\start.ps1            # start services, exit
#        .\start.ps1 -Repl      # start services then drop into chat_repl.py
#        .\start.ps1 -Stop      # stop everything
# Idempotent: re-running won't duplicate processes.

param(
    [switch]$Repl,
    [switch]$Stop,
    # Launch the CPU nano (:8082). Default: only when last set-power-mode was ECO.
    # Pass -WithNano to force on (e.g. cold box where logs\current-mode.txt absent
    # but you still want an ECO floor available). PRIME boots skip it now that
    # the fleet routes heartbeat/chat/subconscious at the GPU :8080.
    # See .local-notes/migrations/2026-05-20-heartbeat-to-gpu/.
    [switch]$WithNano,
    # Restart ONLY the nano (:8082). Kills existing nano if up, then relaunches
    # with current tuning. Skips DB / chat / embed entirely - safe in ECO where
    # chat :8080 would timeout. Use after editing nano serve flags here.
    [switch]$NanoOnly,
    # Restart ONLY the embed (:8081). Kills existing embed if up, then relaunches.
    # Skips DB / chat / nano entirely. Used by watch-embed.ps1 watchdog and after
    # editing embed serve flags here. Idempotent.
    [switch]$EmbedOnly,
    # Skip auto-launching watch-embed.ps1 in the background. Default: launch.
    # The watchdog polls :8081/health every 30s and re-invokes -EmbedOnly on death.
    [switch]$NoWatchdog
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$LlamaServer = "C:\llama.cpp-cuda\llama-server.exe"

# Chat model (:8080) is NOT launched by this script (ADR 019). Its identity +
# serve tuning live in the llm-serve registry (models.json `q36`); serve.py owns
# the launch, invoked by set-power-mode.ps1 prime. No $ChatRepo here — a second
# resolver would be exactly the dual-source drift ADR 019 removes.
$EmbedRepo = "ggml-org/embeddinggemma-300M-GGUF:Q8_0"
# Always-on CPU nano (1B). The floor every character can fall to in ECO mode.
# Kept resident in both modes; mode switches never touch it. See set-power-mode.ps1.
$NanoRepo  = "unsloth/Qwen3-0.6B-GGUF:Q8_0"

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

function Start-Embed {
    if (Get-PortPid 8081) {
        Write-Host "[start] embed :8081 already running"
        return
    }
    Write-Host "[start] embed llama-server :8081 ($EmbedRepo) [CPU]"
    # CPU-bound (--n-gpu-layers 0): embeddinggemma-300M is tiny (~320MB Q8, no
    # autoregressive gen); CPU latency is fine for DB-cached/batched embeddings.
    # Keeps the GPU single-tenant for the chat model on :8080.
    # --parallel 8 + continuous batching: default --parallel 1 serialized all
    # concurrent embed requests under the full 9-persona x 3-worker fleet load,
    # so queued requests hit the get_embedding 5s curl timeout before their turn
    # -> "Embedding service not available" -> chat write-path wedge. embeddinggemma
    # is a tiny forward-pass model; 8 cont-batched slots absorb the burst cheaply.
    # --ctx-size is now total KV across slots, so scale it with --parallel (8*4096).
    Start-Process -FilePath $LlamaServer `
        -ArgumentList @("-hf",$EmbedRepo,
                        "--host","0.0.0.0","--port","8081",
                        "--ctx-size","32768",
                        "--batch-size","4096","--ubatch-size","4096",
                        "--parallel","8","--cont-batching",
                        "--n-gpu-layers","0","--embeddings",
                        "--alias","embeddinggemma-300m") `
        -WindowStyle Hidden
}

function Start-Nano {
    if (Get-PortPid 8082) {
        Write-Host "[start] nano :8082 already running"
        return
    }
    # F2: nano serving relocated to llm-serve serve.py - the SOLE nano lifecycle
    # owner (start.ps1 + set-power-mode both call it; ends the 3-way launch dup +
    # the gpu/nano exclusivity leak). serve.py supplies serve tuning from
    # models.json 'nano' (ctx 32768 / kv q8_0 / ngl 0 / threads 4) + --mlock +
    # below-normal priority + the health-gate. Hexis passes only sampler/reasoning
    # here via --extra-args (same contract as set-power-mode.ps1's eco path):
    #   --temp/top-p/top-k/min-p : Qwen3 OFFICIAL non-thinking sampling (0.7/0.8/20/0)
    #   --repeat-penalty 1.1     : mild echo/loop guard (0.6B on CPU loops easily)
    #   --reasoning off          : template non-thinking - no <think> tag AND no CoT
    #                              narration in content (NOT --reasoning-budget 0 alone)
    $nanoOrch = @("--temp","0.7","--top-p","0.8","--top-k","20","--min-p","0",
                  "--repeat-penalty","1.1","--reasoning","off")
    Write-Host "[start] nano :8082 via serve.py ensure-cpu"
    & py -3.10 C:\llm-serve\infra\serve.py ensure-cpu --extra-args ($nanoOrch -join ' ')
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[fail] serve.py ensure-cpu failed (exit $LASTEXITCODE) - check C:\llm-serve\logs\serve-8082.log"
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

function Get-WatchdogPid {
    # Returns PID if watch-embed.ps1 is alive, else $null. Self-heals stale
    # pid file (process gone, file lingering).
    $pidFile = Join-Path $Root "logs\watch-embed.pid"
    if (-not (Test-Path $pidFile)) { return $null }
    $raw = (Get-Content -LiteralPath $pidFile -Raw -ErrorAction SilentlyContinue).Trim()
    if (-not $raw) { return $null }
    $wd = $null
    if (-not [int]::TryParse($raw, [ref]$wd)) { return $null }
    $proc = Get-Process -Id $wd -ErrorAction SilentlyContinue
    if ($proc) { return $wd }
    # Stale pid file - process gone.
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    return $null
}

function Stop-Watchdog {
    $wd = Get-WatchdogPid
    if ($wd) {
        Stop-Process -Id $wd -Force -ErrorAction SilentlyContinue
        Write-Host "[stop] watch-embed: killed PID $wd"
        Remove-Item -LiteralPath (Join-Path $Root "logs\watch-embed.pid") -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "[stop] watch-embed: not running"
    }
}

function Start-Watchdog {
    $wd = Get-WatchdogPid
    if ($wd) {
        Write-Host "[start] watch-embed already running (PID $wd)"
        return
    }
    $script = Join-Path $Root "watch-embed.ps1"
    if (-not (Test-Path $script)) {
        Write-Host "[warn] watch-embed.ps1 missing; skipping watchdog"
        return
    }
    # Detached: parent (start.ps1) returns to prompt; child loops in background.
    # Hidden window keeps the desktop clean; logs go to logs\watch-embed.log.
    $proc = Start-Process -FilePath "powershell.exe" `
        -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-File",$script) `
        -WindowStyle Hidden -PassThru
    Write-Host "[start] watch-embed PID $($proc.Id) (poll 30s; logs/watch-embed.log)"
}

if ($Stop) {
    Stop-Watchdog
    Kill-Port 8080 "chat"
    Kill-Port 8081 "embed"
    Kill-Port 8082 "nano"
    Push-Location $Root
    Invoke-Docker compose stop db | Out-Null
    Pop-Location
    Write-Host "[done] Hexis stack stopped"
    exit 0
}

if ($NanoOnly) {
    # Bounce only nano (:8082). Use after editing nano serve flags. Safe in ECO
    # (DB / chat / embed left alone; no Vesper :8080 4-min timeout).
    Kill-Port 8082 "nano"
    Start-Sleep -Seconds 1
    Start-Nano
    $ok = Wait-Health "http://127.0.0.1:8082/health" "nano :8082" 180
    if (-not $ok) {
        Write-Host "[fail] nano :8082 did not become healthy"
        exit 1
    }
    Write-Host "[ready] nano :8082"
    exit 0
}

if ($EmbedOnly) {
    # Bounce only embed (:8081). Used by watch-embed.ps1 watchdog after a
    # detected crash, and as a manual restart after editing embed serve flags.
    # Skips DB / chat / nano entirely.
    Kill-Port 8081 "embed"
    Start-Sleep -Seconds 1
    Start-Embed
    $ok = Wait-Health "http://127.0.0.1:8081/health" "embed :8081" 120
    if (-not $ok) {
        Write-Host "[fail] embed :8081 did not become healthy"
        exit 1
    }
    Write-Host "[ready] embed :8081"
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

# Mode marker: read once, gate the nano (:8082) launch on it. Chat (:8080) is
# no longer gated/launched here — llm-serve serve.py owns it (ADR 019), armed by
# set-power-mode.ps1 prime.
$markerFile = Join-Path $Root "logs\current-mode.txt"
$lastMode = $null
if (Test-Path $markerFile) {
    $lastMode = ((Get-Content $markerFile -Raw).Trim() -split "`n")[0].Trim().ToLower()
}
$wantNano = $WithNano.IsPresent -or ($lastMode -eq "eco")

# 2. Chat llama-server :8080 — NOT launched here (ADR 019). serve.py is the sole
#    :8080 launcher; set-power-mode.ps1 prime arms it (health-gated) right after
#    start-all.ps1 calls this script. A direct Start-Process here would restore
#    the dual-launcher smell ADR 019 removed.

# 3. Embed llama-server :8081
Start-Embed

# 4. Nano CPU-1B llama-server :8082 (ECO floor only). CPU -> 0 VRAM.
# Post 2026-05-20 heartbeat-to-GPU migration, the live fleet routes
# llm.chat/llm.heartbeat/llm.subconscious at :8080 (q36 MoE), so PRIME no longer
# needs nano resident. $wantNano was computed from the mode marker above.
if (-not $wantNano) {
    Write-Host "[skip] nano :8082 (mode=$lastMode; pass -WithNano to force)"
} else {
    Start-Nano
}

# 5. Wait health. embed is fatal; nano is best-effort (CPU load slower, must not
#    block the stack). Chat (:8080) is not waited on here — set-power-mode.ps1
#    prime health-gates the arm downstream (serve.py arm throws on a dead :8080).
$embedOk = Wait-Health "http://127.0.0.1:8081/health"  "embed :8081" 120
if ($wantNano) {
    $nanoOk = Wait-Health "http://127.0.0.1:8082/health" "nano :8082" 180
    if (-not $nanoOk) {
        Write-Host "[warn] nano :8082 not healthy yet - ECO fallback degraded until it loads"
    }
}

if (-not $embedOk) {
    Write-Host "[fail] embed :8081 did not become healthy"
    exit 1
}

# 6. Watchdog for embed (:8081). Auto-launched detached so the parent shell
# returns. Idempotent: skipped if already running. -NoWatchdog opts out.
if (-not $NoWatchdog) {
    Start-Watchdog
}

Write-Host ""
Write-Host "[ready] Hexis stack up"
Write-Host "  chat  (not launched here; set-power-mode.ps1 prime arms :8080 via serve.py - ADR 019)"
Write-Host "  embed http://127.0.0.1:8081"
if ($wantNano) {
    Write-Host "  nano  http://127.0.0.1:8082  (CPU-1B, ECO floor)"
} else {
    Write-Host "  nano  (not launched; mode=$lastMode)"
}
Write-Host "  db    127.0.0.1:43815"
Write-Host ""

if ($Repl) {
    $env:PYTHONIOENCODING = "utf-8"
    $env:PYTHONUTF8 = "1"
    & "$Root\venv\Scripts\python.exe" "$Root\chat_repl.py"
} else {
    Write-Host "Next:  .\venv\Scripts\python.exe chat_repl.py"
}
