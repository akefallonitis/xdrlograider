@{
    RootModule        = 'Xdr.Common.Telemetry.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'c2f1e814-7a3a-4d61-9a8e-3e5f7c8b9a01'
    Author            = 'XdrLogRaider'
    Description       = 'AppInsights telemetry helpers + correlation-ID propagation across Xdr.Auth/Poll/Ingest/Parser. Sibling-audit T1 punch-list item.'
    PowerShellVersion = '7.4'
    # Sibling-audit T1 contract: every Xdr.* module gets correlation-ID threading + structured events.
    # Module surface kept TINY (3 exports) to avoid bloating cold-start cost.
    FunctionsToExport = @(
        'Set-XdrCorrelationId',     # Generate / set the per-cycle correlation ID
        'Get-XdrCorrelationId',     # Read current correlation ID (auto-generates if absent)
        'Write-XdrTelemetry'        # Emit AppInsights customEvents row + console structured log
    )
    AliasesToExport   = @()
    CmdletsToExport   = @()
    VariablesToExport = @()
}
