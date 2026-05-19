#Requires -Version 7.4
<#
.SYNOPSIS
    φ.A · Build per-endpoint Postman request templates (method · body · headers)
    so Capture-EndpointSchemas can retry failed calls with the correct request shape.

.DESCRIPTION
    Postman collection has 558 ops with documented request bodies. Many Defender
    POST endpoints return 400 when called with empty body — Postman has the
    proper body shape (filters · sortByField · pageIndex etc.).

    This tool:
      1. Walks the Postman collection tree
      2. For each leaf endpoint, extracts: method · path · headers · body.raw
      3. Matches to manifest entries by normalized path key
      4. Emits references/Defender/<sub>/<slug>/postman-request.json

    Capture-EndpointSchemas reads this on retry-after-400 path · re-issues request
    with Postman's exact body · headers · method.

.PARAMETER Portal
    Default 'Defender'. Future: Purview · Entra · Intune · SecurityCopilot.

.EXAMPLE
    pwsh tools/Build-PostmanRequestTemplates.ps1 -Portal Defender
#>
[CmdletBinding()]
param(
    [string]$Portal = 'Defender',
    [string]$ManifestPath,
    [string]$PostmanCollection = (Join-Path $PSScriptRoot '..\references\_external\nodoc\postman\collections\defender.collection.json'),
    [string]$ReferencesRoot = (Join-Path $PSScriptRoot '..\references'),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $ManifestPath) {
    $ManifestPath = Join-Path $PSScriptRoot ("..\manifests\{0}.psd1" -f $Portal.ToLowerInvariant())
}

Write-Host "Build-PostmanRequestTemplates · Portal=$Portal" -ForegroundColor Cyan
Write-Host "  Collection: $PostmanCollection" -ForegroundColor DarkGray

if (-not (Test-Path $PostmanCollection)) {
    throw "Postman collection not found: $PostmanCollection"
}

# ── Walk Postman collection → request map keyed by 'METHOD path/key' ─────────
function _Get-PathKey {
    param([string[]]$PathParts)
    ($PathParts | ForEach-Object { $_ -replace ':\w+','*' -replace '{[^}]+}','*' }) -join '/'
}

function _Walk {
    param($Node, [string[]]$AncestorNames, [hashtable]$Map)
    if ($null -eq $Node) { return }
    $hasItem    = $Node.PSObject.Properties['item'] -and $null -ne $Node.item -and (@($Node.item).Count -gt 0)
    $hasRequest = $Node.PSObject.Properties['request'] -and $null -ne $Node.request
    if ($hasRequest -and -not $hasItem) {
        try {
            $url = $Node.request.url
            $pathParts = if ($url -and $url.PSObject.Properties['path']) { @($url.path) } else { @() }
            if ($pathParts.Count -eq 0) { return }
            $pathKey = _Get-PathKey -PathParts $pathParts
            $method  = if ($Node.request.PSObject.Properties['method']) { $Node.request.method.ToUpperInvariant() } else { 'GET' }
            # Extract body.raw (the JSON request body)
            $body = $null
            if ($Node.request.PSObject.Properties['body'] -and $Node.request.body) {
                if ($Node.request.body.PSObject.Properties['raw'] -and $Node.request.body.raw) {
                    $body = [string]$Node.request.body.raw
                }
            }
            # Extract headers
            $headers = @{}
            if ($Node.request.PSObject.Properties['header'] -and $Node.request.header) {
                foreach ($h in @($Node.request.header)) {
                    if ($h -and $h.PSObject.Properties['key'] -and $h.PSObject.Properties['value']) {
                        $headers[[string]$h.key] = [string]$h.value
                    }
                }
            }
            # Extract query params
            $query = @()
            if ($url -and $url.PSObject.Properties['query'] -and $url.query) {
                foreach ($q in @($url.query)) {
                    if ($q -and $q.PSObject.Properties['key']) {
                        $query += @{ Key = [string]$q.key; Value = if ($q.PSObject.Properties['value']) { [string]$q.value } else { '' } }
                    }
                }
            }
            # Extract URL variables (path-param values · e.g. {AlertId} → real value)
            $variables = @{}
            if ($url -and $url.PSObject.Properties['variable'] -and $url.variable) {
                foreach ($v in @($url.variable)) {
                    if ($v -and $v.PSObject.Properties['key'] -and $v.PSObject.Properties['value']) {
                        $variables[[string]$v.key] = [string]$v.value
                    }
                }
            }
            $mapKey = "$method $pathKey"
            if (-not $Map.ContainsKey($mapKey)) {
                $Map[$mapKey] = @{
                    Method     = $method
                    Path       = '/' + ($pathParts -join '/')
                    PathKey    = $pathKey
                    Body       = $body
                    Headers    = $headers
                    Query      = @($query)
                    Variables  = $variables
                    Name       = $Node.name
                    AncestorPath = ($AncestorNames -join ' / ')
                }
            }
        } catch { }
        return
    }
    if ($hasItem) {
        $newAncestors = $AncestorNames + @($Node.name)
        foreach ($child in @($Node.item)) { _Walk $child $newAncestors $Map }
    }
}

