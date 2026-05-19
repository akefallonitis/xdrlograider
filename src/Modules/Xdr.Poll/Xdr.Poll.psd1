@{
    RootModule        = 'Xdr.Poll.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '9d4f7a2b-5c1e-4b6a-8e3d-2f1a4c7b9e0d'
    Author            = 'Alex Kefallonitis'
    CompanyName       = 'XdrLogRaider'
    Copyright         = '(c) 2026 Alex Kefallonitis. MIT License.'
    Description       = 'Defender XDR /apiproxy/ endpoint poll wrapper. Enforces /apiproxy/<service>/ prefix (Gate O), HTML-content sniff (B-8), 401-reauth-once, 429 Retry-After backoff.'
    PowerShellVersion = '7.4'
    # Xdr.Auth is imported by src/profile.ps1 ahead of Xdr.Poll on cold-start.
    # Declaring it as RequiredModules causes Test-ModuleManifest to fail because
    # the sibling module isn't on the standard PSModulePath. Import order is the
    # contract; the FA layout test enforces both modules ship in the same zip.
    FunctionsToExport = @(
        'Invoke-DefenderApiproxy',
        'Test-ApiproxyPathPrefix',
        'Test-AuthChainHtmlResponse',
        'Invoke-XdrPortalRequest',
        'Discover-XdrPortalCapabilities',
        'Test-XdrEndpointAllowedByCapabilities',
        'Clear-XdrCapabilityCache'
    )
    CmdletsToExport   = @()
    AliasesToExport   = @()
    VariablesToExport = @()
}
