$ErrorActionPreference='Stop'
$projectRoot=Split-Path -Parent $PSScriptRoot
foreach ($file in (Get-ChildItem -LiteralPath $projectRoot -Filter '*.ps1' -Recurse -File)) {
    $tokens=$null; $syntaxErrors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$syntaxErrors)
    if ($syntaxErrors.Count) { throw "Syntax errors in $($file.Name): $($syntaxErrors.Message -join '; ')" }
}
Write-Host 'PASS: PowerShell syntax validation'
foreach ($test in @('safety.tests.ps1','depot.tests.ps1','settings.tests.ps1','entitlement.tests.ps1','download.tests.ps1','steamcmd.tests.ps1')) {
    & (Join-Path $PSScriptRoot $test)
}
Write-Host 'All offline suites passed.'
