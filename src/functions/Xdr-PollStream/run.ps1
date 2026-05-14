# Xdr-PollStream — Durable Functions activity (Section R consolidation, 2026-05-06).
#
# Receives input: @{ Portal, Tier, StreamName, StreamPath, OperationId }
# Performs auth (cached per FA instance via Connect-DefenderPortal's session
# cache) + single-stream poll + Send-ToLogAnalytics ingest + DLQ replay (in
# SEPARATE batch with post-success deletion) + final-step Set-XdrTierStateRow.
# Returns: @{ StreamName, Tier, Portal, RowsIngested, LatencyMs, Success, Error, DlqDrained, OperationId }
#
# Activities CAN be non-deterministic (KV reads, portal API calls, current
# time, exception handling, Storage writes) — only orchestrators must be deterministic.
#
# Per internal design doc Section R.
#
# CRITICAL: The activity parameter MUST NOT be named '$Input' — that name
# shadows PowerShell's automatic $Input variable (the pipeline enumerator).
# Live forensic 2026-05-06 (commit fb2c6f4): rename to $ActivityInput is REQUIRED;
# function.json binding name is also 'ActivityInput' to match.
param($ActivityInput)

$ErrorActionPreference = 'Stop'
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# Activity input from Durable orchestrator is a JObject; .Property returns
# JValue. Explicit [string] cast prevents the same JValue->String cast crash.
$portal      = [string]$ActivityInput.Portal
$tier        = [string]$ActivityInput.Tier
$streamName  = [string]$ActivityInput.StreamName
# Phase A1: EntryKey is the unique manifest dispatch key (`<sub_area>::<slug>`).
# StreamName (workspace table) is shared across many EntryKeys within a sub-area
# — only EntryKey uniquely identifies one endpoint. Fall back to StreamName for
# legacy callers (pre-A1 orchestrators), but log a deprecation warning so we
# can remove the fallback in v0.2.0.
$entryKey    = [string]$ActivityInput.EntryKey
if ([string]::IsNullOrWhiteSpace($entryKey)) {
    Write-Warning "Xdr-PollStream: ActivityInput missing EntryKey; falling back to StreamName='$streamName'. Orchestrator should pass EntryKey explicitly (Phase A1)."
    $entryKey = $streamName
}
# Section R B-4: OperationId propagation. Falls back to a per-activity GUID if
# orchestrator didn't supply one (legacy callers).
$opId        = [string]$ActivityInput.OperationId
if ([string]::IsNullOrWhiteSpace($opId)) { $opId = ([Guid]::NewGuid().ToString()) }

# Read FA config from $env:* (process-scoped; always present per profile.ps1)
$config = [pscustomobject]@{
    KeyVaultUri          = $env:KEY_VAULT_URI
    AuthSecretName       = $env:AUTH_SECRET_NAME
    AuthMethod           = $env:AUTH_METHOD
    ServiceAccountUpn    = $env:SERVICE_ACCOUNT_UPN
    DceEndpoint          = $env:DCE_ENDPOINT
    DcrImmutableIdsJson  = $env:DCR_IMMUTABLE_IDS_JSON
    StorageAccountName   = $env:STORAGE_ACCOUNT_NAME
    CheckpointTable      = $env:CHECKPOINT_TABLE_NAME
    DlqTable             = $env:XDR_INGEST_DLQ_TABLE_NAME
    ExpectedTenantId     = $env:TENANT_ID
}

# B1 (Plan R+++++++++.2): pre-activity config validation. If env vars are unset
# (mis-deployed FA, stale ARM, manual env var deletion), Set-XdrTierStateRow + DCE
# ingest fail silently; connector card flips Disconnected with no operator signal.
# Throw before auth so AppInsights captures Phase='config-validation' for KQL alerts.
$missingConfig = @()
foreach ($k in 'KeyVaultUri','AuthSecretName','AuthMethod','DceEndpoint','DcrImmutableIdsJson','StorageAccountName','CheckpointTable','DlqTable','ExpectedTenantId') {
    if ([string]::IsNullOrWhiteSpace($config.$k)) { $missingConfig += $k }
}
if ($missingConfig.Count -gt 0) {
    $errMsg = "Config validation FAIL — missing env vars: $($missingConfig -join ', '). FA may be mis-deployed (ARM template + WEBSITE_RUN_FROM_PACKAGE update both required). Phase='config-validation'."
    try {
        Send-XdrAppInsightsTrace -Message $errMsg -SeverityLevel 'Error' -Properties @{
            Phase       = 'config-validation'
            Stream      = $streamName
            Tier        = $tier
            OperationId = $opId
            MissingVars = ($missingConfig -join ',')
        }
    } catch { }
    throw $errMsg
}

