#Requires -Version 7.0
<#
.SYNOPSIS
    Packages XdrLogRaider as a Microsoft Sentinel Solution for Content Hub submission.

.DESCRIPTION
    Produces a solution ZIP that matches the Azure-Sentinel/Solutions/<Name>/ layout:
      Analytic Rules/     — 15 YAML files
      Data Connectors/    — connector definition JSON
      Hunting Queries/    — 10 YAML files
      Parsers/            — 6 KQL files
      Workbooks/          — 6 JSON + 6 YAML sidecars
      Images/             — Logo.svg
      Package/
        mainTemplate.json
        createUiDefinition.json
        <version>.zip      ← this file — the solution-installable bundle
      Data/
        Solution_XdrLogRaider.json  — solution generator input
      ReleaseNotes.md
      Solution_README.md

.PARAMETER Version
    Semver version (e.g., 1.0.0).

.PARAMETER OutputRoot
    Where to write the staging folder. Defaults to deploy/solution-staging/.

.EXAMPLE
    ./tools/Build-SentinelSolution.ps1 -Version 1.0.0
#>

[CmdletBinding()]
param(
    [string] $Version = '1.0.0',
    [string] $RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string] $OutputRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $OutputRoot) {
    $OutputRoot = Join-Path $RepoRoot 'deploy' 'solution-staging'
}

$solutionName    = 'XdrLogRaider'
$stagingDir      = Join-Path $OutputRoot $solutionName
$sentinelDir     = Join-Path $RepoRoot 'sentinel'
$deployDir       = Join-Path $RepoRoot 'deploy'

Write-Host "Building Sentinel Solution package v$Version" -ForegroundColor Cyan
Write-Host "  Staging: $stagingDir"

# --- Clean + prepare staging ---

if (Test-Path $stagingDir) {
    Remove-Item -Path $stagingDir -Recurse -Force
}
$dirs = @(
    'Analytic Rules',
    'Data Connectors',
    'Hunting Queries',
    'Parsers',
    'Workbooks',
    'Images',
    'Package',
    'Data'
)
foreach ($d in $dirs) {
    New-Item -ItemType Directory -Path (Join-Path $stagingDir $d) -Force | Out-Null
}

# --- Copy sentinel content ---

Write-Host "`nCopying Sentinel content..." -ForegroundColor Cyan

Copy-Item -Path (Join-Path $sentinelDir 'analytic-rules\*.yaml')   -Destination (Join-Path $stagingDir 'Analytic Rules')  -Force
Copy-Item -Path (Join-Path $sentinelDir 'hunting-queries\*.yaml')  -Destination (Join-Path $stagingDir 'Hunting Queries') -Force
Copy-Item -Path (Join-Path $sentinelDir 'parsers\*.kql')           -Destination (Join-Path $stagingDir 'Parsers')         -Force
Copy-Item -Path (Join-Path $sentinelDir 'workbooks\*.json')        -Destination (Join-Path $stagingDir 'Workbooks')       -Force
Copy-Item -Path (Join-Path $sentinelDir 'workbooks\*.yaml')        -Destination (Join-Path $stagingDir 'Workbooks')       -Force -ErrorAction SilentlyContinue

$arCount = (Get-ChildItem -Path (Join-Path $stagingDir 'Analytic Rules') -Filter *.yaml).Count
$hqCount = (Get-ChildItem -Path (Join-Path $stagingDir 'Hunting Queries') -Filter *.yaml).Count
$pCount  = (Get-ChildItem -Path (Join-Path $stagingDir 'Parsers') -Filter *.kql).Count
$wbCount = (Get-ChildItem -Path (Join-Path $stagingDir 'Workbooks') -Filter *.json).Count

Write-Host "  Analytic rules:  $arCount"
Write-Host "  Hunting queries: $hqCount"
Write-Host "  Parsers:         $pCount"
Write-Host "  Workbooks:       $wbCount"

# --- Data Connectors ---

Copy-Item -Path (Join-Path $deployDir 'solution\Data Connectors\*.json') -Destination (Join-Path $stagingDir 'Data Connectors') -Force

# --- Images ---

Copy-Item -Path (Join-Path $deployDir 'solution\Images\*') -Destination (Join-Path $stagingDir 'Images') -Force -Recurse

# --- Package/ — compiled ARM + createUiDefinition ---

Copy-Item -Path (Join-Path $deployDir 'compiled\mainTemplate.json')     -Destination (Join-Path $stagingDir 'Package')
Copy-Item -Path (Join-Path $deployDir 'compiled\createUiDefinition.json') -Destination (Join-Path $stagingDir 'Package')
Copy-Item -Path (Join-Path $deployDir 'compiled\sentinelContent.json')   -Destination (Join-Path $stagingDir 'Package') -ErrorAction SilentlyContinue

# --- Data/Solution_XdrLogRaider.json — solution generator input ---

