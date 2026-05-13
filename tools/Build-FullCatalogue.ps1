# Build-FullCatalogue.ps1
#
# Builds references/_FULL_CATALOGUE.md — exhaustive per-portal-per-sub-area-per-endpoint
# reference for Phase 1 manifest builder. Aggregates from:
#   - references/<portal>/<sub-area>/<endpoint>/metadata.json   (path, methods, params, pagination, time-filter, entities, cadence)
#   - references/<portal>/<sub-area>/<endpoint>/live.json       (httpStatus, successKind, rowCount, responseShape)
#   - references/<portal>/<sub-area>/_SUBAREA_ENRICHED.json     (aggregate cadence, production scale)
#   - references/<portal>/_AUTH_RESEARCH.json                   (bucket, clientId, audience, apiBase)
#   - xdrlograider/.internal/nodoc-reference/postman/collections/<portal>.collection.json   (postman fallback)
#   - xdrlograider/.internal/nodoc-reference/specifications/nodoc-<portal>/specification/*.yml   (nodoc source)
#
# Read-only. Produces a single _FULL_CATALOGUE.md (large but navigable).

#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$ReferencesRoot = "$PSScriptRoot\..\references",
    [string]$NodocRoot      = "$PSScriptRoot\..\..\xdrlograider\.internal\nodoc-reference",
    [string]$OutputPath     = "$PSScriptRoot\..\references\_FULL_CATALOGUE.md"
)

$ErrorActionPreference = 'Stop'

# Postman + nodoc reference paths per portal (best-effort mapping; nodoc uses different naming)
$nodocPortalMap = @{
    'defender'             = 'nodoc-defender-xdr'
    'entra-b2c'            = 'nodoc-entra-b2c'
    'entra-ibiza-iam'      = 'nodoc-ibiza-iam'
    'entra-idgov'          = 'nodoc-entra-idgov'
    'entra-iga'            = 'nodoc-entra-iga'
    'entra-pim'            = 'nodoc-entra-pim'
    'exchange'             = 'nodoc-exchange-beta'
    'intune-autopatch'     = 'nodoc-intune-autopatch'
    'intune-portal'        = 'nodoc-intune-portal'
    'm365-admin'           = 'nodoc-m365-admin'
    'm365-apps-config'     = 'nodoc-m365-apps-config'
    'm365-apps-inventory'  = 'nodoc-m365-apps-inventory'
    'm365-apps-services'   = 'nodoc-m365-apps-services'
    'power-platform'       = 'nodoc-power-platform'
    'purview'              = 'nodoc-purview'
    'purview-portal'       = 'nodoc-purview-portal'
    'security-copilot'     = 'nodoc-security-copilot'
    'sharepoint'           = 'nodoc-sharepoint-admin'
    'teams'                = 'nodoc-teams'
    'viva'                 = 'nodoc-viva-engage'
}

$postmanPortalMap = @{
    'defender'             = 'defender'
    'entra-b2c'            = 'entra-b2c'
    'entra-ibiza-iam'      = 'entra-iam'
    'entra-idgov'          = 'entra-idgov'
    'entra-iga'            = 'entra-iga'
    'entra-pim'            = 'entra-pim'
    'exchange'             = 'exchange-beta'
    'intune-autopatch'     = 'intune-autopatch'
    'intune-portal'        = 'intune-portal'
    'm365-admin'           = 'm365-admin'
    'm365-apps-config'     = 'm365-apps-config'
    'm365-apps-inventory'  = 'm365-apps-inventory'
    'm365-apps-services'   = 'm365-apps-services'
    'power-platform'       = 'power-platform'
    'purview'              = 'purview'
    'purview-portal'       = 'purview-portal'
    'security-copilot'     = 'security-copilot'
    'sharepoint'           = 'sharepoint-admin'
    'teams'                = 'teams'
    'viva'                 = 'viva-engage'
}

# Phase 1 in-scope sub-areas (Defender only)
$phase1InScope = @(
    'action_center','attack_simulator','cloud_apps','configuration','data_lake',
    'endpoint_configuration','endpoint_devices','entity_pivots','exposure_management',
    'files','identity','multi_tenant','portal_services','secure_score',
    'sentinel_precision','streaming','threat_analytics','vulnerability_management'
)

$phase1WholesaleExcluded = @('advanced_hunting','alerts_incidents','live_response','common')

