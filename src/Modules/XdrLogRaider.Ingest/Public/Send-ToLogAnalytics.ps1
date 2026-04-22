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
        [pscustomobject] with RowsSent, BatchesSent, LatencyMs.

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
        [int] $MaxRetries = 5
    )

    if (-not $Rows -or $Rows.Count -eq 0) {
        return [pscustomobject]@{
            RowsSent = 0; BatchesSent = 0; LatencyMs = 0
        }
    }

    # Acquire monitor.azure.com token (MI-backed)
    $token = Get-MonitorIngestionToken

    $uri = "$($DceEndpoint.TrimEnd('/'))/dataCollectionRules/$DcrImmutableId/streams/$StreamName" + "?api-version=2023-01-01"

    $totalRows     = 0
    $totalBatches  = 0
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

        $attempt = 0
        while ($true) {
            try {
                $resp = Invoke-WebRequest `
                    -Uri $uri `
                    -Method POST `
                    -Headers @{
                        'Authorization' = "Bearer $token"
                        'Content-Type'  = 'application/json'
                    } `
                    -Body $payload `
                    -UseBasicParsing `
                    -TimeoutSec 60 `
                    -ErrorAction Stop

                if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300) {
                    $totalBatches++
                    $totalRows += $batch.Count
                    break
                }
            } catch {
                $statusCode = $null
                if ($_.Exception.Response) {
                    $statusCode = [int]$_.Exception.Response.StatusCode
                }

                $isTransient = $statusCode -eq 429 -or ($statusCode -ge 500 -and $statusCode -lt 600) -or $null -eq $statusCode

                if (-not $isTransient -or $attempt -ge $MaxRetries) {
                    throw "DCE ingest failed: $($_.Exception.Message). StreamName=$StreamName, Rows=$($batch.Count), HttpStatus=$statusCode"
                }

                $delayMs = [math]::Min(2000 * [math]::Pow(2, $attempt), 30000)
                Write-Warning "DCE ingest transient failure (attempt $attempt/$MaxRetries), retrying in $([int]$delayMs)ms — HTTP $statusCode"
                Start-Sleep -Milliseconds $delayMs
                $attempt++
            }
        }
    }

    $totalStopwatch.Stop()
    return [pscustomobject]@{
        RowsSent    = $totalRows
        BatchesSent = $totalBatches
        LatencyMs   = [int]$totalStopwatch.ElapsedMilliseconds
        StreamName  = $StreamName
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

    $expiry = if ($tokenResponse.ExpiresOn -is [datetimeoffset]) {
        $tokenResponse.ExpiresOn.UtcDateTime
    } else {
        [datetime]::Parse($tokenResponse.ExpiresOn).ToUniversalTime()
    }

    $script:MonitorTokenCache = $token
    $script:MonitorTokenExpiry = $expiry
    return $token
}
