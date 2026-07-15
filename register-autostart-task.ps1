# register-autostart-task.ps1 - (re)register "Hexis Autostart" NON-elevated.
#
# Why Limited: the old task ran RunLevel Highest + S4U, so every boot-spawned
# child (llama-servers via start.ps1) inherited elevation -> the unkillable
# elevated-orphan footgun serve.py documents (non-elevated taskkill can't touch
# an elevated llama-server; orphan survived every PRIME flip for two weeks,
# 2026-07-10). Nothing in start-all.ps1 needs admin: Docker Desktop.exe launch
# (docker-users group), llama-servers, compose - all user-level.
#
# Why logon-only (boot trigger dropped): Docker Desktop needs an interactive
# session; the old boot-triggered S4U run just burned its 600s engine wait and
# failed, with the logon trigger doing the real work anyway.
#
# ONE-TIME: run from an ELEVATED shell (the old task was registered elevated,
# so replacing it needs admin once). After this, it never needs elevation again.
$ErrorActionPreference = "Stop"
$TaskName = "Hexis Autostart"

$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\hexis\start-all.ps1"'

$logon = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable

$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME `
    -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $action `
    -Trigger $logon -Settings $settings -Principal $principal -Force | Out-Null

$p = (Get-ScheduledTask $TaskName).Principal
Write-Host "registered '$TaskName' (runlevel $($p.RunLevel), logon $($p.LogonType))"
if ($p.RunLevel -ne "Limited") { throw "runlevel is $($p.RunLevel), expected Limited" }
