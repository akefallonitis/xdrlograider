#requires -Version 7.0
<#
.SYNOPSIS
  ITER11 · Lift stub entries to Source='live' when references/Defender/<sub>/<slug>/live.json exists with non-empty Body.

.DESCRIPTION
  Apply-ProjectionMaps missed 32 entries that have live.json on disk with real response data.
  This tool walks the stub set, reads live.json (.Body field), parses JSON, derives endpoint-specific
  ProjectionMap, and updates manifest entry: Source='live', ProjectionMap=derived, IrreducibleSchema=$false.

  Skip when live.json .Body is `{}` or `[]` (genuinely empty) · those stay stub.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ManifestPath = (Join-Path $PSScriptRoot '..' 'manifests' 'defender.psd1'),
    [string]$ReferencesRoot = (Join-Path $PSScriptRoot '..' 'references' 'Defender'),
    [int]$MaxFields = 30
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 13 canonical entity column names (preserve when present)
$EntityFields = @('DeviceId','UserPrincipalName','IpAddress','Url','FileHash','ProcessName','AlertId','IncidentId','MessageId','Mailbox','AppName','ResourceId','ThreatName')

function _ProjectionMapFromJsonSample {
    param([string]$JsonStr, [int]$MaxFields)
    $obj = $null
    try { $obj = $JsonStr | ConvertFrom-Json -Depth 20 -ErrorAction Stop } catch { return $null }
    if ($null -eq $obj) { return $null }
    if ($obj -is [array]) {
        if (@($obj).Count -eq 0) { return $null }
        $obj = $obj[0]
    }
    # OData / paginated response · use first .value element
    if ($obj.PSObject.Properties['value'] -and $obj.value -is [array] -and @($obj.value).Count -gt 0) {
        $obj = $obj.value[0]
    }
    if ($null -eq $obj) { return $null }

    $paths = [System.Collections.Generic.List[string]]::new()
    function _Walk { param($node, [string]$prefix)
        if ($null -eq $node) { return }
        if ($node -is [array]) {
            if (@($node).Count -gt 0) { _Walk $node[0] $prefix }
            return
        }
        $isScalar = ($node -is [string]) -or ($node -is [int]) -or ($node -is [long]) -or ($node -is [double]) -or ($node -is [bool]) -or ($node -is [datetime]) -or ($node -is [decimal])
        if ($isScalar) {
            if ($prefix) { [void]$paths.Add($prefix) }
            return
        }
        $props = @($node.PSObject.Properties)
        if ($props.Count -eq 0) {
            if ($prefix) { [void]$paths.Add($prefix) }
            return
        }
        foreach ($p in $props) {
            $childPrefix = if ([string]::IsNullOrEmpty($prefix)) { $p.Name } else { "$prefix.$($p.Name)" }
            _Walk $p.Value $childPrefix
        }
    }
    _Walk $obj ''
    if ($paths.Count -eq 0) { return $null }
    # Cap at MaxFields
    if ($paths.Count -gt $MaxFields) { $paths = $paths[0..($MaxFields - 1)] }

    # Build typed-DSL ProjectionMap
    $pm = @{}
    foreach ($p in $paths) {
        $segs = $p -split '\.'
        $last = $segs[-1]
        $fieldName = ($last) -replace '\W',''
        # PascalCase first letter
        if ($fieldName -and $fieldName[0] -match '[a-z]') {
            $fieldName = ([char]::ToUpperInvariant($fieldName[0])) + $fieldName.Substring(1)
        }
        if (-not $fieldName) { continue }
        # Skip Key_N garbage
        if ($fieldName -match '^Key_\d+$') { continue }
        $jsonPath = "`$.$p"
        $pm[$fieldName] = "`$tostring:$jsonPath"
    }
    if ($pm.Count -eq 0) { return $null }
    return $pm
}

# Load manifest
$manifestText = Get-Content -Raw -LiteralPath $ManifestPath
$manifest = & ([scriptblock]::Create($manifestText))
$entries = @($manifest.Entries)

$plan = [System.Collections.Generic.List[hashtable]]::new()
foreach ($e in $entries) {
    if ($e.Source -ne 'stub') { continue }
    $slug = [string]$e.Slug
    $sub = [string]$e.SubArea
    $livePath = Join-Path $ReferencesRoot "$sub/$slug/live.json"
    if (-not (Test-Path $livePath)) { continue }
    try {
        $live = Get-Content -Raw -LiteralPath $livePath | ConvertFrom-Json -ErrorAction Stop
    } catch { continue }
    if (-not $live.PSObject.Properties['Body']) { continue }
    $body = [string]$live.Body
    if ([string]::IsNullOrWhiteSpace($body)) { continue }
    $body = $body.Trim()
    if ($body -eq '{}' -or $body -eq '[]') { continue }
    if ($body.Length -lt 20) { continue }
    if ($body -match '^\s*\{\s*"error"\s*:\s*\{') { continue }
    $derivedPM = _ProjectionMapFromJsonSample -JsonStr $body -MaxFields $MaxFields
    if ($null -eq $derivedPM) { continue }
    if ($derivedPM.Count -lt 2) { continue }   # need at least 2 real fields to justify lift
    [void]$plan.Add(@{ EntryKey=[string]$e.EntryKey; PM=$derivedPM; BodySize=$body.Length })
}

