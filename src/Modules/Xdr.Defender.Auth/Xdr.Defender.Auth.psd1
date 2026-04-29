@{
    RootModule            = 'Xdr.Defender.Auth.psm1'
    ModuleVersion         = '1.0.0'
    CompatiblePSEditions  = @('Core')
    PowerShellVersion     = '7.4'
    GUID                  = 'c2bd0a13-5e91-4d7c-9f6e-8a3d52b1f2e4'
    Author                = 'Alex Kefallonitis'
    CompanyName           = 'Community'
    Copyright             = '(c) 2026 Alex Kefallonitis and contributors. MIT License.'
    Description           = 'L2 Microsoft Defender XDR portal (security.microsoft.com) auth + request layer. Wraps the L1 Xdr.Common.Auth Entra-layer primitives, handles Defender-specific cookie exchange (sccauth + XSRF-TOKEN), session caching, proactive 50-min/3h30m rotation, and reactive 401/440/429 retry logic. Sibling L2 modules in v0.2.0: Xdr.Purview.Auth, Xdr.Intune.Auth, Xdr.Entra.Auth. Caller MUST import Xdr.Common.Auth BEFORE this module (profile.ps1 enforces this order).'
    FunctionsToExport     = @(
        'Connect-DefenderPortal',
        'Connect-DefenderPortalWithCookies',
        'Get-DefenderSccauth',
        'Invoke-DefenderPortalRequest',
        'Test-DefenderPortalAuth',
        'Get-XdrPortalRate429Count',
        'Reset-XdrPortalRate429Count'
    )
    CmdletsToExport       = @()
    VariablesToExport     = @()
    AliasesToExport       = @()
    PrivateData           = @{
        PSData = @{
            Tags         = @('Security', 'Defender', 'Sentinel', 'MDE', 'XDR', 'Auth', 'Portal')
            LicenseUri   = 'https://github.com/akefallonitis/xdrlograider/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/akefallonitis/xdrlograider'
            ReleaseNotes = 'L2 Defender-portal-specific module — extracted from the monolithic Xdr.Portal.Auth shim. Companion L1: Xdr.Common.Auth.'
        }
    }
}
