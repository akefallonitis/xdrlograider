@{
    RootModule            = 'Xdr.Sentinel.Ingest.psm1'
    ModuleVersion         = '1.0.0'
    CompatiblePSEditions  = @('Core')
    PowerShellVersion     = '7.4'
    GUID                  = '2f3bc6a8-4e1d-45b2-9a04-8c7f1d2b5e9a'
    Author                = 'Alex Kefallonitis'
    CompanyName           = 'Community'
    Copyright             = '(c) 2026 Alex Kefallonitis and contributors. MIT License.'
    Description           = 'L1 portal-generic Sentinel ingest layer (DCE/DCR + Storage Table). Includes batch writer, heartbeat, checkpoint persistence, and DLQ. AppInsights helpers extracted to Xdr.Common.Telemetry (Phase J D''.22). Requires Az.Accounts at runtime; bundled in function-app.zip via the release pipeline (Y1 Linux Consumption does not support Managed Dependencies, so src/requirements.psd1 is intentionally empty).'
    # Note: Az.Accounts is loaded at FA startup via profile.ps1 from the modules
    # bundled into function-app.zip by the release workflow (pinned RequiredVersion
    # in .github/workflows/release.yml). It is intentionally NOT declared in
    # RequiredModules so the module can be imported for unit tests even without Az
    # installed locally; runtime calls fail with a clear error if Az.Accounts is
    # missing on the FA at execution time.
    # Phase J D'.22 (2026-05-04): Send-XdrAppInsights* helpers extracted to
    # Xdr.Common.Telemetry. This module declares it as a RequiredModule.
    RequiredModules       = @('Xdr.Common.Telemetry')
    FunctionsToExport     = @(
        'Send-ToLogAnalytics',
        'Write-Heartbeat',
        'Get-CheckpointTimestamp',
        'Get-CheckpointState',
        'Set-CheckpointTimestamp',
        'Invoke-XdrStorageTableEntity',
        'Get-DcrImmutableIdForStream',
        # v0.1.0 GA first publish: ingest dead-letter queue. Failed batches
        # are persisted to Storage Table xdrIngestDlq + drained on next poll.
        'Push-XdrIngestDlq',
        'Pop-XdrIngestDlq',
        'Remove-XdrIngestDlqEntry',
        # v0.1.0 GA Section R consolidation (2026-05-06): per-tier StreamsSucceeded
        # signal moves into XdrTierState Storage table. Activity writes; Heartbeat reads.
        'Get-XdrTierCadenceMap',
        'Set-XdrTierStateRow',
        'Get-XdrTierStateAggregate',
        # Decision 18 circuit-breaker pure state-machine helper.
        'Get-XdrCircuitBreakerNextState',
        # Architecture I (Plan R++++++++++ 2026-05-08): tenant capability cache
        # populated daily on Inventory cadence by Connector-Heartbeat from
        # MDE_TenantContext_CL. WARNING-ONLY per Plan AMEND-1 #5 — never used to
        # short-circuit polling, only to enrich operator-visible context.
        'Set-XdrTenantStateCapability',
        'Get-XdrTenantStateCapability'
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
