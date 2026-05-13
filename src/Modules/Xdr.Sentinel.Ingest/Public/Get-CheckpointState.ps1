function Get-CheckpointState {
    <#
    .SYNOPSIS
        Reads the full checkpoint row for a stream (timestamp + pagination state).

    .DESCRIPTION
        Companion to Get-CheckpointTimestamp. Returns a hashtable with:
            LastPolledUtc      [datetime]    last successful poll cycle
            LastCompletedPage  [int]         last page index successfully ingested (0 = no resume needed)
            PaginationToken    [string]      opaque continuation token (empty = no resume needed)
        If no checkpoint exists, returns @{ LastPolledUtc=MinValue; LastCompletedPage=0; PaginationToken='' }.

        Used by Xdr-PollStream activity for multi-cycle pagination resume on
        endpoints whose first-poll page count exceeds the Y1 10-min activity
        cap (vuln_management 1000 pages × 1s each = ~16 min wall-clock).

    .PARAMETER StorageAccountName
        Storage account name.

    .PARAMETER TableName
        Table name (default 'connectorCheckpoints').

    .PARAMETER StreamName
        Stream name used as partition key.

    .OUTPUTS
        [hashtable] { LastPolledUtc, LastCompletedPage, PaginationToken }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $StorageAccountName,
        [string] $TableName = 'connectorCheckpoints',
        [Parameter(Mandatory)] [string] $StreamName
    )

    $default = @{
        LastPolledUtc     = [datetime]::MinValue
        LastCompletedPage = 0
        PaginationToken   = ''
    }

    try {
        $entity = Invoke-XdrStorageTableEntity `
            -StorageAccountName $StorageAccountName `
            -TableName $TableName `
            -PartitionKey $StreamName `
            -RowKey 'latest' `
            -Operation Get -ErrorAction Stop

        if ($null -eq $entity) { return $default }

        $result = @{
            LastPolledUtc     = [datetime]::MinValue
            LastCompletedPage = 0
            PaginationToken   = ''
        }
        if ($entity.PSObject.Properties.Name -contains 'LastPolledUtc') {
            try { $result.LastPolledUtc = [datetime]::Parse($entity.LastPolledUtc).ToUniversalTime() } catch { }
        }
        if ($entity.PSObject.Properties.Name -contains 'LastCompletedPage') {
            try { $result.LastCompletedPage = [int]$entity.LastCompletedPage } catch { }
        }
        if ($entity.PSObject.Properties.Name -contains 'PaginationToken') {
            $result.PaginationToken = [string]$entity.PaginationToken
        }
        return $result
    } catch {
        Write-Warning "Failed to read checkpoint state for '$StreamName': $($_.Exception.Message)"
        return $default
    }
}
