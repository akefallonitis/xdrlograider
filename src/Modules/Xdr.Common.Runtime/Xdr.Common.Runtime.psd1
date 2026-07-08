@{
    RootModule        = 'Xdr.Common.Runtime.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'a7b8c9d0-e1f2-3456-7890-123456012345'
    Author            = 'Alex Kefallonitis'
    CompanyName       = 'Alex Kefallonitis'
    Description       = 'XdrLogRaider · Xdr.Common.Runtime · the keystone Invoke-XdrEntryPoll activity work-unit · ETag-conditional checkpoint advance · pagination · IngestionMode dispatch.'
    PowerShellVersion = '7.4'
    RequiredModules   = @('Xdr.Common.Storage','Xdr.Common.Auth','Xdr.Common.Parser','Xdr.Common.Ingest','Xdr.Common.Cache','Xdr.Common.Telemetry','Xdr.Common.Exceptions')
    FunctionsToExport = @(
        'Get-XdrPortalConfig',
        'Invoke-XdrEntryPoll',
        'Invoke-XdrPortalHttp',
        'Invoke-XdrAuthenticated',
        'Test-XdrIsCapabilityAbsent',
        'Select-XdrExactlyOnceRows',
        'Get-XdrAdvancedFrontier',
        'Get-XdrCursorAtPrecision',
        'Invoke-XdrEntityFanout',
        'Get-XdrParentEntityIds',
        'Add-XdrEntityIds',
        'Get-XdrCachedEntityIds',
        'Clear-XdrEntityCache',
        'Get-XdrEntityIdField',
        'Get-XdrCheckpoint',
        'Get-XdrCheckpointsForPartition',
        'Save-XdrCheckpointAtomic',
        'Save-XdrCheckpointReset',
        'New-XdrRequestUrl',
        'New-XdrRequestBody',
        'Get-XdrRequestParams',
        'Resolve-XdrTimeWindow',
        'Select-XdrCycleEntries',
        'Get-XdrCircuitState',
        'Test-XdrCircuitClosed',
        'Update-XdrCircuitState',
        'Get-XdrManifests',
        'ConvertTo-XdrDeepHashtable',
        'ConvertFrom-XdrActivityInput',
        'Get-XdrEnabledCategorySet',
        'Test-XdrCategoryEnabled'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags         = @('XdrLogRaider', 'Runtime', 'Sentinel')
            ProjectUri   = 'https://github.com/akefallonitis/xdrlograider'
            LicenseUri   = 'https://github.com/akefallonitis/xdrlograider/blob/main/LICENSE'
            ReleaseNotes = 'v0.1.0 · ETag-conditional checkpoint · CycleId propagation · HttpClient REST.'
        }
    }
}
