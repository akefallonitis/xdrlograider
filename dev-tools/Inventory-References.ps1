#Requires -Version 7.4
<#
.SYNOPSIS
Inventory references/ tree · build per-Portal/Category/Operation coverage matrix.

.DESCRIPTION
Scans references/ subtrees (live · postman · openapi · cross-source/xdrinternals · inventory · contracts)
and produces a coverage matrix showing per-Category data availability across the 4 RAW sources.

Output: references/inventory/<portal>/categories.json + per-Category operations.json + a top-level
coverage-matrix.json that drives dynamic pilot selection (Plan §3.3 + §5.2).

Methodology compliance: NEVER inherit prior catalogue · derive everything from RAW sources at scan time.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path,
    [ValidateSet('Defender','Entra','Intune','Purview','SecurityCopilot','All')]
    [string] $Portal = 'All',
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$refRoot = Join-Path $RepoRoot 'references'
$inventoryRoot = Join-Path $refRoot 'inventory'

function Get-DefenderCategoryFromLivePath {
    param([string]$LiveBasename)
    # Pattern 1: source-final-cross/by-path/<category>__<operation>.json
    if ($LiveBasename -match '^([a-z_]+)__(.+)\.json$') {
        return [pscustomobject]@{ Category = $Matches[1]; Operation = $Matches[2] }
    }
    # Pattern 2: source-xdrlograider-raw/MDE_<Stream>_CL-{raw,ingest}.json
    if ($LiveBasename -match '^MDE_([A-Za-z]+)_CL-(raw|ingest)\.json$') {
        return [pscustomobject]@{ Category = $Matches[1].ToLowerInvariant(); Operation = "MDE_$($Matches[1])_$($Matches[2])" }
    }
    return $null
}

function Get-OpenApiInventoryForPortal {
    param([string]$PortalName)
    $portalKey = switch ($PortalName) {
        'Defender' { 'nodoc-defender-xdr' }
        'Entra'    { 'nodoc-entra' }
        'Intune'   { 'nodoc-intune' }
        'Purview'  { 'nodoc-purview' }
        'SecurityCopilot' { 'nodoc-security-copilot' }
        default { $null }
    }
    if (-not $portalKey) { return @() }
    $specDir = Join-Path $refRoot "openapi/$portalKey/specification"
    if (-not (Test-Path $specDir)) { return @() }
    return Get-ChildItem -Path $specDir -Filter '*.yml' -ErrorAction SilentlyContinue
}

function Test-PostmanHasCategory {
    param([string]$PortalName, [string]$CategoryName)
    $collectionFile = switch ($PortalName) {
        'Defender' { 'defender.collection.json' }
        'Entra'    { 'entra-iam.collection.json' }
        'Intune'   { 'intune-portal.collection.json' }
        'Purview'  { 'purview.collection.json' }
        'SecurityCopilot' { 'security-copilot.collection.json' }
        default { $null }
    }
    if (-not $collectionFile) { return $false }
    $path = Join-Path $refRoot "postman/$collectionFile"
    if (-not (Test-Path $path)) { return $false }
    try {
        $content = Get-Content $path -Raw -ErrorAction Stop
        return ($content -imatch [regex]::Escape($CategoryName))
    } catch { return $false }
}

function Test-XDRInternalsHasReference {
    param([string]$CategoryName)
    $cmdletInv = Join-Path $refRoot 'cross-source/xdrinternals/cmdlet-inventory.md'
    if (-not (Test-Path $cmdletInv)) { return $false }
    $content = Get-Content $cmdletInv -Raw -ErrorAction SilentlyContinue
    if (-not $content) { return $false }
    return ($content -imatch [regex]::Escape($CategoryName))
}

# ─── Build inventory per portal ──────────────────────────────────────────────
$portalsToProcess = if ($Portal -eq 'All') { @('Defender','Entra','Intune','Purview','SecurityCopilot') } else { @($Portal) }
$coverageMatrix = @{
    GeneratedUtc = (Get-Date).ToUniversalTime().ToString('o')
    Portals = @{}
}

