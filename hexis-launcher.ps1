# hexis-launcher.ps1 - phase-2 GUI front-end for ECO/PRIME.
#
# A thin face over the engine. It does NOT hold logic:
#   - scans *.gguf on disk (HF cache),
#   - lets you pick a model per character + a mode,
#   - on Apply: REWRITES power-profiles.psd1 (the canonical store) then calls
#     set-power-mode.ps1.
#
# power-profiles.psd1 stays hand-editable; Apply overwrites it (expected - the
# GUI is just another editor of the same store, the redundancy you wanted).
#
# Run: powershell -ExecutionPolicy Bypass -File C:\hexis\hexis-launcher.ps1
# (a desktop "Hexis Launcher" shortcut is created by make-power-shortcuts.ps1)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ProfilePath = Join-Path $Root "power-profiles.psd1"
$SetMode     = Join-Path $Root "set-power-mode.ps1"
if (-not (Test-Path $ProfilePath)) { throw "power-profiles.psd1 not found at $ProfilePath" }
if (-not (Test-Path $SetMode))     { throw "set-power-mode.ps1 not found at $SetMode" }

$P = Import-PowerShellDataFile -Path $ProfilePath

# Stable per-character GPU port (so a nano character can be promoted to GPU).
$DefaultGpuPort = @{ Sam = 8080; Baymax = 8083; Rocky = 8084; TARS = 8085 }
$NanoAlias = $P.Nano.Alias
$NanoPort  = [int]$P.Nano.Port
$NanoItem  = "nano-imp-1b  (CPU :$NanoPort, always-on)"

# Model scan roots (HF cache first; add more if you keep gguf elsewhere).
$ScanRoots = @(
    (Join-Path $env:USERPROFILE ".cache\huggingface\hub"),
    (Join-Path $Root "models")
)

function Get-DiskModels {
    $out = [ordered]@{}
    foreach ($r in $ScanRoots) {
        if (-not (Test-Path $r)) { continue }
        Get-ChildItem -Path $r -Recurse -Filter *.gguf -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -gt 0 -and $_.Name -notlike "mmproj*" } |
            ForEach-Object {
                $disp = "{0}  ({1:N1}GB)" -f $_.BaseName, ($_.Length / 1GB)
                if (-not $out.Contains($disp)) { $out[$disp] = $_.FullName }
            }
    }
    return $out
}

function ConvertTo-Alias([string]$Stem) {
    $a = $Stem.ToLower() -replace '[^a-z0-9]+', '-'
    return $a.Trim('-')
}

# Build the canonical psd1 text from the chosen rows + untouched settings.
function Write-Profile($Rows) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("#")
    [void]$sb.AppendLine("# power-profiles.psd1 - canonical ECO/PRIME store.")
    [void]$sb.AppendLine("# AUTO-WRITTEN by hexis-launcher.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm'). Still hand-editable;")
    [void]$sb.AppendLine("# the launcher's Apply overwrites this file. See .reference/power-modes.md.")
    [void]$sb.AppendLine("#")
    [void]$sb.AppendLine("@{")
    [void]$sb.AppendLine("    LlamaServer = '$($P.LlamaServer)'")
    [void]$sb.AppendLine("    PgDsnBase   = '$($P.PgDsnBase)'")
    [void]$sb.AppendLine("    DockerHost  = '$($P.DockerHost)'")
    [void]$sb.AppendLine("    Provider    = '$($P.Provider)'")
    [void]$sb.AppendLine("    ApiKeyEnv   = '$($P.ApiKeyEnv)'")
    [void]$sb.AppendLine("    Nano  = @{ Alias = '$($P.Nano.Alias)'; Repo = '$($P.Nano.Repo)'; Port = $($P.Nano.Port) }")
    [void]$sb.AppendLine("    Embed = @{ Port = $($P.Embed.Port) }")
    [void]$sb.AppendLine("    Characters = @(")
    foreach ($r in $Rows) {
        if ($r.Tier -eq "nano") {
            [void]$sb.AppendLine("        @{ Name='$($r.Name)'; Db='$($r.Db)'; Prime=@{ Tier='nano'; Alias='$NanoAlias'; Port=$NanoPort } }")
        } else {
            $pathEsc = $r.Path -replace "'", "''"
            [void]$sb.AppendLine("        @{ Name='$($r.Name)'; Db='$($r.Db)'; Prime=@{ Tier='gpu'; Alias='$($r.Alias)'; Path='$pathEsc'; Port=$($r.Port) } }")
        }
    }
    [void]$sb.AppendLine("    )")
    [void]$sb.AppendLine("}")
    [System.IO.File]::WriteAllText($ProfilePath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
}

# ---------------- UI ----------------
$models = Get-DiskModels

$form = New-Object System.Windows.Forms.Form
$form.Text = "Hexis Power Launcher"
$form.Size = New-Object System.Drawing.Size(720, 460)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false

$lblMode = New-Object System.Windows.Forms.Label
$lblMode.Text = "Mode:"
$lblMode.Location = New-Object System.Drawing.Point(20, 20)
$lblMode.AutoSize = $true
$form.Controls.Add($lblMode)

$rbPrime = New-Object System.Windows.Forms.RadioButton
$rbPrime.Text = "PRIME (per-character models)"
$rbPrime.Location = New-Object System.Drawing.Point(70, 18)
$rbPrime.AutoSize = $true
$rbPrime.Checked = $true
$form.Controls.Add($rbPrime)

$rbEco = New-Object System.Windows.Forms.RadioButton
$rbEco.Text = "ECO (all -> CPU nano, frees VRAM)"
$rbEco.Location = New-Object System.Drawing.Point(320, 18)
$rbEco.AutoSize = $true
$form.Controls.Add($rbEco)

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Location = New-Object System.Drawing.Point(20, 55)
$grid.Size = New-Object System.Drawing.Size(665, 210)
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.RowHeadersVisible = $false
$grid.SelectionMode = "CellSelect"
$grid.AutoSizeColumnsMode = "Fill"

