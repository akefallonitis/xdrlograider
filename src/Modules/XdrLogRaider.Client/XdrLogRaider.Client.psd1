@{
    RootModule            = 'XdrLogRaider.Client.psm1'
    ModuleVersion         = '1.0.0'
    CompatiblePSEditions  = @('Core')
    PowerShellVersion     = '7.4'
    GUID                  = 'e6a71234-9b85-4ef3-bd1a-0c8b7e2d5f14'
    Author                = 'Alex Kefallonitis'
    CompanyName           = 'Community'
    Copyright             = '(c) 2026 Alex Kefallonitis and contributors. MIT License.'
    Description           = 'Manifest-driven dispatcher for Defender XDR portal-only telemetry (45 streams across P0-P7 tiers). Single per-stream entry point (Invoke-MDEEndpoint), per-tier batch poller (Invoke-MDETierPoll), and shared timer-body helper (Invoke-TierPollWithHeartbeat). Read-only; supports server-side time filtering, path-parameter substitution, per-entry Headers / UnwrapProperty, and forward-scalable Portal= annotation.'
    RequiredModules       = @('Xdr.Portal.Auth')
    # Public surface: single dispatcher + per-tier poller + shared timer body +
    # manifest loader + 3 underlying helpers. The 45 stream names live in
    # endpoints.manifest.psd1 (not in this file) so adding/retiring an endpoint
    # is a one-line manifest change.
    FunctionsToExport     = @(
        'Invoke-MDEEndpoint',
        'Invoke-MDETierPoll',
        'Invoke-TierPollWithHeartbeat',
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
            ReleaseNotes = 'v0.1.0-beta: 45 portal-only endpoints with live-captured fixtures, Availability classification, Headers + UnwrapProperty + forward-scalable Portal= manifest schema, Invoke-TierPollWithHeartbeat shared timer helper. Part of XdrLogRaider v0.1.0-beta.'
        }
    }
}
