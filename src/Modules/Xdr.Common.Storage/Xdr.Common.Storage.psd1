@{
    RootModule        = 'Xdr.Common.Storage.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'e8a5b3c2-7d4f-4e1a-9b8c-2f6a1d3e9b7c'
    Author            = 'Alex Kefallonitis'
    CompanyName       = 'Alex Kefallonitis'
    Description       = 'XdrLogRaider · Xdr.Common.Storage · HttpClient REST primitives against Azure Storage (Tables OAuth + Blob lease). Replaces the deprecated AzTable SDK so ETag-conditional writes (Tables) and atomic mutex (Blob lease) are usable.'
    PowerShellVersion = '7.4'
    FunctionsToExport = @(
        'Get-XdrTableEntity',
        'Get-XdrTableEntities',
        'Set-XdrTableEntity',
        'Remove-XdrTableEntity',
        'Ensure-XdrBlobExists',
        'Acquire-XdrBlobLease',
        'Release-XdrBlobLease',
        'Renew-XdrBlobLease'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags         = @('XdrLogRaider', 'Storage', 'Sentinel')
            ProjectUri   = 'https://github.com/akefallonitis/xdrlograider'
            LicenseUri   = 'https://github.com/akefallonitis/xdrlograider/blob/main/LICENSE'
            ReleaseNotes = 'v0.1.0 · initial · HttpClient REST replaces AzTable SDK.'
        }
    }
}
