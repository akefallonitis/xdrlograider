#Requires -Version 7.4
<#
.SYNOPSIS
Tier-1 → OpenAPI schema enricher (full-schema GA path · reusable per onboard). For each SHIPPED empty-ProjectionMap op
that is LANDING data in its Log Analytics table, derive the top-level {prop:type} from the latest landed RawJson
(items-shape unwrapped) and FILL its OpenAPI 200-response `pending` stub with those properties — so Build-Catalogue
tier-2 derives a typed ProjectionMap. Commits ZERO captured values (schema keys+types only · no PII · same nodoc-exposure
as the already-committed specs). Ops with no landed data (un-deployed / dormant / cap-absent) are SKIPPED + reported
(→ MS-docs enrichment or capture at their category onboard).
.NOTES
DRY by default. -Apply writes the spec files. Re-run `Build-Catalogue.ps1 -Portal Defender -WriteFile` after, then verify.
Query mechanism: REST api.loganalytics.io (NOT az-CLI KQL · quote-trap). Workspace: Sentinel-Workspace.
#>
[CmdletBinding()]
param(
    [string] $WorkspaceId = $env:XDRLR_WORKSPACE_ID,   # LA workspace customerId · set XDRLR_WORKSPACE_ID or pass -WorkspaceId (never hardcode a tenant id in the public repo)
    [string[]] $OnlyOps,
    [switch] $Apply,
    [string] $RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($WorkspaceId)) { throw 'WorkspaceId required · set $env:XDRLR_WORKSPACE_ID or pass -WorkspaceId' }
$tok = (az account get-access-token --resource https://api.loganalytics.io --query accessToken -o tsv 2>$null)
if (-not $tok) { throw 'no LA token (az login?)' }
$hdr = @{ Authorization = "Bearer $tok" }
function Invoke-LA([string]$kql) {
    $body = @{ query = $kql } | ConvertTo-Json -Compress
    try { (Invoke-RestMethod -Uri "https://api.loganalytics.io/v1/workspaces/$WorkspaceId/query" -Method Post -Headers $hdr -Body $body -ContentType 'application/json' -TimeoutSec 180).tables[0] } catch { $null }
}
function Get-XdrLandedPropTypes($raw) {
    try { $obj = $raw | ConvertFrom-Json -Depth 30 } catch { return $null }
    $item = $obj
    if ($obj -is [System.Array]) { if (@($obj).Count -gt 0) { $item = @($obj)[0] } else { return $null } }
    elseif ($obj -is [psobject]) {
        foreach ($wk in 'Results','results','value','data','items','Items','records','actions') {
            $p = $obj.PSObject.Properties[$wk]
            if ($p -and ($p.Value -is [System.Array])) {
                # well-known wrapper key → the records live in THIS array. Non-empty: derive from item[0]. EMPTY: a wrapper
                # with no sample item → cannot derive the per-item schema → return $null (needs docs/onboard), NEVER fall
                # through to enrich the envelope {Items,Next,…} as if it were the record (the GMTE empty-Items class).
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
    return $t
}
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

$cat = Get-Content (Join-Path $RepoRoot 'references/inventory/nodoc-defender-xdr/catalogue.json') -Raw | ConvertFrom-Json
$ops = @($cat.Operations | Where-Object { $_.Shipped -and ((-not $_.ProjectionMap) -or (@($_.ProjectionMap.PSObject.Properties).Count -eq 0)) })
if ($OnlyOps) { $ops = @($ops | Where-Object { $_.OperationId -in $OnlyOps }) }
"empty-proj ops to process: $($ops.Count) · Apply=$($Apply.IsPresent)"
$enriched = 0; $skipped = 0
foreach ($op in $ops) {
    try {
        $tbl = [string]$op.WorkspaceTable; $opv = [string]$op.Operation
        if (-not $tbl) { "  SKIP $($op.OperationId) · no table"; $skipped++; continue }
        # Sample the RICHEST non-empty bodies (not the LATEST — a fan-out/list op's latest row is often an idle/empty
        # sample, e.g. GMTE {Items:[]} on a quiet machine; the schema lives in a POPULATED body). Try the top-N richest
        # by RawJson length until one derives a per-item schema (Get-XdrLandedPropTypes returns $null for empty records).
        $r = Invoke-LA "$tbl | where Operation == '$opv' | where isnotempty(RawJson) | top 8 by strlen(RawJson) desc | project RawJson"
        if (-not $r -or @($r.rows).Count -eq 0) { "  SKIP $($op.OperationId) · no landed data (docs/onboard)"; $skipped++; continue }
        $pt = $null
        foreach ($row in $r.rows) { $pt = Get-XdrLandedPropTypes ([string]$row[0]); if ($pt) { break } }
        if (-not $pt) { "  SKIP $($op.OperationId) · empty/non-derivable body (docs)"; $skipped++; continue }
        $oapi = [string]$op.Provenance.OpenApi
        $parts = $oapi -split '#', 2
        if ($parts.Count -lt 2) { "  SKIP $($op.OperationId) · no OpenApi provenance"; $skipped++; continue }
        $specPath = Join-Path $RepoRoot $parts[0]
        if ($Apply) {
            $res = Set-XdrOpenApiProperties $specPath $parts[1] $pt
            "  $res $($op.OperationId) · $($pt.Count) props → $($parts[0])"
            if ($res -eq 'enriched') { $enriched++ } else { $skipped++ }
        } else {
            "  WOULD-ENRICH $($op.OperationId) · $($pt.Count) props: $(@($pt.Keys) -join ', ')"
            $enriched++
        }
    } catch { "  ERR $($op.OperationId) · $($_.Exception.Message)"; $skipped++ }
}
"=== enriched=$enriched · skipped=$skipped ==="
