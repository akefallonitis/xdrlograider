@{
    RootModule            = 'Xdr.Sentinel.Ingest.psm1'
    ModuleVersion         = '1.0.0'
    CompatiblePSEditions  = @('Core')
    PowerShellVersion     = '7.4'
    GUID                  = '2f3bc6a8-4e1d-45b2-9a04-8c7f1d2b5e9a'
    Author                = 'Alex Kefallonitis'
    CompanyName           = 'Community'
    Copyright             = '(c) 2026 Alex Kefallonitis and contributors. MIT License.'
    Description           = 'L1 portal-generic Sentinel ingest layer (DCE/DCR + Storage Table + Send-XdrAppInsightsEvent). Includes batch writer, heartbeat, checkpoint persistence, and structured App Insights logging. Requires Az.Accounts at runtime (declared in src/requirements.psd1 for Function App; checked lazily for local dev).'
    # Note: Az.Accounts is a runtime requirement loaded by Azure Functions managed dependencies
    # via src/requirements.psd1. We do NOT declare it in RequiredModules so the module can
    # be imported for unit tests even without Az installed locally; runtime calls fail with
    # a clear error if Az.Accounts isn't present.
    FunctionsToExport     = @(
        'Send-ToLogAnalytics',
        'Write-Heartbeat',
        'Write-AuthTestResult',
        'Get-CheckpointTimestamp',
        'Set-CheckpointTimestamp',
        'Get-XdrAuthSelfTestFlag',
        'Invoke-XdrStorageTableEntity',
        # iter-14.0 Phase 14B: structured logging to App Insights.
        'Send-XdrAppInsightsTrace',
        'Send-XdrAppInsightsCustomEvent',
        'Send-XdrAppInsightsCustomMetric',
        'Send-XdrAppInsightsException'
    )
    CmdletsToExport       = @()
    VariablesToExport     = @()
    AliasesToExport       = @()
    PrivateData           = @{
        PSData = @{
            Tags         = @('LogAnalytics', 'DCE', 'DCR', 'Sentinel')
            LicenseUri   = 'https://github.com/akefallonitis/xdrlograider/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/akefallonitis/xdrlograider'
            ReleaseNotes = 'Initial release. Part of XdrLogRaider v1.0.0.'
        }
    }
}
