function Get-DownloadCompletion {
    param([string]$Text, [string]$DepotId, [string]$ManifestId, [string]$ExpectedPath)
    $completion=[regex]::Match($Text,'(?im)^\s*Depot download complete\s*:\s*"(?<path>[^"\r\n]+)"\s*\((?<details>[^\r\n]*)\)')
    if (-not $completion.Success -or $completion.Groups['details'].Value -notmatch ('\bmanifest\s+' + [regex]::Escape($ManifestId) + '\b')) { throw "Depot $DepotId did not report completion for the selected manifest. Retry; it is not safe to assemble." }
    $reported=[IO.Path]::GetFullPath($completion.Groups['path'].Value).TrimEnd('\')
    if ($reported -ne $ExpectedPath.TrimEnd('\')) { throw 'SteamCMD reported an unexpected download directory. Automatic cache import refused.' }
    $countMatch=[regex]::Match($completion.Groups['details'].Value,'\b(?<count>[0-9]+)\s+files?\b')
    return [pscustomobject]@{ FileCount=$(if ($countMatch.Success) {[long]$countMatch.Groups['count'].Value} else {$null}) }
}

function Invoke-DepotDownloads {
    param($Plan, $Settings, [string]$Exe, [string]$UserName, [string]$LogPath)
    if (-not $Plan.CanDownload) { throw 'Depot resolution requires review; no download was started.' }
    $cacheRoot=Assert-DepotPath $Settings.CacheRoot -Create
    $snapshot=Assert-DepotPath (Join-Path (Join-Path $cacheRoot $Plan.AppId) (Get-DepotPlanKey $Plan)) -Create
    $metadataPath=Join-Path $snapshot 'metadata.json'
    $receipts=[Collections.Generic.List[object]]::new()
    $index=0
    foreach ($depot in $Plan.Depots) {
        $index++
        $target=Join-Path $snapshot "depot_$($depot.DepotId)"
        $receiptPath=Join-Path $snapshot "depot_$($depot.DepotId).receipt.json"
        if ((Test-Path -LiteralPath $target) -and (Test-Path -LiteralPath $receiptPath)) {
            $receiptItem=Get-Item -LiteralPath $receiptPath -Force -ErrorAction Stop
            if ($receiptItem.PSIsContainer -or ($receiptItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe receipt file.' }
            $receipt=Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($receipt.Status -ne 'Complete' -or $receipt.DepotId -ne $depot.DepotId -or $receipt.ManifestId -cne $depot.ManifestId) { throw 'Cached receipt does not match the resolved manifest. Use a new cache root.' }
            $null=Test-DepotInventory $target @($receipt.Inventory)
            $receipts.Add($receipt)
            Write-DepotLog "Verified cached depot $($depot.DepotId)." -LogPath $LogPath
            continue
        }
        if (Test-Path -LiteralPath $target) { throw "Unverified cache folder exists: $target. Keep it for diagnosis and select another CacheRoot." }
        $sourceParent=Assert-DepotPath (Join-Path (Split-Path -Parent $Exe) "steamapps\content\app_$($Plan.AppId)") -Create
        $source=Join-Path $sourceParent "depot_$($depot.DepotId)"
        # Preserve earlier/native interrupted downloads; never mix stale files into a new manifest.
        if (Test-Path -LiteralPath $source) {
            $null=Assert-LocalDirectory $source
            $saved=$source + '.previous-' + [guid]::NewGuid().ToString('N')
            [IO.Directory]::Move($source,$saved)
            Write-DepotLog "Preserved existing SteamCMD depot at $saved." -LogPath $LogPath
        }
        Write-DepotLog "Downloading [$index/$(@($Plan.Depots).Count)] depot $($depot.DepotId), manifest $($depot.ManifestId)." -LogPath $LogPath
        $result=Invoke-SteamCmd -Exe $Exe -UserName $UserName -Operation Download -AppId $Plan.AppId -DepotId $depot.DepotId -ManifestId $depot.ManifestId -TimeoutSeconds $Settings.TimeoutSeconds
        $completion=Get-DownloadCompletion $result.Stdout $depot.DepotId $depot.ManifestId $source
        $null=Assert-LocalDirectory $source
        $inventory=@(Get-DepotInventory $source)
        if ($null -ne $completion.FileCount -and $inventory.Count -ne $completion.FileCount) { throw 'Downloaded file count does not match SteamCMD completion. Cache import refused.' }
        if ($null -ne $depot.ExpectedBytes -and [string]$depot.ExpectedBytes -ne '') {
            $actualBytes=($inventory | Measure-Object -Property Length -Sum).Sum
            if ([decimal]$actualBytes -ne [decimal]$depot.ExpectedBytes) { throw 'Downloaded size does not match AppInfo manifest size. Cache import refused.' }
        }
        if (-not $inventory.Count -and [string]$depot.ExpectedBytes -ne '0') { throw 'Downloaded depot is empty without an explicit zero-size manifest.' }
        $incoming=$target + '.incoming-' + [guid]::NewGuid().ToString('N')
        Copy-DepotContents $source $incoming
        $null=Test-DepotInventory $incoming $inventory
        [IO.Directory]::Move($incoming,$target)
        $receipt=[pscustomobject]@{ DepotId=$depot.DepotId; ManifestId=$depot.ManifestId; Status='Complete'; CompletedAt=[DateTime]::UtcNow.ToString('o'); Inventory=$inventory }
        Write-DepotJson $receiptPath $receipt
        $receipts.Add($receipt)
        Write-DepotLog "Depot $($depot.DepotId) completed and cached; $($inventory.Count) files." -LogPath $LogPath
    }
    # Metadata declaring success exists only after EVERY selected depot has a valid receipt.
    $metadata=[pscustomobject]@{ SchemaVersion=1; Status='Downloaded'; PlanKey=(Get-DepotPlanKey $Plan); Plan=$Plan; Receipts=@($receipts.ToArray()); DownloadedAt=[DateTime]::UtcNow.ToString('o'); Verification='SteamCMD completion plus local SHA256 inventory; not an independent Steam manifest signature check' }
    Write-DepotJson $metadataPath $metadata
    return $metadataPath
}

function Invoke-SteamDepotDownload {
    param([string]$AppId, $Settings, [string]$UserName)
    $ErrorActionPreference='Stop'
    $null=Assert-SteamId $AppId
    $exe=Get-SteamCmdPath $Settings
    $toolsRoot=Split-Path -Parent $exe
    if (Get-Process -Name steamcmd -ErrorAction SilentlyContinue) { throw 'Close other SteamCMD processes before starting this download.' }
    $installedSteam=$null
    try { $installedSteam=Find-SteamRoot } catch { Write-Verbose 'No unique validated Steam client root; downloader does not require an installed client.' }
    if ($installedSteam) {
        foreach ($candidate in @($toolsRoot,$Settings.CacheRoot,$Settings.OutputRoot)) {
            Assert-SeparateDepotPaths $installedSteam $candidate
        }
    }
    $cache=Assert-DepotPath $Settings.CacheRoot -Create
    $output=Assert-DepotPath $Settings.OutputRoot -Create
    Assert-SeparateDepotPaths $cache $toolsRoot; Assert-SeparateDepotPaths $cache $output; Assert-SeparateDepotPaths $toolsRoot $output
    $logPath=Join-Path $cache ('download-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N') + '.log')
    # FileShare.None serializes tool/cache use across processes. Native SteamCMD should not run concurrently.
    $lock=$null; $cacheLock=$null
    try {
        $lock=[IO.File]::Open((Join-Path $toolsRoot 'steam-cleaner.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $cacheLock=[IO.File]::Open((Join-Path $cache 'steam-cleaner.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        Connect-SteamCmd $exe $UserName
        Write-DepotLog "Resolving AppID $AppId." -LogPath $logPath
        $appInfos=@{}
        $fetch={ param($id)
            if (-not $appInfos.ContainsKey($id)) {
                $response=Invoke-SteamCmd -Exe $exe -UserName $UserName -Operation AppInfo -AppId $id -TimeoutSeconds $Settings.TimeoutSeconds
                $appInfos[$id]=Get-SteamAppInfoFromOutput $response.Stdout $id
            }
            return ,$appInfos[$id]
        }
        $plan=Resolve-SteamDepots $AppId (& $fetch $AppId) $Settings $fetch
        Write-Host "Game: $($plan.Name)`nInstallDir: $($plan.InstallDir)`nConfiguration: $($plan.Platform) / $($plan.Architecture) / $($plan.Language) / $($plan.Branch)`nBuild: $($plan.BuildId)"
        foreach ($decision in $plan.Decisions) { Write-DepotLog "$($decision.DepotId) $($decision.Action) $($decision.Confidence): $($decision.Reason)" -LogPath $logPath }
        if (-not $plan.CanDownload) { throw 'Automatic resolution stopped: review ambiguous depots/configuration above. No partial selection will be downloaded.' }
        Write-DepotLog $plan.OrderSource -Level WARN -LogPath $logPath
        if (Test-Path -LiteralPath (Join-Path $output $plan.InstallDir)) { throw 'Output already exists. Choose a different OutputRoot in settings, or cancel.' }
        $metadataPath=Invoke-DepotDownloads $plan $Settings $exe $UserName $logPath
        # Detect branch drift, including shared-source metadata, before assembling a snapshot.
        $appInfos.Clear()
        $currentPlan=Resolve-SteamDepots $AppId (& $fetch $AppId) $Settings $fetch
        if (-not $currentPlan.CanDownload -or (Get-DepotPlanKey $currentPlan) -cne (Get-DepotPlanKey $plan)) { throw 'Branch/build changed during download. Cache retains the pinned snapshot; rerun resolution or explicitly reassemble it from metadata.' }
        $assembled=Invoke-DepotAssembly $metadataPath $output $Settings.CollisionPolicy $logPath
        Write-Host "Output: $($assembled.OutputPath)`nMetadata: $metadataPath"
        if ((Read-Host 'Keep raw depot cache? [Y/n] (Enter = keep)') -ieq 'n') {
            if ((Read-Host 'Type DELETE to delete ONLY this verified raw cache snapshot') -ceq 'DELETE') {
                if (-not $assembled.Verified) { throw 'Raw cache deletion requires verified assembly.' }
                # Retain metadata/receipts for audit; delete only selected raw depot folders.
                foreach ($depot in $plan.Depots) { Remove-DepotTree (Join-Path (Split-Path -Parent $metadataPath) "depot_$($depot.DepotId)") (Split-Path -Parent $metadataPath) }
                Write-DepotLog 'Selected raw cache deleted. SteamCMD spool/previous downloads are retained separately.' -LogPath $logPath
            }
        }
        return $assembled
    } catch { Write-DepotLog $_.Exception.Message -Level ERROR -LogPath $logPath; throw }
    finally { if ($cacheLock) {$cacheLock.Dispose()}; if ($lock) {$lock.Dispose()} }
}
