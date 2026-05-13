function Set-XdrTenantStateCapability {
    <#
    .SYNOPSIS
        Writes/upserts a tenant capability snapshot to Storage table XdrTenantState.

    .DESCRIPTION
        Architecture I (Plan R++++++++++): caches per-tenant capability flags read
        from MDE_TenantContext_CL on the Inventory cadence (24h) so the orchestrator
        + dispatcher can fast-lookup whether a tenant has MDI / MDATP-Plan2 / OATP /
        XSPM / etc. licensing without re-querying the workspace each cycle.

        Connector-Heartbeat (or a dedicated daily Inventory-tier activity) calls this
        function daily after MDE_TenantContext_CL ingest completes. The orchestrator
        consults Get-XdrTenantStateCapability before fanning out streams to skip
        known-gated streams + emit informational `Reason='capability-warning'` rows
        instead of attempting + recording 4xx on the connector card.

        Per AMEND-1 #5 + Plan R+++++.4 all-live policy: capability detection is
        WARNING-ONLY. We never short-circuit polling - runtime SuccessKind is the
        ground truth per actual customer deployment. This cache exists to enrich
        operator-visible context (XdrConnectorHealth_CL.Reason col), NOT to gate.

    .PARAMETER StorageAccountName
        FA's Storage account (same as connectorCheckpoints + xdrIngestDlq + XdrTierState).

    .PARAMETER TableName
        Storage table name. Default: 'XdrTenantState'.

    .PARAMETER TenantId
        Azure AD tenant GUID.

    .PARAMETER IsMdiActive
        Microsoft Defender for Identity provisioned + license active.

    .PARAMETER IsMdatpActive
        Microsoft Defender for Endpoint Plan 2 license active.

    .PARAMETER IsOatpActive
        Microsoft Defender for Office Plan 2 / MCAS active.

    .PARAMETER IsXspmActive
        Microsoft Defender External Attack Surface Management / XSPM active.

    .PARAMETER LicenseTier
        Plan 1 / Plan 2 / E5 / etc.

    .PARAMETER Region
        Tenant home region.

    .OUTPUTS
        None. Side-effect: PUT row to Storage Table XdrTenantState.

    .EXAMPLE
        Set-XdrTenantStateCapability -StorageAccountName 'xdrlrst' `
            -TenantId '00000000-0000-0000-0000-000000000000' `
            -IsMdiActive $false -IsMdatpActive $true `
            -LicenseTier 'Plan2' -Region 'westeurope'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $StorageAccountName,
        [string] $TableName = 'XdrTenantState',
        [Parameter(Mandatory)] [string] $TenantId,
        [bool] $IsMdiActive = $false,
        [bool] $IsMdatpActive = $false,
        [bool] $IsOatpActive = $false,
        [bool] $IsXspmActive = $false,
        [string] $LicenseTier = '',
        [string] $Region = ''
    )

    $entity = @{
        PartitionKey   = 'Capability'
        RowKey         = $TenantId
        TenantId       = $TenantId
        IsMdiActive    = $IsMdiActive
        IsMdatpActive  = $IsMdatpActive
        IsOatpActive   = $IsOatpActive
        IsXspmActive   = $IsXspmActive
        LicenseTier    = $LicenseTier
        Region         = $Region
        LastRefreshUtc = ([DateTime]::UtcNow).ToString('o')
    }

    try {
        Invoke-XdrStorageTableEntity `
            -StorageAccountName $StorageAccountName `
            -TableName          $TableName `
            -PartitionKey       $entity.PartitionKey `
            -RowKey             $entity.RowKey `
            -Operation          'Upsert' `
            -Entity             $entity | Out-Null
    } catch {
        if ("$($_.Exception.Message)" -match 'TableNotFound|404') {
            throw ("Set-XdrTenantStateCapability: Storage table '{0}' does not exist on storage account '{1}'. " +
                   "ARM template MUST provision this table (Microsoft.Storage/storageAccounts/tableServices/tables). " +
                   "Remediation: redeploy the ARM template. The FA's SAMI is data-plane only and MUST NOT create resources." -f $TableName, $StorageAccountName)
        }
        throw
    }
}
