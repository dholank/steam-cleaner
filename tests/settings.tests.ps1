$ErrorActionPreference='Stop'
. "$PSScriptRoot/../steam-cleaner.ps1" -LoadOnly
$script:passed=0
function Check($Condition,$Message) { if (-not $Condition) { throw "FAILED: $Message" }; $script:passed++; Write-Host "PASS: $Message" }
function Reject([scriptblock]$Action,$Message) { $failed=$false; try { & $Action | Out-Null } catch { $failed=$true }; Check $failed $Message }
$fixture=Join-Path $env:TEMP ('steam-settings-test-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $fixture; $fixture=(Get-Item -LiteralPath $fixture).FullName
try {
    $storedPath=Join-Path $fixture 'local/settings.json'
    $storedRoot=Assert-DepotPath (Join-Path $fixture 'stored') -Create
    Write-SteamCleanerSettings $storedRoot $true $storedPath
    $stored=Get-DepotSettings -StoredSettingsPath $storedPath
    Check ($stored.DownloadRoot -eq $storedRoot -and $stored.KeepTemporaryDepots) 'Stored download settings load'
    Write-SteamCleanerSettings $storedRoot $false $storedPath
    $overwritten=Get-DepotSettings -StoredSettingsPath $storedPath
    Check (-not $overwritten.KeepTemporaryDepots) 'Existing settings file is replaced atomically'
    Write-SteamCleanerSettings $storedRoot $true $storedPath

    $configRoot=Assert-DepotPath (Join-Path $fixture 'config-root') -Create
    $configPath=Join-Path $fixture 'config.json'
    [IO.File]::WriteAllText($configPath,(@{DownloadRoot=$configRoot;KeepTemporaryDepots=$false}|ConvertTo-Json))
    $configured=Get-DepotSettings -ConfigPath $configPath -StoredSettingsPath $storedPath
    Check ($configured.DownloadRoot -eq $configRoot -and -not $configured.KeepTemporaryDepots) 'Explicit config overrides stored settings'
    $cliRoot=Assert-DepotPath (Join-Path $fixture 'cli-root') -Create
    $cli=Get-DepotSettings -ConfigPath $configPath -DownloadRoot $cliRoot -KeepTemporaryDepots $true -StoredSettingsPath $storedPath
    Check ($cli.DownloadRoot -eq $cliRoot -and $cli.KeepTemporaryDepots) 'CLI values have highest precedence'
    Check ((Get-DepotCacheRoot $cli '42') -eq (Join-Path $cliRoot '.depot-cache\42')) 'Cache is derived from one DownloadRoot'
    Check ((Get-DepotOutputPath $cli 'Game') -eq (Join-Path $cliRoot 'Game')) 'Final output is derived from one DownloadRoot'

    $legacyRoot=Assert-DepotPath (Join-Path $fixture 'legacy') -Create
    $legacyPath=Join-Path $fixture 'legacy.json'
    [IO.File]::WriteAllText($legacyPath,(@{OutputRoot=$legacyRoot;CacheRoot=(Join-Path $legacyRoot '.depot-cache')}|ConvertTo-Json))
    Check ((Get-DepotSettings -ConfigPath $legacyPath -StoredSettingsPath (Join-Path $fixture 'none.json')).DownloadRoot -eq $legacyRoot) 'Compatible legacy paths migrate to DownloadRoot'
    $badLegacyPath=Join-Path $fixture 'bad-legacy.json'
    $oldCache=Assert-DepotPath (Join-Path $fixture 'old-cache') -Create
    [IO.File]::WriteAllText($badLegacyPath,(@{OutputRoot=$legacyRoot;CacheRoot=$oldCache}|ConvertTo-Json))
    Reject { Get-DepotSettings -ConfigPath $badLegacyPath -StoredSettingsPath (Join-Path $fixture 'none.json') } 'Incompatible legacy paths stop with migration guidance'
    Check (Test-Path -LiteralPath $oldCache) 'Legacy migration never moves old data'

    $seenInitial=$null
    $cancelled=Show-DepotLocationDialog $storedRoot $true {param($path,$keep) $script:seenInitial=$path; [pscustomobject]@{Accepted=$false;DownloadRoot=$path;KeepTemporaryDepots=$keep}}
    Check (-not $cancelled.Accepted -and $seenInitial -eq $storedRoot) 'Dialog adapter receives initial path and cancel preserves it'
    Check ((Set-DepotPathFromBrowse $storedRoot '') -eq $storedRoot) 'Browse cancel leaves manual path unchanged'
    Check ((Get-DepotBrowseInitialPath $storedRoot) -eq $storedRoot) 'Folder picker starts at the current valid path'
    Check (Test-DepotFolderCanOpen $storedRoot) 'Open Folder is enabled only for a valid folder'
    $opened=$null; Open-DepotFolder $storedRoot {param($path) $script:opened=$path}
    Check ($opened -eq $storedRoot) 'Open Folder uses the validated current path'
    $filePath=Join-Path $fixture 'not-a-folder'; [IO.File]::WriteAllText($filePath,'x')
    Check (-not (Test-DepotRootWritable $filePath)) 'Non-directory download location is rejected as not writable'

    $manualRoot=Assert-DepotPath (Join-Path $fixture 'manual') -Create
    $selected=Select-DepotLocation $stored {param($path,$keep) [pscustomobject]@{Accepted=$true;DownloadRoot=$manualRoot;KeepTemporaryDepots=$false}} (Join-Path $fixture 'selected/settings.json')
    Check ($selected.DownloadRoot -eq $manualRoot -and -not $selected.KeepTemporaryDepots) 'Manual entry and checkbox selection persist on Continue'
    $cancelSettingsPath=Join-Path $fixture 'cancel/settings.json'
    $none=Select-DepotLocation $stored {param($path,$keep) [pscustomobject]@{Accepted=$false;DownloadRoot=$path;KeepTemporaryDepots=$keep}} $cancelSettingsPath
    Check ($null -eq $none -and -not (Test-Path -LiteralPath $cancelSettingsPath)) 'Cancel does not modify persisted settings'
    Write-Host "All $script:passed settings/UI checks passed."
} finally {
    foreach ($node in @(Get-CleanupNode $fixture ([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')))) { if ($node.Directory) {[IO.Directory]::Delete($node.Path,$false)} else {Remove-Item -LiteralPath $node.Path -Force} }
}
