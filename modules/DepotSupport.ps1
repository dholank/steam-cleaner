function Assert-SteamId {
    param([string]$Value, [switch]$Manifest)
    if ($Value -notmatch '^[1-9][0-9]{0,19}$') { throw 'Invalid Steam ID. Enter positive decimal digits only.' }
    $number = [uint64]0
    if (-not [uint64]::TryParse($Value, [ref]$number) -or (-not $Manifest -and $number -gt [uint32]::MaxValue)) { throw 'Steam ID is out of range.' }
    return $Value
}

function ConvertTo-InstallDirectoryName {
    param([string]$Name, [switch]$Fallback)
    if ([string]::IsNullOrWhiteSpace($Name)) { throw 'AppInfo has no usable install directory or game name.' }
    if ($Fallback) { $Name = $Name -replace '[<>:"/\\|?*\x00-\x1f]', '_'; $Name = $Name.Trim().TrimEnd('.') }
    if ($Name.Length -gt 255 -or $Name -match '[<>:"/\\|?*\x00-\x1f]' -or $Name -match '[ .]$' -or $Name -in @('.', '..') -or $Name -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
        throw 'Unsafe InstallDir in AppInfo. Refusing to reinterpret a publisher-supplied path.'
    }
    return $Name
}

function Assert-DepotPath {
    param([string]$Path, [switch]$Create)
    if ($Path -notmatch '^[A-Za-z]:[\\/]' -or $Path -match '(?:^|[\\/])\.\.(?:[\\/]|$)' -or $Path.Substring(2).Contains(':')) { throw 'Use a local absolute path without traversal or alternate data streams.' }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $probe = $full
    while (-not (Test-Path -LiteralPath $probe)) {
        $next = Split-Path -Parent $probe
        if (-not $next -or $next -eq $probe) { throw 'No accessible parent directory.' }
        $probe = $next
    }
    # Reuse the cleaner guard for existing folders and all their ancestors.
    $null = Assert-LocalDirectory $probe -AllowProtectedAncestor
    if ($probe.TrimEnd('\') -eq $full) { return Assert-LocalDirectory $full }
    if ($Create) { $null = New-Item -ItemType Directory -Path $full -Force -ErrorAction Stop }
    if (Test-Path -LiteralPath $full) { return Assert-LocalDirectory $full }
    return $full
}

function Assert-SeparateDepotPaths {
    param([string]$First, [string]$Second)
    $a = [IO.Path]::GetFullPath($First).TrimEnd('\')
    $b = [IO.Path]::GetFullPath($Second).TrimEnd('\')
    if ($a -eq $b -or $a.StartsWith($b + '\', [StringComparison]::OrdinalIgnoreCase) -or $b.StartsWith($a + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Cache, SteamCMD and output directories must not overlap.' }
}

function Get-SteamCleanerDataRoot {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA is unavailable.' }
    return (Join-Path $env:LOCALAPPDATA 'SteamCleaner')
}

function Get-SteamCleanerSettingsPath { return (Join-Path (Get-SteamCleanerDataRoot) 'settings.json') }

function Get-SteamCleanerDownloadsFolder {
    $downloads=$null
    try {
        $shellFolders=Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction Stop
        $downloads=[string]$shellFolders.'{374DE290-123F-4565-9164-39C4925E467B}'
        if ($downloads) { $downloads=[Environment]::ExpandEnvironmentVariables($downloads) }
    } catch {}
    if ([string]::IsNullOrWhiteSpace($downloads)) { $downloads=Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads' }
    return [IO.Path]::GetFullPath($downloads)
}

function Get-SteamCleanerDefaultDownloadRoot {
    return (Join-Path (Get-SteamCleanerDownloadsFolder) 'Steam Cleaner Downloads')
}

function Get-DepotCacheRoot {
    param([Parameter(Mandatory=$true)]$Settings, [Parameter(Mandatory=$true)][string]$AppId)
    $null = Assert-SteamId $AppId
    return (Join-Path (Join-Path $Settings.DownloadRoot '.depot-cache') $AppId)
}

function Get-DepotOutputPath {
    param([Parameter(Mandatory=$true)]$Settings, [Parameter(Mandatory=$true)][string]$InstallDir)
    $safeName = ConvertTo-InstallDirectoryName $InstallDir
    return (Join-Path $Settings.DownloadRoot $safeName)
}

function Test-DepotRootWritable {
    param([Parameter(Mandatory=$true)][string]$Path, [switch]$Create)
    try { $full = Assert-DepotPath $Path -Create:$Create } catch { return $false }
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { return $false }
    $probe = Join-Path $full ('.steam-cleaner-write-probe-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($probe, 'probe', [Text.UTF8Encoding]::new($false))
        return $true
    } catch {
        return $false
    } finally {
        if (Test-Path -LiteralPath $probe -PathType Leaf) { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue }
    }
}

function Write-SteamCleanerSettings {
    param([Parameter(Mandatory=$true)][string]$DownloadRoot, [Parameter(Mandatory=$true)][bool]$KeepTemporaryDepots, [string]$Path=(Get-SteamCleanerSettingsPath))
    $validated = Assert-DepotPath $DownloadRoot -Create
    if (-not (Test-DepotRootWritable $validated)) { throw 'Download Location is not writable.' }
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop }
    $payload = [ordered]@{ SchemaVersion=1; DownloadRoot=$validated; KeepTemporaryDepots=$KeepTemporaryDepots; UpdatedUtc=[DateTime]::UtcNow.ToString('o') }
    $temporary = Join-Path $parent ('.settings-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $backup = Join-Path $parent ('.settings-backup-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, ($payload | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, $backup); Remove-Item -LiteralPath $backup -Force -ErrorAction Stop }
        else { [IO.File]::Move($temporary, $Path) }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue }
    }
}

function Write-DepotLog {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO', [string]$LogPath)
    # Callers pass structured events, NEVER raw SteamCMD transcripts or credentials.
    $safe = $Message -replace '[\x00-\x1f\x7f]', ' '
    Write-Host "[$Level] $safe"
    if ($LogPath) {
        $null = Assert-LocalDirectory (Split-Path -Parent $LogPath)
        if (Test-Path -LiteralPath $LogPath) {
            $logItem = Get-Item -LiteralPath $LogPath -Force
            if ($logItem.PSIsContainer -or ($logItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe log file.' }
        }
        Add-Content -LiteralPath $LogPath -Value "[$([DateTime]::UtcNow.ToString('o'))][$Level] $safe" -Encoding UTF8 -ErrorAction Stop
    }
}

function Get-DepotSettings {
    param([string]$ConfigPath, [string]$DownloadRoot, [Nullable[bool]]$KeepTemporaryDepots, [string]$StoredSettingsPath=(Get-SteamCleanerSettingsPath))
    $base = Get-SteamCleanerDataRoot
    $oldDefault = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Steam Cleaner Downloads'
    $newDefault = Get-SteamCleanerDefaultDownloadRoot
    $settings = [ordered]@{ Platform='windows'; Architecture='x64'; Language='english'; Branch='public'; DLC='None'; DownloadRoot=$newDefault; KeepTemporaryDepots=$false; SteamCmdPath=''; ToolsRoot=(Join-Path $base 'SteamCMD'); TimeoutSeconds=21600; CollisionPolicy='ResolvedOrder' }

    if (Test-Path -LiteralPath $StoredSettingsPath -PathType Leaf) {
        $stored = Get-Content -LiteralPath $StoredSettingsPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        foreach ($key in @('DownloadRoot','KeepTemporaryDepots')) {
            if ($stored.PSObject.Properties[$key]) { $settings[$key] = $stored.$key }
        }
        if ([string]$settings.DownloadRoot -and [IO.Path]::GetFullPath([string]$settings.DownloadRoot).TrimEnd('\').Equals([IO.Path]::GetFullPath($oldDefault).TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)) {
            $settings.DownloadRoot=$newDefault
        }
    }

    if ($ConfigPath) {
        $custom = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $legacyCache = $custom.PSObject.Properties['CacheRoot']
        $legacyOutput = $custom.PSObject.Properties['OutputRoot']
        if ($legacyCache -or $legacyOutput) {
            if (-not ($legacyCache -and $legacyOutput)) { throw 'Legacy migration requires both CacheRoot and OutputRoot. Set DownloadRoot instead; old data is not moved automatically.' }
            $expected = [IO.Path]::GetFullPath((Join-Path ([string]$custom.OutputRoot) '.depot-cache')).TrimEnd('\')
            $actual = [IO.Path]::GetFullPath([string]$custom.CacheRoot).TrimEnd('\')
            if (-not $actual.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) { throw 'Legacy CacheRoot must equal <OutputRoot>\.depot-cache before automatic migration. Set DownloadRoot manually; old data was not moved.' }
            $settings.DownloadRoot = [string]$custom.OutputRoot
        }
        foreach ($property in $custom.PSObject.Properties) {
            if ($property.Name -in @('CacheRoot','OutputRoot')) { continue }
            if (-not $settings.Contains($property.Name)) { throw "Unknown setting: $($property.Name). Credentials do not belong in settings." }
            $settings[$property.Name] = $property.Value
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($DownloadRoot)) { $settings.DownloadRoot = $DownloadRoot }
    if ($null -ne $KeepTemporaryDepots) { $settings.KeepTemporaryDepots = [bool]$KeepTemporaryDepots }
    if ($settings.Platform -notin @('windows') -or $settings.Architecture -notin @('x64','x86') -or $settings.DLC -ne 'None') { throw 'Automatic mode supports Windows, x64/x86 and DLC=None.' }
    foreach ($key in @('Language','Branch')) { if ($settings[$key] -notmatch '^[a-zA-Z0-9_-]{1,64}$') { throw "Invalid $key setting." } }
    if ($settings.CollisionPolicy -notin @('Stop','AppInfoOrder','ResolvedOrder')) { throw 'CollisionPolicy must be Stop, AppInfoOrder or ResolvedOrder.' }
    if ([int]$settings.TimeoutSeconds -lt 30 -or [int]$settings.TimeoutSeconds -gt 86400) { throw 'TimeoutSeconds must be 30..86400.' }
    if ($settings.KeepTemporaryDepots -isnot [bool]) { throw 'KeepTemporaryDepots must be true or false.' }
    $settings.DownloadRoot = Assert-DepotPath ([string]$settings.DownloadRoot)
    return [pscustomobject]$settings
}

function Get-DepotFiles {
    param([string]$Root)
    $rootPath = Assert-LocalDirectory $Root
    foreach ($child in (Get-ChildItem -LiteralPath $rootPath -Force -ErrorAction Stop)) {
        # Existing cleaner walker rejects links and verifies containment; no duplicate traversal.
        foreach ($node in @(Get-CleanupNode $child.FullName $rootPath)) {
            $relative = $node.Path.Substring($rootPath.Length + 1)
            foreach ($part in ($relative -split '\\')) { $null = ConvertTo-InstallDirectoryName $part }
            [pscustomobject]@{ Path=$node.Path; RelativePath=$relative; Directory=$node.Directory; Length=$node.Length }
        }
    }
}

function Remove-DepotTree {
    param([string]$Path, [string]$AllowedRoot)
    $rootPath = Assert-LocalDirectory $AllowedRoot
    $targetPath = Assert-LocalDirectory $Path
    if (-not $targetPath.StartsWith($rootPath + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Deletion target is outside the designated cache.' }
    foreach ($node in @(Get-CleanupNode $targetPath $rootPath)) {
        $null = Assert-LocalDirectory (Split-Path -Parent $node.Path)
        $item = Get-Item -LiteralPath $node.Path -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Deletion target changed to a link.' }
        if ($node.Directory) { [IO.Directory]::Delete($node.Path, $false) }
        else { Remove-Item -LiteralPath $node.Path -Force -ErrorAction Stop }
    }
}
