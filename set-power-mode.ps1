# set-power-mode.ps1 - switch the agent fleet between ECO and PRIME.
#
# PRIME: arm the shared ActiveBig GPU model on :8080; flip all instance DBs to
#        it. Kill nano (:8082) when no live persona is nano-tier - the fleet
#        runs on :8080 post heartbeat-to-GPU migration (2026-05-20).
# ECO:   kill the GPU model server (frees VRAM); ensure CPU nano (:8082) is up
#        + healthy; flip all instance DBs to it. Optionally point Sam at a
#        heavy model you already loaded for your own use (vibe-coding /
#        SillyTavern).
#
# embed (:8081) is owned by start.ps1; never touched here. Nano was previously
# also start.ps1-owned ("always-on") - that contract changed 2026-05-20: nano
# is now ECO-only and this script ensure-launches / kills it.
#
# Usage:
#   .\set-power-mode.ps1 eco
#   .\set-power-mode.ps1 eco -SamEndpoint http://host.docker.internal:8090/v1 -SamModel my-coding-model
#   .\set-power-mode.ps1 prime
#
# Source of truth: power-profiles.psd1 (hand-editable; GUI writes it later).

param(
    # Accepts:
    #   eco            -> kill GPU, flip all DBs to nano
    #   prime          -> arm psd1 ActiveBig (back-compat)
    #   <model key>    -> arm that BigModels key, override psd1 ActiveBig
    #                     for this run, write marker as the model key
    [Parameter(Mandatory = $true, Position = 0)]
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
# Import-PowerShellDataFile lives in Microsoft.PowerShell.Utility. When this
# script is spawned by hexis-vram-guard mid-session, module autoload has been
# seen to transiently miss it -> CommandNotFoundException, which (pre-fix) wedged
# the guard in PRIME for hours (2026-06-09). Ensure the module, then fall back to
# evaluating the psd1 (a plain hashtable literal) so the switch can never die here.
if (-not (Get-Command Import-PowerShellDataFile -ErrorAction SilentlyContinue)) {
    Import-Module Microsoft.PowerShell.Utility -ErrorAction SilentlyContinue
}
if (Get-Command Import-PowerShellDataFile -ErrorAction SilentlyContinue) {
    $P = Import-PowerShellDataFile -Path $ProfilePath
} else {
    Write-Host "[psd1] Import-PowerShellDataFile unavailable - evaluating psd1 literal as fallback"
    $P = & ([scriptblock]::Create((Get-Content -Raw -Path $ProfilePath)))
}

$LlamaServer = $P.LlamaServer
$DockerHost  = $P.DockerHost
$Provider    = $P.Provider
$ApiKeyEnv   = $P.ApiKeyEnv
$NanoPort    = $P.Nano.Port
$NanoAlias   = $P.Nano.Alias
$NanoRepo    = $P.Nano.Repo

# Single shared GPU slot: ActiveBig (1-of-N) on BigPort. Decoupled from
# persona - all gpu-tier characters ride this one server.
#
# Resolve which big model to arm THIS run:
#   $Mode == 'eco'     -> ActiveBig irrelevant (no GPU server armed)
#   $Mode == 'prime'   -> use psd1 ActiveBig (back-compat default)
#   $Mode == <key>     -> override: arm that BigModels key for this run.
#                         psd1 ActiveBig stays as the next-default; hand-edit
#                         the psd1 if you want the override to persist.
$BigPort   = [int]$P.BigPort
$ActiveBig = $P.ActiveBig
$IsEco     = ($Mode -eq 'eco')
$IsPrimeAlias = ($Mode -eq 'prime')
if (-not $IsEco -and -not $IsPrimeAlias) {
    # Treat $Mode as a BigModels key
    if (-not $P.BigModels.ContainsKey($Mode)) {
        $known = ($P.BigModels.Keys | Sort-Object) -join ', '
        throw "Unknown mode '$Mode'. Valid: eco, prime, or a BigModels key. Known keys: $known"
    }
    $ActiveBig = $Mode
}
$big = $P.BigModels[$ActiveBig]
if (-not $IsEco -and -not $big) { throw "ActiveBig '$ActiveBig' not found in BigModels (power-profiles.psd1)" }

# ---- F2 (2026-06-12): serving relocated to llm-serve infra/serve.py ----
# The registry resolution (Get-RegistryEntry / Build-RegistryFlags /
# Resolve-RegistryGguf / Resolve-BigModel) + the arm/kill/health-gate helpers
# (Get-PortPid / Kill-Port / Wait-PortHealth / Ensure-NanoServer /
# Ensure-GpuServer) lived here as a PowerShell mirror of infra/switch.py. They are
# gone: serve.py owns serving (tuning from models.json) and this script calls
# `serve.py arm/eco/ensure-nano/print-alias`. Cognition (the DB flip below) stays.
# Design: C:\llm-serve\docs\INFERENCE-ROUTER-F2-DESIGN.md.

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

# Arm the ONE shared ActiveBig server once, if PRIME-like (eco-not) AND any
# gpu-tier char. PRIME-like = $Mode is 'prime' or any BigModels key — already
# resolved into $ActiveBig above.
$bigAlias = $null
if (-not $IsEco -and ($liveChars | Where-Object { $_.Tier -eq "gpu" })) {
    # Serving (arm/kill/health-gate/exclusivity) is llm-serve serve.py (F2 lift).
    # Hexis keeps one cognition need from the registry: the model ALIAS for the
    # DB llm.chat.model value, read via the single registry reader (print-alias).
    # NB: no `| Select-Object -First 1` — that sends StopUpstreamCommands, kills
    # the py process early, and sets $LASTEXITCODE = -1 (false failure). Capture
    # the (single-line) stdout directly, then trim.
    $bigAlias = & py -3.10 C:\llm-serve\infra\serve.py print-alias $ActiveBig
    if ($LASTEXITCODE -ne 0 -or -not $bigAlias) {
        throw "serve.py print-alias $ActiveBig failed (exit $LASTEXITCODE) - cannot resolve model alias for the DB flip."
    }
    $bigAlias = "$bigAlias".Trim()
    # F2: serving relocated to llm-serve serve.py. Hexis orchestration flags pass
    # through --extra-args; llm-serve owns tuning (models.json) + the health-gate
    # + nano exclusivity. Exit!=0 => dead endpoint => abort before flipping DBs
    # (preserves the "never flip the gpu fleet to a dead :8080" invariant).
    $orchFlags = @("--reasoning-budget","0","--repeat-penalty","1.1","--repeat-last-n","256")
    & py -3.10 C:\llm-serve\infra\serve.py arm $ActiveBig --extra-args ($orchFlags -join ' ')
    if ($LASTEXITCODE -ne 0) {
        throw "serve.py arm $ActiveBig failed health-gate (exit $LASTEXITCODE) - refusing to flip DBs to a dead endpoint. Check C:\llm-serve\logs\serve-8080.log"
    }
    $gpuPortsInUse += $BigPort
}

foreach ($ch in $liveChars) {
    $name = $ch.Name
    if (-not $IsEco) {
        if ($ch.Tier -eq "gpu") {
            # all gpu personas share the one ActiveBig server on BigPort.
            # Model id = registry-resolved alias (== server --alias) so the
            # char DB and the llama-server advertise the same name.
            if (-not $bigAlias) { $bigAlias = "$(& py -3.10 C:\llm-serve\infra\serve.py print-alias $ActiveBig)".Trim() }
            $cfg = New-LlmCfg -Model $bigAlias -Port $BigPort
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
            # Power mode is the single flag the workers gate on:
            #   eco  -> heartbeat skipped, chat returns canned reply, no memory write
            #   prime -> full LLM behavior (chat + autonomous heartbeats resume)
            "agent.power_mode" = $Mode
        }
    }
    Write-Host "[plan] $name ($($ch.Db)) -> $($cfg.model) @ $($cfg.endpoint) [mode=$Mode]"
}

# ---- Nano (:8082) lifecycle ----
# Pre 2026-05-20 the nano was always-on (owned solely by start.ps1) and this
# script "never touched :8082". Post heartbeat-to-GPU migration, the live fleet
# routes at :8080 in PRIME, so nano can be torn down to free ~1.5 GB RAM + 4
# CPU threads. ECO still hard-depends on nano: every DB flips to its endpoint,
# so we must ensure it is up AND healthy before letting the asyncpg applier
# point DBs at it - flipping to a dead endpoint would silently brick the fleet.
if ($Mode -eq "eco") {
    # F2: serve.py owns nano floor + gpu kill + exclusivity (ensure nano healthy
    # FIRST, then free :8080). Nano sampler/reasoning are Hexis orchestration ->
    # --extra-args (mirrors the old Ensure-NanoServer sampler block). Exit!=0 =>
    # nano floor dead => abort before flipping DBs.
    $nanoOrch = @("--temp","0.7","--top-p","0.8","--top-k","20","--min-p","0",
                  "--repeat-penalty","1.1","--reasoning","off")
    & py -3.10 C:\llm-serve\infra\serve.py eco --extra-args ($nanoOrch -join ' ')
    if ($LASTEXITCODE -ne 0) {
        throw "serve.py eco failed (nano :$NanoPort unhealthy, exit $LASTEXITCODE) - refusing to flip DBs to a dead endpoint."
    }
}
# PRIME: serve.py arm already enforced gpu XOR nano (killed nano for exclusivity);
# nothing to tear down here. (Live nano-tier personas are all retired.)
# embed (:8081) is owned by start.ps1; never touched here.

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
