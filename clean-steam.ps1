#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$SteamPath,
    [switch]$PreviewOnly,
    [switch]$LoadOnly
)

# Compatibility entry point for the original clean-steam.ps1 URL.
if ($PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'steam-cleaner.ps1'))) {
    & (Join-Path $PSScriptRoot 'steam-cleaner.ps1') @PSBoundParameters
    return
}

if ($PSBoundParameters.Count) {
    throw 'Untuk memakai parameter, download repository lalu jalankan steam-cleaner.ps1 secara lokal.'
}

$ErrorActionPreference = 'Stop'
try {
    $revision = (Invoke-RestMethod 'https://api.github.com/repos/dholank/steam-cleaner/commits/main').sha
    if ($revision -notmatch '^[a-f0-9]{40}$') { throw 'Versi repository tidak dapat diverifikasi.' }
    $scriptText = Invoke-RestMethod "https://raw.githubusercontent.com/dholank/steam-cleaner/$revision/steam-cleaner.ps1"
} catch {
    Write-Error "Steam Cleaner gagal dimuat: $_"
    return
}
& ([scriptblock]::Create([string]$scriptText))

