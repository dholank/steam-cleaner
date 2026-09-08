#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Menu','Clean','Download','Reassemble')][string]$Action='Menu',
    [string]$AppId, [string]$UserName, [string]$ConfigPath, [string]$MetadataPath,
    [string]$SteamPath, [switch]$PreviewOnly, [switch]$LoadOnly
)

# Keep the original single-file cleaner usable at its existing raw URL.
# Remote invocation loads all modules from one immutable repository revision.
if (-not $PSScriptRoot -or -not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'modules/DepotSupport.ps1'))) {
    if ($LoadOnly) { throw 'LoadOnly requires the complete local repository.' }
    if ($PSBoundParameters.Count) { throw 'Use the full local repository for parameterized commands. The remote launcher opens the interactive menu.' }
    $ErrorActionPreference='Stop'
    $tempParent=Get-Item -LiteralPath $env:TEMP -Force -ErrorAction Stop
    while ($null -ne $tempParent) {
        if ($tempParent.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Remote launcher requires a TEMP directory without linked ancestors.' }
        $tempParent=$tempParent.Parent
    }
    $releaseRoot=Join-Path $env:TEMP ('steam-cleaner-package-' + [guid]::NewGuid().ToString('N'))
    $null=New-Item -ItemType Directory -Path $releaseRoot
    try {
        $revision=(Invoke-RestMethod 'https://api.github.com/repos/dholank/steam-cleaner/commits/main').sha
        if ($revision -notmatch '^[a-f0-9]{40}$') { throw 'Could not pin the repository revision.' }
        $files=@('steam-cleaner.ps1','clean-steam.ps1','modules/DepotSupport.ps1','modules/SteamCmdClient.ps1','modules/AppInfoParser.ps1','modules/DepotResolver.ps1','modules/DepotMetadata.ps1','modules/DepotAssembler.ps1','modules/DepotDownloader.ps1')
        foreach ($file in $files) {
            $target=Join-Path $releaseRoot $file
            $null=New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force
            Invoke-WebRequest -Uri "https://raw.githubusercontent.com/dholank/steam-cleaner/$revision/$file" -OutFile $target -UseBasicParsing
        }
        Write-Host "Steam Cleaner revision: $revision"
        # Policy bypass applies only to this explicit remote-execution child process.
        # No password or Guard code is accepted as an argument.
        $modern=Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $engine=if ($modern) { $modern.Source } else { Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe' }
        & $engine -NoProfile -ExecutionPolicy Bypass -File (Join-Path $releaseRoot 'steam-cleaner.ps1')
    } catch { Write-Error "Steam Cleaner package download/start failed: $_" }
    return
}

$entryLoadOnly=$LoadOnly; $entrySteamPath=$SteamPath; $entryPreviewOnly=$PreviewOnly
. "$PSScriptRoot/clean-steam.ps1" -LoadOnly
$LoadOnly=$entryLoadOnly; $SteamPath=$entrySteamPath; $PreviewOnly=$entryPreviewOnly
foreach ($module in @('DepotSupport','AppInfoParser','DepotResolver','SteamCmdClient','DepotMetadata','DepotAssembler','DepotDownloader')) {
    . "$PSScriptRoot/modules/$module.ps1"
}

if (-not $LoadOnly) {
    $ErrorActionPreference='Stop'
    try {
        if ($env:OS -ne 'Windows_NT') { throw 'Steam Cleaner requires Windows.' }
        if ($Action -eq 'Menu') {
            Write-Host "Steam Cleaner`n-------------`n[1] Clean Steam`n[2] Depot Downloader`n[3] Reassemble downloaded depots`n[Enter] Cancel"
            switch (Read-Host 'Choose an option') {
                '1' { $Action='Clean' }
                '2' { $Action='Download' }
                '3' { $Action='Reassemble' }
                default { return }
            }
            if ($Action -ne 'Clean') { $ConfigPath=Read-Host 'Settings JSON path (Enter = defaults)' }
        }
        if ($Action -eq 'Clean') { Invoke-SteamCleanup -SteamPath $SteamPath -PreviewOnly:$PreviewOnly; return }
        $settings=Get-DepotSettings $ConfigPath
        if ($Action -eq 'Download') {
            if (-not $AppId) { $AppId=Read-Host 'Enter AppID' }
            if (-not $UserName) { $UserName=Read-Host 'Steam login name (or anonymous for supported free content)' }
            Invoke-SteamDepotDownload $AppId $settings $UserName | Out-Null
        } else {
            if (-not $MetadataPath) { $MetadataPath=Read-Host 'Path to metadata.json' }
            $assemblyLog=Join-Path (Split-Path -Parent $MetadataPath) ('assembly-'+[guid]::NewGuid().ToString('N')+'.log')
            $result=Invoke-DepotAssembly -MetadataPath $MetadataPath -OutputRoot $settings.OutputRoot -CollisionPolicy $settings.CollisionPolicy -LogPath $assemblyLog
            Write-Host "Output: $($result.OutputPath)"
        }
    } catch { Write-Error "Steam Cleaner stopped: $_" }
}
