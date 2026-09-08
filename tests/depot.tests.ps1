$ErrorActionPreference='Stop'
. "$PSScriptRoot/../steam-cleaner.ps1" -LoadOnly
$script:passed=0
function Check($Condition,$Message) { if (-not $Condition) { throw "FAILED: $Message" }; $script:passed++; Write-Host "PASS: $Message" }
function Reject([scriptblock]$Action,$Message) { $failed=$false; try { & $Action | Out-Null } catch { $failed=$true }; Check $failed $Message }
$settings=Get-DepotSettings
$text=Get-Content -LiteralPath "$PSScriptRoot/fixtures/appinfo.vdf" -Raw
$info=Get-SteamAppInfoFromOutput $text '100'
$plan=Resolve-SteamDepots '100' $info $settings
Check ($info['common']['name'] -eq 'Fixture Store Name') 'AppInfo console noise parsed'
Check ($plan.InstallDir -eq 'FixtureInstall') 'Publisher InstallDir preferred over Store name'
Check (($plan.Depots.DepotId -join ',') -eq '900,200,300') 'Common, Windows x64 and English selected in publisher order'
Check ($plan.Depots[0].ManifestId -ceq '18446744073709551614') '64-bit manifest remains an exact string'
Check (($plan.Decisions | Where-Object DepotId -eq '400').Action -eq 'SKIP') 'OS filtering'
Check (($plan.Decisions | Where-Object DepotId -eq '500').Action -eq 'SKIP') 'Language filtering'
Check (($plan.Decisions | Where-Object DepotId -eq '600').Action -eq 'SKIP') 'DLC filtering'
Check (($plan.Decisions | Where-Object DepotId -eq '700').Action -eq 'SKIP') 'Architecture filtering'
Check ($plan.CanDownload -and $plan.Confidence -eq 'MEDIUM') 'Order uncertainty disclosed'
Reject { ConvertFrom-SteamVdf '"a" { "b" "c"' } 'Truncated VDF rejected'
Reject { ConvertFrom-SteamVdf '"a" "b" "a" "c"' } 'Duplicate VDF rejected'
Reject { Get-SteamAppInfoFromOutput 'no such app' '100' } 'Missing AppInfo rejected'
Reject { Assert-SteamId '100 +quit' } 'Command injection rejected'
Reject { Assert-SteamId '18446744073709551616' -Manifest } 'Manifest overflow rejected'
Reject { ConvertTo-InstallDirectoryName '..\..\escape' } 'InstallDir traversal rejected'
Reject { ConvertTo-InstallDirectoryName 'CON' } 'Windows reserved name rejected'
Reject { ConvertTo-InstallDirectoryName 'Game:stream' } 'Alternate data stream rejected'
Check ((ConvertTo-InstallDirectoryName 'Name: subtitle' -Fallback) -eq 'Name_ subtitle') 'Store-name fallback sanitized'
$originalManifest=$info['depots']['200']['manifests']
$info['depots']['200']['manifests']=[ordered]@{}
Check (-not (Resolve-SteamDepots '100' $info $settings).CanDownload) 'Missing required manifest blocks automatic download'
$info['depots']['200']['manifests']=$originalManifest
$settings.Branch='beta'
$beta=Resolve-SteamDepots '100' $info $settings
Check ($beta.Depots[0].ManifestId -eq '7001' -and -not $beta.CanDownload) 'Selected branch used without silent public fallback'
$settings.Branch='missing'
Reject { Resolve-SteamDepots '100' $info $settings } 'Missing branch rejected'
$settings.Branch='public'
$info['depots']['200']['config']['lowviolence']='1'
Check (-not (Resolve-SteamDepots '100' $info $settings).CanDownload) 'Unknown restriction requires review'
$info['depots']['200']['config'].Remove('lowviolence')
$sharedFixture=ConvertFrom-SteamVdf '"depots" { "850" { "config" { "language" "english" } "manifests" { "public" { "gid" "9999" } } } "branches" { "public" { "buildid" "7" } } }'
$info['depots']['850']=[ordered]@{depotfromapp='150'}
$shared=Resolve-SteamDepots '100' $info $settings { param($id) if ($id -ne '150') {throw 'bad source'}; return ,$sharedFixture }
Check (($shared.Depots | Where-Object DepotId -eq '850').ManifestId -eq '9999') 'Shared manifest resolved through source AppInfo'
Check (($shared.Depots | Where-Object DepotId -eq '850').SourceAppId -eq '150') 'Shared source tracked'
$sharedFixture['depots']['850']['depotfromapp']='150'
Check (-not (Resolve-SteamDepots '100' $info $settings {param($id) return ,$sharedFixture}).CanDownload) 'Shared reference cycles require review'
$info['depots'].Remove('850')
Check ((Get-SteamCmdFailure 'ERROR! no subscription' 0) -like '*ownership*') 'License error actionable even on exit zero'
Check ((Get-SteamCmdFailure 'Steam Guard required' 0) -like '*authentication*') 'Guard requirement detected'
Reject { Get-DownloadCompletion 'Depot download complete : "C:\cache\depot_900" (manifest 1)' '900' '2' 'C:\cache\depot_900' } 'Wrong completed manifest rejected'

