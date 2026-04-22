# poll-p5-identity-1d — daily poll of all Tier 5 identity/MDI streams (5 endpoints).

param($Timer)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$fnName = 'poll-p5-identity-1d'

$config = $global:XdrLogRaiderConfig
if (-not $config) { throw 'Global config not initialized' }

if (-not (Get-XdrAuthSelfTestFlag -StorageAccountName $config.StorageAccountName -CheckpointTable $config.CheckpointTable)) {
    Write-Warning "$fnName skipped — auth not validated"
    Write-Heartbeat -DceEndpoint $config.DceEndpoint -DcrImmutableId $config.DcrImmutableId `
        -FunctionName $fnName -Tier 'P5' `
        -StreamsAttempted 0 -StreamsSucceeded 0 -RowsIngested 0 `
        -LatencyMs ([int]$sw.ElapsedMilliseconds) `
        -Notes ([pscustomobject]@{ skipped = $true; reason = 'auth not validated' }) | Out-Null
    return
}

$credential = Get-MDEAuthFromKeyVault -VaultUri $config.KeyVaultUri -SecretName $config.AuthSecretName -AuthMethod $config.AuthMethod
$session    = Connect-MDEPortal -Method $config.AuthMethod -Credential $credential -PortalHost 'security.microsoft.com'

$result = Invoke-MDETierPoll -Session $session -Tier 'P5' -Config $config

Write-Heartbeat -DceEndpoint $config.DceEndpoint -DcrImmutableId $config.DcrImmutableId `
    -FunctionName $fnName -Tier 'P5' `
    -StreamsAttempted $result.StreamsAttempted -StreamsSucceeded $result.StreamsSucceeded `
    -RowsIngested $result.RowsIngested -LatencyMs ([int]$sw.ElapsedMilliseconds) `
    -Notes ([pscustomobject]@{ errors = $result.Errors }) | Out-Null

Write-Information "$fnName complete — $($result.StreamsSucceeded)/$($result.StreamsAttempted) streams, $($result.RowsIngested) rows, $([int]$sw.ElapsedMilliseconds)ms"
