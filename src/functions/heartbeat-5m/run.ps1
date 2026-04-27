# heartbeat-5m — regular heartbeat, independent of any auth state.
# Writes a row to MDE_Heartbeat_CL every 5 minutes confirming the Function App
# itself is alive. Used by the Sentinel data-connector UI to show connection status.

param($Timer)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$sw = [System.Diagnostics.Stopwatch]::StartNew()

# Iter 13.3: read config directly from $env:* (process-scoped, always present
# per profile.ps1 required-env-vars validation). Eliminates multi-runspace
# $global state propagation bug that caused "$global:XdrLogRaiderConfig not set"
# crashes when PSWorkerInProcConcurrencyUpperBound > 1.
$config = [pscustomobject]@{
    KeyVaultUri        = $env:KEY_VAULT_URI
    AuthSecretName     = $env:AUTH_SECRET_NAME
    AuthMethod         = $env:AUTH_METHOD
    ServiceAccountUpn  = $env:SERVICE_ACCOUNT_UPN
    DceEndpoint        = $env:DCE_ENDPOINT
    DcrImmutableId     = $env:DCR_IMMUTABLE_ID
    StorageAccountName = $env:STORAGE_ACCOUNT_NAME
    CheckpointTable    = $env:CHECKPOINT_TABLE_NAME
    ExpectedTenantId   = $env:TENANT_ID
}

try {
    Write-Heartbeat `
        -DceEndpoint $config.DceEndpoint `
        -DcrImmutableId $config.DcrImmutableId `
        -FunctionName 'heartbeat-5m' `
        -Tier 'overhead' `
        -StreamsAttempted 0 `
        -StreamsSucceeded 0 `
        -RowsIngested 0 `
        -LatencyMs ([int]$sw.ElapsedMilliseconds) | Out-Null
    Write-Information "heartbeat-5m complete"
} catch {
    Write-Error "heartbeat-5m failed: $_"
}
