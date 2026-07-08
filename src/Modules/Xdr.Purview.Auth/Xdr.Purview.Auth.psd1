@{
    RootModule        = 'Xdr.Purview.Auth.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '29c552b9-23da-4b37-ab19-2a44018dee34'
    Author            = 'Alex Kefallonitis'
    Description       = 'Purview cookie + XSRF auth (Defender pattern). not polled in v0.1.0 (Defender-only dispatch, plan section 4.18).'
    PowerShellVersion = '7.4'
    RequiredModules   = @('Xdr.Common.Auth','Xdr.Common.Telemetry','Xdr.Common.Exceptions','Xdr.Common.Cache','Xdr.Defender.Auth')
    FunctionsToExport = @('Connect-PurviewPortal')
}