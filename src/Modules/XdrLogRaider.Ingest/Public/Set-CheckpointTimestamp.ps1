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
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $StorageAccountName,
        [string] $TableName = 'connectorCheckpoints',
        [Parameter(Mandatory)] [string] $StreamName,
        [datetime] $Timestamp = [datetime]::UtcNow
    )

    try {
        $context = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount -ErrorAction Stop
        $table = Get-AzStorageTable -Name $TableName -Context $context -ErrorAction SilentlyContinue
        if (-not $table) {
            $table = New-AzStorageTable -Name $TableName -Context $context -ErrorAction Stop
        }

        $entity = [ordered]@{
            PartitionKey   = $StreamName
            RowKey         = 'latest'
            LastPolledUtc  = $Timestamp.ToString('o')
        }

        Add-AzTableRow -Table $table.CloudTable -PartitionKey $StreamName -RowKey 'latest' -Property $entity -UpdateExisting | Out-Null
    } catch {
        Write-Warning "Failed to write checkpoint for '$StreamName': $_"
    }
}