# Parse Postman collection
$collection = Get-Content -Raw -LiteralPath $PostmanCollection | ConvertFrom-Json -Depth 50
$postmanMap = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($rootItem in @($collection.item)) { _Walk $rootItem @() $postmanMap }
Write-Host "  Indexed $($postmanMap.Count) Postman operations" -ForegroundColor DarkGray

# Stats
$opsWithBody  = @($postmanMap.Values | Where-Object { $_.Body }).Count
$opsWithVars  = @($postmanMap.Values | Where-Object { $_.Variables.Count -gt 0 }).Count
$opsWithQuery = @($postmanMap.Values | Where-Object { $_.Query.Count -gt 0 }).Count
Write-Host "    · With request body  : $opsWithBody" -ForegroundColor DarkGray
Write-Host "    · With path-var values: $opsWithVars" -ForegroundColor DarkGray
Write-Host "    · With query params  : $opsWithQuery" -ForegroundColor DarkGray

# Match Postman ops to manifest entries · write postman-request.json
$manifest = & ([scriptblock]::Create((Get-Content -Raw -LiteralPath $ManifestPath)))
$entries = @($manifest.Entries)

$stats = @{
    Total          = $entries.Count
    Matched        = 0
    WithBody       = 0
    WithVariables  = 0
    WithQuery      = 0
    WroteTemplate  = 0
    NoMatch        = @()
}

foreach ($e in $entries) {
    $slug = if ($e.ContainsKey('Slug') -and $e.Slug) { [string]$e.Slug } elseif ($e.ContainsKey('NodocRoute') -and $e.NodocRoute) {
        $leaf = ($e.NodocRoute -split '\.')[-1]
        if ($leaf -match 'TenantContext$') { 'TenantContext' } else { $leaf }
    } else { [string]$e.EntryKey }
    $subArea = [string]$e.SubArea
    # Normalize manifest path: strip /apiproxy/ prefix, strip query, replace path-params with *
    $p = [string]$e.Path -replace '^/apiproxy/', '' -replace '\?.*$', '' -replace '\{[^}]+\}', '*'
    $p = $p.TrimStart('/')
    $methodKey = "$($e.Method.ToUpperInvariant()) $p"

    $postmanOp = $null
    if ($postmanMap.ContainsKey($methodKey)) {
        $postmanOp = $postmanMap[$methodKey]
    } else {
        # Case-insensitive scan as fallback
        foreach ($k in $postmanMap.Keys) {
            if ($k -ieq $methodKey) { $postmanOp = $postmanMap[$k]; break }
        }
    }

    if (-not $postmanOp) {
        $stats.NoMatch += $e.EntryKey
        continue
    }
    $stats.Matched++

    # Compose template
    $template = [ordered]@{
        EntryKey      = [string]$e.EntryKey
        Slug          = $slug
        SubArea       = $subArea
        Method        = $postmanOp.Method
        ManifestPath  = [string]$e.Path
        PostmanPath   = $postmanOp.Path
        PostmanName   = $postmanOp.Name
        PostmanAncestor = $postmanOp.AncestorPath
        Headers       = $postmanOp.Headers
        Body          = $postmanOp.Body
        Query         = @($postmanOp.Query)
        Variables     = $postmanOp.Variables
        Provenance    = 'nodoc-postman'
        DerivedAt     = (Get-Date).ToUniversalTime().ToString('o')
    }
    if ($postmanOp.Body)            { $stats.WithBody++ }
    if ($postmanOp.Variables.Count) { $stats.WithVariables++ }
    if ($postmanOp.Query.Count)     { $stats.WithQuery++ }

    # Write template
    $epDir = Join-Path $ReferencesRoot "$Portal\$subArea\$slug"
    New-Item -ItemType Directory -Path $epDir -Force | Out-Null
    $outPath = Join-Path $epDir 'postman-request.json'
    if ((Test-Path $outPath) -and -not $Force) { continue }
    $template | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $outPath -Encoding UTF8
    $stats.WroteTemplate++
}

Write-Host ""
Write-Host "Build-PostmanRequestTemplates stats:" -ForegroundColor Cyan
Write-Host ("  Total entries:        {0}" -f $stats.Total)
Write-Host ("  Matched to Postman:   {0} ({1}%)" -f $stats.Matched, [math]::Round(100.0 * $stats.Matched / $stats.Total, 1))
Write-Host ("    With request body:  {0}" -f $stats.WithBody)
Write-Host ("    With path-vars:     {0}" -f $stats.WithVariables)
Write-Host ("    With query params:  {0}" -f $stats.WithQuery)
Write-Host ("  Templates written:    {0}" -f $stats.WroteTemplate)
Write-Host ("  No match (skipped):   {0}" -f @($stats.NoMatch).Count)
if (@($stats.NoMatch).Count -gt 0 -and @($stats.NoMatch).Count -le 20) {
    Write-Host "  No-match entries (first 20):" -ForegroundColor DarkGray
    foreach ($k in @($stats.NoMatch | Select-Object -First 20)) { Write-Host "    · $k" -ForegroundColor DarkGray }
}
