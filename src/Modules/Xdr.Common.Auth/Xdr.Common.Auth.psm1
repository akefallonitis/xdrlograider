# Xdr.Common.Auth — L1 portal-generic Entra-layer auth primitives.
#
# Architecture:
#   L1 Xdr.Common.Auth          ← THIS MODULE (Entra layer; portal-agnostic)
#   L2 Xdr.<Portal>.Auth        ← per-portal cookie exchange (Defender today; Purview / Intune / Entra in v0.2.0)
#   L3 Xdr.<Portal>.Client      ← per-portal manifest dispatcher
#   L4 Xdr.Connector.Orchestrator ← portal-routing dispatcher
#
# Boundaries (test-gated by tests/unit/AuthLayerBoundaries.Tests.ps1):
#   - This module MUST NOT contain hardcoded portal hostnames (security.microsoft.com etc).
#   - This module MUST NOT contain portal-specific cookie names (sccauth, X-XSRF-TOKEN-* etc).
#   - This module MUST NOT contain portal-specific OIDC callback paths (signin-oidc etc).
#   - All portal-specific values arrive via parameters (-ClientId, -PortalHost when set externally).

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$privatePath = Join-Path $PSScriptRoot 'Private'
$publicPath  = Join-Path $PSScriptRoot 'Public'

$private = @(Get-ChildItem -Path $privatePath -Filter *.ps1 -ErrorAction SilentlyContinue)
$public  = @(Get-ChildItem -Path $publicPath  -Filter *.ps1 -ErrorAction SilentlyContinue)

foreach ($file in $private + $public) {
    try {
        . $file.FullName
    } catch {
        Write-Error "Failed to load $($file.FullName): $_"
        throw
    }
}

Export-ModuleMember -Function $public.BaseName