Write-Host "Lift plan: $($plan.Count) stub entries to lift to Source='live' via existing fixtures" -ForegroundColor Yellow

if ($plan.Count -eq 0) { Write-Host 'Nothing to lift'; return }
$script:TargetManifest = $ManifestPath
if (-not $PSCmdlet.ShouldProcess($ManifestPath, "Lift $($plan.Count) stubs to live")) { return }

# Line-by-line mutation
$lines = [System.Collections.Generic.List[string]]::new()
Get-Content $script:TargetManifest | ForEach-Object { [void]$lines.Add($_) }

# Block index
$blocks = @{}
$current = $null
for ($i = 0; $i -lt $lines.Count; $i++) {
    $ln = $lines[$i]
    if (-not $current -and $ln -match '^        @\{\s*$') {
        $current = @{ Start=$i; EntryKey=$null; PMStart=$null; PMEnd=$null; SourceLine=$null; IrredLine=$null; ReasonLine=$null }
    }
    if ($current) {
        if ($ln -match "^\s+EntryKey\s+=\s+'([^']+)'") { $current.EntryKey = $Matches[1] }
        elseif ($ln -match '^\s+ProjectionMap\s+=\s+@\{') { $current.PMStart = $i }
        elseif ($current.PMStart -and -not $current.PMEnd -and $ln -match '^            \}') { $current.PMEnd = $i }
        elseif ($ln -match "^(\s+Source\s+=\s+)'([^']+)'") { $current.SourceLine = $i }
        elseif ($ln -match '^(\s+IrreducibleSchema\s+=\s+)') { $current.IrredLine = $i }
        elseif ($ln -match '^(\s+IrreducibleReason\s+=\s+)') { $current.ReasonLine = $i }
        elseif ($ln -match '^        \},?\s*$') {
            if ($current.EntryKey -and $current.PMStart -and $current.PMEnd) { $blocks[$current.EntryKey] = $current }
            $current = $null
        }
    }
}

$sorted = $plan | Sort-Object -Property { $blocks[$_.EntryKey].PMEnd } -Descending
$applied = 0
foreach ($p in $sorted) {
    $b = $blocks[$p.EntryKey]
    if (-not $b) { continue }
    # New PM block
    $pmLines = @('            ProjectionMap        = @{')
    foreach ($k in ($p.PM.Keys | Sort-Object)) {
        $v = $p.PM[$k] -replace "'", "''"
        $pmLines += "                $k".PadRight(40) + " = '$v'"
    }
    $pmLines += '            }'
    $lines.RemoveRange($b.PMStart, ($b.PMEnd - $b.PMStart + 1))
    for ($i = $pmLines.Count - 1; $i -ge 0; $i--) {
        $lines.Insert($b.PMStart, $pmLines[$i])
    }
    # Update Source → 'live'
    if ($b.SourceLine) {
        for ($j = $b.PMStart; $j -lt $lines.Count -and $j -lt $b.PMStart + 60; $j++) {
            if ($lines[$j] -match "^(\s+Source\s+=\s+)'([^']+)'(.*)$") {
                $lines[$j] = $Matches[1] + "'live'" + $Matches[3]
                break
            }
        }
    }
    # Update IrreducibleSchema → $false
    if ($b.IrredLine) {
        for ($j = $b.PMStart; $j -lt $lines.Count -and $j -lt $b.PMStart + 60; $j++) {
            if ($lines[$j] -match '^(\s+IrreducibleSchema\s+=\s+)\$\w+(.*)$') {
                $lines[$j] = $Matches[1] + '$false' + $Matches[2]
                break
            }
        }
    }
    # Update IrreducibleReason → ''
    if ($b.ReasonLine) {
        for ($j = $b.PMStart; $j -lt $lines.Count -and $j -lt $b.PMStart + 60; $j++) {
            if ($lines[$j] -match "^(\s+IrreducibleReason\s+=\s+)'[^']*'(.*)$") {
                $lines[$j] = $Matches[1] + "''" + $Matches[2]
                break
            }
        }
    }
    $applied++
}

[System.IO.File]::WriteAllLines($script:TargetManifest, $lines.ToArray(), [System.Text.UTF8Encoding]::new($false))
Write-Host "DONE · lifted $applied entries · re-parse verify..." -ForegroundColor Green

$m = & ([scriptblock]::Create((Get-Content -Raw -LiteralPath $script:TargetManifest)))
$m.Entries | Group-Object Source | Sort-Object Count -Descending | Format-Table Count, Name -AutoSize
