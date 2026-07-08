@{
    RootModule        = 'Xdr.Intune.Auth.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '07fc4964-f496-4a98-b28c-24b6e75dfd57'
    Author            = 'Alex Kefallonitis'
    Description       = 'Intune 2-sub-portal OAuth bearer auth (Portal/Autopatch). not polled in v0.1.0 (Defender-only dispatch, plan section 4.18).'
    PowerShellVersion = '7.4'
    RequiredModules   = @('Xdr.Common.Auth','Xdr.Common.OAuthBearer','Xdr.Common.Telemetry','Xdr.Common.Exceptions','Xdr.Common.Cache')
    FunctionsToExport = @('Connect-IntunePortal')
}