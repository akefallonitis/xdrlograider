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
# Per .claude/plans/immutable-splashing-waffle.md Section R.
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

$dlqDrained = 0
$dlqEntries = @()

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

    # Poll fresh data via the single-endpoint dispatcher.
    # Invoke-MDEEndpoint returns object[] of DCE-ready rows (NOT a wrapper).
    # Signature: -Session, -Stream, -FromUtc (optional), -PathParams (optional). NO -Config.
    $freshRows = @(Invoke-MDEEndpoint -Session $session -Stream $streamName)

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

    # Section R: final-step write to XdrTierState so Connector-Heartbeat can
    # aggregate per-(Portal,Tier) StreamsSucceeded for the connector card.
    try {
        Set-XdrTierStateRow `
            -StorageAccountName $config.StorageAccountName `
            -Portal             $portal `
            -Tier               $tier `
            -Stream             $streamName `
            -RowsIngested       $rowsIngested `
            -Success            $true `
            -OperationId        $opId
    } catch {
        Write-Warning ("Xdr-PollStream: Set-XdrTierStateRow failed for {0}: {1}" -f $streamName, $_.Exception.Message)
    }

    $sw.Stop()
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

    # Best-effort tier-state write: record the failure so Connector-Heartbeat aggregates correctly.
    try {
        Set-XdrTierStateRow `
            -StorageAccountName $config.StorageAccountName `
            -Portal             $portal `
            -Tier               $tier `
            -Stream             $streamName `
            -RowsIngested       0 `
            -Success            $false `
            -ErrorText          $errMsg `
            -OperationId        $opId
    } catch {
        # Silent — already in error path.
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
