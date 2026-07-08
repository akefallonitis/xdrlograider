@{
    RootModule        = 'Xdr.Defender.Auth.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'b8c9d0e1-f2a3-4567-8901-234567123456'
    Author            = 'Alex Kefallonitis'
    Description       = 'Defender XDR portal auth handler · refreshes sccauth from ESTSAUTHPERSISTENT KMSI 90d cookie. Initial login is interactive via tools/Probe-DefenderAuth-Local.ps1 (Gate 1 ONCE).'
    PowerShellVersion = '7.4'
    RequiredModules   = @('Xdr.Common.Auth','Xdr.Common.Cache','Xdr.Common.Telemetry','Xdr.Common.Exceptions')
    FunctionsToExport = @('Connect-DefenderPortal','Refresh-DefenderSccauth','Get-XdrEntraEstsAuth','Submit-XdrAuthFormPost','Get-XdrDefenderSccauth','Get-XdrCookieExpiry','Get-XdrKmsiCookieValue')
}
