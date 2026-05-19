#Requires -Version 7.4
#Requires -Module powershell-yaml
<#
.SYNOPSIS
    Phase 0i fallback · synthesizes projection-candidates.json from nodoc OpenAPI
    `example` blocks for endpoints lacking live captures.

.DESCRIPTION
    Apply-ProjectionMaps emits a populated ProjectionMap only when a live capture
    succeeded for the endpoint. Many Defender endpoints can't be probed in our
    test tenant (400-error, license-gated, requires path-param substitution).

    For those endpoints, this script parses references/_external/nodoc/.../<spec>.yml
    and looks up the operation by operationId. If a `responses['200'].content.['application/json'].example`
    is present, derives a projection-candidates.json from the example fields.

    Generated artefacts are tagged Provenance='nodoc-openapi-schema-example' so the
    operator can distinguish from live-derived candidates.

    Apply-ProjectionMaps then picks them up on re-run, populating the manifest
    ProjectionMap field for previously-empty entries.

.PARAMETER Portal
    Default 'Defender'.

.EXAMPLE
    pwsh tools/Derive-NodocFallback.ps1 -Portal Defender
    pwsh tools/Apply-ProjectionMaps.ps1 -Portal Defender   # re-run to pick up fallbacks
#>

[CmdletBinding()]
param(
    [string]$Portal = 'Defender',
    [string]$ManifestPath,
    [string]$NodocRoot      = (Join-Path $PSScriptRoot '..\references\_external\nodoc'),
    [string]$ReferencesRoot = (Join-Path $PSScriptRoot '..\references'),
    [string]$PostmanCollection = (Join-Path $PSScriptRoot '..\references\_external\nodoc\postman\collections\defender.collection.json'),
    [switch]$Force          # overwrite existing projection-candidates.json
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $ManifestPath) {
    $ManifestPath = Join-Path $PSScriptRoot ("..\manifests\{0}.psd1" -f $Portal.ToLowerInvariant())
}

Import-Module powershell-yaml -ErrorAction Stop
. (Join-Path $PSScriptRoot 'lib\Derive-Schema.lib.ps1')

Write-Host "Derive-NodocFallback · Portal=$Portal" -ForegroundColor Cyan

# ── Postman parser · 3rd source (operator correction 2026-05-18) ──
# Walks the recursive item[] tree of a Postman v2.1.0 collection · returns map of
# normalized-path → first 2xx response body sample.
# Postman path structure: nested items where leaf has `request` with `url.path` array.
# Response body is in `response[].body` (raw JSON string).

function Get-PostmanPathKey {
    param([Parameter(Mandatory)][string[]]$PathParts)
    # Normalize: lowercase · slash-join · strip path-params (Postman uses :param ; we strip)
    ($PathParts | ForEach-Object { $_ -replace ':\w+','*' -replace '{[^}]+}','*' }) -join '/'
}

function ConvertTo-PostmanOpsMap {
    [CmdletBinding()][OutputType([hashtable])]
    param([Parameter(Mandatory)]$CollectionRoot)

    $map = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)

    function _Walk {
        param($node, [string[]]$ancestorNames)
        if ($null -eq $node) { return }
        # Leaf · has request + no item
        $hasItem = $node.PSObject.Properties['item'] -and $null -ne $node.item -and (@($node.item).Count -gt 0)
        $hasRequest = $node.PSObject.Properties['request'] -and $null -ne $node.request
        if ($hasRequest -and -not $hasItem) {
            try {
                $url = $node.request.url
                $pathParts = if ($url -and $url.PSObject.Properties['path']) { @($url.path) } else { @() }
                if ($pathParts.Count -eq 0) { return }
                $pathKey = Get-PostmanPathKey -PathParts $pathParts
                $method = if ($node.request.PSObject.Properties['method']) { $node.request.method.ToUpperInvariant() } else { 'GET' }
                # φ.A.2.1 · IMPROVED body extraction · was too strict (only 2xx · only 45/501 matched yielded fields)
                # · accept ANY response with non-empty body (some Postman entries have code=0 · 401 examples · valid shape)
                # · prefer 2xx · fall back to any response · take FIRST with non-empty body
                $responseBody = $null
                if ($node.PSObject.Properties['response'] -and $node.response) {
                    $responses = @($node.response) | Where-Object { $null -ne $_ -and $_.PSObject.Properties['body'] -and $_.body }
                    # Priority 1 · 2xx response with body
                    foreach ($r in @($responses)) {
                        $sc = if ($r.PSObject.Properties['code']) { [int]$r.code } else { 0 }
                        if ($sc -ge 200 -and $sc -lt 300) {
                            $responseBody = [string]$r.body
                            break
                        }
                    }
                    # Priority 2 · any response with body (4xx schemas still inform structure)
                    if (-not $responseBody) {
                        foreach ($r in @($responses)) {
                            $b = [string]$r.body
                            if ($b -and $b.TrimStart() -match '^[\{\[]') {   # JSON-shaped (starts with { or [)
                                $responseBody = $b
                                break
                            }
                        }
                    }
                }
                $mapKey = "$method $pathKey"
                if (-not $map.ContainsKey($mapKey)) {
                    $map[$mapKey] = @{
                        Method     = $method
                        PathParts  = $pathParts
                        PathKey    = $pathKey
                        Name       = $node.name
                        Body       = $responseBody
                        AncestorNames = $ancestorNames
                    }
                }
            } catch { }
            return
        }
        if ($hasItem) {
            $newAncestors = $ancestorNames + @($node.name)
            foreach ($child in @($node.item)) { _Walk $child $newAncestors }
        }
    }

    foreach ($rootItem in @($CollectionRoot.item)) { _Walk $rootItem @() }
    return $map
}

