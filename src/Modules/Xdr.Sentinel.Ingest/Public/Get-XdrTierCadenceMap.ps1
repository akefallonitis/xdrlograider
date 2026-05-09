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

    # *** AMEND-9 COMPRESSED-CADENCE AUDIT (2026-05-09) — TEMPORARY OVERRIDE ***
    # Per Plan AMEND-2 + user directive 2026-05-09: compressed 1h-everything
    # cadence for Configuration/Inventory/Maintenance lets all 5 tiers fire
    # within ~1-1.5h so operator can audit ALL: streams + tables + schemas +
    # parsers + checkpoints + states + pagination + drift parsers + workbook
    # panels + analytic rules end-to-end without waiting 7-day Maintenance.
    #
    # Matches XdrRefresh.TierDispatch.Tests.ps1 Section R++ compressed branch.
    #
    # *** MUST REVERT BEFORE v0.1.0 GA TAG (Plan AMEND-2 BINDING) ***
    # Production cadences inline below (commented). Single revert commit:
    #   revert(observation): restore production cadence map per Plan AMEND-2
    return @{
        ActionCenter  = [TimeSpan]::FromMinutes(10)
        XspmGraph     = [TimeSpan]::FromHours(1)
        Configuration = [TimeSpan]::FromHours(1)
        Inventory     = [TimeSpan]::FromHours(1)
        Maintenance   = [TimeSpan]::FromHours(1)
    }
    # PRODUCTION cadence (REVERT TO THIS BEFORE v0.1.0 GA TAG):
    # return @{
    #     ActionCenter  = [TimeSpan]::FromMinutes(10)
    #     XspmGraph     = [TimeSpan]::FromHours(1)
    #     Configuration = [TimeSpan]::FromHours(6)
    #     Inventory     = [TimeSpan]::FromDays(1)
    #     Maintenance   = [TimeSpan]::FromDays(7)
    # }
}
