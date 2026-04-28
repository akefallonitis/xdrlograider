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
        Iter 13.15: refactored to use Invoke-XdrStorageTableEntity (HttpClient
        + MI token via Get-AzAccessToken -ResourceUrl https://storage.azure.com/).
        Replaces AzTable 2.1.0 + New-AzStorageContext path which did not
        reliably honor MI auth (root cause of iter-13.13 production breakage).
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [Parameter(Mandatory)] [string] $StorageAccountName,
        [string] $TableName = 'connectorCheckpoints',
        [Parameter(Mandatory)] [string] $StreamName
    )

    try {
        $entity = Invoke-XdrStorageTableEntity `
            -StorageAccountName $StorageAccountName `
            -TableName $TableName `
            -PartitionKey $StreamName `
            -RowKey 'latest' `
            -Operation Get -ErrorAction Stop

        if ($null -eq $entity) {
            Write-Verbose "No checkpoint for '$StreamName'; returning MinValue"
            return [datetime]::MinValue
        }

        # Iter 13.9 (C8): explicit try/catch around DateTime.Parse so a
        # corrupt LastPolledUtc value (manually edited, locale issue,
        # truncated row) returns MinValue + warning instead of crashing
        # the entire tier poll. Outer try/catch already exists for storage
        # failures; this one specifically handles the parse step.
        try {
            return [datetime]::Parse($entity.LastPolledUtc).ToUniversalTime()
        } catch {
            Write-Warning ("Get-CheckpointTimestamp: corrupt LastPolledUtc='{0}' for stream '{1}' — falling back to MinValue. Storage row may need manual cleanup. Error: {2}" -f $entity.LastPolledUtc, $StreamName, $_.Exception.Message)
            return [datetime]::MinValue
        }
    } catch {
        Write-Warning "Failed to read checkpoint for '$StreamName': $($_.Exception.Message)"
        return [datetime]::MinValue
    }
}
