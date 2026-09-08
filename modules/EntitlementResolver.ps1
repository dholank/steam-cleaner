function Get-SteamLicensePackageIds {
    param([Parameter(Mandatory=$true)][string]$Text)
    $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $patterns=@(
        '(?im)\b(?:license\s+)?package(?:id)?\s*[:=#]?\s*([1-9][0-9]{0,9})\b',
        '(?im)^\s*package\s+([1-9][0-9]{0,9})\b',
        '(?im)^\s*"([1-9][0-9]{0,9})"\s*\{\s*(?:\r?\n)?\s*"packageid"'
    )
    foreach ($pattern in $patterns) {
        foreach ($match in [regex]::Matches($Text,$pattern)) { $null=$ids.Add($match.Groups[1].Value) }
    }
    return @($ids | Sort-Object {[uint64]$_})
}

function Get-SteamIdValues {
    param($Node)
    if ($Node -isnot [Collections.IDictionary]) { return @() }
    $values=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($key in $Node.Keys) {
        $value=[string]$Node[$key]
        if ($value -match '^[1-9][0-9]{0,19}$') { $null=$values.Add($value) }
        elseif ([string]$key -match '^[1-9][0-9]{0,19}$' -and $value -match '^(?:1|true)$') { $null=$values.Add([string]$key) }
    }
    return @($values)
}

function Get-SteamPackageGrantFromOutput {
    param([Parameter(Mandatory=$true)][string]$Text, [Parameter(Mandatory=$true)][string]$PackageId)
    $null=Assert-SteamId $PackageId
    try { $node=Get-SteamVdfObjectFromOutput -Text $Text -RootKey $PackageId -Description 'Package metadata' }
    catch {
        $wrapper=Get-SteamVdfObjectFromOutput -Text $Text -RootKey 'packageinfo' -Description 'Package metadata'
        if ($wrapper -isnot [Collections.IDictionary] -or -not $wrapper.Contains($PackageId)) { throw }
        $node=$wrapper[$PackageId]
    }
    $appNode=Get-VdfValue $node @('appids')
    $depotNode=Get-VdfValue $node @('depotids')
    if ($appNode -isnot [Collections.IDictionary]) { $appNode=Get-VdfValue $node @('data','appids') }
    if ($depotNode -isnot [Collections.IDictionary]) { $depotNode=Get-VdfValue $node @('data','depotids') }
    [pscustomobject]@{
        PackageId=$PackageId
        AppIds=@(Get-SteamIdValues $appNode)
        DepotIds=@(Get-SteamIdValues $depotNode)
        HasAppGrantList=($appNode -is [Collections.IDictionary])
        HasDepotGrantList=($depotNode -is [Collections.IDictionary])
    }
}

function Get-SteamAccountEntitlements {
    param(
        [Parameter(Mandatory=$true)][string]$Exe,
        [Parameter(Mandatory=$true)][string]$UserName,
        [Parameter(Mandatory=$true)][string]$AppId,
        [int]$TimeoutSeconds=21600,
        [scriptblock]$Invoker
    )
    $null=Assert-SteamId $AppId
    $invoke={ param($operation,$package)
        if ($Invoker) { return (& $Invoker $Exe $UserName $operation $AppId $null $null $package $null $TimeoutSeconds) }
        return Invoke-SteamCmd -Exe $Exe -UserName $UserName -Operation $operation -AppId $AppId -PackageId $package -TimeoutSeconds $TimeoutSeconds
    }
    $licenseResult=& $invoke 'LicensesForApp' $null
    $packages=@(Get-SteamLicensePackageIds ([string]$licenseResult.Stdout + "`n" + [string]$licenseResult.Stderr))
    if (-not $packages.Count) {
        return [pscustomobject]@{ AppId=$AppId; PackageIds=@(); AppIds=@(); DepotIds=@(); Complete=$false; Confidence='LOW'; Reason='SteamCMD returned no package IDs for this app. Ownership cannot be proven automatically.'; Grants=@() }
    }

    # licenses_print is a second account-level check. If its format is parseable,
    # keep only package IDs that are active in both SteamCMD views.
    try {
        $allLicenses=& $invoke 'Licenses' $null
        $activePackages=@(Get-SteamLicensePackageIds ([string]$allLicenses.Stdout + "`n" + [string]$allLicenses.Stderr))
        if ($activePackages.Count) { $packages=@($packages | Where-Object { $_ -in $activePackages }) }
    } catch {}
    if (-not $packages.Count) {
        return [pscustomobject]@{ AppId=$AppId; PackageIds=@(); AppIds=@(); DepotIds=@(); Complete=$false; Confidence='LOW'; Reason='SteamCMD license views did not agree on an active package for this app.'; Grants=@() }
    }

    $apps=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $depots=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $grants=[Collections.Generic.List[object]]::new()
    $complete=$true
    foreach ($package in $packages) {
        try {
            $packageResult=& $invoke 'PackageInfo' $package
            $grant=Get-SteamPackageGrantFromOutput ([string]$packageResult.Stdout + "`n" + [string]$packageResult.Stderr) $package
            $grants.Add($grant)
            foreach ($id in $grant.AppIds) { $null=$apps.Add($id) }
            foreach ($id in $grant.DepotIds) { $null=$depots.Add($id) }
            if (-not $grant.HasDepotGrantList) { $complete=$false }
        } catch {
            $complete=$false
            $grants.Add([pscustomobject]@{ PackageId=$package; AppIds=@(); DepotIds=@(); HasAppGrantList=$false; HasDepotGrantList=$false; Error=$_.Exception.Message })
        }
    }
    $hasApp=$apps.Contains($AppId)
    $reason=if ($complete) { 'Package metadata contains a complete explicit depot grant list.' }
            elseif ($hasApp) { 'The account has an app-level grant, but SteamCMD package metadata has no complete depot list.' }
            else { 'SteamCMD package metadata is incomplete; entitlement cannot be proven.' }
    [pscustomobject]@{ AppId=$AppId; PackageIds=$packages; AppIds=@($apps); DepotIds=@($depots); Complete=$complete; Confidence=$(if ($complete) {'HIGH'} else {'LOW'}); Reason=$reason; Grants=@($grants.ToArray()) }
}

function Resolve-DepotEntitlement {
    param([Parameter(Mandatory=$true)][string]$DepotId, [Parameter(Mandatory=$true)][string]$SourceAppId, [Parameter(Mandatory=$true)]$Entitlements)
    $packageIds=@($Entitlements.Grants | Where-Object { $_.DepotIds -contains $DepotId } | ForEach-Object PackageId)
    if ($packageIds.Count) { return [pscustomobject]@{ Entitled=$true; Confidence='HIGH'; PackageIds=$packageIds; Reason='An active account package explicitly grants this depot.' } }
    if ($Entitlements.Complete) { return [pscustomobject]@{ Entitled=$false; Confidence='HIGH'; PackageIds=@(); Reason='This depot is absent from the complete grants of the active account packages.' } }
    $appPackages=@($Entitlements.Grants | Where-Object { $_.AppIds -contains $SourceAppId } | ForEach-Object PackageId)
    if ($appPackages.Count) { return [pscustomobject]@{ Entitled=$null; Confidence='LOW'; PackageIds=$appPackages; Reason='The account has an app-level package grant, but its depot grant list is incomplete.' } }
    return [pscustomobject]@{ Entitled=$null; Confidence='LOW'; PackageIds=@(); Reason='SteamCMD did not provide enough package metadata to prove depot ownership.' }
}
