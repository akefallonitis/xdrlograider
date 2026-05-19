#Requires -Version 7.4
<#
.SYNOPSIS
    Phase φ.H · Build Sentinel Solution V3 package zip (marketplace-submittable structure).

.DESCRIPTION
    Stages Package/manifest.json + Package/SolutionMetadata.json + deploy/
    (mainTemplate.json · createUiDefinition.json · sentinelContent.json) into a temp dir
    matching Microsoft's expected structure for `microsoft/Azure-Sentinel/Solutions/<Name>/Package/X.Y.Z.zip`:

      <Name>/                                  - the solution display name (XdrLogRaider)
        Package/
          createUiDefinition.json             - operator-deploy wizard
          mainTemplate.json                   - ARM template (infra + DCRs + RBAC + FA)
          manifest.json                       - Sentinel Solution V3 schema (this repo's Package/manifest.json)
          SolutionMetadata.json               - publisher + categories + support
        Data Connectors/
          XdrLogRaiderInternal.json           - dataConnectorDefinition (this repo's deploy/sentinelContent.json)

    Output: dist/XdrLogRaider-<Version>.zip (gitignored)

    Subsequent CI step (release.yml · operator-gated) cosign-signs this zip with the
    package-only signature for marketplace submission.

.PARAMETER OutputDir
    Directory to write the zip. Default: dist/

.PARAMETER PackageName
    Solution display name. Default: XdrLogRaider

.PARAMETER Version
    Version string. Default: read from Package/manifest.json

.PARAMETER Clean
    Remove any prior temp staging dir before building.

.EXAMPLE
    pwsh tools/Build-SolutionPackage.ps1
    # Output: dist/XdrLogRaider-1.0.0.zip

.EXAMPLE
    pwsh tools/Build-SolutionPackage.ps1 -Version 1.0.1 -OutputDir build
    # Output: build/XdrLogRaider-1.0.1.zip
#>

[CmdletBinding()]
param(
    [string]$OutputDir   = (Join-Path $PSScriptRoot '..\dist'),
    [string]$PackageName = 'XdrLogRaider',
    [string]$Version,
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Repo paths (relative to this script under tools/)
$repoRoot          = Resolve-Path (Join-Path $PSScriptRoot '..')
$packageManifestPath = Join-Path $repoRoot 'Package\manifest.json'
$solutionMetadataPath = Join-Path $repoRoot 'Package\SolutionMetadata.json'
$logoPath          = Join-Path $repoRoot 'Package\Logo\logo.svg'
$mainTemplatePath  = Join-Path $repoRoot 'deploy\mainTemplate.json'
$createUiPath      = Join-Path $repoRoot 'deploy\createUiDefinition.json'
$sentinelContentPath = Join-Path $repoRoot 'deploy\sentinelContent.json'

Write-Host "Build-SolutionPackage v0.1.0 · Sentinel Solution V3" -ForegroundColor Cyan
Write-Host "  PackageName : $PackageName" -ForegroundColor DarkGray
Write-Host "  Repo root   : $repoRoot" -ForegroundColor DarkGray

# Pre-flight · all source files must exist
$sources = @{
    'Package/manifest.json'         = $packageManifestPath
    'Package/SolutionMetadata.json' = $solutionMetadataPath
    'Package/Logo/logo.svg'         = $logoPath
    'deploy/mainTemplate.json'      = $mainTemplatePath
    'deploy/createUiDefinition.json' = $createUiPath
    'deploy/sentinelContent.json'    = $sentinelContentPath
}
$missing = @()
foreach ($k in $sources.Keys) {
    if (-not (Test-Path $sources[$k])) { $missing += $k }
}
if ($missing.Count -gt 0) {
    throw "Build-SolutionPackage: required source(s) missing: $($missing -join ', ')"
}

# Resolve version from Package/manifest.json if not passed
if (-not $Version) {
    try {
        $pmf = Get-Content -Raw -LiteralPath $packageManifestPath | ConvertFrom-Json
        if ($pmf.PSObject.Properties['Version'] -and $pmf.Version) { $Version = [string]$pmf.Version }
    } catch { }
    if (-not $Version) { $Version = '1.0.0' }
}
Write-Host "  Version     : $Version" -ForegroundColor DarkGray

# Output dir + zip path
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}
$zipName = "{0}-{1}.zip" -f $PackageName, $Version
$zipPath = Join-Path $OutputDir $zipName
if (Test-Path $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

# Stage in temp dir · structure matches microsoft/Azure-Sentinel/Solutions/<Name>/Package/
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("xdrlr-pkg-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$stageRoot = Join-Path $tempRoot $PackageName
if ($Clean -and (Test-Path $tempRoot)) { Remove-Item -Recurse -Force $tempRoot }
$stagePackageDir = Join-Path $stageRoot 'Package'
$stageLogoDir    = Join-Path $stagePackageDir 'Logo'
$stageDataConnDir = Join-Path $stageRoot 'Data Connectors'
New-Item -ItemType Directory -Path $stagePackageDir -Force | Out-Null
New-Item -ItemType Directory -Path $stageLogoDir -Force | Out-Null
New-Item -ItemType Directory -Path $stageDataConnDir -Force | Out-Null

# Copy files to stage
Write-Host ""
Write-Host "Staging files:" -ForegroundColor Cyan
Copy-Item $packageManifestPath  (Join-Path $stagePackageDir 'manifest.json')               -Force; Write-Host "  -> Package/manifest.json"
Copy-Item $solutionMetadataPath (Join-Path $stagePackageDir 'SolutionMetadata.json')      -Force; Write-Host "  -> Package/SolutionMetadata.json"
Copy-Item $logoPath             (Join-Path $stageLogoDir 'logo.svg')                       -Force; Write-Host "  -> Package/Logo/logo.svg"
Copy-Item $mainTemplatePath     (Join-Path $stagePackageDir 'mainTemplate.json')           -Force; Write-Host "  -> Package/mainTemplate.json"
Copy-Item $createUiPath         (Join-Path $stagePackageDir 'createUiDefinition.json')    -Force; Write-Host "  -> Package/createUiDefinition.json"
Copy-Item $sentinelContentPath  (Join-Path $stageDataConnDir 'XdrLogRaiderInternal.json') -Force; Write-Host "  -> Data Connectors/XdrLogRaiderInternal.json"

# Validate Package/manifest.json structure (Sentinel V3 schema · key invariants)
$pmf = Get-Content -Raw -LiteralPath (Join-Path $stagePackageDir 'manifest.json') | ConvertFrom-Json
$required = @('Name','Author','Version','TemplateSpec','Is1PConnector','StaticDataConnectorIds','DataConnectors','ContentSchemaVersion',
              'PublisherId','OfferId','ProviderName','Logo')
foreach ($r in $required) {
    if (-not ($pmf.PSObject.Properties.Name -contains $r)) {
        throw "Package/manifest.json missing required field: $r"
    }
}
if ($pmf.ContentSchemaVersion -ne '3.0.0') {
    Write-Warning "Package/manifest.json ContentSchemaVersion='$($pmf.ContentSchemaVersion)' (expected '3.0.0' for V3 marketplace)"
}
# Logo must be a raw URL (not HTML-wrapped) per V3 spec
if ($pmf.Logo -match '<img\s') {
    throw "Package/manifest.json Logo is HTML <img> tag · V3 schema requires raw URL string. Current value: $($pmf.Logo)"
}

# Validate Package/SolutionMetadata.json V3 schema fields
$smd = Get-Content -Raw -LiteralPath (Join-Path $stagePackageDir 'SolutionMetadata.json') | ConvertFrom-Json
$metaRequired = @('publisherId','offerId','displayName','Version','Logo','firstPublishDate','lastPublishDate','providers','categories','support')
foreach ($r in $metaRequired) {
    if (-not ($smd.PSObject.Properties.Name -contains $r)) {
        throw "Package/SolutionMetadata.json missing required V3 field: $r"
    }
}

# Compress
Write-Host ""
Write-Host "Compressing -> $zipPath" -ForegroundColor Cyan
Compress-Archive -Path $stageRoot -DestinationPath $zipPath -Force
$zipSize = (Get-Item $zipPath).Length
Write-Host ("  zip size: {0:N0} bytes" -f $zipSize) -ForegroundColor DarkGray

# Cleanup temp stage
try { Remove-Item -Recurse -Force $tempRoot -ErrorAction SilentlyContinue } catch {}

Write-Host ""
Write-Host "Build-SolutionPackage: OK" -ForegroundColor Green
Write-Host "  Output: $zipPath" -ForegroundColor Green
Write-Host ("  SHA256: " + (Get-FileHash -Algorithm SHA256 $zipPath).Hash) -ForegroundColor DarkGray
Write-Host ""
Write-Host "Next steps (operator-gated):" -ForegroundColor DarkGray
Write-Host "  · cosign sign-blob --yes --output-signature $zipPath.sig --output-certificate $zipPath.pem $zipPath" -ForegroundColor DarkGray
Write-Host "  · gh release upload <tag> $zipPath $zipPath.sig $zipPath.pem" -ForegroundColor DarkGray

# Return the zip path for downstream pipeline consumption
$zipPath
