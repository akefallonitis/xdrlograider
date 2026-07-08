@{
    RootModule        = 'Xdr.Common.Telemetry.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'b2c3d4e5-f6a7-8901-2345-678901bcdef0'
    Author            = 'Alex Kefallonitis (al.kefallonitis@gmail.com)'
    CompanyName       = 'Alex Kefallonitis'
    Copyright         = '(c) 2026 Alex Kefallonitis · MIT License'
    Description       = 'XdrLogRaider AppInsights telemetry · native TrackEvent/Dependency/Exception/Metric/Trace per LOCK 24 (workspace-mode → Sentinel workspace).'
    PowerShellVersion = '7.4'
    FunctionsToExport = @('Send-XdrTelemetry','Track-XdrEvent','Track-XdrException','Track-XdrDependency','Track-XdrMetric','Track-XdrTrace','Send-XdrHeartbeat')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
