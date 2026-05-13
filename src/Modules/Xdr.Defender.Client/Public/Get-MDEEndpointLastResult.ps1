function Get-MDEEndpointLastResult {
    <#
    .SYNOPSIS
        Returns the truth-signal metadata from the most recent Invoke-MDEEndpoint
        call (side-channel companion to the legacy return contract).

    .DESCRIPTION
        Invoke-MDEEndpoint preserves its legacy contract of returning ,@() on
        any failure (so existing callers + tests don't break). To distinguish
        legitimate empty responses from license-blocked endpoints from real
        failures, it ALSO populates a module-scope $script:MDEEndpointLastResult
        with:
          Stream         — stream name
          SuccessKind    — live | live-empty | rate-limited | error  (4 values, Rule 6)
          HttpStatus     — int (0 if helper failed before reaching HTTP)
          ErrorText      — error message (empty for live + live-empty)
          LicenseHint    — populated when the endpoint is license-blocked
                          (HTTP 401/403/404 + manifest-declared license requirement);
                          carries the SKU/feature name an operator needs to
                          unblock this stream. Surfaces in row metadata and
                          in XdrConnectorHealth_CL Notes.perStream[X].licenseHints.
                          Per Rule 23: licence-gated is NOT a failure mode; it's
                          a configuration signal — SuccessKind stays 'error' but
                          LicenseHint differentiates from genuine error.
          TimestampUtc   — when this result was set

        Activity callers (per-sub-area timer triggers) read this AFTER each
        Invoke-MDEEndpoint call to drive Set-XdrTierStateRow + connector-card UX.

    .OUTPUTS
        [pscustomobject] with the 6 fields above, or $null if Invoke-MDEEndpoint
        has not been called in this session.

    .EXAMPLE
        $rows = @(Invoke-MDEEndpoint -Session $s -Stream 'Defender_EndpointDevices_CL')
        $result = Get-MDEEndpointLastResult
        if ($result.LicenseHint) {
            Write-Verbose "Stream is license-blocked: needs $($result.LicenseHint)"
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
        [ValidateSet('live', 'live-empty', 'rate-limited', 'error')]
        [string] $SuccessKind,
        [int] $HttpStatus = 0,
        [string] $ErrorText = '',
        [string] $LicenseHint = '',
        # Phase A0.3: multi-cycle pagination resume side-channel. Activity layer
        # reads this after each Invoke-MDEEndpoint call to write checkpoint
        # state into connectorCheckpoints. LastCompletedPage=0 + PaginationToken=''
        # means single-cycle complete (caller should ClearPagination).
        [int] $LastCompletedPage = 0,
        [string] $PaginationToken = '',
        [bool] $PaginationExhausted = $true
    )
    $script:MDEEndpointLastResult = [pscustomobject]@{
        Stream              = $Stream
        SuccessKind         = $SuccessKind
        HttpStatus          = $HttpStatus
        ErrorText           = $ErrorText
        LicenseHint         = $LicenseHint
        LastCompletedPage   = $LastCompletedPage
        PaginationToken     = $PaginationToken
        PaginationExhausted = $PaginationExhausted
        TimestampUtc        = ([DateTime]::UtcNow).ToString('o')
    }
}
