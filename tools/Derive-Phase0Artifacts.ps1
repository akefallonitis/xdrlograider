<#
.SYNOPSIS
    Phase 0 Step 8 · derive schema/entity/projection artifacts from Step 6 live.json captures.

.DESCRIPTION
    For each `references/<portal>/<sub_area>/<slug>/` dir that has `live.json`:
       schema.json                · typed field inventory (path · jsonType · kqlType · sample value)
       entities.json              · 13 canonical Sentinel entities heuristic match
       projection-candidates.json · ProjectionMap DSL operators (`$tostring:`, `$todatetime:`, ...)
       pagination.json            · hints captured in Step 6
       time-filter.json           · path-query-string hints
       schema-fingerprint.txt     · SHA1 schema signature (Test-Determinism)

    Then builds 8 cross-correlation indices under `references/_index/`:
       1. operationId-to-stream.json
       2. schema-fingerprints.json
       3. entity-coverage.json
       4. provenance-summary.json
       5. capability-to-sub-area.json
       6. cadence-distribution.json
       7. pagination-taxonomy.json
       8. time-filter-coverage.json

    Idempotent · re-runnable · output is byte-identical for same input.

.PARAMETER Portal
    Default 'All' · or restrict.

.PARAMETER OnlyIndices
    Skip per-endpoint derivation · just rebuild indices from existing artifacts.

.PARAMETER OnlyEndpoints
    Skip index rebuild · just derive per-endpoint artifacts.
#>
[CmdletBinding()]
param(
    [ValidateSet('All','Defender','Purview','Entra','Intune','SecurityCopilot')]
    [string] $Portal = 'All',
    [string] $RepoRoot,
    [switch] $OnlyIndices,
    [switch] $OnlyEndpoints
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $RepoRoot) { $RepoRoot = Split-Path $PSScriptRoot -Parent }
. (Join-Path $PSScriptRoot 'lib/Derive-Schema.lib.ps1')

$manifestRoot   = Join-Path $RepoRoot 'manifests'
$referencesRoot = Join-Path $RepoRoot 'references'
$indexRoot      = Join-Path $referencesRoot '_index'
$null = New-Item -ItemType Directory -Path $indexRoot -Force

$portalsToRun = if ($Portal -eq 'All') { @('Defender','Purview','Entra','Intune','SecurityCopilot') } else { @($Portal) }

Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Phase 0 Step 8 · derive schema/entity/projection artifacts" -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan

$globalStats = [ordered]@{
    EndpointsWithLive = 0
    EndpointsTotal    = 0
    SchemaFingerprints = @{}
    EntityCoverage     = @{}
    PaginationHints    = @{}
    TimeFilterHints    = @{}
}

