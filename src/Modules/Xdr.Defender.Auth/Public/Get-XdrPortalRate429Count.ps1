function Get-XdrPortalRate429Count {
    <#
    .SYNOPSIS
        Returns the L2 Defender module-scope cumulative 429 count since the last reset.

    .DESCRIPTION
        Optional accessor for callers that want to surface an aggregate 429
        count across a bounded batch of Invoke-DefenderPortalRequest calls.
        The counter lives in $script:Rate429Count inside Xdr.Defender.Auth.psm1
        and is incremented by Invoke-DefenderPortalRequest on every HTTP 429.

        The v0.1.0 GA 4-Durable-function path does NOT consume this — per-
        stream 429 surfaces via XdrTierState.SuccessKind='rate-limited' and
        AppInsights metrics. Retained as a forward-compat surface.

    .OUTPUTS
        [int] — current cumulative 429 count
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()
    return [int]$script:Rate429Count
}
