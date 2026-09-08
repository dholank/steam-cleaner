function Get-VdfValue {
    param($Node, [string[]]$Keys)
    foreach ($key in $Keys) {
        if ($Node -isnot [Collections.IDictionary] -or -not $Node.Contains($key)) { return $null }
        $Node = $Node[$key]
    }
    return ,$Node
}

function Test-DepotRestriction {
    param([string]$Value, [string]$Selected)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $true }
    return $Selected -in @($Value.ToLowerInvariant() -split '[,;\s]+' | Where-Object { $_ })
}

function Resolve-SharedDepot {
    param([string]$AppId, [string]$DepotId, $Node, [scriptblock]$FetchAppInfo, [string[]]$Visited = @(), [string]$Branch='public')
    $key = "${AppId}:$DepotId"
    if ($key -in $Visited -or $Visited.Count -ge 16) { throw 'Shared depot reference cycle/depth limit.' }
    $source = Get-VdfValue $Node @('depotfromapp')
    if (-not $source) { return [pscustomobject]@{ Node=$Node; SourceAppId=$AppId; SourceBuildId=$null } }
    $null = Assert-SteamId $source
    if (-not $FetchAppInfo) { throw 'Shared depot requires source AppInfo.' }
    $info = & $FetchAppInfo $source
    $sourceNode = Get-VdfValue $info @('depots',$DepotId)
    if ($sourceNode -isnot [Collections.IDictionary]) { throw "Shared depot $DepotId is missing from source AppID $source." }
    $resolved = Resolve-SharedDepot $source $DepotId $sourceNode $FetchAppInfo ($Visited + $key) $Branch
    $merged = [ordered]@{}
    foreach ($k in $resolved.Node.Keys) { $merged[$k]=$resolved.Node[$k] }
    foreach ($k in $Node.Keys) {
        if ($k -eq 'config') {
            $config = [ordered]@{}
            $inherited = Get-VdfValue $resolved.Node @('config')
            if ($inherited -is [Collections.IDictionary]) { foreach ($c in $inherited.Keys) { $config[$c]=$inherited[$c] } }
            if ($Node[$k] -is [Collections.IDictionary]) { foreach ($c in $Node[$k].Keys) {
                if ($config.Contains($c) -and $config[$c] -ne $Node[$k][$c]) { throw "Conflicting shared depot restriction: $c" }
                $config[$c]=$Node[$k][$c]
            } }
            $merged[$k]=$config
        } else { $merged[$k]=$Node[$k] }
    }
    if ((Get-VdfValue $info @('common','type')) -eq 'DLC' -and -not (Get-VdfValue $merged @('dlcappid'))) { $merged['dlcappid']=$source }
    [pscustomobject]@{ Node=$merged; SourceAppId=$resolved.SourceAppId; SourceBuildId=$(if ($resolved.SourceBuildId) {$resolved.SourceBuildId} else {Get-VdfValue $info @('depots','branches',$Branch,'buildid')}) }
}

