function Invoke-XdrIngestDlqQuery {
    <#
    .SYNOPSIS
        INTERNAL: HTTP-level wrapper around the Azure Tables OData query.
        Extracted so unit tests can Mock it.

    .DESCRIPTION
        Returns @{ StatusCode = <int>; Body = <string> } so the caller
        (Pop-XdrIngestDlq) can decide how to interpret 404 / 200 / 5xx
        without owning the HttpClient lifetime.

    .NOTES
        Pure helper — never called outside Pop-XdrIngestDlq. Not exported.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $StorageAccountName,
        [Parameter(Mandatory)] [string] $TableName,
        [Parameter(Mandatory)] [string] $StreamName,
        [Parameter(Mandatory)] [int]    $MaxBatches
    )

    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue

    $tokenObj = Get-AzAccessToken -ResourceUrl 'https://storage.azure.com/'
    $token = if ($tokenObj.Token -is [System.Security.SecureString]) {
        [System.Net.NetworkCredential]::new('', $tokenObj.Token).Password
    } else {
        [string]$tokenObj.Token
    }

    if ($null -eq $script:XdrTableHttpClient) {
        $script:XdrTableHttpClient = [System.Net.Http.HttpClient]::new()
    }
    $client = $script:XdrTableHttpClient

    $escapedStream = $StreamName -replace "'", "''"
    $filter = "PartitionKey eq '$escapedStream'"
    $encodedFilter = [System.Uri]::EscapeDataString($filter)
    $uri = "https://$StorageAccountName.table.core.windows.net/$TableName" + "()?`$filter=$encodedFilter&`$top=$MaxBatches"

    $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $uri)
    $null = $req.Headers.TryAddWithoutValidation('Authorization', "Bearer $token")
    $null = $req.Headers.TryAddWithoutValidation('x-ms-version', '2020-12-06')
    $null = $req.Headers.TryAddWithoutValidation('x-ms-date', [datetime]::UtcNow.ToString('R'))
    $null = $req.Headers.TryAddWithoutValidation('Accept', 'application/json;odata=nometadata')

    $resp = $client.SendAsync($req).GetAwaiter().GetResult()
    try {
        $bodyText = ''
        try { $bodyText = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult() } catch {}
        return @{
            StatusCode    = [int]$resp.StatusCode
            ReasonPhrase  = [string]$resp.ReasonPhrase
            Body          = [string]$bodyText
        }
    } finally {
        $resp.Dispose()
        $req.Dispose()
    }
}


