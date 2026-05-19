@{
    RootModule        = 'Xdr.Ingest.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '4a8c2e9b-7d1f-4e3a-9b5c-6d2f8a1c0b3e'
    Author            = 'Alex Kefallonitis'
    CompanyName       = 'XdrLogRaider'
    Copyright         = '(c) 2026 Alex Kefallonitis. MIT License.'
    Description       = 'Logs Ingestion API sender: gzip + MI bearer + 1 MB chunk split + 429 retry + DLQ on terminal 4xx. Heartbeat writer.'
    PowerShellVersion = '7.4'
    FunctionsToExport = @(
        'Send-ToDce',
        'Write-Heartbeat',
        'Split-IngestBatch',
        'Get-MiBearerToken',
        'Invoke-XdrStorageTableEntity'
    )
    CmdletsToExport   = @()
    AliasesToExport   = @()
    VariablesToExport = @()
}
