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

function Ensure-GpuServer([string]$Repo, [int]$Port, [string]$Alias) {
    if (Get-PortPid $Port) {
        Write-Host "[arm] $Alias :$Port already up"
        return
    }
    if (-not (Test-Path $LlamaServer)) { throw "llama-server not found at $LlamaServer" }
    Write-Host "[arm] $Alias :$Port ($Repo)"
    Start-Process -FilePath $LlamaServer `
        -ArgumentList @("-hf",$Repo,
                        "--host","0.0.0.0","--port","$Port",
                        "--ctx-size","8192","--n-gpu-layers","999",
                        "--alias",$Alias,"--jinja") `
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

foreach ($ch in $P.Characters) {
    $name = $ch.Name
    if ($Mode -eq "prime") {
        $pr = $ch.Prime
        if ($pr.Tier -eq "gpu") {
            Ensure-GpuServer -Repo $pr.Repo -Port $pr.Port -Alias $pr.Alias
            $gpuPortsInUse += [int]$pr.Port
            $cfg = New-LlmCfg -Model $pr.Alias -Port ([int]$pr.Port)
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

# ---- ECO: kill every GPU server defined in the profile (free VRAM) ----
if ($Mode -eq "eco") {
    foreach ($ch in $P.Characters) {
        if ($ch.Prime.Tier -eq "gpu") {
            Kill-Port ([int]$ch.Prime.Port) $ch.Prime.Alias
        }
    }
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
& $py (Join-Path $Root "scripts\set_power_mode.py") --plan $planFile
$pyRc = $LASTEXITCODE
if ($pyRc -ne 0) { throw "set_power_mode.py failed (exit $pyRc) - plan: $planFile" }

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
