function Push-XdrIngestDlq {
    <#
    .SYNOPSIS
        Persists a failed batch of rows to the ingest dead-letter queue (DLQ).

    .DESCRIPTION
        v0.1.0-beta first publish: production-readiness gate for terminal
        DCE ingest failures. Pre-fix, Send-ToLogAnalytics threw on 5x-retry
        exhaustion → timer trigger caught the exception → rows lost forever
        (no replay path). Post-fix, terminal failures spool to a Storage
        Table (`xdrIngestDlq` in the same checkpoint storage account); the
        next poll cycle drains the DLQ via Pop-XdrIngestDlq + retries +
        deletes on success.

        DLQ row shape (Azure Tables):

          PartitionKey  = stream name (e.g. 'Custom-MDE_ActionCenter_CL')
          RowKey        = ISO-8601 UTC timestamp + GUID
                          (e.g. '2026-04-30T14:23:01.4563210Z_a3f2e1b9...')
                          — sortable + unique, even for sub-millisecond
                          enqueues from the same worker.
          RowsJson      = gzip-then-base64-encoded JSON-array payload
                          (the exact rows that failed; preserves typed
                          columns for the DCR replay).
          OriginalLatencyMs   = how long the original send-with-retries
                                burned before giving up.
          LastHttpStatus      = HTTP code from the final retry attempt
                                (429 / 5xx most common; null if DNS/TLS).
          AttemptCount        = 1 on first enqueue. Incremented in-place
                                each time Pop-XdrIngestDlq tries + fails.
                                Operators monitor AttemptCount > 10 as
                                "stuck DLQ" (see Ingest.DlqStuck event).
          FirstFailedUtc      = ISO timestamp of the first failure that
                                produced this DLQ row. Helps operators
                                bound replay-lag SLAs.
          Reason              = short string ('429-terminal' / '5xx-terminal'
                                / 'unknown-terminal') for KQL grouping.
          BatchSizeBytes      = uncompressed JSON byte count. >100 KB rows
                                are rejected (Azure Tables hard limit on
                                an entity is ~1 MB total; we cap each
                                property at 100 KB so the row never trips
                                the platform limit even with overhead).

    .PARAMETER StorageAccountName
        Storage account hosting the DLQ table. Same account as the
        connectorCheckpoints table — keeps SAMI grants minimal.

    .PARAMETER TableName
        DLQ table name. Default 'xdrIngestDlq' (matches deploy/main.bicep
        + the XDR_INGEST_DLQ_TABLE_NAME env var the FA sets).

    .PARAMETER StreamName
        DCR stream name (becomes PartitionKey).

    .PARAMETER Rows
        Array of objects (the original Send-ToLogAnalytics -Rows input).
        Serialised compact JSON, gzipped, base64-encoded for storage.

    .PARAMETER OriginalLatencyMs
        Latency burned by the failed send-with-retries.

    .PARAMETER LastHttpStatus
        HTTP code from the last retry attempt (or $null for DNS/TLS).

    .PARAMETER AttemptCount
        Defaults to 1 (first enqueue). Pop-XdrIngestDlq increments via a
        re-Push when the drain attempt fails too.

    .PARAMETER FirstFailedUtc
        Defaults to now. Preserve across re-pushes.

    .PARAMETER Reason
        Short string for KQL grouping ('429-terminal' / '5xx-terminal' /
        'unknown-terminal').

    .PARAMETER OperationId
        Correlation GUID for App Insights stitching. Pass-through from
        the auth chain when available.

    .OUTPUTS
        [pscustomobject] with PartitionKey, RowKey, BatchSizeBytes,
        Enqueued (bool — false when row was dropped because >100 KB).

    .EXAMPLE
        # Inside Send-ToLogAnalytics terminal-failure branch:
        Push-XdrIngestDlq -StorageAccountName 'sa' -StreamName 'Custom-MDE_ActionCenter_CL' `
            -Rows $batch -OriginalLatencyMs 18234 -LastHttpStatus 429 `
            -Reason '429-terminal' -OperationId $opId

    .NOTES
        Storage Tables hard limit per entity: 1 MB total. We cap RowsJson at
        100 KB (after gzip+base64) so the rest of the metadata + Azure
        overhead never trips the limit. Rows >100 KB after compression are
        DROPPED with a Warning + Ingest.DlqDropped event — operator must
        reduce row size or split upstream. The drop case should be rare
        (gzip-over-JSON typically achieves 5-10x) but is logged loudly so it
        never silently loses data.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $StorageAccountName,

        [string] $TableName = $(if ([Environment]::GetEnvironmentVariable('XDR_INGEST_DLQ_TABLE_NAME')) { [Environment]::GetEnvironmentVariable('XDR_INGEST_DLQ_TABLE_NAME') } else { 'xdrIngestDlq' }),

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $StreamName,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Rows,

        [int] $OriginalLatencyMs = 0,

        [Nullable[int]] $LastHttpStatus = $null,

        [int] $AttemptCount = 1,

        [datetime] $FirstFailedUtc = ([datetime]::UtcNow),

        [string] $Reason = 'unknown-terminal',

        [string] $OperationId
    )

    if (-not $Rows -or $Rows.Count -eq 0) {
        # Nothing to enqueue — no-op (caller misuse, but be defensive)
        return [pscustomobject]@{
            PartitionKey   = $StreamName
            RowKey         = ''
            BatchSizeBytes = 0
            Enqueued       = $false
        }
    }

    # Serialise rows to compact JSON, gzip, base64-encode.
    $rawJson = ConvertTo-Json -InputObject $Rows -Depth 20 -Compress
    if (-not $rawJson.StartsWith('[')) {
        $rawJson = "[$rawJson]"
    }
    $rawBytes = [System.Text.Encoding]::UTF8.GetBytes($rawJson)
    $batchSizeBytes = $rawBytes.Length

    # Gzip → base64. Storage Tables string properties are UTF-16; binary
    # blobs need either base64 or a `binary`-typed property. Easiest is
    # base64 string.
    $ms = [System.IO.MemoryStream]::new()
    $gz = [System.IO.Compression.GzipStream]::new($ms, [System.IO.Compression.CompressionLevel]::Optimal)
    $gz.Write($rawBytes, 0, $rawBytes.Length)
    $gz.Close()
    $gzipBytes = $ms.ToArray()
    $ms.Dispose()
    $rowsJsonB64 = [Convert]::ToBase64String($gzipBytes)

    # Hard cap: Azure Tables entity property string max = 64 KiB
    # (32k chars in UTF-16). We cap at 100,000 chars (~64 KiB UTF-8 raw
    # bytes worth of base64) which leaves headroom for metadata. If
    # exceeded, drop with warning + emit metric.
    $maxRowsJsonChars = 100000
    if ($rowsJsonB64.Length -gt $maxRowsJsonChars) {
        $msg = "Push-XdrIngestDlq: gzipped+base64 batch is $($rowsJsonB64.Length) chars (cap $maxRowsJsonChars). Stream='$StreamName' Rows=$($Rows.Count) UncompressedBytes=$batchSizeBytes — DROPPING. Operator must reduce row size or split upstream."
        Write-Warning $msg
        if (Get-Command -Name Send-XdrAppInsightsCustomEvent -ErrorAction SilentlyContinue) {
            Send-XdrAppInsightsCustomEvent -EventName 'Ingest.DlqDropped' -OperationId $OperationId -Properties @{
                Stream             = $StreamName
                RowCount           = $Rows.Count
                UncompressedBytes  = $batchSizeBytes
                CompressedBytes    = $rowsJsonB64.Length
                CapBytes           = $maxRowsJsonChars
                Reason             = $Reason
            }
        }
        return [pscustomobject]@{
            PartitionKey   = $StreamName
            RowKey         = ''
            BatchSizeBytes = $batchSizeBytes
            Enqueued       = $false
        }
    }

    # RowKey: ISO timestamp + GUID. ToString('o') sorts lexically by time
    # so the table is naturally ordered oldest-first when scanned ascending.
    $rowKey = ('{0}_{1}' -f ([datetime]::UtcNow.ToString('o')), [Guid]::NewGuid().ToString('N'))

    $entity = @{
        PartitionKey       = $StreamName
        RowKey             = $rowKey
        RowsJson           = $rowsJsonB64
        OriginalLatencyMs  = [int]$OriginalLatencyMs
        LastHttpStatus     = if ($null -eq $LastHttpStatus) { -1 } else { [int]$LastHttpStatus }
        AttemptCount       = [int]$AttemptCount
        FirstFailedUtc     = $FirstFailedUtc.ToString('o')
        Reason             = $Reason
        BatchSizeBytes     = [int]$batchSizeBytes
        RowCount           = [int]$Rows.Count
    }

    try {
        Invoke-XdrStorageTableEntity `
            -StorageAccountName $StorageAccountName `
            -TableName          $TableName `
            -PartitionKey       $StreamName `
            -RowKey             $rowKey `
            -Operation          Upsert `
            -Entity             $entity | Out-Null
    } catch {
        # v0.1.0-beta production-readiness polish: emit TrackException so an
        # Azure Tables write failure surfaces in AI alongside the customEvents,
        # then re-throw so the caller's catch handles row loss accounting.
        if (Get-Command -Name Send-XdrAppInsightsException -ErrorAction SilentlyContinue) {
            Send-XdrAppInsightsException -Exception $_.Exception `
                -SeverityLevel 'Error' `
                -OperationId $OperationId `
                -Properties @{
                    Stream   = $StreamName
                    Reason   = $Reason
                    Phase    = 'dlq-push-upsert'
                }
        }
        throw
    }

    if (Get-Command -Name Send-XdrAppInsightsCustomEvent -ErrorAction SilentlyContinue) {
        Send-XdrAppInsightsCustomEvent -EventName 'Ingest.DlqEnqueued' -OperationId $OperationId -Properties @{
            Stream             = $StreamName
            RowCount           = $Rows.Count
            UncompressedBytes  = $batchSizeBytes
            CompressedBytes    = $rowsJsonB64.Length
            LastHttpStatus     = if ($null -eq $LastHttpStatus) { 'null' } else { [string]$LastHttpStatus }
            AttemptCount       = [int]$AttemptCount
            Reason             = $Reason
        }
    }

    # v0.1.0-beta production-readiness polish: DLQ push-count gauge so
    # operators can chart DLQ pressure (pushes/min) per stream in AI.
    # The complementary xdr.dlq.pop_count + xdr.dlq.depth metrics are
    # emitted from Pop-XdrIngestDlq.
    if (Get-Command -Name Send-XdrAppInsightsCustomMetric -ErrorAction SilentlyContinue) {
        Send-XdrAppInsightsCustomMetric -MetricName 'xdr.dlq.push_count' -Value 1.0 `
            -Properties @{ Stream = $StreamName; Reason = $Reason } `
            -OperationId $OperationId
    }

    return [pscustomobject]@{
        PartitionKey   = $StreamName
        RowKey         = $rowKey
        BatchSizeBytes = $batchSizeBytes
        Enqueued       = $true
    }
}
