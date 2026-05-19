# Xdr.Parser · L6 runtime projection layer · Reinforcement-A typed-DSL ProjectionMap.
#
# Cherry-picked from xdrlograider-v3/src/Modules/Xdr.Defender.Parser at Phase 0l (P-2).
# Inlined into single-file module (matching mvp Xdr.Auth/Xdr.Poll/Xdr.Ingest pattern).
# IDictionary-recursion fix applied (v3 bug: _Cast-XdrProjectionValue infinite-looped on hashtables).

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Apply-XdrProjectionMap {
    <#
    .SYNOPSIS
        ProjectionMap DSL evaluator · maps response fields to typed Sentinel columns.

    .DESCRIPTION
        Per Reinforcement-A · ProjectedData primary surface. DSL operators (prefix · colon · path):
          $tostring:Results[].ActionId      → cast value at dot-path to string
          $tolong:Count                      → cast to long
          $todouble:ScorePercentage          → cast to double
          $tobool:IsActive                   → cast to bool
          $todatetime:Results[].StartTime    → parse + emit ISO-8601
          $tojson:DetailedJsonBlob           → ConvertTo-Json -Compress

        Path notation:
          - Dot-separated for nested objects (Outer.Inner)
          - [] suffix for array elements (Results[].Field) · iterates · returns array

    .PARAMETER Response
        Parsed response object (hashtable or pscustomobject).

    .PARAMETER ProjectionMap
        [hashtable] of `ColumnName → 'DslOp:Path'`. From Step 8 ProjectionMap candidates.

    .OUTPUTS
        [hashtable] · ColumnName → typed value (or array for `[]` paths).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowNull()] $Response,
        [Parameter(Mandatory)] [hashtable] $ProjectionMap
    )

    $out = @{}
    foreach ($col in $ProjectionMap.Keys) {
        $expr = [string]$ProjectionMap[$col]
        if (-not ($expr -match '^\$(\w+):(.+)$')) {
            $out[$col] = $expr   # plain literal · no DSL
            continue
        }
        $op = $Matches[1]
        $path = $Matches[2]
        # φ.A · D-2026-05-18s · JSONPath deep-scan support ($..fieldName)
        # Stub-source entries (no live/openapi/postman) use $..fieldName for runtime
        # entity-heuristic extraction · walks the response tree to any depth.
        if ($path -match '^\$\.\.(.+)$') {
            # Deep-scan: walk tree, return first match of $1 key
            $val = _Resolve-XdrDeepScan -Node $Response -FieldName $Matches[1]
        } else {
            # Accept both JSONPath-rooted (`$.OrgId`) and rootless (`OrgId`) — strip leading `$.` if present.
            if ($path -match '^\$\.(.+)$') { $path = $Matches[1] }
            $val = _Resolve-XdrProjectionPath -Node $Response -Path $path
        }
        $out[$col] = _Cast-XdrProjectionValue -Value $val -Op $op
    }
    return $out
}

function _Resolve-XdrDeepScan {
    <#
    .SYNOPSIS
        JSONPath deep-scan · finds first occurrence of $FieldName at ANY depth in $Node tree.
        Used by stub-source ProjectionMap entries for runtime entity-heuristic extraction.
        Case-insensitive · returns first match · null if not found · supports nested arrays.
    #>
    param($Node, [string]$FieldName)
    if ($null -eq $Node -or [string]::IsNullOrEmpty($FieldName)) { return $null }
    # Strip trailing array suffix if present (e.g. 'DeviceId[]' · we deep-scan for 'DeviceId')
    $cleanField = $FieldName -replace '\[\]$', ''
    $stack = [System.Collections.Generic.Stack[object]]::new()
    $stack.Push($Node) | Out-Null
    $depth = 0
    while ($stack.Count -gt 0 -and $depth -lt 50) {
        $depth++
        $cur = $stack.Pop()
        if ($null -eq $cur) { continue }
        # Direct key match (case-insensitive)
        if ($cur -is [System.Collections.IDictionary]) {
            foreach ($k in $cur.Keys) {
                if ([string]$k -ieq $cleanField) {
                    $v = $cur[$k]
                    if ($null -ne $v -and -not ($v -is [System.Collections.IEnumerable] -and $v -isnot [string] -and $v -isnot [System.Collections.IDictionary])) {
                        return $v
                    }
                    if ($v -is [string]) { return $v }
                }
            }
            # Recurse into nested values
            foreach ($v in $cur.Values) {
                if ($null -ne $v) { $stack.Push($v) | Out-Null }
            }
            continue
        }
        # PSCustomObject · check properties
        if ($cur.PSObject -and $cur.PSObject.Properties) {
            foreach ($p in $cur.PSObject.Properties) {
                if ([string]$p.Name -ieq $cleanField) {
                    $v = $p.Value
                    if ($null -ne $v -and ($v -is [string] -or -not ($v -is [System.Collections.IEnumerable]))) {
                        return $v
                    }
                }
                if ($null -ne $p.Value) { $stack.Push($p.Value) | Out-Null }
            }
            continue
        }
        # Array · push each element
        if ($cur -is [System.Collections.IEnumerable] -and $cur -isnot [string]) {
            foreach ($el in $cur) {
                if ($null -ne $el) { $stack.Push($el) | Out-Null }
            }
        }
    }
    return $null
}