# ─── Per-endpoint derivation ──────────────────────────────────────────────────
if (-not $OnlyIndices) {
    foreach ($p in $portalsToRun) {
        $portalDir = Join-Path $referencesRoot $p
        if (-not (Test-Path $portalDir)) { continue }
        Write-Host ""
        Write-Host "── Portal: $p ──" -ForegroundColor Cyan
        $endpointDirs = Get-ChildItem -Path $portalDir -Recurse -Directory | Where-Object {
            Test-Path (Join-Path $_.FullName 'metadata.json')
        }
        $portalTotal = @($endpointDirs).Count
        $portalLive  = 0
        foreach ($epDir in $endpointDirs) {
            $globalStats.EndpointsTotal++
            $liveFile = Join-Path $epDir.FullName 'live.json'
            if (-not (Test-Path $liveFile)) { continue }
            $globalStats.EndpointsWithLive++
            $portalLive++
            try {
                $live = Get-Content -Raw -LiteralPath $liveFile | ConvertFrom-Json -Depth 12
                $body = $live.Body
                $parsed = $null
                try { $parsed = $body | ConvertFrom-Json -Depth 12 -ErrorAction SilentlyContinue } catch {}
                if ($null -eq $parsed) { continue }

                # Field inventory
                $inventory = Get-JsonFieldInventory -Node $parsed
                $schemaPath = Join-Path $epDir.FullName 'schema.json'
                $inventory | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $schemaPath -Encoding UTF8

                # Entity hints
                $entities = Get-EntityHints -FieldInventory $inventory
                $entitiesPath = Join-Path $epDir.FullName 'entities.json'
                ([ordered]@{
                    EntityHints = $entities
                    NonEmptyCount = @($entities.Keys | Where-Object { $entities[$_].Count -gt 0 }).Count
                }) | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $entitiesPath -Encoding UTF8

                # Projection candidates
                $proj = Get-ProjectionCandidates -FieldInventory $inventory
                $projPath = Join-Path $epDir.FullName 'projection-candidates.json'
                $proj | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $projPath -Encoding UTF8

                # Pagination + time-filter (lifted from live.json)
                ([ordered]@{ Hints = $live.PaginationHints }) | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $epDir.FullName 'pagination.json') -Encoding UTF8
                ([ordered]@{ Hints = $live.TimeFilterHints }) | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $epDir.FullName 'time-filter.json') -Encoding UTF8

                # Schema fingerprint
                $fp = Get-SchemaFingerprint -FieldInventory $inventory
                $fp | Set-Content -LiteralPath (Join-Path $epDir.FullName 'schema-fingerprint.txt') -Encoding UTF8

                # Track for indices
                $globalStats.SchemaFingerprints[$fp] = ($epDir.FullName -replace [regex]::Escape($referencesRoot), '').TrimStart('\','/')
                foreach ($eKey in $entities.Keys) {
                    if ($entities[$eKey].Count -gt 0) {
                        if (-not $globalStats.EntityCoverage.ContainsKey($eKey)) { $globalStats.EntityCoverage[$eKey] = 0 }
                        $globalStats.EntityCoverage[$eKey]++
                    }
                }
                $pagHints = if ($live.PSObject.Properties['PaginationHints']) { @($live.PaginationHints | Where-Object { $_ }) } else { @() }
                foreach ($ph in $pagHints) {
                    if (-not $globalStats.PaginationHints.ContainsKey($ph)) { $globalStats.PaginationHints[$ph] = 0 }
                    $globalStats.PaginationHints[$ph]++
                }
                $tfHints = if ($live.PSObject.Properties['TimeFilterHints']) { @($live.TimeFilterHints | Where-Object { $_ }) } else { @() }
                foreach ($th in $tfHints) {
                    if (-not $globalStats.TimeFilterHints.ContainsKey($th)) { $globalStats.TimeFilterHints[$th] = 0 }
                    $globalStats.TimeFilterHints[$th]++
                }
            } catch {
                Write-Warning "Derive failed for $($epDir.Name): $($_.Exception.Message)"
            }
        }
        Write-Host "  · $portalLive / $portalTotal endpoints derived (others lack live.json)" -ForegroundColor Yellow
    }
}

