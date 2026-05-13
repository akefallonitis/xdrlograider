@{
    RootModule            = 'Xdr.Defender.Client.psm1'
    ModuleVersion         = '1.0.0'
    CompatiblePSEditions  = @('Core')
    PowerShellVersion     = '7.4'
    GUID                  = 'e6a71234-9b85-4ef3-bd1a-0c8b7e2d5f14'
    Author                = 'Alex Kefallonitis'
    CompanyName           = 'Community'
    Copyright             = '(c) 2026 Alex Kefallonitis and contributors. MIT License.'
    Description           = 'L3 Defender-portal manifest dispatcher. Per-stream Invoke-MDEEndpoint backed by manifests/defender.psd1 (492 read endpoints across 18 sub-areas, all GET-shaped, manifest-driven cadence/pagination/projection). Builds on the L2 Xdr.Defender.Auth sccauth+XSRF cookie-exchange layer. Includes Custom Collection cmdlets and Get-DefenderTenantContext for dynamic regionality.'
    RequiredModules       = @('Xdr.Defender.Auth', 'Xdr.Common.Manifest')
    FunctionsToExport     = @(
        'Invoke-MDEEndpoint',
        'Invoke-MDETierPoll',
        'Invoke-MDEPortalEndpoint',
        'ConvertTo-MDEIngestRow',
        'Expand-MDEResponse',
        'Get-MDEEndpointLastResult',
        'Get-XdrCustomCollectionRule',
        'Get-XdrCustomCollectionRuleById',
        'Get-XdrCustomCollectionModel',
        'Get-DefenderTenantContext'
    )
    CmdletsToExport       = @()
    VariablesToExport     = @()
    AliasesToExport       = @()
    PrivateData           = @{
        PSData = @{
            Tags         = @('Defender', 'MDE', 'XDR', 'Portal', 'Endpoints')
            LicenseUri   = 'https://github.com/akefallonitis/xdrlograider/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/akefallonitis/xdrlograider'
            ReleaseNotes = 'v0.1.0 GA: 492 Defender XDR portal-only read endpoints across 18 sub-areas; 4-value SuccessKind (live / live-empty / rate-limited / error) with LicenseHint for licence-blocked streams; corrected /mtp/mdeCustomCollection/rules path; Get-DefenderTenantContext dynamic regionality; ProjectionMap with $tostring/$toint/$tobool/$todatetime/$json type casts; manifest-driven cadence + pagination + per-entity fanout.'
        }
    }
}
