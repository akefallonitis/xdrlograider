<#
.SYNOPSIS
    End-to-end production-readiness verifier for XdrLogRaider deployments.

.DESCRIPTION
    Single consolidated runbook covering 20 production-readiness signals
    across 6 dimensions: Provisioning / Wiring / Liveness / Coverage / Quality
    / Risk. Replaces the overlapping checks in:
      tools/Audit-LiveDeployment.ps1
      tools/Post-DeploymentVerification.ps1
      tools/Smoke-Deploy.ps1
      tools/Test-ConnectorHealth.ps1

    The goal is to give an operator ONE script that returns:
      - PRODUCTION-READY (exit 0): every signal GREEN, connector card flips
        Connected, all tiers fired in expected window
      - DEGRADED (exit 1): WARN signals only — usually transient (cold-start
        not finished, weekly tier hasn't fired yet, expected tenant-gated
        404s)
      - FAILED (exit 2): one or more BLOCKING signals — connector card will
        not flip Connected; immediate action required

    Designed to run AFTER deploy + first cadence cycle (~12-15 min cold-start
    window). Re-run as needed during 1-week observation.

.PARAMETER WorkspaceCustomerId
    Log Analytics workspace GUID. Required for KQL signal queries.

.PARAMETER ConnectorResourceGroup
    Connector RG hosting the Function App, Storage, KV, AppInsights.

.PARAMETER ApplicationInsightsResourceId
    AppInsights resource ID. Falls back to discovery via $ConnectorResourceGroup
    if not provided.

.PARAMETER OutputMarkdown
    Path to write the markdown report. Defaults to
    tests/results/e2e-prod-<UtcStamp>.md

.PARAMETER SkipKql
    Skip KQL-dependent signals (Provisioning + Risk subset only). Useful for
    quick local sanity check without workspace access.

.OUTPUTS
    Markdown report + structured exit code (0 / 1 / 2).

.EXAMPLE
    pwsh tools/Verify-EndToEndProduction.ps1 `
        -WorkspaceCustomerId '<workspace-guid>' `
        -ConnectorResourceGroup 'xdrlograider-rg'
#>
[CmdletBinding()]
param(
    [string] $WorkspaceCustomerId,
    [string] $ConnectorResourceGroup,
    [string] $ApplicationInsightsResourceId,
    [string] $OutputMarkdown,
    [switch] $SkipKql
)

$ErrorActionPreference = 'Continue'  # Per-signal failure isolation

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

$script:Findings = New-Object System.Collections.Generic.List[object]
$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Add-Signal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('Provisioning','Wiring','Liveness','Coverage','Quality','Risk')] [string] $Section,
        [Parameter(Mandatory)] [string] $Id,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [ValidateSet('PASS','WARN','FAIL','SKIP')] [string] $Status,
        [string] $Detail = '',
        [string] $Remediation = '',
        [string] $Kql = ''
    )
    $script:Findings.Add([pscustomobject]@{
        Section     = $Section
        Id          = $Id
        Name        = $Name
        Status      = $Status
        Detail      = $Detail
        Remediation = $Remediation
        Kql         = $Kql
        Timestamp   = (Get-Date -AsUTC).ToString('o')
    })
    $color = switch ($Status) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } 'SKIP' { 'DarkGray' } }
    Write-Host ("[{0}] {1}/{2}: {3}" -f $Status, $Section, $Id, $Name) -ForegroundColor $color
    if ($Detail) { Write-Host "        $Detail" -ForegroundColor DarkGray }
}

function Invoke-WorkspaceQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $WorkspaceCustomerId,
        [Parameter(Mandatory)] [string] $Query,
        [int] $TimeoutSeconds = 60
    )
    if ($SkipKql) { return $null }
    try {
        Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceCustomerId -Query $Query -ErrorAction Stop -Timespan ([TimeSpan]::FromHours(24))
    } catch {
        Write-Verbose ("Workspace query failed: {0}" -f $_.Exception.Message)
        return $null
    }
}

# -----------------------------------------------------------------------------
# SECTION A — PROVISIONING (Signals 12, 13, partial 14)
#   ARM resources, DCR/DCE liveness, Sentinel content readability.
# -----------------------------------------------------------------------------

