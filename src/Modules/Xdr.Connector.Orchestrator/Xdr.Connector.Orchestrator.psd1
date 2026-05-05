@{
    RootModule            = 'Xdr.Connector.Orchestrator.psm1'
    ModuleVersion         = '1.0.0'
    CompatiblePSEditions  = @('Core')
    PowerShellVersion     = '7.4'
    GUID                  = 'b9c2d7e4-3f5a-4d18-9b6c-7a1f2e8c5d10'
    Author                = 'Alex Kefallonitis'
    CompanyName           = 'Community'
    Copyright             = '(c) 2026 Alex Kefallonitis and contributors. MIT License.'
    Description           = 'L4 portal-routing dispatcher. Provides a single -Portal-keyed entry point (Connect-XdrPortal, Invoke-XdrTierPoll, Test-XdrPortalAuth, Get-XdrPortalManifest) plus v0.1.0 GA helpers Get-XdrConnectorHealth + Test-XdrConnectorConfig. Routes to the right L2 auth + L3 client modules based on an internal portal-routing table. v0.1.0 GA: Defender = live (single-portal). v0.2.0 reintroduces Entra/Purview/Intune modules with real bodies + FA multi-tenancy support.'
    RequiredModules       = @(
        'Xdr.Common.Auth',
        'Xdr.Common.Manifest',
        'Xdr.Common.Telemetry',
        'Xdr.Defender.Auth',
        'Xdr.Defender.Client',
        'Xdr.Sentinel.Ingest'
    )
    FunctionsToExport     = @(
        'Connect-XdrPortal',
        'Invoke-XdrTierPoll',
        'Test-XdrPortalAuth',
        'Get-XdrPortalManifest',
        # v0.1.0 GA Phase A.3.6 helpers:
        'Get-XdrConnectorHealth',
        'Test-XdrConnectorConfig'
    )
    CmdletsToExport       = @()
    VariablesToExport     = @()
    AliasesToExport       = @()
    PrivateData           = @{
        PSData = @{
            Tags         = @('Security', 'XDR', 'Defender', 'Sentinel', 'Orchestrator', 'Portal')
            LicenseUri   = 'https://github.com/akefallonitis/xdrlograider/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/akefallonitis/xdrlograider'
            ReleaseNotes = 'Initial release. Adds the L4 portal-routing layer above L1-L3 modules. Single Defender entry today; portal table is the v0.2.0 expansion seam.'
        }
    }
}
