$ErrorActionPreference='Stop'
. "$PSScriptRoot/../steam-cleaner.ps1" -LoadOnly
$script:passed=0
function Check($Condition,$Message) { if (-not $Condition) { throw "FAILED: $Message" }; $script:passed++; Write-Host "PASS: $Message" }
function Reject([scriptblock]$Action,$Message) { $failed=$false; try { & $Action | Out-Null } catch { $failed=$true }; Check $failed $Message }
$fixture=Join-Path $env:TEMP ('steam-process-test-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $fixture
$fixture=(Get-Item -LiteralPath $fixture).FullName
try {
    $fakeExe=Join-Path $fixture 'steamcmd.exe'
    $sourcePath=(Join-Path $PSScriptRoot 'fixtures/ProcessFixture.cs').Replace("'","''")
    $binaryPath=$fakeExe.Replace("'","''")
    # Compile our network-free fixture for .NET Framework so both PS 5.1 and PS 7 can run it.
    $compile="Add-Type -TypeDefinition ([IO.File]::ReadAllText('$sourcePath')) -OutputAssembly '$binaryPath' -OutputType ConsoleApplication -ErrorAction Stop"
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($compile))
    & powershell.exe -NoProfile -EncodedCommand $encoded
    if ($LASTEXITCODE -ne 0) { throw 'Could not compile the process fixture.' }
    Reject { Assert-ValveSteamCmd $fakeExe } 'Unsigned SteamCMD executable rejected'
    function Assert-ValveSteamCmd { param($Path) return $Path }
    $previousDirectory=(Get-Location).Path
    Connect-SteamCmd -Exe $fakeExe -UserName directory
    Check (([IO.File]::ReadAllText((Join-Path $fixture 'cwd.txt'))) -eq $fixture -and (Get-Location).Path -eq $previousDirectory) 'Native login uses tool directory and restores caller location'
    $reply=Invoke-SteamCmd -Exe $fakeExe -UserName anonymous -Operation AppInfo -AppId 100 -TimeoutSeconds 10
    Check ($reply.ExitCode -eq 0 -and $reply.Stdout.Length -eq 100000 -and $reply.Stderr.Length -eq 100000) 'Both process streams drained without deadlock'
    Reject { Invoke-SteamCmd -Exe $fakeExe -UserName license -Operation AppInfo -AppId 100 } 'Process license failure detected despite exit zero'
    Reject { Invoke-SteamCmd -Exe $fakeExe -UserName guard -Operation AppInfo -AppId 100 } 'Noninteractive process Guard requirement fails safely'
    Reject { Invoke-SteamCmd -Exe $fakeExe -UserName failure -Operation AppInfo -AppId 100 } 'Process nonzero exit detected'
    Reject { Invoke-SteamCmd -Exe $fakeExe -UserName timeout -Operation AppInfo -AppId 100 -TimeoutSeconds 1 } 'Timed-out child process terminated'
    Reject { Invoke-SteamCmd -Exe $fakeExe -UserName 'name +quit' -Operation AppInfo -AppId 100 } 'Username cannot inject SteamCMD commands'
    Write-Host "All $script:passed SteamCMD process checks passed."
} finally {
    if (-not $fixture.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $fixture -Leaf) -notlike 'steam-process-test-*') { throw 'Unsafe fixture cleanup.' }
    foreach ($node in @(Get-CleanupNode $fixture ([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')))) {
        if ($node.Directory) { [IO.Directory]::Delete($node.Path,$false) } else { Remove-Item -LiteralPath $node.Path -Force }
    }
}
