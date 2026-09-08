$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../steam-cleaner.ps1" -LoadOnly
$script:passed = 0
function Check($Condition, $Message) {
    if (-not $Condition) { throw "FAILED: $Message" }
    $script:passed++
    Write-Host "PASS: $Message"
}
function Reject([scriptblock]$Action, $Message) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    Check $failed $Message
}
$fixture = Join-Path $env:TEMP ('steam-cleaner-test-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $fixture | Out-Null
# Only this uniquely created synthetic directory may be deleted by tests.
$fixture = (Get-Item -LiteralPath $fixture).FullName
try {
    New-Item -ItemType Directory -Path "$fixture/steamapps", "$fixture/userdata", "$fixture/cache/nested" -Force | Out-Null
    Set-Content -LiteralPath "$fixture/steam.exe" -Value 'fake executable'
    Set-Content -LiteralPath "$fixture/steamapps/game.dat" -Value 'keep game'
    Set-Content -LiteralPath "$fixture/userdata/save.dat" -Value 'keep save'
    Set-Content -LiteralPath "$fixture/cache/nested/file[1].txt" -Value 'delete'
    Set-Content -LiteralPath "$fixture/extra.txt" -Value 'delete'
    Check (Test-ValveCertificateSubject 'CN=Valve, OU=Digital ID, O=Valve, C=US') 'Current Valve certificate identity accepted'
    Check (Test-ValveCertificateSubject 'CN=Valve Corp., O=Valve Corporation, C=US') 'Legacy Valve certificate identity accepted'
    Check (-not (Test-ValveCertificateSubject 'CN=Valve Support, O=Example Corp, C=US')) 'Unrelated publisher rejected'
    Reject { Assert-SteamRoot $fixture } 'Unsigned executable rejected'
    Reject { Assert-LocalDirectory ([IO.Path]::GetPathRoot($fixture)) } 'Drive root rejected'
    Reject { Assert-LocalDirectory '.' } 'Relative path rejected'
    Reject { Assert-LocalDirectory '\\server\share' } 'UNC path rejected'
    # Replace external dependencies only; exercise actual validation and deletion logic.
    function Get-AuthenticodeSignature { [pscustomobject]@{ Status='Valid'; SignerCertificate=[pscustomobject]@{ Subject='CN=Valve Corp., O=Valve Corp., C=US' } } }
    function Get-Process { [pscustomobject]@{ ProcessName='steam' } }
    Reject { Invoke-SteamCleanup -SteamPath $fixture -PreviewOnly } 'Running Steam rejected'
    function Get-Process { @() }
    function Read-Host { throw 'Preview must not prompt' }
    Invoke-SteamCleanup -SteamPath $fixture -PreviewOnly
    Check (Test-Path -LiteralPath "$fixture/extra.txt") 'Preview retains deletion targets'
    function Read-Host { 'cancel' }
    Invoke-SteamCleanup -SteamPath $fixture
    Check (Test-Path -LiteralPath "$fixture/extra.txt") 'Cancellation retains deletion targets'
    New-Item -ItemType Junction -Path "$fixture/link" -Target "$fixture/steamapps" | Out-Null
    Reject { Get-CleanupPlan $fixture } 'Junction rejected without traversal'
    [IO.Directory]::Delete("$fixture/link")
    function Read-Host { Set-Content -LiteralPath "$fixture/new.txt" -Value 'new'; 'DELETE' }
    Reject { Invoke-SteamCleanup -SteamPath $fixture } 'Changed plan rejected'
    Check (Test-Path -LiteralPath "$fixture/extra.txt") 'Changed plan performs no deletions'
    function Read-Host { 'DELETE' }
    Invoke-SteamCleanup -SteamPath $fixture
    Check (((Get-ChildItem -LiteralPath $fixture).Name | Sort-Object) -join ',' -eq 'steam.exe,steamapps,userdata') 'Only keep entries remain'
    Check ((Get-Content -LiteralPath "$fixture/steamapps/game.dat") -eq 'keep game') 'Game data preserved'
    Check ((Get-Content -LiteralPath "$fixture/userdata/save.dat") -eq 'keep save') 'User data preserved'
    Write-Host "All $script:passed safety checks passed."
} finally {
    $resolvedFixture = [IO.Path]::GetFullPath($fixture)
    $tempPrefix = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if (-not $resolvedFixture.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolvedFixture -Leaf) -notlike 'steam-cleaner-test-*') { throw 'Unsafe test cleanup path' }
    # Reuse the non-following walker after removing retained files individually.
    if (Test-Path -LiteralPath "$fixture/link") { [IO.Directory]::Delete("$fixture/link") }
    foreach ($child in (Get-ChildItem -LiteralPath $fixture -Force)) {
        foreach ($node in @(Get-CleanupNode $child.FullName $fixture)) {
            if ($node.Directory) { [IO.Directory]::Delete($node.Path, $false) }
            else { Remove-Item -LiteralPath $node.Path -Force }
        }
    }
    [IO.Directory]::Delete($fixture, $false)
}

