#requires -Version 5.1
[CmdletBinding()]
param([string]$SteamPath, [switch]$PreviewOnly, [switch]$LoadOnly)

function Assert-LocalDirectory {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -notmatch '^[A-Za-z]:[\\/]') { throw 'Use an absolute local drive path.' }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or $item.PSProvider.Name -ne 'FileSystem') { throw 'Not a filesystem directory.' }
    $current = $item
    while ($null -ne $current) {
        if ($current.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked directory rejected: $($current.FullName)" }
        $current = $current.Parent
    }
    $resolved = $item.FullName.TrimEnd('\')
    if ($resolved -eq [IO.Path]::GetPathRoot($resolved).TrimEnd('\')) { throw 'Drive roots are forbidden.' }
    foreach ($protected in @($env:USERPROFILE, $env:windir, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, [Environment]::GetFolderPath('MyDocuments'), [Environment]::GetFolderPath('Desktop'))) {
        if ($protected -and $resolved -eq $protected.TrimEnd('\')) { throw 'Protected directory rejected.' }
    }
    return $resolved
}

function Assert-SteamRoot {
    param([string]$Path)
    $root = Assert-LocalDirectory $Path
    foreach ($name in @('steamapps', 'userdata', 'steam.exe')) {
        $item = Get-Item -LiteralPath (Join-Path $root $name) -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked keep item rejected: $name" }
        if (($name -eq 'steam.exe') -eq $item.PSIsContainer) { throw "Unexpected item type: $name" }
    }
    $exe = Join-Path $root 'steam.exe'
    $signature = Get-AuthenticodeSignature -LiteralPath $exe -ErrorAction Stop
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=Valve Corp(?:\.|oration)?(?:,|$)') {
        throw 'steam.exe must have a valid Valve Authenticode signature.'
    }
    return $root
}

function Find-SteamRoot {
    $candidates = @()
    foreach ($key in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam')) {
        $entry = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if ($entry) { $candidates += $entry.SteamPath; $candidates += $entry.InstallPath }
    }
    if (${env:ProgramFiles(x86)}) { $candidates += Join-Path ${env:ProgramFiles(x86)} 'Steam' }
    if ($env:ProgramFiles) { $candidates += Join-Path $env:ProgramFiles 'Steam' }
    $valid = @(foreach ($candidate in ($candidates | Where-Object { $_ } | Select-Object -Unique)) {
        try { Assert-SteamRoot $candidate } catch { Write-Verbose $_ }
    }) | Select-Object -Unique
    if (@($valid).Count -ne 1) { throw 'No unique valid Steam installation found. Supply -SteamPath explicitly.' }
    return $valid
}

function Assert-SteamStopped {
    $active = @(Get-Process -ErrorAction Stop | Where-Object { $_.ProcessName -match '^(steam.*|gameoverlayui|steamerrorreporter.*)$' })
    if ($active.Count) { throw "Close Steam and its background processes first: $($active.ProcessName -join ', ')" }
}

function Get-CleanupPlan {
    param([string]$Root)
    # Walk manually so no junction or symbolic link is ever traversed.
    foreach ($item in (Get-ChildItem -LiteralPath $Root -Force -ErrorAction Stop)) {
        if ($item.Name -in @('steamapps', 'userdata', 'steam.exe')) { continue }
        Get-CleanupNode -Path $item.FullName -Root $Root
    }
}

function Get-CleanupNode {
    param([string]$Path, [string]$Root)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.FullName.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Target escapes Steam directory.' }
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked item rejected: $Path" }
    if ($item.PSIsContainer) {
        foreach ($child in (Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)) { Get-CleanupNode $child.FullName $Root }
    }
    [pscustomobject]@{ Path = $item.FullName; Directory = $item.PSIsContainer; Length = $(if ($item.PSIsContainer) { 0 } else { $item.Length }); Modified = $item.LastWriteTimeUtc.Ticks }
}

function Invoke-SteamCleanup {
    [CmdletBinding()]
    param([string]$SteamPath, [switch]$PreviewOnly)
    $ErrorActionPreference = 'Stop'
    if ($env:OS -ne 'Windows_NT') { throw 'Windows is required.' }
    if (-not $SteamPath) { $SteamPath = Find-SteamRoot }
    $root = Assert-SteamRoot $SteamPath
    Assert-SteamStopped
    $plan = @(Get-CleanupPlan $root)
    Write-Host "Steam: $root"
    Write-Host 'Keep: steamapps, userdata, steam.exe'
    Write-Host 'PERMANENT deletion includes config, screenshots outside userdata, mods and other custom files outside the keep list. Back up first.'
    $plan | ForEach-Object { Write-Host "DELETE: $($_.Path)" }
    if (-not $plan.Count) { Write-Host 'Nothing to delete.'; return }
    if ($PreviewOnly) { Write-Host 'Preview only. Nothing deleted.'; return }
    $expected = "DELETE $root"
    if ((Read-Host "Type exactly: $expected") -cne $expected) { Write-Host 'Cancelled. Nothing deleted.'; return }
    $null = Assert-SteamRoot $root
    Assert-SteamStopped
    $fresh = @(Get-CleanupPlan $root)
    if (($plan | ConvertTo-Json -Compress) -cne ($fresh | ConvertTo-Json -Compress)) { throw 'Files changed after preview. Run again.' }
    foreach ($target in $plan) {
        Assert-SteamStopped
        $parent = Split-Path -Parent $target.Path
        $null = Assert-LocalDirectory $parent
        if (-not $target.Path.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Target escapes Steam directory.' }
        $item = Get-Item -LiteralPath $target.Path -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Target changed to a link. Stopped.' }
        if ($item.PSIsContainer -ne $target.Directory) { throw 'Target type changed. Stopped.' }
        if ($target.Directory) {
            # Never recursively delete: newly-created contents cause an error.
            [IO.Directory]::Delete($target.Path, $false)
        } else {
            Remove-Item -LiteralPath $target.Path -Force -ErrorAction Stop
        }
    }
    $remaining = @(Get-ChildItem -LiteralPath $root -Force | Where-Object { $_.Name -notin @('steamapps','userdata','steam.exe') })
    if ($remaining.Count) { throw 'New files appeared during cleanup. Inspect the folder.' }
    Write-Host 'Completed. Only steamapps, userdata and steam.exe remain.'
}

if (-not $LoadOnly) {
    try { Invoke-SteamCleanup -SteamPath $SteamPath -PreviewOnly:$PreviewOnly }
    catch { Write-Error "Cleanup stopped (earlier deletions may already have completed): $_" }
}
