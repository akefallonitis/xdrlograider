function Get-XdrPortalRate429Count {
    <#
    .SYNOPSIS
        Returns the L2 Defender module-scope cumulative 429 count since the last reset.

    .DESCRIPTION
        Consumed by Invoke-MDETierPoll (in Xdr.Defender.Client) to populate
        MDE_Heartbeat_CL.Notes.rate429Count. The counter lives in
        $script:Rate429Count inside Xdr.Defender.Auth.psm1; this accessor is
        the public read-path for callers in sibling modules.

    .OUTPUTS
        [int] — current cumulative 429 count

    .EXAMPLE
        # Inside Invoke-MDETierPoll, after processing all streams:
        $rate429 = Get-XdrPortalRate429Count
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()
    return [int]$script:Rate429Count
}
