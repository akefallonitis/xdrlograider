@{
    RootModule        = 'Xdr.Common.OAuthBearer.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '5780329a-974a-442a-bb86-da800b7ebcd4'
    Author            = 'Alex Kefallonitis'
    Description       = 'Shared OAuth bearer (ROPC + refresh_token) for Entra/Intune/SecurityCopilot. 5min expiry safety margin + SemaphoreSlim single-flight.'
    PowerShellVersion = '7.4'
    RequiredModules   = @('Xdr.Common.Cache','Xdr.Common.Telemetry','Xdr.Common.Exceptions')
    FunctionsToExport = @('Get-XdrOAuthToken','Test-XdrOAuthTokenAlive')
}