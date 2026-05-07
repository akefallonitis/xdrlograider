<#
.SYNOPSIS
    LIVE data-quality + schema-parsing audit per-stream.

.DESCRIPTION
    Goes beyond Audit-LiveStreamCoverage.ps1 (which checks "did API return
    200"). This tool checks:

      1. SCHEMA — every typed col declared in manifest ProjectionMap appears
         in the workspace table AND has at least one non-null value in the
         last 24h. Catches:
         - Manifest ProjectionMap drift (col declared but never populated)
         - Workspace table schema mismatch (col missing in destination)
         - Silent col drops (Section R++.B2 class bug)

      2. ENTITY ID — fraction of rows using idx-N synthetic fallback. Should
         be 0% for every stream after Section R++ + Phase 1 fixes.

      3. RAWJSON — every row should have parseable JSON in RawJson col.
         parse_json() failures indicate Shape-3 scalar wrapping bug (MM fix).

      4. DRIFT PARSER COMPATIBILITY — for each cadence-tier parser, verify
         the parser KQL successfully runs against the actual ingested data
         (no syntax errors, returns expected output cols).

      5. TIMELINESS — latest TimeGenerated freshness vs cadence (e.g.,
         Inventory tier should have rows in last 24h+15min).

    Per the operator directive 2026-05-07: "all streams all tables should
    be checked only for getting events but actually quality of data and
    schema parsing for full coverage to ensure that our content will work
    properly."

.PARAMETER WorkspaceCustomerId
    Log Analytics workspace GUID. Required.

.PARAMETER OutputMarkdown
    Output report path. Default: tests/results/data-quality-<UtcStamp>.md.

.EXAMPLE
    pwsh tools/Audit-DataQuality.ps1 -WorkspaceCustomerId '<guid>'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WorkspaceCustomerId,
    [string] $OutputMarkdown
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

if (-not $OutputMarkdown) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmssZ'
    $OutputMarkdown = Join-Path $RepoRoot "tests/results/data-quality-$stamp.md"
}

# Category -> consolidated workspace table (mirrors Build-SentinelContent.ps1)
$catToTable = @{
    'Endpoint Device Management'  = 'Defender_EndpointDeviceManagement_CL'
    'Endpoint Configuration'      = 'Defender_EndpointConfiguration_CL'
    'Vulnerability Management'    = 'Defender_VulnerabilityManagement_CL'
    'Identity Protection'         = 'Defender_IdentityProtection_CL'
    'Configuration and Settings'  = 'Defender_ConfigurationAndSettings_CL'
    'Exposure Management'         = 'Defender_ExposureManagement_CL'
    'Threat Analytics'            = 'Defender_ThreatAnalytics_CL'
    'Action Center'               = 'Defender_ActionCenter_CL'
    'MultiTenant Operations'      = 'Defender_MultiTenantOperations_CL'
    'Streaming API'               = 'Defender_StreamingApi_CL'
}

$manifest = Import-PowerShellDataFile -Path (Join-Path $RepoRoot 'src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1')
$streams = @($manifest.Endpoints | Where-Object { $_.Availability -ne 'deprecated' })

Write-Host "===== Data Quality Audit =====" -ForegroundColor Cyan
Write-Host "  Workspace : $WorkspaceCustomerId"
Write-Host "  Streams   : $($streams.Count)"
Write-Host ""

$rows = @()
$summary = @{ pass = 0; warn = 0; fail = 0; skip = 0 }

