# Defender-XspmGraph-Refresh — refreshes the XSPM exposure-graph capability per directive 12 (capability-named).
#
# Phase H per directive 16: this is a Durable Functions STARTER. It delegates to
# Xdr-PollOrchestrator which fans out per-stream activities via Xdr-PollStream.
# Falls back to legacy Invoke-TierPollWithHeartbeat pattern if DurableClient
# binding unavailable (graceful degradation).
param($Timer, $Starter)

if ($Starter) {
    # Durable Functions path (preferred)
    $instanceId = Start-NewOrchestration -InputObject @{
        Portal = 'Defender'
        Tier = 'XspmGraph'
        FunctionName = 'Defender-XspmGraph-Refresh'
    } -FunctionName 'Xdr-PollOrchestrator' -DurableClient $Starter
    Write-Information "Defender-XspmGraph-Refresh: started orchestration $instanceId"
} else {
    # Legacy fallback: direct invocation if DurableClient binding unavailable
    Invoke-TierPollWithHeartbeat -Tier 'XspmGraph' -FunctionName 'Defender-XspmGraph-Refresh'
}