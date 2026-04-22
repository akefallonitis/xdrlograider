@{
    RootModule            = 'XdrLogRaider.Client.psm1'
    ModuleVersion         = '1.0.0'
    CompatiblePSEditions  = @('Core')
    PowerShellVersion     = '7.4'
    GUID                  = 'e6a71234-9b85-4ef3-bd1a-0c8b7e2d5f14'
    Author                = 'Alex Kefallonitis'
    CompanyName           = 'Community'
    Copyright             = '(c) 2026 Alex Kefallonitis and contributors. MIT License.'
    Description           = 'Manifest-driven dispatcher for Defender XDR portal-only telemetry (53 streams across P0-P7 tiers). Single per-stream entry point (Invoke-MDEEndpoint) + per-tier batch poller (Invoke-MDETierPoll). Read-only; supports server-side time filtering and path-parameter substitution.'
    RequiredModules       = @('Xdr.Portal.Auth')
    # Single dispatcher + single tier-poller + manifest loader + 3 underlying helpers.
    # The 53 stream names are kept in endpoints.manifest.psd1 (not in this file) so
    # adding/retiring an endpoint is a one-line manifest change.
    FunctionsToExport     = @(
        'Invoke-MDEEndpoint',
        'Invoke-MDETierPoll',
        'Get-MDEEndpointManifest',
        'Invoke-MDEPortalEndpoint',
        'ConvertTo-MDEIngestRow',
        'Expand-MDEResponse'
    )
    CmdletsToExport       = @()
    VariablesToExport     = @()
    AliasesToExport       = @()
    PrivateData           = @{
        PSData = @{
            Tags         = @('Defender', 'MDE', 'XDR', 'Portal', 'Endpoints')
            LicenseUri   = 'https://github.com/akefallonitis/xdrlograider/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/akefallonitis/xdrlograider'
            ReleaseNotes = 'Initial release. All 55 endpoint wrappers. Part of XdrLogRaider v1.0.0.'
        }
    }
}
