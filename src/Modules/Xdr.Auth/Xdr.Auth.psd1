@{
    RootModule        = 'Xdr.Auth.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '7b1c9e0a-3c8f-4d2a-9f8a-1d4b5c6e7a9f'
    Author            = 'Alex Kefallonitis'
    CompanyName       = 'XdrLogRaider'
    Copyright         = '(c) 2026 Alex Kefallonitis. MIT License.'
    Description       = 'Defender XDR portal auth chain (sccauth + XSRF) via SA TOTP / Passkey; KMSI-aware cookie cache wired to actual cookie expiry, not 50-min hardcode.'
    PowerShellVersion = '7.4'
    FunctionsToExport = @(
        'Connect-DefenderPortal',
        'Connect-PurviewPortal',           # Phase 0k · cookie sibling of Defender (compliance.microsoft.com)
        'Connect-EntraPortal',             # Phase 0k · bearer · 5 sub-portals (IAM/PIM/IDGov/IGA/B2C)
        'Connect-IntunePortal',            # Phase 0k · bearer · 2 sub-portals (Portal/Autopatch)
        'Connect-SecurityCopilotPortal',   # Phase 0k · bearer · multi-host
        'Get-XdrCookieExpiry',
        'Resolve-EntraResponse',
        'Invoke-XdrAuthHttp',
        'Get-XdrTotpCode',
        'Get-XdrAuthFromKeyVault',
        'Clear-XdrCookieCache',
        # φ.AUTH.0 · Cross-runspace file session cache (v2 B-19 fix)
        'Save-XdrSessionToCache',
        'Read-XdrSessionFromCache',
        'Remove-XdrSessionFromCache',
        # φ.AUTH.1 · KV credential TTL cache (60-min default · prevents KV throttle)
        'Clear-XdrCredentialCache',
        # φ.AUTH.2 · Auth-failure sliding-window circuit-breaker (5min/2-error trip · v2 B-21)
        'Test-XdrAuthCircuitOpen',
        'Add-XdrAuthCircuitFailure',
        'Reset-XdrAuthCircuit',
        'Clear-XdrAuthCircuit',
        'New-ApiproxyPath',
        'Get-EntraEstsAuth',
        'Get-EntraBearerToken',
        'Get-XdrBearerTokenExpiry',
        'Refresh-XdrBearerToken',
        'Get-XdrPortalConfig'
    )
    CmdletsToExport   = @()
    AliasesToExport   = @()
    VariablesToExport = @()
}
