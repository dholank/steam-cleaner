#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$SteamPath,
    [switch]$PreviewOnly,
    [switch]$LoadOnly
)

function Write-CleanerHeader {
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host '  STEAM CLEANER' -ForegroundColor Cyan
    Write-Host '  Reset file inti Steam, pertahankan game dan data pengguna' -ForegroundColor Gray
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host ''
}

function Write-CleanerSection {
    param([Parameter(Mandatory)][string]$Title)
    Write-Host ''
    Write-Host ('-- {0} ' -f $Title) -NoNewline -ForegroundColor Cyan
    Write-Host ('-' * [Math]::Max(1, 54 - $Title.Length)) -ForegroundColor DarkCyan
}

function Format-ByteSize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    return ('{0} bytes' -f $Bytes)
}

function Test-ValveCertificateSubject {
    param([string]$Subject)
    return [bool]($Subject -match '(?:^|,\s*)O=Valve(?: Corp(?:\.|oration)?)?(?:,|$)')
}

function Assert-LocalDirectory {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -notmatch '^[A-Za-z]:[\\/]') { throw 'Gunakan path drive lokal yang absolut, contoh: C:\Program Files (x86)\Steam.' }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or $item.PSProvider.Name -ne 'FileSystem') { throw 'Path tersebut bukan folder lokal.' }
    $current = $item
    while ($null -ne $current) {
        if ($current.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Folder link tidak diizinkan: $($current.FullName)" }
        $current = $current.Parent
    }
    $resolved = $item.FullName.TrimEnd('\')
    if ($resolved -eq [IO.Path]::GetPathRoot($resolved).TrimEnd('\')) { throw 'Drive root tidak boleh dibersihkan.' }
    foreach ($protected in @($env:USERPROFILE, $env:windir, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, [Environment]::GetFolderPath('MyDocuments'), [Environment]::GetFolderPath('Desktop'))) {
        if ($protected -and $resolved -eq $protected.TrimEnd('\')) { throw 'Folder sistem atau folder pengguna tidak boleh dibersihkan.' }
    }
    return $resolved
}

function Assert-SteamRoot {
    param([Parameter(Mandatory)][string]$Path)
    $root = Assert-LocalDirectory $Path
    foreach ($name in @('steamapps', 'userdata', 'steam.exe')) {
        $item = Get-Item -LiteralPath (Join-Path $root $name) -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Item yang dipertahankan tidak boleh berupa link: $name" }
        if (($name -eq 'steam.exe') -eq $item.PSIsContainer) { throw "Tipe item Steam tidak sesuai: $name" }
    }
    $exe = Join-Path $root 'steam.exe'
    $signature = Get-AuthenticodeSignature -LiteralPath $exe -ErrorAction Stop
    if ($signature.Status -ne 'Valid' -or -not (Test-ValveCertificateSubject $signature.SignerCertificate.Subject)) {
        throw 'steam.exe harus memiliki tanda tangan digital Valve yang valid.'
    }
    return $root
}

function Find-SteamRoot {
    $candidates = @()
    foreach ($key in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam')) {
        $entry = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if ($entry) {
            $candidates += $entry.SteamPath
            $candidates += $entry.InstallPath
        }
    }
    if (${env:ProgramFiles(x86)}) { $candidates += Join-Path ${env:ProgramFiles(x86)} 'Steam' }
    if ($env:ProgramFiles) { $candidates += Join-Path $env:ProgramFiles 'Steam' }
    $valid = @(foreach ($candidate in ($candidates | Where-Object { $_ } | Select-Object -Unique)) {
        try { Assert-SteamRoot $candidate } catch { Write-Verbose $_ }
    }) | Select-Object -Unique
    if (@($valid).Count -ne 1) { throw 'Instalasi Steam tidak ditemukan secara unik. Jalankan file lokal dengan parameter -SteamPath.' }
    return $valid
}

function Assert-SteamStopped {
    $active = @(Get-Process -ErrorAction Stop | Where-Object { $_.ProcessName -match '^(steam.*|gameoverlayui|steamerrorreporter.*)$' })
    if ($active.Count) { throw "Tutup Steam dan proses latar belakangnya terlebih dahulu: $($active.ProcessName -join ', ')" }
}

function Get-CleanupPlan {
    param([Parameter(Mandatory)][string]$Root)
    foreach ($item in (Get-ChildItem -LiteralPath $Root -Force -ErrorAction Stop)) {
        if ($item.Name -in @('steamapps', 'userdata', 'steam.exe')) { continue }
        Get-CleanupNode -Path $item.FullName -Root $Root
    }
}

function Get-CleanupNode {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.FullName.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Target berada di luar folder Steam.' }
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Link terdeteksi dan proses dihentikan: $Path" }
    if ($item.PSIsContainer) {
        foreach ($child in (Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)) {
            Get-CleanupNode -Path $child.FullName -Root $Root
        }
    }
    [pscustomobject]@{
        Path      = $item.FullName
        Directory = $item.PSIsContainer
        Length    = $(if ($item.PSIsContainer) { 0 } else { $item.Length })
        Modified  = $item.LastWriteTimeUtc.Ticks
    }
}

function Show-CleanupPlan {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][object[]]$Plan)
    $files = @($Plan | Where-Object { -not $_.Directory })
    $directories = @($Plan | Where-Object { $_.Directory })
    $bytes = [long](($files | Measure-Object -Property Length -Sum).Sum)

    Write-CleanerSection 'RINGKASAN'
    Write-Host '  Lokasi Steam : ' -NoNewline -ForegroundColor Gray
    Write-Host $Root -ForegroundColor White
    Write-Host '  Dipertahankan: ' -NoNewline -ForegroundColor Gray
    Write-Host 'steamapps, userdata, steam.exe' -ForegroundColor Green
    Write-Host '  Akan dihapus : ' -NoNewline -ForegroundColor Gray
    Write-Host ("{0} file, {1} folder ({2})" -f $files.Count, $directories.Count, (Format-ByteSize $bytes)) -ForegroundColor Yellow

    Write-CleanerSection 'PREVIEW PENGHAPUSAN'
    foreach ($target in $Plan) {
        $relative = $target.Path.Substring($Root.Length).TrimStart('\')
        $depth = @($relative -split '[\\/]').Count - 1
        $indent = '  ' + ('  ' * $depth)
        $kind = if ($target.Directory) { '[DIR] ' } else { '[FILE]' }
        $color = if ($target.Directory) { 'DarkYellow' } else { 'DarkGray' }
        Write-Host ("{0}{1} {2}" -f $indent, $kind, $relative) -ForegroundColor $color
    }

    [pscustomobject]@{ FileCount = $files.Count; DirectoryCount = $directories.Count; Bytes = $bytes }
}

function Invoke-SteamCleanup {
    [CmdletBinding()]
    param([string]$SteamPath, [switch]$PreviewOnly)
    $ErrorActionPreference = 'Stop'
    if ($env:OS -ne 'Windows_NT') { throw 'Steam Cleaner hanya dapat dijalankan di Windows.' }

    Write-CleanerHeader
    Write-Host '[1/4] Mencari dan memvalidasi instalasi Steam...' -ForegroundColor Gray
    if (-not $SteamPath) { $SteamPath = Find-SteamRoot }
    $root = Assert-SteamRoot $SteamPath
    Write-Host '[2/4] Memastikan Steam sudah ditutup...' -ForegroundColor Gray
    Assert-SteamStopped
    Write-Host '[3/4] Membuat rencana penghapusan...' -ForegroundColor Gray
    $plan = @(Get-CleanupPlan $root)

    if (-not $plan.Count) {
        Write-CleanerSection 'SUDAH BERSIH'
        Write-Host '  Tidak ada file atau folder yang perlu dihapus.' -ForegroundColor Green
        Write-Host '  steamapps, userdata, dan steam.exe tetap aman.' -ForegroundColor Gray
        Write-Host ''
        return
    }

    $summary = Show-CleanupPlan -Root $root -Plan $plan
    Write-CleanerSection 'PERHATIAN'
    Write-Host '  Penghapusan bersifat permanen dan tidak masuk Recycle Bin.' -ForegroundColor Yellow
    Write-Host '  Backup file custom di luar steamapps dan userdata jika masih diperlukan.' -ForegroundColor Yellow

    if ($PreviewOnly) {
        Write-Host ''
        Write-Host '[PREVIEW] Belum ada file yang dihapus.' -ForegroundColor Cyan
        Write-Host ''
        return
    }

    Write-Host ''
    if ((Read-Host 'Ketik DELETE untuk lanjut (Enter = batal)') -cne 'DELETE') {
        Write-Host ''
        Write-Host '[BATAL] Tidak ada file yang dihapus.' -ForegroundColor Yellow
        Write-Host ''
        return
    }

    Write-Host ''
    Write-Host '[4/4] Menghapus target yang sudah diverifikasi...' -ForegroundColor Gray
    $null = Assert-SteamRoot $root
    Assert-SteamStopped
    $fresh = @(Get-CleanupPlan $root)
    if (($plan | ConvertTo-Json -Compress) -cne ($fresh | ConvertTo-Json -Compress)) { throw 'Isi folder berubah setelah preview. Jalankan Steam Cleaner lagi.' }

    foreach ($target in $plan) {
        Assert-SteamStopped
        $parent = Split-Path -Parent $target.Path
        $null = Assert-LocalDirectory $parent
        if (-not $target.Path.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Target berada di luar folder Steam.' }
        $item = Get-Item -LiteralPath $target.Path -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Target berubah menjadi link. Proses dihentikan.' }
        if ($item.PSIsContainer -ne $target.Directory) { throw 'Tipe target berubah. Proses dihentikan.' }
        if ($target.Directory) {
            [IO.Directory]::Delete($target.Path, $false)
        } else {
            Remove-Item -LiteralPath $target.Path -Force -ErrorAction Stop
        }
    }

    $remaining = @(Get-ChildItem -LiteralPath $root -Force | Where-Object { $_.Name -notin @('steamapps', 'userdata', 'steam.exe') })
    if ($remaining.Count) { throw 'File baru muncul selama proses. Periksa folder Steam.' }

    Write-CleanerSection 'SELESAI'
    Write-Host '  [OK] Steam berhasil dibersihkan.' -ForegroundColor Green
    Write-Host ("  Dihapus      : {0} file, {1} folder ({2})" -f $summary.FileCount, $summary.DirectoryCount, (Format-ByteSize $summary.Bytes)) -ForegroundColor Gray
    Write-Host '  Dipertahankan: steamapps, userdata, steam.exe' -ForegroundColor Green
    Write-Host '  Steam akan membuat ulang file client yang diperlukan saat dibuka.' -ForegroundColor Gray
    Write-Host ''
}

if (-not $LoadOnly) {
    try {
        Invoke-SteamCleanup -SteamPath $SteamPath -PreviewOnly:$PreviewOnly
    } catch {
        Write-Host ''
        Write-Host '[ERROR] Steam Cleaner dihentikan.' -ForegroundColor Red
        Write-Error "$($_.Exception.Message) Penghapusan yang sudah selesai sebelum error tidak dapat dibatalkan."
    }
}

