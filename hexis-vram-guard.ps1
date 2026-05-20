# hexis-vram-guard.ps1 - graceful fallback: auto-switch to ECO when a
# VRAM-heavy app appears, so you don't have to remember before gaming.
#
# Triggers (either):
#   1. A process whose base name is in $GameProcs is running (games use a
#      graphics context and do NOT show in nvidia-smi compute-apps, so the
#      name list is the ONLY reliable signal for them - keep it current).
#   2. A non-llama process holds > $MinForeignVramMB of GPU memory per
#      nvidia-smi compute-apps (catches CUDA apps: img-gen, video AI, training).
#
# On trigger, if currently PRIME -> runs set-power-mode.ps1 eco (kills the GPU
# llama-servers, frees VRAM). NEVER auto-restores PRIME (no flapping) - click
# "Hexis PRIME" yourself when you are done with GPU work.
#
# Runs hidden, single-instance, started by start-all.ps1. Edit the config
# block below by hand (especially $GameProcs).

$ErrorActionPreference = "Continue"   # daemon: robustness over strictness
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

# ----------------- CONFIG (hand-edit) -----------------
# Detection on consumer GeForce is process-based: nvidia-smi reports per-process
# VRAM as [N/A] under WDDM, and in PRIME the card is already full so a reactive
# VRAM signal is too late. So the reliable triggers are NAME and PATH.
#
# 1) $GameProcs - exact process base names WITHOUT .exe (catches games even if
#    installed outside the dirs below).
$GameProcs = @(
    # 'eldenring', 'Cyberpunk2077', 'RDR2', 'bf2042', 'starfield'
)
# 2) $GameDirs - ANY process whose .exe lives under one of these roots trips
#    the guard. Covers games you forgot to list. Add your launchers/libraries.
$GameDirs = @(
    'C:\Program Files (x86)\Steam\steamapps\common',
    'C:\Program Files\Epic Games',
    'C:\Program Files\Steam\steamapps\common',
    'C:\XboxGames',
    'C:\Program Files (x86)\GOG Galaxy\Games',
    'C:\ComfyUI',  # ComfyUI portable: python_embeded\python.exe under here = CUDA hog, treat like a game (one-way PRIME->ECO)
    'C:\Games',
    'C:\GOG Games',
    'D:\Games',
    'D:\GOG Games',
    'E:\Games',
    'E:\GOG Games'
)
# 3) nvidia-smi foreign-CUDA fallback (works only where per-proc VRAM is real;
#    inert on this GeForce - kept for portability, harmless).
$MinForeignVramMB   = 300
$PollSeconds        = 4
$ConsecutiveSamples = 2      # need N consecutive hits before acting (debounce)
$LlamaExeName       = 'llama-server'
# ------------------------------------------------------

$LogDir = Join-Path $Root "logs"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
$GuardLog   = Join-Path $LogDir "vram-guard.log"
$MarkerFile = Join-Path $LogDir "current-mode.txt"
$LockFile   = Join-Path $LogDir "vram-guard.lock"
$SetMode    = Join-Path $Root "set-power-mode.ps1"

function Log([string]$m) {
    $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m
    Add-Content -Path $GuardLog -Value $line
}