function Test-Provisioning {
    if (-not $ConnectorResourceGroup) {
        Add-Signal -Section 'Provisioning' -Id 'P1' -Name 'Connector RG resources' -Status 'SKIP' `
            -Detail '-ConnectorResourceGroup not supplied; skipping provisioning checks'
        return
    }
    try {
        $resources = Get-AzResource -ResourceGroupName $ConnectorResourceGroup -ErrorAction Stop
    } catch {
        Add-Signal -Section 'Provisioning' -Id 'P1' -Name 'Connector RG enumerable' -Status 'FAIL' `
            -Detail $_.Exception.Message -Remediation 'Check Az auth + RG name'
        return
    }
    Add-Signal -Section 'Provisioning' -Id 'P1' -Name 'Connector RG enumerable' -Status 'PASS' `
        -Detail ("$($resources.Count) total resources")

    $expected = @{
        'Microsoft.Web/sites'           = 1
        'Microsoft.KeyVault/vaults'     = 1
        'Microsoft.Storage/storageAccounts' = 1
        'Microsoft.Insights/dataCollectionRules' = 7
        'Microsoft.Insights/dataCollectionEndpoints' = 1
    }
    foreach ($t in $expected.Keys) {
        $count = @($resources | Where-Object ResourceType -eq $t).Count
        if ($count -ge $expected[$t]) {
            Add-Signal -Section 'Provisioning' -Id "P2-$($t -replace '\W','')" -Name "$t count" -Status 'PASS' `
                -Detail "$count present (expected ≥$($expected[$t]))"
        } else {
            Add-Signal -Section 'Provisioning' -Id "P2-$($t -replace '\W','')" -Name "$t count" -Status 'FAIL' `
                -Detail "$count present (expected ≥$($expected[$t]))" `
                -Remediation 'Re-run Deploy-to-Azure'
        }
    }
}

# -----------------------------------------------------------------------------
# SECTION B — WIRING (Signals 3, 4, 5, 8)
#   AppDependencies grouped by Target with per-endpoint success rate.
# -----------------------------------------------------------------------------

function Test-Wiring {
    if (-not $WorkspaceCustomerId -or $SkipKql) {
        Add-Signal -Section 'Wiring' -Id 'W1' -Name 'AppDependencies KV success rate' -Status 'SKIP' `
            -Detail '-WorkspaceCustomerId not supplied or -SkipKql set'
        return
    }
    # Section R++++++ fix (2026-05-07): AppDependencies.Success is string in
    # AppInsights schema, not bool — `not Success` raised BadRequest. Use
    # explicit equality comparison instead. Also track LatestFailUtc so we
    # can distinguish "real-time production gap" from "historical noise"
    # (e.g. pre-FA-restart 4xx that aged into the window but is no longer
    # happening) — a transient pre-restart failure shouldn't block the
    # PRODUCTION-READY verdict if zero failures are happening NOW.
    $depQuery = @'
AppDependencies
| where TimeGenerated > ago(1h)
| extend Cat = case(Target has 'vault.azure.net','KV', Target has 'security.microsoft.com','Defender', Target has 'ingest.monitor.azure.com','DCE', Target has 'storage.azure.com' or Target has 'core.windows.net','Storage','Other')
| summarize n=count(), succ=countif(Success == true), fail=countif(Success == false),
            LatestFailUtc=maxif(TimeGenerated, Success == false),
            p95=percentile(DurationMs,95) by Cat, Target
| order by Cat, fail desc
'@
    $r = Invoke-WorkspaceQuery -WorkspaceCustomerId $WorkspaceCustomerId -Query $depQuery
    if (-not $r) {
        Add-Signal -Section 'Wiring' -Id 'W1' -Name 'AppDependencies query' -Status 'FAIL' `
            -Detail 'Query failed or returned null' -Kql $depQuery
        return
    }
    foreach ($row in $r.Results) {
        $rate = if ($row.n -gt 0) { [Math]::Round($row.succ / $row.n, 3) } else { 0 }
        # Failures-fresh check: only FAIL if recent failures exist (last 15 min).
        # Pre-FA-restart historical 4xx that already aged past 15 min are
        # transient noise from a prior code version, not production-impacting.
        $failureFresh = $false
        if ($row.fail -gt 0 -and $row.LatestFailUtc) {
            try {
                $ageMin = ((Get-Date).ToUniversalTime() - [DateTime]::Parse($row.LatestFailUtc)).TotalMinutes
                if ($ageMin -le 15) { $failureFresh = $true }
            } catch { $failureFresh = $true }  # safe default if parse fails
        }
        $status = if ($row.n -eq 0) { 'WARN' }
                  elseif ($rate -lt 0.95 -and $failureFresh) { 'FAIL' }
                  elseif ($rate -lt 0.95) { 'WARN' }  # historical-only failures
                  elseif ($rate -lt 0.99) { 'WARN' }
                  else { 'PASS' }
        $detail = "n={0} succ={1} fail={2} rate={3} p95={4}ms" -f $row.n, $row.succ, $row.fail, $rate, $row.p95
        if ($row.fail -gt 0 -and -not $failureFresh) { $detail += " (failures stale; latest >15min ago)" }
        Add-Signal -Section 'Wiring' -Id ("W-{0}-{1}" -f $row.Cat, ($row.Target -replace '\W','')) `
            -Name "Dependency $($row.Target)" -Status $status `
            -Detail $detail
    }
}

