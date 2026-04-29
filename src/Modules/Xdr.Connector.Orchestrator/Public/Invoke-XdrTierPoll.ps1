function Invoke-XdrTierPoll {
    <#
    .SYNOPSIS
        Portal-routing wrapper for per-tier batch polling. Routes to the
        per-portal tier-poll function based on the -Portal value.

    .DESCRIPTION
        Today routes 'Defender' to Invoke-MDETierPoll (Xdr.Defender.Client).
        Future portals will register their own per-portal tier-poll function
        in the orchestrator's routing table.

        The function performs:
          1. -Portal value validation.
          2. Pass-through to the per-portal tier-poll function with -Session,
             -Tier, -Config splatted as-is.

    .PARAMETER Session
        PortalSession returned by Connect-XdrPortal.

    .PARAMETER Tier
        Tier label (e.g. P0..P7) recognised by the target per-portal poller.

    .PARAMETER Config
        Runtime config object/hashtable forwarded to the per-portal poller.
        Required keys: DceEndpoint, DcrImmutableId, StorageAccountName,
        CheckpointTable.

    .PARAMETER Portal
        Portal name. Must match an entry in the orchestrator's routing table.
        Currently supported: 'Defender'.

    .PARAMETER IncludeDeferred
        Forwarded to the per-portal poller (back-compat for legacy Deferred
        manifest entries).

    .OUTPUTS
        [pscustomobject] aggregate counters as returned by the per-portal
        poller (StreamsAttempted, StreamsSucceeded, RowsIngested, Errors,
        Rate429Count, GzipBytes).

    .EXAMPLE
        $result = Invoke-XdrTierPoll -Session $s -Tier 'P0' -Config $c -Portal 'Defender'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Session,

        [Parameter(Mandatory)] [string] $Tier,

        [Parameter(Mandatory)] $Config,

        [Parameter(Mandatory)] [string] $Portal,

        [switch] $IncludeDeferred
    )

    $route = Resolve-XdrPortalRoute -Portal $Portal

    $tierPollFn = $route.TierPollFn
    if (-not (Get-Command -Name $tierPollFn -ErrorAction SilentlyContinue)) {
        throw "Invoke-XdrTierPoll: per-portal function '$tierPollFn' for portal '$Portal' is not available. Ensure module '$($route.ClientModule)' is imported."
    }

    $args = @{
        Session = $Session
        Tier    = $Tier
        Config  = $Config
    }
    if ($IncludeDeferred.IsPresent) { $args['IncludeDeferred'] = $true }

    # Dispatch through the per-portal client module's session state (Pester-friendly).
    $clientModule = Get-Module -Name $route.ClientModule
    if ($clientModule) {
        & $clientModule { param($Fn, $Splat) & $Fn @Splat } $tierPollFn $args
    } else {
        & $tierPollFn @args
    }
}
