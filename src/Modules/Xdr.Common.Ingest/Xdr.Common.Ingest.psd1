@{
    RootModule        = 'Xdr.Common.Ingest.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'f6a7b8c9-d0e1-2345-6789-012345f01234'
    Author            = 'Alex Kefallonitis'
    CompanyName       = 'Alex Kefallonitis'
    Description       = 'XdrLogRaider · DCE/DCR ingest · single-encode hashtable→JSON discipline · DLQ on 5xx-after-retries AND terminal 4xx AND network-faults · no silent loss.'
    PowerShellVersion = '7.4'
    RequiredModules   = @('Xdr.Common.Telemetry','Xdr.Common.Exceptions')
    FunctionsToExport = @('Send-ToDce','Send-XdrDlq','Get-XdrDcrAuthToken')
}
