# ops/backup-fleet.ps1 — full-cluster backup of the hexis_brain Postgres.
#
# Captures ALL databases in the cluster (every hexis_<persona> DB + roles) in a
# single pg_dumpall, gzipped, rotated. Writes to the HOST filesystem so the
# backup survives `docker compose down -v` (the operation that wiped the fleet
# on 2026-05-29). Existing `db-manage.sh backup` only dumps one DB — do not use
# it for the fleet.
#
# Usage:
#   .\ops\backup-fleet.ps1                       # backup to C:\hexis-backups, keep 14
#   .\ops\backup-fleet.ps1 -Dest D:\hexis-backups -Keep 30
#
# Schedule (run AFTER fleet rebuild; point -Dest at the SSD):
#   $a = New-ScheduledTaskAction -Execute "pwsh" `
#        -Argument "-NoProfile -File C:\hexis\ops\backup-fleet.ps1 -Dest D:\hexis-backups"
#   $t = New-ScheduledTaskTrigger -Daily -At 3am
#   Register-ScheduledTask -TaskName "hexis-fleet-backup" -Action $a -Trigger $t `
#        -Description "Nightly pg_dumpall of hexis fleet" -RunLevel Highest

param(
    [string]$Dest      = "C:\hexis-backups",   # use the SSD (e.g. D:\hexis-backups) once installed
    [int]$Keep         = 14,                    # rotation: keep newest N dumps
    [string]$Container = "hexis_brain",
    [string]$User      = "hexis_user"
)
$ErrorActionPreference = "Stop"

# 1. brain must be running (no point dumping a down/empty cluster)
$running = ""
try { $running = (docker inspect -f '{{.State.Running}}' $Container 2>$null) } catch {}
if ($running -ne "true") { Write-Error "[$Container] not running - backup skipped"; exit 1 }

# 2. destination on host fs (NOT inside any docker volume)
New-Item -ItemType Directory -Force -Path $Dest | Out-Null
$ts  = Get-Date -Format "yyyyMMdd_HHmmss"
$out = Join-Path $Dest "hexis_fleet_$ts.sql.gz"

# 3. dump whole cluster -> gzip -> host file.
#    cmd /c redirection is byte-clean for the binary gzip stream; PowerShell's
#    own `>` would re-encode text and corrupt it.
cmd /c "docker exec $Container sh -c ""pg_dumpall -U $User | gzip -c"" > ""$out"""
if ($LASTEXITCODE -ne 0) { Write-Error "pg_dumpall failed (exit $LASTEXITCODE)"; exit 1 }

# 4. sanity: a real fleet dump is well over 1 KB even gzipped
$len = (Get-Item $out).Length
if ($len -lt 1024) { Remove-Item $out -Force; Write-Error "backup too small ($len bytes) - treated as failure"; exit 1 }
Write-Host ("OK  {0}  ({1} MB)" -f $out, [math]::Round($len/1MB,2))

# 5. rotate - keep newest N
Get-ChildItem $Dest -Filter "hexis_fleet_*.sql.gz" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -Skip $Keep |
    Remove-Item -Force -ErrorAction SilentlyContinue
