function Write-Heartbeat {
    <#
    .SYNOPSIS
        Appends a heartbeat row to XdrConnectorHealth_CL via the ingest pipeline.

    .DESCRIPTION
        Called at the end of every successful timer function invocation. Rows include
        timer name, tier, stream count attempted, stream count succeeded, and total
        latency. The Connector UI in Sentinel reads XdrConnectorHealth_CL to determine
        connection status.

    .PARAMETER DceEndpoint
        DCE URL (usually $env:DCE_ENDPOINT).

    .PARAMETER DcrImmutableId
        DCR immutable ID (usually $env:DCR_IMMUTABLE_ID).

    .PARAMETER FunctionName
        Timer function name (e.g., 'poll-fast-10m').

    .PARAMETER Tier
        Capability tier label. One of: ActionCenter | XspmGraph | Configuration |
        Inventory | Maintenance | Heartbeat. The first five match the per-capability
        model declared in endpoints.manifest.psd1 (per directive 12 + Phase B.3);
        'Heartbeat' is reserved for the Connector-Heartbeat timer's pure liveness
        rows. The IsConnectedQuery on the connector card explicitly excludes
        Tier='Heartbeat' rows because liveness alone does not prove data is
        flowing (D'.16 in v0.1.0 plan: gate IsConnected on actual data flow).

    .PARAMETER StreamsAttempted
        Number of streams this invocation tried.

    .PARAMETER StreamsSucceeded
        Number of streams that ingested successfully.

    .PARAMETER RowsIngested
        Total rows written across all streams.

    .PARAMETER LatencyMs
        Total invocation time.

    .PARAMETER Notes
        Optional additional structured info (as pscustomobject).

    .PARAMETER OrchestrationInstanceId
        Phase J D'.2 (2026-05-04): Durable Functions instance GUID. Null for
        legacy direct-invocation path (Invoke-TierPollWithHeartbeat fallback).
        Operators correlate heartbeat row to specific orchestration instance
        for incident debugging.

    .PARAMETER DurableActivityCount
        Phase J D'.2: number of fan-out activities (Xdr-PollStream) the
        orchestrator dispatched in this poll cycle. 0 for legacy fallback.

    .PARAMETER DurableActivitySuccessful
        Phase J D'.2: count of activities that completed successfully.

    .PARAMETER FunctionType
        Phase J D'.2: 'Simple' (Connector-Heartbeat) | 'Starter' (Defender-*-Refresh
        timer-trigger) | 'Orchestrator' (Xdr-PollOrchestrator) | 'Activity'
        (Xdr-PollStream).

    .PARAMETER Portal
        Phase J D'.2: portal identifier (Defender|Entra|Purview|Intune). Default
        'Defender' for v0.1.0 GA. v0.2.0 multi-portal expansion adds others.

    .OUTPUTS
        Same shape as Send-ToLogAnalytics.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $DceEndpoint,
        [Parameter(Mandatory)] [string] $DcrImmutableId,
        [Parameter(Mandatory)] [string] $FunctionName,
        [Parameter(Mandatory)]
        # Phase B.3 capability-themed Tier values per directive 12.
        # 'Heartbeat' kept for Connector-Heartbeat's own liveness rows (it is not
        # a Defender capability — it's pure liveness; IsConnectedQuery excludes
        # Tier='Heartbeat' per D'.16 to gate IsConnected on actual data flow).
        # Phase K (2026-05-04): renamed 'overhead' -> 'Heartbeat' for semantic clarity.
        [ValidateSet('ActionCenter', 'XspmGraph', 'Configuration', 'Inventory', 'Maintenance', 'Heartbeat')]
        [string] $Tier,
        [int] $StreamsAttempted = 0,
        [int] $StreamsSucceeded = 0,
        [int] $RowsIngested = 0,
        [int] $LatencyMs = 0,
        [pscustomobject] $Notes = $null,
        # Phase J D'.2 (2026-05-04): Durable Functions correlation + multi-portal forward-compat.
        [string] $OrchestrationInstanceId = $null,
        [Nullable[int]] $DurableActivityCount = $null,
        [Nullable[int]] $DurableActivitySuccessful = $null,
        [ValidateSet('Simple', 'Starter', 'Orchestrator', 'Activity', $null)]
        [string] $FunctionType = $null,
        [ValidateSet('Defender', 'Entra', 'Purview', 'Intune')]
        [string] $Portal = 'Defender'
    )

    $row = [ordered]@{
        TimeGenerated             = [datetime]::UtcNow.ToString('o')
        FunctionName              = $FunctionName
        Tier                      = $Tier
        StreamsAttempted          = $StreamsAttempted
        StreamsSucceeded          = $StreamsSucceeded
        RowsIngested              = $RowsIngested
        LatencyMs                 = $LatencyMs
        HostName                  = [System.Environment]::MachineName
        Notes                     = if ($Notes) { $Notes | ConvertTo-Json -Compress -Depth 5 } else { '{}' }
        OrchestrationInstanceId   = $OrchestrationInstanceId
        DurableActivityCount      = $DurableActivityCount
        DurableActivitySuccessful = $DurableActivitySuccessful
        FunctionType              = $FunctionType
        Portal                    = $Portal
    }

    Send-ToLogAnalytics `
        -DceEndpoint $DceEndpoint `
        -DcrImmutableId $DcrImmutableId `
        -StreamName 'Custom-XdrConnectorHealth_CL' `
        -Rows @([pscustomobject]$row)
}