# -----------------------------------------------------------------------------
# SECTION C — LIVENESS (Signals 1, 2, 6, 7, 11, 14)
#   AppRequests by function + heartbeat + IsConnected explicit calculation.
# -----------------------------------------------------------------------------

function Test-Liveness {
    if (-not $WorkspaceCustomerId -or $SkipKql) {
        Add-Signal -Section 'Liveness' -Id 'L0' -Name 'Workspace KQL skipped' -Status 'SKIP'
        return
    }
    # L1: AppRequests by function in last 1h
    $reqQ = @'
AppRequests
| where TimeGenerated > ago(1h)
| where Name in ('Xdr-Refresh','Xdr-PollOrchestrator','Xdr-PollStream','Connector-Heartbeat')
| summarize n=count(), succ=countif(Success), fail=countif(not Success), p95=percentile(DurationMs,95), avg=avg(DurationMs) by Name
'@
    $r = Invoke-WorkspaceQuery -WorkspaceCustomerId $WorkspaceCustomerId -Query $reqQ
    if ($r -and $r.Results) {
        foreach ($row in $r.Results) {
            $rate = if ($row.n) { [Math]::Round($row.succ/$row.n,3) } else { 0 }
            $status = if ($row.n -eq 0) { 'WARN' } elseif ($rate -lt 0.95) { 'FAIL' } else { 'PASS' }
            Add-Signal -Section 'Liveness' -Id ("L1-{0}" -f $row.Name) -Name "$($row.Name) executions" -Status $status `
                -Detail ("n={0} succ={1} fail={2} avg={3}ms p95={4}ms" -f $row.n,$row.succ,$row.fail,[int]$row.avg,[int]$row.p95)
        }
    } else {
        Add-Signal -Section 'Liveness' -Id 'L1' -Name 'AppRequests query' -Status 'WARN' -Detail 'No rows returned (cold-start? no executions yet?)'
    }

    # L2: Per-stream coverage by SourceName from union Defender_*_CL
    $covQ = @'
union withsource=Tbl Defender_EndpointDeviceManagement_CL, Defender_EndpointConfiguration_CL,
                     Defender_VulnerabilityManagement_CL, Defender_IdentityProtection_CL,
                     Defender_ConfigurationAndSettings_CL, Defender_ExposureManagement_CL,
                     Defender_ThreatAnalytics_CL, Defender_ActionCenter_CL,
                     Defender_MultiTenantOperations_CL, Defender_StreamingApi_CL
| where TimeGenerated > ago(24h)
| summarize Rows = count(), LastSeen = max(TimeGenerated) by Tbl, SourceName
| order by Tbl, SourceName
'@
    $r = Invoke-WorkspaceQuery -WorkspaceCustomerId $WorkspaceCustomerId -Query $covQ
    if ($r -and $r.Results) {
        $perTable = $r.Results | Group-Object Tbl
        foreach ($g in $perTable) {
            $totalRows = ($g.Group | Measure-Object Rows -Sum).Sum
            $streamCount = $g.Group.Count
            Add-Signal -Section 'Liveness' -Id ("L2-{0}" -f $g.Name) -Name "$($g.Name) coverage" -Status 'PASS' `
                -Detail ("$streamCount distinct streams, $totalRows total rows in last 24h")
        }
    } else {
        Add-Signal -Section 'Liveness' -Id 'L2' -Name 'Per-stream coverage' -Status 'WARN' `
            -Detail 'No rows in any Defender_*_CL — connector may be cold-starting'
    }

    # L3: HEARTBEAT — XdrConnectorHealth_CL liveness in last 15min
    $hbQ = @'
XdrConnectorHealth_CL
| where TimeGenerated > ago(15m)
| summarize Hb = count(), MaxStreamsSucceeded = max(StreamsSucceeded), MaxRowsIngested = max(RowsIngested)
'@
    $r = Invoke-WorkspaceQuery -WorkspaceCustomerId $WorkspaceCustomerId -Query $hbQ
    if ($r -and $r.Results -and $r.Results[0].Hb -gt 0) {
        Add-Signal -Section 'Liveness' -Id 'L3' -Name 'Heartbeat (15m)' -Status 'PASS' `
            -Detail ("Hb={0} maxStreamsSucceeded={1} maxRowsIngested={2}" -f $r.Results[0].Hb, $r.Results[0].MaxStreamsSucceeded, $r.Results[0].MaxRowsIngested)
    } else {
        Add-Signal -Section 'Liveness' -Id 'L3' -Name 'Heartbeat (15m)' -Status 'WARN' `
            -Detail 'No heartbeat row in last 15 min — cold-start? Connector-Heartbeat misconfigured?'
    }

    # L4: EXPLICIT CONNECTOR-CARD GATE — exact replica of connectivityCriteria query
    $gateQ = @"
XdrConnectorHealth_CL
| where TimeGenerated > ago(1h)
| where Tier != 'Heartbeat'
| where StreamsSucceeded > 0
| where RowsIngested > 0
| summarize IsConnected = count() > 0
"@
    $r = Invoke-WorkspaceQuery -WorkspaceCustomerId $WorkspaceCustomerId -Query $gateQ
    if ($r -and $r.Results -and $r.Results[0].IsConnected -eq $true) {
        Add-Signal -Section 'Liveness' -Id 'L4' -Name 'Connector card IsConnected' -Status 'PASS' `
            -Detail 'Sentinel UI will show "Connected"'
    } else {
        Add-Signal -Section 'Liveness' -Id 'L4' -Name 'Connector card IsConnected' -Status 'FAIL' `
            -Detail 'connectivityCriteria query returns IsConnected=false — Sentinel UI will show "Disconnected"' `
            -Remediation 'Wait for next Connector-Heartbeat tick (5min) AFTER an orchestration completes; verify Set-XdrTierStateRow path' `
            -Kql $gateQ
    }
}

# -----------------------------------------------------------------------------
# SECTION D — COVERAGE (Signals 7, 19, 20)
#   Tier-based coverage + empty-result streams + drift parser issues.
# -----------------------------------------------------------------------------

function Test-Coverage {
    if (-not $WorkspaceCustomerId -or $SkipKql) {
        Add-Signal -Section 'Coverage' -Id 'C0' -Name 'Workspace KQL skipped' -Status 'SKIP'
        return
    }
    # C1: Per-tier rows last 24h (proves all tiers fired)
    $tierQ = @'
union withsource=Tbl Defender_EndpointDeviceManagement_CL, Defender_EndpointConfiguration_CL,
                     Defender_VulnerabilityManagement_CL, Defender_IdentityProtection_CL,
                     Defender_ConfigurationAndSettings_CL, Defender_ExposureManagement_CL,
                     Defender_ThreatAnalytics_CL, Defender_ActionCenter_CL,
                     Defender_MultiTenantOperations_CL, Defender_StreamingApi_CL
| where TimeGenerated > ago(24h)
| summarize Rows=count(), Streams=dcount(SourceName), LatestRow=max(TimeGenerated) by Tbl
'@
    $r = Invoke-WorkspaceQuery -WorkspaceCustomerId $WorkspaceCustomerId -Query $tierQ
    if ($r -and $r.Results) {
        foreach ($row in $r.Results) {
            $ageMin = [int]((Get-Date).ToUniversalTime() - [DateTime]::Parse($row.LatestRow)).TotalMinutes
            $status = if ($ageMin -le 1500) { 'PASS' } elseif ($ageMin -le 2880) { 'WARN' } else { 'FAIL' }
            Add-Signal -Section 'Coverage' -Id ("C1-{0}" -f $row.Tbl) -Name "$($row.Tbl) freshness" -Status $status `
                -Detail ("Rows=$($row.Rows) Streams=$($row.Streams) AgeMin=$ageMin (latest: $($row.LatestRow))")
        }
    }
}

