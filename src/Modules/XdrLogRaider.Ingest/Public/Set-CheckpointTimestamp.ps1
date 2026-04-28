function Set-CheckpointTimestamp {
    <#
    .SYNOPSIS
        Writes the last-polled timestamp for a stream to the checkpoint Storage Table.

    .PARAMETER StorageAccountName
        Storage account name.

    .PARAMETER TableName
        Table name (default 'connectorCheckpoints').

    .PARAMETER StreamName
        Stream name used as partition key.

    .PARAMETER Timestamp
        UTC timestamp to persist (default: now).

    .NOTES
        Iter 13.15: refactored to use Invoke-XdrStorageTableEntity Upsert
        (PUT WITHOUT If-Match = Insert-Or-Replace). Replaces AzTable's
        Add-AzTableRow -UpdateExisting which did not reliably honor MI auth
        (root cause of iter-13.13 production breakage). Table is pre-created
        by Bicep at deploy time, so runtime table-creation logic is removed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $StorageAccountName,
        [string] $TableName = 'connectorCheckpoints',
        [Parameter(Mandatory)] [string] $StreamName,
        [datetime] $Timestamp = [datetime]::UtcNow
    )

    try {
        $entity = @{
            LastPolledUtc = $Timestamp.ToString('o')
        }

        Invoke-XdrStorageTableEntity `
            -StorageAccountName $StorageAccountName `
            -TableName $TableName `
            -PartitionKey $StreamName `
            -RowKey 'latest' `
            -Operation Upsert `
            -Entity $entity -ErrorAction Stop | Out-Null
    } catch {
        Write-Warning "Failed to write checkpoint for '$StreamName': $($_.Exception.Message)"
    }
}
