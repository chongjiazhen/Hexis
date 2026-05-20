# start.ps1 - bring up Hexis stack: Docker DB + chat + embed + nano llama-servers
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
    [switch]$NanoOnly
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

function Start-Nano {
    if (Get-PortPid 8082) {
        Write-Host "[start] nano :8082 already running"
        return
    }
    # Thread-capped + below-normal priority: pure-CPU inference must NOT saturate
    # all cores and starve interactive apps (this crashed VS Code).
    # 8 physical cores -> cap at 4, leave headroom.
    $NanoThreads = 4
    Write-Host "[start] nano llama-server :8082 ($NanoRepo, threads=$NanoThreads, below-normal)"
    # Tuning rationale (ECO floor; 11 personas serialize on --parallel 1):
    #   --ctx-size 32768           : prompt bloat headroom (lovesick hit 5735 tok ceiling at 4096)
    #   --cache-type-k/v q8_0      : halves KV cache; trivial quality loss; pairs w/ bigger ctx
    #   --repeat-penalty 1.1       : kills echo/loop degeneracy (1B persona-hold weakness)
    #   --mlock                    : pin weights+KV in RAM, no page-fault stalls mid-stream
    #   --n-gpu-layers 0           : CPU-only, 0 VRAM (PRIME owns GPU)
    $nanoProc = Start-Process -FilePath $LlamaServer `
        -ArgumentList @("-hf",$NanoRepo,
                        "--host","0.0.0.0","--port","8082",
                        "--ctx-size","32768","--n-gpu-layers","0",
                        "--cache-type-k","q8_0","--cache-type-v","q8_0",
                        "--repeat-penalty","1.1",
                        "--mlock",
                        "--parallel","1",
                        "--threads","$NanoThreads","--threads-batch","$NanoThreads",
                        "--alias","nano-imp-1b","--jinja") `
        -WindowStyle Hidden -PassThru
    try {
        $nanoProc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal
        Write-Host "[start] nano PID $($nanoProc.Id) priority=BelowNormal"
    } catch {
        Write-Host "[warn] could not lower nano priority: $($_.Exception.Message)"
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

# Mode marker: read once, gate chat (:8080) + nano (:8082) launches on it.
# set-power-mode.ps1 owns :8080 in PRIME (q36 ActiveBig per power-profiles.psd1).
# start.ps1 launching its own Vesper-12B on :8080 in ECO mode is wrong: it
# wastes ~7 GB VRAM that vram-guard just freed for ComfyUI/games, AND the
# alias mismatch (Vesper here vs the q36 alias workers expect) causes silent
# model misrouting if anything later flips configs back to :8080.
$markerFile = Join-Path $Root "logs\current-mode.txt"
$lastMode = $null
if (Test-Path $markerFile) {
    $lastMode = ((Get-Content $markerFile -Raw).Trim() -split "`n")[0].Trim().ToLower()
}
$wantChat = ($lastMode -ne "eco")  # PRIME or unknown -> launch chat
$wantNano = $WithNano.IsPresent -or ($lastMode -eq "eco")

# 2. Chat llama-server :8080 (PRIME only; ECO = leave GPU free)
if (-not $wantChat) {
    Write-Host "[skip] chat :8080 (mode=$lastMode; set-power-mode.ps1 prime owns :8080)"
} elseif (Get-PortPid 8080) {
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
    Write-Host "[start] embed llama-server :8081 ($EmbedRepo) [CPU]"
    # CPU-bound (--n-gpu-layers 0): embeddinggemma-300M is tiny (~320MB Q8, no
    # autoregressive gen); CPU latency is fine for DB-cached/batched embeddings.
    # Keeps the GPU single-tenant for the 35B chat model on :8080 (eliminates
    # the 8080-vs-8081 CUDA contention on the single 16 GB card). Same pattern
    # as the always-on nano (:8082, also -ngl 0).
    Start-Process -FilePath $LlamaServer `
        -ArgumentList @("-hf",$EmbedRepo,
                        "--host","0.0.0.0","--port","8081",
                        "--ctx-size","4096",
                        "--batch-size","4096","--ubatch-size","4096",
                        "--n-gpu-layers","0","--embeddings",
                        "--alias","embeddinggemma-300m") `
        -WindowStyle Hidden
}

# 4. Nano CPU-1B llama-server :8082 (ECO floor only). CPU -> 0 VRAM.
# Post 2026-05-20 heartbeat-to-GPU migration, the live fleet routes
# llm.chat/llm.heartbeat/llm.subconscious at :8080 (q36 MoE), so PRIME no longer
# needs nano resident. $wantNano was computed earlier alongside $wantChat.
if (-not $wantNano) {
    Write-Host "[skip] nano :8082 (mode=$lastMode; pass -WithNano to force)"
} else {
    Start-Nano
}

# 5. Wait health. embed is always fatal; chat is fatal when launched (PRIME);
#    nano is best-effort (CPU load slower, must not block the stack).
$chatOk  = $true  # treat as OK in ECO (skipped); only matters if we launched
if ($wantChat) {
    $chatOk = Wait-Health "http://127.0.0.1:8080/health"  "chat :8080" 240
}
$embedOk = Wait-Health "http://127.0.0.1:8081/health"  "embed :8081" 120
if ($wantNano) {
    $nanoOk = Wait-Health "http://127.0.0.1:8082/health" "nano :8082" 180
    if (-not $nanoOk) {
        Write-Host "[warn] nano :8082 not healthy yet - ECO fallback degraded until it loads"
    }
}

if (-not ($chatOk -and $embedOk)) {
    Write-Host "[fail] one or more servers did not become healthy"
    exit 1
}

Write-Host ""
Write-Host "[ready] Hexis stack up"
if ($wantChat) {
    Write-Host "  chat  http://127.0.0.1:8080"
} else {
    Write-Host "  chat  (not launched; mode=$lastMode; use set-power-mode.ps1 prime)"
}
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