# ---- single instance ----
if (Test-Path $LockFile) {
    $old = (Get-Content $LockFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($old -and ($p = Get-Process -Id $old -ErrorAction SilentlyContinue) -and $p.ProcessName -eq 'powershell') {
        Log "another guard already running (PID $old) - exiting"
        return
    }
}
[System.IO.File]::WriteAllText($LockFile, "$PID", (New-Object System.Text.UTF8Encoding($false)))
Log "guard started (PID $PID); poll=${PollSeconds}s games=[$($GameProcs -join ',')] minForeignMB=$MinForeignVramMB"

function Get-Mode {
    # Marker contents (written by set-power-mode.ps1):
    #   'eco'         -> GPU killed, nano serving
    #   'prime'       -> back-compat alias, GPU armed via psd1 ActiveBig
    #   <model key>   -> GPU armed with that specific BigModels key (e.g. 'ablx')
    # Any non-empty value other than 'eco' means GPU is armed. The trigger
    # decision below only cares about 'is ECO' vs 'is GPU-armed'.
    if (Test-Path $MarkerFile) {
        $m = (Get-Content $MarkerFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($m) { return $m.Trim() }
    }
    # No marker: infer from GPU llama ports.
    foreach ($port in 8080, 8083, 8084, 8085) {
        if (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue) {
            return 'prime'
        }
    }
    return 'eco'
}

function Get-LlamaPids {
    return @((Get-Process -Name $LlamaExeName -ErrorAction SilentlyContinue).Id)
}

function Test-GameRunning {
    # (a) exact name match
    foreach ($g in $GameProcs) {
        if (Get-Process -Name $g -ErrorAction SilentlyContinue) {
            Log "gameproc match: name=$g"
            return $true
        }
    }
    # (b) path match: any process whose exe is under a game dir
    if ($GameDirs.Count -gt 0) {
        foreach ($proc in (Get-Process -ErrorAction SilentlyContinue)) {
            $path = $null
            try { $path = $proc.Path } catch { }   # protected procs throw - skip
            if (-not $path) { continue }
            foreach ($d in $GameDirs) {
                if ($path.StartsWith($d, [System.StringComparison]::OrdinalIgnoreCase)) {
                    # Diagnostic: capture parent + command line so silent callers
                    # of e.g. C:\ComfyUI\python_embeded\python.exe are identifiable.
                    # CIM only on match (slower than Get-Process) - rare path.
                    $parentDesc = '?'
                    $cmdLine    = '?'
                    try {
                        $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.Id)" -ErrorAction SilentlyContinue
                        if ($cim) {
                            if ($cim.CommandLine) { $cmdLine = $cim.CommandLine }
                            $ppid = $cim.ParentProcessId
                            if ($ppid) {
                                $pp = Get-Process -Id $ppid -ErrorAction SilentlyContinue
                                if ($pp) {
                                    $ppPath = $null; try { $ppPath = $pp.Path } catch { }
                                    $parentDesc = "$($pp.ProcessName)[$ppid]" + $(if ($ppPath) { " $ppPath" } else { '' })
                                } else {
                                    $parentDesc = "?[$ppid]"
                                }
                            }
                        }
                    } catch { }
                    Log "gamedir match: $($proc.ProcessName) [PID $($proc.Id)] $path (under $d) parent=$parentDesc cmd=$cmdLine"
                    return $true
                }
            }
        }
    }
    return $false
}

function Get-ForeignGpuMB {
    # Sum GPU memory held by compute (CUDA) processes that are NOT llama.
    $llama = Get-LlamaPids
    $raw = & nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits 2>$null
    if (-not $raw) { return 0 }
    $total = 0
    foreach ($line in $raw) {
        $parts = $line -split ',' | ForEach-Object { $_.Trim() }
        if ($parts.Count -lt 2) { continue }
        $cpid = 0; $mem = 0
        if ([int]::TryParse($parts[0], [ref]$cpid) -and [int]::TryParse($parts[1], [ref]$mem)) {
            if ($llama -notcontains $cpid) { $total += $mem }
        }
    }
    return $total
}

function Invoke-Eco {
    Log "TRIGGER -> switching to ECO (set-power-mode.ps1 eco)"
    $psArgs = @("-NoProfile","-ExecutionPolicy","Bypass","-File","`"$SetMode`"","eco")
    $proc = Start-Process powershell -ArgumentList $psArgs -WorkingDirectory $Root `
        -WindowStyle Hidden -PassThru -Wait
    Log "set-power-mode eco exited $($proc.ExitCode)"
}

$armed = $true
$hits  = 0

try {
    while ($true) {
        $game    = Test-GameRunning
        $foreign = Get-ForeignGpuMB
        $trig    = $game -or ($foreign -gt $MinForeignVramMB)

        if ($trig) {
            $hits++
            if ($armed -and $hits -ge $ConsecutiveSamples) {
                $mode = Get-Mode
                # GPU-armed = anything other than 'eco' (prime alias or a
                # specific BigModels key like 'ablx'/'q36'). All flip to ECO.
                if ($mode -ne 'eco') {
                    Log "sustained trigger (game=$game foreignMB=$foreign) mode=$mode"
                    Invoke-Eco
                } else {
                    Log "trigger but mode=$mode - nothing to do"
                }
                $armed = $false   # do not re-fire until trigger clears; never auto-PRIME
            }
        } else {
            $hits = 0
            if (-not $armed) {
                Log "trigger cleared - re-armed (still ECO; PRIME is manual)"
                $armed = $true
            }
        }

        Start-Sleep -Seconds $PollSeconds
    }
} finally {
    Remove-Item $LockFile -ErrorAction SilentlyContinue
    Log "guard stopped (PID $PID)"
}
