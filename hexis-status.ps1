# hexis-status.ps1 - one-shot fleet health check.
#
# Reads power-profiles.psd1 (for ports/power mode) + live `docker ps` and reports:
#   - current power mode (logs/current-mode.txt marker)
#   - LLM port liveness + the model each port actually serves
#   - per-character DB: configured?, consent, and the model llm.chat points at
#
# Character roster is enumerated from RUNNING worker containers, NOT the
# psd1 Characters list (that list is frozen pre-newchars and goes stale).
#
# Read-only. Touches nothing. Safe to run any time.
#
#   .\hexis-status.ps1

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

$ProfilePath = Join-Path $Root "power-profiles.psd1"
if (-not (Test-Path $ProfilePath)) { throw "power-profiles.psd1 not found at $ProfilePath" }
$P = Import-PowerShellDataFile -Path $ProfilePath

function Test-Port([int]$Port) {
    $c = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    return [bool]$c
}

function Get-ServedModel([int]$Port) {
    try {
        $r = Invoke-RestMethod -Uri "http://localhost:$Port/v1/models" -TimeoutSec 3 -ErrorAction Stop
        if ($r.data) { return ($r.data | ForEach-Object { $_.id }) -join ", " }
        return "(up, no model list)"
    } catch {
        return "(no /v1/models response)"
    }
}

# DB creds from PgDsnBase (postgresql://user:pass@host:port). Container = hexis_brain.
$dsnBase = $P.PgDsnBase
$dbUser  = "hexis_user"
if ($dsnBase -match "://([^:]+):") { $dbUser = $Matches[1] }

function Get-DbConfig([string]$Db) {
    $sql = "SELECT key || '=' || (value #>> '{}') FROM config WHERE key IN ('agent.is_configured','agent.consent_status') UNION ALL SELECT 'model=' || COALESCE(value->>'model','?') FROM config WHERE key='llm.chat';"
    $out = & docker exec hexis_brain psql -U $dbUser -d $Db -tAc $sql 2>&1
    $h = @{ configured = "?"; consent = "?"; model = "?" }
    if ($LASTEXITCODE -ne 0) { $h.model = "(db unreachable)"; return $h }
    foreach ($line in $out) {
        $line = "$line".Trim()
        if ($line -match '^agent\.is_configured=(.+)$')  { $h.configured = $Matches[1] }
        elseif ($line -match '^agent\.consent_status=(.+)$') { $h.consent = $Matches[1] }
        elseif ($line -match '^model=(.+)$')               { $h.model = $Matches[1] }
    }
    return $h
}

Write-Host ""
Write-Host "=== HEXIS FLEET STATUS ===" -ForegroundColor Cyan

# --- Power mode marker ---
$markerFile = Join-Path $Root "logs\current-mode.txt"
if (Test-Path $markerFile) {
    $marker = (Get-Content $markerFile -Raw).Trim() -split "`n"
    Write-Host ("mode      : {0}  (set {1})" -f $marker[0].ToUpper().Trim(), $marker[1].Trim())
} else {
    Write-Host "mode      : (no marker - set-power-mode never run)"
}

# --- LLM ports ---
Write-Host ""
Write-Host "--- LLM servers ---"
$ports = [ordered]@{
    ("BigPort/ActiveBig=" + $P.ActiveBig) = [int]$P.BigPort
    "Nano"  = [int]$P.Nano.Port
    "Embed" = [int]$P.Embed.Port
}
foreach ($label in $ports.Keys) {
    $pt = $ports[$label]
    if (Test-Port $pt) {
        $model = Get-ServedModel $pt
        Write-Host ("  :{0,-5} {1,-28} UP    {2}" -f $pt, $label, $model) -ForegroundColor Green
    } else {
        Write-Host ("  :{0,-5} {1,-28} DOWN" -f $pt, $label) -ForegroundColor DarkYellow
    }
}

# --- Characters (live workers, not the frozen psd1 roster) ---
Write-Host ""
Write-Host "--- Characters (live workers) ---"

# Persona = infix in hexis_<persona>_<role>_worker. Default agent
# (Sam/hexis_memory) has no infix (hexis_<role>_worker). Infra containers
# (brain/api/rabbitmq/ui/browser) lack the _worker suffix -> regex skips them.
$names = & docker ps --filter "name=hexis" --format "{{.Names}}" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "  (docker unreachable - cannot enumerate live fleet)" -ForegroundColor Red
} else {
    $fleet = [ordered]@{}
    foreach ($n in $names) {
        $n = "$n".Trim()
        if ($n -match '^hexis_(?:(.+)_)?(heartbeat|channel|maintenance)_worker$') {
            $persona = if ($Matches[1]) { $Matches[1] } else { '_default' }
            if (-not $fleet.Contains($persona)) { $fleet[$persona] = @{} }
            $fleet[$persona][$Matches[2]] = $true
        }
    }

    Write-Host ("  {0,-10} {1,-14} {2,-5} {3,-9} {4,-10} {5,-9} {6}" -f `
        "NAME","DB","TIER","WORKERS","CONFIG","CONSENT","MODEL (llm.chat)")

    $order = $fleet.Keys | Sort-Object { if ($_ -eq '_default') { '' } else { $_ } }
    foreach ($persona in $order) {
        if ($persona -eq '_default') { $name = 'Sam'; $db = 'hexis_memory' }
        else { $name = $persona; $db = "hexis_$persona" }

        $roles = $fleet[$persona]
        $w = @()
        if ($roles['heartbeat'])   { $w += 'hb' }
        if ($roles['channel'])     { $w += 'ch' }
        if ($roles['maintenance']) { $w += 'mt' }
        $workers = ($w -join '+')

        $cfg = Get-DbConfig $db
        $tier = if ($cfg.model -like '*nano*') { 'nano' }
                elseif ($cfg.model -like '*unreachable*') { '?' }
                else { 'gpu' }

        $color = "Gray"
        if ($cfg.configured -eq "true" -and $cfg.consent -eq "consent") { $color = "Green" }
        elseif ($cfg.model -like "*unreachable*") { $color = "Red" }
        # channel-only (no heartbeat worker) = onboarding, not yet autonomous
        elseif (-not $roles['heartbeat']) { $color = "DarkYellow" }

        Write-Host ("  {0,-10} {1,-14} {2,-5} {3,-9} {4,-10} {5,-9} {6}" -f `
            $name, $db, $tier, $workers, $cfg.configured, $cfg.consent, $cfg.model) -ForegroundColor $color
    }
}
Write-Host ""