function Resolve-SteamDepots {
    param([string]$AppId, $AppInfo, $Settings, [scriptblock]$FetchAppInfo)
    $null = Assert-SteamId $AppId
    $depots = Get-VdfValue $AppInfo @('depots')
    if ($depots -isnot [Collections.IDictionary]) { throw 'AppInfo contains no depot configuration. Check account access or AppID.' }
    $branch = Get-VdfValue $depots @('branches',$Settings.Branch)
    if ($null -eq $branch) { throw "Branch '$($Settings.Branch)' is unavailable. Select an accessible branch." }
    if ((Get-VdfValue $branch @('pwdrequired')) -eq '1') { throw 'Password-protected branches are not supported in version 1.' }
    $name = [string](Get-VdfValue $AppInfo @('common','name'))
    $install = [string](Get-VdfValue $AppInfo @('config','installdir'))
    if ([string]::IsNullOrWhiteSpace($install)) { $install=ConvertTo-InstallDirectoryName $name -Fallback }
    else { $install=ConvertTo-InstallDirectoryName $install }
    $appType = Get-VdfValue $AppInfo @('common','type')
    if ($appType -eq 'DLC') { throw 'This AppID is DLC. Version 1 downloads base applications with DLC=None.' }
    $decisions=[Collections.Generic.List[object]]::new()
    $order=0
    foreach ($depotId in $depots.Keys) {
        if ($depotId -notmatch '^[0-9]+$') { continue }
        $null=Assert-SteamId $depotId
        $order++
        $row=[ordered]@{ DepotId=[string]$depotId; Action='DOWNLOAD'; Confidence='HIGH'; Reason='Common/unrestricted'; ManifestId=$null; MountOrder=$order; OrderSource='AppInfo enumeration (unverified mount priority)'; OrderConfidence='MEDIUM'; SourceAppId=$AppId; SourceBuildId=$null; Config=$null; DLCAppId=$null; SharedInstall=$null; ExpectedBytes=$null }
        try {
            $shared=Resolve-SharedDepot -AppId $AppId -DepotId $depotId -Node $depots[$depotId] -FetchAppInfo $FetchAppInfo -Branch $Settings.Branch
            $node=$shared.Node
            $row.SourceAppId=$shared.SourceAppId; $row.SourceBuildId=$shared.SourceBuildId
            $config=Get-VdfValue $node @('config'); $row.Config=$config
            $dlc=Get-VdfValue $node @('dlcappid')
            if (-not $dlc) { $dlc=Get-VdfValue $config @('dlcappid') }
            $row.DLCAppId=$dlc; $row.SharedInstall=Get-VdfValue $node @('sharedinstall')
            $arch = if ($Settings.Architecture -eq 'x64') { '64' } else { '32' }
            if ($dlc -and $dlc -ne '0') { $row.Action='SKIP'; $row.Reason='DLC excluded' }
            elseif (-not (Test-DepotRestriction (Get-VdfValue $config @('oslist')) $Settings.Platform)) { $row.Action='SKIP'; $row.Reason='OS mismatch' }
            elseif (-not (Test-DepotRestriction (Get-VdfValue $config @('osarch')) $arch)) { $row.Action='SKIP'; $row.Reason='Architecture mismatch' }
            elseif (-not (Test-DepotRestriction (Get-VdfValue $config @('language')) $Settings.Language)) { $row.Action='SKIP'; $row.Reason='Language mismatch' }
            else {
                if ($config -is [Collections.IDictionary]) {
                    $unknown=@($config.Keys | Where-Object { $_ -notin @('oslist','osarch','language','dlcappid') })
                    if ($unknown.Count) { throw "Unsupported depot restriction: $($unknown -join ', ')" }
                    if ($config.Count) { $row.Reason='Selected configuration matches' }
                }
                if ($row.SharedInstall -and $row.SharedInstall -notin @('0','2')) { throw 'Shared install may require a separate installation target; automatic flattening is unsafe.' }
                $manifest=Get-VdfValue $node @('manifests',$Settings.Branch)
                if ($manifest -is [Collections.IDictionary]) {
                    $row.ManifestId=[string](Get-VdfValue $manifest @('gid'))
                    $row.ExpectedBytes=Get-VdfValue $manifest @('size')
                } else { $row.ManifestId=[string]$manifest }
                if (-not $row.ManifestId) { throw 'No visible manifest for selected branch (missing or encrypted).' }
                $null=Assert-SteamId $row.ManifestId -Manifest
                if ($row.SourceAppId -ne $AppId) { $row.Confidence='MEDIUM'; $row.Reason='Shared source resolved; source build tracked separately' }
            }
        } catch { $row.Action='REVIEW'; $row.Confidence='LOW'; $row.Reason=$_.Exception.Message }
        $decisions.Add([pscustomobject]$row)
    }
    if (-not $decisions.Count) { throw 'No depot entries found in AppInfo.' }
    $selected=@($decisions | Where-Object Action -eq 'DOWNLOAD')
    $review=@($decisions | Where-Object Action -eq 'REVIEW')
    [pscustomobject]@{ SchemaVersion=1; AppId=$AppId; Name=$name; InstallDir=$install; Platform=$Settings.Platform; Architecture=$Settings.Architecture; Language=$Settings.Language; Branch=$Settings.Branch; DLC=$Settings.DLC; BuildId=(Get-VdfValue $branch @('buildid')); Depots=$selected; Decisions=@($decisions.ToArray()); CanDownload=($review.Count -eq 0 -and $selected.Count -gt 0); Confidence=$(if ($review.Count) {'LOW'} else {'MEDIUM'}); OrderSource='AppInfo enumeration; not guaranteed Steam mount priority'; ResolvedAt=[DateTime]::UtcNow.ToString('o') }
}
