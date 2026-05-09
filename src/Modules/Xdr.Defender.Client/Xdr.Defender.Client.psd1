@{
    RootModule            = 'Xdr.Defender.Client.psm1'
    ModuleVersion         = '1.0.0'
    CompatiblePSEditions  = @('Core')
    PowerShellVersion     = '7.4'
    GUID                  = 'e6a71234-9b85-4ef3-bd1a-0c8b7e2d5f14'
    Author                = 'Alex Kefallonitis'
    CompanyName           = 'Community'
    Copyright             = '(c) 2026 Alex Kefallonitis and contributors. MIT License.'
    Description           = 'L3 Defender-portal manifest dispatcher. Per-stream Invoke-MDEEndpoint backed by the endpoints.manifest.psd1 catalogue (64 streams; 63 live + 1 deprecated; across 5 cadence tiers: ActionCenter 10m / XspmGraph 1h / Configuration 6h / Inventory 24h / Maintenance 7d, all read-only). Builds on the L2 Xdr.Defender.Auth cookie-exchange layer.'
    RequiredModules       = @('Xdr.Defender.Auth', 'Xdr.Common.Manifest')
    # Public surface: single dispatcher + truth-signal accessor + 3 underlying
    # helpers exported for v0.2.0 multi-portal extensibility (Entra/Purview/
    # Intune wrapper modules can re-use the projection + response-expansion
    # logic without reimplementing). Stream names live in endpoints.manifest.psd1
    # so adding/retiring an endpoint is a one-line manifest change.
    # Manifest loader (Get-XdrEndpointManifest) lives in Xdr.Common.Manifest.
    FunctionsToExport     = @(
        'Invoke-MDEEndpoint',
        'Invoke-MDETierPoll',
        'Invoke-TierPollWithHeartbeat',
        'Invoke-MDEPortalEndpoint',
        'ConvertTo-MDEIngestRow',
        'Expand-MDEResponse',
        # Section R++.A: truth-signal side-channel for activity callers.
        'Get-MDEEndpointLastResult'
    )
    CmdletsToExport       = @()
    VariablesToExport     = @()
    AliasesToExport       = @()
    PrivateData           = @{
        PSData = @{
            Tags         = @('Defender', 'MDE', 'XDR', 'Portal', 'Endpoints')
            LicenseUri   = 'https://github.com/akefallonitis/xdrlograider/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/akefallonitis/xdrlograider'
            ReleaseNotes = 'v0.1.0 GA: 65 Defender XDR portal-only streams (PerEntityFanout + PerPlatformFanout + Pagination architectures), live-captured fixtures, runtime SuccessKind classification (live / live-empty / tenant-gated / error), Headers + UnwrapProperty + IdProperty + SyntheticEntityId manifest schema, ProjectionMap with $tostring/$toint/$tobool/$todatetime/$json type casts. Part of XdrLogRaider v0.1.0 GA.'
        }
    }
}