# Read-semantics classifier (operationId/slug → read/write/unknown)
$readPrefixes  = @('List','Get','Query','Search','Filter','Export','Probe','Fetch','Read','Inspect','Audit','Find','Resolve','Validate','Check','Test')
$writePrefixes = @('Create','Update','Delete','Save','Add','Remove','Move','Patch','Modify','Submit','Invoke','Run','Refresh','Reset','Reload','Reboot','Trigger','Send','Post','Put','Push','Apply','Approve','Reject','Suppress','Unsuppress','Disable','Enable','Override','Set')

function Get-ReadSemantics {
    param([string]$Slug, [string]$OperationId)
    $name = if ($OperationId) { $OperationId -replace '^[^.]+\.', '' } else { $Slug }
    foreach ($p in $readPrefixes)  { if ($name -clike "$p*") { return 'read'  } }
    foreach ($p in $writePrefixes) { if ($name -clike "$p*") { return 'write' } }
    return 'unknown'
}

function Format-MethodList {
    param($Methods)
    if (-not $Methods) { return '?' }
    return ($Methods | ForEach-Object { $_.ToUpper() }) -join '/'
}

function Format-PaginationCell {
    param($P)
    if (-not $P) { return 'none' }
    if ($P.style -and $P.style -ne 'none') {
        $params = @()
        if ($P.indexParam) { $params += "idx=$($P.indexParam)" }
        if ($P.sizeParam)  { $params += "size=$($P.sizeParam)" }
        if ($P.tokenParam) { $params += "tok=$($P.tokenParam)" }
        $suffix = if ($params.Count -gt 0) { ' (' + ($params -join ',') + ')' } else { '' }
        return "$($P.style)$suffix"
    }
    return 'none'
}

function Format-TimeFilterCell {
    param($T)
    if (-not $T -or -not $T.supported) { return '-' }
    $parts = @()
    if ($T.startParam)   { $parts += "start=$($T.startParam)" }
    if ($T.endParam)     { $parts += "end=$($T.endParam)" }
    if ($T.lookbackParam){ $parts += "lookback=$($T.lookbackParam)" }
    if ($T.type)         { $parts += "type=$($T.type)" }
    return ($parts -join ' ')
}

function Format-EntitiesCell {
    param($E)
    if (-not $E -or $E.Count -eq 0) { return '-' }
    return ($E | Select-Object -First 3) -join ', '
}

function Format-LiveCell {
    param($L)
    if (-not $L) { return 'unprobed' }
    $kind = if ($L.successKind) { $L.successKind } else { 'unprobed' }
    $http = if ($L.httpStatus)  { "[$($L.httpStatus)]" } else { '' }
    $rows = if ($L.rowCount -ne $null) { " r=$($L.rowCount)" } else { '' }
    return "$kind$http$rows"
}

# ---------------------------------------------------------------------------
# Build output
# ---------------------------------------------------------------------------
$now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
$md = New-Object System.Collections.Generic.List[string]
[void]$md.Add("# XdrLogRaider v2 — Full Phase 0 Catalogue")
[void]$md.Add("")
[void]$md.Add("**Generated:** $now UTC")
[void]$md.Add('**Source:** disk-aggregated from `references/<portal>/<sub-area>/<endpoint>/metadata.json` + `live.json` + `_SUBAREA_ENRICHED.json` + `_AUTH_RESEARCH.json` + cross-referenced with vendored nodoc OpenAPI + Postman collections.')
[void]$md.Add('**Purpose:** core reference for Phase 1 manifest builder. Wins over `_CATALOGUE_INDEX.md` (legacy summary) on conflict.')
[void]$md.Add("")
[void]$md.Add("Format conventions:")
[void]$md.Add('- ReadSemantics column: `read` (List/Get/Query/Search/Filter/Export/Probe/Fetch/Read/Inspect/Audit/Find/Resolve/Validate/Check/Test) · `write` (Create/Update/Delete/Save/Add/Remove/Move/Patch/Modify/Submit/Invoke/Run/Refresh/Reset/Reload/Reboot/Trigger/Send/Post/Put/Push/Apply/Approve/Reject/Suppress/Unsuppress/Disable/Enable/Override/Set) · `unknown` else')
[void]$md.Add('- Pagination column: `style (idx=...,size=...,tok=...)` or `none`')
[void]$md.Add('- TimeFilter column: `start=... end=... lookback=... type=...` or `-`')
[void]$md.Add('- Entities column: top 3 Sentinel-compatible entity hints (`Host.MdatpId`, `Account.UPN`, etc.) — see Enrich-Entities-Parsing-Value.ps1 mapping')
[void]$md.Add('- Live column: `successKind[httpStatus] r=rowCount` or `unprobed`')
[void]$md.Add('- Phase 1 in-scope sub-areas marked with [P1]; wholesale-excluded with [EXCL]')
[void]$md.Add("")
[void]$md.Add("---")
[void]$md.Add("")

