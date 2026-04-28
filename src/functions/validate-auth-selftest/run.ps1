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

$context = $null
try {
    $context = New-AzStorageContext -StorageAccountName $config.StorageAccountName -UseConnectedAccount -ErrorAction Stop
    $table = Get-AzStorageTable -Name $config.CheckpointTable -Context $context -ErrorAction SilentlyContinue
    if (-not $table) {
        $table = New-AzStorageTable -Name $config.CheckpointTable -Context $context
    }
} catch {
    Write-Error "${fnName}:failed to initialize Storage Table: $_"
    return
}

# --- Run the auth chain ---
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
# Iter 13.14: switched from AzTable's Add-AzTableRow to direct REST API
# because AzTable 2.1.0 + New-AzStorageContext -UseConnectedAccount doesn't
# reliably propagate the MI auth token to AzTable's older
# Microsoft.Azure.Cosmos.Table SDK. Symptom (live evidence post iter-13.13
# deploy): Add-AzTableRow throws 'Exception calling "Execute" with "1"
# argument(s): "The specified resource does not exist."' even though the
# table exists and SAMI has Storage Table Data Contributor.
# Direct REST with Get-AzAccessToken honors MI auth natively.
try {
    $tokenObj = Get-AzAccessToken -ResourceUrl 'https://storage.azure.com/'
    $tableToken = if ($tokenObj.Token -is [System.Security.SecureString]) {
        [System.Net.NetworkCredential]::new('', $tokenObj.Token).Password
    } else {
        [string]$tokenObj.Token
    }
    $entity = [ordered]@{
        PartitionKey  = 'auth-selftest'
        RowKey        = 'latest'
        Success       = $result.Success
        Stage         = $result.Stage
        FailureReason = if ($result.FailureReason) { $result.FailureReason } else { '' }
        LastRunUtc    = [datetime]::UtcNow.ToString('o')
    }
    $tableUri = "https://$($config.StorageAccountName).table.core.windows.net/$($config.CheckpointTable)(PartitionKey='auth-selftest',RowKey='latest')"
    $headers = @{
        Authorization  = "Bearer $tableToken"
        'x-ms-version' = '2020-12-06'
        'x-ms-date'    = [datetime]::UtcNow.ToString('R')
        'Content-Type' = 'application/json'
        'Accept'       = 'application/json;odata=nometadata'
        'If-Match'     = '*'  # MERGE upsert — overwrite existing if present
    }
    Invoke-RestMethod -Method Merge -Uri $tableUri -Headers $headers -Body ($entity | ConvertTo-Json -Compress) -ErrorAction Stop | Out-Null
} catch {
    Write-Warning "${fnName}:failed to persist gating flag (direct REST): $($_.Exception.Message)"
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
