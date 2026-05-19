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

# ---- llm-serve registry: single source of truth for per-model serve flags ----
# C:\llm-serve\models.json owns ctx/ngl/kv_quant/batch/threads per model and is
# consumed by infra/switch.py, monitor.py, gen-litellm-config. Hexis sources GPU
# serve TUNING from it keyed by ActiveBig; Hexis-specific ORCHESTRATION flags
# (--alias/--jinja/--reasoning-budget) stay here - they are not serve tuning and
# the kobold/SillyTavern consumer must never see them. Falls back to built-in
# defaults when the registry file or the model's entry is absent, so models not
# yet backfilled into the registry keep working unchanged.
$RegistryPath = if ($env:HEXIS_LLM_REGISTRY) { $env:HEXIS_LLM_REGISTRY } else { 'C:\llm-serve\models.json' }
$HFCache = Join-Path $env:USERPROFILE ".cache\huggingface\hub"

function Get-RegistryEntry([string]$Key) {
    if (-not $Key) { return $null }
    if (-not (Test-Path $RegistryPath)) {
        Write-Host "[registry] $RegistryPath not found - built-in serve defaults"
        return $null
    }
    try {
        $reg = Get-Content -Raw -Path $RegistryPath | ConvertFrom-Json
    } catch {
        Write-Host "[registry] parse failed ($($_.Exception.Message)) - built-in serve defaults"
        return $null
    }
    $prop = $reg.PSObject.Properties[$Key]
    if (-not $prop) {
        Write-Host "[registry] no entry '$Key' - built-in serve defaults"
        return $null
    }
    return $prop.Value
}

# Mirror of infra/switch.py build_llama_flags() - KEEP IN SYNC. Returns serve
# tuning args only; the caller appends model source + Hexis orchestration flags.
function Build-RegistryFlags($e) {
    $kv = [string]$e.kv_quant
    if ($kv -notin @('f16','q8_0','q4_0')) { throw "registry: unknown kv_quant '$kv'" }
    $parts = @('-ngl', "$($e.ngl)")
    if ($e.tensor_split) {
        $parts += @('-ts', (($e.tensor_split | ForEach-Object { "$_" }) -join ','), '--split-mode', 'layer')
    }
    $parts += @('--flash-attn','true')
    if ($kv -ne 'f16') { $parts += @('--cache-type-k',$kv,'--cache-type-v',$kv) }
    $parts += @('-c',"$($e.ctx)",'-b',"$($e.batch_logical)",'-ub',"$($e.batch_physical)",
                '--parallel',"$($e.parallel)",'--threads',"$($e.threads)")
    if ($e.extra_flags) { $parts += ([string]$e.extra_flags -split '\s+') }
    return $parts
}

# PS mirror of infra/switch.py find_gguf() + test_registry.py case 5 - KEEP IN
# SYNC. HF cache layout: <hub>\models--<org>--<name>\snapshots\<rev>\*.gguf.
# Globs in models.json llama.file only use '*' (PS -like compatible with fnmatch).
function Resolve-RegistryGguf($llamaCfg) {
    if (-not $llamaCfg -or -not $llamaCfg.repo -or -not $llamaCfg.file) { return $null }
    $hub  = "models--" + ([string]$llamaCfg.repo -replace '/', '--')
    $snap = Join-Path (Join-Path $HFCache $hub) "snapshots"
    if (-not (Test-Path $snap)) { return $null }
    Get-ChildItem -Path $snap -Recurse -Filter *.gguf -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like ([string]$llamaCfg.file) } |
        Select-Object -First 1 -ExpandProperty FullName
}

# Single-registry resolution: alias + gguf source + serve tuning all come from
# C:\llm-serve\models.json keyed by the BigModels key (== ActiveBig). The psd1
# entry is now just a key pointer (no Alias/Path/Repo). Legacy psd1 fields are
# accepted ONLY as a fallback for a key with no registry entry (un-backfilled or
# a retired key whose weights are gone) - that path then hard-fails cleanly.
function Resolve-BigModel([string]$RegistryKey, [string]$LegacyRepo, [string]$LegacyPath, [string]$LegacyAlias) {
    $entry = Get-RegistryEntry $RegistryKey
    if ($entry) {
        $alias = [string]$entry.alias
        if (-not $alias) { throw "registry '$RegistryKey': alias missing" }
        $gguf = Resolve-RegistryGguf $entry.llama
        if (-not $gguf) {
            throw "registry '$RegistryKey' gguf not in HF cache (repo=$($entry.llama.repo) file=$($entry.llama.file)). Download it or pick another ActiveBig."
        }
        return @{
            Alias     = $alias
            ModelArgs = @("-m", $gguf)
            Src       = $gguf
            Tuning    = Build-RegistryFlags $entry
            Tag       = "registry:$RegistryKey ctx=$($entry.ctx) kv=$($entry.kv_quant) ngl=$($entry.ngl)"
        }
    }
    # No registry entry -> legacy psd1 fallback (kept so an un-backfilled model
    # still works byte-for-byte; a retired key with no weights fails cleanly).
    if ($LegacyPath) {
        if (-not (Test-Path $LegacyPath)) { throw "ActiveBig '$RegistryKey': no registry entry and psd1 Path missing on disk: $LegacyPath" }
        $modelArgs = @("-m", $LegacyPath); $src = $LegacyPath
    } elseif ($LegacyRepo) {
        $modelArgs = @("-hf", $LegacyRepo); $src = $LegacyRepo
    } else {
        throw "ActiveBig '$RegistryKey': no registry entry and no psd1 Path/Repo - cannot resolve model source"
    }
    if (-not $LegacyAlias) { throw "ActiveBig '$RegistryKey': legacy fallback requires Alias in power-profiles.psd1" }
    return @{
        Alias     = $LegacyAlias
        ModelArgs = $modelArgs
        Src       = $src
        Tuning    = @('-ngl','999','--flash-attn','true','--cache-type-k','q4_0',
                      '--cache-type-v','q4_0','-c','24576','--parallel','1')
        Tag       = "defaults ctx=24576 kv=q4_0 (no registry entry '$RegistryKey')"
    }
}

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

