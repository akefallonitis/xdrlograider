# Defender-Maintenance-Refresh — refreshes the Maintenance capability per directive 12 (capability-named).
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
        Tier = 'Maintenance'
        FunctionName = 'Defender-Maintenance-Refresh'
    } -FunctionName 'Xdr-PollOrchestrator' -DurableClient $Starter
    Write-Information "Defender-Maintenance-Refresh: started orchestration $instanceId"
} else {
    # Legacy fallback: direct invocation if DurableClient binding unavailable
    Invoke-TierPollWithHeartbeat -Tier 'Maintenance' -FunctionName 'Defender-Maintenance-Refresh'
}