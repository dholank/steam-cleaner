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
    param([string]$ConfigPath)
    $base = Join-Path $env:LOCALAPPDATA 'SteamCleaner'
    $settings = [ordered]@{ Platform='windows'; Architecture='x64'; Language='english'; Branch='public'; DLC='None'; CacheRoot=(Join-Path $base 'DepotCache'); OutputRoot=(Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'SteamGames'); SteamCmdPath=''; ToolsRoot=(Join-Path $base 'SteamCMD'); TimeoutSeconds=21600; CollisionPolicy='Stop' }
    if ($ConfigPath) {
        $custom = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        foreach ($property in $custom.PSObject.Properties) {
            if (-not $settings.Contains($property.Name)) { throw "Unknown setting: $($property.Name). Credentials do not belong in settings." }
            $settings[$property.Name] = $property.Value
        }
    }
    if ($settings.Platform -notin @('windows') -or $settings.Architecture -notin @('x64','x86') -or $settings.DLC -ne 'None') { throw 'Version 1 supports Windows, x64/x86 and DLC=None.' }
    foreach ($key in @('Language','Branch')) { if ($settings[$key] -notmatch '^[a-zA-Z0-9_-]{1,64}$') { throw "Invalid $key setting." } }
    if ($settings.CollisionPolicy -notin @('Stop','AppInfoOrder')) { throw 'CollisionPolicy must be Stop or AppInfoOrder.' }
    if ([int]$settings.TimeoutSeconds -lt 30 -or [int]$settings.TimeoutSeconds -gt 86400) { throw 'TimeoutSeconds must be 30..86400.' }
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
