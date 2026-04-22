@{
    RootModule            = 'Xdr.Portal.Auth.psm1'
    ModuleVersion         = '1.0.0'
    CompatiblePSEditions  = @('Core')
    PowerShellVersion     = '7.4'
    GUID                  = 'bd4fa1c2-5d9a-4e0a-8c45-1fa0a5d1c7b3'
    Author                = 'Alex Kefallonitis'
    CompanyName           = 'Community'
    Copyright             = '(c) 2026 Alex Kefallonitis and contributors. MIT License.'
    Description           = 'Portal-agnostic authentication chain for Microsoft portals (security.microsoft.com, intune.microsoft.com, etc). Supports Credentials+TOTP and Software Passkey, auto-refresh, XSRF rotation, sccauth cookie management.'
    FunctionsToExport     = @(
        'Connect-MDEPortal',
        'Connect-MDEPortalWithCookies',
        'Invoke-MDEPortalRequest',
        'Test-MDEPortalAuth',
        'Get-MDEAuthFromKeyVault'
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
