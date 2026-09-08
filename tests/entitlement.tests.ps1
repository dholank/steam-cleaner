$ErrorActionPreference='Stop'
. "$PSScriptRoot/../steam-cleaner.ps1" -LoadOnly
$script:passed=0
function Check($Condition,$Message) { if (-not $Condition) { throw "FAILED: $Message" }; $script:passed++; Write-Host "PASS: $Message" }
$packageText='"55" { "packageid" "55" "appids" { "0" "12345" } "depotids" { "0" "12346" "1" "12348" "2" "12349" } }'
Check (((Get-SteamLicensePackageIds "License package 55`npackageid: 55") -join ',') -eq '55') 'SteamCMD license package IDs parsed without duplicates'
$grant=Get-SteamPackageGrantFromOutput $packageText '55'
Check (($grant.AppIds -contains '12345') -and ($grant.DepotIds -contains '12346') -and $grant.HasDepotGrantList) 'Package app and depot grants parsed'
$invoker={param($exe,$user,$operation,$app,$depot,$manifest,$package,$destination,$timeout)
    if ($operation -eq 'LicensesForApp') {return [pscustomobject]@{Stdout='License package 55';Stderr=''}}
    if ($operation -eq 'PackageInfo') {return [pscustomobject]@{Stdout=$packageText;Stderr=''}}
}
$entitlements=Get-SteamAccountEntitlements 'C:\fixture\steamcmd.exe' 'account' '12345' 30 $invoker
Check ($entitlements.Complete -and $entitlements.DepotIds.Count -eq 3) 'Complete active package grants produce HIGH-confidence entitlement data'
$unknown=Get-SteamAccountEntitlements 'C:\fixture\steamcmd.exe' 'account' '12345' 30 {param($e,$u,$o) [pscustomobject]@{Stdout='No licenses found';Stderr=''}}
Check (-not $unknown.Complete -and $unknown.Confidence -eq 'LOW') 'Missing license metadata remains unknown'
$incomplete=Get-SteamAccountEntitlements 'C:\fixture\steamcmd.exe' 'account' '12345' 30 {param($e,$u,$o,$a,$d,$m,$p) if($o -eq 'LicensesForApp'){[pscustomobject]@{Stdout='License package 56';Stderr=''}}else{[pscustomobject]@{Stdout='"56" { "appids" { "0" "12345" } }';Stderr=''}}}
Check (-not $incomplete.Complete -and $incomplete.AppIds -contains '12345') 'App-level grant without depot list remains incomplete'

$settings=Get-DepotSettings -StoredSettingsPath (Join-Path $env:TEMP ('missing-'+[guid]::NewGuid()+'.json'))
$info=Get-SteamAppInfoFromOutput (Get-Content -Raw "$PSScriptRoot/fixtures/dayz-style-appinfo.vdf") '12345'
$plan=Resolve-SteamDepots '12345' $info $settings $null $entitlements
$unowned=@($plan.Decisions | Where-Object DepotId -eq '12347')[0]
Check ($unowned.Decision -eq 'SKIP' -and $unowned.Confidence -eq 'HIGH' -and $unowned.Entitled -eq $false) 'Generic Windows x64 unrestricted but unowned depot is skipped'
Check (-not (Select-String -Path "$PSScriptRoot/../modules/*.ps1" -Pattern '221100' -Quiet)) 'Entitlement behavior has no game-specific AppID condition'
$zero=@($plan.Decisions | Where-Object DepotId -eq '12348')[0]
Check ($zero.Decision -eq 'SKIP' -and $zero.ContentKind -eq 'ZeroByte') 'Zero-byte depot is recorded without download or merge'
$dlc=@($plan.Decisions | Where-Object DepotId -eq '12349')[0]
Check ($dlc.Decision -eq 'SKIP' -and $dlc.ContentKind -eq 'DLC') 'Owned DLC remains skipped under DLC=None'
Check ($plan.CanDownload -and ($plan.Depots.DepotId -join ',') -eq '12346') 'Only explicitly entitled base content is selected'
$reviewPlan=Resolve-SteamDepots '12345' $info $settings $null $incomplete
Check (-not $reviewPlan.CanDownload -and @($reviewPlan.Decisions | Where-Object Decision -eq 'REVIEW').Count) 'Unknown entitlement blocks automatic download as REVIEW/LOW'

$sharedInfo=ConvertFrom-SteamVdf '"depots" { "777" { "manifests" { "public" { "gid" "7000" "size" "1" } } } "branches" { "public" { "buildid" "8" } } } "common" { "name" "Shared Fixture" "type" "Game" }'
$sharedTarget=ConvertFrom-SteamVdf '"common" { "name" "Target" "type" "Game" } "config" { "installdir" "Target" } "depots" { "777" { "depotfromapp" "20000" } "branches" { "public" { "buildid" "9" } } }'
$noShared=[pscustomobject]@{Complete=$true;PackageIds=@('1');Grants=@([pscustomobject]@{PackageId='1';AppIds=@('12345');DepotIds=@()})}
$sharedDenied=Resolve-SteamDepots '12345' $sharedTarget $settings {param($id) return ,$sharedInfo} $noShared
Check ((@($sharedDenied.Decisions)[0].Decision -eq 'ERROR') -and -not $sharedDenied.CanDownload) 'Required unowned shared depot is an actionable error'
$sharedUnknown=Resolve-SteamDepots '12345' $sharedTarget $settings {param($id) return ,$sharedInfo} $incomplete
Check ((@($sharedUnknown.Decisions)[0].Decision -eq 'REVIEW') -and -not $sharedUnknown.CanDownload) 'Unclear shared-depot entitlement requires review'

$redistSource=ConvertFrom-SteamVdf '"depots" { "228981" { "manifests" { "public" { "gid" "8000" "size" "3" } } } "branches" { "public" { "buildid" "10" } } } "common" { "name" "Steamworks Common Redistributables" "type" "Application" }'
$redistTarget=ConvertFrom-SteamVdf '"common" { "name" "Target" "type" "Game" } "config" { "installdir" "Target" } "depots" { "228981" { "depotfromapp" "228980" } "branches" { "public" { "buildid" "11" } } }'
$redistGrant=[pscustomobject]@{Complete=$true;PackageIds=@('2');Grants=@([pscustomobject]@{PackageId='2';AppIds=@('228980');DepotIds=@('228981')})}
$redistPlan=Resolve-SteamDepots '12345' $redistTarget $settings {param($id) return ,$redistSource} $redistGrant
Check ((@($redistPlan.Decisions)[0].ContentKind -eq 'Prerequisite') -and (@($redistPlan.Decisions)[0].Decision -eq 'SKIP')) 'Validated Steamworks Common Redistributables are excluded from game assembly'

$modules=(Get-Content -Raw "$PSScriptRoot/../modules/*.ps1") -join "`n"
Check ($modules -notmatch '(?i)appmanifest_' -and $modules -notmatch '(?i)run_app_build') 'Implementation never creates Steam app manifests or changes library registration'
Check ($modules -notmatch '(?i)\+app_run|\+run_app|installscript\.vdf') 'Implementation never launches games or executes prerequisite install scripts'
Write-Host "All $script:passed entitlement checks passed."
