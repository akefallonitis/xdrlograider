@{
    RootModule            = 'Xdr.Purview.Client.psm1'
    ModuleVersion         = '0.0.1'
    CompatiblePSEditions  = @('Core')
    PowerShellVersion     = '7.4'
    GUID                  = 'd4f6a70e-8e1f-4045-c091-ad6e1f80a557'
    Author                = 'Alex Kefallonitis'
    CompanyName           = 'Community'
    Copyright             = '(c) 2026 Alex Kefallonitis and contributors. MIT License.'
    Description           = 'L3 Microsoft Purview portal manifest dispatcher scaffolding stub. v0.2.0 fills in actual Purview endpoints (DLP policies, retention labels, audit logs, eDiscovery cases). See docs/MULTI-PORTAL.md.'
    RequiredModules       = @(
        'Xdr.Common.Auth',
        'Xdr.Purview.Auth',
        'Xdr.Sentinel.Ingest'
    )
    FunctionsToExport     = @(
        'Invoke-PurviewTierPoll',
        'Get-PurviewEndpointManifest'
    )
    CmdletsToExport       = @()
    VariablesToExport     = @()
    AliasesToExport       = @()
    PrivateData           = @{
        PSData = @{
            Tags         = @('Security', 'Purview', 'Sentinel', 'XDR', 'Client', 'Portal', 'v0.2.0-roadmap', 'scaffolding-stub')
            LicenseUri   = 'https://github.com/akefallonitis/xdrlograider/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/akefallonitis/xdrlograider'
            ReleaseNotes = 'v0.1.0 GA: scaffolding stub only.'
        }
    }
}