function Resolve-PostmanResponseForEntry {
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][hashtable]$PostmanMap)
    # Entry.Path is e.g. '/apiproxy/mtp/alertsApiService/alerts'
    # Postman pathKey is e.g. 'mtp/alertsApiService/alerts'
    # Strip leading '/apiproxy/' from entry.Path · then normalize
    $p = $Entry.Path -replace '^/apiproxy/', '' -replace '\?.*$', '' -replace '\{[^}]+\}', '*'
    $p = $p.TrimStart('/')
    $methodKey = "$($Entry.Method.ToUpperInvariant()) $p"
    if ($PostmanMap.ContainsKey($methodKey)) { return $PostmanMap[$methodKey] }
    # Try case-insensitive search (Postman collection casing may differ)
    foreach ($k in $PostmanMap.Keys) {
        if ($k -ieq $methodKey) { return $PostmanMap[$k] }
    }
    return $null
}

# Resolve `$ref: '#/components/schemas/<name>'` or 'common.yml#/components/...' relative
# to the spec's own components.schemas (or a sibling spec for cross-file refs).
function Resolve-SchemaRef {
    param([Parameter(Mandatory)][string]$Ref, [Parameter(Mandatory)]$LocalComponents, [hashtable]$AllSpecs)
    # Local ref · '#/components/schemas/Database'
    if ($Ref -match '^#/components/schemas/(.+)$') {
        $name = $Matches[1]
        if ($LocalComponents -and $LocalComponents.ContainsKey('schemas') -and $LocalComponents.schemas.ContainsKey($name)) {
            return $LocalComponents.schemas[$name]
        }
    }
    # Cross-file ref · 'common.yml#/components/schemas/Foo'
    if ($Ref -match '^([\w_.-]+\.yml)#/components/schemas/(.+)$') {
        $sib  = $Matches[1]
        $name = $Matches[2]
        if ($AllSpecs.ContainsKey($sib)) {
            $sibSpec = $AllSpecs[$sib]
            if ($sibSpec -and $sibSpec.ContainsKey('components') -and $sibSpec.components.ContainsKey('schemas') -and $sibSpec.components.schemas.ContainsKey($name)) {
                return $sibSpec.components.schemas[$name]
            }
        }
    }
    return $null
}

