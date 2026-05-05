function Reset-XdrPortalRate429Count {
    <#
    .SYNOPSIS
        Resets the L2 Defender cumulative 429 counter to zero.

    .DESCRIPTION
        Called by Invoke-MDETierPoll at the START of each tier poll so the
        Heartbeat row reflects that tier's rate-limit pressure only, not a
        running total across all tiers in the same FA worker.

        The counter lives in $script:Rate429Count inside the Xdr.Defender.Auth
        module scope. Resetting affects only the current process's module
        instance; module reimport has the same effect.

    .EXAMPLE
        # Inside Invoke-MDETierPoll, at the start of each tier poll:
        Reset-XdrPortalRate429Count
        foreach ($stream in $tierStreams) { ... }
        $rate429 = Get-XdrPortalRate429Count
    #>
    [CmdletBinding()]
    param()
    $script:Rate429Count = 0
}
