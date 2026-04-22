# poll-p0-compliance-1h — hourly poll of all Tier 0 security-configuration streams (19 endpoints).
# Fires at :15 past every hour.

param($Timer)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$fnName = 'poll-p0-compliance-1h'
Write-Information "$fnName starting — scheduled=$($Timer.ScheduleStatus.Last) isPastDue=$($Timer.IsPastDue)"

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

$credential = Get-MDEAuthFromKeyVault -VaultUri $config.KeyVaultUri -SecretName $config.AuthSecretName -AuthMethod $config.AuthMethod
$session    = Connect-MDEPortal -Method $config.AuthMethod -Credential $credential -PortalHost 'security.microsoft.com'

$result = Invoke-MDETierPoll -Session $session -Tier 'P0' -Config $config

Write-Heartbeat -DceEndpoint $config.DceEndpoint -DcrImmutableId $config.DcrImmutableId `
    -FunctionName $fnName -Tier 'P0' `
    -StreamsAttempted $result.StreamsAttempted -StreamsSucceeded $result.StreamsSucceeded `
    -RowsIngested $result.RowsIngested -LatencyMs ([int]$sw.ElapsedMilliseconds) `
    -Notes ([pscustomobject]@{ errors = $result.Errors }) | Out-Null

Write-Information "$fnName complete — $($result.StreamsSucceeded)/$($result.StreamsAttempted) streams, $($result.RowsIngested) rows, $([int]$sw.ElapsedMilliseconds)ms"