# Walk a (possibly nested) OpenAPI schema object → emit pseudo-example.
# Recursively resolves $ref. Returns an example-style object (hashtable/array) that
# Get-JsonFieldInventory can walk to produce typed field paths.
function ConvertTo-ExampleFromSchema {
    param([Parameter(Mandatory)]$Schema, [hashtable]$LocalComponents, [hashtable]$AllSpecs, [int]$Depth = 0)
    if ($Depth -gt 8) { return $null }
    if ($null -eq $Schema -or -not ($Schema -is [System.Collections.IDictionary])) { return $null }

    if ($Schema.ContainsKey('$ref')) {
        $resolved = Resolve-SchemaRef -Ref $Schema['$ref'] -LocalComponents $LocalComponents -AllSpecs $AllSpecs
        if ($null -eq $resolved) { return $null }
        return (ConvertTo-ExampleFromSchema -Schema $resolved -LocalComponents $LocalComponents -AllSpecs $AllSpecs -Depth ($Depth + 1))
    }

    if ($Schema.ContainsKey('example')) { return $Schema.example }

    $type = if ($Schema.ContainsKey('type')) { $Schema.type } else { 'object' }
    switch ($type) {
        'string' {
            if ($Schema.ContainsKey('format')) {
                switch ($Schema.format) {
                    'date-time' { return '2026-01-01T00:00:00Z' }
                    'date'      { return '2026-01-01' }
                    'uuid'      { return '00000000-0000-0000-0000-000000000000' }
                    default     { return 'sample-string' }
                }
            }
            return 'sample-string'
        }
        'integer'  { return 0 }
        'number'   { return 0.0 }
        'boolean'  { return $false }
        'array'    {
            if ($Schema.ContainsKey('items')) {
                $childEx = ConvertTo-ExampleFromSchema -Schema $Schema.items -LocalComponents $LocalComponents -AllSpecs $AllSpecs -Depth ($Depth + 1)
                if ($null -ne $childEx) { return @($childEx) }
            }
            return @()
        }
        'object'   {
            if ($Schema.ContainsKey('properties')) {
                $obj = [ordered]@{}
                foreach ($prop in $Schema.properties.GetEnumerator()) {
                    $val = ConvertTo-ExampleFromSchema -Schema $prop.Value -LocalComponents $LocalComponents -AllSpecs $AllSpecs -Depth ($Depth + 1)
                    if ($null -ne $val) { $obj[$prop.Key] = $val }
                }
                if ($obj.Count -gt 0) { return $obj }
            }
            return $null
        }
        default { return $null }
    }
}

# Build a SpecFile → operation lookup from nodoc YAMLs (avoid re-parsing per entry)
# Per-portal spec-root map (Phase ε.2 multi-portal expansion)
$specsRootByPortal = @{
    'Defender'        = @('specifications/nodoc-defender-xdr/specification')
    'Purview'         = @('specifications/nodoc-purview/specification')
    'Entra'           = @(
        'specifications/nodoc-ibiza-iam/specification'
        'specifications/nodoc-entra-pim/specification'
        'specifications/nodoc-entra-idgov/specification'
        'specifications/nodoc-entra-iga/specification'
        'specifications/nodoc-entra-b2c/specification'
    )
    'Intune'          = @(
        'specifications/nodoc-intune-portal/specification'
        'specifications/nodoc-intune-autopatch/specification'
    )
    'SecurityCopilot' = @('specifications/nodoc-security-copilot/specification')
}
$specRoots = @($specsRootByPortal[$Portal])
if (-not $specRoots -or $specRoots.Count -eq 0) {
    throw "Derive-NodocFallback: no spec-root mapping for portal '$Portal'"
}
$specFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
$specsRootResolved = $null
foreach ($r in $specRoots) {
    $p = Join-Path $NodocRoot $r
    if (Test-Path $p) {
        $allYaml = @(Get-ChildItem -Path $p -Filter '*.yml' -File -ErrorAction SilentlyContinue)
        # Skip openapi.yml ONLY when sub-area yamls exist alongside it (Defender pattern).
        # When openapi.yml is the only yaml (Intune/SecurityCopilot pattern), keep it.
        $nonOpenapi = @($allYaml | Where-Object { $_.Name -notmatch 'openapi\.yml$' })
        $toScan = if ($nonOpenapi.Count -gt 0) { $nonOpenapi } else { $allYaml }
        foreach ($f in $toScan) { $specFiles.Add($f) | Out-Null }
        if (-not $specsRootResolved) { $specsRootResolved = $p }
    }
}
$specsRoot = $specsRootResolved
if (-not $specsRoot -or $specFiles.Count -eq 0) {
    Write-Warning "Derive-NodocFallback: no spec files found for portal '$Portal' under $($specRoots -join ', ')"
}
Write-Host ("  Parsing {0} nodoc spec files..." -f $specFiles.Count) -ForegroundColor DarkGray

