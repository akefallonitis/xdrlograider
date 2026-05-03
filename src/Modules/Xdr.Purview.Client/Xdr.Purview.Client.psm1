# Xdr.Purview.Client — L3 Purview portal manifest dispatcher scaffolding stub (v0.1.0).
# v0.2.0 implementation plan: see docs/MULTI-PORTAL.md.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-PurviewTierPoll {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Session,
        [Parameter(Mandatory)] [string] $Tier,
        [Parameter(Mandatory)] [object] $Config
    )
    throw "Invoke-PurviewTierPoll: NOT IMPLEMENTED in v0.1.0 — Purview portal is a v0.2.0 roadmap item. See docs/MULTI-PORTAL.md."
}

function Get-PurviewEndpointManifest {
    [CmdletBinding()]
    param()
    throw "Get-PurviewEndpointManifest: NOT IMPLEMENTED in v0.1.0 — Purview portal manifest is a v0.2.0 roadmap item. See docs/MULTI-PORTAL.md."
}

Export-ModuleMember -Function @(
    'Invoke-PurviewTierPoll',
    'Get-PurviewEndpointManifest'
)
