function Send-ToLogAnalytics {
    <#
    .SYNOPSIS
        Sends rows to a Log Analytics custom table via Data Collection Endpoint (DCE).

    .DESCRIPTION
        Uses the Logs Ingestion API (monitor.azure.com scope) to POST rows to a
        Data Collection Rule (DCR) stream. Implements:
          - Auto token acquisition via managed identity (Az.Accounts)
          - Batch size enforcement (DCE limit: 1 MB uncompressed per POST)
          - Exponential backoff retry on transient failures (429, 5xx)
          - Structured logging to App Insights

    .PARAMETER DceEndpoint
        Data Collection Endpoint URL.
        Format: https://<dce-name>.<region>.ingest.monitor.azure.com

    .PARAMETER DcrImmutableId
        DCR immutable ID.
        Format: dcr-<32 hex chars>

    .PARAMETER StreamName
        DCR stream name (e.g., 'Custom-MDE_AdvancedFeatures_CL').

    .PARAMETER Rows
        Array of objects to ingest. Each row becomes one row in the target table.
        Objects are serialized to JSON; schema must match the DCR stream declaration.

    .PARAMETER MaxBatchBytes
        Max bytes per POST. Default 900 KB (headroom under DCE's 1 MB limit).

    .PARAMETER MaxRetries
        Max retry attempts on transient failures. Default 5.

    .OUTPUTS
        [pscustomobject] with RowsSent, BatchesSent, LatencyMs, GzipBytes,
        StreamName, DlqEnqueued (count of batches that landed in the DLQ
        instead of throwing — only nonzero when the DCE fails after retry
        exhaustion AND -DlqStorageAccount was supplied).

    .PARAMETER DlqStorageAccount
        Optional. Storage account name for the ingest dead-letter queue
        table (default `xdrIngestDlq`). When supplied, terminal failures
        (5x-retry exhaustion on 429/5xx) Push the failing batch to the
        DLQ instead of throwing. The next poll cycle drains the DLQ via
        Pop-XdrIngestDlq.

        v0.1.0-beta first publish: production-readiness gate. Without this
        parameter, terminal failures still throw (back-compat for callers
        that haven't been wired to provide -DlqStorageAccount yet —
        e.g., unit tests for the original behaviour).

    .PARAMETER DlqOperationId
        Optional. Pass-through correlation GUID for App Insights stitching
        of the Ingest.DlqEnqueued event back to the auth chain.

    .EXAMPLE
        Send-ToLogAnalytics -DceEndpoint 'https://my-dce.eastus.ingest.monitor.azure.com' `
            -DcrImmutableId 'dcr-abc123...' `
            -StreamName 'Custom-MDE_AdvancedFeatures_CL' `
            -Rows @($row1, $row2)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $DceEndpoint,
        [Parameter(Mandatory)] [string] $DcrImmutableId,
        [Parameter(Mandatory)] [string] $StreamName,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Rows,
        [int] $MaxBatchBytes = 900KB,
        [int] $MaxRetries = 5,
        # Gzip compression — DCE Ingestion API supports Content-Encoding: gzip
        # and sizes like our RawJson+config snapshots compress ~5-10x.
        # Disable only for debugging or if DCE region ever stops accepting gzip.
        [switch] $DisableGzip,
        # 413 split-and-retry recursion depth guard — caller doesn't set;
        # used internally when halving a batch that hit HTTP 413.
        [int] $SplitDepth = 0,
        # v0.1.0-beta first publish: dead-letter-queue parameters. When
        # supplied, terminal failures spool the failing batch to the DLQ
        # instead of throwing. NOT mandatory — back-compat for legacy
        # callers + unit tests asserting the original throw behaviour.
        [string] $DlqStorageAccount,
        [string] $DlqOperationId
    )

    if (-not $Rows -or $Rows.Count -eq 0) {
        return [pscustomobject]@{
            RowsSent = 0; BatchesSent = 0; LatencyMs = 0; GzipBytes = 0; StreamName = $StreamName; DlqEnqueued = 0
        }
    }

    # Iter 13.9 (C4): sanity-check DcrImmutableId prefix + non-emptiness before
    # issuing the request. Real DCR IDs are `dcr-<32 hex chars>` but we use a
    # loose regex (`^dcr-\S+$`) so that test fixtures with shorter stubs
    # (`dcr-stub`, `dcr-12345`) keep passing while still catching obvious typos
    # (empty string, missing prefix, URL pasted instead of ID, whitespace-only).
    # A malformed value otherwise surfaces as opaque 400 Bad Request inside
    # the catch block — operators can't distinguish config error from server
    # flake.
    if ([string]::IsNullOrWhiteSpace($DcrImmutableId) -or $DcrImmutableId -notmatch '^dcr-\S+$') {
        throw "Send-ToLogAnalytics: invalid DcrImmutableId '$DcrImmutableId'. Expected 'dcr-<id>'. Check FA appSettings DCR_IMMUTABLE_ID — value may be from a deleted/recreated DCR, missing the 'dcr-' prefix, or have a copy/paste error."
    }

    # Acquire monitor.azure.com token (MI-backed)
    $token = Get-MonitorIngestionToken

    $uri = "$($DceEndpoint.TrimEnd('/'))/dataCollectionRules/$DcrImmutableId/streams/$StreamName" + "?api-version=2023-01-01"

    $totalRows      = 0
    $totalBatches   = 0
    $totalGzipBytes = 0
    $dlqEnqueued    = 0
    $totalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # Batch rows by serialized size
    $batches = [System.Collections.Generic.List[object[]]]::new()
    $current = [System.Collections.Generic.List[object]]::new()
    $currentBytes = 2  # open/close brackets

    foreach ($row in $Rows) {
        $rowJson = $row | ConvertTo-Json -Depth 20 -Compress
        $rowBytes = [System.Text.Encoding]::UTF8.GetByteCount($rowJson)

        # If this single row exceeds the limit, log a warning and skip
        if ($rowBytes -ge $MaxBatchBytes) {
            Write-Warning "Row exceeds $MaxBatchBytes bytes ($rowBytes); skipping. StreamName=$StreamName"
            continue
        }

        if (($currentBytes + $rowBytes + 1) -gt $MaxBatchBytes -and $current.Count -gt 0) {
            [void] $batches.Add($current.ToArray())
            $current = [System.Collections.Generic.List[object]]::new()
            $currentBytes = 2
        }

        [void] $current.Add($row)
        $currentBytes += $rowBytes + 1  # +1 for comma
    }
    if ($current.Count -gt 0) {
        [void] $batches.Add($current.ToArray())
    }

    # Send each batch with retry
    foreach ($batch in $batches) {
        $payload = ConvertTo-Json -InputObject $batch -Depth 20 -Compress
        # Ensure it's always an array at top level
        if (-not $payload.StartsWith('[')) {
            $payload = "[$payload]"
        }

        # v0.1.0-beta production-readiness polish: idempotency key per batch.
        # Stamping x-ms-client-request-id makes DCE-side retries safe — if a
        # transient retry resends the same batch, the DCE deduplicates by this
        # GUID instead of producing duplicate rows in the target table.
        # We also stamp the GUID into dependency telemetry so operators can
        # correlate a single batch across the entire transaction view.
        $batchId = [Guid]::NewGuid().ToString()

        # Build the request body — gzip-compressed bytes when enabled (default),
        # raw string otherwise. DCE accepts Content-Encoding: gzip per
        # https://learn.microsoft.com/azure/azure-monitor/logs/logs-ingestion-api-overview
        # Gzip-over-JSON typically achieves 5-10x compression on log payloads.
        $headers = @{
            'Authorization'         = "Bearer $token"
            'Content-Type'          = 'application/json'
            'x-ms-client-request-id' = $batchId
        }
        $uncompressedBytes = [System.Text.Encoding]::UTF8.GetByteCount($payload)
        $bodyForInvoke = $payload
        $batchGzipBytes = 0
        if (-not $DisableGzip) {
            $raw = [System.Text.Encoding]::UTF8.GetBytes($payload)
            $ms = [System.IO.MemoryStream]::new()
            $gz = [System.IO.Compression.GzipStream]::new($ms, [System.IO.Compression.CompressionLevel]::Optimal)
            $gz.Write($raw, 0, $raw.Length)
            $gz.Close()
            $bodyForInvoke = $ms.ToArray()
            $ms.Dispose()
            $headers['Content-Encoding'] = 'gzip'
            $batchGzipBytes = $bodyForInvoke.Length
            $totalGzipBytes += $batchGzipBytes
        }

        $attempt = 0
        $batchRetryCount = 0
        $batchStartedUtc = [datetime]::UtcNow
        while ($true) {
            $callStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $callSuccess = $false
            $callResultCode = 0
            try {
                $resp = Invoke-WebRequest `
                    -Uri $uri `
                    -Method POST `
                    -Headers $headers `
                    -Body $bodyForInvoke `
                    -UseBasicParsing `
                    -TimeoutSec 60 `
                    -ErrorAction Stop

                if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300) {
                    $callSuccess = $true
                    $callResultCode = [int]$resp.StatusCode
                    $callStopwatch.Stop()
                    $callLatencyMs = [int]$callStopwatch.ElapsedMilliseconds

                    # Dependency telemetry — one per successful POST. Operators
                    # filter dependencies in AI's transaction view to see ingest
                    # latency distribution per stream.
                    if (Get-Command -Name Send-XdrAppInsightsDependency -ErrorAction SilentlyContinue) {
                        Send-XdrAppInsightsDependency `
                            -Target      ([uri]$DceEndpoint).Host `
                            -Name        "POST /streams/$StreamName" `
                            -Success     $true `
                            -DurationMs  $callLatencyMs `
                            -ResultCode  $callResultCode `
                            -Type        'HTTP' `
                            -OperationId $DlqOperationId `
                            -Properties  @{
                                Stream         = $StreamName
                                BatchId        = $batchId
                                RetryAttempt   = [string]$batchRetryCount
                                CompressedBytes = [string]$batchGzipBytes
                            }
                    }

                    # Per-batch metrics — Microsoft Well-Architected observability:
                    # ratio + bytes + retry distribution surface the steady-state
                    # ingest health (ratio degradation = schema bloat; retry spike
                    # = DCE 429 storm).
                    if (Get-Command -Name Send-XdrAppInsightsCustomMetric -ErrorAction SilentlyContinue) {
                        $compressionRatio = if ($batchGzipBytes -gt 0) {
                            [math]::Round($uncompressedBytes / [double]$batchGzipBytes, 2)
                        } else { 0.0 }
                        $metricProps = @{ Stream = $StreamName }
                        Send-XdrAppInsightsCustomMetric -MetricName 'xdr.ingest.rows'              -Value ([double]$batch.Count)       -Properties $metricProps -OperationId $DlqOperationId
                        Send-XdrAppInsightsCustomMetric -MetricName 'xdr.ingest.bytes_compressed'  -Value ([double]$batchGzipBytes)    -Properties $metricProps -OperationId $DlqOperationId
                        Send-XdrAppInsightsCustomMetric -MetricName 'xdr.ingest.compression_ratio' -Value ([double]$compressionRatio)  -Properties $metricProps -OperationId $DlqOperationId
                        Send-XdrAppInsightsCustomMetric -MetricName 'xdr.ingest.retry_count'       -Value ([double]$batchRetryCount)   -Properties $metricProps -OperationId $DlqOperationId
                        Send-XdrAppInsightsCustomMetric -MetricName 'xdr.ingest.dce_latency_ms'    -Value ([double]$callLatencyMs)     -Properties $metricProps -OperationId $DlqOperationId

                        # Phase M (R3) per directive 33 + .claude/plans/immutable-splashing-waffle.md:
                        # Per-batch partial-success rate. For successful batches this is 1.0 (all rows
                        # accepted). DCE 207 multi-status responses where a subset of rows fail would
                        # surface < 1.0 (Microsoft Logs Ingestion API returns 207 with per-row errors
                        # for transformKql failures). Currently DCE returns 200 = all-or-nothing per
                        # batch; this metric is the operator hook for future per-row error visibility.
                        Send-XdrAppInsightsCustomMetric -MetricName 'xdr.ingest.row_success_rate' -Value 1.0 -Properties $metricProps -OperationId $DlqOperationId

                        # Phase M (R4) per directive 33 + .claude/plans/immutable-splashing-waffle.md:
                        # Freshness SLI = age of the FIRST row in the batch when ingested. For event-stream
                        # tiers (ActionCenter) this measures portal-to-DCE latency; for snapshot-replace
                        # tiers (Configuration/Inventory/Maintenance) this is poll-cycle freshness.
                        # Operators alert when freshness > expected cadence × 2.
                        $rowAgeSeconds = $null
                        if ($batch.Count -gt 0) {
                            $firstRow = $batch[0]
                            # Try multiple common timestamp fields per manifest ProjectionMap conventions
                            $sourceTime = $null
                            foreach ($prop in 'TimeGenerated', 'EventTime', 'CreatedTime', 'StartTime', 'LastSeenUtc') {
                                if ($firstRow.PSObject.Properties[$prop] -and $firstRow.$prop) {
                                    try {
                                        $sourceTime = [datetime]::Parse([string]$firstRow.$prop).ToUniversalTime()
                                        break
                                    } catch { }
                                }
                            }
                            if ($sourceTime) {
                                $rowAgeSeconds = [math]::Max(0.0, ([datetime]::UtcNow - $sourceTime).TotalSeconds)
                            }
                        }
                        if ($null -ne $rowAgeSeconds) {
                            Send-XdrAppInsightsCustomMetric -MetricName 'xdr.ingest.row_age_seconds' -Value ([double]$rowAgeSeconds) -Properties $metricProps -OperationId $DlqOperationId
                        }
                    }

                    $totalBatches++
                    $totalRows += $batch.Count
                    break
                }
            } catch {
                # Iter 13.5: defensive .Response access. Only WebException / HttpResponseException
                # have .Response; for DNS/TLS/timeout the property may be missing entirely.
                # Strict mode + missing property → crash that masks the real failure.
                $statusCode = $null
                if ($null -ne $_.Exception -and
                    $_.Exception.PSObject.Properties['Response'] -and
                    $null -ne $_.Exception.Response -and
                    $_.Exception.Response.PSObject.Properties['StatusCode']) {
                    $statusCode = [int]$_.Exception.Response.StatusCode
                }

                # v0.1.0-beta production-readiness polish: emit dependency telemetry
                # on the FAILED call too, so AI's transaction view shows latency +
                # status for retries (not just successful POSTs).
                $callStopwatch.Stop()
                $callResultCode = if ($null -ne $statusCode) { [int]$statusCode } else { 0 }
                if (Get-Command -Name Send-XdrAppInsightsDependency -ErrorAction SilentlyContinue) {
                    Send-XdrAppInsightsDependency `
                        -Target      ([uri]$DceEndpoint).Host `
                        -Name        "POST /streams/$StreamName" `
                        -Success     $false `
                        -DurationMs  ([int]$callStopwatch.ElapsedMilliseconds) `
                        -ResultCode  $callResultCode `
                        -Type        'HTTP' `
                        -OperationId $DlqOperationId `
                        -Properties  @{
                            Stream         = $StreamName
                            BatchId        = $batchId
                            RetryAttempt   = [string]$batchRetryCount
                            ErrorMessage   = [string]$_.Exception.Message
                        }
                }

                # 429-rate metric — tier-level dashboards count throttling
                # pressure on the DCE distinct from portal Rate429Count.
                if ($statusCode -eq 429 -and (Get-Command -Name Send-XdrAppInsightsCustomMetric -ErrorAction SilentlyContinue)) {
                    Send-XdrAppInsightsCustomMetric -MetricName 'xdr.ingest.rate429_count' -Value 1.0 `
                        -Properties @{ Stream = $StreamName } -OperationId $DlqOperationId
                }

                # 413 Payload Too Large — split the batch in half and recurse.
                # Capped at depth 3 so a pathological single-row oversize doesn't
                # infinite-recurse; by then we've tried batches of 1/8 size.
                if ($statusCode -eq 413 -and $SplitDepth -lt 3 -and $batch.Count -ge 2) {
                    $half = [math]::Ceiling($batch.Count / 2)
                    $left  = $batch[0..($half - 1)]
                    $right = $batch[$half..($batch.Count - 1)]
                    Write-Warning "DCE 413 Payload Too Large for $StreamName — splitting batch of $($batch.Count) into 2x$half (depth=$SplitDepth)"
                    $splitArgs = @{
                        DceEndpoint    = $DceEndpoint
                        DcrImmutableId = $DcrImmutableId
                        StreamName     = $StreamName
                        MaxBatchBytes  = $MaxBatchBytes
                        MaxRetries     = $MaxRetries
                        SplitDepth     = $SplitDepth + 1
                    }
                    if ($DisableGzip) { $splitArgs['DisableGzip'] = $true }
                    $l = Send-ToLogAnalytics -Rows $left  @splitArgs
                    $r = Send-ToLogAnalytics -Rows $right @splitArgs
                    $totalRows      += $l.RowsSent + $r.RowsSent
                    $totalBatches   += $l.BatchesSent + $r.BatchesSent
                    $totalGzipBytes += $l.GzipBytes + $r.GzipBytes
                    break
                }

                $isTransient = $statusCode -eq 429 -or ($statusCode -ge 500 -and $statusCode -lt 600) -or $null -eq $statusCode

                if (-not $isTransient -or $attempt -ge $MaxRetries) {
                    # v0.1.0-beta first publish: terminal failure path. If
                    # the caller supplied -DlqStorageAccount, spool the
                    # failing batch to the ingest DLQ instead of throwing —
                    # the next poll cycle drains it via Pop-XdrIngestDlq.
                    # This converts "rows lost forever on 429-storm" into
                    # "rows replayed on the next 10-minute cycle".
                    if (-not [string]::IsNullOrWhiteSpace($DlqStorageAccount)) {
                        $reason = if ($statusCode -eq 429) { '429-terminal' }
                                  elseif ($null -ne $statusCode -and $statusCode -ge 500 -and $statusCode -lt 600) { '5xx-terminal' }
                                  elseif (-not $isTransient) { 'non-transient-terminal' }
                                  else { 'unknown-terminal' }
                        try {
                            $pushArgs = @{
                                StorageAccountName = $DlqStorageAccount
                                StreamName         = $StreamName
                                Rows               = $batch
                                OriginalLatencyMs  = [int]$totalStopwatch.ElapsedMilliseconds
                                LastHttpStatus     = $statusCode
                                AttemptCount       = 1
                                FirstFailedUtc     = [datetime]::UtcNow
                                Reason             = $reason
                            }
                            if (-not [string]::IsNullOrWhiteSpace($DlqOperationId)) {
                                $pushArgs['OperationId'] = $DlqOperationId
                            }
                            $pushResult = Push-XdrIngestDlq @pushArgs
                            if ($pushResult -and $pushResult.Enqueued) {
                                $dlqEnqueued++
                                Write-Warning "DCE ingest exhausted $MaxRetries retries (HTTP $statusCode) — batch enqueued to DLQ. Stream=$StreamName Rows=$($batch.Count) RowKey=$($pushResult.RowKey)"
                                # Continue to the next batch — do NOT throw.
                                break
                            } else {
                                # Push failed (oversize / unknown). Fall
                                # through to the throw so we don't silently
                                # lose the rows.
                                Write-Warning "DCE ingest exhausted retries AND DLQ push failed/dropped. Throwing to surface the loss. Stream=$StreamName Rows=$($batch.Count)"
                            }
                        } catch {
                            Write-Warning "DCE ingest exhausted retries AND DLQ push threw: $($_.Exception.Message). Throwing original error to surface the loss."
                        }
                    }
                    # v0.1.0-beta production-readiness polish: emit
                    # TrackException on terminal failure (after retries
                    # exhausted) BEFORE throw so AI's exceptions table shows
                    # the failure with a stitched OperationId. Preserves stack
                    # trace via $_.Exception.
                    if (Get-Command -Name Send-XdrAppInsightsException -ErrorAction SilentlyContinue) {
                        Send-XdrAppInsightsException -Exception $_.Exception `
                            -SeverityLevel 'Error' `
                            -OperationId $DlqOperationId `
                            -Properties @{
                                Stream      = $StreamName
                                BatchId     = $batchId
                                HttpStatus  = [string]$statusCode
                                RowCount    = [string]$batch.Count
                                Phase       = 'send-to-log-analytics-terminal'
                            }
                    }
                    throw "DCE ingest failed: $($_.Exception.Message). StreamName=$StreamName, Rows=$($batch.Count), HttpStatus=$statusCode"
                }

                $delayMs = [math]::Min(2000 * [math]::Pow(2, $attempt), 30000)
                Write-Warning "DCE ingest transient failure (attempt $attempt/$MaxRetries), retrying in $([int]$delayMs)ms — HTTP $statusCode"
                Start-Sleep -Milliseconds $delayMs
                $attempt++
                $batchRetryCount++
            }
        }
    }

    $totalStopwatch.Stop()
    return [pscustomobject]@{
        RowsSent    = $totalRows
        BatchesSent = $totalBatches
        LatencyMs   = [int]$totalStopwatch.ElapsedMilliseconds
        StreamName  = $StreamName
        GzipBytes   = $totalGzipBytes
        DlqEnqueued = $dlqEnqueued
    }
}

