#Requires -Version 7.4
<#
.SYNOPSIS
    Backfill references/<portal>/<sub-area>/<slug>/{live.json,metadata.json} from
    existing tests/fixtures/live/<slug>/{response.json,meta.json}.

.DESCRIPTION
    The Capture-EndpointSchemas tool dual-writes both the test-fixture layout AND the
    Derive-Phase0Artifacts-expected references/ layout. For endpoints captured before
    the dual-write feature landed (or for fixtures hand-copied from another source),
    this script rehydrates the references/ layout from the existing fixtures.

    Idempotent · safe to run multiple times · only writes when references/ file missing.

.PARAMETER Portal
    Default 'Defender'. Used to resolve manifest and write to references/<portal>/.

.EXAMPLE
    pwsh tools/Rehydrate-References.ps1 -Portal Defender
#>
[CmdletBinding()]
param(
    [string]$Portal       = 'Defender',
    [string]$ManifestPath,
    [string]$FixtureRoot  = (Join-Path $PSScriptRoot '..\tests\fixtures\live'),
    [string]$ReferencesRoot = (Join-Path $PSScriptRoot '..\references')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $ManifestPath) {
    $ManifestPath = Join-Path $PSScriptRoot ("..\manifests\{0}.psd1" -f $Portal.ToLowerInvariant())
}
$manifest = & ([scriptblock]::Create((Get-Content -Raw -LiteralPath $ManifestPath)))
$entries = if ($manifest.ContainsKey('Entries')) { @($manifest.Entries) } else { @($manifest.Endpoints) }

# Build slug → entry map (with Slug derived from NodocRoute leaf for candidate shape)
function Get-EntrySlug {
    param($Entry)
    if ($Entry.PSObject.Properties['Slug'] -and $Entry.Slug) { return $Entry.Slug }
    if ($Entry.ContainsKey('Slug') -and $Entry.Slug) { return $Entry.Slug }
    if ($Entry.ContainsKey('NodocRoute') -and $Entry.NodocRoute) {
        $leaf = ($Entry.NodocRoute -split '\.')[-1]
        if ($leaf -match 'TenantContext$') { return 'TenantContext' }
        return $leaf
    }
    return $Entry.EntryKey
}

$bySlug = @{}
foreach ($e in $entries) {
    $slug = Get-EntrySlug $e
    if (-not $bySlug.ContainsKey($slug)) { $bySlug[$slug] = $e }
}

$stats = @{ Rehydrated = 0; Skipped = 0; NoFixture = 0; NoEntry = 0 }
$fixtureDirs = Get-ChildItem -Path $FixtureRoot -Directory -ErrorAction SilentlyContinue
foreach ($fxd in $fixtureDirs) {
    $slug = $fxd.Name
    # Skip portal-level smoke dirs from Probe-Auth-Local (Defender/Entra/Intune/Purview/SecurityCopilot)
    if ($slug -in 'Defender','Entra','Intune','Purview','SecurityCopilot') { continue }
    $metaFx = Join-Path $fxd.FullName 'meta.json'
    $respFx = Join-Path $fxd.FullName 'response.json'
    if (-not (Test-Path $metaFx)) { $stats.NoFixture++; continue }
    if (-not $bySlug.ContainsKey($slug)) {
        Write-Host "  ! No manifest entry for slug '$slug' · skipping" -ForegroundColor DarkYellow
        $stats.NoEntry++; continue
    }
    $entry = $bySlug[$slug]
    $meta = Get-Content -Raw -LiteralPath $metaFx | ConvertFrom-Json
    $refDir = Join-Path $ReferencesRoot ("{0}/{1}/{2}" -f $Portal, $entry.SubArea, $slug)
    $metaRefPath = Join-Path $refDir 'metadata.json'
    $liveRefPath = Join-Path $refDir 'live.json'
    if ((Test-Path $metaRefPath) -and (Test-Path $liveRefPath)) {
        $stats.Skipped++
        continue
    }
    New-Item -ItemType Directory -Path $refDir -Force | Out-Null

    # metadata.json (always)
    @{
        Portal          = $Portal
        SubArea         = $entry.SubArea
        Slug            = $slug
        EntryKey        = $entry.EntryKey
        Path            = $entry.Path
        Method          = $entry.Method
        NodocRoute      = if ($entry.ContainsKey('NodocRoute')) { $entry.NodocRoute } else { '' }
        IngestionMode   = if ($entry.ContainsKey('IngestionMode')) { $entry.IngestionMode } else { '' }
        Capability      = if ($entry.ContainsKey('Capability')) { $entry.Capability } else { '' }
        LicenseHint     = if ($entry.ContainsKey('LicenseHint')) { $entry.LicenseHint } else { '' }
        Classification  = if ($meta.PSObject.Properties['classification']) { $meta.classification } else { 'unknown' }
        StatusCode      = if ($meta.PSObject.Properties['statusCode']) { $meta.statusCode } else { $null }
        CapturedAt      = if ($meta.PSObject.Properties['capturedAt']) { $meta.capturedAt } else { (Get-Date).ToUniversalTime().ToString('o') }
        ConnectorVersion = '0.1.0'
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $metaRefPath -Encoding UTF8

    # live.json (only for live or live-empty)
    if ($meta.classification -in 'live','live-empty' -and (Test-Path $respFx)) {
        $rawBody = Get-Content -Raw -LiteralPath $respFx
        @{
            Body            = $rawBody
            StatusCode      = if ($meta.PSObject.Properties['statusCode']) { $meta.statusCode } else { 200 }
            ContentType     = 'application/json'
            PaginationHints = if ($meta.PSObject.Properties['paginationHints']) { @($meta.paginationHints) } else { @() }
            TimeFilterHints = if ($meta.PSObject.Properties['timeFilterHints']) { @($meta.timeFilterHints) } else { @() }
            CapturedAt      = if ($meta.PSObject.Properties['capturedAt']) { $meta.capturedAt } else { (Get-Date).ToUniversalTime().ToString('o') }
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $liveRefPath -Encoding UTF8
    }
    $stats.Rehydrated++
}

Write-Host ""
Write-Host "Rehydrate-References complete · Portal=$Portal" -ForegroundColor Cyan
Write-Host ("  Rehydrated: {0}" -f $stats.Rehydrated) -ForegroundColor Green
Write-Host ("  Skipped (already-present): {0}" -f $stats.Skipped) -ForegroundColor DarkGray
Write-Host ("  No fixture meta.json: {0}" -f $stats.NoFixture) -ForegroundColor DarkYellow
Write-Host ("  No manifest entry: {0}" -f $stats.NoEntry) -ForegroundColor DarkYellow