foreach ($p in $portalsToProcess) {
    Write-Host "[Inventory] Processing portal: $p"

    # OpenAPI categories
    $openApiFiles = @(Get-OpenApiInventoryForPortal -PortalName $p)
    $openApiCategories = @($openApiFiles | ForEach-Object { $_.BaseName })

    # Live captures by Category (Defender uses 2 directory layouts)
    $liveCategories = @{}
    if ($p -eq 'Defender') {
        # source-final-cross/by-path
        $bypathDir = Join-Path $refRoot 'live/source-final-cross/by-path'
        if (Test-Path $bypathDir) {
            Get-ChildItem -Path $bypathDir -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object {
                $derived = Get-DefenderCategoryFromLivePath -LiveBasename $_.Name
                if ($derived) {
                    if (-not $liveCategories.ContainsKey($derived.Category)) { $liveCategories[$derived.Category] = [System.Collections.Generic.List[string]]::new() }
                    $liveCategories[$derived.Category].Add($derived.Operation)
                }
            }
        }
        # source-xdrlograider-raw
        $rawDir = Join-Path $refRoot 'live/source-xdrlograider-raw'
        if (Test-Path $rawDir) {
            Get-ChildItem -Path $rawDir -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object {
                $derived = Get-DefenderCategoryFromLivePath -LiveBasename $_.Name
                if ($derived) {
                    if (-not $liveCategories.ContainsKey($derived.Category)) { $liveCategories[$derived.Category] = [System.Collections.Generic.List[string]]::new() }
                    $liveCategories[$derived.Category].Add($derived.Operation)
                }
            }
        }
    }

    # Build per-Category coverage
    $allCategories = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($oa in $openApiCategories) { $null = $allCategories.Add($oa) }
    foreach ($lc in $liveCategories.Keys) { $null = $allCategories.Add($lc) }

    $categoryCoverage = @{}
    foreach ($cat in $allCategories) {
        $liveOps = if ($liveCategories.ContainsKey($cat)) { @($liveCategories[$cat] | Select-Object -Unique).Count } else { 0 }
        $hasOpenApi = ($openApiCategories -icontains $cat)
        $hasPostman = Test-PostmanHasCategory -PortalName $p -CategoryName $cat
        $hasXdrInternals = Test-XDRInternalsHasReference -CategoryName $cat

        $categoryCoverage[$cat] = @{
            LiveOperationCount  = $liveOps
            HasOpenApi          = $hasOpenApi
            HasPostman          = $hasPostman
            HasXDRInternals     = $hasXdrInternals
            Sources             = @(
                if ($liveOps -gt 0) { 'live' }
                if ($hasPostman)    { 'postman' }
                if ($hasOpenApi)    { 'openapi' }
                if ($hasXdrInternals) { 'xdrinternals' }
            )
        }
    }

    $coverageMatrix.Portals[$p] = @{
        OpenApiCategoryCount = $openApiCategories.Count
        LiveCategoryCount    = $liveCategories.Count
        Categories           = $categoryCoverage
    }
}

# ─── Write coverage matrix ──────────────────────────────────────────────────
$null = New-Item -ItemType Directory -Path $inventoryRoot -Force -ErrorAction SilentlyContinue
$matrixPath = Join-Path $inventoryRoot 'coverage-matrix.json'
$coverageMatrix | ConvertTo-Json -Depth 10 | Out-File -FilePath $matrixPath -Encoding utf8
Write-Host "[Inventory] Wrote coverage matrix: $matrixPath"

# Summary
foreach ($p in $coverageMatrix.Portals.Keys) {
    $portalData = $coverageMatrix.Portals[$p]
    Write-Host "[Inventory] $p · $($portalData.OpenApiCategoryCount) OpenAPI Categories · $($portalData.LiveCategoryCount) with live captures"
    $top = $portalData.Categories.GetEnumerator() | Sort-Object { -$_.Value.LiveOperationCount } | Select-Object -First 5
    foreach ($entry in $top) {
        $srcCount = @($entry.Value.Sources).Count
        Write-Host "    · $($entry.Key) · live ops=$($entry.Value.LiveOperationCount) · sources=$srcCount [$($entry.Value.Sources -join ',')]"
    }
}

Write-Host ''
Write-Host '[Inventory] DONE · coverage matrix drives Plan §3.3 dynamic pilot selection'