# First pass · parse all specs (so cross-file $ref resolution works)
$allSpecs = @{}
foreach ($f in $specFiles) {
    try {
        $allSpecs[$f.Name] = ConvertFrom-Yaml -Yaml (Get-Content -Raw -LiteralPath $f.FullName)
    } catch {
        Write-Warning "Failed to parse $($f.Name): $($_.Exception.Message)"
    }
}
# Also include common.yml (referenced via cross-file $ref) if present
$commonYml = Join-Path $specsRoot 'common.yml'
if ((Test-Path $commonYml) -and -not $allSpecs.ContainsKey('common.yml')) {
    try { $allSpecs['common.yml'] = ConvertFrom-Yaml -Yaml (Get-Content -Raw -LiteralPath $commonYml) } catch {}
}

# Map operationId → @{ Method · Path · Spec · Example (or derived from schema) }
$opMap = @{}
$exampleHit = 0
$schemaHit  = 0
$specEntries = $allSpecs.GetEnumerator() | Where-Object { $_.Key -ne 'common.yml' }
foreach ($entry in $specEntries) {
    $specName = $entry.Key
    $yaml = $entry.Value
    if ($null -eq $yaml -or -not $yaml.ContainsKey('paths')) { continue }
    $localComponents = if ($yaml.ContainsKey('components')) { $yaml.components } else { @{} }
    foreach ($pathEntry in $yaml.paths.GetEnumerator()) {
        $pathKey = $pathEntry.Key
        $methodsBlock = $pathEntry.Value
        if ($null -eq $methodsBlock -or -not ($methodsBlock -is [System.Collections.IDictionary])) { continue }
        foreach ($methodEntry in $methodsBlock.GetEnumerator()) {
            $method = $methodEntry.Key
            $op = $methodEntry.Value
            if ($null -eq $op -or -not ($op -is [System.Collections.IDictionary])) { continue }
            if (-not $op.ContainsKey('operationId')) { continue }
            $opId = $op.operationId
            $example = $null
            try {
                if ($op.ContainsKey('responses') -and $op.responses.ContainsKey('200')) {
                    $r200 = $op.responses['200']
                    if ($r200.ContainsKey('content') -and $r200.content.ContainsKey('application/json')) {
                        $appJson = $r200.content['application/json']
                        # Priority 1 · explicit example block
                        if ($appJson.ContainsKey('example')) { $example = $appJson.example; $exampleHit++ }
                        # Priority 2 · derive from schema (resolves $ref · walks properties · recursive)
                        elseif ($appJson.ContainsKey('schema')) {
                            $example = ConvertTo-ExampleFromSchema -Schema $appJson.schema -LocalComponents $localComponents -AllSpecs $allSpecs
                            if ($null -ne $example) { $schemaHit++ }
                        }
                    }
                }
            } catch { }
            $opMap[$opId] = @{
                Method  = $method.ToUpperInvariant()
                Path    = $pathKey
                Spec    = $specName
                Example = $example
            }
        }
    }
}
Write-Host ("  Indexed {0} operations · {1} from explicit example · {2} from schema (ref-resolved)" -f $opMap.Count, $exampleHit, $schemaHit) -ForegroundColor DarkGray

# Load Postman collection (3rd schema source · operator correction 2026-05-18)
$postmanMap = @{}
if ($Portal -eq 'Defender' -and (Test-Path $PostmanCollection)) {
    Write-Host "  Parsing Postman collection: $(Split-Path $PostmanCollection -Leaf)" -ForegroundColor DarkGray
    try {
        $col = Get-Content -Raw -LiteralPath $PostmanCollection | ConvertFrom-Json -Depth 100
        $postmanMap = ConvertTo-PostmanOpsMap -CollectionRoot $col
        Write-Host ("    Indexed {0} Postman operations · {1} with response.body" -f $postmanMap.Count, @($postmanMap.Values | Where-Object { $_.Body }).Count) -ForegroundColor DarkGray
    } catch {
        Write-Warning "Failed to parse Postman collection: $($_.Exception.Message)"
    }
}

# Load manifest
$manifest = & ([scriptblock]::Create((Get-Content -Raw -LiteralPath $ManifestPath)))
$entries = @($manifest.Entries)

$stats = @{
    Total                 = $entries.Count
    AlreadyHasCandidates  = 0
    NoOperationMatch      = 0
    NoExample             = 0
    DerivedFromExample    = 0
    DerivedFromPostman    = 0
    NoMatchAnywhere       = 0
}