$colChar = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colChar.HeaderText = "Character"
$colChar.ReadOnly = $true
$colChar.FillWeight = 28
[void]$grid.Columns.Add($colChar)

$colModel = New-Object System.Windows.Forms.DataGridViewComboBoxColumn
$colModel.HeaderText = "PRIME model"
$colModel.FlatStyle = "Flat"
$colModel.FillWeight = 72
[void]$colModel.Items.Add($NanoItem)
foreach ($k in $models.Keys) { [void]$colModel.Items.Add($k) }
[void]$grid.Columns.Add($colModel)
$form.Controls.Add($grid)

# Seed rows from current psd1.
foreach ($ch in $P.Characters) {
    $idx = $grid.Rows.Add()
    $row = $grid.Rows[$idx]
    $row.Cells[0].Value = $ch.Name
    $sel = $NanoItem
    if ($ch.Prime.Tier -eq "gpu") {
        $want = $null
        if ($ch.Prime.Path) {
            $stem = [System.IO.Path]::GetFileNameWithoutExtension($ch.Prime.Path)
            foreach ($k in $models.Keys) { if ($k -like "$stem*") { $want = $k; break } }
        }
        if (-not $want -and $ch.Prime.Repo) {
            foreach ($k in $models.Keys) { if ($k -match [regex]::Escape(($ch.Prime.Repo -split '[:/]')[-2])) { $want = $k; break } }
        }
        if ($want) { $sel = $want }
    }
    $row.Cells[1].Value = $sel
    $row.Tag = @{ Db = $ch.Db; Name = $ch.Name }
}

$status = New-Object System.Windows.Forms.Label
$status.Location = New-Object System.Drawing.Point(20, 275)
$status.Size = New-Object System.Drawing.Size(665, 40)
$status.Text = "$($models.Count) model(s) found on disk. Pick per character, choose mode, Apply."
$form.Controls.Add($status)

$grpSam = New-Object System.Windows.Forms.GroupBox
$grpSam.Text = "Sam piggyback (ECO only, optional - reuse a model you already loaded)"
$grpSam.Location = New-Object System.Drawing.Point(20, 315)
$grpSam.Size = New-Object System.Drawing.Size(665, 70)
$form.Controls.Add($grpSam)

$lblEp = New-Object System.Windows.Forms.Label
$lblEp.Text = "Endpoint:"
$lblEp.Location = New-Object System.Drawing.Point(10, 28)
$lblEp.AutoSize = $true
$grpSam.Controls.Add($lblEp)

$txtEp = New-Object System.Windows.Forms.TextBox
$txtEp.Location = New-Object System.Drawing.Point(70, 25)
$txtEp.Size = New-Object System.Drawing.Size(300, 22)
$txtEp.Text = ""
$grpSam.Controls.Add($txtEp)

$lblSm = New-Object System.Windows.Forms.Label
$lblSm.Text = "Model:"
$lblSm.Location = New-Object System.Drawing.Point(385, 28)
$lblSm.AutoSize = $true
$grpSam.Controls.Add($lblSm)

$txtSm = New-Object System.Windows.Forms.TextBox
$txtSm.Location = New-Object System.Drawing.Point(435, 25)
$txtSm.Size = New-Object System.Drawing.Size(215, 22)
$grpSam.Controls.Add($txtSm)

$btnApply = New-Object System.Windows.Forms.Button
$btnApply.Text = "Apply"
$btnApply.Location = New-Object System.Drawing.Point(515, 395)
$btnApply.Size = New-Object System.Drawing.Size(80, 28)
$form.Controls.Add($btnApply)

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Text = "Close"
$btnClose.Location = New-Object System.Drawing.Point(605, 395)
$btnClose.Size = New-Object System.Drawing.Size(80, 28)
$btnClose.Add_Click({ $form.Close() })
$form.Controls.Add($btnClose)

$btnApply.Add_Click({
    try {
        $rows = @()
        foreach ($gr in $grid.Rows) {
            $tag = $gr.Tag
            $sel = [string]$gr.Cells[1].Value
            if ($sel -eq $NanoItem -or [string]::IsNullOrWhiteSpace($sel)) {
                $rows += @{ Name = $tag.Name; Db = $tag.Db; Tier = "nano" }
            } else {
                $path = $models[$sel]
                $stem = [System.IO.Path]::GetFileNameWithoutExtension($path)
                $rows += @{
                    Name  = $tag.Name; Db = $tag.Db; Tier = "gpu"
                    Path  = $path
                    Alias = (ConvertTo-Alias $stem)
                    Port  = ($DefaultGpuPort[$tag.Name])
                }
            }
        }
        Write-Profile $rows
        $mode = if ($rbEco.Checked) { "eco" } else { "prime" }

        $argList = @("-NoProfile","-ExecutionPolicy","Bypass","-NoExit",
                     "-File","`"$SetMode`"",$mode)
        if ($mode -eq "eco" -and $txtEp.Text.Trim()) {
            if (-not $txtSm.Text.Trim()) { throw "Sam endpoint given but model is empty" }
            $argList += @("-SamEndpoint",$txtEp.Text.Trim(),"-SamModel",$txtSm.Text.Trim())
        }
        Start-Process powershell -ArgumentList $argList -WorkingDirectory $Root
        $status.Text = "psd1 written. Launched set-power-mode $($mode.ToUpper()) in a new window - watch it for [done]/[FAIL]."
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Apply failed",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
})

[void]$form.ShowDialog()
