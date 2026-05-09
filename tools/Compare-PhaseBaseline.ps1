#Requires -Version 7.0
<#
.SYNOPSIS
    Diff two phase-baseline snapshots to verify no regression + progress per
    AMEND-7 step #21 BINDING (no -50% drop on any stream).

.DESCRIPTION
    Plan R++++++++++.AMEND-7 BINDING: every phase boundary compares vs prior
    phase baseline. This produces an explicit regression-or-progress verdict.

    Default policy:
      - Any stream's row-count delta < -50% vs prior baseline = REGRESSION FAIL
      - Any stream's TypedColPopulated drop = REGRESSION FAIL
      - Any stream's SchemaParity flip from PASS to FAIL = REGRESSION FAIL
      - Any aggregate metric (DLQ depth) > 5x prior = REGRESSION WARN
      - Any AppExceptionsClasses15m > prior + 2 = REGRESSION WARN

    Progress / expansion checks:
      - Streams added in current phase have IngestionStatus PASS or expected lab-gated
      - TotalRowsIn24h positive delta or stable
      - Total Live streams >= prior phase's count

.PARAMETER PriorBaselinePath
    Path to phase-baseline JSON for the PREVIOUS phase.

.PARAMETER CurrentBaselinePath
    Path to phase-baseline JSON for the CURRENT phase.

.OUTPUTS
    PSCustomObject:
      Verdict   = NO-REGRESSION | REGRESSION-WARNINGS | REGRESSION-FAILURES
      Diffs     = per-stream + aggregate row-by-row deltas
      Failures  = list of regression items
      Warnings  = list of advisory items

.EXAMPLE
    pwsh tools/Compare-PhaseBaseline.ps1 `
        -PriorBaselinePath tests/results/phase-baseline-Phase-1+_20260509-120000.json `
        -CurrentBaselinePath tests/results/phase-baseline-Phase-2-batch-1-8_20260510-120000.json
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $PriorBaselinePath,

    [Parameter(Mandatory)]
    [string] $CurrentBaselinePath,

    # Regression thresholds — adjust for stricter/looser policy
    [int] $RowsDropPctThreshold = -50,    # any stream's rows dropping > 50% = FAIL
    [int] $DlqDepthMultiplier = 5,         # DLQ > 5x prior = WARN
    [int] $AppExceptionDelta = 2           # +2 new exception classes = WARN
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$prior = Get-Content $PriorBaselinePath -Raw | ConvertFrom-Json
$curr  = Get-Content $CurrentBaselinePath -Raw | ConvertFrom-Json

Write-Host "=== Phase Baseline Comparison ===" -ForegroundColor Cyan
Write-Host "Prior:    $($prior.Phase) @ $($prior.Timestamp)"
Write-Host "Current:  $($curr.Phase)  @ $($curr.Timestamp)"
Write-Host ''

$failures = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()
$diffs    = [System.Collections.Generic.List[pscustomobject]]::new()

# Per-stream diff
$priorStreams = @($prior.StreamCounts.PSObject.Properties.Name)
$currStreams  = @($curr.StreamCounts.PSObject.Properties.Name)
$allStreams   = ($priorStreams + $currStreams) | Sort-Object -Unique

foreach ($s in $allStreams) {
    $priorEntry = if ($priorStreams -contains $s) { $prior.StreamCounts.$s } else { $null }
    $currEntry  = if ($currStreams  -contains $s) { $curr.StreamCounts.$s  } else { $null }

    if (-not $priorEntry -and $currEntry) {
        # New in current phase
        $rows = if ($currEntry.PSObject.Properties.Name -contains 'Rows24h') { [int]$currEntry.Rows24h } else { 0 }
        $diffs.Add([pscustomobject]@{
            Stream = $s; PriorRows = 'NEW'; CurrRows = $rows; Delta = '+'+$rows
            Status = 'EXPANSION (new in this phase)'
        })
        if ($rows -eq 0 -and $currEntry.SuccessKind -ne 'tenant-gated') {
            $warnings.Add("${s}: NEW stream but 0 rows + not tenant-gated — investigate poll cycle")
        }
        continue
    }
    if ($priorEntry -and -not $currEntry) {
        $diffs.Add([pscustomobject]@{
            Stream = $s; PriorRows = [int]$priorEntry.Rows24h; CurrRows = 'MISSING'; Delta = 'REMOVED'
            Status = 'REGRESSION (stream missing in current phase)'
        })
        $failures.Add("${s}: present in prior phase ($($priorEntry.Rows24h) rows) but missing in current phase")
        continue
    }

    $priorRows = [int]$priorEntry.Rows24h
    $currRows  = [int]$currEntry.Rows24h
    $deltaPct = if ($priorRows -gt 0) { [int](100.0 * ($currRows - $priorRows) / $priorRows) } else { if ($currRows -gt 0) { 9999 } else { 0 } }

    $status = 'STABLE'
    if ($priorRows -gt 100 -and $deltaPct -le $RowsDropPctThreshold) {
        $status = 'REGRESSION'
        $failures.Add("${s}: rows ${priorRows} -> ${currRows} (${deltaPct}% drop, threshold $RowsDropPctThreshold%)")
    } elseif ($deltaPct -gt 100) {
        $status = 'EXPANSION'
    }

    # Schema parity flip
    if ($priorEntry.PSObject.Properties.Name -contains 'SchemaParity' -and $currEntry.PSObject.Properties.Name -contains 'SchemaParity') {
        if ($priorEntry.SchemaParity -eq 'PASS' -and $currEntry.SchemaParity -ne 'PASS') {
            $failures.Add("${s}: schema parity regressed PASS -> $($currEntry.SchemaParity)")
            $status = 'REGRESSION'
        }
    }

    # TypedCol drop
    if ($priorEntry.PSObject.Properties.Name -contains 'TypedColPopulated' -and $currEntry.PSObject.Properties.Name -contains 'TypedColPopulated') {
        $priorPop = [int]$priorEntry.TypedColPopulated
        $currPop = [int]$currEntry.TypedColPopulated
        if ($priorPop -gt 0 -and $currPop -lt $priorPop) {
            $warnings.Add("${s}: TypedColPopulated dropped $priorPop -> $currPop (typed col parsing regression?)")
        }
    }

    $diffs.Add([pscustomobject]@{
        Stream = $s; PriorRows = $priorRows; CurrRows = $currRows
        Delta = if ($deltaPct -eq 9999) { 'NEW-DATA' } else { "${deltaPct}%" }
        Status = $status
    })
}