function _Resolve-XdrProjectionPath {
    param($Node, [string] $Path)
    if ($null -eq $Node -or [string]::IsNullOrEmpty($Path)) { return $null }
    $segments = [System.Collections.Generic.List[string]]::new()
    $cur = ''
    foreach ($ch in $Path.ToCharArray()) {
        if ($ch -eq '.') {
            if ($cur) { $segments.Add($cur) | Out-Null; $cur = '' }
        } else {
            $cur += $ch
        }
    }
    if ($cur) { $segments.Add($cur) | Out-Null }

    $current = $Node
    for ($i = 0; $i -lt $segments.Count; $i++) {
        $seg = $segments[$i]
        $isArray = $false
        if ($seg.EndsWith('[]')) { $isArray = $true; $seg = $seg.Substring(0, $seg.Length - 2) }
        if ($seg) {
            if ($null -eq $current) { return $null }
            if ($current -is [System.Collections.IDictionary]) {
                $current = $current[$seg]
            } elseif ($current.PSObject.Properties[$seg]) {
                $current = $current.$seg
            } else {
                return $null
            }
        }
        if ($isArray) {
            if ($null -eq $current) { return @() }
            $rest = if ($i + 1 -lt $segments.Count) { ($segments.GetRange($i + 1, $segments.Count - $i - 1) -join '.') } else { '' }
            $results = [System.Collections.Generic.List[object]]::new()
            foreach ($el in @($current)) {
                if ($rest) {
                    $sub = _Resolve-XdrProjectionPath -Node $el -Path $rest
                    if ($null -ne $sub) {
                        if ($sub -is [System.Collections.IEnumerable] -and $sub -isnot [string]) {
                            foreach ($s in $sub) { $results.Add($s) | Out-Null }
                        } else { $results.Add($sub) | Out-Null }
                    }
                } else {
                    $results.Add($el) | Out-Null
                }
            }
            return @($results)
        }
    }
    return $current
}

function _Cast-XdrProjectionValue {
    param($Value, [string] $Op)
    if ($null -eq $Value) { return $null }
    # Recurse only on plain arrays · NOT dictionaries/hashtables (would infinite-loop on DictionaryEntry enumeration).
    # $tojson handles dictionaries as a single ConvertTo-Json operation at the switch below.
    if ($Value -is [System.Collections.IEnumerable] -and `
        $Value -isnot [string] -and `
        $Value -isnot [System.Collections.IDictionary]) {
        return @($Value | ForEach-Object { _Cast-XdrProjectionValue -Value $_ -Op $Op })
    }
    switch ($Op) {
        'tostring'   { return [string]$Value }
        'tolong'     { try { return [long]$Value } catch { return $null } }
        'todouble'   { try { return [double]$Value } catch { return $null } }
        'tobool'     { try { return [bool]$Value } catch { return $null } }
        'todatetime' {
            try {
                $dt = [datetime]$Value
                return $dt.ToString('o')
            } catch { return $null }
        }
        'tojson'     { return ($Value | ConvertTo-Json -Compress -Depth 6) }
        default      { return [string]$Value }
    }
}

Export-ModuleMember -Function Apply-XdrProjectionMap
