function Get-MDEEndpointLastResult {
    <#
    .SYNOPSIS
        Returns the truth-signal metadata from the most recent Invoke-MDEEndpoint
        call (Section R++.A side-channel).

    .DESCRIPTION
        Invoke-MDEEndpoint preserves its legacy contract of returning ,@() on
        any failure (so existing callers + tests don't break). To distinguish
        legitimate empty responses from tenant-gating from real failures, it
        ALSO populates a module-scope $script:MDEEndpointLastResult with:
          Stream         — stream name
          SuccessKind    — live | live-empty | tenant-gated | error
          HttpStatus     — int (0 if helper failed before reaching HTTP)
          ErrorText      — error message (empty for live + live-empty)
          TimestampUtc   — when this result was set

        Activity callers (Xdr-PollStream) read this AFTER each Invoke-MDEEndpoint
        call to drive Set-XdrTierStateRow -Reason + connector-card UX.

    .OUTPUTS
        [pscustomobject] with the 5 fields above, or $null if Invoke-MDEEndpoint
        has not been called in this session.

    .EXAMPLE
        $rows = @(Invoke-MDEEndpoint -Session $s -Stream 'MDE_DeviceTimeline_CL')
        $result = Get-MDEEndpointLastResult
        if ($result.SuccessKind -eq 'tenant-gated') {
            Write-Verbose "Stream is tenant-gated; not a failure"
        }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    return $script:MDEEndpointLastResult
}

function Set-MDEEndpointLastResult {
    <#
    .SYNOPSIS
        Internal helper used by Invoke-MDEEndpoint to populate the truth-signal
        side-channel. NOT exported (module-internal).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Stream,
        [Parameter(Mandatory)]
        [ValidateSet('live', 'live-empty', 'tenant-gated', 'error')]
        [string] $SuccessKind,
        [int] $HttpStatus = 0,
        [string] $ErrorText = ''
    )
    $script:MDEEndpointLastResult = [pscustomobject]@{
        Stream       = $Stream
        SuccessKind  = $SuccessKind
        HttpStatus   = $HttpStatus
        ErrorText    = $ErrorText
        TimestampUtc = ([DateTime]::UtcNow).ToString('o')
    }
}
