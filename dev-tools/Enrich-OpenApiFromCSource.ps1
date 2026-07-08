#Requires -Version 7.4
<#
.SYNOPSIS
C-source → OpenAPI schema enricher (the C-consolidation · fix-at-source · reproducible). MIRRORS the proven
Enrich-OpenApiFromLanded.ps1 mechanism but derives each empty-ProjectionMap op's typed {prop:type} from the
THIRD reference corpus — the table-grained portal-API captures at references/live/source-xdrlograider-raw/*-raw.json
(REAL response bodies) — instead of Log Analytics. For each empty-proj SHIPPED op that has a VERIFIED C-table in the
semantic map below, it reads that raw file, derives the per-item schema (items-shape unwrapped), and FILLS the op's
OpenAPI 200-response `pending` stub so Build-Catalogue's tier-2 derives a typed ProjectionMap.

Commits ZERO captured values (schema keys+types only · no PII · same nodoc-exposure as the already-committed specs).

.DESCRIPTION
SAME two helpers as the landed enricher (copied self-contained, kept byte-identical except the two documented deltas):
  · Get-XdrCSourcePropTypes — unwraps the wrapper key (rules/Rules/Results/results/value/data/items/Items/records/
    actions · 'rules'/'Rules' ADDED for the C-source asset-rules shape) and returns ordered {prop:type}, $null on an
    empty/non-derivable wrapper. PLUS a DIAGNOSTIC-STUB guard: a C capture for a cap-absent/404 product is a stub
    object {_availability,_capturedUtc,_diagnosticClass,_reason,_responseBodyExcerpt} — NOT a real body; deriving
    from it would emit a garbage 5-underscore-field projection, so a schema whose keys are ALL '_'-prefixed is
    rejected (returns $null · treated as no-C-body).
  · Set-XdrOpenApiProperties — IDENTICAL to the landed enricher: locates `operationId: <X>`, then the
    `type: object` / `description: pending` stub, and replaces it with a `properties:` block.

THE SEMANTIC MAP ($CTableForOp) is the load-bearing, audited judgement: opId → C-table name fragment. ONLY
high-confidence pairs are encoded (C-table field names + the op path/purpose clearly correspond). Ambiguous or
already-covered C-tables are deliberately ABSENT (held · see the header comment on the map). It is correct and
expected that MOST empty-proj ops have NO C-match — they are genuinely cap-absent products (MCAS/MDI/MAPG/MDO) that
capture a body only on a licensed tenant (F18 · the dynamic connector ships + cap-gates + lights up there).

.NOTES
DRY by default. -Apply writes the spec files. Re-run `Build-Catalogue.ps1 -Portal Defender -WriteFile` after, then verify.
NO network/LA — reads the in-repo C-source only. NO C-source file is modified (read-only).
#>
[CmdletBinding()]
param(
    [string[]] $OnlyOps,
    [switch]   $Apply,
    [string]   $RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$CSourceDir = Join-Path $RepoRoot 'references/live/source-xdrlograider-raw'

# ════════════════════════════════════════════════════════════════════════════════════════════════════════════════
# THE VERIFIED SEMANTIC MAP · OperationId → C-table name fragment (the '*-raw.json' basename without the suffix).
# Each pairing was verified by reading the populated (>1KB) C-table's derived item schema AND the op's catalogue
# Path/OperationId, and confirming the field names + path/purpose CLEARLY correspond. ONLY high-confidence pairs.
#
# Currently ONE pair clears the bar:
#   Configuration.GetAssetRules  ←  MDE_AssetRules_CL
#       op path  /mtp/ndr/rulesengine/rules ("Get asset rule management rules")
#       C-table  MDE_AssetRules_CL-raw.json (727KB) · top key 'rules' → 132 items · 23 fields
#                (orgId,tenantId,ruleId,ruleName,ruleDescription,createdBy,createdByName,lastUpdatedBy,
#                 lastUpdatedByName,lastUpdateTime,ruleDefinition,kqlQuery,isDisabled,actions,affectedAssetsCount,
#                 creationTime,ruleType,criticalityLevel,isDeleted,lastExecutionTime,timestamp,assetType,
#                 classificationValue)
#       Cross-confirmed: the SIBLING op Configuration.ListCriticalAssetClassifications (/xspmatlas/assetrules) already
#       carries this EXACT 23-field asset-rule projection live → the schema is real; GetAssetRules is the same asset-
#       rules body served at the /ndr/rulesengine/rules path. High confidence.
#
# DELIBERATELY HELD (documented for audit — do NOT add without a capable-tenant confirm):
#   · MDE_VulnerableMachines (17 real cols · per-device vuln posture) — AMBIGUOUS between two shipped empty-proj ops:
#       VulnerabilityManagement.GetVulnerableDevicesReport (/tvm/analytics/vulnerableDevicesReport) AND
#       VulnerabilityManagement.ListTopVulnerableAssets (/tvm/analytics/assets/topVulnerable). The bare-array body
#       carries no ranking metadata to decide which; the C-table file-name is not an authoritative endpoint binding.
#       Forcing it risks the wrong op → HELD per the task's ambiguity rule.
#   · MDE_DataExportSettings (6 cols) — Configuration.GetDataExportSettings ALREADY carries this exact projection
#       (designatedTenantId/eventHubProperties/Id/logsJson/storageAccountProperties/workspacePropertiesJson) from a
#       fixture; not empty-proj → nothing to fill.
#   · MDE_ActionCenter (19 cols · action HISTORY) — the only empty-proj ActionCenter op is ListAutomationRules
#       (/automation/.../automationRules = automation RULES, a DIFFERENT entity); the history schema is already
#       carried by ActionCenter.GetHistory/GetPending. No correspondence → held.
#   · MDE_VulnerabilityInventory/SoftwareInventory/ExposureRecommendations/PostureMetrics/{Identity,Apps,Data}
#     SecureScore/Machines/RbacDeviceGroups/SuppressionRules/PostureTenants/TenantContext/ThreatAnalytics* /
#     XspmInitiatives/PostureSecurityEvents/SecureScoreBreakdown — their natural target op is ALREADY non-empty
#       (projection derived from corpus A/B); no empty-proj target → held (no double-derive).
#   · MDE_AssetClassificationSchema (schema:array · reference shape), MDE_UserPreferences (single string),
#     MDE_LicenseReport (Sums:array · inner shape empty) — no clean telemetry-grade empty-proj target → held.
#   · The 17 MDI/MDO/MAPG/MCAS empty-proj ops (Identity.* aatp/mdi · AppGovernance.* · CloudApps.* · AttackSimulator.*
#     · Configuration.GetMcasPreviewFeatures) — genuinely cap-absent on this single-tenant lab → NO populated
#       C-table exists (their C captures are the diagnostic stubs). They ship + cap-gate + light up on a capable
#       tenant (F18). NOT a C-consolidation concern.
# ════════════════════════════════════════════════════════════════════════════════════════════════════════════════
$CTableForOp = @{
    'Configuration.GetAssetRules' = 'MDE_AssetRules_CL'
}

# ── Helper 1 · C-source body → ordered {prop:type} (MIRRORS Get-XdrLandedPropTypes · 2 documented deltas) ──────────
function Get-XdrCSourcePropTypes($raw) {
    try { $obj = $raw | ConvertFrom-Json -Depth 30 } catch { return $null }
    $item = $obj
    if ($obj -is [System.Array]) { if (@($obj).Count -gt 0) { $item = @($obj)[0] } else { return $null } }
    elseif ($obj -is [psobject]) {
        # DELTA 1: 'rules'/'Rules' ADDED (the C-source asset-rules wrapper) ahead of the landed-enricher set.
        foreach ($wk in 'rules','Rules','Results','results','value','data','items','Items','records','actions') {
            $p = $obj.PSObject.Properties[$wk]
            if ($p -and ($p.Value -is [System.Array])) {
                # well-known wrapper key → the records live in THIS array. Non-empty: derive from item[0]. EMPTY: a
                # wrapper with no sample item → cannot derive the per-item schema → $null (NEVER enrich the envelope).
                if (@($p.Value).Count -gt 0) { $item = @($p.Value)[0]; break } else { return $null }
            }
        }
    }
    if ($item -isnot [psobject]) { return $null }
    $t = [ordered]@{}
    foreach ($pp in ($item.PSObject.Properties | Sort-Object Name)) {
        $v = $pp.Value
        $t[$pp.Name] = if ($null -eq $v) { 'string' } elseif ($v -is [System.Array]) { 'array' } elseif ($v -is [psobject]) { 'object' } elseif ($v -is [bool]) { 'boolean' } elseif ($v -is [int64] -or $v -is [int32] -or $v -is [double] -or $v -is [decimal]) { 'number' } else { 'string' }
    }
    if ($t.Count -eq 0) { return $null }
    # DELTA 2: DIAGNOSTIC-STUB guard. A C capture for a cap-absent/404 product is a stub object whose keys are ALL
    # '_'-prefixed ({_availability,_capturedUtc,_diagnosticClass,_reason,_responseBodyExcerpt}) — NOT a real response
    # body. Deriving from it would emit a garbage 5-underscore-field projection, so reject it (treat as no C-body).
    $nonDiag = @($t.Keys | Where-Object { -not $_.StartsWith('_') })
    if ($nonDiag.Count -eq 0) { return $null }
    return $t
}

# ── Helper 2 · fill the OpenAPI 200 `pending` stub (IDENTICAL to Enrich-OpenApiFromLanded.ps1) ────────────────────
function Set-XdrOpenApiProperties([string]$specPath, [string]$opId, $propTypes) {
    if (-not (Test-Path $specPath)) { return 'spec-missing' }
    $lines = @(Get-Content $specPath)
    $opLine = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match "operationId:\s*$([regex]::Escape($opId))\s*$") { $opLine = $i; break } }
    if ($opLine -lt 0) { return 'opid-not-found' }
    $blockEnd = $lines.Count
    for ($i = $opLine + 1; $i -lt $lines.Count; $i++) { if ($lines[$i] -match 'operationId:') { $blockEnd = $i; break } }
    $stubLine = -1; $indent = ''
    for ($i = $opLine; $i -lt $blockEnd; $i++) {
        if ($lines[$i] -match '^(\s*)type:\s*object\s*$') {
            $ind = $matches[1]
            if ($i + 1 -lt $lines.Count -and $lines[$i + 1] -match '^\s*description:\s*pending') { $stubLine = $i + 1; $indent = $ind; break }
        }
    }
    if ($stubLine -lt 0) { return 'stub-not-found' }
    $propLines = @("${indent}properties:")
    foreach ($k in $propTypes.Keys) { $propLines += "${indent}  ${k}: { type: $($propTypes[$k]) }" }
    $new = @()
    if ($stubLine -gt 0) { $new += $lines[0..($stubLine - 1)] }
    $new += $propLines
    if ($stubLine + 1 -lt $lines.Count) { $new += $lines[($stubLine + 1)..($lines.Count - 1)] }
    Set-Content -Path $specPath -Value $new -Encoding utf8
    return 'enriched'
}

# Resolve the C-source raw file for a C-table name fragment (the proven AssetRules path is **/<frag>-raw.json).
function Get-XdrCSourceFile([string]$frag) {
    $direct = Join-Path $CSourceDir "$frag-raw.json"
    if (Test-Path $direct) { return $direct }
    $hit = Get-ChildItem -Path $CSourceDir -Recurse -Filter "$frag-raw.json" -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hit) { return $hit.FullName }
    return $null
}

