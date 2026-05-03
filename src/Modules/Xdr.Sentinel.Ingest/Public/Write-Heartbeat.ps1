function Write-Heartbeat {
    <#
    .SYNOPSIS
        Appends a heartbeat row to MDE_Heartbeat_CL via the ingest pipeline.

    .DESCRIPTION
        Called at the end of every successful timer function invocation. Rows include
        timer name, tier, stream count attempted, stream count succeeded, and total
        latency. The Connector UI in Sentinel reads MDE_Heartbeat_CL to determine
        connection status.

    .PARAMETER DceEndpoint
        DCE URL (usually $env:DCE_ENDPOINT).

    .PARAMETER DcrImmutableId
        DCR immutable ID (usually $env:DCR_IMMUTABLE_ID).

    .PARAMETER FunctionName
        Timer function name (e.g., 'poll-fast-10m').

    .PARAMETER Tier
        Capability tier label. One of: ActionCenter | XspmGraph | Configuration |
        Inventory | Maintenance | overhead. The first five match the per-capability
        model declared in endpoints.manifest.psd1 (per directive 12 + Phase B.3);
        'overhead' is reserved for the Connector-Heartbeat timer's own
        bookkeeping rows.

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
        # 'overhead' kept for Connector-Heartbeat's own bookkeeping (it is not
        # a Defender capability — it's connector-layer overhead).
        [ValidateSet('ActionCenter', 'XspmGraph', 'Configuration', 'Inventory', 'Maintenance', 'overhead')]
        [string] $Tier,
        [int] $StreamsAttempted = 0,
        [int] $StreamsSucceeded = 0,
        [int] $RowsIngested = 0,
        [int] $LatencyMs = 0,
        [pscustomobject] $Notes = $null
    )

    $row = [ordered]@{
        TimeGenerated    = [datetime]::UtcNow.ToString('o')
        FunctionName     = $FunctionName
        Tier             = $Tier
        StreamsAttempted = $StreamsAttempted
        StreamsSucceeded = $StreamsSucceeded
        RowsIngested     = $RowsIngested
        LatencyMs        = $LatencyMs
        HostName         = [System.Environment]::MachineName
        Notes            = if ($Notes) { $Notes | ConvertTo-Json -Compress -Depth 5 } else { '{}' }
    }

    Send-ToLogAnalytics `
        -DceEndpoint $DceEndpoint `
        -DcrImmutableId $DcrImmutableId `
        -StreamName 'Custom-MDE_Heartbeat_CL' `
        -Rows @([pscustomobject]$row)
}
