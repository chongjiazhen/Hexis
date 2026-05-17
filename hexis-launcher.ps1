# hexis-launcher.ps1 - GUI front-end for ECO/PRIME (ActiveBig schema).
#
# A thin face over the engine. It does NOT hold logic:
#   - scans *.gguf on disk (HF cache),
#   - lets you pick the single ActiveBig GPU model + per-character gpu/nano
#     tier + a mode,
#   - on Apply: REWRITES power-profiles.psd1 (the canonical store) in the
#     ActiveBig schema, then calls set-power-mode.ps1.
#
# Single GPU slot: 16 GB VRAM holds exactly one ~13 GB model. ALL gpu-tier
# characters share ONE llama-server on BigPort serving ActiveBig (persona is
# applied by Hexis at the conversation layer). nano-tier characters ride the
# always-on CPU nano (:8082). Switching the GPU model = pick a different
# ActiveBig + Apply PRIME. It is NOT a mode.
#
# power-profiles.psd1 stays hand-editable; Apply overwrites it (expected - the
# GUI is just another editor of the same store, the redundancy you wanted).
# Apply writes the FULL ActiveBig schema and never drops a BigModels entry,
# so it is safe to run against set-power-mode.ps1 (the old per-char-Path
# hazard is gone).
#
# Run: powershell -ExecutionPolicy Bypass -File C:\hexis\hexis-launcher.ps1
# (a desktop "Hexis Launcher" shortcut is created by make-power-shortcuts.ps1)
#
# Dot-sourcing this file (. .\hexis-launcher.ps1) loads the helpers WITHOUT
# showing the GUI, so Write-Profile can be driven headlessly for tests.

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ProfilePath = Join-Path $Root "power-profiles.psd1"
$SetMode     = Join-Path $Root "set-power-mode.ps1"
if (-not (Test-Path $ProfilePath)) { throw "power-profiles.psd1 not found at $ProfilePath" }
if (-not (Test-Path $SetMode))     { throw "set-power-mode.ps1 not found at $SetMode" }

$P = Import-PowerShellDataFile -Path $ProfilePath

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

# Find an on-disk *.gguf that backs a BigModels entry whose Path is empty.
# A concrete -m path beats the -hf Repo fallback in set-power-mode.ps1, so we
# fill Path when the file is already in the HF cache. Repo is never dropped.
function Resolve-DiskPath([string]$Repo, [string]$Alias, $DiskFiles) {
    # 1) HF cache layout: <hub>\models--<org>--<name>\snapshots\<rev>\*.gguf
    if ($Repo) {
        $repoNoQuant = ($Repo -split ':')[0]                 # org/name (drop :QUANT)
        $hubDir = "models--" + ($repoNoQuant -replace '/', '--')
        foreach ($f in $DiskFiles.Values) {
            if ($f -like "*$hubDir*") { return $f }
        }
    }
    # 2) Fallback: normalize the alias and the file stem the same way, match.
    if ($Alias) {
        $aliasNorm = ($Alias.ToLower() -replace '[^a-z0-9]+', '')
        foreach ($f in $DiskFiles.Values) {
            $stemNorm = ([System.IO.Path]::GetFileNameWithoutExtension($f).ToLower() -replace '[^a-z0-9]+', '')
            if ($stemNorm -eq $aliasNorm -or $stemNorm -like "$aliasNorm*") { return $f }
        }
    }
    return $null
}

function Quote([object]$v) {
    if ($null -eq $v) { return "''" }
    return "'" + ([string]$v -replace "'", "''") + "'"
}

