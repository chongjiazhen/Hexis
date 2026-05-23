# install-hexis-autostart.ps1 - one-time setup for frictionless reboot recovery.
#
# Creates:
#   1. Scheduled Task "Hexis Autostart" - runs start-all.ps1 hidden, fires at
#      BOOT (AtStartup) and at logon, whether or not a user is signed in.
#   2. Forces Docker Desktop's own "start at login" setting on (so the engine
#      comes up the instant a session exists, with no GUI click).
#   3. Desktop shortcuts "Start Hexis" / "Stop Hexis" for manual one-click control.
#
# Windows reality: Docker Desktop's engine (WSL2 VM) cannot run with NO user
# session at all - it is a per-user app. So the AtStartup trigger fires as early
# as Windows allows, then start-all.ps1 patiently waits (up to 10 min, with task
# retries) for the engine; the AtLogOn trigger is the backstop. This is the
# closest to true boot-start possible without removing the Docker Desktop GUI
# dependency (see caveats printed at the end).
#
# Run once, from an ELEVATED PowerShell (Register-ScheduledTask needs admin):
#   powershell -ExecutionPolicy Bypass -File C:\hexis\install-hexis-autostart.ps1
#
# Re-running is safe: it replaces the existing task/shortcuts.

$ErrorActionPreference = "Stop"
$Root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$StartAll  = Join-Path $Root "start-all.ps1"
$Desktop   = [Environment]::GetFolderPath("Desktop")
$TaskName  = "Hexis Autostart"

# Self-log everything (incl. terminating errors) so an elevated-window run that
# flash-closes still leaves a readable trace.
$LogDir = Join-Path $Root "logs"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
$LogFile = Join-Path $LogDir ("install-autostart_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
Start-Transcript -Path $LogFile -Append | Out-Null
Write-Host "[ctx] elevated=$([bool]([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) user=$env:USERNAME"

try {

if (-not (Test-Path $StartAll)) {
    throw "start-all.ps1 not found at $StartAll - run this from the Hexis repo root."
}

# --- 1. Scheduled Task: run start-all.ps1 hidden at BOOT + at logon ---
$psArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$StartAll`""
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $psArgs -WorkingDirectory $Root

# Two triggers: as early as Windows allows (boot) AND every logon (backstop in
# case the boot run timed out before a session/Docker existed).
$trigStartup = New-ScheduledTaskTrigger -AtStartup
$trigLogon   = New-ScheduledTaskTrigger -AtLogOn
$triggers    = @($trigStartup, $trigLogon)

# Settings: unlimited runtime (model load is slow), survive battery/idle, and
# retry several times so a too-early boot attempt bridges until Docker is up.
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 5 `
    -RestartInterval (New-TimeSpan -Minutes 2)

# S4U = "run whether user is logged on or not" WITHOUT storing a password.
# Highest privileges so it can drive the Docker engine. S4U has no interactive
# desktop, which is fine: start-all.ps1 launches Docker Desktop detached and the
# Docker-Desktop-autostart patch below means a logon session brings the engine
# up on its own anyway.
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType S4U -RunLevel Highest

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}
Register-ScheduledTask -TaskName $TaskName `
    -Action $action -Trigger $triggers -Settings $settings -Principal $principal `
    -Description "Bring up full Hexis stack (Docker + llama-servers + all character workers) at boot and logon." | Out-Null
Write-Host "[ok] scheduled task '$TaskName' registered (triggers: at startup + at logon, run whether logged on or not)"

# --- 1b. Force Docker Desktop's own auto-start-at-login setting ---
# So the engine comes up the moment a session exists, no manual GUI launch.
function Enable-DockerDesktopAutoStart {
    $candidates = @(
        (Join-Path $env:APPDATA "Docker\settings-store.json"),
        (Join-Path $env:APPDATA "Docker\settings.json")
    )
    $patched = $false
    foreach ($path in $candidates) {
        if (-not (Test-Path $path)) { continue }
        try {
            $json = Get-Content $path -Raw | ConvertFrom-Json
        } catch {
            Write-Host "[warn] could not parse $path - skipping ($($_.Exception.Message))"
            continue
        }
        # Newer Docker Desktop uses 'AutoStart'; older used 'autoStart'. Set both
        # if present, add 'AutoStart' if neither exists.
        $hasNew = $json.PSObject.Properties.Name -contains 'AutoStart'
        $hasOld = $json.PSObject.Properties.Name -contains 'autoStart'
        if ($hasNew) { $json.AutoStart = $true }
        if ($hasOld) { $json.autoStart = $true }
        if (-not $hasNew -and -not $hasOld) {
            $json | Add-Member -NotePropertyName 'AutoStart' -NotePropertyValue $true
        }
        ($json | ConvertTo-Json -Depth 32) | Set-Content -Path $path -Encoding utf8
        Write-Host "[ok] Docker Desktop auto-start enabled in $path"
        $patched = $true
    }
    if (-not $patched) {
        Write-Host "[warn] no Docker Desktop settings file found - enable 'Start Docker Desktop when you sign in' manually in Docker Desktop > Settings > General."
    }
}
Enable-DockerDesktopAutoStart

# --- 2 & 3. Desktop shortcuts ---
function New-Shortcut([string]$Name, [string]$ScriptArgs) {
    $lnk = Join-Path $Desktop "$Name.lnk"
    $wsh = New-Object -ComObject WScript.Shell
    $sc  = $wsh.CreateShortcut($lnk)
    $sc.TargetPath       = "powershell.exe"
    $sc.Arguments        = "-NoProfile -ExecutionPolicy Bypass -File `"$StartAll`" $ScriptArgs"
    $sc.WorkingDirectory = $Root
    $sc.IconLocation     = "powershell.exe,0"
    $sc.Description       = "$Name (Hexis)"
    $sc.Save()
    Write-Host "[ok] shortcut: $lnk"
}

New-Shortcut -Name "Start Hexis" -ScriptArgs ""
New-Shortcut -Name "Stop Hexis"  -ScriptArgs "-Stop"

Write-Host ""
Write-Host "Done. Stack now auto-starts at BOOT (and again at logon as backstop)."
Write-Host "Manual control: double-click 'Start Hexis' / 'Stop Hexis' on the Desktop."
Write-Host "Logs: $Root\logs\start-all_<timestamp>.log"
Write-Host ""
Write-Host "CAVEAT (Windows): Docker Desktop's engine is a per-user app and cannot"
Write-Host "run with zero user session. The boot trigger fires immediately but"
Write-Host "start-all.ps1 then waits for the engine; full online typically lands a"
Write-Host "few minutes after the machine reaches the logon screen / a user signs in."
Write-Host "For true pre-login headless Docker you'd run the engine via WSL2 + systemd"
Write-Host "(dockerd as a service, no Docker Desktop). Ask if you want that variant."

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
