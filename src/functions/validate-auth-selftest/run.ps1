# validate-auth-selftest — validates the full auth chain end-to-end.
# Runs every 10 minutes for the first hour post-deploy, then every hour.
# Once 3 consecutive successes, writes the 'auth validated' flag that production
# poll timers gate on. If auth breaks, subsequent polls are skipped until fixed.

param($Timer)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$fnName = 'validate-auth-selftest'

# Iter 13.3: read config directly from $env:* (strict-mode-safe, no $global dep)
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

# Iter 13.15: removed runtime Storage Table init (New-AzStorageContext + New-AzStorageTable).
# The connectorCheckpoints table is pre-created by Bicep at deploy time
# (deploy/modules/storage.bicep). Entity ops below use Invoke-XdrStorageTableEntity
# which goes directly via HttpClient + MI token to the table data plane.

# --- Run the auth chain ---
# New code may prefer the L4 orchestrator entry point:
#   $result = Test-XdrPortalAuth -Portal 'Defender' -Method $config.AuthMethod `
#                                -Credential $credential -PortalHost 'security.microsoft.com'
# The legacy Test-MDEPortalAuth call below is retained for backward-compat and
# routes through the Xdr.Portal.Auth shim → Xdr.Defender.Auth identically.
$result = $null
try {
    $credential = Get-MDEAuthFromKeyVault `
        -VaultUri $config.KeyVaultUri `
        -SecretName $config.AuthSecretName `
        -AuthMethod $config.AuthMethod

    $result = Test-MDEPortalAuth `
        -Method $config.AuthMethod `
        -Credential $credential `
        -PortalHost 'security.microsoft.com'

    Write-Information "${fnName}:auth chain result — success=$($result.Success) stage=$($result.Stage)"
} catch {
    # Build a synthetic failure result if the chain blew up before Test-MDEPortalAuth
    $result = [pscustomobject]@{
        TimeGenerated       = [datetime]::UtcNow
        Method              = $config.AuthMethod
        PortalHost          = 'security.microsoft.com'
        Upn                 = $config.ServiceAccountUpn
        Success             = $false
        Stage               = 'preflight'
        StageTimings        = @{}
        FailureReason       = $_.Exception.Message
        SccauthAcquiredUtc  = $null
        SampleCallHttpCode  = $null
        SampleCallLatencyMs = $null
    }
    Write-Error "$fnName failed before reaching Test-MDEPortalAuth: $($_.Exception.Message)"
}

# --- Write result to Log Analytics ---
try {
    Write-AuthTestResult `
        -DceEndpoint $config.DceEndpoint `
        -DcrImmutableId $config.DcrImmutableId `
        -TestResult $result | Out-Null
} catch {
    Write-Warning "${fnName}:failed to write MDE_AuthTestResult_CL: $_"
}

# --- Write the gating flag to Storage so poll timers know ---
# Iter 13.15: refactored to use Invoke-XdrStorageTableEntity Upsert
# (unified HttpClient + MI token helper). Replaces ad-hoc Invoke-RestMethod
# block. CRITICAL: helper does NOT send If-Match header on Upsert, so PUT
# behaves as Insert-Or-Replace (creates row if missing, replaces if exists).
# This was the root cause of iter-13.14: PUT + If-Match: * = Update Entity
# which 404s on first run when the row doesn't exist yet.
try {
    $entity = @{
        Success       = $result.Success
        Stage         = $result.Stage
        FailureReason = if ($result.FailureReason) { $result.FailureReason } else { '' }
        LastRunUtc    = [datetime]::UtcNow.ToString('o')
    }
    Invoke-XdrStorageTableEntity `
        -StorageAccountName $config.StorageAccountName `
        -TableName $config.CheckpointTable `
        -PartitionKey 'auth-selftest' `
        -RowKey 'latest' `
        -Operation Upsert `
        -Entity $entity -ErrorAction Stop | Out-Null
} catch {
    Write-Warning "${fnName}:failed to persist gating flag: $($_.Exception.Message)"
}

# --- Heartbeat ---
try {
    Write-Heartbeat `
        -DceEndpoint $config.DceEndpoint `
        -DcrImmutableId $config.DcrImmutableId `
        -FunctionName $fnName `
        -Tier 'overhead' `
        -StreamsAttempted 1 `
        -StreamsSucceeded ([int]$result.Success) `
        -RowsIngested 1 `
        -LatencyMs ([int]$sw.ElapsedMilliseconds) `
        -Notes ([pscustomobject]@{ stage = $result.Stage; success = $result.Success }) | Out-Null
} catch {}

Write-Information "$fnName complete — success=$($result.Success) stage=$($result.Stage) latencyMs=$([int]$sw.ElapsedMilliseconds)"