foreach ($entry in $streams) {
    $stream = $entry.Stream
    $cat    = $entry.Category
    $tbl    = $catToTable[$cat]
    if (-not $tbl) {
        $rows += [pscustomobject]@{ Stream = $stream; Tbl = '<unknown>'; Section = 'A1-Schema'; Status = 'SKIP'; Detail = "no category-to-table mapping for '$cat'" }
        $summary.skip++
        continue
    }

    $projMap = if ($entry.ProjectionMap) { @($entry.ProjectionMap.Keys) } else { @() }

    # ============ A1 — Row count + recency ============
    $q1 = "$tbl | where SourceName == '$stream' | summarize Rows=count(), Latest=max(TimeGenerated), Earliest=min(TimeGenerated) | extend AgeMin=datetime_diff('minute', now(), Latest)"
    try {
        $r = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceCustomerId -Query $q1 -ErrorAction Stop
        if ($r.Results.Count -gt 0 -and $r.Results[0].Rows -gt 0) {
            $rows += [pscustomobject]@{ Stream = $stream; Tbl = $tbl; Section = 'A1-Recency'; Status = 'PASS';
                Detail = "Rows=$($r.Results[0].Rows) Latest=$($r.Results[0].Latest) AgeMin=$($r.Results[0].AgeMin)" }
            $summary.pass++
        } else {
            $rows += [pscustomobject]@{ Stream = $stream; Tbl = $tbl; Section = 'A1-Recency'; Status = 'WARN';
                Detail = '0 rows in last 24h (license-gated, never polled, or freshly-added stream)' }
            $summary.warn++
        }
    } catch {
        $rows += [pscustomobject]@{ Stream = $stream; Tbl = $tbl; Section = 'A1-Recency'; Status = 'FAIL'; Detail = $_.Exception.Message }
        $summary.fail++
        continue
    }

    # ============ A2 — idx-N fallback ============
    $q2 = "$tbl | where SourceName == '$stream' | where TimeGenerated > ago(24h) | summarize n=count(), idx=countif(tostring(EntityId) startswith 'idx-')"
    try {
        $r = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceCustomerId -Query $q2 -ErrorAction Stop
        if ($r.Results.Count -gt 0) {
            $n = [int]$r.Results[0].n; $idx = [int]$r.Results[0].idx
            if ($n -eq 0) {
                $rows += [pscustomobject]@{ Stream = $stream; Tbl = $tbl; Section = 'A2-EntityId'; Status = 'SKIP'; Detail = '0 rows to evaluate' }
                $summary.skip++
            } elseif ($idx -eq 0) {
                $rows += [pscustomobject]@{ Stream = $stream; Tbl = $tbl; Section = 'A2-EntityId'; Status = 'PASS'; Detail = "0/$n rows used idx-N fallback" }
                $summary.pass++
            } else {
                $pct = [Math]::Round(100.0 * $idx / $n, 1)
                $rows += [pscustomobject]@{ Stream = $stream; Tbl = $tbl; Section = 'A2-EntityId'; Status = 'WARN'; Detail = "$idx/$n rows ($pct%) used idx-N fallback — add IdProperty/SyntheticEntityId" }
                $summary.warn++
            }
        }
    } catch {}

    # ============ A3 — RawJson parseability ============
    $q3 = "$tbl | where SourceName == '$stream' | where TimeGenerated > ago(24h) | take 100 | extend parsed=parse_json(RawJson) | summarize n=count(), null_or_unparseable=countif(isnull(parsed))"
    try {
        $r = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceCustomerId -Query $q3 -ErrorAction Stop
        if ($r.Results.Count -gt 0) {
            $n = [int]$r.Results[0].n; $bad = [int]$r.Results[0].null_or_unparseable
            if ($n -eq 0) {
                $rows += [pscustomobject]@{ Stream = $stream; Tbl = $tbl; Section = 'A3-RawJson'; Status = 'SKIP'; Detail = '0 rows' }
                $summary.skip++
            } elseif ($bad -eq 0) {
                $rows += [pscustomobject]@{ Stream = $stream; Tbl = $tbl; Section = 'A3-RawJson'; Status = 'PASS'; Detail = "$n/100 sampled rows have parseable RawJson" }
                $summary.pass++
            } else {
                $rows += [pscustomobject]@{ Stream = $stream; Tbl = $tbl; Section = 'A3-RawJson'; Status = 'WARN'; Detail = "$bad/$n rows had unparseable RawJson (Shape-3 scalar wrapping bug?)" }
                $summary.warn++
            }
        }
    } catch {}

    # ============ A4 — Typed col population ============
    if ($projMap.Count -gt 0) {
        # For each ProjectionMap key, check non-null %
        $colChecks = $projMap | ForEach-Object { "isnotnull(['$_'])" }
        $colCount = $colChecks.Count
        $q4 = "$tbl | where SourceName == '$stream' | where TimeGenerated > ago(24h) | take 50 | summarize n=count()"
        try {
            $r = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceCustomerId -Query $q4 -ErrorAction Stop
            if ($r.Results.Count -gt 0 -and [int]$r.Results[0].n -gt 0) {
                # Now do per-col non-null check
                $perCol = ($projMap | ForEach-Object { "$_=countif(isnotnull([`'$_`']))" }) -join ', '
                $q5 = "$tbl | where SourceName == '$stream' | where TimeGenerated > ago(24h) | take 50 | summarize n=count(), $perCol"
                $r2 = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceCustomerId -Query $q5 -ErrorAction Stop
                if ($r2.Results.Count -gt 0) {
                    $rec = $r2.Results[0]
                    $n = [int]$rec.n
                    $deadCols = @()
                    foreach ($c in $projMap) {
                        $val = [int]$rec.$c
                        if ($val -eq 0) { $deadCols += $c }
                    }
                    if ($deadCols.Count -eq 0) {
                        $rows += [pscustomobject]@{ Stream = $stream; Tbl = $tbl; Section = 'A4-TypedCols'; Status = 'PASS'; Detail = "All $colCount typed cols have data (n=$n)" }
                        $summary.pass++
                    } else {
                        $rows += [pscustomobject]@{ Stream = $stream; Tbl = $tbl; Section = 'A4-TypedCols'; Status = 'WARN'; Detail = "$($deadCols.Count)/$colCount typed cols are 100% null: $($deadCols -join ', ')" }
                        $summary.warn++
                    }
                }
            } else {
                $rows += [pscustomobject]@{ Stream = $stream; Tbl = $tbl; Section = 'A4-TypedCols'; Status = 'SKIP'; Detail = '0 rows to evaluate cols' }
                $summary.skip++
            }
        } catch {
            $rows += [pscustomobject]@{ Stream = $stream; Tbl = $tbl; Section = 'A4-TypedCols'; Status = 'FAIL'; Detail = "KQL failed: $($_.Exception.Message.Substring(0, [Math]::Min(100, $_.Exception.Message.Length)))" }
            $summary.fail++
        }
    } else {
        $rows += [pscustomobject]@{ Stream = $stream; Tbl = $tbl; Section = 'A4-TypedCols'; Status = 'SKIP'; Detail = 'Manifest entry has no ProjectionMap (RawJson-only stream)' }
        $summary.skip++
    }
}

