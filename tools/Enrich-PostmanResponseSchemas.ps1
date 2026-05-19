#requires -Version 7.0
<#
.SYNOPSIS
  ITER10 · Comprehensive Postman response-schema enrichment.
  Walks Postman collection · for EVERY manifest entry currently Source='stub'
  (or with generic 14-entity ProjectionMap) · extracts response body schema
  from Postman · derives endpoint-specific ProjectionMap.

.DESCRIPTION
  Operator requirement: 100% ProjectionMap specificity. License-gated/feature-disabled
  endpoints must STILL have endpoint-specific ProjectionMap so when deployed to a
  properly-licensed production tenant the projection extracts the right fields.

  The Postman collection has 583 ops with rich response bodies (≥50 chars · not {}/[]).
  Currently 262 manifest entries are Source='stub' with the generic 13-entity scaffold.
  This tool:
    1. Walks the Postman collection · indexes path → response body
    2. For each stub entry · finds matching Postman op via path
    3. Parses response JSON · walks all leaf paths
    4. Derives ProjectionMap = @{ FieldName = '$tostring:$.path.to.field' }
    5. Re-emits manifest with Source='postman-rich' (or 'postman' for compat)
    6. Preserves 13-entity columns if present in response (DeviceId · UPN · etc.)

  Idempotent · re-runnable · safe to chain after Apply-ProjectionMaps.

.NOTES
  Author: Alex Kefallonitis · ITER10 · 2026-05-20.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ManifestPath  = (Join-Path $PSScriptRoot '..' 'manifests' 'defender.psd1'),
    [string]$PostmanPath   = (Join-Path $PSScriptRoot '..' 'references' '_external' 'nodoc' 'postman' 'collections' 'defender.collection.json'),
    [int]$MinBodyChars     = 50,
    [int]$MaxFields        = 50    # cap ProjectionMap size to avoid manifest bloat
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ManifestPath)) { throw "Manifest not found: $ManifestPath" }
if (-not (Test-Path $PostmanPath))  { throw "Postman collection not found: $PostmanPath" }

# 13 canonical entity field names (preserve in ProjectionMap when present)
$EntityFields = @('DeviceId','UserPrincipalName','IpAddress','Url','FileHash',
                  'ProcessName','AlertId','IncidentId','MessageId','Mailbox',
                  'AppName','ResourceId','ThreatName')

# Step 1 · Walk Postman collection · build path → response-body index
Write-Host "Walking Postman collection..." -ForegroundColor Cyan
$pm = Get-Content -Raw $PostmanPath | ConvertFrom-Json
$postmanIndex = @{}   # normalized path → first rich response body
function _Walk { param($node)
    if ($node.PSObject.Properties['request']) {
        $url = $null
        try {
            if ($node.request.url -is [string]) { $url = $node.request.url }
            elseif ($node.request.url -and $node.request.url.PSObject.Properties['path']) {
                $url = '/' + (@($node.request.url.path) -join '/')
            }
            elseif ($node.request.url -and $node.request.url.PSObject.Properties['raw']) {
                $url = $node.request.url.raw
            }
        } catch { $url = $null }
        if ($url) {
            $normPath = ($url -replace '^https?://[^/]+', '' -replace '\?.*$', '').TrimEnd('/')
            if ($node.PSObject.Properties['response'] -and @($node.response).Count -gt 0) {
                # ITER10 quality-fix · ONLY consider 2xx success responses (code 200-299).
                # Postman collections store 4 examples per op: 200 OK + 401 + 403 + 404
                # The 4xx examples all carry `{"error":{"code":"BadRequest",...}}` (87 bytes).
                # Original tool's MinBodyChars=50 filter accidentally accepted error bodies
                # over empty success bodies `{}`/`[]` (2 bytes) → poisoned 246 entries with
                # error-shape ProjectionMaps. The fix: status-code gate · then body-size +
                # non-empty checks. Entries whose 200 OK body is `{}` revert to honest stub.
                foreach ($r in @($node.response)) {
                    if ($null -eq $r) { continue }
                    $code = if ($r.PSObject.Properties['code']) { [int]$r.code } else { 0 }
                    if ($code -lt 200 -or $code -ge 300) { continue }   # success-only
                    $hasBody = $r.PSObject.Properties['body'] -and $null -ne $r.body
                    if (-not $hasBody) { continue }
                    $bodyStr = ([string]$r.body).Trim()
                    if ($bodyStr.Length -lt $MinBodyChars) { continue }
                    if ($bodyStr -eq '{}' -or $bodyStr -eq '[]') { continue }
                    # Defensive: if the body somehow has top-level "error":{ structure, skip
                    # (some Postman collections mis-tag error responses as 200 OK).
                    if ($bodyStr -match '^\s*\{\s*"error"\s*:\s*\{') { continue }
                    # ITER10 path-syntax normalization · Postman uses `:foo`, manifest uses `{foo}`.
                    # Index under BOTH conventions so manifest matcher can find either shape.
                    if (-not $postmanIndex.ContainsKey($normPath)) {
                        $postmanIndex[$normPath] = $bodyStr
                    }
                    # Also store with `{foo}` convention so manifest entries with that syntax match
                    if ($normPath -match ':') {
                        $bracePath = $normPath -replace ':([A-Za-z0-9_]+)', '{$1}'
                        if (-not $postmanIndex.ContainsKey($bracePath)) {
                            $postmanIndex[$bracePath] = $bodyStr
                        }
                    }
                    break
                }
            }
        }
    }
    if ($node.PSObject.Properties['item']) {
        foreach ($c in $node.item) { _Walk $c }
    }
}
_Walk $pm
Write-Host "Postman index: $($postmanIndex.Count) unique paths with rich response body" -ForegroundColor Green

