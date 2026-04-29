@{
    RootModule            = 'Xdr.Common.Auth.psm1'
    ModuleVersion         = '1.0.0'
    CompatiblePSEditions  = @('Core')
    PowerShellVersion     = '7.4'
    GUID                  = 'a14a7c8b-3d62-49bf-9a2b-2e7f51b0c4e9'
    Author                = 'Alex Kefallonitis'
    CompanyName           = 'Community'
    Copyright             = '(c) 2026 Alex Kefallonitis and contributors. MIT License.'
    Description           = 'Portal-generic Entra (login.microsoftonline.com) authentication primitives — TOTP, software-passkey (FIDO2 ECDSA-P256), Entra ESTSAUTHPERSISTENT cookie acquisition, MFA + interrupt-page handling, KeyVault auth-material loader. Consumed by per-portal L2 modules (Xdr.Defender.Auth today; Xdr.Purview.Auth / Xdr.Intune.Auth / Xdr.Entra.Auth in v0.2.0). Does NOT know about specific portals — callers pass -ClientId for the portal''s public-client app.'
    FunctionsToExport     = @(
        'Get-EntraEstsAuth',
        'Get-XdrAuthFromKeyVault',
        'Resolve-EntraInterruptPage'
    )
    CmdletsToExport       = @()
    VariablesToExport     = @()
    AliasesToExport       = @()
    PrivateData           = @{
        PSData = @{
            Tags         = @('Security', 'Auth', 'Entra', 'TOTP', 'Passkey', 'FIDO2', 'MFA')
            LicenseUri   = 'https://github.com/akefallonitis/xdrlograider/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/akefallonitis/xdrlograider'
            ReleaseNotes = 'L1 portal-generic Entra-layer module — extracted from the monolithic Xdr.Portal.Auth shim. Companion L2 modules: Xdr.Defender.Auth (shipped); Xdr.Purview.Auth / Xdr.Intune.Auth / Xdr.Entra.Auth (planned for v0.2.0).'
        }
    }
}
