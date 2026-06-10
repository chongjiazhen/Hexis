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
# llama-servers, frees VRAM). When the trigger clears and stays clear for
# $PrimeRearmMinutes, auto-restores PRIME - but ONLY if this guard caused the
# ECO (eco flag present). A manual `set-power-mode.ps1 eco` is never overridden.
#
# Runs hidden, single-instance, started by start-all.ps1. Edit the config
# block below by hand (especially $GameProcs).

$ErrorActionPreference = "Continue"   # daemon: robustness over strictness
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

. (Join-Path $Root "guard-decisions.ps1")   # pure decision fns (testable)

# ----------------- CONFIG (hand-edit) -----------------
# Detection on consumer GeForce is process-based: nvidia-smi reports per-process
# VRAM as [N/A] under WDDM, and in PRIME the card is already full so a reactive
# VRAM signal is too late. So the reliable triggers are NAME and PATH.
#
# 1) $GameProcs - exact process base names WITHOUT .exe (catches games even if
#    installed outside the dirs below).
$GameProcs = @(
    'eldenring'
    # 'Cyberpunk2077', 'RDR2', 'bf2042', 'starfield'
)
# 2) $GameDirs - ANY process whose .exe lives under one of these roots trips
#    the guard. Covers games you forgot to list. Add your launchers/libraries.
$GameDirs = @(
    'C:\Program Files (x86)\Steam\steamapps\common',
    'C:\Program Files\Epic Games',
    'C:\Program Files\Steam\steamapps\common',
    'C:\XboxGames',
    'C:\Program Files (x86)\GOG Galaxy\Games',
    'C:\Program Files\EA Games',
    'C:\Program Files (x86)\Origin Games',
    'C:\Program Files\Electronic Arts',
    'C:\Program Files (x86)\Electronic Arts',
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
# PRIME re-arm: GPU must be CONTINUOUSLY clear this many minutes before the
# guard auto-switches back to PRIME. Conservative on purpose - re-arm is QOL,
# not urgent; cold-start on :8080 is ~4 min on top of this anyway. Any single
# trigger sample resets the countdown.
$PrimeRearmMinutes  = 15
# Eco-retry backoff: after a FAILED eco switch the guard stays ARMED and retries
# (a single transient set-power-mode failure must not wedge the box in PRIME).
# This gates how often it respawns set-power-mode so a fast-failing switch does
# not hammer it every poll.
$EcoRetryBackoffSeconds = 15
# --- gpu-llm liveness self-heal (F1) ---
# Re-arm a silently-dead :8080 (gpu-llm crashed post-arm; marker still PRIME).
# Recovery layer; the ctx-checkpoint crash itself is prevented at source (start.ps1
# + models.json `--ctx-checkpoints 0`). $GpuPort is hand-synced to power-profiles.psd1
# BigPort (one constant, like $LlamaExeName - the guard does not import the psd1).
$GpuPort              = 8080   # ActiveBig liveness port (== psd1 BigPort)
$GpuDownSamples       = 15     # ~60s continuous down before re-arm (15 * $PollSeconds)
$ReArmBudget          = 3      # consecutive failed re-arms before giving up
$ReArmCooldownMinutes = 30     # after giving up, grant one more retry this long later
# ------------------------------------------------------

$LogDir = Join-Path $Root "logs"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
$GuardLog   = Join-Path $LogDir "vram-guard.log"
$MarkerFile = Join-Path $LogDir "current-mode.txt"
$LockFile   = Join-Path $LogDir "vram-guard.lock"
$EcoFlag    = Join-Path $LogDir "guard-triggered-eco.flag"
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
    # Stamp the guard-caused flag BEFORE the switch, not after. The switch is the
    # exact moment the guard is most likely to die (set-power-mode eco kills the
    # GPU llama-servers; host sleep/resume often coincides with launching a game).
    # If the guard is killed mid-switch, a flag written afterward never lands, and
    # the next guard start reads an un-flagged ECO as a deliberate manual ECO and
    # refuses to re-arm PRIME - wedged forever. Writing the flag first makes a
    # crash-during-switch survivable: the next guard sees the flag and re-arms.
    # Marks this ECO as guard-caused; a manual `set-power-mode.ps1 eco` writes no
    # flag, so the guard still never overrides a deliberate manual ECO.
    [System.IO.File]::WriteAllText($EcoFlag,
        (Get-Date -Format o), (New-Object System.Text.UTF8Encoding($false)))
    Log "wrote eco flag ($EcoFlag) before switch - PRIME re-arm enabled"
    $psArgs = @("-NoProfile","-ExecutionPolicy","Bypass","-File","`"$SetMode`"","eco")
    $proc = Start-Process powershell -ArgumentList $psArgs -WorkingDirectory $Root `
        -WindowStyle Hidden -PassThru -Wait
    Log "set-power-mode eco exited $($proc.ExitCode)"
    if ($proc.ExitCode -ne 0) {
        # Clean failure (switch ran, returned nonzero): GPU likely still armed,
        # so drop the flag - no re-arm needed for an ECO that didn't take.
        Remove-Item $EcoFlag -ErrorAction SilentlyContinue
        Log "eco exit nonzero - flag removed (no auto re-arm for a failed switch)"
        return $false
    }
    return $true
}

function Invoke-Prime {
    Log "RE-ARM -> switching to PRIME (set-power-mode.ps1 prime)"
    $psArgs = @("-NoProfile","-ExecutionPolicy","Bypass","-File","`"$SetMode`"","prime")
    $proc = Start-Process powershell -ArgumentList $psArgs -WorkingDirectory $Root `
        -WindowStyle Hidden -PassThru -Wait
    Log "set-power-mode prime exited $($proc.ExitCode)"
    if ($proc.ExitCode -eq 0) {
        Remove-Item $EcoFlag -ErrorAction SilentlyContinue
        Log "PRIME re-armed; eco flag cleared"
    } else {
        Log "prime exit nonzero - flag kept; retry after another clear window"
    }
}

$armed = $true
$hits  = 0
$clearSince = $null   # timestamp GPU first went clear; $null while triggered
$lastPoll = Get-Date  # for wake detection: a big gap between polls = host slept
$ecoRetryAfter = $null  # while set, suppress eco retries until this time (backoff)

# F1 gpu-llm liveness state
$gpuDownHits = 0
$reArmBudget = $ReArmBudget
$gaveUpAt    = $null   # set when budget hits 0; drives the cooldown retry window

try {
    while ($true) {
        # Wake detection: poll cadence is $PollSeconds (4s). A gap far larger than
        # that means the process was suspended - host sleep/hibernate (or a long
        # switch). On the first poll after such a gap, treat it as a resume and
        # skip the PRIME re-arm cooldown below, so a guard-caused ECO restored
        # before sleep comes straight back to PRIME on wake (if the GPU is clear),
        # instead of waiting a full $PrimeRearmMinutes of awake time. Self-contained:
        # no dependency on the OS logging wake events (this box often doesn't).
        $now      = Get-Date
        $gapSec   = ($now - $lastPoll).TotalSeconds
        $lastPoll = $now
        $resumed  = $gapSec -gt 180
        if ($resumed) { Log ("resume detected (poll gap {0:N0}s) - will skip re-arm cooldown if GPU clear" -f $gapSec) }

        $game    = Test-GameRunning
        $foreign = Get-ForeignGpuMB
        $trig    = $game -or ($foreign -gt $MinForeignVramMB)

        if ($trig) {
            $hits++
            $clearSince = $null   # any trigger resets the PRIME re-arm countdown
            $mode = Get-Mode
            $ecoDecision = Get-EcoTriggerDecision -Armed $armed -Hits $hits `
                -Threshold $ConsecutiveSamples -Mode $mode
            switch ($ecoDecision.Action) {
                'attempt-eco' {
                    # Backoff gate: a fast-failing eco (e.g. a transient module
                    # autoload error) would otherwise respawn set-power-mode every
                    # poll while the trigger persists.
                    $blocked = ($ecoRetryAfter -and ((Get-Date) -lt $ecoRetryAfter))
                    if (-not $blocked) {
                        Log "sustained trigger (game=$game foreignMB=$foreign) mode=$mode"
                        $ecoOk = Invoke-Eco
                        $armed = Get-ArmedAfterEco -Action 'attempt-eco' -EcoSucceeded $ecoOk
                        if ($ecoOk) {
                            $ecoRetryAfter = $null
                        } else {
                            # Stay armed; the switch did NOT take. Retry after the
                            # backoff so one transient failure can't strand PRIME.
                            $ecoRetryAfter = (Get-Date).AddSeconds($EcoRetryBackoffSeconds)
                            Log ("eco switch FAILED - staying armed; retry after {0}s" -f $EcoRetryBackoffSeconds)
                        }
                    }
                }
                'already-eco' {
                    Log "trigger but mode=$mode - nothing to do"
                    $armed = Get-ArmedAfterEco -Action 'already-eco' -EcoSucceeded $true
                }
                # 'wait' -> not armed yet or debounce not met; no action
            }
        } else {
            $hits = 0
            $ecoRetryAfter = $null   # trigger gone; clear any eco-retry backoff
            if (-not $armed) {
                Log "trigger cleared - re-armed (PRIME re-arm countdown started)"
                $armed = $true
            }
            if (-not $clearSince) { $clearSince = Get-Date }

            # PRIME re-arm: GPU continuously clear >= $PrimeRearmMinutes AND the
            # current ECO was guard-caused (flag present). Manual ECO has no flag
            # and is never overridden.
            $mode = Get-Mode
            if ($mode -ne 'eco') {
                # Already GPU-armed (manual PRIME, or our own re-arm) - any flag
                # is stale; drop it so a future manual ECO is not auto-reverted.
                if (Test-Path $EcoFlag) {
                    Remove-Item $EcoFlag -ErrorAction SilentlyContinue
                    Log "mode=$mode (not eco) - cleared stale eco flag"
                }
            } elseif (Test-Path $EcoFlag) {
                $clearMin = ((Get-Date) - $clearSince).TotalMinutes
                # Re-arm now if EITHER we just woke (resume) OR the GPU has been
                # continuously clear for the full cooldown. The clear branch means
                # the guard's own detection sees no game/foreign GPU, so a resume
                # skip is safe - it only short-circuits the timer, not the safety
                # check. Manual ECO (no $EcoFlag) is excluded by the elseif above.
                if ($resumed -or $clearMin -ge $PrimeRearmMinutes) {
                    if ($resumed) {
                        Log "resume + GPU clear + guard-caused ECO - re-arming PRIME now (cooldown skipped)"
                    } else {
                        Log ("GPU clear {0:N1}m >= {1}m - re-arming PRIME" -f $clearMin, $PrimeRearmMinutes)
                    }
                    Invoke-Prime
                    # Reset countdown either way: success -> mode!=eco next loop;
                    # failure -> back off a full window before retrying.
                    $clearSince = Get-Date
                }
            }
        }

        # ---- gpu-llm liveness self-heal (F1) ----
        # Runs every poll regardless of $trig. Acts only in-window (mode != eco,
        # no eco-flag, no game trigger). The pure Get-GpuHealDecision owns the
        # truth table; here we gather impure inputs and run the side effect.
        $modeNow = Get-Mode
        $ecoFlagPresent = Test-Path $EcoFlag
        $gpuUp = [bool](Get-NetTCPConnection -LocalPort $GpuPort -State Listen -ErrorAction SilentlyContinue)
        $cooldownElapsed = $false
        if ($gaveUpAt) {
            $cooldownElapsed = (((Get-Date) - $gaveUpAt).TotalMinutes -ge $ReArmCooldownMinutes)
        }

        $decision = Get-GpuHealDecision -Mode $modeNow -EcoFlagPresent $ecoFlagPresent `
            -Trig $trig -GpuListening $gpuUp -Resumed $resumed -CooldownElapsed $cooldownElapsed `
            -GpuDownHits $gpuDownHits -ReArmBudget $reArmBudget `
            -GpuDownSamples $GpuDownSamples -ReArmBudgetMax $ReArmBudget

        $gpuDownHits = $decision.NewDownHits
        $reArmBudget = $decision.NewBudget

        if ($decision.Action -eq 'rearm') {
            # A cooldown-granted retry comes in with the give-up clock already set;
            # restart it so a failed retry waits another full cooldown, not re-fires
            # every poll.
            if ($cooldownElapsed -and $gaveUpAt) { $gaveUpAt = Get-Date }
            Log ("[gpu-heal] :{0} down >= {1} samples (mode={2}) - re-arming (budget left {3})" -f $GpuPort, $GpuDownSamples, $modeNow, $reArmBudget)
            Invoke-Prime
            # Invoke-Prime blocks ~4min (-Wait through set-power-mode's health gate).
            # Reset the poll baseline so that gap is NOT misread as a host-sleep
            # resume next iteration (which would wrongly reset hits + budget).
            $lastPoll = Get-Date
        }
        elseif ($decision.Reason -eq 'budget-exhausted') {
            if (-not $gaveUpAt) {
                $gaveUpAt = Get-Date
                Log ("[gpu-heal] re-arm failed {0}x; giving up until :{1} recovers or {2}m cooldown" -f $ReArmBudget, $GpuPort, $ReArmCooldownMinutes)
            }
        }
        elseif ($decision.Reason -in @('healthy','resume-reset')) {
            if ($gaveUpAt) {
                $gaveUpAt = $null
                Log ("[gpu-heal] :{0} recovered ({1}) - budget reset, give-up cleared" -f $GpuPort, $decision.Reason)
            }
        }

        Start-Sleep -Seconds $PollSeconds
    }
} finally {
    Remove-Item $LockFile -ErrorAction SilentlyContinue
    Log "guard stopped (PID $PID)"
}
