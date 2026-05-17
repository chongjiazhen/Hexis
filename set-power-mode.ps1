# set-power-mode.ps1 - switch the agent fleet between ECO and PRIME.
#
# PRIME: arm each character's assigned GPU model; flip all instance DBs to it.
# ECO:   kill the GPU model servers (frees VRAM); flip all instance DBs to the
#        always-on CPU nano (:8082). Optionally point Sam at a heavy model you
#        already loaded for your own use (vibe-coding / SillyTavern).
#
# The always-on nano (:8082) and embed (:8081) are NEVER touched here - they are
# owned by start.ps1.
#
# Usage:
#   .\set-power-mode.ps1 eco
#   .\set-power-mode.ps1 eco -SamEndpoint http://host.docker.internal:8090/v1 -SamModel my-coding-model
#   .\set-power-mode.ps1 prime
#
# Source of truth: power-profiles.psd1 (hand-editable; GUI writes it later).

param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("eco", "prime")]
    [string]$Mode,

    [string]$SamEndpoint,
    [string]$SamModel
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

$LogDir = Join-Path $Root "logs"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
$LogFile = Join-Path $LogDir ("set-power-mode_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
Start-Transcript -Path $LogFile -Append | Out-Null

try {

$ProfilePath = Join-Path $Root "power-profiles.psd1"
if (-not (Test-Path $ProfilePath)) { throw "power-profiles.psd1 not found at $ProfilePath" }
$P = Import-PowerShellDataFile -Path $ProfilePath

$LlamaServer = $P.LlamaServer
$DockerHost  = $P.DockerHost
$Provider    = $P.Provider
$ApiKeyEnv   = $P.ApiKeyEnv
$NanoPort    = $P.Nano.Port
$NanoAlias   = $P.Nano.Alias

# Single shared GPU slot: ActiveBig (1-of-N) on BigPort. Decoupled from
# persona - all gpu-tier characters ride this one server.
$BigPort   = [int]$P.BigPort
$ActiveBig = $P.ActiveBig
$big       = $P.BigModels[$ActiveBig]
if (-not $big) { throw "ActiveBig '$ActiveBig' not found in BigModels (power-profiles.psd1)" }

function Get-PortPid([int]$Port) {
    $c = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($c) { return $c[0].OwningProcess }
    return $null
}

function Kill-Port([int]$Port, [string]$Label) {
    $procId = Get-PortPid $Port
    if ($procId) {
        Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
        Write-Host "[kill] ${Label}: PID $procId on :$Port"
    } else {
        Write-Host "[kill] ${Label}: nothing on :$Port"
    }
}

function Ensure-GpuServer([string]$Repo, [string]$Path, [int]$Port, [string]$Alias) {
    if (Get-PortPid $Port) {
        Write-Host "[arm] $Alias :$Port already up"
        return
    }
    if (-not (Test-Path $LlamaServer)) { throw "llama-server not found at $LlamaServer" }
    # Prefer a concrete on-disk path (-m, what the GUI launcher writes); fall
    # back to an -hf repo string (resolves from the HF cache).
    if ($Path) {
        if (-not (Test-Path $Path)) { throw "model file not found: $Path" }
        $modelArgs = @("-m", $Path)
        $src = $Path
    } elseif ($Repo) {
        $modelArgs = @("-hf", $Repo)
        $src = $Repo
    } else {
        throw "character '$Alias' has neither Path nor Repo set in power-profiles.psd1"
    }
    Write-Host "[arm] $Alias :$Port ($src)"
    Start-Process -FilePath $LlamaServer `
        -ArgumentList ($modelArgs + @("--host","0.0.0.0","--port","$Port",
                        "--ctx-size","8192","--n-gpu-layers","999",
                        "--alias",$Alias,"--jinja")) `
        -WindowStyle Hidden
}

function New-LlmCfg([string]$Model, [int]$Port, [string]$EndpointOverride) {
    $endpoint = if ($EndpointOverride) { $EndpointOverride } else { "http://${DockerHost}:${Port}/v1" }
    return @{
        model       = $Model
        endpoint    = $endpoint
        provider    = $Provider
        api_key_env = $ApiKeyEnv
    }
}

# ---- Resolve per-character target + GPU server actions ----
$instances = @()
$gpuPortsInUse = @()   # ports that must stay armed in this mode

# Arm the ONE shared ActiveBig server once, if PRIME and any gpu-tier char.
if ($Mode -eq "prime" -and ($P.Characters | Where-Object { $_.Prime.Tier -eq "gpu" })) {
    Ensure-GpuServer -Repo $big.Repo -Path $big.Path -Port $BigPort -Alias $big.Alias
    $gpuPortsInUse += $BigPort
}

foreach ($ch in $P.Characters) {
    $name = $ch.Name
    if ($Mode -eq "prime") {
        $pr = $ch.Prime
        if ($pr.Tier -eq "gpu") {
            # all gpu personas share the one ActiveBig server on BigPort
            $cfg = New-LlmCfg -Model $big.Alias -Port $BigPort
        } else {
            # nano-tier character: uses the always-on :8082
            $cfg = New-LlmCfg -Model $NanoAlias -Port ([int]$NanoPort)
        }
    }
    else {
        # ECO: everyone -> nano, unless Sam override given
        if ($name -eq "Sam" -and $SamEndpoint) {
            if (-not $SamModel) { throw "-SamEndpoint requires -SamModel" }
            $cfg = New-LlmCfg -Model $SamModel -Port 0 -EndpointOverride $SamEndpoint
            Write-Host "[eco] Sam piggybacks $SamModel @ $SamEndpoint"
        } else {
            $cfg = New-LlmCfg -Model $NanoAlias -Port ([int]$NanoPort)
        }
    }

    $instances += @{
        db      = $ch.Db
        entries = @{
            "llm.chat"         = $cfg
            "llm.heartbeat"    = $cfg
            "llm.subconscious" = $cfg
        }
    }
    Write-Host "[plan] $name ($($ch.Db)) -> $($cfg.model) @ $($cfg.endpoint)"
}

# ---- ECO: kill the shared GPU server (free VRAM) ----
if ($Mode -eq "eco") {
    Kill-Port $BigPort $ActiveBig
}
# Never touch nano (:8082) or embed (:8081).

# ---- Flip the DBs via the asyncpg applier ----
$plan = @{
    dsn_base  = $P.PgDsnBase
    instances = $instances
}
$planFile = Join-Path $LogDir ("power-plan_{0}.json" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
($plan | ConvertTo-Json -Depth 12) | Set-Content -Path $planFile -Encoding utf8

$py = Join-Path $Root "venv\Scripts\python.exe"
if (-not (Test-Path $py)) { throw "venv python not found at $py" }
Write-Host "[db] flipping $($instances.Count) instance(s) via set_power_mode.py"
# PS 5.1: native stderr under EAP=Stop is a terminating error. set_power_mode.py
# prints per-DB progress/errors to stderr; demote EAP so we reach the rc check.
$eapPrev = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & $py (Join-Path $Root "scripts\set_power_mode.py") --plan $planFile 2>&1 | ForEach-Object { Write-Host $_ }
    $pyRc = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $eapPrev
}
if ($pyRc -ne 0) { throw "set_power_mode.py failed (exit $pyRc) - plan: $planFile" }

# Mode marker - cheap source of truth for hexis-vram-guard.ps1 (no DB/port probe).
$markerFile = Join-Path $LogDir "current-mode.txt"
[System.IO.File]::WriteAllText($markerFile, "$Mode`n$(Get-Date -Format o)",
    (New-Object System.Text.UTF8Encoding($false)))

Write-Host ""
Write-Host "[done] power mode = $($Mode.ToUpper())"
Write-Host "  Config flip takes effect on each character's next heartbeat/chat (no worker restart)."
if ($Mode -eq "eco") {
    Write-Host "  GPU servers killed. VRAM freed for your own heavy work."
} else {
    Write-Host "  GPU servers armed: $($gpuPortsInUse -join ', ')"
}

}
catch {
    Write-Host "[FAIL] $($_.Exception.GetType().Name): $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
    throw
}
finally {
    Write-Host "[log] $LogFile"
    Stop-Transcript | Out-Null
}
