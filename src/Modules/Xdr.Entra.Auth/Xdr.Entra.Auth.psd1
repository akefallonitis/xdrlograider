@{
    RootModule            = 'Xdr.Entra.Auth.psm1'
    ModuleVersion         = '0.0.1'
    CompatiblePSEditions  = @('Core')
    PowerShellVersion     = '7.4'
    GUID                  = 'd1f3a47e-5b8c-4d12-9e6f-7a3b8c5d1f24'
    Author                = 'Alex Kefallonitis'
    CompanyName           = 'Community'
    Copyright             = '(c) 2026 Alex Kefallonitis and contributors. MIT License.'
    Description           = 'L2 Microsoft Entra portal (entra.microsoft.com) auth scaffolding stub. v0.1.0 ships scaffolding only; v0.2.0 fills in actual TOTP/passkey + cookie exchange. Sibling L2 modules: Xdr.Defender.Auth (live), Xdr.Purview.Auth (stub), Xdr.Intune.Auth (stub). See docs/MULTI-PORTAL.md.'
    FunctionsToExport     = @(
        'Connect-EntraPortal',
        'Test-EntraPortalAuth'
    )
    CmdletsToExport       = @()
    VariablesToExport     = @()
    AliasesToExport       = @()
    PrivateData           = @{
        PSData = @{
            Tags         = @('Security', 'Entra', 'Sentinel', 'XDR', 'Auth', 'Portal', 'v0.2.0-roadmap', 'scaffolding-stub')
            LicenseUri   = 'https://github.com/akefallonitis/xdrlograider/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/akefallonitis/xdrlograider'
            ReleaseNotes = 'v0.1.0 GA: scaffolding stub only — placeholder functions throw informative "v0.2.0 roadmap" errors. Forward-compat for multi-portal expansion per Phase A3 in .claude/plans/immutable-splashing-waffle.md.'
        }
    }
}
