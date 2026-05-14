function Reset-XdrPortalRate429Count {
    <#
    .SYNOPSIS
        Resets the L2 Defender cumulative 429 counter to zero.

    .DESCRIPTION
        Optional helper for callers that want to bracket a known logical batch
        of requests and surface the in-batch 429 count via Get-XdrPortalRate429Count.

        The counter lives in $script:Rate429Count inside the Xdr.Defender.Auth
        module scope (incremented by Invoke-DefenderPortalRequest on 429).
        Resetting affects only the current process's module instance; module
        reimport has the same effect. The v0.1.0 GA 4-Durable-function path
        does NOT use these helpers (per-stream 429 is observed via
        XdrTierState.SuccessKind='rate-limited' instead); they remain as a
        forward-compat surface for any caller doing aggregate batching.
    #>
    [CmdletBinding()]
    param()
    $script:Rate429Count = 0
}