function Ensure-GpuServer($Resolved, [int]$Port) {
    if (Get-PortPid $Port) {
        Write-Host "[arm] $($Resolved.Alias) :$Port already up"
        return
    }
    if (-not (Test-Path $LlamaServer)) { throw "llama-server not found at $LlamaServer" }
    Write-Host "[arm] $($Resolved.Alias) :$Port ($($Resolved.Src)) [$($Resolved.Tag)]"

    # --repeat-penalty/--repeat-last-n: RP-merge GGUFs at low quant fall into
    # whole-paragraph repetition loops without sequence-level penalty (WorldSim
    # IQ3_XXS). Hexis-orchestration sampler choice, not serve tuning - stays
    # here, NOT in models.json (the kobold/SillyTavern consumer must not inherit
    # it). Applies to every ActiveBig the fleet arms.
    Start-Process -FilePath $LlamaServer `
        -ArgumentList ($Resolved.ModelArgs + @("--host","0.0.0.0","--port","$Port") + $Resolved.Tuning +
                        @("--alias",$Resolved.Alias,"--jinja","--reasoning-budget","0",
                          "--repeat-penalty","1.1","--repeat-last-n","256")) `
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

# Roster = RUNNING worker containers, NOT the frozen psd1 Characters list (that
# list stales: newchars/onboarding personas are absent from it, so ECO/PRIME
# never flipped their llm.chat). Persona = infix in hexis_<persona>_<role>_worker;
# default agent (Sam/hexis_memory) has no infix. Infra containers (brain/api/
# rabbitmq/ui/browser) lack the _worker suffix -> regex skips them.
# Tier source: psd1 Characters lookup by Db (keeps Sam/ENI exact); anything not
# in psd1 (newchars) defaults to gpu - correct for the whole current live fleet.
# (The only nano-tier psd1 entries are dead - no containers - so never enumerated.)
$tierByDb = @{}
foreach ($c in $P.Characters) { $tierByDb[$c.Db] = $c.Prime.Tier }

$names = & docker ps --filter "name=hexis" --format "{{.Names}}" 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "docker ps failed - refusing to flip a partial fleet. Output: $names"
}
$liveSeen = [ordered]@{}
foreach ($n in $names) {
    $n = "$n".Trim()
    if ($n -match '^hexis_(?:(.+)_)?(heartbeat|channel|maintenance)_worker$') {
        $persona = if ($Matches[1]) { $Matches[1] } else { '_default' }
        if (-not $liveSeen.Contains($persona)) {
            if ($persona -eq '_default') { $cn = 'Sam'; $cdb = 'hexis_memory' }
            else { $cn = $persona; $cdb = "hexis_$persona" }
            $ctier = if ($tierByDb.ContainsKey($cdb)) { $tierByDb[$cdb] } else { 'gpu' }
            $liveSeen[$persona] = @{ Name = $cn; Db = $cdb; Tier = $ctier }
        }
    }
}
$liveChars = @($liveSeen.Values)
if ($liveChars.Count -eq 0) { throw "no running hexis worker containers - nothing to flip" }

# Arm the ONE shared ActiveBig server once, if PRIME and any gpu-tier char.
$bigResolved = $null
if ($Mode -eq "prime" -and ($liveChars | Where-Object { $_.Tier -eq "gpu" })) {
    # Single source of truth: alias + gguf + tuning resolved from models.json by
    # ActiveBig key. $big.* (psd1) is only a legacy fallback for un-backfilled keys.
    $bigResolved = Resolve-BigModel $ActiveBig $big.Repo $big.Path $big.Alias
    Ensure-GpuServer $bigResolved $BigPort
    $gpuPortsInUse += $BigPort
}

foreach ($ch in $liveChars) {
    $name = $ch.Name
    if ($Mode -eq "prime") {
        if ($ch.Tier -eq "gpu") {
            # all gpu personas share the one ActiveBig server on BigPort.
            # Model id = registry-resolved alias (== server --alias) so the
            # char DB and the llama-server advertise the same name.
            if (-not $bigResolved) { $bigResolved = Resolve-BigModel $ActiveBig $big.Repo $big.Path $big.Alias }
            $cfg = New-LlmCfg -Model $bigResolved.Alias -Port $BigPort
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
