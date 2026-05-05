function Get-XdrPortalManifest {
    <#
    .SYNOPSIS
        Returns the per-portal stream manifest, optionally filtered by Portal
        annotation. Routes to the per-portal manifest function based on the
        -Portal value.

    .DESCRIPTION
        Today routes 'Defender' to Get-XdrEndpointManifest -Portal Defender (Xdr.Defender.Client)
        and filters by the manifest entry's Portal field. The per-portal
        manifest functions return the full per-portal catalogue; this wrapper
        keeps the operator-facing surface portal-keyed.

    .PARAMETER Portal
        Portal name. Must match an entry in the orchestrator's routing table.
        Currently supported: 'Defender'.

    .OUTPUTS
        [hashtable] Stream-name → entry mapping for the requested portal.
        Each entry exposes the per-portal manifest schema (Tier, Path, Filter,
        IdProperty, Availability, Headers, UnwrapProperty, Portal, ...).

    .EXAMPLE
        $entries = Get-XdrPortalManifest -Portal 'Defender'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $Portal
    )

    $route = Resolve-XdrPortalRoute -Portal $Portal

    # Phase J D'.1 (2026-05-04): all 4 portals use unified Get-XdrEndpointManifest
    # from Xdr.Common.Manifest module — invoked with -Portal $Portal. The route's
    # ManifestFn stores only the function name; -Portal arg supplied here.
    $manifestFn = $route.ManifestFn
    if (-not (Get-Command -Name $manifestFn -ErrorAction SilentlyContinue)) {
        throw "Get-XdrPortalManifest: function '$manifestFn' is not available. Ensure module 'Xdr.Common.Manifest' is imported."
    }

    # Dispatch through Xdr.Common.Manifest module session state (Pester-friendly).
    $manifestModule = Get-Module -Name 'Xdr.Common.Manifest'
    $rawManifest = if ($manifestModule) {
        & $manifestModule { param($Fn, $P) & $Fn -Portal $P } $manifestFn $Portal
    } else {
        & $manifestFn -Portal $Portal
    }
    if ($null -eq $rawManifest) { return @{} }

    # Filter to entries whose Portal annotation matches (case-insensitive). If
    # an entry has no Portal field, fall back to the route's default host so
    # legacy manifest entries (no Portal field) still surface for the
    # historical default portal.
    $defaultHost = $route.DefaultHost
    $filtered = @{}
    foreach ($key in $rawManifest.Keys) {
        $entry = $rawManifest[$key]
        $entryPortal = if ($entry -is [hashtable] -and $entry.ContainsKey('Portal') -and $entry.Portal) {
            [string]$entry.Portal
        } else {
            $defaultHost
        }
        # Match the requested -Portal against either the friendly name
        # ('Defender') or the host string ('security.microsoft.com').
        if ($entryPortal -ieq $Portal -or $entryPortal -ieq $defaultHost) {
            $filtered[$key] = $entry
        }
    }
    return $filtered
}
