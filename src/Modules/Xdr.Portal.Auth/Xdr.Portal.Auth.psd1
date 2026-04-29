@{
    RootModule            = 'Xdr.Portal.Auth.psm1'
    ModuleVersion         = '1.0.0'
    CompatiblePSEditions  = @('Core')
    PowerShellVersion     = '7.4'
    GUID                  = 'bd4fa1c2-5d9a-4e0a-8c45-1fa0a5d1c7b3'
    Author                = 'Alex Kefallonitis'
    CompanyName           = 'Community'
    Copyright             = '(c) 2026 Alex Kefallonitis and contributors. MIT License.'
    Description           = 'Backward-compat shim. Imports Xdr.Common.Auth (L1 Entra layer) and Xdr.Defender.Auth (L2 Defender cookie exchange) and re-exports the legacy MDE-prefixed function names (Connect-MDEPortal, Invoke-MDEPortalRequest, Test-MDEPortalAuth, Get-MDEAuthFromKeyVault, Connect-MDEPortalWithCookies, Get-XdrPortalRate429Count, Reset-XdrPortalRate429Count) as wrappers. New code SHOULD reference Xdr.Common.Auth + Xdr.Defender.Auth directly; this shim stays through the v0.1.0 GA window for operator-script + test-mock backward-compat.'
    FunctionsToExport     = @(
        'Connect-MDEPortal',
        'Connect-MDEPortalWithCookies',
        'Invoke-MDEPortalRequest',
        'Test-MDEPortalAuth',
        'Get-MDEAuthFromKeyVault',
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
            ReleaseNotes = 'Initial release. Part of XdrLogRaider v1.0.0.'
        }
    }
}
