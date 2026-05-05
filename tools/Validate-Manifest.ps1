#Requires -Version 7.0
<#
.SYNOPSIS
    Standalone manifest validator (no Pester dependency).

.DESCRIPTION
    Runs the same schema checks as tests/unit/Manifest.Schema.Tests.ps1 but
    without Pester. Used by editors / pre-commit hooks / CI for fast feedback.

    Validates every entry in src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1:

      1. Stream matches ^MDE_[A-Za-z0-9]+_CL$
      2. Path starts with /apiproxy/ or /api/
      3. Tier is one of: ActionCenter | XspmGraph | Configuration | Inventory | Maintenance
      4. Category is one of the 10 nathanmcnulty taxonomy values
      5. CategoryId is 1..10 and matches Category
      6. Availability is live | tenant-gated | deprecated
      7. Purpose is non-empty + >20 chars
      8. Non-deprecated entries have ProjectionMap with >=3 typed columns
      9. Stream names are unique
     10. (Path, Method, Body) combos are unique

    Plus Defaults block contract.

.PARAMETER ManifestPath
    Path to endpoints.manifest.psd1. Default: src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1

.PARAMETER FailFast
    Stop at first error. Default: collect all errors and report at end.

.EXAMPLE
    pwsh ./tools/Validate-Manifest.ps1
    # Exit 0 = clean; exit 1 = errors

.NOTES
    Designed to run in <2 seconds. No external dependencies.
#>
[CmdletBinding()]
param(
    [string] $ManifestPath,
    [switch] $FailFast
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $ManifestPath) {
    $ManifestPath = Join-Path $repoRoot 'src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1'
}

if (-not (Test-Path $ManifestPath)) {
    Write-Host "ERROR: manifest file not found: $ManifestPath" -ForegroundColor Red
    exit 1
}

$validTiers = @('ActionCenter', 'XspmGraph', 'Configuration', 'Inventory', 'Maintenance')
$validAvailability = @('live', 'tenant-gated', 'deprecated')
$categoryToCategoryId = @{
    'Endpoint Device Management'     = 1
    'Endpoint Configuration'         = 2
    'Vulnerability Management (TVM)' = 3
    'Identity Protection (MDI)'      = 4
    'Configuration and Settings'     = 5
    'Exposure Management (XSPM)'     = 6
    'Threat Analytics'               = 7
    'Action Center'                  = 8
    'Multi-Tenant Operations'        = 9
    'Streaming API'                  = 10
}

$errors = @()
$warnings = @()

function Add-Err {
    param([string]$Stream, [string]$Detail)
    $script:errors += "[$Stream] $Detail"
    if ($FailFast) {
        Write-Host "FAIL-FAST: $Stream - $Detail" -ForegroundColor Red
        Write-Host ""
        Write-Host "Total errors so far: $($script:errors.Count)"
        exit 1
    }
}

