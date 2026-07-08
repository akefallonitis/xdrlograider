@{
    RootModule        = 'Xdr.Common.Cache.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'c3d4e5f6-a7b8-9012-3456-789012cdef01'
    Author            = 'Alex Kefallonitis'
    CompanyName       = 'Alex Kefallonitis'
    Description       = 'XdrLogRaider · Xdr.Common.Cache · SecretStore (KV data-plane REST) + HotCache (in-memory) + StateStore (Tables) facade. MutexStore lives in Xdr.Common.Lease (separate module · separate primitive). iter#15: KV via MSI REST · no Az module dependency.'
    PowerShellVersion = '7.4'
    RequiredModules   = @('Xdr.Common.Storage')
    FunctionsToExport = @(
        'Get-XdrCachedSecret',
        'Get-XdrCachedSession',
        'Set-XdrCachedSession',
        'Invalidate-XdrCache'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags         = @('XdrLogRaider', 'Cache', 'Sentinel')
            ProjectUri   = 'https://github.com/akefallonitis/xdrlograider'
            LicenseUri   = 'https://github.com/akefallonitis/xdrlograider/blob/main/LICENSE'
            ReleaseNotes = 'v0.1.0 · HttpClient REST replaces AzTable SDK · Lock/Unlock moved to Xdr.Common.Lease.'
        }
    }
}
