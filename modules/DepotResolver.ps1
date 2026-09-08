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
    if (-not $source) { return [pscustomobject]@{ Node=$Node; SourceAppId=$AppId; SourceBuildId=$null; SourceName=$null; SourceType=$null } }
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
    [pscustomobject]@{
        Node=$merged
        SourceAppId=$resolved.SourceAppId
        SourceBuildId=$(if ($resolved.SourceBuildId) {$resolved.SourceBuildId} else {Get-VdfValue $info @('depots','branches',$Branch,'buildid')})
        SourceName=$(if ($resolved.SourceName) {$resolved.SourceName} else {[string](Get-VdfValue $info @('common','name'))})
        SourceType=$(if ($resolved.SourceType) {$resolved.SourceType} else {[string](Get-VdfValue $info @('common','type'))})
    }
}

function Resolve-SteamDepots {
    param([string]$AppId, $AppInfo, $Settings, [scriptblock]$FetchAppInfo, $Entitlements, [scriptblock]$FetchEntitlements)
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
    if ($appType -eq 'DLC') { throw 'This AppID is DLC. Automatic mode downloads base applications with DLC=None.' }
    $decisions=[Collections.Generic.List[object]]::new()
    $order=0
    foreach ($depotId in $depots.Keys) {
        if ($depotId -notmatch '^[0-9]+$') { continue }
        $null=Assert-SteamId $depotId
        $order++
        $row=[ordered]@{
            DepotId=[string]$depotId; Entitled=$null; Selected=$false; Decision='REVIEW'; Action='REVIEW'
            Reason='Not evaluated'; Confidence='LOW'; ContentKind='Game'; ManifestId=$null; DownloadState='NotStarted'
            MountOrder=$order; OrderSource='AppInfo enumeration'; OrderConfidence='MEDIUM'
            SourceAppId=$AppId; SourceBuildId=$null; SourcePackageIds=@(); Config=$null; DLCAppId=$null
            SharedInstall=$null; ExpectedBytes=$null
        }
        try {
            $shared=Resolve-SharedDepot -AppId $AppId -DepotId $depotId -Node $depots[$depotId] -FetchAppInfo $FetchAppInfo -Branch $Settings.Branch
            $node=$shared.Node
            $row.SourceAppId=$shared.SourceAppId; $row.SourceBuildId=$shared.SourceBuildId
            $config=Get-VdfValue $node @('config'); $row.Config=$config
            $dlc=Get-VdfValue $node @('dlcappid')
            if (-not $dlc) { $dlc=Get-VdfValue $config @('dlcappid') }
            $row.DLCAppId=$dlc; $row.SharedInstall=Get-VdfValue $node @('sharedinstall')
            if ($row.SourceAppId -ne $AppId) { $row.ContentKind='Shared' }
            if ($row.SourceAppId -eq '228980' -and $shared.SourceName -eq 'Steamworks Common Redistributables') { $row.ContentKind='Prerequisite' }
            elseif ($row.SourceAppId -eq '228980') { throw 'Source AppID 228980 did not have the validated Steamworks Common Redistributables identity.' }

            if ($Entitlements) {
                $sourceEntitlements=$Entitlements
                if ($row.SourceAppId -ne $AppId -and $FetchEntitlements) { $sourceEntitlements=& $FetchEntitlements $row.SourceAppId }
                $entitlement=Resolve-DepotEntitlement -DepotId $depotId -SourceAppId $row.SourceAppId -Entitlements $sourceEntitlements
                $row.Entitled=$entitlement.Entitled
                $row.SourcePackageIds=@($entitlement.PackageIds)
                $row.Confidence=$entitlement.Confidence
                if ($null -eq $entitlement.Entitled) {
                    $row.Decision='REVIEW'; $row.Action='REVIEW'; $row.Reason=$entitlement.Reason
                    throw [InvalidOperationException]::new('__ENTITLEMENT_REVIEW__')
                }
                if (-not $entitlement.Entitled) {
                    $row.Decision=$(if ($row.ContentKind -eq 'Shared') {'ERROR'} else {'SKIP'})
                    $row.Action=$row.Decision
                    $row.Reason=$(if ($row.ContentKind -eq 'Shared') {'Required shared depot is not granted by this account. Check ownership or edition.'} else {$entitlement.Reason})
                    throw [InvalidOperationException]::new('__ENTITLEMENT_DECIDED__')
                }
            } else {
                # Kept for resolver-only compatibility; the downloader always supplies SteamCMD entitlement evidence.
                $row.Entitled=$null; $row.Confidence='MEDIUM'
            }
            $arch = if ($Settings.Architecture -eq 'x64') { '64' } else { '32' }
            if ($row.ContentKind -eq 'Prerequisite') { $row.Decision='SKIP'; $row.Action='SKIP'; $row.Reason='Steamworks Common Redistributables are not assembled into the game output.' }
            elseif ($dlc -and $dlc -ne '0') { $row.ContentKind='DLC'; $row.Decision='SKIP'; $row.Action='SKIP'; $row.Reason='DLC excluded by DLC=None policy.' }
            elseif (-not (Test-DepotRestriction (Get-VdfValue $config @('oslist')) $Settings.Platform)) { $row.Decision='SKIP'; $row.Action='SKIP'; $row.Reason='OS mismatch' }
            elseif (-not (Test-DepotRestriction (Get-VdfValue $config @('osarch')) $arch)) { $row.Decision='SKIP'; $row.Action='SKIP'; $row.Reason='Architecture mismatch' }
            elseif (-not (Test-DepotRestriction (Get-VdfValue $config @('language')) $Settings.Language)) { $row.Decision='SKIP'; $row.Action='SKIP'; $row.Reason='Language mismatch' }
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
                if ($row.ExpectedBytes -and [uint64]$row.ExpectedBytes -eq 0) {
                    $row.ContentKind='ZeroByte'; $row.Decision='SKIP'; $row.Action='SKIP'; $row.Reason='Zero-byte depot recorded; no download or merge is needed.'
                } else {
                    $row.Selected=$true; $row.Decision='DOWNLOAD'; $row.Action='DOWNLOAD'
                    if ($Entitlements) { $row.Confidence='HIGH'; $row.Reason='Explicit depot grant and selected configuration match.' }
                    elseif ($row.SourceAppId -ne $AppId) { $row.Confidence='MEDIUM'; $row.Reason='Shared source resolved; source build tracked separately' }
                    else { $row.Reason='Selected configuration matches.' }
                }
            }
        } catch {
            if ($_.Exception.Message -notin @('__ENTITLEMENT_REVIEW__','__ENTITLEMENT_DECIDED__')) {
                $row.Selected=$false; $row.Decision='REVIEW'; $row.Action='REVIEW'; $row.Confidence='LOW'; $row.Reason=$_.Exception.Message
            }
        }
        $decisions.Add([pscustomobject]$row)
    }
    if (-not $decisions.Count) { throw 'No depot entries found in AppInfo.' }
    $selected=@($decisions | Where-Object Selected)
    $blocking=@($decisions | Where-Object { $_.Decision -in @('REVIEW','ERROR') })
    [pscustomobject]@{
        SchemaVersion=2; AppId=$AppId; Name=$name; InstallDir=$install
        Platform=$Settings.Platform; Architecture=$Settings.Architecture; Language=$Settings.Language; Branch=$Settings.Branch; DLC=$Settings.DLC
        BuildId=(Get-VdfValue $branch @('buildid')); Depots=$selected; Decisions=@($decisions.ToArray())
        CanDownload=($blocking.Count -eq 0 -and $selected.Count -gt 0)
        Confidence=$(if ($blocking.Count) {'LOW'} elseif ($Entitlements) {'HIGH'} else {'MEDIUM'})
        OrderSource='AppInfo enumeration (Valve depot mounting order; later entries win)'; ResolvedAt=[DateTime]::UtcNow.ToString('o')
        EntitlementPackages=$(if ($Entitlements) {@($Entitlements.PackageIds)} else {@()})
    }
}
