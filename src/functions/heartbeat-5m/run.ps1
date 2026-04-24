# heartbeat-5m — regular heartbeat, independent of any auth state.
# Writes a row to MDE_Heartbeat_CL every 5 minutes confirming the Function App
# itself is alive. Used by the Sentinel data-connector UI to show connection status.

param($Timer)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$sw = [System.Diagnostics.Stopwatch]::StartNew()

$config = $global:XdrLogRaiderConfig
if (-not $config) {
    Write-Warning "heartbeat-5m: global config not initialized; skipping"
    return
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
