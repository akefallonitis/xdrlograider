@{
    RootModule            = 'Xdr.Defender.Client.psm1'
    ModuleVersion         = '1.0.0'
    CompatiblePSEditions  = @('Core')
    PowerShellVersion     = '7.4'
    GUID                  = 'e6a71234-9b85-4ef3-bd1a-0c8b7e2d5f14'
    Author                = 'Alex Kefallonitis'
    CompanyName           = 'Community'
    Copyright             = '(c) 2026 Alex Kefallonitis and contributors. MIT License.'
    Description           = 'L3 Defender-portal manifest dispatcher. Per-stream Invoke-MDEEndpoint + per-tier Invoke-MDETierPoll + shared Invoke-TierPollWithHeartbeat timer body, backed by the endpoints.manifest.psd1 catalogue (45 streams across P0-P7 tiers, all read-only). Builds on the L2 Xdr.Defender.Auth cookie-exchange layer.'
    RequiredModules       = @('Xdr.Defender.Auth')
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
