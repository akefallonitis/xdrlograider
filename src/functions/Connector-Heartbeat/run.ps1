# Connector-Heartbeat — every 5 min, emits:
#   1. ONE liveness row (Tier='Heartbeat', StreamsSucceeded=0) — proves FA is alive
#      regardless of auth/poll state.
#   2. ONE per-(Portal, Tier) aggregate row built from XdrTierState (Section R).
#      The Sentinel data-connector card's connectivityCriteria gates on
#      `StreamsSucceeded > 0` — these rows flip the card to "Connected" as soon
#      as ANY tier successfully ingests at least one stream.
#
# Per .claude/plans/immutable-splashing-waffle.md Section R.

param($Timer)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$sw = [System.Diagnostics.Stopwatch]::StartNew()

$config = [pscustomobject]@{
    DceEndpoint        = $env:DCE_ENDPOINT
    StorageAccountName = $env:STORAGE_ACCOUNT_NAME
}

try {
    $heartbeatDcrId = Get-DcrImmutableIdForStream -StreamName 'XdrConnectorHealth_CL'

    # 1) Liveness pulse (always written, regardless of poll state).
    Write-Heartbeat `
        -DceEndpoint      $config.DceEndpoint `
        -DcrImmutableId   $heartbeatDcrId `
        -FunctionName     'Connector-Heartbeat' `
        -Tier             'Heartbeat' `
        -StreamsAttempted 0 `
        -StreamsSucceeded 0 `
        -RowsIngested     0 `
        -LatencyMs        ([int]$sw.ElapsedMilliseconds) `
        -FunctionType     'Simple' `
        -Portal           'Defender' | Out-Null

    # 2) Per-(Portal, Tier) aggregate rows from XdrTierState.
    # Section R: replaces the rolled-back Xdr-WriteHeartbeat activity. The
    # activity writes per-stream rows; the heartbeat reads + aggregates here.
    $aggregateRows = @()
    if ($config.StorageAccountName) {
        try {
            $aggregateRows = @(Get-XdrTierStateAggregate `
                -StorageAccountName $config.StorageAccountName `
                -SinceUtc           ([DateTime]::UtcNow.AddHours(-24)))
        } catch {
            Write-Warning ("Connector-Heartbeat: Get-XdrTierStateAggregate failed: {0}" -f $_.Exception.Message)
        }
    }

    foreach ($row in $aggregateRows) {
        try {
            Write-Heartbeat `
                -DceEndpoint      $config.DceEndpoint `
                -DcrImmutableId   $heartbeatDcrId `
                -FunctionName     'Connector-Heartbeat' `
                -Tier             $row.Tier `
                -StreamsAttempted ([int]$row.StreamsAttempted) `
                -StreamsSucceeded ([int]$row.StreamsSucceeded) `
                -RowsIngested     ([int]$row.RowsIngested) `
                -LatencyMs        0 `
                -FunctionType     'Simple' `
                -Portal           $row.Portal | Out-Null
        } catch {
            Write-Warning ("Connector-Heartbeat: Write-Heartbeat failed for {0}|{1}: {2}" -f $row.Portal, $row.Tier, $_.Exception.Message)
        }
    }

    # B3 (Plan R+++++++++.2): emit xdr.dlq.pending_count metric so the
    # XdrOps-DlqDepthAlert analytic rule + ConnectorHealth workbook panel
    # can detect silent DLQ accumulation (DCE flap, batch-too-large loop).
    # Uses Invoke-XdrStorageTableEntity -Operation Query (the canonical
    # Storage Table helper; legacy Get-AzStorageAccount/Get-AzStorageTable
    # are forbidden in src/ per CmdletProviderCoverage gate).
    if ($config.StorageAccountName -and (Get-Command -Name Send-XdrAppInsightsCustomMetric -ErrorAction SilentlyContinue)) {
        try {
            $dlqCount = 0
            try {
                $dlqTableName = if ($env:XDR_INGEST_DLQ_TABLE_NAME) { $env:XDR_INGEST_DLQ_TABLE_NAME } else { 'xdrIngestDlq' }
                $rows = @(Invoke-XdrStorageTableEntity `
                    -StorageAccountName $config.StorageAccountName `
                    -TableName          $dlqTableName `
                    -Operation          Query)
                $dlqCount = $rows.Count
            } catch { Write-Warning "B3 DLQ count probe failed: $($_.Exception.Message)" }
            Send-XdrAppInsightsCustomMetric -MetricName 'xdr.dlq.pending_count' -Value $dlqCount -Properties @{ FunctionName = 'Connector-Heartbeat' }
        } catch {
            Write-Warning ("Connector-Heartbeat: B3 DLQ metric emit failed: {0}" -f $_.Exception.Message)
        }
    }

    Write-Information ("Connector-Heartbeat complete: emitted 1 liveness + {0} per-tier aggregate rows" -f $aggregateRows.Count)
} catch {
    Write-Error "Connector-Heartbeat failed: $_"
}
