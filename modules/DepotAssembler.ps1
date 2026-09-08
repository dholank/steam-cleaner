function Copy-DepotContents {
    param([string]$Source, [string]$Destination)
    $sourcePath=Assert-LocalDirectory $Source
    $destinationPath=Assert-DepotPath $Destination -Create
    Assert-SeparateDepotPaths $sourcePath $destinationPath
    $null=@(Get-DepotFiles $sourcePath)
    $null=@(Get-DepotFiles $destinationPath)
    # /E merges; /MIR would delete content from depots already merged. Robocopy supports long paths.
    & "$env:SystemRoot\System32\robocopy.exe" $sourcePath $destinationPath /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /XJ /NP /NFL /NDL /NJH /NJS | Out-Null
    $copyExit=$LASTEXITCODE
    if ($copyExit -ge 8) { throw "File copy failed (robocopy $copyExit). Check disk space, locked files, path length support and permissions. Cache remains intact." }
}

function Get-DepotAssemblyPlan {
    param($Metadata, [string]$CacheDirectory, [ValidateSet('Stop','AppInfoOrder')][string]$CollisionPolicy='Stop', [string]$LogPath)
    $files=@{}; $directories=@{}; $collisions=[Collections.Generic.List[object]]::new()
    # Persisted order is the parsed AppInfo order, NEVER numeric DepotId order.
    foreach ($depot in $Metadata.Plan.Depots) {
        $root=Join-Path $CacheDirectory "depot_$($depot.DepotId)"
        $receipt=@($Metadata.Receipts | Where-Object DepotId -eq $depot.DepotId)[0]
        $null=Test-DepotInventory $root @($receipt.Inventory)
        $inventoryByPath=@{}
        foreach ($entry in $receipt.Inventory) { $inventoryByPath[$entry.Path]=$entry }
        foreach ($node in @(Get-DepotFiles $root)) {
            $path=$node.RelativePath
            if ($node.Directory) {
                if ($files.ContainsKey($path)) { throw "File/directory collision at $path; choose a different resolver configuration." }
                $directories[$path]=$true; continue
            }
            if ($directories.ContainsKey($path)) { throw "Directory/file collision at $path; automatic assembly refused." }
            $inventory=$inventoryByPath[$path]
            if ($files.ContainsKey($path)) {
                $existing=$files[$path]
                $different=$existing.Sha256 -cne $inventory.Sha256
                $collision=[pscustomobject]@{ Path=$path; ExistingDepot=$existing.DepotId; IncomingDepot=$depot.DepotId; Different=$different; Resolution=$(if ($different -and $CollisionPolicy -eq 'Stop') {'Blocked: mount priority is not guaranteed'} else {'Incoming depot wins using AppInfo enumeration order (unverified)'}) }
                $collisions.Add($collision)
                Write-DepotLog "Collision: $path; existing depot $($existing.DepotId), incoming depot $($depot.DepotId). $($collision.Resolution)" -Level WARN -LogPath $LogPath
            }
            $files[$path]=[pscustomobject]@{ Path=$path; DepotId=$depot.DepotId; Sha256=$inventory.Sha256; Length=$inventory.Length }
        }
    }
    if (@($collisions | Where-Object Different).Count -and $CollisionPolicy -eq 'Stop') { throw 'Conflicting depot files require review. Set CollisionPolicy=AppInfoOrder only after accepting the unverified publisher ordering.' }
    if (-not $files.Count) { throw 'Selected depots contain no game files; assembly refused.' }
    [pscustomobject]@{ Files=@($files.Values); Collisions=@($collisions.ToArray()) }
}

function Invoke-DepotAssembly {
    param([string]$MetadataPath, [string]$OutputRoot, [ValidateSet('Stop','AppInfoOrder')][string]$CollisionPolicy='Stop', [string]$LogPath)
    $ErrorActionPreference='Stop'
    $metadata=Read-DepotMetadata $MetadataPath
    $cache=Assert-LocalDirectory (Split-Path -Parent $MetadataPath)
    $output=Assert-DepotPath $OutputRoot -Create
    Assert-SeparateDepotPaths $cache $output
    $destination=Join-Path $output $metadata.Plan.InstallDir
    if (Test-Path -LiteralPath $destination) { throw "Output already exists: $destination. Choose another OutputRoot or cancel. Existing output is never replaced automatically." }
    $assembly=Get-DepotAssemblyPlan $metadata $cache $CollisionPolicy $LogPath
    $staging=Join-Path $output ($metadata.Plan.InstallDir + '.assembling-' + [guid]::NewGuid().ToString('N'))
    $null=Assert-DepotPath $staging -Create
    try {
        $index=0
        foreach ($depot in $metadata.Plan.Depots) {
            $index++
            Write-DepotLog "Assembling [$index/$(@($metadata.Plan.Depots).Count)] depot $($depot.DepotId)." -LogPath $LogPath
            Copy-DepotContents (Join-Path $cache "depot_$($depot.DepotId)") $staging
        }
        $null=Test-DepotInventory $staging $assembly.Files
        $null=Assert-LocalDirectory $output; $null=Assert-LocalDirectory $staging
        # Same-parent rename is the commit point; fails if another output appeared concurrently.
        [IO.Directory]::Move($staging,$destination)
        Write-DepotLog "Assembly verified: $destination" -LogPath $LogPath
        return [pscustomobject]@{ OutputPath=$destination; FileCount=$assembly.Files.Count; Verified=$true; Collisions=$assembly.Collisions }
    } catch { throw "Assembly stopped. Raw depots and prior output are retained. Partial staging: $staging. $($_.Exception.Message)" }
}