# Global tally pass
$globalEps = 0; $globalLive = 0; $globalWrites = 0; $globalUnknowns = 0
$portalsAll = @()
$portalDirs = Get-ChildItem -Path $ReferencesRoot -Directory | Sort-Object Name
foreach ($pDir in $portalDirs) {
    $epCount = 0; $liveCount = 0
    Get-ChildItem -Path $pDir.FullName -Recurse -Filter 'metadata.json' -ErrorAction SilentlyContinue | ForEach-Object {
        $epCount++
        $liveFile = Join-Path $_.Directory.FullName 'live.json'
        if (Test-Path $liveFile) {
            try {
                $lj = Get-Content $liveFile -Raw | ConvertFrom-Json
                if ($lj.successKind -eq 'live') { $liveCount++ }
            } catch {}
        }
    }
    $globalEps += $epCount
    $globalLive += $liveCount
    $portalsAll += [pscustomobject]@{ Portal = $pDir.Name; Endpoints = $epCount; Live = $liveCount }
}

[void]$md.Add("## Global tally")
[void]$md.Add("")
[void]$md.Add("- **Portals:** $($portalsAll.Count)")
[void]$md.Add("- **Endpoints:** $globalEps")
[void]$md.Add("- **Live-captured:** $globalLive")
[void]$md.Add("- **Postman collections:** $((Get-ChildItem -Path "$NodocRoot\postman\collections" -Filter '*.collection.json' -ErrorAction SilentlyContinue).Count)")
[void]$md.Add("- **Nodoc OpenAPI portal specs:** $((Get-ChildItem -Path "$NodocRoot\specifications" -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'nodoc-*' }).Count)")
[void]$md.Add("")
[void]$md.Add("| Portal | Endpoints | Live | Phase 1 in-scope |")
[void]$md.Add("|---|---:|---:|---|")
foreach ($p in $portalsAll) {
    $p1 = if ($p.Portal -eq 'defender') { 'YES (18 sub-areas)' } else { 'No (v0.2.0+ scope)' }
    [void]$md.Add("| $($p.Portal) | $($p.Endpoints) | $($p.Live) | $p1 |")
}
[void]$md.Add("")

