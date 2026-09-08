function Get-DownloadCompletion {
    param([string]$Text, [string]$DepotId, [string]$ManifestId, [string]$ExpectedPath)
    $completion=[regex]::Match($Text,'(?im)^\s*Depot download complete\s*:\s*"(?<path>[^"\r\n]+)"\s*\((?<details>[^\r\n]*)\)')
    if (-not $completion.Success -or $completion.Groups['details'].Value -notmatch ('\bmanifest\s+' + [regex]::Escape($ManifestId) + '\b')) { throw "Depot $DepotId did not report completion for the selected manifest. Retry; it is not safe to assemble." }
    $reported=[IO.Path]::GetFullPath($completion.Groups['path'].Value).TrimEnd('\')
    if ($reported -ne $ExpectedPath.TrimEnd('\')) { throw 'SteamCMD reported an unexpected download directory. Automatic cache import refused.' }
    $countMatch=[regex]::Match($completion.Groups['details'].Value,'\b(?<count>[0-9]+)\s+files?\b')
    return [pscustomobject]@{ FileCount=$(if ($countMatch.Success) {[long]$countMatch.Groups['count'].Value} else {$null}) }
}

function Get-DepotDiskRequirement {
    param($Plan, [string]$DownloadRoot, [string[]]$CompletedDepotIds=@())
    $known=$true; [decimal]$raw=0; [decimal]$assembly=0
    foreach ($depot in $Plan.Depots) {
        if ($null -eq $depot.ExpectedBytes -or [string]$depot.ExpectedBytes -eq '') { $known=$false; continue }
        $bytes=[decimal]$depot.ExpectedBytes
        $assembly+=$bytes
        if ($depot.DepotId -notin $CompletedDepotIds) { $raw+=$bytes }
    }
    $headroom=[decimal][Math]::Max(1GB,[double](($raw+$assembly)*0.10))
    $required=[decimal]($raw+$assembly+$headroom)
    $drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($DownloadRoot)))
    [pscustomobject]@{ Exact=$known; RawBytes=$raw; AssemblyBytes=$assembly; HeadroomBytes=$headroom; RequiredBytes=$required; AvailableBytes=[decimal]$drive.AvailableFreeSpace }
}

function Assert-DepotDiskSpace {
    param($Plan, [string]$DownloadRoot, [string[]]$CompletedDepotIds=@(), [string]$LogPath)
    $estimate=Get-DepotDiskRequirement $Plan $DownloadRoot $CompletedDepotIds
    if ($estimate.Exact -and $estimate.AvailableBytes -lt $estimate.RequiredBytes) {
        throw "Insufficient space on the selected drive. Required peak: $([Math]::Ceiling($estimate.RequiredBytes/1GB)) GiB; available: $([Math]::Floor($estimate.AvailableBytes/1GB)) GiB."
    }
    if (-not $estimate.Exact) { Write-DepotLog 'Some depot sizes are unavailable. Disk-space check is an estimate; raw depots, staging output and headroom share this drive.' -Level WARN -LogPath $LogPath }
    return $estimate
}

function Get-DepotSteamCmdRuntime {
    param([string]$PrimaryExe, $Settings, [bool]$SupportsDestination, [scriptblock]$RuntimeResolver)
    if ($SupportsDestination) { return [pscustomobject]@{ Exe=$PrimaryExe; DirectDestination=$true } }
    $runtimeRoot=Assert-DepotPath (Join-Path (Join-Path $Settings.DownloadRoot '.depot-cache') '_steamcmd-runtime') -Create
    $runtimeSettings=[pscustomobject]@{ SteamCmdPath=''; ToolsRoot=$runtimeRoot }
    $runtimeExe=if ($RuntimeResolver) { & $RuntimeResolver $runtimeSettings } else { Get-SteamCmdPath $runtimeSettings -ManagedOnly }
    return [pscustomobject]@{ Exe=$runtimeExe; DirectDestination=$false }
}

function Invoke-DepotDownloads {
    param($Plan, $Settings, [string]$Exe, [string]$UserName, [string]$LogPath, [bool]$DirectDestination=$false)
    if (-not $Plan.CanDownload) { throw 'Depot resolution requires review; no download was started.' }
    $snapshot=Assert-DepotPath (Get-DepotCacheRoot $Settings $Plan.AppId) -Create
    $metadataPath=Join-Path $snapshot 'metadata.json'
    $receipts=[Collections.Generic.List[object]]::new()
    $metadata=[pscustomobject]@{
        SchemaVersion=2; Status='Planned'; PlanKey=(Get-DepotPlanKey $Plan); Plan=$Plan; Receipts=@()
        DownloadRoot=$Settings.DownloadRoot; CacheRoot=$snapshot; OutputPath=(Get-DepotOutputPath $Settings $Plan.InstallDir)
        PlannedAt=[DateTime]::UtcNow.ToString('o'); DestinationMode=$(if ($DirectDestination) {'Direct'} else {'IsolatedSteamCmdRuntime'})
        Verification='SteamCMD completion plus local SHA256 inventory; not an independent Steam manifest signature check'
    }
    Write-DepotJson $metadataPath $metadata
    try {
        $completed=[Collections.Generic.List[string]]::new()
        foreach ($depot in $Plan.Depots) {
            $target=Join-Path $snapshot "depot_$($depot.DepotId)"
            $receiptPath=Join-Path $snapshot "receipt_$($depot.DepotId).json"
            if ((Test-Path -LiteralPath $target) -and (Test-Path -LiteralPath $receiptPath)) {
                try {
                    $receipt=Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    if ($receipt.Status -ne 'Complete' -or $receipt.DepotId -ne $depot.DepotId -or $receipt.ManifestId -cne $depot.ManifestId) { throw 'Manifest receipt mismatch.' }
                    $null=Test-DepotInventory $target @($receipt.Inventory)
                    $receipts.Add($receipt); $completed.Add([string]$depot.DepotId)
                    $depot.DownloadState='Reused'
                    Write-DepotLog "Verified cached depot $($depot.DepotId)." -LogPath $LogPath
                    continue
                } catch {
                    $oldManifest=try {[string]$receipt.ManifestId} catch {'unknown'}
                    $moved=Move-StaleDepotSnapshot $snapshot $depot.DepotId $oldManifest
                    Write-DepotLog "Moved mismatched depot $($depot.DepotId) to stale storage: $moved" -Level WARN -LogPath $LogPath
                }
            } elseif ((Test-Path -LiteralPath $target) -or (Test-Path -LiteralPath $receiptPath)) {
                $moved=Move-StaleDepotSnapshot $snapshot $depot.DepotId
                Write-DepotLog "Moved incomplete depot $($depot.DepotId) to stale storage: $moved" -Level WARN -LogPath $LogPath
            }
        }
        $metadata.Receipts=@($receipts.ToArray()); $metadata.Status='Downloading'; Write-DepotJson $metadataPath $metadata
        $null=Assert-DepotDiskSpace $Plan $Settings.DownloadRoot @($completed) $LogPath

        $index=0
        foreach ($depot in $Plan.Depots) {
            $index++
            if ($depot.DepotId -in $completed) { continue }
            $target=Join-Path $snapshot "depot_$($depot.DepotId)"
            $depot.DownloadState='Downloading'; Write-DepotJson $metadataPath $metadata
            if ($DirectDestination) {
                $source=$target
                $result=Invoke-SteamCmd -Exe $Exe -UserName $UserName -Operation Download -AppId $Plan.AppId -DepotId $depot.DepotId -ManifestId $depot.ManifestId -Destination $target -TimeoutSeconds $Settings.TimeoutSeconds
            } else {
                $sourceParent=Assert-DepotPath (Join-Path (Split-Path -Parent $Exe) "steamapps\content\app_$($Plan.AppId)") -Create
                $source=Join-Path $sourceParent "depot_$($depot.DepotId)"
                if (Test-Path -LiteralPath $source) {
                    $saved=$source + '.previous-' + [guid]::NewGuid().ToString('N'); [IO.Directory]::Move($source,$saved)
                    Write-DepotLog "Preserved interrupted SteamCMD spool at $saved." -Level WARN -LogPath $LogPath
                }
                $result=Invoke-SteamCmd -Exe $Exe -UserName $UserName -Operation Download -AppId $Plan.AppId -DepotId $depot.DepotId -ManifestId $depot.ManifestId -TimeoutSeconds $Settings.TimeoutSeconds
            }
            Write-DepotLog "Downloading [$index/$(@($Plan.Depots).Count)] depot $($depot.DepotId), manifest $($depot.ManifestId)." -LogPath $LogPath
            $completion=Get-DownloadCompletion $result.Stdout $depot.DepotId $depot.ManifestId $source
            $null=Assert-LocalDirectory $source
            $inventory=@(Get-DepotInventory $source)
            if ($null -ne $completion.FileCount -and $inventory.Count -ne $completion.FileCount) { throw 'Downloaded file count does not match SteamCMD completion.' }
            if ($null -ne $depot.ExpectedBytes -and [string]$depot.ExpectedBytes -ne '') {
                $actualBytes=($inventory | Measure-Object -Property Length -Sum).Sum
                if ([decimal]$actualBytes -ne [decimal]$depot.ExpectedBytes) { throw 'Downloaded size does not match AppInfo manifest size.' }
            }
            if (-not $inventory.Count) { throw 'Selected depot downloaded no files.' }
            if (-not $DirectDestination) {
                $incoming=$target + '.incoming-' + [guid]::NewGuid().ToString('N')
                Copy-DepotContents $source $incoming; $null=Test-DepotInventory $incoming $inventory; [IO.Directory]::Move($incoming,$target)
            }
            $receipt=[pscustomobject]@{ DepotId=$depot.DepotId; ManifestId=$depot.ManifestId; Status='Complete'; CompletedAt=[DateTime]::UtcNow.ToString('o'); Inventory=$inventory }
            Write-DepotReceipt $snapshot $receipt
            $receipts.Add($receipt); $metadata.Receipts=@($receipts.ToArray()); $depot.DownloadState='Complete'; Write-DepotJson $metadataPath $metadata
            Write-DepotLog "Depot $($depot.DepotId) completed and verified; $($inventory.Count) files." -LogPath $LogPath
        }
        $metadata.Status='Downloaded'; Set-DepotMetadataValue $metadata 'DownloadedAt' ([DateTime]::UtcNow.ToString('o')); Write-DepotJson $metadataPath $metadata
        return $metadataPath
    } catch {
        Set-DepotMetadataValue $metadata 'Status' 'Failed'; Set-DepotMetadataValue $metadata 'FailureStage' 'Download'; Set-DepotMetadataValue $metadata 'LastError' $_.Exception.Message
        try { Write-DepotJson $metadataPath $metadata } catch {}
        throw
    }
}

function Invoke-SteamDepotDownload {
    param([string]$AppId, $Settings, [string]$UserName, [switch]$InteractiveLocation)
    $ErrorActionPreference='Stop'; $null=Assert-SteamId $AppId
    if (Get-Process -Name steamcmd -ErrorAction SilentlyContinue) { throw 'Close other SteamCMD processes before starting this download.' }
    $primaryExe=Get-SteamCmdPath $Settings
    Connect-SteamCmd $primaryExe $UserName
    $logRoot=Assert-DepotPath (Join-Path (Get-SteamCleanerDataRoot) 'logs') -Create
    $logPath=Join-Path $logRoot ('download-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N') + '.log')
    $cacheParent=$null; $cacheLock=$null; $cleaned=$false
    try {
        Write-DepotLog "Resolving AppID $AppId and account package grants." -LogPath $logPath
        $appInfos=@{}
        $fetch={ param($id)
            if (-not $appInfos.ContainsKey($id)) {
                $response=Invoke-SteamCmd -Exe $primaryExe -UserName $UserName -Operation AppInfo -AppId $id -TimeoutSeconds $Settings.TimeoutSeconds
                $appInfos[$id]=Get-SteamAppInfoFromOutput $response.Stdout $id
            }
            return ,$appInfos[$id]
        }
        $entitlementSets=@{}
        $fetchEntitlements={ param($id)
            if (-not $entitlementSets.ContainsKey($id)) { $entitlementSets[$id]=Get-SteamAccountEntitlements -Exe $primaryExe -UserName $UserName -AppId $id -TimeoutSeconds $Settings.TimeoutSeconds }
            return $entitlementSets[$id]
        }
        $entitlements=& $fetchEntitlements $AppId
        $plan=Resolve-SteamDepots $AppId (& $fetch $AppId) $Settings $fetch $entitlements $fetchEntitlements
        foreach ($decision in $plan.Decisions) { Write-DepotLog "$($decision.DepotId) $($decision.Decision) $($decision.Confidence) entitled=$($decision.Entitled): $($decision.Reason)" -LogPath $logPath }
        if (-not $plan.CanDownload) { throw 'Automatic resolution stopped at REVIEW/ERROR. Check ownership, edition, branch, and the decisions above; no depot was downloaded.' }

        while (Test-Path -LiteralPath (Get-DepotOutputPath $Settings $plan.InstallDir)) {
            if (-not $InteractiveLocation) { throw "Final output already exists: $(Get-DepotOutputPath $Settings $plan.InstallDir). Choose another DownloadRoot or cancel." }
            Write-Host 'The final output already exists. Choose another Download Location or cancel.'
            $Settings=Select-DepotLocation $Settings
            if (-not $Settings) { throw 'Cancelled; settings and existing output were not changed.' }
        }
        $downloadRoot=Assert-DepotPath $Settings.DownloadRoot -Create
        if (-not (Test-DepotRootWritable $downloadRoot)) { throw 'Download Location is not writable.' }
        $installedSteam=$null; try { $installedSteam=Find-SteamRoot } catch {}
        if ($installedSteam) { Assert-SeparateDepotPaths $installedSteam $downloadRoot }

        $supportsDestination=Test-SteamCmdDownloadDestination $primaryExe $UserName 120
        $runtime=Get-DepotSteamCmdRuntime $primaryExe $Settings $supportsDestination
        if ($runtime.Exe -ne $primaryExe) { Connect-SteamCmd $runtime.Exe $UserName }
        $cacheParent=Assert-DepotPath (Join-Path $downloadRoot '.depot-cache') -Create
        $cacheLock=[IO.File]::Open((Join-Path $cacheParent 'steam-cleaner.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $cache=Get-DepotCacheRoot $Settings $AppId
        $output=Get-DepotOutputPath $Settings $plan.InstallDir
        Write-Host "Game: $($plan.Name)`nAppID: $AppId`nDownload Location: $downloadRoot`nTemporary Cache: $cache`nFinal Output: $output"
        $metadataPath=Invoke-DepotDownloads $plan $Settings $runtime.Exe $UserName $logPath $runtime.DirectDestination

        $appInfos.Clear()
        $currentEntitlementSets=@{}
        $fetchCurrentEntitlements={ param($id)
            if (-not $currentEntitlementSets.ContainsKey($id)) { $currentEntitlementSets[$id]=Get-SteamAccountEntitlements -Exe $runtime.Exe -UserName $UserName -AppId $id -TimeoutSeconds $Settings.TimeoutSeconds }
            return $currentEntitlementSets[$id]
        }
        $currentEntitlements=& $fetchCurrentEntitlements $AppId
        $fetchCurrent={ param($id)
            if (-not $appInfos.ContainsKey($id)) {
                $response=Invoke-SteamCmd -Exe $runtime.Exe -UserName $UserName -Operation AppInfo -AppId $id -TimeoutSeconds $Settings.TimeoutSeconds
                $appInfos[$id]=Get-SteamAppInfoFromOutput $response.Stdout $id
            }
            return ,$appInfos[$id]
        }
        $currentPlan=Resolve-SteamDepots $AppId (& $fetchCurrent $AppId) $Settings $fetchCurrent $currentEntitlements $fetchCurrentEntitlements
        if (-not $currentPlan.CanDownload -or (Get-DepotPlanKey $currentPlan) -cne (Get-DepotPlanKey $plan)) { throw 'Branch, build, manifest, or entitlement changed during download. The cache was retained for review.' }
        $assembled=Invoke-DepotAssembly $metadataPath $downloadRoot $Settings.CollisionPolicy $logPath
        if (-not $assembled.Verified) { throw 'Assembly verification did not complete.' }
        if (-not $Settings.KeepTemporaryDepots) {
            Remove-DepotTree (Get-DepotCacheRoot $Settings $AppId) $cacheParent
            $cleaned=$true
            Write-DepotLog "Verified cache for AppID $AppId was removed automatically." -LogPath $logPath
        }
        Write-Host "Files Ready / Assembly Complete`nFinal Output: $($assembled.OutputPath)`nSteam installation state and prerequisites were not changed."
        return $assembled
    } catch { Write-DepotLog $_.Exception.Message -Level ERROR -LogPath $logPath; throw }
    finally {
        if ($cacheLock) { $cacheLock.Dispose() }
        if ($cacheParent -and (Test-Path -LiteralPath $cacheParent)) {
            $lockPath=Join-Path $cacheParent 'steam-cleaner.lock'
            if (Test-Path -LiteralPath $lockPath) { Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue }
            if (-not @(Get-ChildItem -LiteralPath $cacheParent -Force -ErrorAction SilentlyContinue).Count) { [IO.Directory]::Delete($cacheParent,$false) }
        }
    }
}
