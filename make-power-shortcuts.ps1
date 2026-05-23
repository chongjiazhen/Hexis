# make-power-shortcuts.ps1 - Desktop buttons for ECO / PRIME. No admin needed.
#
# Run once (normal PowerShell, no elevation):
#   powershell -ExecutionPolicy Bypass -File C:\hexis\make-power-shortcuts.ps1
#
# Creates:
#   "Hexis ECO"   -> set-power-mode.ps1 eco    (free VRAM; agents drop to CPU-1B)
#   "Hexis PRIME" -> set-power-mode.ps1 prime  (restore per-character models)
#
# Re-running is safe (overwrites).

$ErrorActionPreference = "Stop"
$Root    = Split-Path -Parent $MyInvocation.MyCommand.Path
$SetMode = Join-Path $Root "set-power-mode.ps1"
$Desktop = [Environment]::GetFolderPath("Desktop")

if (-not (Test-Path $SetMode)) {
    throw "set-power-mode.ps1 not found at $SetMode - run from the Hexis repo root."
}

function New-ModeShortcut([string]$Name, [string]$ModeArg) {
    $lnk = Join-Path $Desktop "$Name.lnk"
    $wsh = New-Object -ComObject WScript.Shell
    $sc  = $wsh.CreateShortcut($lnk)
    $sc.TargetPath       = "powershell.exe"
    # Keep the window so the user sees the result / any FAIL line.
    $sc.Arguments        = "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$SetMode`" $ModeArg"
    $sc.WorkingDirectory = $Root
    $sc.IconLocation     = "powershell.exe,0"
    $sc.Description       = "$Name - Hexis power mode"
    $sc.Save()
    Write-Host "[ok] shortcut: $lnk"
}

New-ModeShortcut -Name "Hexis ECO"   -ModeArg "eco"
New-ModeShortcut -Name "Hexis PRIME" -ModeArg "prime"

# GUI launcher (model dropdowns per character + mode + Apply).
$Launcher = Join-Path $Root "hexis-launcher.ps1"
if (Test-Path $Launcher) {
    $lnk = Join-Path $Desktop "Hexis Launcher.lnk"
    $wsh = New-Object -ComObject WScript.Shell
    $sc  = $wsh.CreateShortcut($lnk)
    $sc.TargetPath       = "powershell.exe"
    $sc.Arguments        = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Launcher`""
    $sc.WorkingDirectory = $Root
    $sc.IconLocation     = "powershell.exe,0"
    $sc.Description       = "Hexis Launcher - pick models per character, set ECO/PRIME"
    $sc.Save()
    Write-Host "[ok] shortcut: $lnk"
} else {
    Write-Host "[skip] hexis-launcher.ps1 not present - no launcher shortcut"
}

Write-Host ""
Write-Host "Done. 'Hexis Launcher' = GUI. 'Hexis ECO'/'Hexis PRIME' = one-click mode."
Write-Host "Sam piggyback (ECO + a heavy model you already loaded) stays CLI-only:"
Write-Host "  .\set-power-mode.ps1 eco -SamEndpoint http://host.docker.internal:<port>/v1 -SamModel <name>"