# Build the canonical psd1 text in the ActiveBig schema from the chosen
# ActiveBig key + per-character tier rows, preserving every untouched setting
# and EVERY BigModels entry. $TierRows = @( @{ Name; Db; Tier } ).
# Single source of truth for the GUI Apply and headless tests.
function Write-Profile([string]$ActiveKey, $TierRows) {
    if (-not $P.BigModels.Contains($ActiveKey)) {
        throw "ActiveBig '$ActiveKey' is not a key in BigModels"
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("#")
    [void]$sb.AppendLine("# power-profiles.psd1 - canonical ECO/PRIME store.")
    [void]$sb.AppendLine("# AUTO-WRITTEN by hexis-launcher.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm'). Hand-editable;")
    [void]$sb.AppendLine("# the launcher's Apply overwrites this file (the GUI is just another editor")
    [void]$sb.AppendLine("# of the same store). See .local-notes/power-modes.md.")
    [void]$sb.AppendLine("#")
    [void]$sb.AppendLine("@{")
    [void]$sb.AppendLine("    LlamaServer = $(Quote $P.LlamaServer)")
    [void]$sb.AppendLine("    PgDsnBase   = $(Quote $P.PgDsnBase)")
    [void]$sb.AppendLine("    DockerHost  = $(Quote $P.DockerHost)")
    [void]$sb.AppendLine("    Provider    = $(Quote $P.Provider)")
    [void]$sb.AppendLine("    ApiKeyEnv   = $(Quote $P.ApiKeyEnv)")
    $nanoParts = @("Alias = $(Quote $P.Nano.Alias)")
    if ($P.Nano.Repo) { $nanoParts += "Repo = $(Quote $P.Nano.Repo)" }
    $nanoParts += "Port = $([int]$P.Nano.Port)"
    [void]$sb.AppendLine("    Nano  = @{ $($nanoParts -join '; ') }")
    [void]$sb.AppendLine("    Embed = @{ Port = $([int]$P.Embed.Port) }")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("    # --- Single GPU slot -------------------------------------------------")
    [void]$sb.AppendLine("    # 16 GB VRAM = exactly one ~13 GB model resident. ALL gpu-tier characters")
    [void]$sb.AppendLine("    # share ONE llama-server on BigPort serving ActiveBig; the persona is")
    [void]$sb.AppendLine("    # applied by Hexis at the conversation layer, not by the weights. Switch")
    [void]$sb.AppendLine("    # model = change ActiveBig + re-run set-power-mode prime. NOT a mode.")
    [void]$sb.AppendLine("    BigPort   = $([int]$P.BigPort)")
    [void]$sb.AppendLine("    ActiveBig = $(Quote $ActiveKey)")
    [void]$sb.AppendLine("    BigModels = @{")
    foreach ($k in ($P.BigModels.Keys | Sort-Object)) {
        $m = $P.BigModels[$k]
        $alias = if ($null -eq $m.Alias) { '' } else { [string]$m.Alias }
        $repo  = if ($null -eq $m.Repo)  { '' } else { [string]$m.Repo }
        $path  = if ($null -eq $m.Path)  { '' } else { [string]$m.Path }
        # Fill the chosen ActiveBig entry's Path from disk if it is empty and
        # the gguf is already cached. Other entries pass through untouched.
        if ($k -eq $ActiveKey -and [string]::IsNullOrEmpty($path)) {
            $disk = Resolve-DiskPath $repo $alias $models
            if ($disk) { $path = $disk }
        }
        $parts = @("Alias = $(Quote $alias)")
        if ($repo) { $parts += "Repo = $(Quote $repo)" }
        $parts += "Path = $(Quote $path)"
        [void]$sb.AppendLine("        $(Quote $k) = @{ $($parts -join '; ') }")
    }
    [void]$sb.AppendLine("    }")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("    # gpu-tier characters all resolve to ActiveBig on BigPort (shared server).")
    [void]$sb.AppendLine("    # nano-tier characters use the always-on CPU nano (:8082).")
    [void]$sb.AppendLine("    Characters = @(")
    foreach ($r in $TierRows) {
        $tier = if ($r.Tier -eq "gpu") { "gpu" } else { "nano" }
        [void]$sb.AppendLine("        @{ Name=$(Quote $r.Name); Db=$(Quote $r.Db); Prime=@{ Tier=$(Quote $tier) } }")
    }
    [void]$sb.AppendLine("    )")
    [void]$sb.AppendLine("}")
    [System.IO.File]::WriteAllText($ProfilePath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
}

# Disk scan runs unconditionally (cheap, HF-cache recursive) so a dot-sourced
# Write-Profile test has $models without building the GUI.
$models = Get-DiskModels

# ---------------- UI ----------------
function Show-LauncherUI {
    # ActiveBig keys (sorted, stable) + a display string that surfaces the
    # alias/quant so the operator knows what each key serves.
    $bigKeys  = @($P.BigModels.Keys | Sort-Object)
    $bigDisp  = @()
    foreach ($k in $bigKeys) {
        $m = $P.BigModels[$k]
        $src = if ($m.Path) { "on-disk" } elseif ($m.Repo) { "-hf $($m.Repo)" } else { "?" }
        $bigDisp += "{0}   ->   {1}   [{2}]" -f $k, $m.Alias, $src
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Hexis Power Launcher"
    $form.Size = New-Object System.Drawing.Size(760, 480)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false

    $lblMode = New-Object System.Windows.Forms.Label
    $lblMode.Text = "Mode:"
    $lblMode.Location = New-Object System.Drawing.Point(20, 20)
    $lblMode.AutoSize = $true
    $form.Controls.Add($lblMode)

    $rbPrime = New-Object System.Windows.Forms.RadioButton
    $rbPrime.Text = "PRIME (gpu-tier -> shared ActiveBig server)"
    $rbPrime.Location = New-Object System.Drawing.Point(70, 18)
    $rbPrime.AutoSize = $true
    $rbPrime.Checked = $true
    $form.Controls.Add($rbPrime)

    $rbEco = New-Object System.Windows.Forms.RadioButton
    $rbEco.Text = "ECO (all -> CPU nano, frees VRAM)"
    $rbEco.Location = New-Object System.Drawing.Point(420, 18)
    $rbEco.AutoSize = $true
    $form.Controls.Add($rbEco)

    $lblBig = New-Object System.Windows.Forms.Label
    $lblBig.Text = "ActiveBig (single GPU slot):"
    $lblBig.Location = New-Object System.Drawing.Point(20, 56)
    $lblBig.AutoSize = $true
    $form.Controls.Add($lblBig)

    $cboBig = New-Object System.Windows.Forms.ComboBox
    $cboBig.Location = New-Object System.Drawing.Point(195, 53)
    $cboBig.Size = New-Object System.Drawing.Size(530, 24)
    $cboBig.DropDownStyle = "DropDownList"
    foreach ($d in $bigDisp) { [void]$cboBig.Items.Add($d) }
    $seedIdx = [Array]::IndexOf($bigKeys, [string]$P.ActiveBig)
    if ($seedIdx -lt 0) { $seedIdx = 0 }
    $cboBig.SelectedIndex = $seedIdx
    $form.Controls.Add($cboBig)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(20, 90)
    $grid.Size = New-Object System.Drawing.Size(705, 190)
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.RowHeadersVisible = $false
    $grid.SelectionMode = "CellSelect"
    $grid.AutoSizeColumnsMode = "Fill"

    $colChar = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colChar.HeaderText = "Character"
    $colChar.ReadOnly = $true
    $colChar.FillWeight = 50
    [void]$grid.Columns.Add($colChar)

    $colTier = New-Object System.Windows.Forms.DataGridViewComboBoxColumn
    $colTier.HeaderText = "PRIME tier"
    $colTier.FlatStyle = "Flat"
    $colTier.FillWeight = 50
    [void]$colTier.Items.Add("gpu")
    [void]$colTier.Items.Add("nano")
    [void]$grid.Columns.Add($colTier)
    $form.Controls.Add($grid)

    # Seed rows from current psd1 (tier per character).
    foreach ($ch in $P.Characters) {
        $idx = $grid.Rows.Add()
        $row = $grid.Rows[$idx]
        $row.Cells[0].Value = $ch.Name
        $tier = if ($ch.Prime -and $ch.Prime.Tier -eq "gpu") { "gpu" } else { "nano" }
        $row.Cells[1].Value = $tier
        $row.Tag = @{ Db = $ch.Db; Name = $ch.Name }
    }

    $status = New-Object System.Windows.Forms.Label
    $status.Location = New-Object System.Drawing.Point(20, 290)
    $status.Size = New-Object System.Drawing.Size(705, 40)
    $status.Text = "$($models.Count) gguf on disk. Pick ActiveBig + each character's tier, choose mode, Apply. gpu-tier all share ActiveBig on BigPort."
    $form.Controls.Add($status)

    $grpSam = New-Object System.Windows.Forms.GroupBox
    $grpSam.Text = "Sam piggyback (ECO only, optional - reuse a model you already loaded)"
    $grpSam.Location = New-Object System.Drawing.Point(20, 330)
    $grpSam.Size = New-Object System.Drawing.Size(705, 70)
    $form.Controls.Add($grpSam)

    $lblEp = New-Object System.Windows.Forms.Label
    $lblEp.Text = "Endpoint:"
    $lblEp.Location = New-Object System.Drawing.Point(10, 28)
    $lblEp.AutoSize = $true
    $grpSam.Controls.Add($lblEp)

    $txtEp = New-Object System.Windows.Forms.TextBox
    $txtEp.Location = New-Object System.Drawing.Point(70, 25)
    $txtEp.Size = New-Object System.Drawing.Size(320, 22)
    $txtEp.Text = ""
    $grpSam.Controls.Add($txtEp)

    $lblSm = New-Object System.Windows.Forms.Label
    $lblSm.Text = "Model:"
    $lblSm.Location = New-Object System.Drawing.Point(405, 28)
    $lblSm.AutoSize = $true
    $grpSam.Controls.Add($lblSm)

    $txtSm = New-Object System.Windows.Forms.TextBox
    $txtSm.Location = New-Object System.Drawing.Point(455, 25)
    $txtSm.Size = New-Object System.Drawing.Size(235, 22)
    $grpSam.Controls.Add($txtSm)

    $btnApply = New-Object System.Windows.Forms.Button
    $btnApply.Text = "Apply"
    $btnApply.Location = New-Object System.Drawing.Point(555, 410)
    $btnApply.Size = New-Object System.Drawing.Size(80, 28)
    $form.Controls.Add($btnApply)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(645, 410)
    $btnClose.Size = New-Object System.Drawing.Size(80, 28)
    $btnClose.Add_Click({ $form.Close() })
    $form.Controls.Add($btnClose)

    $btnApply.Add_Click({
        try {
            $bi = $cboBig.SelectedIndex
            if ($bi -lt 0) { throw "no ActiveBig selected" }
            $activeKey = $bigKeys[$bi]

            $tierRows = @()
            foreach ($gr in $grid.Rows) {
                $tag = $gr.Tag
                $sel = [string]$gr.Cells[1].Value
                $tier = if ($sel -eq "gpu") { "gpu" } else { "nano" }
                $tierRows += @{ Name = $tag.Name; Db = $tag.Db; Tier = $tier }
            }

            Write-Profile -ActiveKey $activeKey -TierRows $tierRows
            $mode = if ($rbEco.Checked) { "eco" } else { "prime" }

            $argList = @("-NoProfile","-ExecutionPolicy","Bypass","-NoExit",
                         "-File","`"$SetMode`"",$mode)
            if ($mode -eq "eco" -and $txtEp.Text.Trim()) {
                if (-not $txtSm.Text.Trim()) { throw "Sam endpoint given but model is empty" }
                $argList += @("-SamEndpoint",$txtEp.Text.Trim(),"-SamModel",$txtSm.Text.Trim())
            }
            Start-Process powershell -ArgumentList $argList -WorkingDirectory $Root
            $status.Text = "psd1 written (ActiveBig=$activeKey). Launched set-power-mode $($mode.ToUpper()) in a new window - watch it for [done]/[FAIL]."
        } catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Apply failed",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
    })

    [void]$form.ShowDialog()
}

# Show the GUI only when executed directly. Dot-sourcing (. .\hexis-launcher.ps1)
# loads helpers + $P + $models for headless Write-Profile tests, no dialog.
if ($MyInvocation.InvocationName -ne '.') {
    Show-LauncherUI
}