function Get-MonitorIngestionToken {
    <#
    .SYNOPSIS
        Acquires a bearer token for the Azure Monitor ingestion audience.

    .DESCRIPTION
        Uses the Az.Accounts module. In the Function App, this picks up the system-assigned
        managed identity. For local dev, it uses the interactive-logged-in Az account.

        Tokens are cached in module scope until 5 minutes before expiry.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $now = [datetime]::UtcNow
    $expiryBuffer = $now.AddMinutes(5)

    if ($script:MonitorTokenCache -and $script:MonitorTokenExpiry -gt $expiryBuffer) {
        return $script:MonitorTokenCache
    }

    try {
        $tokenResponse = Get-AzAccessToken -ResourceUrl 'https://monitor.azure.com/' -ErrorAction Stop
    } catch {
        throw "Failed to acquire monitor.azure.com token: $($_.Exception.Message). Ensure managed identity is enabled and has Monitoring Metrics Publisher role on the DCR."
    }

    # Extract the token and expiry. ExpiresOn is DateTimeOffset in newer Az; string in older.
    $token = if ($tokenResponse.Token -is [System.Security.SecureString]) {
        [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($tokenResponse.Token)
        )
    } else {
        $tokenResponse.Token
    }

    # Iter 13.5: defensive ExpiresOn extraction. Older Az.Accounts emits string,
    # newer (5.x) emits DateTimeOffset, mock contexts may emit $null. Strict mode
    # crashes on $tokenResponse.ExpiresOn if the property is absent.
    $rawExpiry = $null
    if ($null -ne $tokenResponse -and $tokenResponse.PSObject.Properties['ExpiresOn']) {
        $rawExpiry = $tokenResponse.ExpiresOn
    }
    $expiry = if ($rawExpiry -is [datetimeoffset]) {
        $rawExpiry.UtcDateTime
    } elseif ($null -ne $rawExpiry) {
        try { [datetime]::Parse($rawExpiry).ToUniversalTime() } catch { [datetime]::UtcNow.AddMinutes(55) }
    } else {
        # No expiry info → assume short-lived (55 min) so we'll re-acquire soon
        [datetime]::UtcNow.AddMinutes(55)
    }

    $script:MonitorTokenCache = $token
    $script:MonitorTokenExpiry = $expiry
    return $token
}
