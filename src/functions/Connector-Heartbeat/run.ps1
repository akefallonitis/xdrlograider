# Connector-Heartbeat — regular heartbeat, independent of any auth state.
# Writes a row to MDE_Heartbeat_CL every 5 minutes confirming the Function App
# itself is alive. Used by the Sentinel data-connector UI to show connection
# status. Per directive 12: capability-named (Connector + Heartbeat) not
# cron-named (heartbeat-5m).

param($Timer)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$sw = [System.Diagnostics.Stopwatch]::StartNew()

# Iter 13.3: read config directly from $env:* (process-scoped, always present
# per profile.ps1 required-env-vars validation). Eliminates multi-runspace
# $global state propagation bug that caused "$global:XdrLogRaiderConfig not set"
# crashes when PSWorkerInProcConcurrencyUpperBound > 1.
$config = [pscustomobject]@{
    KeyVaultUri          = $env:KEY_VAULT_URI
    AuthSecretName       = $env:AUTH_SECRET_NAME
    AuthMethod           = $env:AUTH_METHOD
    ServiceAccountUpn    = $env:SERVICE_ACCOUNT_UPN
    DceEndpoint          = $env:DCE_ENDPOINT
    DcrImmutableIdsJson  = $env:DCR_IMMUTABLE_IDS_JSON
    StorageAccountName   = $env:STORAGE_ACCOUNT_NAME
    CheckpointTable      = $env:CHECKPOINT_TABLE_NAME
    ExpectedTenantId     = $env:TENANT_ID
}

try {
    # Resolve the Heartbeat DCR immutableId from the deploy-time map.
    # 47 streams partitioned across 5 DCRs sharing 1 DCE — Heartbeat lives
    # in DCR-2 per the alphabetical partition (deploy/modules/dce-dcr.bicep).
    $heartbeatDcrId = Get-DcrImmutableIdForStream -StreamName 'MDE_Heartbeat_CL'
    Write-Heartbeat `
        -DceEndpoint $config.DceEndpoint `
        -DcrImmutableId $heartbeatDcrId `
        -FunctionName 'Connector-Heartbeat' `
        -Tier 'overhead' `
        -StreamsAttempted 0 `
        -StreamsSucceeded 0 `
        -RowsIngested 0 `
        -LatencyMs ([int]$sw.ElapsedMilliseconds) | Out-Null
    Write-Information "Connector-Heartbeat complete"
} catch {
    Write-Error "Connector-Heartbeat failed: $_"
}
