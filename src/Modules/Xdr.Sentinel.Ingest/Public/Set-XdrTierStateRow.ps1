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
        [string] $OperationId = ''
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
    }

    # Reuse the existing Invoke-XdrStorageTableEntity helper which handles SAMI auth.
    # On first call (existing deploy without XdrTierState in ARM), the Upsert may
    # 404 — we then call CreateTable + retry. ARM-deployed clusters skip this fallback.
    try {
        Invoke-XdrStorageTableEntity `
            -StorageAccountName $StorageAccountName `
            -TableName          $TableName `
            -PartitionKey       $entity.PartitionKey `
            -RowKey             $entity.RowKey `
            -Operation          'Upsert' `
            -Entity             $entity | Out-Null
    } catch {
        # Defensive fallback: try to create the table then retry.
        if ("$($_.Exception.Message)" -match 'TableNotFound|404') {
            Invoke-XdrStorageTableEntity `
                -StorageAccountName $StorageAccountName `
                -TableName          $TableName `
                -PartitionKey       'placeholder' `
                -RowKey             'placeholder' `
                -Operation          'CreateTable' | Out-Null
            Invoke-XdrStorageTableEntity `
                -StorageAccountName $StorageAccountName `
                -TableName          $TableName `
                -PartitionKey       $entity.PartitionKey `
                -RowKey             $entity.RowKey `
                -Operation          'Upsert' `
                -Entity             $entity | Out-Null
        } else {
            throw
        }
    }
}