# ─── 8 cross-correlation indices ──────────────────────────────────────────────
if (-not $OnlyEndpoints) {
    Write-Host ""
    Write-Host "── Building cross-correlation indices ──" -ForegroundColor Cyan

    # Load all manifests + metadata.json for indices
    $allEntries = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($p in @('Defender','Purview','Entra','Intune','SecurityCopilot')) {
        $manifestPath = Join-Path $manifestRoot "$($p.ToLowerInvariant()).psd1"
        if (-not (Test-Path $manifestPath)) { continue }
        $manifest = & ([scriptblock]::Create((Get-Content -Raw -LiteralPath $manifestPath)))
        foreach ($e in $manifest.Entries) {
            $allEntries.Add([pscustomobject]@{
                Portal        = [string]$e.Portal
                SubPortal     = [string]($(if($e.ContainsKey('SubPortal')){$e.SubPortal}else{''}))
                SubArea       = [string]$e.SubArea
                Stream        = [string]$e.Stream
                EntryKey      = [string]$e.EntryKey
                OperationId   = [string]$e.NodocRoute
                Path          = [string]$e.Path
                Method        = [string]$e.Method
                Tier          = [string]$e.Tier
                IngestionMode = [string]($(if($e.ContainsKey('IngestionMode')){$e.IngestionMode}else{''}))
                Cadence       = [string]($(if($e.ContainsKey('Cadence')){$e.Cadence}else{''}))
                Provenance    = [string]$e.Provenance
                AuthScheme    = [string]$e.AuthScheme
                LicenseHint   = [string]$e.LicenseHint
                Capability    = [string]$e.Capability
                ReadSemantics = [string]($(if($e.ContainsKey('ReadSemantics')){$e.ReadSemantics}else{''}))
                ProjectionMapSize = [int]($(if($e.ContainsKey('ProjectionMap') -and $e.ProjectionMap){@($e.ProjectionMap.Keys).Count}else{0}))
            }) | Out-Null
        }
    }

    # Deterministic emitter · sorts hashtable keys + uses [ordered]@{} for stable JSON output.
    function _WriteSortedJson {
        param($Data, [string] $Path)
        if ($Data -is [System.Collections.IDictionary]) {
            $ord = [ordered]@{}
            foreach ($k in ($Data.Keys | Sort-Object)) { $ord[$k] = $Data[$k] }
            $ord | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Path -Encoding UTF8
        } else {
            $Data | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Path -Encoding UTF8
        }
    }

    # 1. operationId-to-stream.json
    $opToStream = @{}
    foreach ($e in $allEntries) { if ($e.OperationId) { $opToStream[$e.OperationId] = $e.Stream } }
    _WriteSortedJson -Data $opToStream -Path (Join-Path $indexRoot 'operationId-to-stream.json')

    # 2. schema-fingerprints.json
    _WriteSortedJson -Data $globalStats.SchemaFingerprints -Path (Join-Path $indexRoot 'schema-fingerprints.json')

    # 3. entity-coverage.json
    _WriteSortedJson -Data $globalStats.EntityCoverage -Path (Join-Path $indexRoot 'entity-coverage.json')

    # 4. provenance-summary.json (deterministic: sort by name)
    $provSummary = @($allEntries | Group-Object Provenance | Sort-Object Name | ForEach-Object { [ordered]@{ Provenance = $_.Name; Count = $_.Count } })
    $provSummary | ConvertTo-Json -Depth 2 | Set-Content -LiteralPath (Join-Path $indexRoot 'provenance-summary.json') -Encoding UTF8

    # 5. capability-to-sub-area.json
    $capToSub = @($allEntries | Group-Object SubArea | Sort-Object Name | ForEach-Object {
        [ordered]@{ SubArea = $_.Name; Portal = ($_.Group | Select-Object -First 1).Portal; EntryCount = $_.Count }
    })
    $capToSub | ConvertTo-Json -Depth 2 | Set-Content -LiteralPath (Join-Path $indexRoot 'capability-to-sub-area.json') -Encoding UTF8

    # 6. cadence-distribution.json · group by Cadence (Phase 0j-enriched) · falls back to Tier when Cadence absent
    $cadenceKey = if ($allEntries.Count -gt 0 -and ($allEntries[0].PSObject.Properties['Cadence']) -and $allEntries[0].Cadence) { 'Cadence' } else { 'Tier' }
    $cadence = @($allEntries | Group-Object $cadenceKey | Sort-Object Name | ForEach-Object { [ordered]@{ ($cadenceKey) = $_.Name; Count = $_.Count } })
    $cadence | ConvertTo-Json -Depth 2 | Set-Content -LiteralPath (Join-Path $indexRoot 'cadence-distribution.json') -Encoding UTF8

    # 7. pagination-taxonomy.json
    _WriteSortedJson -Data $globalStats.PaginationHints -Path (Join-Path $indexRoot 'pagination-taxonomy.json')

    # 8. time-filter-coverage.json
    _WriteSortedJson -Data $globalStats.TimeFilterHints -Path (Join-Path $indexRoot 'time-filter-coverage.json')

    $indexFiles = Get-ChildItem $indexRoot -File
    Write-Host "  · 8 indices built · total $($indexFiles.Count) files" -ForegroundColor Green
}

# ─── Summary ──────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  STEP 8 SUMMARY" -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Endpoints with live.json (derived): $($globalStats.EndpointsWithLive)" -ForegroundColor Green
Write-Host "  Endpoints with metadata.json:        $($globalStats.EndpointsTotal)" -ForegroundColor Yellow
Write-Host "  Indices: 8/8 built (references/_index/)"
if ($globalStats.EntityCoverage.Count -gt 0) {
    Write-Host "  Entity coverage hits:"
    foreach ($k in ($globalStats.EntityCoverage.Keys | Sort-Object { -$globalStats.EntityCoverage[$_] })) {
        Write-Host ("    · {0,-12} {1}" -f $k, $globalStats.EntityCoverage[$k])
    }
}
