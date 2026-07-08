@{
    RootModule        = 'Xdr.Common.Auth.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'e5f6a7b8-c9d0-1234-5678-901234ef0123'
    Author            = 'Alex Kefallonitis'
    CompanyName       = 'Alex Kefallonitis'
    Description       = 'XdrLogRaider · auth orchestration · cookie + KMSI 90d + TOTP/Passkey first-class · per-Portal handler dispatch. Single-flight T3 reauth via Xdr.Common.Lease (Azure Blob Lease primitive).'
    PowerShellVersion = '7.4'
    RequiredModules   = @('Xdr.Common.Cache','Xdr.Common.Lease','Xdr.Common.Telemetry','Xdr.Common.Exceptions')
    FunctionsToExport = @('Connect-XdrPortal','Get-XdrSession','Save-XdrSession','Test-XdrSessionAlive','Register-XdrPortalHandler','Get-XdrCredentials','ConvertTo-XdrSessionHashtable')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags         = @('XdrLogRaider', 'Auth', 'Sentinel')
            ProjectUri   = 'https://github.com/akefallonitis/xdrlograider'
            LicenseUri   = 'https://github.com/akefallonitis/xdrlograider/blob/main/LICENSE'
            ReleaseNotes = 'v0.1.0 · Lock-XdrSingleFlight dependency moved to Xdr.Common.Lease (Blob Lease primitive).'
        }
    }
}
