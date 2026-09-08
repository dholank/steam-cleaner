$ErrorActionPreference='Stop'
. "$PSScriptRoot/../steam-cleaner.ps1" -LoadOnly
$script:passed=0
function Check($Condition,$Message) { if (-not $Condition) { throw "FAILED: $Message" }; $script:passed++; Write-Host "PASS: $Message" }
function Reject([scriptblock]$Action,$Message) { $failed=$false; try { & $Action | Out-Null } catch { $failed=$true; $script:lastError=$_.Exception.Message }; Check $failed $Message }
$fixture=Join-Path $env:TEMP ('steam-download-test-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $fixture
$fixture=(Get-Item -LiteralPath $fixture).FullName
$oldLocalAppData=$env:LOCALAPPDATA
$env:LOCALAPPDATA=Assert-DepotPath (Join-Path $fixture 'local') -Create
$stubText=Get-Content -LiteralPath "$PSScriptRoot/fixtures/appinfo.vdf" -Raw
$stubText=$stubText.Replace('"size" "7"','')
$stubCalls=[Collections.Generic.List[string]]::new()
$stubFail=$true; $stubDrift=$false; $stubInfoCalls=0
$fakeExePath=Join-Path (Assert-DepotPath (Join-Path $fixture 'tools') -Create) 'steamcmd.exe'
function Get-SteamCmdPath { param($Settings,[switch]$ManagedOnly) return $fakeExePath }
function Connect-SteamCmd { param($Exe,$UserName) }
function Test-SteamCmdDownloadDestination { param($Exe,$UserName,$TimeoutSeconds) return $true }
function Get-SteamAccountEntitlements {
    param($Exe,$UserName,$AppId,$TimeoutSeconds)
    $grant=[pscustomobject]@{PackageId='55';AppIds=@('100');DepotIds=@('900','200','300');HasAppGrantList=$true;HasDepotGrantList=$true}
    [pscustomobject]@{AppId='100';PackageIds=@('55');AppIds=@('100');DepotIds=@('900','200','300');Complete=$true;Confidence='HIGH';Reason='fixture';Grants=@($grant)}
}
function Invoke-SteamCmd {
    param($Exe,$UserName,$Operation,$AppId,$DepotId,$ManifestId,$PackageId,$Destination,$WorkingDirectory,$TimeoutSeconds)
    if ($Operation -eq 'AppInfo') {
        $script:stubInfoCalls++
        $reply=$stubText
        if ($stubDrift -and $script:stubInfoCalls -gt 1) { $reply=$reply.Replace('"buildid" "42"','"buildid" "99"') }
        return [pscustomobject]@{Stdout=$reply;Stderr='';ExitCode=0}
    }
    if ($Operation -ne 'Download') { return [pscustomobject]@{Stdout='';Stderr='';ExitCode=0} }
    $stubCalls.Add($DepotId)
    if ($stubFail -and $DepotId -eq '200') { throw 'Simulated network interruption.' }
    $spool=if ($Destination) { Assert-DepotPath $Destination -Create } else { Assert-DepotPath (Join-Path (Split-Path -Parent $Exe) "steamapps/content/app_$AppId/depot_$DepotId") -Create }
    [IO.File]::WriteAllText((Join-Path $spool "game_$DepotId.bin"),"data-$DepotId")
    return [pscustomobject]@{Stdout="Depot download complete : `"$spool`" (1 files, manifest $ManifestId)";Stderr='';ExitCode=0}
}
try {
    $settings=Get-DepotSettings -StoredSettingsPath (Join-Path $fixture 'missing-settings.json')
    $settings.DownloadRoot=Assert-DepotPath (Join-Path $fixture 'root') -Create
    $settings.KeepTemporaryDepots=$true
    Reject { Invoke-SteamDepotDownload '100' $settings 'anonymous' } 'Interrupted second depot stops whole pipeline'
    if (-not (Test-Path -LiteralPath (Join-Path (Get-DepotCacheRoot $settings '100') 'metadata.json'))) { throw "Pipeline failed before metadata: $script:lastError" }
    $cache=Get-DepotCacheRoot $settings '100'
    $failed=Get-Content -LiteralPath (Join-Path $cache 'metadata.json') -Raw | ConvertFrom-Json
    Check ($failed.Status -eq 'Failed') 'Metadata records failure after a partial download'
    Check (-not (Test-Path -LiteralPath (Join-Path $settings.DownloadRoot 'FixtureInstall'))) 'No assembly after partial download'
    Check ((Test-Path -LiteralPath (Join-Path $cache 'receipt_900.json')) -and (Test-Path -LiteralPath (Join-Path $cache 'depot_900'))) 'Completed first depot retained for retry'
    $stubFail=$false; $stubCalls.Clear(); $script:stubInfoCalls=0
    $result=Invoke-SteamDepotDownload '100' $settings 'anonymous'
    Check (($stubCalls -join ',') -eq '200,300') 'Retry verifies matching manifest without downloading it again'
    Check ($result.Verified -and $result.FileCount -eq 3) 'Resolver/download/cache/assembly pipeline completes'
    $metadataFile=Join-Path $cache 'metadata.json'
    $stored=Read-DepotMetadata $metadataFile
    Check ($stored.Receipts.Count -eq 3) 'All receipts recorded in metadata'
    Check (@(Get-ChildItem -LiteralPath $cache -Directory -Filter 'depot_*').Count -eq 3) 'KeepTemporaryDepots preserves raw depots'
    $receipt900=Get-Content -Raw (Join-Path $cache 'receipt_900.json') | ConvertFrom-Json
    $receipt900.ManifestId='999'; Write-DepotJson (Join-Path $cache 'receipt_900.json') $receipt900
    $stubCalls.Clear(); $appFixture=Get-SteamAppInfoFromOutput $stubText '100'
    $grantFixture=Get-SteamAccountEntitlements $fakeExePath 'anonymous' '100' 30
    $retryPlan=Resolve-SteamDepots '100' $appFixture $settings $null $grantFixture
    $null=Invoke-DepotDownloads $retryPlan $settings $fakeExePath 'anonymous' (Join-Path $env:LOCALAPPDATA 'retry.log') $true
    Check (($stubCalls -join ',') -eq '900') 'Mismatched ManifestID is downloaded again while matching depots are reused'
    Check (@(Get-ChildItem -LiteralPath (Join-Path $cache 'stale') -Directory).Count -eq 1) 'Mismatched depot and receipt move to AppID stale storage'

    $hugePlan=[pscustomobject]@{Depots=@([pscustomobject]@{DepotId='1';ExpectedBytes=([decimal][IO.DriveInfo]::new([IO.Path]::GetPathRoot($fixture)).AvailableFreeSpace*2)})}
    Reject { Assert-DepotDiskSpace $hugePlan $fixture } 'Provable disk-space shortage is a hard stop'

    $cleanupSettings=Get-DepotSettings -StoredSettingsPath (Join-Path $fixture 'missing-settings.json')
    $cleanupSettings.DownloadRoot=Assert-DepotPath (Join-Path $fixture 'cleanup-root') -Create
    $cleanupSettings.KeepTemporaryDepots=$false; $stubCalls.Clear(); $script:stubInfoCalls=0
    $cleanupResult=Invoke-SteamDepotDownload '100' $cleanupSettings 'anonymous'
    Check ($cleanupResult.Verified -and -not (Test-Path -LiteralPath (Get-DepotCacheRoot $cleanupSettings '100'))) 'Default cleanup removes exactly the verified AppID cache'
    Check (Test-Path -LiteralPath (Join-Path $cleanupSettings.DownloadRoot 'FixtureInstall')) 'Default cleanup leaves verified final output intact'

    $stubDrift=$true; $script:stubInfoCalls=0
    $driftSettings=Get-DepotSettings -StoredSettingsPath (Join-Path $fixture 'missing-settings.json')
    $driftSettings.DownloadRoot=Assert-DepotPath (Join-Path $fixture 'drift-root') -Create
    $driftSettings.KeepTemporaryDepots=$true
    Reject { Invoke-SteamDepotDownload '100' $driftSettings 'anonymous' } 'Branch change after downloads prevents automatic assembly'
    Check (-not (Test-Path -LiteralPath (Join-Path $driftSettings.DownloadRoot 'FixtureInstall'))) 'Branch drift leaves final output absent'
    Check (Test-Path -LiteralPath (Join-Path (Get-DepotCacheRoot $driftSettings '100') 'metadata.json')) 'Branch drift retains the pinned cache'

    function Copy-DepotContents { param($Source,$Destination) throw 'Simulated disk full.' }
    Reject { Invoke-DepotAssembly $metadataFile (Join-Path $fixture 'io-output') } 'Disk write failure aborts assembly'
    Check (-not (Test-Path -LiteralPath (Join-Path $fixture 'io-output/FixtureInstall'))) 'Failed staging is not published'
    Check (Test-Path -LiteralPath (Join-Path $cache 'depot_900')) 'Assembly error retains raw cache'
    Write-Host "All $script:passed download checks passed."
} finally {
    $env:LOCALAPPDATA=$oldLocalAppData
    if (-not $fixture.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $fixture -Leaf) -notlike 'steam-download-test-*') { throw 'Unsafe fixture cleanup.' }
    foreach ($node in @(Get-CleanupNode $fixture ([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')))) {
        if ($node.Directory) { [IO.Directory]::Delete($node.Path,$false) } else { Remove-Item -LiteralPath $node.Path -Force }
    }
}
