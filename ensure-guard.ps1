# ensure-guard.ps1 - idempotent: start hexis-vram-guard.ps1 if not already running.
#
# Single source for "make sure the VRAM guard is alive". Called from two places:
#   1. start-all.ps1 (boot/logon, via the Hexis Autostart task)
#   2. the "Hexis Guard Watchdog" scheduled task (repeating, every few minutes)
#
# Why a watchdog: the guard is a long-lived poll loop spawned DETACHED. If it
# dies mid-session (sleep/resume, or the eco-switch teardown - see the 2026-06-04
# wedge), nothing restarts it until the next boot/logon, because the Autostart
# task watches start-all.ps1, which exits immediately after fire-and-forgetting
# the guard. This script, run on a repeating trigger, closes that gap.
#
# Single-instance is enforced by the guard's own lockfile, so calling this every
# few minutes is a cheap no-op whenever the guard is already alive.
$ErrorActionPreference = "Stop"
$Root  = Split-Path -Parent $MyInvocation.MyCommand.Path
$guard = Join-Path $Root "hexis-vram-guard.ps1"
if (-not (Test-Path $guard)) { return }

$LogDir = Join-Path $Root "logs"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
$guardLock = Join-Path $LogDir "vram-guard.lock"

# Alive only if the lockfile names a PID that is a live powershell process. A
# stale lock (dead PID) is ignored here; the guard overwrites it on next start.
$running = $false
if (Test-Path $guardLock) {
    $gpid = (Get-Content $guardLock -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($gpid -and (Get-Process -Id $gpid -ErrorAction SilentlyContinue)) { $running = $true }
}

if ($running) {
    Write-Host "[ensure-guard] already running (PID $gpid)"
} else {
    Write-Host "[ensure-guard] starting vram-guard (auto-ECO on heavy GPU app)"
    Start-Process powershell `
        -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File","`"$guard`"") `
        -WorkingDirectory $Root -WindowStyle Hidden | Out-Null
}
