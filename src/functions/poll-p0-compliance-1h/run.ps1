# poll-p0-compliance-1h — hourly poll of all Tier 0 security-configuration streams (15 endpoints, v1.0.2).
# Fires at :15 past every hour.

param($Timer)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$fnName = 'poll-p0-compliance-1h'
Write-Information "$fnName starting"

$config = $global:XdrLogRaiderConfig
if (-not $config) { throw 'Global config not initialized; profile.ps1 must run before timer functions' }

# Refuse to poll until validate-auth-selftest has signed in at least once.
if (-not (Get-XdrAuthSelfTestFlag -StorageAccountName $config.StorageAccountName -CheckpointTable $config.CheckpointTable)) {
    Write-Warning "$fnName skipped — auth self-test not yet green"
    Write-Heartbeat -DceEndpoint $config.DceEndpoint -DcrImmutableId $config.DcrImmutableId `
        -FunctionName $fnName -Tier 'P0' `
        -StreamsAttempted 0 -StreamsSucceeded 0 -RowsIngested 0 `
        -LatencyMs ([int]$sw.ElapsedMilliseconds) `
        -Notes ([pscustomobject]@{ skipped = $true; reason = 'auth not validated' }) | Out-Null
    return
}

# v1.0.2 — top-level try/catch guards against fatal errors (KV down, auth
# rejected, DCE unreachable). On failure we emit a heartbeat row with
# `fatalError` so operators see "something broke" in MDE_Heartbeat_CL rather
# than silence, then re-throw for Application Insights to capture.
try {
    $credential = Get-MDEAuthFromKeyVault -VaultUri $config.KeyVaultUri -SecretName $config.AuthSecretName -AuthMethod $config.AuthMethod
    $session    = Connect-MDEPortal -Method $config.AuthMethod -Credential $credential -PortalHost 'security.microsoft.com'

    $result = Invoke-MDETierPoll -Session $session -Tier 'P0' -Config $config

    Write-Heartbeat -DceEndpoint $config.DceEndpoint -DcrImmutableId $config.DcrImmutableId `
        -FunctionName $fnName -Tier 'P0' `
        -StreamsAttempted $result.StreamsAttempted -StreamsSucceeded $result.StreamsSucceeded `
        -RowsIngested $result.RowsIngested -LatencyMs ([int]$sw.ElapsedMilliseconds) `
        -Notes ([pscustomobject]@{ errors = $result.Errors }) | Out-Null

    Write-Information "$fnName complete — $($result.StreamsSucceeded)/$($result.StreamsAttempted) streams, $($result.RowsIngested) rows, $([int]$sw.ElapsedMilliseconds)ms"
} catch {
    $errMsg = $_.Exception.Message
    Write-Error "$fnName FATAL: $errMsg"
    try {
        Write-Heartbeat -DceEndpoint $config.DceEndpoint -DcrImmutableId $config.DcrImmutableId `
            -FunctionName $fnName -Tier 'P0' `
            -StreamsAttempted 0 -StreamsSucceeded 0 -RowsIngested 0 `
            -LatencyMs ([int]$sw.ElapsedMilliseconds) `
            -Notes ([pscustomobject]@{ fatalError = $errMsg }) | Out-Null
    } catch {
        Write-Warning ("{0}: failed to emit fatal-error heartbeat: {1}" -f $fnName, $_.Exception.Message)
    }
    throw
}