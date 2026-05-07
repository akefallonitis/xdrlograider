function Set-XdrTierStateRow {
    <#
    .SYNOPSIS
        Writes/upserts a per-stream tier-state row to Storage table XdrTierState.

    .DESCRIPTION
        Called by Xdr-PollStream activity at its FINAL step (after Send-ToLogAnalytics
        succeeds). The row is later aggregated by Connector-Heartbeat to populate
        XdrConnectorHealth_CL with per-(Portal, Tier) StreamsSucceeded/RowsIngested
        metrics — which the Sentinel data-connector card's connectivityCriteria
        uses to flip the card to "Connected".

        Per-stream granularity (PartitionKey=Tier, RowKey=Stream) lets Connector-Heartbeat
        compute per-tier aggregates via a single Storage Table query.

        Activities CAN do non-deterministic work (Storage writes, current time) per
        Microsoft Durable Functions docs. This is the architecturally-correct place
        for the per-tier StreamsSucceeded signal.

    .PARAMETER StorageAccountName
        FA's Storage account (same as connectorCheckpoints + xdrIngestDlq).

    .PARAMETER TableName
        Storage table name. Default: 'XdrTierState'.

    .PARAMETER Portal
        Logical portal name (Defender / Entra / Purview / Intune). Stored as a
        column for v0.2.0+ multi-portal aggregation.

    .PARAMETER Tier
        ActionCenter | XspmGraph | Configuration | Inventory | Maintenance.

    .PARAMETER Stream
        Stream identifier (e.g. 'MDE_ActionCenter_CL').

    .PARAMETER RowsIngested
        Number of rows successfully ingested.

    .PARAMETER Success
        Whether the per-stream poll succeeded.

    .PARAMETER ErrorText
        Error message if Success=$false; null otherwise.

    .PARAMETER OperationId
        Correlation/operation ID for stitching telemetry across timer→orch→activity→ingest.

    .OUTPUTS
        None. Side-effect: PUT row to Storage Table (upsert).

    .EXAMPLE
        Set-XdrTierStateRow -StorageAccountName 'xdrlrst' -Portal 'Defender' `
            -Tier 'ActionCenter' -Stream 'MDE_ActionCenter_CL' `
            -RowsIngested 5 -Success $true -OperationId $opId
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $StorageAccountName,
        [string] $TableName = 'XdrTierState',
        [Parameter(Mandatory)] [ValidateSet('Defender','Entra','Purview','Intune')] [string] $Portal,
        [Parameter(Mandatory)] [ValidateSet('ActionCenter','XspmGraph','Configuration','Inventory','Maintenance')] [string] $Tier,
        [Parameter(Mandatory)] [string] $Stream,
        [int] $RowsIngested = 0,
        [bool] $Success = $true,
        [string] $ErrorText = '',
        [string] $OperationId = '',

        # Section R++.A: truth-signal classification per Invoke-MDEEndpoint
        # SuccessKind. Lets Connector-Heartbeat aggregator + connector-card
        # query distinguish "tenant doesn't have feature" from "real failure"
        # from "live but no rows this poll" from "live with rows".
        [ValidateSet('live','live-empty','tenant-gated','error','')]
        [string] $Reason = '',
        [int] $HttpStatus = 0
    )

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
