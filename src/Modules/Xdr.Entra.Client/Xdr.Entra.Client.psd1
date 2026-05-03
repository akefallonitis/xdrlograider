@{
    RootModule            = 'Xdr.Entra.Client.psm1'
    ModuleVersion         = '0.0.1'
    CompatiblePSEditions  = @('Core')
    PowerShellVersion     = '7.4'
    GUID                  = 'd2f4a58e-6c9d-4e23-af7f-8b4c9d6e2f35'
    Author                = 'Alex Kefallonitis'
    CompanyName           = 'Community'
    Copyright             = '(c) 2026 Alex Kefallonitis and contributors. MIT License.'
    Description           = 'L3 Microsoft Entra portal manifest dispatcher scaffolding stub. v0.1.0 ships scaffolding only; v0.2.0 fills in actual Entra endpoints + manifest. Sibling L3 modules: Xdr.Defender.Client (live), Xdr.Purview.Client (stub), Xdr.Intune.Client (stub). See docs/MULTI-PORTAL.md.'
    RequiredModules       = @(
        'Xdr.Common.Auth',
        'Xdr.Entra.Auth',
        'Xdr.Sentinel.Ingest'
    )
    FunctionsToExport     = @(
        'Invoke-EntraTierPoll',
        'Get-EntraEndpointManifest'
    )
    CmdletsToExport       = @()
    VariablesToExport     = @()
    AliasesToExport       = @()
    PrivateData           = @{
        PSData = @{
            Tags         = @('Security', 'Entra', 'Sentinel', 'XDR', 'Client', 'Portal', 'v0.2.0-roadmap', 'scaffolding-stub')
            LicenseUri   = 'https://github.com/akefallonitis/xdrlograider/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/akefallonitis/xdrlograider'
            ReleaseNotes = 'v0.1.0 GA: scaffolding stub only — placeholder functions throw informative "v0.2.0 roadmap" errors.'
        }
    }
}
