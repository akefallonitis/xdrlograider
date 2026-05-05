# Module manifest for Xdr.Common.Telemetry
# Generic AppInsights telemetry helpers used by all portal modules (Defender,
# Entra, Purview, Intune). Per Phase J D'.22: extracted from
# Xdr.Sentinel.Ingest so v0.2.0 portal modules depend on Xdr.Common.Telemetry
# for telemetry rather than coupling to ingest.
@{
    RootModule        = 'Xdr.Common.Telemetry.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'c7e84a3f-1d62-4f8b-9e15-2a6b8d4c7e3f'
    Author            = 'XdrLogRaider Project'
    Description       = 'Generic AppInsights telemetry helpers (CustomEvent, CustomMetric, Exception, Trace, Dependency) for SRE/dev observability surface'
    PowerShellVersion = '7.4'
    FunctionsToExport = @(
        'Send-XdrAppInsightsTrace',
        'Send-XdrAppInsightsCustomEvent',
        'Send-XdrAppInsightsCustomMetric',
        'Send-XdrAppInsightsException',
        'Send-XdrAppInsightsDependency'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags         = @('XdrLogRaider', 'AppInsights', 'Telemetry', 'Observability', 'MultiPortal')
            ProjectUri   = 'https://github.com/akefallonitis/xdrlograider'
            ReleaseNotes = 'v0.1.0 GA Phase J D''.22 — extracted from Xdr.Sentinel.Ingest. AppInsights = SRE/dev surface (separation of concerns from XdrConnectorHealth_CL operator surface).'
        }
    }
}
