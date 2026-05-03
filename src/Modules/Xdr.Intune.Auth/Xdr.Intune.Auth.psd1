@{
    RootModule            = 'Xdr.Intune.Auth.psm1'
    ModuleVersion         = '0.0.1'
    CompatiblePSEditions  = @('Core')
    PowerShellVersion     = '7.4'
    GUID                  = 'd5f7a81e-9f20-4156-d1a2-be7f2091b668'
    Author                = 'Alex Kefallonitis'
    CompanyName           = 'Community'
    Copyright             = '(c) 2026 Alex Kefallonitis and contributors. MIT License.'
    Description           = 'L2 Microsoft Intune portal (intune.microsoft.com) auth scaffolding stub. v0.1.0 ships scaffolding only; v0.2.0 fills in actual TOTP/passkey + cookie exchange. See docs/MULTI-PORTAL.md.'
    FunctionsToExport     = @(
        'Connect-IntunePortal',
        'Test-IntunePortalAuth'
    )
    CmdletsToExport       = @()
    VariablesToExport     = @()
    AliasesToExport       = @()
    PrivateData           = @{
        PSData = @{
            Tags         = @('Security', 'Intune', 'Sentinel', 'XDR', 'Auth', 'Portal', 'v0.2.0-roadmap', 'scaffolding-stub')
            LicenseUri   = 'https://github.com/akefallonitis/xdrlograider/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/akefallonitis/xdrlograider'
            ReleaseNotes = 'v0.1.0 GA: scaffolding stub only.'
        }
    }
}
