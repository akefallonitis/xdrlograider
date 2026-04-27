# validate-auth-selftest — validates the full auth chain end-to-end.
# Runs every 10 minutes for the first hour post-deploy, then every hour.
# Once 3 consecutive successes, writes the 'auth validated' flag that production
# poll timers gate on. If auth breaks, subsequent polls are skipped until fixed.

param($Timer)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$fnName = 'validate-auth-selftest'

$config = $global:XdrLogRaiderConfig
if (-not $config) {
    Write-Warning "${fnName}:global config not initialized"
    return
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
try {
    $entity = [ordered]@{
        PartitionKey  = 'auth-selftest'
        RowKey        = 'latest'
        Success       = $result.Success
        Stage         = $result.Stage
        FailureReason = if ($result.FailureReason) { $result.FailureReason } else { '' }
        LastRunUtc    = [datetime]::UtcNow.ToString('o')
    }
    Add-AzTableRow -Table $table.CloudTable `
        -PartitionKey 'auth-selftest' `
        -RowKey 'latest' `
        -Property $entity `
        -UpdateExisting | Out-Null
} catch {
    Write-Warning "${fnName}:failed to persist gating flag: $_"
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
