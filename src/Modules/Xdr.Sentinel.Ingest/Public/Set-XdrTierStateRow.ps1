function Set-XdrTierStateRow {
    <#
    .SYNOPSIS
        Writes/upserts a per-sub-area state row to the XdrTierState storage table.
        Producer side of the ConnectorHeartbeat chain (Rule 12).

    .DESCRIPTION
        Called by each per-sub-area timer trigger at its FINAL step. ConnectorHeartbeat
        reads the aggregate (Get-XdrTierStateAggregate) every 5 minutes to compose
        the populated Notes JSON for XdrConnectorHealth_CL.

        Two parameter sets:

        ByProperties (Phase 1+):
            Set-XdrTierStateRow -StorageAccountName ... -PartitionKey 'Defender' `
                -RowKey 'action_center' -Properties @{ Tier='ActionCenter'; ... }
            One row per <Portal>::<SubArea>; arbitrary columns via -Properties.

        BySchema (pilot compat):
            Set-XdrTierStateRow -StorageAccountName ... -Portal 'Defender' `
                -Tier 'ActionCenter' -Stream 'Defender_ActionCenter_CL' `
                -RowsIngested 5 -Reason 'live' -OperationId $opId
            Pilot's per-stream signature; emits row with PartitionKey='Portal|Tier'
            RowKey=Stream. Retained for backward compat; new code uses ByProperties.

        Per Rule 6, the 4-value SuccessKind set is live/live-empty/rate-limited/error.
        ‘tenant-gated’ retired (replaced by ‘error’ + LicenseHint per Rule 23).

    .OUTPUTS
        None. Side-effect: PUT row to Storage Table (upsert).
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByProperties')]
    param(
        [Parameter(Mandatory)] [string] $StorageAccountName,
        [string] $TableName = 'XdrTierState',

        # ByProperties (Phase 1+ per-sub-area pattern)
        [Parameter(Mandatory, ParameterSetName = 'ByProperties')] [string] $PartitionKey,
        [Parameter(Mandatory, ParameterSetName = 'ByProperties')] [string] $RowKey,
        [Parameter(Mandatory, ParameterSetName = 'ByProperties')] [hashtable] $Properties,

        # BySchema (pilot compat — to be deprecated in v0.3.0)
        [Parameter(Mandatory, ParameterSetName = 'BySchema')]
        [ValidateSet('Defender','Entra','Purview','Intune')] [string] $Portal,
        [Parameter(Mandatory, ParameterSetName = 'BySchema')]
        [ValidateSet('ActionCenter','XspmGraph','Configuration','Inventory','Maintenance')] [string] $Tier,
        [Parameter(Mandatory, ParameterSetName = 'BySchema')] [string] $Stream,
        [Parameter(ParameterSetName = 'BySchema')] [int] $RowsIngested = 0,
        [Parameter(ParameterSetName = 'BySchema')] [bool] $Success = $true,
        [Parameter(ParameterSetName = 'BySchema')] [string] $ErrorText = '',
        [Parameter(ParameterSetName = 'BySchema')] [string] $OperationId = '',
        [Parameter(ParameterSetName = 'BySchema')]
        [ValidateSet('live','live-empty','rate-limited','error','')]
        [string] $Reason = '',
        [Parameter(ParameterSetName = 'BySchema')] [int] $HttpStatus = 0
    )

    if ($PSCmdlet.ParameterSetName -eq 'ByProperties') {
        $entity = @{
            PartitionKey = $PartitionKey
            RowKey       = $RowKey
            TimestampUtc = ([DateTime]::UtcNow).ToString('o')
        }
        foreach ($k in $Properties.Keys) { $entity[$k] = $Properties[$k] }
    } else {
        $entity = @{
            PartitionKey  = "$Portal|$Tier"
            RowKey        = $Stream
            TimestampUtc  = ([DateTime]::UtcNow).ToString('o')
            Portal        = $Portal
            Tier          = $Tier
            Stream        = $Stream
            RowsIngested  = $RowsIngested
            Success       = $Success
            ErrorText     = $ErrorText
            OperationId   = $OperationId
            Reason        = $Reason
            HttpStatus    = $HttpStatus
        }
    }

    # Reuse the existing Invoke-XdrStorageTableEntity helper which handles SAMI auth.
    # SENIOR-ARCHITECT INVARIANT: the FA's SAMI is DATA-PLANE only
    # (Storage Table Data Contributor). The XdrTierState table MUST be provisioned
    # by the ARM template (deploy/compiled/mainTemplate.json declares it as a
    # Microsoft.Storage/storageAccounts/tableServices/tables resource). The activity
    # NEVER attempts CreateTable — that would require control-plane access and
    # violate least-privilege.
    # If the Upsert returns 404 TableNotFound, throw a clear actionable error
    # pointing the operator to the ARM remediation path.
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
            throw ("Set-XdrTierStateRow: Storage table '{0}' does not exist on storage account '{1}'. " +
                   "ARM template MUST provision this table (Microsoft.Storage/storageAccounts/tableServices/tables). " +
                   "Remediation: redeploy the ARM template OR have an operator with control-plane access PUT to " +
                   "https://management.azure.com/subscriptions/.../resourceGroups/.../providers/Microsoft.Storage/storageAccounts/{1}/tableServices/default/tables/{0}?api-version=2023-05-01. " +
                   "The FA's SAMI is data-plane only and MUST NOT create resources." -f $TableName, $StorageAccountName)
        }
        throw
    }
}