$dlqDrained = 0
$dlqEntries = @()

# Decision 18 circuit-breaker state — initialized at function scope so the
# catch block (~line 549) can still read $priorConsecutiveErrors when the try
# body throws after the prior-row read. Defaults survive a read failure.
$priorConsecutiveErrors = 0
$priorCircuitState      = 'closed'

# Per-stream circuit-breaker pre-flight. Read the prior XdrTierState row so we
# can (a) skip the poll entirely when CircuitState='open' and CooldownUntilUtc
# hasn't expired, and (b) chain ConsecutiveErrors across cycles (Decision 18:
# 3 consecutive errors -> open + 30-min cooldown). When cooldown expires the
# next cycle's attempt is implicitly half-open — a single trial whose result
# re-classifies the breaker: success -> closed (reset), error -> open again
# with fresh cooldown. The orchestrator already does a tier-level pre-flight
# (skip whole fan-out when ALL streams open); this is the per-stream gate.
try {
    $priorRow = Invoke-XdrStorageTableEntity `
        -StorageAccountName $config.StorageAccountName `
        -TableName          'XdrTierState' `
        -PartitionKey       $portal `
        -RowKey             $entryKey `
        -Operation          'Get'
} catch {
    $priorRow = $null
    Write-Warning ("Xdr-PollStream {0}: prior tier-state read failed (continuing without circuit-breaker context): {1}" -f $entryKey, $_.Exception.Message)
}
if ($priorRow) {
    if ($priorRow.PSObject.Properties['ConsecutiveErrors']) {
        try { $priorConsecutiveErrors = [int]$priorRow.ConsecutiveErrors } catch { $priorConsecutiveErrors = 0 }
    }
    if ($priorRow.PSObject.Properties['CircuitState']) {
        $priorCircuitState = [string]$priorRow.CircuitState
    }
    if ($priorCircuitState -eq 'open') {
        $cooldownExpired = $true
        if ($priorRow.PSObject.Properties['CooldownUntilUtc'] -and $priorRow.CooldownUntilUtc) {
            try {
                $cu = [DateTime]::Parse([string]$priorRow.CooldownUntilUtc)
                $cooldownExpired = ($cu -le [DateTime]::UtcNow)
            } catch { $cooldownExpired = $true }
        }
        if (-not $cooldownExpired) {
            Write-Information ("Xdr-PollStream {0}: circuit-breaker OPEN (cooldown until {1}); skipping poll" -f $entryKey, $priorRow.CooldownUntilUtc)
            if (Get-Command -Name Send-XdrAppInsightsCustomEvent -ErrorAction SilentlyContinue) {
                try {
                    Send-XdrAppInsightsCustomEvent -EventName 'xdr.poll.skip.circuit_open' `
                        -OperationId $opId `
                        -Properties @{
                            Stream            = $streamName
                            EntryKey          = $entryKey
                            Tier              = $tier
                            Portal            = $portal
                            ConsecutiveErrors = $priorConsecutiveErrors
                            CooldownUntilUtc  = [string]$priorRow.CooldownUntilUtc
                        }
                } catch { }
            }
            $sw.Stop()
            return @{
                StreamName    = $streamName
                Tier          = $tier
                Portal        = $portal
                RowsIngested  = 0
                LatencyMs     = [int]$sw.ElapsedMilliseconds
                Success       = $true
                Error         = $null
                DlqDrained    = 0
                OperationId   = $opId
                SkippedReason = 'circuit-open'
            }
        }
    }
}

try {
    # Auth — Connect-DefenderPortal caches session per FA instance for ~50 min.
    $authBundle = Get-XdrAuthFromKeyVault `
        -VaultUri     $config.KeyVaultUri `
        -SecretPrefix $config.AuthSecretName `
        -AuthMethod   $config.AuthMethod
    $session = Connect-DefenderPortal `
        -Method     $config.AuthMethod `
        -Credential $authBundle `
        -TenantId   $config.ExpectedTenantId

    # Pop any DLQ entries for this stream first (drain before fresh ingest).
    # Section R B-3: keep DLQ entries (NOT just rows) so we can REPLAY each in
    # a SEPARATE batch with post-success deletion (idempotent under orchestrator replay).
    try {
        $dlqEntries = @(Pop-XdrIngestDlq `
            -StorageAccountName $config.StorageAccountName `
            -TableName          $config.DlqTable `
            -StreamName         "Custom-$streamName" `
            -MaxBatches         5)
    } catch {
        Write-Warning ("Xdr-PollStream: DLQ pop failed for {0}: {1}" -f $streamName, $_.Exception.Message)
        $dlqEntries = @()
    }

    # Section R++ CHECKPOINT MECHANISM (2026-05-07): for streams whose manifest
    # entry declares Filter='fromDate' (incremental-poll capable), read the last
    # successful poll timestamp from connectorCheckpoints Storage table + pass
    # as -FromUtc so the API server-side ?fromDate filter only returns NEW events.
    # Without this, every poll re-fetches full history (e.g. ActionCenter every
    # 10min would re-pull all alerts since epoch — wasteful + may rate-limit).
    # The activity is best-effort: if checkpoint read fails, fall back to no
    # filter (Get-CheckpointTimestamp returns DateTime.MinValue on first run).
    $manifest = Get-XdrEndpointManifest -Portal Defender
    # Phase A1: lookup by EntryKey (unique per endpoint), not StreamName (shared
    # across many endpoints in a sub-area). EntryKey is the canonical dispatch key.
    $manifestEntry = $manifest[$entryKey]
    if (-not $manifestEntry) {
        # Fallback: try StreamName (legacy/transition).
        $manifestEntry = $manifest[$streamName]
        if ($manifestEntry) {
            Write-Warning "Xdr-PollStream: manifest lookup fell back to StreamName='$streamName' (no EntryKey='$entryKey' match)"
        }
    }
    $hasFromDateFilter = $manifestEntry -and
                         $manifestEntry.ContainsKey('Filter') -and
                         [string]$manifestEntry.Filter -eq 'fromDate'
    # Use EntryKey for Invoke-MDEEndpoint dispatch (ByEntryKey param set).
    $invokeArgs = @{ Session = $session; EntryKey = $entryKey }
    if ($hasFromDateFilter) {
        $checkpointFromUtc = Get-CheckpointTimestamp `
            -StorageAccountName $config.StorageAccountName `
            -StreamName         $streamName `
            -TableName          $config.CheckpointTable
        if ($checkpointFromUtc -gt [DateTime]::MinValue) {
            $invokeArgs['FromUtc'] = $checkpointFromUtc
            Write-Information ("Xdr-PollStream {0}: incremental poll from {1:o}" -f $streamName, $checkpointFromUtc)
        } else {
            Write-Information ("Xdr-PollStream {0}: first run (no checkpoint) — full snapshot" -f $streamName)
        }
    }

    # Section R++++++ Architecture A PerEntityFanout (2026-05-07): if manifest declares
    # `PerEntityFanout = @{ Source='MDE_Machines_CL'; PathParam='MachineId'; ... }`,
    # iterate entities from the source stream, call Invoke-MDEEndpoint with
    # -PathParams @{$pathParam=$entityId}, aggregate rows. Composite checkpoint
    # key {Stream}|{EntityId} for per-entity resume. Cap MaxEntitiesPerCycle to
    # avoid 429-storms in 10K-machine tenants.
    # Activity-level fanout (sequential per-entity within one activity invocation).
    # v0.1.0.1 may move to orchestrator-level fanout via Wait-DurableTask for parallelism.
    if ($manifestEntry -and $manifestEntry.ContainsKey('PerEntityFanout') -and $manifestEntry.PerEntityFanout) {
        $fanoutCfg     = $manifestEntry.PerEntityFanout
        $sourceStream  = [string]$fanoutCfg.Source
        $entityIdField = [string]$fanoutCfg.EntityIdField
        $pathParamName = [string]$fanoutCfg.PathParam
        $maxEntities   = if ($fanoutCfg.ContainsKey('MaxEntitiesPerCycle')) { [int]$fanoutCfg.MaxEntitiesPerCycle } else { 50 }
        $perEntityChk  = $fanoutCfg.ContainsKey('CheckpointPerEntity') -and $fanoutCfg.CheckpointPerEntity

        Write-Information ("Xdr-PollStream PerEntityFanout {0}: source={1} param={2} maxPerCycle={3}" -f
            $streamName, $sourceStream, $pathParamName, $maxEntities)

        # Step 1: get entity list by polling the source stream (single call to source).
        # Phase 1A diagnostic logging (Section R++++++++++): expose source-poll
        # behavior so 0-row failures are debuggable from AppTraces.
        Write-Information ("Xdr-PollStream PerEntityFanout {0}: BEFORE source poll {1}" -f $streamName, $sourceStream)
        $sourceArgs = @{ Session = $session; Stream = $sourceStream }
        $sourceRows = @()
        $sourceErr = $null
        try {
            $rawSource = Invoke-MDEEndpoint @sourceArgs
            # Phase 1A-fix (Section R++++++++++ 2026-05-09): Phase 1A diagnostic
            # revealed Invoke-MDEEndpoint returned 1 row whose own props were array-
            # builtins ([Length,LongLength,Rank,SyncRoot,IsReadOnly,IsFixedSize,
            # IsSynchronized,Count]). Root cause: array-wrapped-in-array preservation
            # through @() — @($x) where $x is already a single-array preserves the
            # nesting, so $sourceRows[0] became the wrapping array vs first row.
            # Fix: detect the wrapped-array case + unwrap.
            if ($null -eq $rawSource) {
                $sourceRows = @()
            } elseif ($rawSource -is [System.Collections.IList] -and $rawSource.Count -gt 0 -and
                      ($rawSource[0] -isnot [System.Collections.IList])) {
                # Already a flat array of row objects — normal case
                $sourceRows = @($rawSource)
            } elseif ($rawSource -is [System.Collections.IList] -and $rawSource.Count -eq 1 -and
                      $rawSource[0] -is [System.Collections.IList]) {
                # Array-wrapped-in-array — unwrap one level
                $sourceRows = @($rawSource[0])
            } else {
                $sourceRows = @($rawSource)
            }
        } catch {
            $sourceErr = $_.Exception.Message
            Write-Warning ("Xdr-PollStream PerEntityFanout {0}: source stream {1} poll FAILED: {2}" -f
                $streamName, $sourceStream, $sourceErr)
        }
        Write-Information ("Xdr-PollStream PerEntityFanout {0}: AFTER source poll {1} returned {2} rows (err={3})" -f
            $streamName, $sourceStream, $sourceRows.Count, $(if ($sourceErr) { $sourceErr.Substring(0, [Math]::Min(80, $sourceErr.Length)) } else { 'none' }))

        # Diagnostic: dump first-row property names so we can verify the entity field
        # (e.g. 'machineId') is accessible on the row. Helps catch case-sensitivity
        # or schema-mismatch issues that would silently produce 0 entities.
        if ($sourceRows.Count -gt 0 -and $null -ne $sourceRows[0]) {
            $propNames = ($sourceRows[0].PSObject.Properties | ForEach-Object { $_.Name }) -join ','
            $sampleId = if ($sourceRows[0].PSObject.Properties[$entityIdField]) {
                [string]($sourceRows[0].$entityIdField)
            } elseif ($sourceRows[0].PSObject.Properties['EntityId']) {
                [string]($sourceRows[0].EntityId)
            } else { '<NEITHER>' }
            Write-Information ("Xdr-PollStream PerEntityFanout {0}: first source row props=[{1}]; entityIdField={2} sample={3}" -f
                $streamName, $propNames, $entityIdField, $sampleId)
        }

        # Step 2: extract distinct entity IDs from source rows; cap to MaxEntitiesPerCycle.
        $entityIds = @()
        foreach ($srow in $sourceRows) {
            if ($null -eq $srow) { continue }
            $rawId = $null
            if ($srow.PSObject.Properties[$entityIdField]) {
                $rawId = $srow.$entityIdField
            } elseif ($srow.PSObject.Properties['EntityId']) {
                $rawId = $srow.EntityId
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$rawId)) {
                $entityIds += [string]$rawId
            }
        }
        $entityIds = @($entityIds | Select-Object -Unique | Select-Object -First $maxEntities)

        Write-Information ("Xdr-PollStream PerEntityFanout {0}: iterating {1} entities (capped at {2}) — sourceRowCount={3}" -f
            $streamName, $entityIds.Count, $maxEntities, $sourceRows.Count)

        # Step 3: iterate entities, call per-entity, aggregate rows.
        $aggregated = @()
        # Rule 6: 4-value SuccessKind set (tenant-gated retired per Rule 23 —
        # license-blocked endpoints stay 'error' with LicenseHint populated).
        $entityResults = @{ live = 0; 'live-empty' = 0; 'rate-limited' = 0; error = 0 }
        foreach ($eid in $entityIds) {
            $entityArgs = @{} + $invokeArgs
            $entityArgs['PathParams'] = @{ $pathParamName = $eid }

            # Per-entity checkpoint resume (composite key {Stream}|{EntityId})
            if ($perEntityChk -and $hasFromDateFilter) {
                try {
                    $entityCheckpoint = Get-CheckpointTimestamp `
                        -StorageAccountName $config.StorageAccountName `
                        -StreamName         ("$streamName|$eid") `
                        -TableName          $config.CheckpointTable
                    if ($entityCheckpoint -gt [DateTime]::MinValue) {
                        $entityArgs['FromUtc'] = $entityCheckpoint
                    }
                } catch {
                    # Per-entity checkpoint is best-effort; fall back to no filter.
                }
            }

            try {
                $entityRows = @(Invoke-MDEEndpoint @entityArgs)
                $entityLast = Get-MDEEndpointLastResult
                $kindKey = if ($entityLast) { $entityLast.SuccessKind } else { 'unknown' }
                if ($entityResults.ContainsKey($kindKey)) { $entityResults[$kindKey]++ } else { $entityResults[$kindKey] = 1 }

                # Stamp EntityId placeholder col (e.g. MachineId) on each row.
                foreach ($row in $entityRows) {
                    if ($null -ne $row -and -not $row.PSObject.Properties[$pathParamName]) {
                        $row | Add-Member -NotePropertyName $pathParamName -NotePropertyValue $eid -Force
                    }
                }
                $aggregated += $entityRows

                # Per-entity checkpoint advance (only on live OR live-empty)
                if ($perEntityChk -and $hasFromDateFilter -and $kindKey -in 'live','live-empty') {
                    try {
                        Set-CheckpointTimestamp `
                            -StorageAccountName $config.StorageAccountName `
                            -StreamName         ("$streamName|$eid") `
                            -Timestamp          ([DateTime]::UtcNow) `
                            -TableName          $config.CheckpointTable | Out-Null
                    } catch {
                        # Checkpoint advance is best-effort.
                    }
                }
            } catch {
                $entityResults['error']++
                Write-Warning ("Xdr-PollStream PerEntityFanout {0} entity={1} failed: {2}" -f
                    $streamName, $eid, $_.Exception.Message)
            }
        }
        # Section R++++++ defensive null filter: strip $null elements before ingest.
        $freshRows = @($aggregated | Where-Object { $null -ne $_ })
        $resultSummary = ($entityResults.GetEnumerator() | Where-Object { $_.Value -gt 0 } | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '
        Write-Information ("Xdr-PollStream PerEntityFanout {0}: {1} rows across {2} entities ({3})" -f
            $streamName, $freshRows.Count, $entityIds.Count, $resultSummary)
    }
    # Section R++++++ Architecture C PerPlatformFanout (2026-05-07): if manifest declares
    # `PerPlatformFanout = @('Windows','Linux','macOS','iOS')`, iterate each platform,
    # call Invoke-MDEEndpoint with -BodyOverride @{platform=$p}, tag rows with
    # Platform col, aggregate into single stream. Operators query:
    #   Defender_<Cat>_CL | where SourceName == '<Stream>' | where Platform == 'Linux'
    # NO new streams/tables/DCRs — just multi-call activity loop with per-row tagging.
    elseif ($manifestEntry -and $manifestEntry.ContainsKey('PerPlatformFanout') -and $manifestEntry.PerPlatformFanout) {
        $platforms = @($manifestEntry.PerPlatformFanout)
        $aggregated = @()
        $platformResults = @{}
        foreach ($platform in $platforms) {
            $platformArgs = @{} + $invokeArgs
            $platformArgs['BodyOverride'] = @{ platform = $platform }
            try {
                $platformRows = @(Invoke-MDEEndpoint @platformArgs)
                $platformLast = Get-MDEEndpointLastResult
                $platformResults[$platform] = if ($platformLast) { $platformLast.SuccessKind } else { 'unknown' }
                # Stamp Platform col on each row (operators use this to filter/group).
                foreach ($row in $platformRows) {
                    if ($null -ne $row -and $row.PSObject.Properties['Platform']) {
                        # Already has Platform from API response — leave as-is.
                    } elseif ($null -ne $row) {
                        $row | Add-Member -NotePropertyName 'Platform' -NotePropertyValue $platform -Force
                    }
                }
                $aggregated += $platformRows
            } catch {
                Write-Warning ("Xdr-PollStream PerPlatformFanout {0} platform={1} failed: {2}" -f $streamName, $platform, $_.Exception.Message)
                $platformResults[$platform] = 'error'
            }
        }
        # Section R++++++ defensive null filter (2026-05-07T18:55Z): Send-ToLogAnalytics
        # GetByteCount throws on null when aggregated rows contain $null elements
        # (one platform returned null, others returned objects). Strip nulls before
        # ingest. Same defense applies to the standard single-call path below.
        $freshRows = @($aggregated | Where-Object { $null -ne $_ })
        Write-Information ("Xdr-PollStream PerPlatformFanout {0}: {1} rows across {2} platforms ({3})" -f
            $streamName, $freshRows.Count, $platforms.Count, (($platformResults.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '))
    } else {
        # Standard single-call path (no fanout).
        # Phase A0.3: multi-cycle pagination resume. Read checkpoint state — if a
        # prior cycle hit per-cycle cap with PaginationExhausted=false, resume
        # at LastCompletedPage+1. Otherwise default StartFromPage=1.
        $hasPagination = $manifestEntry -and $manifestEntry.ContainsKey('Pagination') -and $manifestEntry.Pagination
        if ($hasPagination) {
            try {
                $ckptState = Get-CheckpointState `
                    -StorageAccountName $config.StorageAccountName `
                    -StreamName         $streamName `
                    -TableName          $config.CheckpointTable
                if ($ckptState.LastCompletedPage -gt 0) {
                    $invokeArgs['StartFromPage'] = ($ckptState.LastCompletedPage + 1)
                    Write-Information ("Xdr-PollStream {0}: resuming pagination at page {1}" -f $streamName, $invokeArgs['StartFromPage'])
                }
                # Y1 10-min activity cap → bound per-cycle pages. PageSize=200 × 50 pages ≈ 50s
                # network + processing, well under cap. vuln_management with 1000-page first
                # poll spreads across 20 cycles. Operator can tune via $env if needed.
                $cycleCap = 50
                if ($env:XDR_MAX_PAGES_PER_CYCLE) {
                    try { $cycleCap = [int]$env:XDR_MAX_PAGES_PER_CYCLE } catch { }
                }
                $invokeArgs['MaxPagesPerCycle'] = $cycleCap
            } catch {
                Write-Warning ("Xdr-PollStream {0}: checkpoint state read failed (continuing without resume): {1}" -f $streamName, $_.Exception.Message)
            }
        }
        # Invoke-MDEEndpoint returns object[] of DCE-ready rows (NOT a wrapper).
        # Defensive null filter (Section R++++++): strip $null elements that
        # could otherwise bomb Send-ToLogAnalytics GetByteCount.
        $freshRows = @(@(Invoke-MDEEndpoint @invokeArgs) | Where-Object { $null -ne $_ })
    }

    # Section R++.A + Rule 6 (tenant-gated retired per Rule 23): read truth-signal
    # side-channel for Set-XdrTierStateRow. 4-value SuccessKind set:
    #   live         — rows landed
    #   live-empty   — 200, no rows (legitimate)
    #   rate-limited — 429 (apiproxy throttling; circuit-breaker handles)
    #   error        — 5xx/network OR 401/403/404 with LicenseHint populated
    #                  (license-blocked is a configuration signal, not a defect)
    # Connector-Heartbeat aggregator reads + connector-card UX never flags
    # license-blocked as a failure (LicenseHint surfaces the SKU operator needs).
    $endpointResult = Get-MDEEndpointLastResult
    $successKind = if ($endpointResult) { [string]$endpointResult.SuccessKind } else { 'live-empty' }
    $httpStatus  = if ($endpointResult) { [int]$endpointResult.HttpStatus }    else { 0 }
    $endpointErr = if ($endpointResult) { [string]$endpointResult.ErrorText }  else { '' }

    # Resolve the per-stream DCR immutableId from the deploy-time map.
    $dcrImmutableIds = $config.DcrImmutableIdsJson | ConvertFrom-Json -AsHashtable
    if (-not $dcrImmutableIds.ContainsKey($streamName)) {
        throw "Stream '$streamName' missing from DCR_IMMUTABLE_IDS_JSON env var"
    }
    $dcrId = [string]$dcrImmutableIds[$streamName]

    # Section R B-1: pass -DlqStorageAccount so terminal DCE failures push to DLQ
    # instead of throwing. Section R B-3: SEPARATE batches for fresh vs DLQ rows
    # so DLQ replay is idempotent under orchestrator retries.
    $rowsIngested = 0

    # Batch 1: fresh rows
    if ($freshRows.Count -gt 0) {
        Send-ToLogAnalytics `
            -DceEndpoint       $config.DceEndpoint `
            -DcrImmutableId    $dcrId `
            -StreamName        "Custom-$streamName" `
            -Rows              $freshRows `
            -DlqStorageAccount $config.StorageAccountName `
            -DlqOperationId    $opId | Out-Null
        $rowsIngested += $freshRows.Count
    }

    # Batch 2..N: each DLQ entry replayed individually; delete on success.
    foreach ($entry in $dlqEntries) {
        try {
            Send-ToLogAnalytics `
                -DceEndpoint       $config.DceEndpoint `
                -DcrImmutableId    $dcrId `
                -StreamName        "Custom-$streamName" `
                -Rows              $entry.Rows `
                -DlqStorageAccount $config.StorageAccountName `
                -DlqOperationId    $opId | Out-Null
            $rowsIngested += $entry.Rows.Count
            $dlqDrained++
            # Post-success: delete the DLQ row.
            try {
                Remove-XdrIngestDlqEntry `
                    -StorageAccountName $config.StorageAccountName `
                    -TableName          $config.DlqTable `
                    -PartitionKey       $entry.PartitionKey `
                    -RowKey             $entry.RowKey `
                    -OperationId        $opId | Out-Null
            } catch {
                Write-Warning ("Xdr-PollStream: DLQ row delete failed for {0} {1}/{2}: {3}" -f $streamName, $entry.PartitionKey, $entry.RowKey, $_.Exception.Message)
            }
        } catch {
            # Replay failed — leave the DLQ row in place; AttemptCount auto-increments
            # on next Pop. Operators alert on AttemptCount > 10 via XdrOps-DlqDepthAlert.
            Write-Warning ("Xdr-PollStream: DLQ replay failed for {0} {1}/{2}: {3}" -f $streamName, $entry.PartitionKey, $entry.RowKey, $_.Exception.Message)
        }
    }

    # Section R++ CHECKPOINT WRITE: for incremental-poll streams, advance the
    # checkpoint timestamp ONLY if the poll succeeded with no error (live OR
    # live-empty — both confirm we got a clean response). Tenant-gated + error
    # do NOT advance checkpoint so next retry resumes from prior FromUtc.
    if ($hasFromDateFilter -and $successKind -in 'live','live-empty') {
        try {
            $pollCompletedAt = [DateTime]::UtcNow
            Set-CheckpointTimestamp `
                -StorageAccountName $config.StorageAccountName `
                -StreamName         $streamName `
                -Timestamp          $pollCompletedAt `
                -TableName          $config.CheckpointTable
        } catch {
            Write-Warning ("Xdr-PollStream {0}: checkpoint advance failed: {1}" -f $streamName, $_.Exception.Message)
        }
    }

    # Phase A0.3: pagination-state checkpoint write. Independent of fromDate
    # filter — applies to any paginated stream (e.g. vuln_management 1000-page
    # first poll). When PaginationExhausted=false, write LastCompletedPage so
    # next cycle resumes at LastCompletedPage+1. When PaginationExhausted=true,
    # ClearPagination so the next cycle starts from page 1 (fresh poll).
    if ($successKind -in 'live','live-empty' -and $endpointResult -and
        $endpointResult.PSObject.Properties['PaginationExhausted']) {
        try {
            if ($endpointResult.PaginationExhausted) {
                Set-CheckpointTimestamp `
                    -StorageAccountName $config.StorageAccountName `
                    -StreamName         $streamName `
                    -TableName          $config.CheckpointTable `
                    -ClearPagination | Out-Null
            } else {
                Set-CheckpointTimestamp `
                    -StorageAccountName $config.StorageAccountName `
                    -StreamName         $streamName `
                    -TableName          $config.CheckpointTable `
                    -LastCompletedPage  ([int]$endpointResult.LastCompletedPage) | Out-Null
                Write-Information ("Xdr-PollStream {0}: pagination NOT exhausted; checkpointed page {1} for next-cycle resume" -f $streamName, $endpointResult.LastCompletedPage)
            }
        } catch {
            Write-Warning ("Xdr-PollStream {0}: pagination checkpoint write failed: {1}" -f $streamName, $_.Exception.Message)
        }
    }

    # Phase A1: Section R + R++.A — final-step write to XdrTierState via
    # ByProperties form (PartitionKey=<Portal>, RowKey=<EntryKey>) so
    # Connector-Heartbeat reads per-sub-area state by EntryKey lookup. LicenseHint
    # propagation (Rule 23) — license-blocked endpoints stay SuccessKind='error'
    # but operators see WHY via LicenseHint column.
    # Success classification (Rule 6):
    #   live + live-empty -> Success=$true (poll completed cleanly)
    #   rate-limited      -> Success=$true (transient; circuit-breaker handles)
    #   error             -> Success=$false (real failure; surfaces in card + alert)
    $tierStateSuccess = ($successKind -ne 'error')
    $licenseHint = if ($endpointResult -and $endpointResult.PSObject.Properties['LicenseHint']) {
        [string]$endpointResult.LicenseHint
    } else { '' }
    # Decision 18 circuit-breaker state machine. Pure helper handles the rules:
    #   live / live-empty / rate-limited -> counter resets, breaker closed
    #   error                            -> counter increments; trip at 3
    # The 'rate-limited' case explicitly does NOT count as a failure because
    # apiproxy throttling is transient and Send-ToLogAnalytics retries 429s.
    $cbNext = Get-XdrCircuitBreakerNextState `
        -PriorConsecutiveErrors $priorConsecutiveErrors `
        -SuccessKind            $successKind

    $tierStateProps = @{
        Tier              = $tier
        Stream            = $streamName
        SuccessKind       = $successKind
        HttpStatus        = $httpStatus
        LicenseHint       = $licenseHint
        Success           = $tierStateSuccess
        ErrorText         = $endpointErr
        OperationId       = $opId
        RowsIngested      = $rowsIngested
        LatencyMs         = [int]$sw.ElapsedMilliseconds
        LastRunUtc        = ([DateTime]::UtcNow).ToString('o')
        ConsecutiveErrors = $cbNext.ConsecutiveErrors
        CircuitState      = $cbNext.CircuitState
        CooldownUntilUtc  = $cbNext.CooldownUntilUtc
    }
    try {
        Set-XdrTierStateRow `
            -StorageAccountName $config.StorageAccountName `
            -PartitionKey       $portal `
            -RowKey             $entryKey `
            -Properties         $tierStateProps
    } catch {
        Write-Warning ("Xdr-PollStream: Set-XdrTierStateRow ByProperties failed for {0}: {1}" -f $entryKey, $_.Exception.Message)
    }

    $sw.Stop()

    # Per-stream AppMetrics. Operators rely on these for the ConnectorHealth
    # workbook freshness panels + cost-budget alerts (Decision 26 observability).
    if (Get-Command -Name Send-XdrAppInsightsCustomMetric -ErrorAction SilentlyContinue) {
        try {
            Send-XdrAppInsightsCustomMetric `
                -MetricName  'xdr.stream.rows_emitted' `
                -Value       $rowsIngested `
                -OperationId $opId `
                -Properties  @{ Stream = $streamName; Tier = $tier; Portal = $portal; Reason = $successKind }
            Send-XdrAppInsightsCustomMetric `
                -MetricName  'xdr.stream.poll_duration_ms' `
                -Value       ([int]$sw.ElapsedMilliseconds) `
                -OperationId $opId `
                -Properties  @{ Stream = $streamName; Tier = $tier; Portal = $portal; Reason = $successKind }
        } catch {
            # Telemetry is best-effort — do not fail the activity on metric emit failure.
            Write-Warning ("Xdr-PollStream: per-stream metric emit failed for {0}: {1}" -f $streamName, $_.Exception.Message)
        }
    }

    return @{
        StreamName    = $streamName
        Tier          = $tier
        Portal        = $portal
        RowsIngested  = $rowsIngested
        LatencyMs     = [int]$sw.ElapsedMilliseconds
        Success       = $true
        Error         = $null
        DlqDrained    = $dlqDrained
        OperationId   = $opId
    }
} catch {
    $sw.Stop()
    $errMsg = $_.Exception.Message

    # Best-effort tier-state write via ByProperties (Phase A1): record the failure
    # so Connector-Heartbeat aggregates correctly. Defensive: skip if EntryKey is unset.
    # Decision 18 circuit-breaker: chain ConsecutiveErrors from the prior-row
    # read at function entry; helper trips the breaker at 3.
    $cbNext = Get-XdrCircuitBreakerNextState `
        -PriorConsecutiveErrors $priorConsecutiveErrors `
        -SuccessKind            'error'
    if (-not [string]::IsNullOrWhiteSpace($entryKey)) {
        try {
            Set-XdrTierStateRow `
                -StorageAccountName $config.StorageAccountName `
                -PartitionKey       $portal `
                -RowKey             $entryKey `
                -Properties         @{
                    Tier              = $tier
                    Stream            = $streamName
                    SuccessKind       = 'error'
                    HttpStatus        = 0
                    LicenseHint       = ''
                    Success           = $false
                    ErrorText         = $errMsg
                    OperationId       = $opId
                    RowsIngested      = 0
                    LatencyMs         = [int]$sw.ElapsedMilliseconds
                    LastRunUtc        = ([DateTime]::UtcNow).ToString('o')
                    ConsecutiveErrors = $cbNext.ConsecutiveErrors
                    CircuitState      = $cbNext.CircuitState
                    CooldownUntilUtc  = $cbNext.CooldownUntilUtc
                }
        } catch {
            # Silent — already in error path.
        }
    }

    # Emit AppInsights exception with stream context + OperationId for forensic stitching.
    if (Get-Command -Name Send-XdrAppInsightsException -ErrorAction SilentlyContinue) {
        Send-XdrAppInsightsException `
            -Exception     $_.Exception `
            -SeverityLevel 'Warning' `
            -OperationId   $opId `
            -Properties    @{
                Stream    = $streamName
                Tier      = $tier
                Portal    = $portal
                Phase     = 'durable-activity-poll'
            }
    }
    return @{
        StreamName    = $streamName
        Tier          = $tier
        Portal        = $portal
        RowsIngested  = 0
        LatencyMs     = [int]$sw.ElapsedMilliseconds
        Success       = $false
        Error         = $errMsg
        DlqDrained    = $dlqDrained
        OperationId   = $opId
    }
}
