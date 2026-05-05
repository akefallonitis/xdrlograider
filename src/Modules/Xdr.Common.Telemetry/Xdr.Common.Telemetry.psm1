# Xdr.Common.Telemetry — generic AppInsights telemetry helpers
#
# Phase J D'.22 (2026-05-04): extracted from Xdr.Sentinel.Ingest.
# v0.2.0 multi-portal expansion (Entra/Purview/Intune) needs to emit
# AppInsights telemetry without coupling to Xdr.Sentinel.Ingest (which is
# Defender-DCE-specific). Extracting here gives the right dependency graph:
# portal modules depend on Xdr.Common.Telemetry; Xdr.Sentinel.Ingest also
# depends on Xdr.Common.Telemetry for its own telemetry needs.
#
# Architecture (separation of concerns per Phase Section §5.2.quater):
#   - Workspace tables (XdrConnectorHealth_CL, Defender_<Category>_CL) =
#     OPERATOR surface (Sentinel KQL + workbooks + analytic rules)
#   - AppInsights tables (AppMetrics, AppExceptions, AppTraces, AppEvents,
#     AppDependencies) = SRE/DEV surface (Azure Monitor / Live Metrics /
#     Profiler) — for connector internals troubleshooting
#   - Bridge: XdrOps-* analytic rules read AppInsights (federated KQL) and
#     fire operator alerts when SRE telemetry needs operator attention

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Dot-source private helpers + public functions.
foreach ($folder in @('Private', 'Public')) {
    $dir = Join-Path $PSScriptRoot $folder
    if (Test-Path $dir) {
        Get-ChildItem -Path $dir -Filter '*.ps1' -File | ForEach-Object {
            . $_.FullName
        }
    }
}

# Export public functions per the .psd1 FunctionsToExport list.
Export-ModuleMember -Function @(
    'Send-XdrAppInsightsTrace',
    'Send-XdrAppInsightsCustomEvent',
    'Send-XdrAppInsightsCustomMetric',
    'Send-XdrAppInsightsException',
    'Send-XdrAppInsightsDependency'
)