# Per-portal sections
foreach ($pDir in $portalDirs) {
    $portal = $pDir.Name
    Write-Host "Processing portal: $portal" -ForegroundColor Cyan

    # Read auth research
    $authFile = Join-Path $pDir.FullName '_AUTH_RESEARCH.json'
    $auth = $null
    if (Test-Path $authFile) {
        try { $auth = Get-Content $authFile -Raw | ConvertFrom-Json } catch {}
    }

    # Source references
    $nodocDir   = if ($nodocPortalMap[$portal])   { Join-Path $NodocRoot "specifications\$($nodocPortalMap[$portal])\specification" } else { $null }
    $postmanFile= if ($postmanPortalMap[$portal]) { Join-Path $NodocRoot "postman\collections\$($postmanPortalMap[$portal]).collection.json" } else { $null }
    $hasPostman = $postmanFile -and (Test-Path $postmanFile)
    $hasNodoc   = $nodocDir -and (Test-Path $nodocDir)

    [void]$md.Add("---")
    [void]$md.Add("")
    [void]$md.Add("## Portal: ``$portal``")
    [void]$md.Add("")

    # Auth header
    if ($auth -and $auth.authModel) {
        [void]$md.Add("### Auth")
        [void]$md.Add("")
        [void]$md.Add("| Field | Value |")
        [void]$md.Add("|---|---|")
        [void]$md.Add("| Bucket | $($auth.authModel.bucket) |")
        [void]$md.Add("| ClientId | ``$($auth.authModel.clientId)`` |")
        [void]$md.Add("| Audience | ``$($auth.authModel.audience)`` |")
        [void]$md.Add("| ApiBase | ``$($auth.authModel.apiBase)`` |")
        if ($auth.authModel.headers) {
            $hdrs = ($auth.authModel.headers.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '; '
            [void]$md.Add("| Required headers | ``$hdrs`` |")
        }
        [void]$md.Add("")
    }

    # Source references
    [void]$md.Add("### Source references")
    [void]$md.Add("")
    [void]$md.Add("- **Nodoc OpenAPI:** ``$nodocDir`` ($(if($hasNodoc){'present'}else{'MISSING'}))")
    [void]$md.Add("- **Postman collection:** ``$postmanFile`` ($(if($hasPostman){'present'}else{'MISSING'}))")
    [void]$md.Add("")

    # Sub-areas
    $subDirs = Get-ChildItem -Path $pDir.FullName -Directory -ErrorAction SilentlyContinue | Sort-Object Name
    if ($subDirs.Count -eq 0) {
        [void]$md.Add("_(no sub-areas)_")
        [void]$md.Add("")
        continue
    }

    [void]$md.Add("### Sub-areas: $($subDirs.Count) · Endpoints: $($portalsAll | Where-Object Portal -eq $portal | Select-Object -ExpandProperty Endpoints) · Live: $($portalsAll | Where-Object Portal -eq $portal | Select-Object -ExpandProperty Live)")
    [void]$md.Add("")

    foreach ($sa in $subDirs) {
        $subArea = $sa.Name

        # Tag: Phase 1 in-scope, wholesale-excluded, or v0.2.0
        $tag = if ($portal -eq 'defender') {
            if ($subArea -in $phase1InScope) { '[P1]' }
            elseif ($subArea -in $phase1WholesaleExcluded) { '[EXCL]' }
            else { '[?]' }
        } else { '[v0.2.0+]' }

        # Read sub-area enriched aggregate
        $saEnrichedFile = Join-Path $sa.FullName '_SUBAREA_ENRICHED.json'
        $saEnriched = $null
        if (Test-Path $saEnrichedFile) {
            try { $saEnriched = Get-Content $saEnrichedFile -Raw | ConvertFrom-Json } catch {}
        }

        # Iterate endpoints
        $epDirs = Get-ChildItem -Path $sa.FullName -Directory -ErrorAction SilentlyContinue | Sort-Object Name
        if ($epDirs.Count -eq 0) { continue }

        [void]$md.Add("#### ``$subArea`` $tag")
        [void]$md.Add("")

        if ($saEnriched) {
            $paginDist = ($saEnriched.paginationDistribution.PSObject.Properties | ForEach-Object { "$($_.Name):$($_.Value)" }) -join ' / '
            $topEnts = if ($saEnriched.topEntities) { ($saEnriched.topEntities | Select-Object -First 5) -join ', ' } else { '-' }
            $prod = $saEnriched.productionScale
            $prodCell = if ($prod) { "$($prod.VolumeLargeT) · risk=$($prod.RateLimitRisk) · delta=$($prod.DeltaPollPriority)" } else { '-' }
            [void]$md.Add("**Sub-area summary:** $($epDirs.Count) endpoints · cadence=$($saEnriched.cadenceSuggestion) · pagination=$paginDist · time-filter coverage=$($saEnriched.timeFilterEndpointCount)/$($epDirs.Count) · top entities=$topEnts · production scale=$prodCell")
        } else {
            [void]$md.Add("**Sub-area summary:** $($epDirs.Count) endpoints (no _SUBAREA_ENRICHED.json)")
        }
        [void]$md.Add("")
        [void]$md.Add("| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |")
        [void]$md.Add("|---|---|---|---|---|---|---|---|---|")

        $epRows = @()
        foreach ($epDir in $epDirs) {
            $metaFile = Join-Path $epDir.FullName 'metadata.json'
            if (-not (Test-Path $metaFile)) { continue }
            try {
                $m = Get-Content $metaFile -Raw | ConvertFrom-Json
            } catch { continue }

            $liveFile = Join-Path $epDir.FullName 'live.json'
            $live = $null
            if (Test-Path $liveFile) {
                try { $live = Get-Content $liveFile -Raw | ConvertFrom-Json } catch {}
            }

            $rs = Get-ReadSemantics -Slug $m.slug -OperationId $m.operationId
            $methodsCell = Format-MethodList $m.methods
            $paginCell   = Format-PaginationCell $m.pagination
            $tfCell      = Format-TimeFilterCell $m.timeFilter
            $entCell     = Format-EntitiesCell $m.entities
            $cadenceCell = if ($m.cadenceSuggestion) { $m.cadenceSuggestion } else { '-' }
            $liveCell    = Format-LiveCell $live

            # Truncate long paths
            $pathDisplay = if ($m.path.Length -gt 60) { '...' + $m.path.Substring($m.path.Length - 57) } else { $m.path }

            $epRows += [pscustomobject]@{
                Slug         = $m.slug
                Path         = $pathDisplay
                Methods      = $methodsCell
                ReadSemantics= $rs
                Pagination   = $paginCell
                TimeFilter   = $tfCell
                Entities     = $entCell
                Cadence      = $cadenceCell
                Live         = $liveCell
            }
        }

        $epRows | Sort-Object Slug | ForEach-Object {
            [void]$md.Add("| $($_.Slug) | ``$($_.Path)`` | $($_.Methods) | $($_.ReadSemantics) | $($_.Pagination) | $($_.TimeFilter) | $($_.Entities) | $($_.Cadence) | $($_.Live) |")
        }
        [void]$md.Add("")
    }
}

# ---------------------------------------------------------------------------
# Footer: ReadSemantics distribution + write-shaped + unknown
# ---------------------------------------------------------------------------
[void]$md.Add("---")
[void]$md.Add("")
[void]$md.Add("## Appendix A — ReadSemantics distribution (Defender only)")
[void]$md.Add("")

$defenderEps = @()
foreach ($epDir in Get-ChildItem -Path "$ReferencesRoot\defender" -Recurse -Filter 'metadata.json' -ErrorAction SilentlyContinue) {
    try {
        $m = Get-Content $epDir.FullName -Raw | ConvertFrom-Json
        $rs = Get-ReadSemantics -Slug $m.slug -OperationId $m.operationId
        $defenderEps += [pscustomobject]@{ Slug = $m.slug; SubArea = $m.subArea; ReadSemantics = $rs }
    } catch {}
}
$rsDist = $defenderEps | Group-Object ReadSemantics | ForEach-Object { "$($_.Name): $($_.Count)" }
[void]$md.Add("- $($rsDist -join ' · ')")
[void]$md.Add("")

[void]$md.Add("### Write-shaped endpoints in Defender (must exclude from Phase 1 manifest)")
[void]$md.Add("")
[void]$md.Add("| Sub-area | Slug |")
[void]$md.Add("|---|---|")
$defenderEps | Where-Object ReadSemantics -eq 'write' | Sort-Object SubArea,Slug | ForEach-Object {
    [void]$md.Add("| $($_.SubArea) | $($_.Slug) |")
}
[void]$md.Add("")

[void]$md.Add("### Unknown-classification endpoints in Defender (need manual review)")
[void]$md.Add("")
[void]$md.Add("| Sub-area | Slug |")
[void]$md.Add("|---|---|")
$defenderEps | Where-Object ReadSemantics -eq 'unknown' | Sort-Object SubArea,Slug | ForEach-Object {
    [void]$md.Add("| $($_.SubArea) | $($_.Slug) |")
}
[void]$md.Add("")

# Cadence + production scale map (Defender)
[void]$md.Add("## Appendix B — Cadence + production-scale map (Defender Phase 1)")
[void]$md.Add("")
[void]$md.Add("| Sub-area | Cadence | Pagination distribution | Time-filter coverage | Top entities | Production scale |")
[void]$md.Add("|---|---|---|---|---|---|")
foreach ($sa in (Get-ChildItem -Path "$ReferencesRoot\defender" -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
    $saEnrFile = Join-Path $sa.FullName '_SUBAREA_ENRICHED.json'
    if (-not (Test-Path $saEnrFile)) { continue }
    try {
        $e = Get-Content $saEnrFile -Raw | ConvertFrom-Json
    } catch { continue }
    $paginDist = if ($e.paginationDistribution) {
        ($e.paginationDistribution.PSObject.Properties | ForEach-Object { "$($_.Name):$($_.Value)" }) -join ' / '
    } else { '-' }
    $tfCov = "$($e.timeFilterEndpointCount)/$($e.endpointCount)"
    $topE  = if ($e.topEntities) { ($e.topEntities | Select-Object -First 4) -join ', ' } else { '-' }
    $ps    = $e.productionScale
    $psCell= if ($ps) { "$($ps.VolumeLargeT) · risk=$($ps.RateLimitRisk) · delta=$($ps.DeltaPollPriority)" } else { '-' }
    [void]$md.Add("| $($e.subArea) | $($e.cadenceSuggestion) | $paginDist | $tfCov | $topE | $psCell |")
}
[void]$md.Add("")

# Write output
Set-Content -Path $OutputPath -Value ($md -join "`n") -NoNewline
Write-Host ""
Write-Host "Full catalogue written: $OutputPath" -ForegroundColor Green
Write-Host "Total lines: $($md.Count)" -ForegroundColor Green
Write-Host "Total endpoints catalogued: $globalEps" -ForegroundColor Green
Write-Host "Defender read=$(($defenderEps|Where-Object ReadSemantics -eq 'read').Count) write=$(($defenderEps|Where-Object ReadSemantics -eq 'write').Count) unknown=$(($defenderEps|Where-Object ReadSemantics -eq 'unknown').Count)" -ForegroundColor Green