# Step 2 · Load manifest · identify enrichment candidates
$manifest = & ([scriptblock]::Create((Get-Content -Raw -LiteralPath $ManifestPath)))
$entries = @($manifest.Entries)
Write-Host "Loaded $($entries.Count) manifest entries" -ForegroundColor Cyan

# Helper: derive ProjectionMap from JSON sample body
function _ProjectionMapFromJsonSample {
    param([string]$JsonStr, [int]$MaxFields)
    $obj = $null
    try { $obj = $JsonStr | ConvertFrom-Json -Depth 20 -ErrorAction Stop } catch { return $null }
    if ($null -eq $obj) { return $null }
    # Unwrap arrays · use first element as template
    if ($obj -is [array]) {
        if (@($obj).Count -eq 0) { return $null }
        $obj = $obj[0]
    }
    if ($obj.PSObject.Properties['value'] -and $obj.value -is [array] -and @($obj.value).Count -gt 0) {
        # OData-style { "@odata.context": "...", "value": [...] } → use first element
        $obj = $obj.value[0]
    }
    if ($null -eq $obj) { return $null }

    # Walk object · collect leaf JSONPaths
    $paths = [System.Collections.Generic.List[string]]::new()
    function _Walk { param($node, [string]$prefix)
        if ($null -eq $node) { return }
        if ($node -is [array]) {
            if (@($node).Count -gt 0) { _Walk $node[0] $prefix }
            return
        }
        # Type-check: only walk into objects (PSCustomObject from JSON) · not scalars
        $isScalar = ($node -is [string]) -or ($node -is [int]) -or ($node -is [long]) -or ($node -is [double]) -or ($node -is [bool]) -or ($node -is [datetime]) -or ($node -is [decimal])
        if ($isScalar) {
            if ($prefix) { [void]$paths.Add($prefix) }
            return
        }
        # PSCustomObject · iterate properties (safely)
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
    if ($paths.Count -gt $MaxFields) { $paths = $paths[0..($MaxFields - 1)] }

    $pm = @{}
    foreach ($p in $paths) {
        # Field name = last segment · PascalCase
        $segs = $p -split '\.'
        $last = $segs[-1]
        $fieldName = ([char]::ToUpperInvariant($last[0]) + $last.Substring(1)) -replace '\W',''
        if (-not $fieldName) { continue }
        # Detect type from prefix-stripped path  ·  default to string for simplicity
        $jsonPath = "`$.$p"
        $pm[$fieldName] = "`$tostring:$jsonPath"
    }
    return $pm
}

# Step 3 · For each entry · attempt Postman enrichment if current ProjectionMap is generic stub
$plan = [System.Collections.Generic.List[hashtable]]::new()
foreach ($e in $entries) {
    if ($e.ProbeMode -eq 'Excluded') { continue }     # never enrich excluded mutations
    $currentSource = if ($e.ContainsKey('Source')) { [string]$e.Source } else { 'unknown' }
    # Defensive · ProjectionMap may be $null in malformed entries
    $pmKeys = @()
    if ($e.ContainsKey('ProjectionMap') -and $null -ne $e.ProjectionMap) {
        $pmKeys = @($e.ProjectionMap.Keys)
    }
    $pmCount = $pmKeys.Count
    # Detect generic 14-entity stub (DeviceId + UPN + IP + Url + FileHash + ... + _StubSource)
    $isGenericStub = ($currentSource -eq 'stub') -or
                     ($pmCount -le 14 -and $pmKeys -contains 'DeviceId' -and $pmKeys -contains 'UserPrincipalName' -and $pmKeys -contains '_StubSource')
    if (-not $isGenericStub) { continue }

    # Match in Postman index · try multiple normalizations
    # NB: PowerShell is case-insensitive for variable names · $manifestPath would shadow $ManifestPath param
    $entryUrl = [string]$e.Path
    $candidates = @(
        ($entryUrl -replace '^/apiproxy', ''),
        $entryUrl,
        ($entryUrl -replace '^/apiproxy/', '/')
    )
    $matchedBody = $null
    foreach ($c in $candidates) {
        $norm = $c.TrimEnd('/')
        if ($postmanIndex.ContainsKey($norm)) { $matchedBody = $postmanIndex[$norm]; break }
    }
    if (-not $matchedBody) { continue }

    $derivedPM = _ProjectionMapFromJsonSample -JsonStr $matchedBody -MaxFields $MaxFields
    if ($null -eq $derivedPM) { continue }
    $derivedCount = if ($derivedPM -is [hashtable]) { $derivedPM.Keys.Count } else { 0 }
    if ($derivedCount -eq 0) { continue }

    [void]$plan.Add(@{
        EntryKey   = $e.EntryKey
        OldSource  = $currentSource
        OldFields  = $pmCount
        NewSource  = 'postman-rich'
        NewPM      = $derivedPM
        NewFields  = $derivedCount
    })
}

Write-Host "Enrichment plan: $($plan.Count) entries to lift from generic stub → endpoint-specific Postman schema" -ForegroundColor Yellow

if ($plan.Count -eq 0) { Write-Host 'Nothing to enrich · all entries already have specific schema'; return }
# Save to script-scope to avoid ShouldProcess positional-arg shadowing of $ManifestPath
$script:TargetManifest = $ManifestPath
if (-not $PSCmdlet.ShouldProcess('manifests/defender.psd1', "Enrich $($plan.Count) entries with Postman response schemas")) { return }

# Step 4 · Mutate manifest line-by-line · replace ProjectionMap + Source field
$lines = [System.Collections.Generic.List[string]]::new()
Get-Content $script:TargetManifest | ForEach-Object { [void]$lines.Add($_) }

$blocks = @{}
$current = $null
for ($i = 0; $i -lt $lines.Count; $i++) {
    $ln = $lines[$i]
    if (-not $current -and $ln -match '^        @\{\s*$') {
        $current = @{ Start=$i; EntryKey=$null; PMStart=$null; PMEnd=$null; SourceLine=$null }
    }
    if ($current) {
        if ($ln -match "^\s+EntryKey\s+=\s+'([^']+)'") { $current.EntryKey = $Matches[1] }
        elseif ($ln -match '^\s+ProjectionMap\s+=\s+@\{') { $current.PMStart = $i }
        elseif ($current.PMStart -and -not $current.PMEnd -and $ln -match '^            \}') { $current.PMEnd = $i }
        elseif ($ln -match "^(\s+Source\s+=\s+)'([^']+)'") { $current.SourceLine = $i }
        elseif ($ln -match '^        \},?\s*$') {
            if ($current.EntryKey -and $current.PMStart -and $current.PMEnd) {
                $blocks[$current.EntryKey] = $current
            }
            $current = $null
        }
    }
}

# Apply enrichments in reverse order (to preserve line indices)
$sorted = $plan | Sort-Object -Property { $blocks[$_.EntryKey].PMEnd } -Descending
$applied = 0
foreach ($p in $sorted) {
    $b = $blocks[$p.EntryKey]
    if (-not $b) { continue }
    # Build new ProjectionMap lines · alphabetical for determinism
    $pmLines = @('            ProjectionMap        = @{')
    foreach ($k in ($p.NewPM.Keys | Sort-Object)) {
        $v = $p.NewPM[$k] -replace "'", "''"
        $pmLines += "                $k".PadRight(40) + " = '$v'"
    }
    $pmLines += '            }'
    # Remove old ProjectionMap block (PMStart..PMEnd inclusive) · insert new
    $lines.RemoveRange($b.PMStart, ($b.PMEnd - $b.PMStart + 1))
    for ($i = $pmLines.Count - 1; $i -ge 0; $i--) {
        $lines.Insert($b.PMStart, $pmLines[$i])
    }
    # Update Source line if present
    if ($b.SourceLine) {
        # Re-locate source line (it shifted)
        for ($j = $b.PMStart; $j -lt $lines.Count -and $j -lt $b.PMStart + 50; $j++) {
            if ($lines[$j] -match "^(\s+Source\s+=\s+)'([^']+)'(.*)$") {
                $lines[$j] = $Matches[1] + "'$($p.NewSource)'" + $Matches[3]
                break
            }
        }
    }
    $applied++
}

[System.IO.File]::WriteAllLines($script:TargetManifest, $lines.ToArray(), [System.Text.UTF8Encoding]::new($false))
Write-Host "Wrote $($lines.Count) lines · applied $applied enrichments" -ForegroundColor Green

# Verify
$m = & ([scriptblock]::Create((Get-Content -Raw -LiteralPath $script:TargetManifest)))
Write-Host "`nFinal Source distribution:" -ForegroundColor Cyan
$m.Entries | Group-Object Source | Sort-Object Count -Descending | Format-Table Count, Name -AutoSize
$genericStub = @($m.Entries | Where-Object { @($_.ProjectionMap.Keys).Count -le 14 -and $_.ProjectionMap.ContainsKey('DeviceId') -and $_.ProjectionMap.ContainsKey('_StubSource') })
Write-Host "Remaining generic-stub entries: $($genericStub.Count) (target: <50)"
