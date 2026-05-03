# Xdr.Entra.Auth — L2 Entra portal auth scaffolding stub (v0.1.0).
#
# v0.1.0 ships scaffolding ONLY: placeholder functions throw informative
# errors. v0.2.0 fills in actual TOTP/passkey + cookie exchange following
# the Xdr.Defender.Auth template (which is the reference L2 implementation).
#
# Why scaffold in v0.1.0:
#   - Multi-portal forward-compat: Xdr.Connector.Orchestrator's $script:PortalRoutes
#     references this module without conditional/optional checks.
#   - Operator visibility: explicit "v0.2.0 roadmap" error message when an
#     operator tries -Portal Entra in v0.1.0 — clear, not silent.
#   - No surprise refactor in v0.2.0: module structure is final; only function
#     bodies change.
#
# v0.2.0 implementation plan: see docs/MULTI-PORTAL.md.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Connect-EntraPortal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $UserPrincipalName,
        [Parameter()] [pscredential] $Credential,
        [Parameter()] [string] $TotpBase32Secret,
        [Parameter()] [string] $PasskeyJsonPath,
        [Parameter()] [hashtable] $ExistingCookies
    )
    throw "Connect-EntraPortal: NOT IMPLEMENTED in v0.1.0 — Entra portal (entra.microsoft.com) is a v0.2.0 roadmap item. Today XdrLogRaider supports only -Portal Defender. See docs/MULTI-PORTAL.md for v0.2.0 plan + ETA."
}

function Test-EntraPortalAuth {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $UserPrincipalName,
        [Parameter()] [pscredential] $Credential,
        [Parameter()] [string] $TotpBase32Secret,
        [Parameter()] [string] $PasskeyJsonPath
    )
    throw "Test-EntraPortalAuth: NOT IMPLEMENTED in v0.1.0 — Entra portal is a v0.2.0 roadmap item. See docs/MULTI-PORTAL.md."
}

Export-ModuleMember -Function @(
    'Connect-EntraPortal',
    'Test-EntraPortalAuth'
)
