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
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $StorageAccountName,
        [string] $TableName = 'XdrTierState',
        [datetime] $SinceUtc = ([DateTime]::UtcNow.AddHours(-24)),

        # BySubArea path (default): returns hashtable keyed by RowKey for rows
        # under PartitionKey='Defender'. Each value is the full row entity
        # (Tier/CircuitState/StreamsAttempted/etc.) — exactly what
        # ConnectorHeartbeat needs to compose populated Notes JSON (Rule 12).
        [string] $PartitionKey = 'Defender',

        # ByTier: legacy pilot path — returns array grouped by Portal|Tier.
        [switch] $ByTier
    )

    if (-not $ByTier) {
        # Phase 1 per-sub-area path.
        $rows = @(Invoke-XdrStorageTableEntity `
            -StorageAccountName $StorageAccountName `
            -TableName          $TableName `
            -Operation          'Query' `
            -Filter             "PartitionKey eq '$PartitionKey'")
        $result = @{}
        foreach ($r in $rows) {
            if ($r -is [System.Collections.IDictionary]) {
                $rk = $r['RowKey']
            } else {
                $rk = $r.PSObject.Properties['RowKey']?.Value
            }
            if (-not $rk) { continue }
            $result[$rk] = $r
        }
        return $result
    }

    # Query all rows EXCEPT the dispatcher's __schedule__ control rows.
    # The Xdr-Refresh dispatcher upserts rows with RowKey='__schedule__' that
    # carry NextRunUtc + cadence metadata but NO TimestampUtc/Portal/Tier/Success
    # columns. Including them would (a) trigger StrictMode property-access
    # crashes on missing columns and (b) inflate StreamsAttempted with non-poll
    # rows. Server-side filter is cheap (one OData clause) and removes both
    # risks at the source.
    #
    # Schema-side filter rationale:
    #   per-stream poll rows: PartitionKey='<Portal>|<Tier>', RowKey='<StreamName>'
    #   schedule rows:        PartitionKey='<Portal>|<Tier>', RowKey='__schedule__'
    # The (RowKey ne '__schedule__') predicate is exact-match against a literal
    # so Storage Tables OData scans linearly but it's bounded (~6-20 schedule rows).
    $rows = @(Invoke-XdrStorageTableEntity `
        -StorageAccountName $StorageAccountName `
        -TableName          $TableName `
        -Operation          'Query' `
        -Filter             "RowKey ne '__schedule__'")

    # Client-side TimestampUtc filter — defensive null-guard required because:
    #  1. StrictMode v3 in Azure Functions PowerShell runtime throws on missing
    #     property access ($_.TimestampUtc when the row lacks the column).
    #  2. Legacy rows from earlier deploys may not have TimestampUtc.
    #  3. Storage Table query result is [pscustomobject] — PSObject.Properties.Name
    #     check is the strict-safe pattern.
    $sinceCutoff = $SinceUtc.ToString('o')
    # Section R++++++ orphan filter (2026-05-07T19:15Z): skip rows lacking the
    # Section R++.A truth-signal cols (Reason, HttpStatus). Pre-R++.A rows are
    # legacy schema — they cannot be meaningfully aggregated for connector-card
    # classification (would surface as "no reason" to operators). When manifest
    # streams change tier (e.g. MDE_DeviceTimeline_CL Inventory → ActionCenter)
    # OR get retired (deprecated streams stop polling), the original PK row
    # is never overwritten + becomes orphan. Filter these out so operators see
    # only current-tier-mapped streams in XdrConnectorHealth_CL.
    $fresh = @($rows | Where-Object {
        ($_.PSObject.Properties.Name -contains 'TimestampUtc') -and
        ($_.TimestampUtc -gt $sinceCutoff) -and
        ($_.PSObject.Properties.Name -contains 'Reason')   # post-R++.A schema only
    })

    # Group by Portal + Tier; emit aggregate row per group.
    # Defensive null-guards on every property — same StrictMode rationale.
    $groups = $fresh | Group-Object -Property { "$($_.Portal)|$($_.Tier)" }
    $out = @()
    foreach ($g in $groups) {
        $first = $g.Group[0]
        $errors = @(
            $g.Group |
                Where-Object { ($_.PSObject.Properties.Name -contains 'Success') -and (-not $_.Success) } |
                ForEach-Object { if ($_.PSObject.Properties.Name -contains 'ErrorText') { $_.ErrorText } } |
                Where-Object { $_ } |
                Select-Object -Unique -First 3
        )
        # [DateTime]::Parse may throw on malformed values — wrap each parse defensively.
        $parsed = @()
        foreach ($r in $g.Group) {
            try { $parsed += [DateTime]::Parse($r.TimestampUtc) } catch { }
        }
        $latest = if ($parsed.Count) { ($parsed | Measure-Object -Maximum).Maximum } else { [DateTime]::UtcNow }

        $succeededCount = @(
            $g.Group | Where-Object {
                ($_.PSObject.Properties.Name -contains 'Success') -and $_.Success
            }
        ).Count

        $rowsTotal = (
            $g.Group | ForEach-Object {
                if ($_.PSObject.Properties.Name -contains 'RowsIngested') { [int]$_.RowsIngested } else { 0 }
            } | Measure-Object -Sum
        ).Sum

        $out += [pscustomobject]@{
            Portal             = $first.Portal
            Tier               = $first.Tier
            StreamsAttempted   = $g.Group.Count
            StreamsSucceeded   = $succeededCount
            RowsIngested       = $rowsTotal
            LatestTimestampUtc = $latest.ToString('o')
            ErrorsSnippet      = ($errors -join '; ')
        }
    }
    return $out
}
