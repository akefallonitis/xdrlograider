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
        Durable Functions orchestration GUID — set by Xdr-PollOrchestrator on
        every cycle so heartbeat rows correlate to a specific orchestration
        instance for incident debugging. Null for the Connector-Heartbeat
        timer itself (it's an independent 5-min timer, not Durable).

    .PARAMETER DurableActivityCount
        Phase J D'.2: number of fan-out activities (Xdr-PollStream) the
        orchestrator dispatched in this poll cycle. 0 for legacy fallback.

    .PARAMETER DurableActivitySuccessful
        Phase J D'.2: count of activities that completed successfully.

    .PARAMETER FunctionType
        4-Durable topology labels (Decision 1):
          'Simple'       — Connector-Heartbeat (independent 5-min timer)
          'Starter'      — Xdr-Refresh (universal 1-min timer + durableClient dispatcher)
          'Orchestrator' — Xdr-PollOrchestrator (orchestrationTrigger fan-out)
          'Activity'     — Xdr-PollStream (activityTrigger per-stream poll)

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
        [string] $Portal = 'Defender',
        # H13 (Decision 15): operator-facing build pin — captured by every heartbeat
        # row so latest XdrConnectorHealth_CL row reveals the deployed version.
        [string] $ConnectorVersion = '',
        [string] $ConnectorBuildId = ''
    )

    # H14 (Decision 15): Notes MUST NEVER be '{}'/null (Rule 12). If caller did not
    # supply, emit a minimal-but-populated lean form so the contract holds even on
    # the liveness pulse. Caller-supplied Notes wins (composed lean per Heartbeat
    # function — cardState/dlqDepth/openCircuits/fatalError).
    $notesJson = if ($Notes) {
        $Notes | ConvertTo-Json -Compress -Depth 5
    } else {
        # Minimal lean fallback — at least signals liveness with no diagnostic data.
        '{"cardState":"Connected","dlqDepth":0,"openCircuits":0,"fatalError":null}'
    }

    $row = [ordered]@{
        TimeGenerated             = [datetime]::UtcNow.ToString('o')
        FunctionName              = $FunctionName
        Tier                      = $Tier
        StreamsAttempted          = $StreamsAttempted
        StreamsSucceeded          = $StreamsSucceeded
        RowsIngested              = $RowsIngested
        LatencyMs                 = $LatencyMs
        ConnectorVersion          = $ConnectorVersion
        ConnectorBuildId          = $ConnectorBuildId
        HostName                  = [System.Environment]::MachineName
        Notes                     = $notesJson
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
