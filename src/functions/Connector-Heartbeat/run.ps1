# Connector-Heartbeat — every 5 min, emits:
#   1. ONE liveness row (Tier='Heartbeat', StreamsSucceeded=0) — proves FA is alive
#      regardless of auth/poll state.
#   2. ONE per-(Portal, Tier) aggregate row built from XdrTierState (Section R).
#      The Sentinel data-connector card's connectivityCriteria gates on
#      `StreamsSucceeded > 0` — these rows flip the card to "Connected" as soon
#      as ANY tier successfully ingests at least one stream.
#
# Per internal design doc Section R.

param($Timer)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$sw = [System.Diagnostics.Stopwatch]::StartNew()

$config = [pscustomobject]@{
    DceEndpoint        = $env:DCE_ENDPOINT
    StorageAccountName = $env:STORAGE_ACCOUNT_NAME
}

# H13: operator-facing build pin — captured by every heartbeat row.
# ARM template sets these at deploy time; defaults preserve liveness even
# if the env vars are missing on a stale FA.
$connectorVersion = if ($env:CONNECTOR_VERSION)  { $env:CONNECTOR_VERSION }  else { '0.1.0' }
$connectorBuildId = if ($env:CONNECTOR_BUILD_ID) { $env:CONNECTOR_BUILD_ID } else { 'unknown' }

# H14 (Decision 15): lean Notes JSON — aggregate health flags ONLY.
# Per-stream detail lives in XdrTierState Storage Table (richer/cheaper).
# This composer pre-builds a single Notes object that is reused for every
# row in this cycle so all rows are correlatable on (cardState, dlqDepth).
$dlqDepth     = 0
$openCircuits = 0
$fatalError   = $null
$aggregateRows = @()

