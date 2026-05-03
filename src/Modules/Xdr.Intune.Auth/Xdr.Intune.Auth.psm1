# Xdr.Intune.Auth — L2 Intune portal auth scaffolding stub (v0.1.0).
# v0.2.0 implementation plan: see docs/MULTI-PORTAL.md.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Connect-IntunePortal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $UserPrincipalName,
        [Parameter()] [pscredential] $Credential,
        [Parameter()] [string] $TotpBase32Secret,
        [Parameter()] [string] $PasskeyJsonPath,
        [Parameter()] [hashtable] $ExistingCookies
    )
    throw "Connect-IntunePortal: NOT IMPLEMENTED in v0.1.0 — Intune portal (intune.microsoft.com) is a v0.2.0 roadmap item. Today XdrLogRaider supports only -Portal Defender. See docs/MULTI-PORTAL.md."
}

function Test-IntunePortalAuth {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $UserPrincipalName,
        [Parameter()] [pscredential] $Credential,
        [Parameter()] [string] $TotpBase32Secret,
        [Parameter()] [string] $PasskeyJsonPath
    )
    throw "Test-IntunePortalAuth: NOT IMPLEMENTED in v0.1.0 — Intune portal is a v0.2.0 roadmap item. See docs/MULTI-PORTAL.md."
}

Export-ModuleMember -Function @(
    'Connect-IntunePortal',
    'Test-IntunePortalAuth'
)
