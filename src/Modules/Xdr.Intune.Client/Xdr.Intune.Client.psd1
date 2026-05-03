@{
    RootModule            = 'Xdr.Intune.Client.psm1'
    ModuleVersion         = '0.0.1'
    CompatiblePSEditions  = @('Core')
    PowerShellVersion     = '7.4'
    GUID                  = 'd6f8a92e-a031-4267-e2b3-cf80309c2779'
    Author                = 'Alex Kefallonitis'
    CompanyName           = 'Community'
    Copyright             = '(c) 2026 Alex Kefallonitis and contributors. MIT License.'
    Description           = 'L3 Microsoft Intune portal manifest dispatcher scaffolding stub. v0.2.0 fills in actual Intune endpoints (compliance policies, configuration profiles, app protection). See docs/MULTI-PORTAL.md.'
    RequiredModules       = @(
        'Xdr.Common.Auth',
        'Xdr.Intune.Auth',
        'Xdr.Sentinel.Ingest'
    )
    FunctionsToExport     = @(
        'Invoke-IntuneTierPoll',
        'Get-IntuneEndpointManifest'
    )
    CmdletsToExport       = @()
    VariablesToExport     = @()
    AliasesToExport       = @()
    PrivateData           = @{
        PSData = @{
            Tags         = @('Security', 'Intune', 'Sentinel', 'XDR', 'Client', 'Portal', 'v0.2.0-roadmap', 'scaffolding-stub')
            LicenseUri   = 'https://github.com/akefallonitis/xdrlograider/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/akefallonitis/xdrlograider'
            ReleaseNotes = 'v0.1.0 GA: scaffolding stub only.'
        }
    }
}
