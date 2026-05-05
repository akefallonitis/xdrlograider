@{
    RootModule            = 'Xdr.Sentinel.Ingest.psm1'
    ModuleVersion         = '1.0.0'
    CompatiblePSEditions  = @('Core')
    PowerShellVersion     = '7.4'
    GUID                  = '2f3bc6a8-4e1d-45b2-9a04-8c7f1d2b5e9a'
    Author                = 'Alex Kefallonitis'
    CompanyName           = 'Community'
    Copyright             = '(c) 2026 Alex Kefallonitis and contributors. MIT License.'
    Description           = 'L1 portal-generic Sentinel ingest layer (DCE/DCR + Storage Table). Includes batch writer, heartbeat, checkpoint persistence, and DLQ. AppInsights helpers extracted to Xdr.Common.Telemetry (Phase J D''.22). Requires Az.Accounts at runtime (declared in src/requirements.psd1 for Function App; checked lazily for local dev).'
    # Note: Az.Accounts is a runtime requirement loaded by Azure Functions managed dependencies
    # via src/requirements.psd1. We do NOT declare it in RequiredModules so the module can
    # be imported for unit tests even without Az installed locally; runtime calls fail with
    # a clear error if Az.Accounts isn't present.
    # Phase J D'.22 (2026-05-04): Send-XdrAppInsights* helpers extracted to
    # Xdr.Common.Telemetry. This module declares it as a RequiredModule.
    RequiredModules       = @('Xdr.Common.Telemetry')
    FunctionsToExport     = @(
        'Send-ToLogAnalytics',
        'Write-Heartbeat',
        'Get-CheckpointTimestamp',
        'Set-CheckpointTimestamp',
        'Invoke-XdrStorageTableEntity',
        'Get-DcrImmutableIdForStream',
        # v0.1.0 GA first publish: ingest dead-letter queue. Failed batches
        # are persisted to Storage Table xdrIngestDlq + drained on next poll.
        'Push-XdrIngestDlq',
        'Pop-XdrIngestDlq',
        'Remove-XdrIngestDlqEntry'
        # Send-XdrAppInsights* helpers (Trace, CustomEvent, CustomMetric,
        # Exception, Dependency) moved to Xdr.Common.Telemetry per Phase J D'.22.
        # They remain available via the RequiredModules dependency chain.
    )
    CmdletsToExport       = @()
    VariablesToExport     = @()
    # v0.1.0 GA Phase A.2: forward-compat Xdr* aliases per directive 16.
    AliasesToExport       = @(
        'Send-XdrToLogAnalytics',
        'Get-XdrCheckpointTimestamp',
        'Set-XdrCheckpointTimestamp',
        'Get-XdrDcrImmutableIdForStream'
    )
    PrivateData           = @{
        PSData = @{
            Tags         = @('LogAnalytics', 'DCE', 'DCR', 'Sentinel')
            LicenseUri   = 'https://github.com/akefallonitis/xdrlograider/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/akefallonitis/xdrlograider'
            ReleaseNotes = 'v0.1.0 GA: forward-compat Xdr* aliases added (Send-XdrToLogAnalytics, Get-XdrCheckpointTimestamp, Set-XdrCheckpointTimestamp, Get-XdrDcrImmutableIdForStream) per Phase A.2 in .claude/plans/immutable-splashing-waffle.md. Legacy names retained for v0.1.0 GA scope.'
        }
    }
}
