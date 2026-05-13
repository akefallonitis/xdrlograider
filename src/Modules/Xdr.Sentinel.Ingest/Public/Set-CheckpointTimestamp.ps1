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
        Uses Invoke-XdrStorageTableEntity Upsert (PUT WITHOUT If-Match =
        Insert-Or-Replace). The legacy AzTable Add-AzTableRow -UpdateExisting
        path did not reliably honor MI auth, which caused production breakage
        in earlier builds. The table is pre-created by Bicep at deploy time,
        so runtime table-creation logic is omitted here.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $StorageAccountName,
        [string] $TableName = 'connectorCheckpoints',
        [Parameter(Mandatory)] [string] $StreamName,
        [datetime] $Timestamp = [datetime]::UtcNow,

        # Multi-cycle pagination resume (Phase A0.3). Writes page-index
        # state for endpoints that exceed the Y1 10-min activity cap on
        # first poll (vuln_management 1000 pages × 1s each = ~16 min).
        # Caller may pass either, both, or neither.
        [Nullable[int]] $LastCompletedPage,
        [string] $PaginationToken,

        # Reset both pagination fields to "complete" — caller signals
        # that the multi-cycle resume is finished. Equivalent to passing
        # LastCompletedPage=0 + PaginationToken=''.
        [switch] $ClearPagination
    )

    try {
        $entity = @{
            LastPolledUtc = $Timestamp.ToString('o')
        }
        if ($ClearPagination) {
            $entity.LastCompletedPage = 0
            $entity.PaginationToken   = ''
        } else {
            if ($PSBoundParameters.ContainsKey('LastCompletedPage')) {
                $entity.LastCompletedPage = [int]$LastCompletedPage
            }
            if ($PSBoundParameters.ContainsKey('PaginationToken')) {
                $entity.PaginationToken = [string]$PaginationToken
            }
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
