# Build-CatalogueMasterIndex.ps1
#
# Consolidates per-sub-area _SUBAREA_ENRICHED.json + per-portal _AUTH_RESEARCH.json
# into a single browse-able master index at references/_CATALOGUE_INDEX.md
# (one master document; per-portal sections; all sub-areas + counts + cadence + entities).

#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$ReferencesRoot = "$PSScriptRoot\..\references"
)

$ErrorActionPreference = 'Stop'
Set-Location $ReferencesRoot

$md = @()
$now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
$md += "# XdrLogRaider v2 — Master Catalogue Index"
$md += ""
$md += "Generated: $now UTC"
$md += ""
$md += "Complete Phase 0 catalogue: all portals × all sub-areas × all endpoints × auth model × pagination × time-filter × entities × production-scale cadence. Sourced from nodoc (1,727 endpoints) + v1 reference + this session's live-probe evidence."
$md += ""

# Global tally
$portals = Get-ChildItem -Directory | Sort-Object Name
$totalEp = 0; $totalSa = 0; $totalLive = 0
foreach ($p in $portals) {
    $epCnt = (Get-ChildItem -Path $p.FullName -Recurse -Filter 'metadata.json').Count
    $totalEp += $epCnt
    $totalSa += (Get-ChildItem -Path $p.FullName -Directory).Count
    $liveCnt = 0
    Get-ChildItem -Path $p.FullName -Recurse -Filter 'live.json' | ForEach-Object {
        try { $j = Get-Content $_.FullName -Raw | ConvertFrom-Json; if ($j.successKind -eq 'live') { $liveCnt++ } } catch {}
    }
    $totalLive += $liveCnt
}

$md += "## Global tally"
$md += ""
$md += "- **Portals**: $($portals.Count)"
$md += "- **Sub-areas**: $totalSa"
$md += "- **Endpoints**: $totalEp"
$md += "- **Live-captured (live verdict)**: $totalLive"
$md += ""
$md += "## Per-portal catalogue"
$md += ""

foreach ($portalDir in $portals) {
    $portal = $portalDir.Name
    $epCnt = (Get-ChildItem -Path $portalDir.FullName -Recurse -Filter 'metadata.json').Count
    $saCnt = (Get-ChildItem -Path $portalDir.FullName -Directory).Count
    $liveCnt = 0; $leCnt=0; $errCnt=0
    Get-ChildItem -Path $portalDir.FullName -Recurse -Filter 'live.json' | ForEach-Object {
        try {
            $j = Get-Content $_.FullName -Raw | ConvertFrom-Json
            switch ($j.successKind) {
                'live'       { $liveCnt++ }
                'live-empty' { $leCnt++ }
                'error'      { $errCnt++ }
            }
        } catch {}
    }

    # Auth bucket from _AUTH_RESEARCH.json
    $authFile = Join-Path $portalDir.FullName '_AUTH_RESEARCH.json'
    $bucket = '-'; $clientId = '-'; $audience = '-'; $unattendedStatus = '-'
    if (Test-Path $authFile) {
        try {
            $a = Get-Content $authFile -Raw | ConvertFrom-Json
            $bucket = $a.authModel.bucket
            $clientId = if ($a.authModel.clientId) { $a.authModel.clientId } else { '-' }
            $audience = if ($a.authModel.audience) { $a.authModel.audience } else { '-' }
            $unattendedStatus = $a.unattendedStatus
        } catch {}
    }

    $md += "### $portal"
    $md += ""
    $md += "- **Bucket**: $bucket"
    $md += "- **ClientId**: ``$clientId``"
    $md += "- **Audience**: ``$audience``"
    $md += "- **Unattended status**: $unattendedStatus"
    $md += "- **Sub-areas**: $saCnt · **Endpoints**: $epCnt · **Live**: $liveCnt / live-empty $leCnt / err $errCnt"
    $md += ""

    # Sub-area roll-up
    if ($saCnt -gt 0) {
        $md += "| Sub-area | Endpoints | Cadence | Pagination | Top entities | Live | Production scale |"
        $md += "|---|---:|---|---|---|---:|---|"
        $subAreas = Get-ChildItem -Path $portalDir.FullName -Directory | Sort-Object Name
        foreach ($sa in $subAreas) {
            $saEnFile = Join-Path $sa.FullName '_SUBAREA_ENRICHED.json'
            $saEpCnt = (Get-ChildItem -Path $sa.FullName -Recurse -Filter 'metadata.json').Count
            $saLive = 0
            Get-ChildItem -Path $sa.FullName -Recurse -Filter 'live.json' | ForEach-Object {
                try { $j = Get-Content $_.FullName -Raw | ConvertFrom-Json; if ($j.successKind -eq 'live') { $saLive++ } } catch {}
            }
            $cadence = '-'; $pagDist = '-'; $topEnts = '-'; $prodScale = '-'
            if (Test-Path $saEnFile) {
                try {
                    $sx = Get-Content $saEnFile -Raw | ConvertFrom-Json
                    $cadence = $sx.cadenceSuggestion
                    $pagPairs = @()
                    if ($sx.paginationDistribution) {
                        foreach ($p in $sx.paginationDistribution.PSObject.Properties) {
                            $pagPairs += "$($p.Name):$($p.Value)"
                        }
                    }
                    $pagDist = ($pagPairs -join ', ')
                    if (-not $pagDist) { $pagDist = 'none' }
                    $topEntsArr = @($sx.topEntities)
                    $topEnts = if ($topEntsArr.Count -gt 0) { ($topEntsArr | Select-Object -First 4) -join ', ' } else { '-' }
                    if ($sx.productionScale) {
                        $prodScale = "$($sx.productionScale.VolumeLargeT) · risk=$($sx.productionScale.RateLimitRisk) · delta=$($sx.productionScale.DeltaPollPriority)"
                    }
                } catch {}
            }
            $md += "| $($sa.Name) | $saEpCnt | $cadence | $pagDist | $topEnts | $saLive | $prodScale |"
        }
        $md += ""
    }
}