function Pop-XdrIngestDlq {
    <#
    .SYNOPSIS
        Reads pending DLQ batches for a given stream + returns deserialised
        rows. Caller drives the retry; deletion is the caller's responsibility
        (via Remove-XdrIngestDlqEntry on success).

    .DESCRIPTION
        v0.1.0-beta first publish: paired with Push-XdrIngestDlq. Drains the
        ingest dead-letter queue at the start of each tier poll cycle.
        Failed batches that previously would have been LOST when
        Send-ToLogAnalytics threw on retry-exhaust are now persisted in
        Storage Table `xdrIngestDlq` (PartitionKey = stream name).

        Algorithm:
          1. Query Azure Tables: $filter=PartitionKey eq '<stream>'
             $top=<MaxBatches> (oldest-first by RowKey, which is ISO
             timestamp + GUID — naturally sorts by enqueue time).
          2. For each row, base64-decode + gunzip + ConvertFrom-Json the
             RowsJson property → typed-column object array.
          3. Return [pscustomobject[]] with: PartitionKey, RowKey,
             AttemptCount, Reason, FirstFailedUtc, Rows. Caller iterates,
             retries Send-ToLogAnalytics, then either:
               - Success → Remove-XdrIngestDlqEntry (PartitionKey, RowKey)
                          + emit Ingest.DlqDrained
               - Failure → Push-XdrIngestDlq with AttemptCount+1
                          + emit Ingest.DlqStuck if AttemptCount > 10

        On 404 / no rows / table missing, returns @() — first-run safe
        (the table is auto-created by Push-XdrIngestDlq's Upsert call;
        operators don't need to provision it explicitly).

    .PARAMETER StorageAccountName
        Storage account hosting the DLQ table.

    .PARAMETER TableName
        DLQ table name. Default 'xdrIngestDlq' (matches deploy/main.bicep
        + the XDR_INGEST_DLQ_TABLE_NAME env var the FA sets).

    .PARAMETER StreamName
        DCR stream name (PartitionKey filter). Required — the DLQ is
        partitioned per-stream so each tier-poll cycle drains only its
        own streams.

    .PARAMETER MaxBatches
        Cap on rows returned per call. Default 5 (each batch is up to
        ~100 KB compressed so 5 caps the worker memory at a few MB
        + bounds the time spent draining vs. polling fresh data).

    .PARAMETER OperationId
        Correlation GUID for App Insights stitching. Pass-through from
        the auth chain when available.

    .OUTPUTS
        Array of [pscustomobject] entries:
          PartitionKey       [string]   stream name
          RowKey             [string]   ISO timestamp + GUID
          Rows               [object[]] deserialised rows (caller resends)
          AttemptCount       [int]      1 on first push; +1 per failed pop
          Reason             [string]   '429-terminal' / '5xx-terminal' / etc.
          FirstFailedUtc     [string]   ISO timestamp
          OriginalLatencyMs  [int]      from the original failed send
          LastHttpStatus     [int]      from the original failed send (-1 if null)
          BatchSizeBytes     [int]      uncompressed bytes (for SLA dashboards)

    .EXAMPLE
        # In Invoke-MDETierPoll, before polling fresh:
        $pending = Pop-XdrIngestDlq -StorageAccountName $sa -StreamName "Custom-$stream" -MaxBatches 5
        foreach ($entry in $pending) {
            try {
                Send-ToLogAnalytics -DceEndpoint $dce -DcrImmutableId $dcr -StreamName $entry.PartitionKey -Rows $entry.Rows
                Remove-XdrIngestDlqEntry -StorageAccountName $sa -PartitionKey $entry.PartitionKey -RowKey $entry.RowKey
            } catch {
                Push-XdrIngestDlq ... -AttemptCount ($entry.AttemptCount + 1)
            }
        }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $StorageAccountName,

        [string] $TableName = $(if ([Environment]::GetEnvironmentVariable('XDR_INGEST_DLQ_TABLE_NAME')) { [Environment]::GetEnvironmentVariable('XDR_INGEST_DLQ_TABLE_NAME') } else { 'xdrIngestDlq' }),

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $StreamName,

        [int] $MaxBatches = 5,

        [string] $OperationId
    )

    # Delegate the HTTP query to the testable helper (Invoke-XdrIngestDlqQuery).
    # That helper wraps the SendAsync().GetAwaiter().GetResult() chain so unit
    # tests can Mock it without intercepting the .NET HttpClient lifetime.
    try {
        $queryResult = Invoke-XdrIngestDlqQuery `
            -StorageAccountName $StorageAccountName `
            -TableName          $TableName `
            -StreamName         $StreamName `
            -MaxBatches         $MaxBatches
    } catch {
        # v0.1.0-beta production-readiness polish: emit TrackException so
        # an Azure Tables outage during DLQ drain shows up in AI before the
        # exception bubbles. Caller may catch + log warning; we ensure the
        # signal lands in App Insights regardless.
        if (Get-Command -Name Send-XdrAppInsightsException -ErrorAction SilentlyContinue) {
            Send-XdrAppInsightsException -Exception $_.Exception `
                -SeverityLevel 'Warning' `
                -OperationId $OperationId `
                -Properties @{
                    Stream = $StreamName
                    Phase  = 'dlq-pop-query'
                }
        }
        throw
    }

    # 404 → table doesn't exist yet (first run, no DLQ activity ever).
    # Return empty array; the table is created lazily on first Push.
    if ($queryResult.StatusCode -eq 404) {
        if (Get-Command -Name Send-XdrAppInsightsCustomMetric -ErrorAction SilentlyContinue) {
            Send-XdrAppInsightsCustomMetric -MetricName 'xdr.dlq.pop_count' -Value 1.0 `
                -Properties @{ Stream = $StreamName; Outcome = 'table-not-found' } -OperationId $OperationId
            Send-XdrAppInsightsCustomMetric -MetricName 'xdr.dlq.depth' -Value 0.0 `
                -Properties @{ Stream = $StreamName } -OperationId $OperationId
        }
        return @()
    }

    if ($queryResult.StatusCode -lt 200 -or $queryResult.StatusCode -ge 300) {
        throw ("Pop-XdrIngestDlq: Azure Tables query failed: HTTP {0} ({1}) -- {2}" -f `
            [int]$queryResult.StatusCode, [string]$queryResult.ReasonPhrase, [string]$queryResult.Body)
    }

    $bodyText = [string]$queryResult.Body
    if ([string]::IsNullOrWhiteSpace($bodyText)) {
        if (Get-Command -Name Send-XdrAppInsightsCustomMetric -ErrorAction SilentlyContinue) {
            Send-XdrAppInsightsCustomMetric -MetricName 'xdr.dlq.pop_count' -Value 1.0 `
                -Properties @{ Stream = $StreamName; Outcome = 'empty' } -OperationId $OperationId
            Send-XdrAppInsightsCustomMetric -MetricName 'xdr.dlq.depth' -Value 0.0 `
                -Properties @{ Stream = $StreamName } -OperationId $OperationId
        }
        return @()
    }

    $parsed = $bodyText | ConvertFrom-Json
    if (-not $parsed -or -not $parsed.PSObject.Properties['value']) {
        if (Get-Command -Name Send-XdrAppInsightsCustomMetric -ErrorAction SilentlyContinue) {
            Send-XdrAppInsightsCustomMetric -MetricName 'xdr.dlq.pop_count' -Value 1.0 `
                -Properties @{ Stream = $StreamName; Outcome = 'no-value' } -OperationId $OperationId
            Send-XdrAppInsightsCustomMetric -MetricName 'xdr.dlq.depth' -Value 0.0 `
                -Properties @{ Stream = $StreamName } -OperationId $OperationId
        }
        return @()
    }
    $rawEntries = @($parsed.value)
    if ($rawEntries.Count -eq 0) {
        if (Get-Command -Name Send-XdrAppInsightsCustomMetric -ErrorAction SilentlyContinue) {
            Send-XdrAppInsightsCustomMetric -MetricName 'xdr.dlq.pop_count' -Value 1.0 `
                -Properties @{ Stream = $StreamName; Outcome = 'empty' } -OperationId $OperationId
            Send-XdrAppInsightsCustomMetric -MetricName 'xdr.dlq.depth' -Value 0.0 `
                -Properties @{ Stream = $StreamName } -OperationId $OperationId
        }
        return @()
    }

    $output = New-Object System.Collections.Generic.List[pscustomobject]
    $expiredCount = 0
    $now = [datetime]::UtcNow
    foreach ($e in $rawEntries) {
        # Phase L.1 (B5) — TTL consumer per Section 0.A of plan.
        # Push side stamps ExpiresUtc + TtlDays; Pop side skips + DELETES
        # expired entries so the DLQ doesn't grow unbounded for genuinely
        # unrecoverable batches (e.g., portal API permanent shape change).
        # Per Section 0.A in plan: this completes the half-implementation
        # documented in the prior CHANGELOG.
        if ($e.PSObject.Properties['ExpiresUtc'] -and $e.ExpiresUtc) {
            $expiresUtc = $null
            try { $expiresUtc = [datetime]::Parse([string]$e.ExpiresUtc).ToUniversalTime() } catch {}
            if ($expiresUtc -and $expiresUtc -lt $now) {
                # Expired — emit Ingest.DlqExpired exception + delete + skip
                if (Get-Command -Name Send-XdrAppInsightsException -ErrorAction SilentlyContinue) {
                    $ttlDaysStr = if ($e.PSObject.Properties['TtlDays']) { [string]$e.TtlDays } else { 'unknown' }
                    $msg = ("DLQ entry expired: PartitionKey='{0}' RowKey='{1}' ExpiresUtc={2} (was {3} days TTL); auto-deleting." -f `
                        $e.PartitionKey, $e.RowKey, $e.ExpiresUtc, $ttlDaysStr)
                    Send-XdrAppInsightsException -Exception ([System.Exception]::new($msg)) `
                        -SeverityLevel 'Warning' `
                        -OperationId $OperationId `
                        -Properties @{
                            ErrorClass     = 'Ingest.DlqExpired'
                            Stream         = $StreamName
                            RowKey         = [string]$e.RowKey
                            ExpiresUtc     = [string]$e.ExpiresUtc
                            FirstFailedUtc = if ($e.PSObject.Properties['FirstFailedUtc']) { [string]$e.FirstFailedUtc } else { '' }
                            Reason         = if ($e.PSObject.Properties['Reason']) { [string]$e.Reason } else { '' }
                            AttemptCount   = if ($e.PSObject.Properties['AttemptCount']) { [string]$e.AttemptCount } else { '0' }
                            Phase          = 'dlq-pop-ttl-expired'
                        }
                }
                # Delete via Remove-XdrIngestDlqEntry (paired helper below)
                try {
                    Remove-XdrIngestDlqEntry -StorageAccountName $StorageAccountName -TableName $TableName `
                        -PartitionKey ([string]$e.PartitionKey) -RowKey ([string]$e.RowKey) | Out-Null
                    $expiredCount++
                } catch {
                    Write-Warning ("Pop-XdrIngestDlq: failed to delete expired DLQ entry: {0}" -f $_.Exception.Message)
                }
                continue
            }
        }

        $rowsJson = $null
        if ($e.PSObject.Properties['RowsJson'] -and $e.RowsJson) {
            # Decode: base64 → gunzip → UTF-8 string → JSON array
            try {
                $gzipBytes = [Convert]::FromBase64String([string]$e.RowsJson)
                $msIn = [System.IO.MemoryStream]::new($gzipBytes)
                $gz   = [System.IO.Compression.GzipStream]::new($msIn, [System.IO.Compression.CompressionMode]::Decompress)
                $reader = [System.IO.StreamReader]::new($gz, [System.Text.Encoding]::UTF8)
                $jsonText = $reader.ReadToEnd()
                $reader.Close(); $gz.Close(); $msIn.Close()
                if (-not [string]::IsNullOrWhiteSpace($jsonText)) {
                    $rowsJson = @($jsonText | ConvertFrom-Json)
                }
            } catch {
                Write-Warning "Pop-XdrIngestDlq: failed to decode DLQ row PartitionKey='$($e.PartitionKey)' RowKey='$($e.RowKey)' — $($_.Exception.Message). Skipping (will be re-popped next cycle)."
                if (Get-Command -Name Send-XdrAppInsightsException -ErrorAction SilentlyContinue) {
                    Send-XdrAppInsightsException -Exception $_.Exception `
                        -SeverityLevel 'Warning' `
                        -OperationId $OperationId `
                        -Properties @{
                            Stream    = $StreamName
                            RowKey    = [string]$e.RowKey
                            Phase     = 'dlq-pop-decode'
                        }
                }
                continue
            }
        }
        if (-not $rowsJson -or $rowsJson.Count -eq 0) {
            # Empty payload — orphan row. Skip; an operator can clean
            # the table manually if it builds up (we don't auto-delete
            # corrupt rows since that masks bugs).
            continue
        }

        $output.Add([pscustomobject]@{
            PartitionKey      = [string]$e.PartitionKey
            RowKey            = [string]$e.RowKey
            Rows              = $rowsJson
            AttemptCount      = if ($e.PSObject.Properties['AttemptCount']) { [int]$e.AttemptCount } else { 1 }
            Reason            = if ($e.PSObject.Properties['Reason']) { [string]$e.Reason } else { 'unknown-terminal' }
            FirstFailedUtc    = if ($e.PSObject.Properties['FirstFailedUtc']) { [string]$e.FirstFailedUtc } else { '' }
            OriginalLatencyMs = if ($e.PSObject.Properties['OriginalLatencyMs']) { [int]$e.OriginalLatencyMs } else { 0 }
            LastHttpStatus    = if ($e.PSObject.Properties['LastHttpStatus']) { [int]$e.LastHttpStatus } else { -1 }
            BatchSizeBytes    = if ($e.PSObject.Properties['BatchSizeBytes']) { [int]$e.BatchSizeBytes } else { 0 }
        })
    }
    # v0.1.0-beta production-readiness polish: pop-count + depth gauge so
    # operators can chart DLQ drain pressure (pops/min) + remaining depth
    # per stream in AI's customMetrics.
    if (Get-Command -Name Send-XdrAppInsightsCustomMetric -ErrorAction SilentlyContinue) {
        Send-XdrAppInsightsCustomMetric -MetricName 'xdr.dlq.pop_count' -Value 1.0 `
            -Properties @{ Stream = $StreamName; Outcome = 'drained' } -OperationId $OperationId
        Send-XdrAppInsightsCustomMetric -MetricName 'xdr.dlq.depth' -Value ([double]$output.Count) `
            -Properties @{ Stream = $StreamName } -OperationId $OperationId
        # Phase L.1 TTL consumer metric: track how many entries auto-evicted
        # per Pop call. Operators alert on sustained nonzero (= portal API
        # permanent failure pattern; manual intervention needed).
        if ($expiredCount -gt 0) {
            Send-XdrAppInsightsCustomMetric -MetricName 'xdr.dlq.ttl_evicted_count' -Value ([double]$expiredCount) `
                -Properties @{ Stream = $StreamName } -OperationId $OperationId
        }
    }
    return ,$output.ToArray()
}


function Remove-XdrIngestDlqEntry {
    <#
    .SYNOPSIS
        Deletes a successfully-replayed DLQ entry from Storage Table.

    .DESCRIPTION
        Caller invokes this AFTER Send-ToLogAnalytics succeeds for a
        Pop-XdrIngestDlq entry. Wraps Invoke-XdrStorageTableEntity with the
        DLQ-table-specific defaults so callers don't have to thread the
        table name through every call site.

        On success emits Ingest.DlqDrained custom event for App Insights.

    .PARAMETER StorageAccountName
        Storage account hosting the DLQ table.

    .PARAMETER TableName
        DLQ table name. Default 'xdrIngestDlq' (matches deploy + env var).

    .PARAMETER PartitionKey
        Stream name (matches the DLQ entry's PartitionKey).

    .PARAMETER RowKey
        ISO timestamp + GUID (matches the DLQ entry's RowKey).

    .PARAMETER OperationId
        Correlation GUID for App Insights stitching.

    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $StorageAccountName,

        [string] $TableName = $(if ([Environment]::GetEnvironmentVariable('XDR_INGEST_DLQ_TABLE_NAME')) { [Environment]::GetEnvironmentVariable('XDR_INGEST_DLQ_TABLE_NAME') } else { 'xdrIngestDlq' }),

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $PartitionKey,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $RowKey,

        [string] $OperationId
    )

    Invoke-XdrStorageTableEntity `
        -StorageAccountName $StorageAccountName `
        -TableName          $TableName `
        -PartitionKey       $PartitionKey `
        -RowKey             $RowKey `
        -Operation          Delete | Out-Null

    if (Get-Command -Name Send-XdrAppInsightsCustomEvent -ErrorAction SilentlyContinue) {
        Send-XdrAppInsightsCustomEvent -EventName 'Ingest.DlqDrained' -OperationId $OperationId -Properties @{
            Stream  = $PartitionKey
            RowKey  = $RowKey
        }
    }
}
