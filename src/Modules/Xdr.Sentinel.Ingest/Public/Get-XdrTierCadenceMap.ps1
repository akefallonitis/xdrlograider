function Get-XdrTierCadenceMap {
    <#
    .SYNOPSIS
        Returns the canonical Tier → cadence (TimeSpan) map used by Xdr-Refresh
        to determine when each (Portal, Tier) is due for re-poll.

    .DESCRIPTION
        v0.1.0 GA cadence tiers per directive 12 (capability-based naming):
          ActionCenter   → 10 min   (response-action audit, high churn)
          XspmGraph      → 1 hour   (exposure graph snapshots)
          Configuration  → 6 hours  (policy + posture state)
          Inventory      → 1 day    (asset/identity inventory)
          Maintenance    → 7 days   (rare-change ops state)

        Constant data — does NOT vary by portal. v0.2.0+ multi-portal additions
        share the SAME cadence map (all portals' streams cluster into the same
        5 tiers per the unified manifest schema).

        Returned as a [hashtable] keyed by Tier name; values are [TimeSpan].

    .OUTPUTS
        [hashtable] Tier (string) → cadence (TimeSpan)

    .EXAMPLE
        $map = Get-XdrTierCadenceMap
        $next = (Get-Date).ToUniversalTime() + $map['ActionCenter']
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    # PRODUCTION cadence (Section R++++++.4 F3 revert 2026-05-07):
    # Compressed troubleshooting cadence (1h-everything) was used during
    # iter-15→18 LIVE re-verify shake-out to surface end-to-end data flow
    # within minutes. Production tag REQUIRES the canonical cadence below
    # — compressed cadence inflates row counts ~24x (Inventory) / ~168x
    # (Maintenance) vs SLI/SLO baseline and breaches RowVolumeSpike
    # cost-budget gates.
    return @{
        ActionCenter  = [TimeSpan]::FromMinutes(10)
        XspmGraph     = [TimeSpan]::FromHours(1)
        Configuration = [TimeSpan]::FromHours(6)
        Inventory     = [TimeSpan]::FromDays(1)
        Maintenance   = [TimeSpan]::FromDays(7)
    }
}