$md += "## How to operate this catalogue"
$md += ""
$md += "### Per-endpoint enrichment fields (in each metadata.json)"
$md += ""
$md += "- ``parameters`` — path/query/header/body parameters from nodoc OpenAPI"
$md += "- ``paginationStyle`` — pageIndex0Based | pageIndex1Based | topSkip | continuationToken | limitOffset | fromSize | none"
$md += "- ``timeFilterParams`` — names of time-filter params (startDateTime, since, etc.) for delta-poll"
$md += "- ``entities`` — canonical Sentinel entity types extracted from response schema (Host.MdatpId, Account.UPN, File.Sha256, ...)"
$md += "- ``cadenceSuggestion`` — 10min | 1h | 6h | daily | weekly (FA timer hint per sub-area)"
$md += ""
$md += "### Per-sub-area roll-up (_SUBAREA_ENRICHED.json)"
$md += ""
$md += "- ``paginationDistribution`` — count of endpoints per pagination style in this sub-area"
$md += "- ``timeFilterEndpointCount`` — how many endpoints support incremental polls"
$md += "- ``topEntities`` — top 8 cross-correlation join keys (Sentinel entity types)"
$md += "- ``productionScale`` — VolumeLargeT (rows expected on large tenants), RateLimitRisk, DeltaPollPriority"
$md += ""
$md += "### Per-portal auth research (_AUTH_RESEARCH.json)"
$md += ""
$md += "- ``authModel`` — bucket, clientId, portalHost, audience, cookieNames, requiredHeaders"
$md += "- ``unattendedAuth`` — TOTP+Passkey support, CA matrix, ESTSAUTHPERSISTENT, refreshToken cadence"
$md += "- ``kvSecretSchema`` — KV secret names per portal"
$md += ""

$indexPath = Join-Path $ReferencesRoot '_CATALOGUE_INDEX.md'
Set-Content -Path $indexPath -Value ($md -join "`n")
Write-Host "Master catalogue index written: $indexPath" -ForegroundColor Green
Write-Host "Total endpoints catalogued: $totalEp across $($portals.Count) portals × $totalSa sub-areas; $totalLive endpoints currently live"