$solutionInput = [ordered]@{
    Name        = $solutionName
    Author      = 'Alex Kefallonitis'
    Logo        = '<img src="Images/Logo.svg" width="75px" height="75px">'
    Description = 'XdrLogRaider ingests Defender XDR portal-only telemetry (configuration, compliance, drift, exposure, governance) that is NOT exposed by public Graph Security / Defender XDR / MDE public APIs. 52 streams across 7 compliance tiers; drift detection via pure KQL; 6 workbooks, 15 analytic rules, 10 hunting queries.'
    Workbooks   = @(Get-ChildItem -Path (Join-Path $stagingDir 'Workbooks') -Filter *.json | ForEach-Object { "Workbooks/$($_.Name)" })
    AnalyticalRules = @(Get-ChildItem -Path (Join-Path $stagingDir 'Analytic Rules') -Filter *.yaml | ForEach-Object { "Analytic Rules/$($_.Name)" })
    HuntingQueries  = @(Get-ChildItem -Path (Join-Path $stagingDir 'Hunting Queries') -Filter *.yaml | ForEach-Object { "Hunting Queries/$($_.Name)" })
    Parsers         = @(Get-ChildItem -Path (Join-Path $stagingDir 'Parsers') -Filter *.kql | ForEach-Object { "Parsers/$($_.Name)" })
    DataConnectors  = @(Get-ChildItem -Path (Join-Path $stagingDir 'Data Connectors') -Filter *.json | ForEach-Object { "Data Connectors/$($_.Name)" })
    BasePath        = '.'
    Version         = $Version
    Metadata        = 'SolutionMetadata.json'
    TemplateSpec    = $true
    Is1PConnector   = $false
}
$solutionInputPath = Join-Path $stagingDir 'Data' "Solution_$solutionName.json"
$solutionInput | ConvertTo-Json -Depth 20 | Set-Content -Path $solutionInputPath -Encoding UTF8

# --- SolutionMetadata ---

$metadata = [ordered]@{
    publisherId         = 'akefallonitis'
    offerId             = 'xdrlograider'
    firstPublishDate    = (Get-Date -Format 'yyyy-MM-dd')
    providers           = @('Community')
    categories          = @{
        domains  = @('Security - Threat Protection', 'Security - Cloud Security', 'Compliance')
        verticals = @()
    }
    support             = @{
        tier  = 'Community'
        name  = 'XdrLogRaider community'
        email = ''
        link  = 'https://github.com/akefallonitis/xdrlograider/issues'
    }
    version             = $Version
}
$metadataPath = Join-Path $stagingDir 'SolutionMetadata.json'
$metadata | ConvertTo-Json -Depth 10 | Set-Content -Path $metadataPath -Encoding UTF8

# --- ReleaseNotes + Solution_README ---

$releaseNotes = @"
## XdrLogRaider v$Version

### Highlights
- 55 Defender XDR portal-only telemetry streams
- Two unattended auto-refreshing auth methods: Credentials+TOTP, Software Passkey
- 6 KQL drift parsers, 6 workbooks, 15 analytic rules, 10 hunting queries
- Full documentation + 3-OS CI
- MIT licensed; community-maintained

### Known limitations
- Portal endpoints are undocumented by Microsoft; may be hardened without notice
- Auth chain depends on sccauth cookie pattern (MSRC-acknowledged as intended behavior per April 2026 CloudBrothers disclosure)
- Analytic rules ship disabled; enable selectively after tuning
"@
Set-Content -Path (Join-Path $stagingDir 'ReleaseNotes.md') -Value $releaseNotes -Encoding UTF8

$solutionReadme = Get-Content (Join-Path $RepoRoot 'README.md') -Raw
Set-Content -Path (Join-Path $stagingDir 'Solution_README.md') -Value $solutionReadme -Encoding UTF8

# --- Package into ZIP ---

$zipPath = Join-Path $stagingDir 'Package' "$Version.zip"
Write-Host "`nPackaging solution ZIP: $zipPath" -ForegroundColor Cyan

# Zip the full staging layout (including Package/mainTemplate.json +
# createUiDefinition.json + sentinelContent.json). Exclude only the zip itself
# to avoid self-inclusion on re-runs.
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

$topLevel = Get-ChildItem -Path $stagingDir
$zipInputs = @()
foreach ($entry in $topLevel) {
    if ($entry.PSIsContainer -and $entry.Name -eq 'Package') {
        # inside Package/, include the three compiled JSONs but NOT the <version>.zip
        $jsonFiles = Get-ChildItem -Path $entry.FullName -Filter '*.json'
        $zipInputs += $jsonFiles.FullName
        continue
    }
    $zipInputs += $entry.FullName
}

Compress-Archive -Path $zipInputs -DestinationPath $zipPath -Force

$zipSize = (Get-Item $zipPath).Length
Write-Host "  Solution ZIP: $([int]($zipSize / 1024)) KB" -ForegroundColor Green

# --- Summary ---

Write-Host "`n" + ('=' * 67) -ForegroundColor Green
Write-Host " Sentinel Solution package v$Version built" -ForegroundColor Green
Write-Host ('=' * 67) -ForegroundColor Green
Write-Host "  Staging dir:  $stagingDir"
Write-Host "  Solution zip: $zipPath"
Write-Host ""
Write-Host "  To submit to Content Hub: see docs/SENTINEL-SOLUTION-SUBMISSION.md"
Write-Host "  For self-hosted deploy:   push function-app.zip + Package/*.json to a GitHub release"
Write-Host ""
