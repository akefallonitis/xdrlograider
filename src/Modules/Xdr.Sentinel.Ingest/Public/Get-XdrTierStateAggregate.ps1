function Get-XdrTierStateAggregate {
    <#
    .SYNOPSIS
        Queries the XdrTierState Storage table and returns per-(Portal, Tier)
        aggregates suitable for emission to XdrConnectorHealth_CL.

    .DESCRIPTION
        Called by Connector-Heartbeat (5-min timer). For each (Portal, Tier)
        partition seen in the last $SinceUtc, computes:
          StreamsAttempted  = count(rows)
          StreamsSucceeded  = count(rows where Success=$true)
          RowsIngested      = sum(RowsIngested)
          LatestTimestampUtc = max(TimestampUtc)
          ErrorsSnippet     = first-3 distinct error messages joined with ';'

        Returns a [pscustomobject[]] one element per (Portal, Tier).

        These rows feed Write-Heartbeat to populate the XdrConnectorHealth_CL
        table; the Sentinel data-connector card's connectivityCriteria
        (`StreamsSucceeded > 0`) flips to Connected as soon as any tier
        returns at least one successful stream.

    .PARAMETER StorageAccountName
        FA's Storage account.

    .PARAMETER TableName
        Default: 'XdrTierState'.

    .PARAMETER SinceUtc
        Only consider rows newer than this timestamp. Default: 24h ago.

    .OUTPUTS
        [pscustomobject[]] with fields: Portal, Tier, StreamsAttempted,
        StreamsSucceeded, RowsIngested, LatestTimestampUtc, ErrorsSnippet.

    .EXAMPLE
        $aggregate = Get-XdrTierStateAggregate -StorageAccountName $env:STORAGE_ACCOUNT_NAME
        foreach ($row in $aggregate) {
            Write-Heartbeat -Tier $row.Tier -Portal $row.Portal `
                -StreamsAttempted $row.StreamsAttempted `
                -StreamsSucceeded $row.StreamsSucceeded `
                -RowsIngested    $row.RowsIngested `
                -FunctionName    'Connector-Heartbeat' `
                -FunctionType    'Simple' `
                ...
        }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)] [string] $StorageAccountName,
        [string] $TableName = 'XdrTierState',
        [datetime] $SinceUtc = ([DateTime]::UtcNow.AddHours(-24))
    )

    # Query all rows; filter client-side by TimestampUtc > $SinceUtc.
    # Storage Table OData $filter for datetime is fragile; client-side is simpler
    # and the table cardinality is bounded (max ~59 streams × 5 tiers × 4 portals = 1180 rows).
    $rows = @(Invoke-XdrStorageTableEntity `
        -StorageAccountName $StorageAccountName `
        -TableName          $TableName `
        -Operation          'Query')

    $sinceCutoff = $SinceUtc.ToString('o')
    $fresh = @($rows | Where-Object { $_.TimestampUtc -gt $sinceCutoff })

    # Group by Portal + Tier; emit aggregate row per group.
    $groups = $fresh | Group-Object -Property { "$($_.Portal)|$($_.Tier)" }
    $out = @()
    foreach ($g in $groups) {
        $first = $g.Group[0]
        $errors = @($g.Group | Where-Object { -not $_.Success } | ForEach-Object { $_.ErrorText } | Where-Object { $_ } | Select-Object -Unique -First 3)
        $latest = ($g.Group | ForEach-Object { [DateTime]::Parse($_.TimestampUtc) } | Measure-Object -Maximum).Maximum
        $out += [pscustomobject]@{
            Portal             = $first.Portal
            Tier               = $first.Tier
            StreamsAttempted   = $g.Group.Count
            StreamsSucceeded   = @($g.Group | Where-Object { $_.Success }).Count
            RowsIngested       = ($g.Group | ForEach-Object { [int]$_.RowsIngested } | Measure-Object -Sum).Sum
            LatestTimestampUtc = $latest.ToString('o')
            ErrorsSnippet      = ($errors -join '; ')
        }
    }
    return $out
}
