# Xdr.Intune.Client — L3 Intune portal manifest dispatcher scaffolding stub (v0.1.0).
# v0.2.0 implementation plan: see docs/MULTI-PORTAL.md.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-IntuneTierPoll {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Session,
        [Parameter(Mandatory)] [string] $Tier,
        [Parameter(Mandatory)] [object] $Config
    )
    throw "Invoke-IntuneTierPoll: NOT IMPLEMENTED in v0.1.0 — Intune portal is a v0.2.0 roadmap item. See docs/MULTI-PORTAL.md."
}

function Get-IntuneEndpointManifest {
    [CmdletBinding()]
    param()
    throw "Get-IntuneEndpointManifest: NOT IMPLEMENTED in v0.1.0 — Intune portal manifest is a v0.2.0 roadmap item. See docs/MULTI-PORTAL.md."
}

Export-ModuleMember -Function @(
    'Invoke-IntuneTierPoll',
    'Get-IntuneEndpointManifest'
)
