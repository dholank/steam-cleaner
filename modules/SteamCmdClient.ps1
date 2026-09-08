function Assert-ValveSteamCmd {
    param([string]$Path)
    $null=Assert-LocalDirectory (Split-Path -Parent $Path)
    $exe=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($exe.Name -ne 'steamcmd.exe' -or $exe.PSIsContainer -or ($exe.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Expected a regular steamcmd.exe file.' }
    $signature=Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=Valve Corp(?:\.|oration)?(?:,|$)') { throw 'SteamCMD must have a valid Valve signature. Download it from Valve and check Windows certificate trust.' }
    return $exe.FullName
}

function Get-SteamCmdPath {
    param($Settings)
    if ($Settings.SteamCmdPath) { return Assert-ValveSteamCmd $Settings.SteamCmdPath }
    $managed=Join-Path $Settings.ToolsRoot 'steamcmd.exe'
    if (Test-Path -LiteralPath $managed) { return Assert-ValveSteamCmd $managed }
    $found=Get-Command steamcmd.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return Assert-ValveSteamCmd $found.Source }
    $root=Assert-DepotPath $Settings.ToolsRoot -Create
    Write-DepotLog 'Installing SteamCMD from Valve HTTPS CDN.'
    $zip=Join-Path $root ('bootstrap-' + [guid]::NewGuid() + '.zip')
    try {
        Invoke-WebRequest -Uri 'https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip' -OutFile $zip -UseBasicParsing -ErrorAction Stop
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive=[IO.Compression.ZipFile]::OpenRead($zip)
        try {
            $entry=$archive.GetEntry('steamcmd.exe')
            if (-not $entry) { throw 'Valve archive contains no steamcmd.exe.' }
            # Extract only the expected filename, never an archive-provided path.
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$managed,$false)
        } finally { $archive.Dispose() }
        return Assert-ValveSteamCmd $managed
    } catch { throw "SteamCMD bootstrap failed. Check connection, write permissions and disk space. $($_.Exception.Message)" }
    finally { if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force -ErrorAction Stop } }
}

function Connect-SteamCmd {
    param([string]$Exe, [string]$UserName)
    if ($UserName -notmatch '^[a-zA-Z0-9_]{1,64}$') { throw 'Enter a Steam account login name (letters, digits or underscore), or anonymous.' }
    if ($UserName -eq 'anonymous') { return }
    Write-Host 'SteamCMD will ask for your password/Steam Guard directly. This application does not capture this session. Do not run under a PowerShell transcript.'
    $null=Assert-ValveSteamCmd $Exe
    # Native terminal handles password masking/Steam Guard. No secret in arguments or script files.
    Push-Location -LiteralPath (Split-Path -Parent $Exe)
    try {
        & $Exe '+login' $UserName '+quit'
        if ($LASTEXITCODE -ne 0) { throw 'SteamCMD login did not finish successfully. Retry and complete Steam Guard in the native prompt.' }
    } finally { Pop-Location }
}

function Get-SteamCmdFailure {
    param([string]$Text, [int]$ExitCode)
    if ($Text -match '(?i)no subscription|missing license|access denied|does not have.*license|missing encryption key') { return 'Steam denied depot access. Verify game ownership, branch access and any DLC license; anonymous cannot download most retail games.' }
    if ($Text -match '(?i)steam guard|two.factor|No cached credentials|password.*required|Invalid Password|Account Logon Denied|FAILED.*Logon') { return 'Steam authentication is required or expired. Retry interactive SteamCMD login and complete Steam Guard.' }
    if ($Text -match '(?i)manifest.*(not available|unavailable|not found)|Failed.*manifest') { return 'Manifest unavailable. Resolve again and check branch/account access.' }
    if ($Text -match '(?i)disk.*full|not enough.*space|disk write|write failure') { return 'Disk write failed. Free disk space and check permissions before retrying.' }
    if ($Text -match '(?i)Depot download failed|ERROR!|Failed to install|connection.*failed|no connection|timed out') { return 'SteamCMD operation failed. Check network, account access, disk space and retry; cache has been retained.' }
    if ($ExitCode -ne 0) { return "SteamCMD exited with code $ExitCode. Check connection and authentication, then retry." }
    return $null
}

function Invoke-SteamCmd {
    param([string]$Exe, [string]$UserName, [ValidateSet('AppInfo','Download')][string]$Operation, [string]$AppId, [string]$DepotId, [string]$ManifestId, [int]$TimeoutSeconds=21600)
    $null=Assert-SteamId $AppId
    if ($UserName -notmatch '^[a-zA-Z0-9_]{1,64}$') { throw 'Invalid account name.' }
    $argsText="+@ShutdownOnFailedCommand 1 +@NoPromptForPassword 1 +login $UserName "
    if ($Operation -eq 'AppInfo') { $argsText+="+app_info_update 1 +app_info_print $AppId +quit" }
    else {
        $null=Assert-SteamId $DepotId; $null=Assert-SteamId $ManifestId -Manifest
        $argsText+="+download_depot $AppId $DepotId $ManifestId +quit"
    }
    $null=Assert-ValveSteamCmd $Exe
    $process=[Diagnostics.Process]::new()
    $started=$false
    $process.StartInfo=[Diagnostics.ProcessStartInfo]@{ FileName=$Exe; Arguments=$argsText; WorkingDirectory=(Split-Path -Parent $Exe); UseShellExecute=$false; RedirectStandardOutput=$true; RedirectStandardError=$true; RedirectStandardInput=$true; CreateNoWindow=$true }
    $process.StartInfo.StandardOutputEncoding=[Text.UTF8Encoding]::new($false)
    $process.StartInfo.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
    try {
        $null=$process.Start()
        $started=$true
        $process.StandardInput.Close()
        # Read both streams asynchronously to prevent stderr/stdout pipe deadlocks.
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        $watch=[Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            $exited=$process.WaitForExit(250)
            if ($exited -and $stdout.IsCompleted -and $stderr.IsCompleted) { break }
            if ($watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) { throw 'SteamCMD timed out. Retry after checking network and Steam authentication.' }
            Write-Progress -Activity 'Steam Depot Downloader' -Status "$Operation AppID $AppId - $([int]$watch.Elapsed.TotalSeconds)s (SteamCMD does not provide reliable percentage progress)"
            if ($exited) { Start-Sleep -Milliseconds 50 }
        }
        $result=[pscustomobject]@{ Stdout=$stdout.GetAwaiter().GetResult(); Stderr=$stderr.GetAwaiter().GetResult(); ExitCode=$process.ExitCode }
        $failure=Get-SteamCmdFailure ($result.Stdout + "`n" + $result.Stderr) $result.ExitCode
        if ($failure) { throw $failure }
        return $result
    } finally {
        if ($started -and -not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $process.Dispose()
        Write-Progress -Activity 'Steam Depot Downloader' -Completed
    }
}
