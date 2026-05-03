# Xdr.Entra.Client — L3 Entra portal manifest dispatcher scaffolding stub (v0.1.0).
#
# v0.1.0 ships scaffolding ONLY. v0.2.0 fills in actual Entra portal endpoints
# (groups + apps + service principals + sign-in logs) following the
# Xdr.Defender.Client template.
#
# v0.2.0 implementation plan: see docs/MULTI-PORTAL.md.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-EntraTierPoll {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Session,
        [Parameter(Mandatory)] [string] $Tier,
        [Parameter(Mandatory)] [object] $Config
    )
    throw "Invoke-EntraTierPoll: NOT IMPLEMENTED in v0.1.0 — Entra portal is a v0.2.0 roadmap item. Today XdrLogRaider supports only -Portal Defender. See docs/MULTI-PORTAL.md."
}

function Get-EntraEndpointManifest {
    [CmdletBinding()]
    param()
    throw "Get-EntraEndpointManifest: NOT IMPLEMENTED in v0.1.0 — Entra portal manifest is a v0.2.0 roadmap item. See docs/MULTI-PORTAL.md."
}

Export-ModuleMember -Function @(
    'Invoke-EntraTierPoll',
    'Get-EntraEndpointManifest'
)
