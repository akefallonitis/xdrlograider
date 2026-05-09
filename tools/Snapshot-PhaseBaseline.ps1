#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.OperationalInsights
<#
.SYNOPSIS
    Persists a phase-baseline snapshot JSON for AMEND-7 regression checking.

.DESCRIPTION
    Plan R++++++++++.AMEND-7 step #24 BINDING. After each phase's online e2e
    GREEN, snapshot the live state so the NEXT phase's step #21 can diff
    against it (no-regression invariant: each phase must build on top, not
    erase prior progress).

    Schema:
      Phase / Timestamp / Verdict / StreamCounts / AggregateMetrics
      RegressionCheckVsPriorPhase (computed at the next phase, persisted here as null)

    Per-stream metrics captured (matches Audit-StreamLevelE2E.ps1 fields):
      Rows24h, DistinctEntities, TypedColPopulated, SchemaParity, SuccessKind

    Aggregate metrics:
      TotalRowsIn24h, TotalStreamsLive, TotalStreamsTenantGated,
      AppExceptionsClasses15m, DLQDepth, AuthChainSuccessPct

.PARAMETER Phase
    Phase identifier ('Phase-1+', 'Phase-2-batch-1-8', 'Phase-2-batch-9', etc.)

.PARAMETER WorkspaceCustomerId
    Sentinel workspace Customer ID.

.PARAMETER StorageAccountName
    Storage account holding XdrTierState + xdrIngestDlq.

.PARAMETER ManifestPath
    Optional path to endpoints.manifest.psd1.

.OUTPUTS
    Persists JSON to tests/results/phase-baseline-{Phase}-{YYYYMMDD-HHMMSS}.json.
    Returns the path.

.EXAMPLE
    Connect-AzAccount
    pwsh tools/Snapshot-PhaseBaseline.ps1 `
        -Phase 'Phase-1+' `
        -WorkspaceCustomerId '<workspace-guid>' `
        -StorageAccountName 'xdrlrst5lsncl'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Phase,

    [Parameter(Mandatory)]
    [string] $WorkspaceCustomerId,

    [Parameter(Mandatory)]
    [string] $StorageAccountName,

    [string] $ManifestPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $ManifestPath) {
    $ManifestPath = Join-Path $repoRoot 'src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1'
}

# Run the per-stream audit to get fresh data
Write-Host "[Snapshot] Running Audit-StreamLevelE2E.ps1 to capture phase baseline..." -ForegroundColor Cyan
$auditScript = Join-Path $PSScriptRoot 'Audit-StreamLevelE2E.ps1'
$auditResult = & $auditScript -WorkspaceCustomerId $WorkspaceCustomerId `
                              -StorageAccountName $StorageAccountName `
                              -ManifestPath $ManifestPath `
                              -WindowHours 24

# Extract per-stream metrics
$streamCounts = @{}
foreach ($r in $auditResult.Results) {
    $streamCounts[$r.Stream] = @{
        Rows24h           = [int]$r.IngestRows
        TypedColPopulated = [int]$r.TypedColPopulated
        TypedColExpected  = [int]$r.TypedColExpected
        SchemaParity      = [string]$r.SchemaParityStatus
        SuccessKind       = [string]$r.SuccessKind
        Category          = [string]$r.Category
    }
}

# Aggregate metrics
$aggregate = @{
    TotalStreamsTotal       = $auditResult.Summary.TotalStreams
    TotalRowsIn24h          = ($auditResult.Results | Measure-Object -Sum -Property IngestRows).Sum
    TotalStreamsIngested    = ($auditResult.Results | Where-Object IngestionStatus -eq 'PASS').Count
    TotalStreamsTenantGated = ($auditResult.Results | Where-Object SuccessKind -eq 'tenant-gated').Count
    SchemaParityPass        = $auditResult.Summary.SchemaParity_PASS
    SchemaParityFail        = $auditResult.Summary.SchemaParity_FAIL
}

# Pull AppExceptions + DLQ + AuthChain from workspace
$exKql = "AppExceptions | where TimeGenerated > ago(15min) | summarize n=dcount(ProblemId)"
try {
    $exR = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceCustomerId -Query $exKql -ErrorAction SilentlyContinue
    $aggregate.AppExceptionsClasses15m = if ($exR -and $exR.Results.Count -gt 0) { [int]$exR.Results[0].n } else { -1 }
} catch {
    $aggregate.AppExceptionsClasses15m = -1
}

$authKql = @'
AppEvents
| where TimeGenerated > ago(2h)
| where Name startswith 'AuthChain'
| summarize Errors=countif(Name has 'Error'), Total=count()
| extend SuccessPct = iff(Total > 0, 100.0 * (Total - Errors) / Total, 0.0)
'@
try {
    $authR = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceCustomerId -Query $authKql -ErrorAction SilentlyContinue
    $aggregate.AuthChainSuccessPct = if ($authR -and $authR.Results.Count -gt 0) { [math]::Round([double]$authR.Results[0].SuccessPct, 1) } else { -1 }
} catch {
    $aggregate.AuthChainSuccessPct = -1
}

# DLQ depth via Storage Tables
try {
    $dlqResp = Invoke-AzRestMethod -Path "https://$StorageAccountName.table.core.windows.net/xdrIngestDlq()?`$top=100" -Method GET -ErrorAction SilentlyContinue
    if ($dlqResp -and $dlqResp.StatusCode -eq 200) {
        $body = $dlqResp.Content | ConvertFrom-Json
        $aggregate.DLQDepth = if ($body.value) { @($body.value).Count } else { 0 }
    } else {
        $aggregate.DLQDepth = -1
    }
} catch {
    $aggregate.DLQDepth = -1
}

# Build snapshot
$snapshot = @{
    Phase                       = $Phase
    Timestamp                   = (Get-Date -Format 'o')
    Verdict                     = $auditResult.Verdict
    StreamCounts                = $streamCounts
    AggregateMetrics            = $aggregate
    RegressionCheckVsPriorPhase = $null    # populated by Compare-PhaseBaseline.ps1 in next phase
    Window                      = '24h'
}

# Persist
$outDir = Join-Path $repoRoot 'tests' 'results'
$null = New-Item -ItemType Directory -Path $outDir -Force -ErrorAction SilentlyContinue
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$safePhase = $Phase -replace '[^A-Za-z0-9.-]', '_'
$outFile = Join-Path $outDir "phase-baseline-${safePhase}-${ts}.json"
$snapshot | ConvertTo-Json -Depth 8 | Set-Content -Path $outFile -Encoding UTF8

Write-Host "Snapshot persisted: $outFile" -ForegroundColor Green
Write-Host "  Verdict:           $($snapshot.Verdict)"
Write-Host "  Total streams:     $($aggregate.TotalStreamsTotal)"
Write-Host "  Ingested live:     $($aggregate.TotalStreamsIngested)"
Write-Host "  Tenant-gated:      $($aggregate.TotalStreamsTenantGated)"
Write-Host "  Total rows / 24h:  $($aggregate.TotalRowsIn24h)"
Write-Host "  Schema parity:     $($aggregate.SchemaParityPass) PASS / $($aggregate.SchemaParityFail) FAIL"
Write-Host "  AppExceptions15m:  $($aggregate.AppExceptionsClasses15m) classes"
Write-Host "  DLQ depth:         $($aggregate.DLQDepth) entries"
Write-Host "  AuthChain success: $($aggregate.AuthChainSuccessPct)%"

return $outFile