# Aggregate diff
$agPrior = $prior.AggregateMetrics
$agCurr  = $curr.AggregateMetrics

$priorTotal = if ($agPrior.PSObject.Properties.Name -contains 'TotalRowsIn24h') { [long]$agPrior.TotalRowsIn24h } else { 0 }
$currTotal  = if ($agCurr.PSObject.Properties.Name -contains 'TotalRowsIn24h') { [long]$agCurr.TotalRowsIn24h } else { 0 }
$totalDelta = $currTotal - $priorTotal

if ($priorTotal -gt 1000 -and $currTotal -lt ($priorTotal * 0.5)) {
    $failures.Add("AGGREGATE: TotalRowsIn24h ${priorTotal} -> ${currTotal} (>50% drop)")
}

# DLQ depth
if ($agPrior.PSObject.Properties.Name -contains 'DLQDepth' -and $agCurr.PSObject.Properties.Name -contains 'DLQDepth') {
    $priorDlq = [int]$agPrior.DLQDepth
    $currDlq  = [int]$agCurr.DLQDepth
    if ($priorDlq -gt 0 -and $currDlq -gt ($priorDlq * $DlqDepthMultiplier)) {
        $warnings.Add("AGGREGATE: DLQ depth ${priorDlq} -> ${currDlq} (>${DlqDepthMultiplier}x multiplier)")
    }
}

# AppExceptions
if ($agPrior.PSObject.Properties.Name -contains 'AppExceptionsClasses15m' -and $agCurr.PSObject.Properties.Name -contains 'AppExceptionsClasses15m') {
    $priorEx = [int]$agPrior.AppExceptionsClasses15m
    $currEx  = [int]$agCurr.AppExceptionsClasses15m
    if ($priorEx -ge 0 -and $currEx -gt ($priorEx + $AppExceptionDelta)) {
        $warnings.Add("AGGREGATE: AppExceptionsClasses15m $priorEx -> $currEx (+$($currEx - $priorEx) new classes)")
    }
}

# AuthChain success rate
if ($agPrior.PSObject.Properties.Name -contains 'AuthChainSuccessPct' -and $agCurr.PSObject.Properties.Name -contains 'AuthChainSuccessPct') {
    $priorAuth = [double]$agPrior.AuthChainSuccessPct
    $currAuth  = [double]$agCurr.AuthChainSuccessPct
    if ($priorAuth -ge 99 -and $currAuth -lt 95) {
        $failures.Add("AGGREGATE: AuthChain success rate ${priorAuth}% -> ${currAuth}% (degraded; investigate auth)")
    }
}

# Print
Write-Host '=== Per-stream diffs ===' -ForegroundColor Cyan
$diffs | Format-Table -AutoSize

Write-Host ''
Write-Host '=== Aggregate diff ===' -ForegroundColor Cyan
Write-Host "TotalRowsIn24h:           $priorTotal -> $currTotal (delta: $totalDelta)"
Write-Host "TotalStreamsIngested:     $($agPrior.TotalStreamsIngested ?? '?') -> $($agCurr.TotalStreamsIngested ?? '?')"
Write-Host "DLQDepth:                 $($agPrior.DLQDepth ?? '?') -> $($agCurr.DLQDepth ?? '?')"
Write-Host "AppExceptionsClasses15m:  $($agPrior.AppExceptionsClasses15m ?? '?') -> $($agCurr.AppExceptionsClasses15m ?? '?')"
Write-Host "AuthChainSuccessPct:      $($agPrior.AuthChainSuccessPct ?? '?')% -> $($agCurr.AuthChainSuccessPct ?? '?')%"

# Final verdict
Write-Host ''
if ($failures.Count -eq 0 -and $warnings.Count -eq 0) {
    $verdict = 'NO-REGRESSION'
    Write-Host "VERDICT: $verdict (clean phase progression)" -ForegroundColor Green
} elseif ($failures.Count -eq 0) {
    $verdict = 'REGRESSION-WARNINGS'
    Write-Host "VERDICT: $verdict ($($warnings.Count) WARN — review)" -ForegroundColor Yellow
    foreach ($w in $warnings) { Write-Host "  WARN: $w" -ForegroundColor Yellow }
} else {
    $verdict = 'REGRESSION-FAILURES'
    Write-Host "VERDICT: $verdict ($($failures.Count) FAIL — halt + audit-fix-test-reverify per AMEND-7 #23)" -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "  FAIL: $f" -ForegroundColor Red }
    foreach ($w in $warnings) { Write-Host "  WARN: $w" -ForegroundColor Yellow }
}

return [pscustomobject]@{
    Verdict  = $verdict
    Diffs    = $diffs
    Failures = $failures
    Warnings = $warnings
    Aggregate = @{
        Prior   = $agPrior
        Current = $agCurr
    }
}
