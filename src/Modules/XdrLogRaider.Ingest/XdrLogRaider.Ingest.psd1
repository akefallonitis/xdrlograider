@{
    RootModule            = 'XdrLogRaider.Ingest.psm1'
    ModuleVersion         = '1.0.0'
    CompatiblePSEditions  = @('Core')
    PowerShellVersion     = '7.4'
    GUID                  = '7c1e9aa3-2d68-4b4f-91a7-08e6f4d5b921'
    Author                = 'Alex Kefallonitis'
    CompanyName           = 'Community'
    Copyright             = '(c) 2026 Alex Kefallonitis and contributors. MIT License.'
    Description           = 'Backward-compat shim. Imports Xdr.Sentinel.Ingest (L1 portal-generic Sentinel ingest layer) and re-exports the legacy function names (Send-ToLogAnalytics, Write-Heartbeat, Get-CheckpointTimestamp, Set-CheckpointTimestamp, Get-XdrAuthSelfTestFlag, Invoke-XdrStorageTableEntity, Send-XdrAppInsights*). New code SHOULD reference Xdr.Sentinel.Ingest directly; this shim stays through the v0.1.0 GA window for operator-script + test-mock backward-compat.'
    FunctionsToExport     = @(
        'Send-ToLogAnalytics',
        'Write-Heartbeat',
        'Write-AuthTestResult',
        'Get-CheckpointTimestamp',
        'Set-CheckpointTimestamp',
        'Get-XdrAuthSelfTestFlag',
        'Invoke-XdrStorageTableEntity',
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
            Tags         = @('LogAnalytics', 'DCE', 'DCR', 'Sentinel', 'Compat')
            LicenseUri   = 'https://github.com/akefallonitis/xdrlograider/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/akefallonitis/xdrlograider'
            ReleaseNotes = 'Backward-compat shim. Re-exports the renamed Xdr.Sentinel.Ingest surface under the legacy XdrLogRaider.Ingest name.'
        }
    }
}
