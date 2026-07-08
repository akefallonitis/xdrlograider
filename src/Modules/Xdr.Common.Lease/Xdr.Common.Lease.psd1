@{
    RootModule        = 'Xdr.Common.Lease.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'b7c2e5a8-1f3d-4b6c-9a8e-7d4f2c1b5e9a'
    Author            = 'Alex Kefallonitis'
    CompanyName       = 'Alex Kefallonitis'
    Description       = 'XdrLogRaider · Xdr.Common.Lease · server-enforced distributed mutex via Azure Blob Lease. Drop-in replacement for the prior read-then-write Storage-Table lease (which had a TOCTOU race under concurrent T3 OAuth+TOTP attempts).'
    PowerShellVersion = '7.4'
    RequiredModules   = @('Xdr.Common.Storage')
    FunctionsToExport = @(
        'Lock-XdrSingleFlight',
        'Renew-XdrSingleFlight',
        'Unlock-XdrSingleFlight'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags         = @('XdrLogRaider', 'Lease', 'Mutex', 'Sentinel')
            ProjectUri   = 'https://github.com/akefallonitis/xdrlograider'
            LicenseUri   = 'https://github.com/akefallonitis/xdrlograider/blob/main/LICENSE'
            ReleaseNotes = 'v0.1.0 · initial · Azure Blob Lease primitive.'
        }
    }
}
