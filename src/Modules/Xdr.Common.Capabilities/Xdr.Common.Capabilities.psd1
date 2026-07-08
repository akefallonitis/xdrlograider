@{
    RootModule        = 'Xdr.Common.Capabilities.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'bcda1c11-0cd8-42ac-9c4e-454716f0a104'
    Author            = 'Alex Kefallonitis'
    CompanyName       = 'Alex Kefallonitis'
    Description       = 'XdrLogRaider · Xdr.Common.Capabilities · dynamic tenant context + product/license discovery at FA cold-start. StateStore TTL 24h via Xdr.Common.Storage REST helpers.'
    PowerShellVersion = '7.4'
    RequiredModules   = @('Xdr.Common.Storage','Xdr.Common.Cache','Xdr.Common.Telemetry','Xdr.Common.Exceptions')
    FunctionsToExport = @('Get-XdrTenantContext','Get-XdrTenantCapabilities','Test-XdrRequiresProducts')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags         = @('XdrLogRaider', 'Capabilities', 'Sentinel')
            ProjectUri   = 'https://github.com/akefallonitis/xdrlograider'
            LicenseUri   = 'https://github.com/akefallonitis/xdrlograider/blob/main/LICENSE'
            ReleaseNotes = 'v0.1.0 · HttpClient REST via Xdr.Common.Storage replaces AzTable SDK.'
        }
    }
}
