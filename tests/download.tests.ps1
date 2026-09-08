$ErrorActionPreference='Stop'
. "$PSScriptRoot/../steam-cleaner.ps1" -LoadOnly
$script:passed=0
function Check($Condition,$Message) { if (-not $Condition) { throw "FAILED: $Message" }; $script:passed++; Write-Host "PASS: $Message" }
function Reject([scriptblock]$Action,$Message) { $failed=$false; try { & $Action | Out-Null } catch { $failed=$true }; Check $failed $Message }
$fixture=Join-Path $env:TEMP ('steam-download-test-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $fixture
$fixture=(Get-Item -LiteralPath $fixture).FullName
$stubText=Get-Content -LiteralPath "$PSScriptRoot/fixtures/appinfo.vdf" -Raw
# Size is omitted in this generated-content test; size validation has a separate assertion.
$stubText=$stubText.Replace('"size" "7"','')
$stubCalls=[Collections.Generic.List[string]]::new()
$stubFail=$true
$stubDrift=$false
$stubInfoCalls=0
$fakeExePath=Join-Path (Assert-DepotPath (Join-Path $fixture 'tools') -Create) 'steamcmd.exe'
function Get-SteamCmdPath { param($Settings) return $fakeExePath }
function Connect-SteamCmd { param($Exe,$UserName) }
function Read-Host { param($Prompt) return '' }
function Invoke-SteamCmd {
    param($Exe,$UserName,$Operation,$AppId,$DepotId,$ManifestId,$TimeoutSeconds)
    if ($Operation -eq 'AppInfo') {
        $script:stubInfoCalls++
        $reply=$stubText
        if ($stubDrift -and $script:stubInfoCalls -gt 1) { $reply=$reply.Replace('"buildid" "42"','"buildid" "99"') }
        return [pscustomobject]@{Stdout=$reply;Stderr='';ExitCode=0}
    }
    $stubCalls.Add($DepotId)
    if ($stubFail -and $DepotId -eq '200') { throw 'Simulated network interruption.' }
    $spool=Assert-DepotPath (Join-Path (Split-Path -Parent $Exe) "steamapps/content/app_$AppId/depot_$DepotId") -Create
    [IO.File]::WriteAllText((Join-Path $spool "game_$DepotId.bin"),"data-$DepotId")
    return [pscustomobject]@{Stdout="Depot download complete : `"$spool`" (1 files, manifest $ManifestId)";Stderr='';ExitCode=0}
}
try {
    $settings=Get-DepotSettings
    $settings.CacheRoot=Join-Path $fixture 'cache'; $settings.OutputRoot=Join-Path $fixture 'output'
    Reject { Invoke-SteamDepotDownload '100' $settings 'anonymous' } 'Interrupted second depot stops whole pipeline'
    Check (-not @(Get-ChildItem -LiteralPath $settings.CacheRoot -Filter metadata.json -Recurse).Count) 'No successful metadata before all downloads complete'
    Check (-not (Test-Path -LiteralPath (Join-Path $settings.OutputRoot 'FixtureInstall'))) 'No assembly after partial download'
    Check (@(Get-ChildItem -LiteralPath $settings.CacheRoot -Filter '*.receipt.json' -Recurse).Count -eq 1) 'Completed first depot retained for retry'
    $stubFail=$false; $stubCalls.Clear()
    $result=Invoke-SteamDepotDownload '100' $settings 'anonymous'
    Check (($stubCalls -join ',') -eq '200,300') 'Retry verifies completed depot without downloading it again'
    Check ($result.Verified -and $result.FileCount -eq 3) 'AppID-only resolver/download/cache/assemble pipeline completes'
    $metadataFile=Get-ChildItem -LiteralPath $settings.CacheRoot -Filter metadata.json -Recurse | Select-Object -First 1
    $stored=Read-DepotMetadata $metadataFile.FullName
    Check ($stored.Receipts.Count -eq 3) 'All receipts recorded in metadata'
    Check (@(Get-ChildItem -LiteralPath $metadataFile.DirectoryName -Directory -Filter 'depot_*').Count -eq 3) 'Default answer keeps raw depots'
    $stubDrift=$true; $script:stubInfoCalls=0
    $settings.CacheRoot=Join-Path $fixture 'drift-cache'; $settings.OutputRoot=Join-Path $fixture 'drift-output'
    Reject { Invoke-SteamDepotDownload '100' $settings 'anonymous' } 'Branch change after downloads prevents automatic assembly'
    Check (-not (Test-Path -LiteralPath (Join-Path $settings.OutputRoot 'FixtureInstall'))) 'Branch drift leaves final output absent'
    Check (@(Get-ChildItem -LiteralPath $settings.CacheRoot -Filter metadata.json -Recurse).Count -eq 1) 'Pinned version metadata retained for explicit reassembly'
    # Simulated I/O failure must not turn a staging folder into the final output.
    function Copy-DepotContents { param($Source,$Destination) throw 'Simulated disk full.' }
    Reject { Invoke-DepotAssembly $metadataFile.FullName (Join-Path $fixture 'io-output') } 'Disk write failure aborts assembly'
    Check (-not (Test-Path -LiteralPath (Join-Path $fixture 'io-output/FixtureInstall'))) 'Failed staging is not published'
    Check (Test-Path -LiteralPath (Join-Path $metadataFile.DirectoryName 'depot_900')) 'Assembly error retains raw cache'
    Write-Host "All $script:passed download checks passed."
} finally {
    if (-not $fixture.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $fixture -Leaf) -notlike 'steam-download-test-*') { throw 'Unsafe fixture cleanup.' }
    foreach ($node in @(Get-CleanupNode $fixture ([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')))) {
        if ($node.Directory) { [IO.Directory]::Delete($node.Path,$false) } else { Remove-Item -LiteralPath $node.Path -Force }
    }
}
