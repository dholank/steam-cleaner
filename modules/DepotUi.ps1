function Get-DepotBrowseInitialPath {
    param([string]$Path)
    try { if (Test-Path -LiteralPath $Path -PathType Container) { return [IO.Path]::GetFullPath($Path) } } catch {}
    return ''
}

function Set-DepotPathFromBrowse {
    param([string]$CurrentPath, [string]$SelectedPath)
    if ([string]::IsNullOrWhiteSpace($SelectedPath)) { return $CurrentPath }
    return [IO.Path]::GetFullPath($SelectedPath)
}

function Test-DepotFolderCanOpen {
    param([string]$Path)
    try { return [bool](Test-Path -LiteralPath ([IO.Path]::GetFullPath($Path)) -PathType Container) } catch { return $false }
}

function Open-DepotFolder {
    param([Parameter(Mandatory=$true)][string]$Path, [scriptblock]$Launcher)
    if (-not (Test-DepotFolderCanOpen $Path)) { throw 'Download Location does not exist yet.' }
    $full=[IO.Path]::GetFullPath($Path)
    if ($Launcher) { & $Launcher $full; return }
    [Diagnostics.Process]::Start('explorer.exe', ('"' + $full + '"')) | Out-Null
}

function Show-DepotLocationDialog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$InitialPath,
        [bool]$KeepTemporaryDepots=$false,
        [scriptblock]$DialogAdapter
    )

    if ($DialogAdapter) { return (& $DialogAdapter $InitialPath $KeepTemporaryDepots) }
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) { throw 'The download-location dialog requires an STA PowerShell process.' }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object Windows.Forms.Form
    $form.Text = 'Steam Cleaner - Download Location'
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ClientSize = New-Object Drawing.Size(650, 184)

    $label = New-Object Windows.Forms.Label
    $label.Location = New-Object Drawing.Point(12, 14)
    $label.Size = New-Object Drawing.Size(620, 34)
    $label.Text = 'Choose one location. Temporary depot files and the final game folder will both stay on this drive.'
    $form.Controls.Add($label)

    $pathBox = New-Object Windows.Forms.TextBox
    $pathBox.Location = New-Object Drawing.Point(12, 52)
    $pathBox.Size = New-Object Drawing.Size(450, 23)
    $pathBox.Text = $InitialPath
    $form.Controls.Add($pathBox)

    $browse = New-Object Windows.Forms.Button
    $browse.Location = New-Object Drawing.Point(470, 50)
    $browse.Size = New-Object Drawing.Size(75, 27)
    $browse.Text = 'Browse...'
    $form.Controls.Add($browse)

    $open = New-Object Windows.Forms.Button
    $open.Location = New-Object Drawing.Point(551, 50)
    $open.Size = New-Object Drawing.Size(88, 27)
    $open.Text = 'Open Folder'
    $form.Controls.Add($open)

    $keep = New-Object Windows.Forms.CheckBox
    $keep.Location = New-Object Drawing.Point(12, 91)
    $keep.Size = New-Object Drawing.Size(310, 24)
    $keep.Text = 'Keep temporary depot files (advanced)'
    $keep.Checked = $KeepTemporaryDepots
    $form.Controls.Add($keep)

    $cancel = New-Object Windows.Forms.Button
    $cancel.Location = New-Object Drawing.Point(472, 139)
    $cancel.Size = New-Object Drawing.Size(80, 30)
    $cancel.Text = 'Cancel'
    $cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancel)

    $continue = New-Object Windows.Forms.Button
    $continue.Location = New-Object Drawing.Point(558, 139)
    $continue.Size = New-Object Drawing.Size(80, 30)
    $continue.Text = 'Continue'
    $form.Controls.Add($continue)
    $form.CancelButton = $cancel
    $form.AcceptButton = $continue

    $refreshOpen = {
        $open.Enabled = Test-DepotFolderCanOpen $pathBox.Text
    }
    $pathBox.Add_TextChanged($refreshOpen)
    & $refreshOpen

    $browse.Add_Click({
        $picker = New-Object Windows.Forms.FolderBrowserDialog
        $picker.Description = 'Steam Cleaner download location'
        $picker.SelectedPath = Get-DepotBrowseInitialPath $pathBox.Text
        if ($picker.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK) { $pathBox.Text = Set-DepotPathFromBrowse $pathBox.Text $picker.SelectedPath }
        $picker.Dispose()
    })
    $open.Add_Click({ Open-DepotFolder $pathBox.Text })
    $continue.Add_Click({
        try {
            $selected = Assert-DepotPath $pathBox.Text -Create
            if (-not (Test-DepotRootWritable $selected)) { throw 'The selected location is not writable.' }
            $form.Tag = [pscustomobject]@{ Accepted=$true; DownloadRoot=$selected; KeepTemporaryDepots=[bool]$keep.Checked }
            $form.DialogResult = [Windows.Forms.DialogResult]::OK
            $form.Close()
        } catch { [Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Steam Cleaner', 'OK', 'Error') | Out-Null }
    })

    $result = $form.ShowDialog()
    $value = if ($result -eq [Windows.Forms.DialogResult]::OK) { $form.Tag } else { [pscustomobject]@{ Accepted=$false; DownloadRoot=$InitialPath; KeepTemporaryDepots=$KeepTemporaryDepots } }
    $form.Dispose()
    return $value
}

function Select-DepotLocation {
    param([Parameter(Mandatory=$true)]$Settings, [scriptblock]$DialogAdapter, [string]$StoredSettingsPath=(Get-SteamCleanerSettingsPath))
    $choice = Show-DepotLocationDialog -InitialPath $Settings.DownloadRoot -KeepTemporaryDepots:$Settings.KeepTemporaryDepots -DialogAdapter $DialogAdapter
    if (-not $choice.Accepted) { return $null }
    Write-SteamCleanerSettings -DownloadRoot $choice.DownloadRoot -KeepTemporaryDepots $choice.KeepTemporaryDepots -Path $StoredSettingsPath
    $Settings.DownloadRoot = $choice.DownloadRoot
    $Settings.KeepTemporaryDepots = [bool]$choice.KeepTemporaryDepots
    return $Settings
}
