@{
    RootModule        = 'Xdr.Entra.Auth.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'c4a7ec26-3394-4115-912f-3c71393a92fe'
    Author            = 'Alex Kefallonitis'
    Description       = 'Entra 5-sub-portal OAuth bearer auth (IAM/PIM/IDGov/IGA/B2C). not polled in v0.1.0 (Defender-only dispatch, plan section 4.18) + auth FUNCTIONAL for v0.2.0.'
    PowerShellVersion = '7.4'
    RequiredModules   = @('Xdr.Common.Auth','Xdr.Common.OAuthBearer','Xdr.Common.Telemetry','Xdr.Common.Exceptions','Xdr.Common.Cache')
    FunctionsToExport = @('Connect-EntraPortal')
}