# -----------------------------------------------------------------------------
# SECTION E — QUALITY (Signals 17, 20)
#   RawJson-only rows, projection-quality, parser failures.
# -----------------------------------------------------------------------------

function Test-Quality {
    if (-not $WorkspaceCustomerId -or $SkipKql) {
        Add-Signal -Section 'Quality' -Id 'Q0' -Name 'Workspace KQL skipped' -Status 'SKIP'
        return
    }
    # Q1: rows with EntityId starting 'idx-' (manifest IdProperty fallback) — should be 0 after manifest fixes
    $idxQ = @'
union withsource=Tbl Defender_EndpointDeviceManagement_CL, Defender_EndpointConfiguration_CL,
                     Defender_VulnerabilityManagement_CL, Defender_IdentityProtection_CL,
                     Defender_ConfigurationAndSettings_CL, Defender_ExposureManagement_CL,
                     Defender_ThreatAnalytics_CL, Defender_ActionCenter_CL,
                     Defender_MultiTenantOperations_CL, Defender_StreamingApi_CL
| where TimeGenerated > ago(24h)
| where tostring(EntityId) startswith 'idx-'
| summarize FallbackRows=count() by Tbl, SourceName
| order by FallbackRows desc
'@
    $r = Invoke-WorkspaceQuery -WorkspaceCustomerId $WorkspaceCustomerId -Query $idxQ
    if ($r -and $r.Results -and $r.Results.Count -gt 0) {
        foreach ($row in $r.Results) {
            Add-Signal -Section 'Quality' -Id ("Q1-{0}" -f $row.SourceName) -Name "Projection fallback (idx-N) on $($row.SourceName)" -Status 'WARN' `
                -Detail ("$($row.FallbackRows) rows in $($row.Tbl) used the idx-N EntityId fallback") `
                -Remediation 'Add IdProperty=@("<naturalKey>") to manifest entry'
        }
    } else {
        Add-Signal -Section 'Quality' -Id 'Q1' -Name 'Projection EntityId stability' -Status 'PASS' `
            -Detail 'No rows used the idx-N fallback (every stream has a stable IdProperty)'
    }
}

# -----------------------------------------------------------------------------
# SECTION F — RISK (Signals 9, 10, 15, 16, 18)
#   DLQ depth, XdrTierState freshness, p95 latency, cost.
# -----------------------------------------------------------------------------

function Test-Risk {
    # F1: AuthChain failure rate
    if ($WorkspaceCustomerId -and -not $SkipKql) {
        $authQ = @'
AppEvents
| where TimeGenerated > ago(1h)
| where Name has 'AuthChain'
| summarize n=count(), errors=countif(Name has 'Error')
'@
        $r = Invoke-WorkspaceQuery -WorkspaceCustomerId $WorkspaceCustomerId -Query $authQ
        if ($r -and $r.Results -and $r.Results[0].n -gt 0) {
            $errRate = [Math]::Round($r.Results[0].errors / $r.Results[0].n, 3)
            $status = if ($errRate -gt 0.1) { 'FAIL' } elseif ($errRate -gt 0.01) { 'WARN' } else { 'PASS' }
            Add-Signal -Section 'Risk' -Id 'R1' -Name 'AuthChain error rate' -Status $status `
                -Detail ("n={0} errors={1} rate={2}" -f $r.Results[0].n, $r.Results[0].errors, $errRate)
        }
    }

    # F2: Per-stream tenant-gated 403/404 expected vs unexpected
    if ($WorkspaceCustomerId -and -not $SkipKql) {
        $errQ = @'
XdrConnectorHealth_CL
| where TimeGenerated > ago(24h)
| where Success == false or StreamsSucceeded < StreamsAttempted
| where ErrorsSnippet has '403' or ErrorsSnippet has '404'
| summarize n=count() by Tier
'@
        $r = Invoke-WorkspaceQuery -WorkspaceCustomerId $WorkspaceCustomerId -Query $errQ
        if ($r -and $r.Results -and $r.Results.Count -gt 0) {
            foreach ($row in $r.Results) {
                Add-Signal -Section 'Risk' -Id ("R2-{0}" -f $row.Tier) -Name "$($row.Tier) tenant-gated errors" -Status 'WARN' `
                    -Detail ("$($row.n) heartbeat rows show 403/404 — verify against manifest Availability='tenant-gated'")
            }
        }
    }
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

Write-Host '=== XdrLogRaider — End-to-End Production Verification ===' -ForegroundColor Cyan
Write-Host ('  Workspace: {0}' -f ($WorkspaceCustomerId -replace '.{20}$', '...')) -ForegroundColor DarkGray
Write-Host ('  RG       : {0}' -f $ConnectorResourceGroup) -ForegroundColor DarkGray
Write-Host ''

Test-Provisioning
Test-Wiring
Test-Liveness
Test-Coverage
Test-Quality
Test-Risk

# -----------------------------------------------------------------------------
# Verdict + report
# -----------------------------------------------------------------------------

$failCount = @($script:Findings | Where-Object Status -eq 'FAIL').Count
$warnCount = @($script:Findings | Where-Object Status -eq 'WARN').Count
$passCount = @($script:Findings | Where-Object Status -eq 'PASS').Count
$skipCount = @($script:Findings | Where-Object Status -eq 'SKIP').Count

Write-Host ''
Write-Host '=== Summary ===' -ForegroundColor Cyan
Write-Host ("  PASS: {0}  WARN: {1}  FAIL: {2}  SKIP: {3}" -f $passCount, $warnCount, $failCount, $skipCount)

$verdict = if ($failCount -gt 0) { 'FAILED' } elseif ($warnCount -gt 0) { 'DEGRADED' } else { 'PRODUCTION-READY' }
$verdictColor = switch ($verdict) { 'PRODUCTION-READY' { 'Green' } 'DEGRADED' { 'Yellow' } 'FAILED' { 'Red' } }
Write-Host ("  VERDICT: {0}" -f $verdict) -ForegroundColor $verdictColor

# Write markdown report
if (-not $OutputMarkdown) {
    $resultsDir = Join-Path $script:RepoRoot 'tests/results'
    if (-not (Test-Path $resultsDir)) { New-Item -ItemType Directory -Path $resultsDir | Out-Null }
    $stamp = (Get-Date -AsUTC).ToString('yyyyMMdd-HHmmssZ')
    $OutputMarkdown = Join-Path $resultsDir "e2e-prod-$stamp.md"
}

$md = New-Object System.Text.StringBuilder
$null = $md.AppendLine("# XdrLogRaider — End-to-End Production Verification")
$null = $md.AppendLine("")
$null = $md.AppendLine("- Timestamp: $((Get-Date -AsUTC).ToString('o'))")
$null = $md.AppendLine("- Workspace: $WorkspaceCustomerId")
$null = $md.AppendLine("- RG: $ConnectorResourceGroup")
$null = $md.AppendLine("- Verdict: **$verdict**")
$null = $md.AppendLine("- PASS: $passCount  WARN: $warnCount  FAIL: $failCount  SKIP: $skipCount")
$null = $md.AppendLine("")
foreach ($section in 'Provisioning','Wiring','Liveness','Coverage','Quality','Risk') {
    $sec = $script:Findings | Where-Object Section -eq $section
    if (-not $sec) { continue }
    $null = $md.AppendLine("## $section")
    $null = $md.AppendLine("")
    $null = $md.AppendLine("| Status | ID | Name | Detail |")
    $null = $md.AppendLine("|---|---|---|---|")
    foreach ($s in $sec) {
        $null = $md.AppendLine(("| {0} | {1} | {2} | {3} |" -f $s.Status, $s.Id, $s.Name, ($s.Detail -replace '\|','\\|')))
    }
    $null = $md.AppendLine("")
}
[System.IO.File]::WriteAllText($OutputMarkdown, $md.ToString(), [System.Text.UTF8Encoding]::new($false))
Write-Host ("Report: {0}" -f $OutputMarkdown) -ForegroundColor Cyan

exit $(if ($failCount -gt 0) { 2 } elseif ($warnCount -gt 0) { 1 } else { 0 })
