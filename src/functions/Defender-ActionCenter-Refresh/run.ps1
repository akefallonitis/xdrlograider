# Defender-ActionCenter-Refresh — every 10 minutes, refreshes the Action Center
# capability (MDE_ActionCenter_CL + MDE_MachineActions_CL). Per directive 12:
# function name describes CAPABILITY (Action Center) not CADENCE (10m).
#
# Phase H per directive 16: this is now a Durable Functions STARTER. It
# delegates to Xdr-PollOrchestrator which fans out per-stream activities
# via Xdr-PollStream. Falls back to legacy Invoke-TierPollWithHeartbeat
# pattern if Durable Functions extension is unavailable (graceful
# degradation per Microsoft Durable Functions PowerShell guidance).
param($Timer, $Starter)

if ($Starter) {
    # Durable Functions path (preferred)
    $instanceId = Start-NewOrchestration -InputObject @{
        Portal = 'Defender'
        Tier = 'ActionCenter'
        FunctionName = 'Defender-ActionCenter-Refresh'
    } -FunctionName 'Xdr-PollOrchestrator' -DurableClient $Starter
    Write-Information "Defender-ActionCenter-Refresh: started orchestration $instanceId"
} else {
    # Legacy fallback: direct invocation if DurableClient binding unavailable
    Invoke-TierPollWithHeartbeat -Tier 'ActionCenter' -FunctionName 'Defender-ActionCenter-Refresh'
}
