# Xdr.Connector.Orchestrator — L4 portal-routing dispatcher.
#
# Layering:
#   L1 Xdr.Common.Auth      — portal-generic Entra (TOTP, passkey, ESTS, KV loader)
#   L1 Xdr.Sentinel.Ingest  — portal-generic ingest (DCE/DCR + Storage Table + AI events)
#   L2 Xdr.Defender.Auth    — Defender-portal cookie exchange (sccauth + XSRF-TOKEN)
#   L3 Xdr.Defender.Client  — Defender-portal manifest dispatcher (45 streams)
#   L4 Xdr.Connector.Orchestrator (THIS module) — portal-routing dispatcher
#
# Operators using the L4 surface call:
#     Connect-XdrPortal -Portal 'Defender' -Method ... -Credential ...
#     Invoke-XdrTierPoll -Tier P0 -Portal 'Defender' -Session $s -Config $c
#     Test-XdrPortalAuth -Portal 'Defender' -Method ... -Credential ...
#     Get-XdrPortalManifest -Portal 'Defender'
#
# Internally each call looks up the -Portal value in $script:PortalRoutes
# and dispatches into the appropriate L2/L3 function. Adding a new portal
# in v0.2.0+ is a one-line addition to $script:PortalRoutes plus the
# corresponding L2/L3 modules.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Portal routing table. Keyed by the canonical portal name (case-insensitive
# match in the dispatcher). Each entry maps to the underlying L2 + L3 modules
# and the per-portal function names that the dispatchers call through to.
#
# v0.2.0 additions (planned): Purview, Intune, Entra. Each new entry brings
# its own L2 auth module + L3 client module + per-portal Connect/Test/Poll
# function names; the orchestrator surface is unchanged.
$script:PortalRoutes = @{
    'Defender' = @{
        AuthModule    = 'Xdr.Defender.Auth'
        ClientModule  = 'Xdr.Defender.Client'
        ConnectFn     = 'Connect-DefenderPortal'
        TestFn        = 'Test-DefenderPortalAuth'
        TierPollFn    = 'Invoke-MDETierPoll'
        ManifestFn    = 'Get-MDEEndpointManifest'
        DefaultHost   = 'security.microsoft.com'
    }
}

# Helper: validate a -Portal value and return its routing entry. Throws a
# clear error listing the available portals if the value is unknown.
function Resolve-XdrPortalRoute {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $Portal
    )
    $match = $script:PortalRoutes.Keys | Where-Object { $_ -ieq $Portal } | Select-Object -First 1
    if (-not $match) {
        $known = ($script:PortalRoutes.Keys | Sort-Object) -join ', '
        throw "Unknown -Portal '$Portal'. Known portals: $known. To add a new portal, extend `$script:PortalRoutes in Xdr.Connector.Orchestrator.psm1."
    }
    return $script:PortalRoutes[$match]
}

# Public functions live under Public/. Dot-source them so they have access to
# $script:PortalRoutes and the Resolve-XdrPortalRoute helper above.
$publicPath = Join-Path $PSScriptRoot 'Public'
$publicFiles = @(Get-ChildItem -Path $publicPath -Filter *.ps1 -ErrorAction SilentlyContinue)
foreach ($file in $publicFiles) {
    try {
        . $file.FullName
    } catch {
        Write-Error "Failed to load $($file.FullName): $_"
        throw
    }
}

Export-ModuleMember -Function @(
    'Connect-XdrPortal',
    'Invoke-XdrTierPoll',
    'Test-XdrPortalAuth',
    'Get-XdrPortalManifest'
)
