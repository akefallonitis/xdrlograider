@{
    RootModule        = 'Xdr.SecurityCopilot.Auth.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'a26a8ea4-d5d5-4314-a268-95e3e574459d'
    Author            = 'Alex Kefallonitis'
    Description       = 'Security Copilot OAuth bearer auth. not polled in v0.1.0 (Defender-only dispatch, plan section 4.18).'
    PowerShellVersion = '7.4'
    RequiredModules   = @('Xdr.Common.Auth','Xdr.Common.OAuthBearer','Xdr.Common.Telemetry','Xdr.Common.Exceptions','Xdr.Common.Cache')
    FunctionsToExport = @('Connect-SecurityCopilotPortal')
}