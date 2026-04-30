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
        Cadence tier label. One of: fast | exposure | config | inventory |
        maintenance | overhead. The first five match the per-Category cadence
        model declared in endpoints.manifest.psd1; 'overhead' is reserved for
        the heartbeat-5m timer's own bookkeeping rows.

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
        [ValidateSet('fast', 'exposure', 'config', 'inventory', 'maintenance', 'overhead')]
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
