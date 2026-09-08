# Optional network smoke test. NOT included in run-tests.ps1 or default CI.
[CmdletBinding()]
param([string]$AppId='90', [Parameter(Mandatory)][string]$ToolsRoot)
$ErrorActionPreference='Stop'
$integrationAppId=$AppId
. "$PSScriptRoot/../steam-cleaner.ps1" -LoadOnly
$AppId=$integrationAppId
$settings=Get-DepotSettings
$settings.ToolsRoot=$ToolsRoot
$exe=Get-SteamCmdPath $settings
$response=Invoke-SteamCmd -Exe $exe -UserName anonymous -Operation AppInfo -AppId $AppId -TimeoutSeconds 300
$info=Get-SteamAppInfoFromOutput $response.Stdout $AppId
if (-not (Get-VdfValue $info @('depots'))) { throw 'Live AppInfo lacks depots.' }
Write-Host 'Live anonymous AppInfo smoke test passed. No game depots downloaded.'