foreach ($e in $entries) {
    $slug = if ($e.ContainsKey('Slug') -and $e.Slug) { $e.Slug } else {
        $leaf = ($e.NodocRoute -split '\.')[-1]
        if ($leaf -match 'TenantContext$') { 'TenantContext' } else { $leaf }
    }
    $refDir = Join-Path $ReferencesRoot ("{0}/{1}/{2}" -f $Portal, $e.SubArea, $slug)
    $candPath = Join-Path $refDir 'projection-candidates.json'

    if (-not $Force -and (Test-Path $candPath)) { $stats.AlreadyHasCandidates++; continue }

    $opId = $e.NodocRoute
    $inventory = $null
    $provenance = $null

    # Priority 1: nodoc OpenAPI (existing path · explicit example OR schema-walk)
    if ($opMap.ContainsKey($opId)) {
        $op = $opMap[$opId]
        if ($null -ne $op.Example) {
            $inv = Get-JsonFieldInventory -Node $op.Example
            if ($inv -and @($inv).Count -gt 0) {
                $inventory = $inv
                $provenance = 'nodoc-openapi-schema-example'
            }
        }
    }

    # Priority 2: Postman collection (3rd source · operator correction 2026-05-18)
    # Used when OpenAPI lacks example AND endpoint doesn't have a live capture
    if ($null -eq $inventory -and $postmanMap.Count -gt 0) {
        $postmanOp = Resolve-PostmanResponseForEntry -Entry $e -PostmanMap $postmanMap
        if ($postmanOp -and $postmanOp.Body) {
            try {
                $parsed = $postmanOp.Body | ConvertFrom-Json -Depth 30 -ErrorAction SilentlyContinue
                if ($null -ne $parsed) {
                    $inv = Get-JsonFieldInventory -Node $parsed
                    if ($inv -and @($inv).Count -gt 0) {
                        $inventory = $inv
                        $provenance = 'nodoc-postman-response'
                    }
                }
            } catch { }
        }
    }

    if ($null -eq $inventory) {
        if (-not $opMap.ContainsKey($opId)) { $stats.NoOperationMatch++ }
        else { $stats.NoMatchAnywhere++ }
        continue
    }

    $candidates = Get-ProjectionCandidates -FieldInventory $inventory
    if (-not $candidates -or @($candidates).Count -eq 0) { $stats.NoExample++; continue }

    New-Item -ItemType Directory -Path $refDir -Force | Out-Null

    # Tag provenance · operator can distinguish nodoc-OpenAPI-derived vs Postman-derived vs live-derived
    $augmented = $candidates | ForEach-Object {
        [pscustomobject]@{
            ColumnName  = $_.ColumnName
            DslOp       = $_.DslOp
            Path        = $_.Path
            KqlType     = $_.KqlType
            SampleValue = $_.SampleValue
            Provenance  = $provenance
        }
    }
    $augmented | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $candPath -Encoding UTF8
    if ($provenance -eq 'nodoc-openapi-schema-example') { $stats.DerivedFromExample++ }
    elseif ($provenance -eq 'nodoc-postman-response') { $stats.DerivedFromPostman++ }
}

Write-Host ""
Write-Host "Derive-NodocFallback stats:" -ForegroundColor Cyan
Write-Host ("  Total entries:                       {0}" -f $stats.Total)
Write-Host ("  Already had projection-candidates:   {0}" -f $stats.AlreadyHasCandidates)
Write-Host ("  Derived from nodoc OpenAPI example:  {0}" -f $stats.DerivedFromExample) -ForegroundColor Green
Write-Host ("  Derived from nodoc Postman response: {0}" -f $stats.DerivedFromPostman) -ForegroundColor Green
Write-Host ("  No operation match in nodoc OpenAPI: {0}" -f $stats.NoOperationMatch)
Write-Host ("  No example/response found anywhere:  {0}" -f $stats.NoMatchAnywhere)
Write-Host ("  No example block in nodoc OpenAPI:   {0}" -f $stats.NoExample)
$total = [int]$stats.AlreadyHasCandidates + [int]$stats.DerivedFromExample + [int]$stats.DerivedFromPostman
Write-Host ("  TOTAL with projection-candidates:    {0}/{1} ({2:N1}%)" -f $total, $stats.Total, (100.0*$total/$stats.Total)) -ForegroundColor Cyan
