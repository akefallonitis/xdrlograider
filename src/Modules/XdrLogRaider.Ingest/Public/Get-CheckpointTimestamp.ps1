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
        Write-Warning "Failed to read checkpoint for '$StreamName': $_"
        return [datetime]::MinValue
    }
}
