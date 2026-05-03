@{
    RootModule            = 'Xdr.Purview.Auth.psm1'
    ModuleVersion         = '0.0.1'
    CompatiblePSEditions  = @('Core')
    PowerShellVersion     = '7.4'
    GUID                  = 'd3f5a69e-7d0e-4f34-bf80-9c5d0e7f3b46'
    Author                = 'Alex Kefallonitis'
    CompanyName           = 'Community'
    Copyright             = '(c) 2026 Alex Kefallonitis and contributors. MIT License.'
    Description           = 'L2 Microsoft Purview portal (compliance.microsoft.com / purview.microsoft.com) auth scaffolding stub. v0.1.0 ships scaffolding only; v0.2.0 fills in actual TOTP/passkey + cookie exchange. See docs/MULTI-PORTAL.md.'
    FunctionsToExport     = @(
        'Connect-PurviewPortal',
        'Test-PurviewPortalAuth'
    )
    CmdletsToExport       = @()
    VariablesToExport     = @()
    AliasesToExport       = @()
    PrivateData           = @{
        PSData = @{
            Tags         = @('Security', 'Purview', 'Sentinel', 'XDR', 'Auth', 'Portal', 'v0.2.0-roadmap', 'scaffolding-stub')
            LicenseUri   = 'https://github.com/akefallonitis/xdrlograider/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/akefallonitis/xdrlograider'
            ReleaseNotes = 'v0.1.0 GA: scaffolding stub only.'
        }
    }
}
