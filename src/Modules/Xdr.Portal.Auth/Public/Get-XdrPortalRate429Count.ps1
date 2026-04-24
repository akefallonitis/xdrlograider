function Get-XdrPortalRate429Count {
    <#
    .SYNOPSIS
        Returns the module-scope cumulative 429 count since the last reset.

    .DESCRIPTION
        Consumed by Invoke-MDETierPoll to populate MDE_Heartbeat_CL.Notes.rate429Count.
        The counter lives in $script:Rate429Count inside Invoke-MDEPortalRequest.ps1;
        this accessor is the public read-path for callers in sibling modules
        (XdrLogRaider.Client) that need the value for heartbeat aggregation.

    .OUTPUTS
        [int] — current cumulative 429 count

    .EXAMPLE
        # Inside Invoke-MDETierPoll, after processing all streams:
        $rate429 = Get-XdrPortalRate429Count
        # pass to heartbeat as Notes.rate429Count
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()
    return [int]$script:Rate429Count
}