# ── Drive ──
$cat = Get-Content (Join-Path $RepoRoot 'references/inventory/nodoc-defender-xdr/catalogue.json') -Raw | ConvertFrom-Json
$ops = @($cat.Operations | Where-Object { $_.Shipped -and ((-not $_.ProjectionMap) -or (@($_.ProjectionMap.PSObject.Properties).Count -eq 0)) })
if ($OnlyOps) { $ops = @($ops | Where-Object { $_.OperationId -in $OnlyOps }) }
# Process only the empty-proj ops that have a VERIFIED C-table in the map.
$mapped = @($ops | Where-Object { $CTableForOp.ContainsKey([string]$_.OperationId) })
"empty-proj ops: $($ops.Count) · mapped to a C-table: $($mapped.Count) · Apply=$($Apply.IsPresent)"
$enriched = 0; $skipped = 0
foreach ($op in $mapped) {
    try {
        $opId = [string]$op.OperationId
        $frag = $CTableForOp[$opId]
        $cfile = Get-XdrCSourceFile $frag
        if (-not $cfile) { "  SKIP $opId · C-table '$frag' not found"; $skipped++; continue }
        $pt = Get-XdrCSourcePropTypes (Get-Content $cfile -Raw)
        if (-not $pt) { "  SKIP $opId · '$frag' empty/non-derivable/diagnostic-stub body"; $skipped++; continue }
        $oapi = [string]$op.Provenance.OpenApi
        $parts = $oapi -split '#', 2
        if ($parts.Count -lt 2) { "  SKIP $opId · no OpenApi provenance"; $skipped++; continue }
        $specPath = Join-Path $RepoRoot $parts[0]
        if ($Apply) {
            $res = Set-XdrOpenApiProperties $specPath $parts[1] $pt
            "  $res $opId · $($pt.Count) props ← $frag → $($parts[0])"
            if ($res -eq 'enriched') { $enriched++ } else { $skipped++ }
        } else {
            "  WOULD-ENRICH $opId · $($pt.Count) props ← ${frag}: $(@($pt.Keys) -join ', ')"
            $enriched++
        }
    } catch { "  ERR $($op.OperationId) · $($_.Exception.Message)"; $skipped++ }
}
"=== enriched=$enriched · skipped=$skipped ==="
