#Requires -Version 7.4
<#
.SYNOPSIS
Build Sentinel Content Hub solution package zip · future-ready for Microsoft marketplace submission.

.DESCRIPTION
Per plan v11 §B-build-now decision (no defer · senior-dev rule).

Builds a Microsoft Sentinel Content Hub-compatible .zip from Package/ contents:
  - Package/manifest.json (solution metadata · references the connector definition file)
  - Package/SolutionMetadata.json (publisher · category)
  - Package/dataConnectors/XdrLogRaiderDataConnectorDefinition.json (V3 schema · mirrors ARM inline)
  - Package/Logo/logo.svg (75x75 branding)

Output: artifacts/xdrlograider-solution-v0.1.0.zip

Validation: ensures manifest.json references all listed files · JSON parses · logo exists.

CREATE for v11 per plan §11.3 · cites §B-build-now + §S5 marketplace + §F5 plan iteration.
#>
[CmdletBinding()]
param(
    [string] $PackageRoot = (Join-Path (Resolve-Path "$PSScriptRoot\..").Path 'Package'),
    [string] $OutputDir = (Join-Path (Resolve-Path "$PSScriptRoot\..").Path 'artifacts'),
    [string] $Version = '0.1.0',
    [switch] $Validate
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $PackageRoot)) { Write-Error "Package/ directory not found: $PackageRoot"; exit 1 }
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

$manifestPath = Join-Path $PackageRoot 'manifest.json'
$solutionMetaPath = Join-Path $PackageRoot 'SolutionMetadata.json'
$logoPath = Join-Path $PackageRoot 'Logo/logo.svg'

# ── Validate ──────────────────────────────────────────────────────────────────────
$errors = @()
foreach ($p in @($manifestPath, $solutionMetaPath, $logoPath)) {
    if (-not (Test-Path $p)) { $errors += "missing required file: $p" }
}
if ($errors.Count -gt 0) {
    foreach ($e in $errors) { Write-Error $e }
    exit 1
}

try {
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    $solutionMeta = Get-Content $solutionMetaPath -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
} catch {
    Write-Error "Package JSON parse FAIL: $($_.Exception.Message)"
    exit 1
}

# Verify all `Data Connectors` files referenced in manifest exist
$dcFiles = @($manifest.'Data Connectors')
foreach ($dcRef in $dcFiles) {
    # References are relative paths from repo root (e.g., "Package/dataConnectors/X.json")
    $repoRoot = Split-Path -Parent $PackageRoot
    $dcAbs = Join-Path $repoRoot $dcRef
    if (-not (Test-Path $dcAbs)) {
        Write-Error "manifest.json references non-existent file: $dcRef"
        exit 1
    }
    # Validate it parses
    try {
        $null = Get-Content $dcAbs -Raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Error "data connector JSON parse FAIL ($dcRef): $($_.Exception.Message)"
        exit 1
    }
}

Write-Host '[Build-SolutionPackage] Validation:'
Write-Host "  Manifest        : OK ($(($manifest.Keys | Measure-Object).Count) top-level keys)"
Write-Host "  SolutionMetadata: OK (publisher=$($solutionMeta.publisherId))"
Write-Host "  Logo            : OK ($((Get-Item $logoPath).Length) bytes)"
Write-Host "  Data Connectors : OK ($($dcFiles.Count) files referenced + verified)"

if ($Validate) {
    Write-Host 'Validate-only mode · no zip produced.'
    exit 0
}

# ── Build zip ─────────────────────────────────────────────────────────────────────
$outZip = Join-Path $OutputDir "xdrlograider-solution-v${Version}.zip"
if (Test-Path $outZip) { Remove-Item $outZip -Force }

Write-Host '[Build-SolutionPackage] Building zip...'
$stagingDir = Join-Path $OutputDir 'staging-solution-package'
if (Test-Path $stagingDir) { Remove-Item $stagingDir -Recurse -Force }
New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null

# Copy Package/ contents preserving structure
Copy-Item -Path $PackageRoot -Destination $stagingDir -Recurse -Force

# Compress
Compress-Archive -Path (Join-Path $stagingDir 'Package/*') -DestinationPath $outZip -Force

# Cleanup staging
Remove-Item $stagingDir -Recurse -Force

$sizeMB = [Math]::Round((Get-Item $outZip).Length / 1MB, 3)
$sha256 = (Get-FileHash $outZip -Algorithm SHA256).Hash

Write-Host '[Build-SolutionPackage] Build complete:'
Write-Host "  Output  : $outZip"
Write-Host "  Size    : ${sizeMB} MB"
Write-Host "  SHA-256 : $sha256"
Write-Host ''
Write-Host 'Solution package ready for Sentinel Content Hub submission via Partner Center (Phase F+ marketplace track).'
exit 0