# H15: top-level try/catch wraps state-aggregation work so heartbeat row STILL
# fires (with fatalError populated + cardState='Disconnected') even when
# Storage Table reads fail. Operators must see WHY when card flips Disconnected.
try {
    if ($config.StorageAccountName) {
        try {
            $aggregateRows = @(Get-XdrTierStateAggregate `
                -StorageAccountName $config.StorageAccountName `
                -SinceUtc           ([DateTime]::UtcNow.AddHours(-24)))
        } catch {
            $fatalError = "Get-XdrTierStateAggregate failed: $($_.Exception.Message)"
            Write-Warning ("Connector-Heartbeat: {0}" -f $fatalError)
        }

        # DLQ depth probe — count rows in xdrIngestDlq Storage Table.
        try {
            $dlqTableName = if ($env:XDR_INGEST_DLQ_TABLE_NAME) { $env:XDR_INGEST_DLQ_TABLE_NAME } else { 'xdrIngestDlq' }
            $dlqRows = @(Invoke-XdrStorageTableEntity `
                -StorageAccountName $config.StorageAccountName `
                -TableName          $dlqTableName `
                -Operation          Query)
            $dlqDepth = $dlqRows.Count
        } catch {
            Write-Warning ("Connector-Heartbeat: DLQ depth probe failed: {0}" -f $_.Exception.Message)
        }

        # Count open circuits across XdrTierState per-sub-area rows.
        # v0.1.0 GA: single portal ('Defender'). v0.2.0 multi-portal aggregation
        # loops over $enabledPortals (matches Xdr-Refresh:29). Today the
        # hardcoded literal is the same single-portal scope that Xdr-Refresh
        # uses; when v0.2.0 lands, both Xdr-Refresh AND this block accept the
        # array — fully portal-agnostic with a single seed list change.
        try {
            $enabledPortals = @('Defender')  # v0.2.0: += 'Entra','Purview','Intune'
            foreach ($portal in $enabledPortals) {
                $allStateRows = Get-XdrTierStateAggregate `
                    -StorageAccountName $config.StorageAccountName `
                    -PartitionKey       $portal
                if ($allStateRows -is [System.Collections.IDictionary]) {
                    foreach ($k in $allStateRows.Keys) {
                        $r = $allStateRows[$k]
                        $cs = if ($r.PSObject.Properties['CircuitState']) { [string]$r.CircuitState } else { '' }
                        if ($cs -eq 'open') { $openCircuits++ }
                    }
                }
            }
        } catch {
            Write-Warning ("Connector-Heartbeat: open-circuit count probe failed: {0}" -f $_.Exception.Message)
        }
    } else {
        $fatalError = 'STORAGE_ACCOUNT_NAME env var not set'
    }
} catch {
    # Catch-all: any unexpected error in the aggregation chain ends up here.
    $fatalError = "Aggregation crash: $($_.Exception.Message)"
    Write-Warning ("Connector-Heartbeat: {0}" -f $fatalError)
}

$cardState = if ($fatalError) { 'Disconnected' } else { 'Connected' }
$leanNotes = [pscustomobject]@{
    cardState    = $cardState
    dlqDepth     = $dlqDepth
    openCircuits = $openCircuits
    fatalError   = $fatalError
}

try {
    $heartbeatDcrId = Get-DcrImmutableIdForStream -StreamName 'XdrConnectorHealth_CL'

    # 1) Liveness pulse — ALWAYS written, even when aggregation failed.
    # The pulse row carries fatalError + cardState='Disconnected' so operators
    # see WHY the card flipped (not just that it flipped silently).
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
        -Portal           'Defender' `
        -Notes            $leanNotes `
        -ConnectorVersion $connectorVersion `
        -ConnectorBuildId $connectorBuildId | Out-Null

    # 2) Per-(Portal, Tier) aggregate rows from XdrTierState (with same lean Notes).
    # Section R: replaces the rolled-back Xdr-WriteHeartbeat activity. The
    # activity writes per-stream rows; the heartbeat reads + aggregates here.
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
                -Portal           $row.Portal `
                -Notes            $leanNotes `
                -ConnectorVersion $connectorVersion `
                -ConnectorBuildId $connectorBuildId | Out-Null
        } catch {
            Write-Warning ("Connector-Heartbeat: Write-Heartbeat failed for {0}|{1}: {2}" -f $row.Portal, $row.Tier, $_.Exception.Message)
        }
    }

    # H12 (Decision 26): 3 critical customMetrics — xdr.heartbeat.cardState
    # (gauge 1/0) · xdr.dlq.pending_count (gauge) · xdr.subarea.circuit_state
    # (gauge per-EntryKey, 0=closed/1=half-open/2=open). Reuses $dlqDepth +
    # $openCircuits computed earlier (no second probe call).
    if ($config.StorageAccountName -and (Get-Command -Name Send-XdrAppInsightsCustomMetric -ErrorAction SilentlyContinue)) {
        try {
            $cardStateValue = if ($cardState -eq 'Connected') { 1 } else { 0 }
            Send-XdrAppInsightsCustomMetric -MetricName 'xdr.heartbeat.cardState' -Value $cardStateValue `
                -Properties @{ FunctionName = 'Connector-Heartbeat'; Portal = 'Defender' }
        } catch {
            Write-Warning ("Connector-Heartbeat: xdr.heartbeat.cardState emit failed: {0}" -f $_.Exception.Message)
        }
        try {
            Send-XdrAppInsightsCustomMetric -MetricName 'xdr.dlq.pending_count' -Value $dlqDepth `
                -Properties @{ FunctionName = 'Connector-Heartbeat' }
        } catch {
            Write-Warning ("Connector-Heartbeat: xdr.dlq.pending_count emit failed: {0}" -f $_.Exception.Message)
        }

        # Per-EntryKey circuit-state gauge (tagged per stream so operators can
        # alert on a specific stream's open circuit without polluting the whole-
        # portal heartbeat dashboard).
        try {
            $perStreamState = Get-XdrTierStateAggregate `
                -StorageAccountName $config.StorageAccountName `
                -PartitionKey       'Defender'
            if ($perStreamState -is [System.Collections.IDictionary]) {
                foreach ($entryKey in $perStreamState.Keys) {
                    $s = $perStreamState[$entryKey]
                    $cs = if ($s.PSObject.Properties['CircuitState']) { [string]$s.CircuitState } else { 'closed' }
                    $value = switch ($cs) {
                        'open'      { 2 }
                        'half-open' { 1 }
                        default     { 0 }
                    }
                    Send-XdrAppInsightsCustomMetric -MetricName 'xdr.subarea.circuit_state' -Value $value `
                        -Properties @{ FunctionName = 'Connector-Heartbeat'; EntryKey = $entryKey; CircuitState = $cs }
                }
            }
        } catch {
            Write-Warning ("Connector-Heartbeat: xdr.subarea.circuit_state emit failed: {0}" -f $_.Exception.Message)
        }
    }

    # Architecture I (Plan R++++++++++ 2026-05-08): refresh XdrTenantState daily.
    # The cache is operator-visible context enrichment (WARNING-ONLY per Plan AMEND-1
    # #5; never used to short-circuit polling). v0.1.0 GA inference: capability flags
    # derived from XdrTierState SuccessKind observations (lightweight, no workspace
    # query). v0.2.0 may upgrade to direct MDE_TenantContext_CL workspace query.
    if ($config.StorageAccountName) {
        try {
            # Derive TenantId from SAMI Az context (no env var dependency).
            $tenantId = $null
            try {
                $azCtx = Get-AzContext -ErrorAction SilentlyContinue
                if ($azCtx -and $azCtx.Tenant) { $tenantId = [string]$azCtx.Tenant.Id }
            } catch { Write-Warning "XdrTenantState: Get-AzContext failed: $($_.Exception.Message)" }
            if ($tenantId) {
                $cap = Get-XdrTenantStateCapability `
                    -StorageAccountName $config.StorageAccountName `
                    -TenantId           $tenantId
                $stale = $true
                if ($cap -and $cap.LastRefreshUtc) {
                    $age = ([DateTime]::UtcNow) - ([DateTime]::Parse($cap.LastRefreshUtc))
                    $stale = ($age.TotalHours -ge 23)
                }
                if ($stale) {
                    # Infer capability flags from observed XdrTierState SuccessKind data.
                    # Per AMEND-1 #5: WARNING-ONLY usage; never short-circuits polling.
                    $isMdatpActive = $false
                    $isXspmActive  = $false
                    foreach ($row in $aggregateRows) {
                        if ([int]$row.StreamsSucceeded -gt 0) {
                            switch ($row.Tier) {
                                'XspmGraph' { $isXspmActive  = $true }
                                'Inventory' { $isMdatpActive = $true }
                                default     {}
                            }
                        }
                    }
                    # MDI / OATP probed via specific stream names if XdrTierState is
                    # queryable per-stream; v0.1.0 GA falls back to "unknown" for those
                    # license types (LicenseTier='inferred'). v0.2.0 upgrades by reading
                    # per-stream rows or directly querying MDE_TenantContext_CL.
                    Set-XdrTenantStateCapability `
                        -StorageAccountName $config.StorageAccountName `
                        -TenantId           $tenantId `
                        -IsMdiActive        $false `
                        -IsMdatpActive      $isMdatpActive `
                        -IsOatpActive       $false `
                        -IsXspmActive       $isXspmActive `
                        -LicenseTier        'inferred-from-tier-success' `
                        -Region             ''
                    Write-Information ("Connector-Heartbeat: refreshed XdrTenantState capability cache (mdatp={0} xspm={1})" -f $isMdatpActive, $isXspmActive)
                }
            }
        } catch {
            Write-Warning ("Connector-Heartbeat: XdrTenantState refresh failed: {0}" -f $_.Exception.Message)
        }
    }

    Write-Information ("Connector-Heartbeat complete: emitted 1 liveness + {0} per-tier aggregate rows" -f $aggregateRows.Count)
} catch {
    Write-Error "Connector-Heartbeat failed: $_"
}
