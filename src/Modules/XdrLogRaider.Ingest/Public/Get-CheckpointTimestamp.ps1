function Get-CheckpointTimestamp {
    <#
    .SYNOPSIS
        Reads the last-polled timestamp for a stream from the checkpoint Storage Table.

    .DESCRIPTION
        Lookup strategy: Storage Table 'connectorCheckpoints', partition key = stream name,
        row key = 'latest'. Returns [datetime] of last successful poll, or [datetime]::MinValue
        if no checkpoint exists (indicates first run).

    .PARAMETER StorageAccountName
        Storage account name (from $env:STORAGE_ACCOUNT_NAME).

    .PARAMETER TableName
        Table name (default 'connectorCheckpoints').

    .PARAMETER StreamName
        Stream name used as partition key.

    .OUTPUTS
        [datetime] UTC. MinValue if no prior checkpoint.

    .NOTES
        Uses Az.Storage / Az.Table. Inherits managed identity auth.
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [Parameter(Mandatory)] [string] $StorageAccountName,
        [string] $TableName = 'connectorCheckpoints',
        [Parameter(Mandatory)] [string] $StreamName
    )

    try {
        $context = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount -ErrorAction Stop
        $table = Get-AzStorageTable -Name $TableName -Context $context -ErrorAction SilentlyContinue
        if (-not $table) {
            Write-Verbose "Checkpoint table '$TableName' does not exist; returning MinValue for first run"
            return [datetime]::MinValue
        }

        $entity = Get-AzTableRow -Table $table.CloudTable -PartitionKey $StreamName -RowKey 'latest' -ErrorAction SilentlyContinue
        if (-not $entity) {
            Write-Verbose "No checkpoint for '$StreamName'; returning MinValue"
            return [datetime]::MinValue
        }

        return [datetime]::Parse($entity.LastPolledUtc).ToUniversalTime()
    } catch {
        Write-Warning "Failed to read checkpoint for '$StreamName': $_"
        return [datetime]::MinValue
    }
}
