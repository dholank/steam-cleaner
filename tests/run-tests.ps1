$ErrorActionPreference='Stop'
$projectRoot=Split-Path -Parent $PSScriptRoot
foreach ($file in (Get-ChildItem -LiteralPath $projectRoot -Filter '*.ps1' -Recurse -File)) {
    $tokens=$null; $syntaxErrors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$syntaxErrors)
    if ($syntaxErrors.Count) { throw "Syntax errors in $($file.Name): $($syntaxErrors.Message -join '; ')" }
}
Write-Host 'PASS: PowerShell syntax validation'
& (Join-Path $PSScriptRoot 'safety.tests.ps1')
Write-Host 'All offline suites passed.'