# Load manifest
try {
    $manifest = Import-PowerShellDataFile -Path $ManifestPath
} catch {
    Write-Host "ERROR: Manifest failed to parse as PowerShell data file: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

if (-not $manifest.ContainsKey('Endpoints')) {
    Write-Host "ERROR: Manifest missing 'Endpoints' key" -ForegroundColor Red
    exit 1
}
if (-not $manifest.ContainsKey('Defaults')) {
    Write-Host "ERROR: Manifest missing 'Defaults' key" -ForegroundColor Red
    exit 1
}

$endpoints = @($manifest.Endpoints)
Write-Host "Manifest: $($endpoints.Count) entries" -ForegroundColor Cyan

# 1-7: Per-entry field validation
foreach ($e in $endpoints) {
    $stream = if ($e.ContainsKey('Stream')) { $e.Stream } else { '<missing>' }

    # Required fields
    foreach ($field in 'Stream','Path','Tier','Category','CategoryId','Purpose','Availability') {
        if (-not $e.ContainsKey($field) -or [string]::IsNullOrWhiteSpace([string]$e[$field])) {
            Add-Err $stream "Missing required field: $field"
        }
    }
    if (-not $e.ContainsKey('Stream')) { continue }

    # Stream name format
    if ($e.Stream -notmatch '^MDE_[A-Za-z0-9]+_CL$') {
        Add-Err $stream "Stream name '$($e.Stream)' must match ^MDE_[A-Za-z0-9]+_CL$"
    }

    # Path format
    if ($e.ContainsKey('Path') -and $e.Path -notmatch '^/(apiproxy|api)/') {
        Add-Err $stream "Path '$($e.Path)' must start with /apiproxy/ or /api/"
    }

    # Tier
    if ($e.ContainsKey('Tier') -and $validTiers -notcontains $e.Tier) {
        Add-Err $stream "Tier '$($e.Tier)' must be one of: $($validTiers -join ', ')"
    }

    # Category
    if ($e.ContainsKey('Category') -and -not $categoryToCategoryId.ContainsKey($e.Category)) {
        Add-Err $stream "Category '$($e.Category)' is not in the 10-category taxonomy"
    }

    # CategoryId matches Category
    if ($e.ContainsKey('Category') -and $e.ContainsKey('CategoryId') -and $categoryToCategoryId.ContainsKey($e.Category)) {
        $expected = $categoryToCategoryId[$e.Category]
        if ($e.CategoryId -ne $expected) {
            Add-Err $stream "CategoryId=$($e.CategoryId) does not match Category='$($e.Category)' (expected $expected)"
        }
    }

    # Availability
    if ($e.ContainsKey('Availability') -and $validAvailability -notcontains $e.Availability) {
        Add-Err $stream "Availability '$($e.Availability)' must be one of: $($validAvailability -join ', ')"
    }

    # Purpose
    if ($e.ContainsKey('Purpose')) {
        if ([string]::IsNullOrWhiteSpace([string]$e.Purpose) -or ([string]$e.Purpose).Length -lt 20) {
            Add-Err $stream "Purpose too short or empty (must be >20 chars)"
        }
    }

    # ProjectionMap (non-deprecated)
    if ($e.ContainsKey('Availability') -and $e.Availability -ne 'deprecated') {
        if (-not $e.ContainsKey('ProjectionMap') -or $null -eq $e.ProjectionMap) {
            Add-Err $stream "Non-deprecated entry must declare ProjectionMap"
        } elseif (@($e.ProjectionMap.Keys).Count -lt 3) {
            Add-Err $stream "ProjectionMap has only $(@($e.ProjectionMap.Keys).Count) keys (need >=3 for typed columns)"
        }
    }

    # SingleObjectAsRow + UnwrapProperty mutual exclusion
    if ($e.ContainsKey('SingleObjectAsRow') -and $e.SingleObjectAsRow -and $e.ContainsKey('UnwrapProperty')) {
        Add-Err $stream "Cannot have both SingleObjectAsRow=true and UnwrapProperty"
    }
}

# 8: Stream name uniqueness
$names = @($endpoints | ForEach-Object { $_.Stream })
$dupes = $names | Group-Object | Where-Object { $_.Count -gt 1 }
foreach ($d in $dupes) {
    Add-Err $d.Name "Duplicate Stream name appears $($d.Count) times"
}

# 9: (Path, Method, Body) uniqueness
$combos = @{}
foreach ($e in $endpoints) {
    if (-not $e.ContainsKey('Path')) { continue }
    $method = if ($e.ContainsKey('Method')) { $e.Method } else { 'GET' }
    $bodyHash = if ($e.ContainsKey('Body')) {
        ($e.Body | ConvertTo-Json -Compress -Depth 10).GetHashCode().ToString()
    } else { 'no-body' }
    $key = "$method $($e.Path) body=$bodyHash"
    if ($combos.ContainsKey($key)) {
        Add-Err $e.Stream "Duplicate (Path, Method, Body) — also used by $($combos[$key])"
    } else {
        $combos[$key] = $e.Stream
    }
}

# 10: Defaults block contract
$defaults = $manifest.Defaults
foreach ($key in 'IdProperty', 'Portal', 'SchemaSource') {
    if (-not $defaults.ContainsKey($key)) {
        Add-Err 'Defaults' "Missing Defaults baseline key: $key"
    }
}

# Summary
Write-Host ""
if ($errors.Count -eq 0) {
    Write-Host "✓ Manifest is clean ($($endpoints.Count) entries, all schema checks pass)" -ForegroundColor Green
    exit 0
} else {
    Write-Host "✗ $($errors.Count) manifest error(s):" -ForegroundColor Red
    foreach ($e in $errors) { Write-Host "  $e" -ForegroundColor Red }
    exit 1
}