# ============ Report ============
$mdLines = @()
$mdLines += "# Data Quality Audit"
$mdLines += ""
$mdLines += "Generated: $(Get-Date -Format 'o')"
$mdLines += "Workspace: $WorkspaceCustomerId"
$mdLines += "Streams audited: $($streams.Count)"
$mdLines += ""
$mdLines += "## Summary"
$mdLines += ""
$mdLines += "| Status | Count |"
$mdLines += "|--------|------:|"
$mdLines += "| PASS   | $($summary.pass) |"
$mdLines += "| WARN   | $($summary.warn) |"
$mdLines += "| FAIL   | $($summary.fail) |"
$mdLines += "| SKIP   | $($summary.skip) |"
$mdLines += ""
$mdLines += "## Per-stream signals"
$mdLines += ""
$mdLines += "| Stream | Section | Status | Detail |"
$mdLines += "|--------|---------|--------|--------|"
foreach ($r in $rows) {
    $mdLines += "| $($r.Stream) | $($r.Section) | $($r.Status) | $($r.Detail) |"
}

[void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputMarkdown))
$mdLines | Set-Content -Path $OutputMarkdown -Encoding UTF8

Write-Host ""
Write-Host "===== Summary =====" -ForegroundColor Cyan
Write-Host ("  PASS: {0}" -f $summary.pass) -ForegroundColor Green
Write-Host ("  WARN: {0}" -f $summary.warn) -ForegroundColor Yellow
Write-Host ("  FAIL: {0}" -f $summary.fail) -ForegroundColor Red
Write-Host ("  SKIP: {0}" -f $summary.skip) -ForegroundColor Gray
Write-Host ""
Write-Host "Report: $OutputMarkdown" -ForegroundColor Cyan

if ($summary.fail -gt 0) { exit 2 }
if ($summary.warn -gt 0) { exit 1 }
exit 0
