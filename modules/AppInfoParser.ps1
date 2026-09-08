function ConvertFrom-SteamVdf {
    param([Parameter(Mandatory)][string]$Text)
    # Preserve publisher order. Reject duplicate keys and unsupported conditions rather than guessing.
    $pattern = '\G(?:\s+|//[^\r\n]*(?:\r?\n|$)|(?<quoted>"(?:\\.|[^"\\])*")|(?<brace>[{}])|(?<bare>[^\s"{}]+))'
    $tokens = [Collections.Generic.List[string]]::new()
    $position = 0
    $regex = [regex]::new($pattern, [Text.RegularExpressions.RegexOptions]::Singleline, [TimeSpan]::FromSeconds(2))
    while ($position -lt $Text.Length) {
        $match = $regex.Match($Text, $position)
        if (-not $match.Success) { throw "Malformed VDF near character $position." }
        $position += $match.Length
        if ($match.Groups['quoted'].Success -or $match.Groups['brace'].Success -or $match.Groups['bare'].Success) { $tokens.Add($match.Value) }
    }
    $state = @{ Tokens=$tokens; Index=0; Depth=0 }
    $result = Read-VdfObject $state
    if ($state.Index -ne $tokens.Count) { throw 'Unexpected trailing VDF tokens.' }
    return ,$result
}

function ConvertFrom-VdfToken {
    param([string]$Token)
    if ($Token.StartsWith('"')) {
        $value = $Token.Substring(1, $Token.Length - 2)
        return [regex]::Replace($value, '\\(["\\])', '$1')
    }
    if ($Token -match '^\[' -or $Token.StartsWith('#')) { throw 'Conditional/directive VDF is not supported in automatic mode.' }
    return $Token
}

function Read-VdfObject {
    param([hashtable]$State, [switch]$Nested)
    if (++$State.Depth -gt 64) { throw 'VDF nesting limit exceeded.' }
    $object = [ordered]@{}
    while ($State.Index -lt $State.Tokens.Count) {
        $keyToken = $State.Tokens[$State.Index++]
        if ($keyToken -eq '}') {
            if (-not $Nested) { throw 'Unexpected closing VDF brace.' }
            $State.Depth--; return ,$object
        }
        if ($keyToken -eq '{' -or $State.Index -ge $State.Tokens.Count) { throw 'Missing VDF key or value.' }
        $key = ConvertFrom-VdfToken $keyToken
        if ($object.Contains($key)) { throw "Duplicate VDF key: $key" }
        $value = $State.Tokens[$State.Index++]
        if ($value -eq '{') { $object[$key] = Read-VdfObject $State -Nested }
        elseif ($value -eq '}') { throw 'Missing VDF value.' }
        else { $object[$key] = ConvertFrom-VdfToken $value }
    }
    $State.Depth--
    if ($Nested) { throw 'Unterminated VDF object.' }
    return ,$object
}

function Get-SteamVdfObjectFromOutput {
    param([string]$Text, [string]$RootKey, [string]$Description='Steam metadata')
    $start = [regex]::Match($Text, '(?m)^\s*"?' + [regex]::Escape($RootKey) + '"?\s*\{')
    if (-not $start.Success) { throw "$Description for $RootKey is missing or incomplete." }
    $tail = $Text.Substring($start.Index)
    # Extract exactly one balanced object; SteamCMD prepends/appends console chatter.
    $quoted=$false; $escaped=$false; $depth=0; $opened=$false
    for ($i=0; $i -lt $tail.Length; $i++) {
        $c=$tail[$i]
        if ($quoted) {
            if ($escaped) { $escaped=$false }
            elseif ($c -eq '\') { $escaped=$true }
            elseif ($c -eq '"') { $quoted=$false }
        } elseif ($c -eq '/' -and $i+1 -lt $tail.Length -and $tail[$i+1] -eq '/') {
            while ($i -lt $tail.Length -and $tail[$i] -ne "`n") { $i++ }
        } elseif ($c -eq '"') { $quoted=$true }
        elseif ($c -eq '{') { $depth++; $opened=$true }
        elseif ($c -eq '}') {
            $depth--
            if ($opened -and $depth -eq 0) {
                $parsed=ConvertFrom-SteamVdf $tail.Substring(0,$i+1)
                return ,$parsed[$RootKey]
            }
        }
    }
    throw "Truncated $Description output; no complete VDF object."
}

function Get-SteamAppInfoFromOutput {
    param([string]$Text, [string]$AppId)
    $null = Assert-SteamId $AppId
    return ,(Get-SteamVdfObjectFromOutput -Text $Text -RootKey $AppId -Description 'AppInfo')
}
