function Write-DepotJson {
    param([string]$Path, $Value)
    $parent=Assert-LocalDirectory (Split-Path -Parent $Path)
    $target=[IO.Path]::GetFullPath($Path)
    if ((Split-Path -Parent $target) -ne $parent) { throw 'Invalid metadata target.' }
    if (Test-Path -LiteralPath $target) {
        $item=Get-Item -LiteralPath $target -Force
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe metadata file.' }
    }
    $temp=Join-Path $parent ([guid]::NewGuid().ToString() + '.tmp')
    try {
        [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $target) {
            $backup=Join-Path $parent ([guid]::NewGuid().ToString()+'.tmp')
            [IO.File]::Replace($temp,$target,$backup)
            Remove-Item -LiteralPath $backup -Force -ErrorAction Stop
        }
        else { [IO.File]::Move($temp,$target) }
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction Stop } }
}

function Set-DepotMetadataValue {
    param([Parameter(Mandatory=$true)]$Metadata, [Parameter(Mandatory=$true)][string]$Name, $Value)
    $Metadata | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Get-DepotPlanKey {
    param($Plan)
    $identity=[ordered]@{ AppId=$Plan.AppId; Platform=$Plan.Platform; Architecture=$Plan.Architecture; Language=$Plan.Language; Branch=$Plan.Branch; BuildId=$Plan.BuildId; InstallDir=$Plan.InstallDir; Depots=@($Plan.Depots | ForEach-Object { "$($_.DepotId):$($_.ManifestId):$($_.SourceAppId):$($_.SourceBuildId):$($_.MountOrder)" }) }
    $hash=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes(($identity | ConvertTo-Json -Compress -Depth 8))))).Replace('-','').ToLowerInvariant() }
    finally { $hash.Dispose() }
}

function Get-DepotInventory {
    param([string]$Root)
    foreach ($entry in @(Get-DepotFiles $Root)) {
        if (-not $entry.Directory) {
            [pscustomobject]@{ Path=$entry.RelativePath; Length=$entry.Length; Sha256=(Get-FileHash -LiteralPath $entry.Path -Algorithm SHA256 -ErrorAction Stop).Hash }
        }
    }
}

function Test-DepotInventory {
    param([string]$Root, [object[]]$Inventory)
    $actual=@(Get-DepotInventory $Root)
    if ($actual.Count -ne @($Inventory).Count) { throw 'Depot file count changed. Cache verification failed; download again into a new cache location.' }
    $expected=@{}
    foreach ($entry in $Inventory) {
        if ($entry.Path -match '(^[\\/]|^[A-Za-z]:|(?:^|[\\/])\.\.(?:[\\/]|$)|:)' -or $expected.ContainsKey($entry.Path)) { throw 'Invalid or duplicate inventory path.' }
        $expected[$entry.Path]=$entry
    }
    foreach ($entry in $actual) {
        $before=$expected[$entry.Path]
        if (-not $before -or $before.Length -ne $entry.Length -or $before.Sha256 -cne $entry.Sha256) { throw "Cache integrity mismatch: $($entry.Path). Restore or redownload this cache." }
    }
    return $true
}

function Write-DepotReceipt {
    param([Parameter(Mandatory=$true)][string]$CacheDirectory, [Parameter(Mandatory=$true)]$Receipt)
    $null=Assert-SteamId ([string]$Receipt.DepotId)
    Write-DepotJson (Join-Path $CacheDirectory ("receipt_$($Receipt.DepotId).json")) $Receipt
}

function Move-StaleDepotSnapshot {
    param([Parameter(Mandatory=$true)][string]$CacheDirectory, [Parameter(Mandatory=$true)][string]$DepotId, [string]$OldManifestId='unknown')
    $null=Assert-SteamId $DepotId
    $depot=Join-Path $CacheDirectory "depot_$DepotId"
    $receipt=Join-Path $CacheDirectory "receipt_$DepotId.json"
    if (-not (Test-Path -LiteralPath $depot) -and -not (Test-Path -LiteralPath $receipt)) { return $null }
    $stale=Assert-DepotPath (Join-Path $CacheDirectory 'stale') -Create
    $safeManifest=if ($OldManifestId -match '^[0-9]+$') {$OldManifestId} else {'unknown'}
    $target=Assert-DepotPath (Join-Path $stale ("depot_${DepotId}-${safeManifest}-" + [DateTime]::UtcNow.ToString('yyyyMMddHHmmss') + '-' + [guid]::NewGuid().ToString('N'))) -Create
    if (Test-Path -LiteralPath $depot) { [IO.Directory]::Move($depot,(Join-Path $target "depot_$DepotId")) }
    if (Test-Path -LiteralPath $receipt) { [IO.File]::Move($receipt,(Join-Path $target "receipt_$DepotId.json")) }
    return $target
}

function Read-DepotMetadata {
    param([string]$Path)
    $null=Assert-LocalDirectory (Split-Path -Parent $Path)
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe metadata path.' }
    $metadata=Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($metadata.SchemaVersion -notin @(1,2) -or $metadata.Status -notin @('Downloaded','Assembling','Complete','Failed')) { throw 'Metadata is not a completed supported download snapshot.' }
    $null=Assert-SteamId $metadata.Plan.AppId
    $null=ConvertTo-InstallDirectoryName $metadata.Plan.InstallDir
    if (-not @($metadata.Plan.Depots).Count -or (Get-DepotPlanKey $metadata.Plan) -cne $metadata.PlanKey) { throw 'Metadata plan is missing or inconsistent.' }
    $ids=@{}
    foreach ($depot in $metadata.Plan.Depots) {
        $null=Assert-SteamId $depot.DepotId; $null=Assert-SteamId $depot.ManifestId -Manifest
        if ($ids.ContainsKey($depot.DepotId)) { throw 'Duplicate depot in metadata.' }
        $ids[$depot.DepotId]=$true
        $receipt=@($metadata.Receipts | Where-Object { $_.DepotId -eq $depot.DepotId -and $_.ManifestId -ceq $depot.ManifestId })
        if ($receipt.Count -ne 1 -or $receipt[0].Status -ne 'Complete') { throw 'Missing completed depot receipt.' }
    }
    return $metadata
}