$fixture=Join-Path $env:TEMP ('steam-depot-test-' + [guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $fixture
$fixture=(Get-Item -LiteralPath $fixture).FullName
try {
    $cache=Assert-DepotPath (Join-Path $fixture 'cache') -Create
    $output=Assert-DepotPath (Join-Path $fixture 'output') -Create
    $receipts=@(foreach ($depot in $plan.Depots) {
        $root=Assert-DepotPath (Join-Path $cache "depot_$($depot.DepotId)") -Create
        Set-Content -LiteralPath (Join-Path $root "file_$($depot.DepotId).txt") -Value $depot.DepotId
        [pscustomobject]@{ DepotId=$depot.DepotId; ManifestId=$depot.ManifestId; Status='Complete'; Inventory=@(Get-DepotInventory $root) }
    })
    $metadata=[pscustomobject]@{ SchemaVersion=1; Status='Downloaded'; Plan=$plan; PlanKey=(Get-DepotPlanKey $plan); Receipts=$receipts }
    $metadataPath=Join-Path $cache 'metadata.json'
    Write-DepotJson $metadataPath $metadata
    $loaded=Read-DepotMetadata $metadataPath
    Check ($loaded.Plan.Depots[0].ManifestId -ceq $plan.Depots[0].ManifestId) 'Metadata JSON roundtrip preserves IDs/order'
    $unicodeName='Game-' + [char]0x65e5 + [char]0x672c
    $metadata.Plan.InstallDir=$unicodeName
    $metadata.PlanKey=Get-DepotPlanKey $metadata.Plan
    Write-DepotJson $metadataPath $metadata
    Check ((Read-DepotMetadata $metadataPath).Plan.InstallDir -ceq $unicodeName) 'Unicode metadata survives UTF8 roundtrip in both shells'
    $metadata.Plan.InstallDir='FixtureInstall'; $metadata.PlanKey=Get-DepotPlanKey $metadata.Plan
    Write-DepotJson $metadataPath $metadata
    $plan.Depots[0].OrderConfidence='LOW'; Write-DepotJson $metadataPath $metadata
    Reject { Get-DepotAssemblyPlan $metadata $cache 'ResolvedOrder' } 'LOW-confidence mount order blocks automatic assembly'
    $plan.Depots[0].OrderConfidence='MEDIUM'; Write-DepotJson $metadataPath $metadata
    $result=Invoke-DepotAssembly $metadataPath $output
    Check ($result.Verified -and $result.FileCount -eq 3) 'Assembly verified from all depots'
    Check (Test-Path -LiteralPath (Join-Path $result.OutputPath 'file_900.txt')) 'Contents merged directly into InstallDir'
    Check (-not (Test-Path -LiteralPath (Join-Path $result.OutputPath 'depot_900'))) 'Depot container folders not nested in game output'
    Reject { Invoke-DepotAssembly $metadataPath $output } 'Existing output not overwritten'
    Check (Test-Path -LiteralPath (Join-Path $cache 'depot_900')) 'Failed assembly retains raw cache'
    Set-Content -LiteralPath (Join-Path $cache 'depot_900/shared.txt') -Value 'first'
    Set-Content -LiteralPath (Join-Path $cache 'depot_200/shared.txt') -Value 'second'
    foreach ($receipt in $metadata.Receipts) { $receipt.Inventory=@(Get-DepotInventory (Join-Path $cache "depot_$($receipt.DepotId)")) }
    Write-DepotJson $metadataPath $metadata
    $output2=Assert-DepotPath (Join-Path $fixture 'output2') -Create
    Reject { Invoke-DepotAssembly $metadataPath $output2 } 'Different-content collisions block default assembly'
    $result2=Invoke-DepotAssembly $metadataPath $output2 'AppInfoOrder'
    Check ((Get-Content -LiteralPath (Join-Path $result2.OutputPath 'shared.txt')) -eq 'second') 'Explicit AppInfo order uses later depot, not larger numeric ID'
    Check ($result2.Collisions.Count -eq 1) 'Collision audit returned'
    Set-Content -LiteralPath (Join-Path $cache 'depot_900/file_900.txt') -Value 'tampered'
    Reject { Invoke-DepotAssembly $metadataPath (Join-Path $fixture 'output3') } 'Tampered cache blocks assembly'
    Check ((Get-Content -LiteralPath (Join-Path $result.OutputPath 'file_900.txt')) -eq '900') 'Failed operation preserves previous valid output'
    Reject { Assert-SeparateDepotPaths $cache (Join-Path $cache 'output') } 'Overlapping paths rejected'
    New-Item -ItemType Junction -Path (Join-Path $cache 'linked') -Target $output | Out-Null
    Reject { Get-DepotFiles $cache } 'Linked depot tree rejected'
    [IO.Directory]::Delete((Join-Path $cache 'linked'))
    Write-Host "All $script:passed depot checks passed."
} finally {
    if (-not $fixture.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $fixture -Leaf) -notlike 'steam-depot-test-*') { throw 'Unsafe fixture cleanup.' }
    if (Test-Path -LiteralPath (Join-Path $fixture 'cache/linked')) { [IO.Directory]::Delete((Join-Path $fixture 'cache/linked')) }
    foreach ($node in @(Get-CleanupNode $fixture ([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')))) {
        if ($node.Directory) { [IO.Directory]::Delete($node.Path,$false) } else { Remove-Item -LiteralPath $node.Path -Force }
    }
}
