# Xdr.Purview.Auth — L2 Purview portal auth scaffolding stub (v0.1.0).
# v0.2.0 implementation plan: see docs/MULTI-PORTAL.md.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Connect-PurviewPortal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $UserPrincipalName,
        [Parameter()] [pscredential] $Credential,
        [Parameter()] [string] $TotpBase32Secret,
        [Parameter()] [string] $PasskeyJsonPath,
        [Parameter()] [hashtable] $ExistingCookies
    )
    throw "Connect-PurviewPortal: NOT IMPLEMENTED in v0.1.0 — Purview portal (compliance.microsoft.com / purview.microsoft.com) is a v0.2.0 roadmap item. Today XdrLogRaider supports only -Portal Defender. See docs/MULTI-PORTAL.md."
}

function Test-PurviewPortalAuth {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $UserPrincipalName,
        [Parameter()] [pscredential] $Credential,
        [Parameter()] [string] $TotpBase32Secret,
        [Parameter()] [string] $PasskeyJsonPath
    )
    throw "Test-PurviewPortalAuth: NOT IMPLEMENTED in v0.1.0 — Purview portal is a v0.2.0 roadmap item. See docs/MULTI-PORTAL.md."
}

Export-ModuleMember -Function @(
    'Connect-PurviewPortal',
    'Test-PurviewPortalAuth'
)
