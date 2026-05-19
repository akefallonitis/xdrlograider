# Xdr.Ingest.psm1 — Sentinel Logs Ingestion API sender
#
# Public:
#   Send-ToDce        — gzip + MI bearer + chunk split + 429 retry + DLQ on terminal 4xx
#   Write-Heartbeat   — emit 1 row to Defender_Health_CL (Sentinel card freshness)
#   Split-IngestBatch — pure: splits row array into chunks ≤ 900 KB JSON each
#   Get-MiBearerToken — MI bearer for https://monitor.azure.com (cached ~50 min)
#
# Locked constraints (per Logs Ingestion API service-limits doc):
#   - Max 1 MB per request body (compressed AND uncompressed); split at 900 KB safe ceiling
#   - Max 64 KB per field value; oversized fields are truncated by DCR ingest layer
#   - 429 returned with Retry-After when over 2 GB/min/DCR or 12 000 req/min/DCR
#   - No documented 413; over-limit returns 400

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:BearerCache = $null   # @{ Token; ExpiresUtc }
$script:SafeMaxBodyBytes = 900KB   # 90 % of 1 MB hard cap to leave gzip + framing headroom

# -----------------------------------------------------------------------------
# Get-MiBearerToken — MI token for monitor.azure.com (Logs Ingestion API audience)
# -----------------------------------------------------------------------------
function Get-MiBearerToken {
    [CmdletBinding()][OutputType([string])]
    param([switch]$Force, [int]$RefreshBeforeMinutes = 5)

    if (-not $Force -and $script:BearerCache) {
        $cached = $script:BearerCache
        if ($cached.ExpiresUtc -gt (Get-Date).ToUniversalTime().AddMinutes($RefreshBeforeMinutes)) {
            return $cached.Token
        }
    }

    Import-Module Az.Accounts -ErrorAction Stop
    $token = Get-AzAccessToken -ResourceUrl 'https://monitor.azure.com' -ErrorAction Stop
    # Az.Accounts >= 5.x returns Token as SecureString by default; older returns string.
    $plain = if ($token.Token -is [System.Security.SecureString]) {
        [System.Net.NetworkCredential]::new('', $token.Token).Password
    } else { [string]$token.Token }

    $script:BearerCache = [pscustomobject]@{
        Token      = $plain
        ExpiresUtc = $token.ExpiresOn.UtcDateTime
    }
    $plain
}

# -----------------------------------------------------------------------------
# Split-IngestBatch — pure helper: split rows into chunks under 900 KB JSON each
# -----------------------------------------------------------------------------
function Split-IngestBatch {
    [CmdletBinding()][OutputType([Object[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
        [int]$MaxBytes = $script:SafeMaxBodyBytes
    )
    if ($Rows.Count -eq 0) { return ,@() }

    $chunks = [System.Collections.Generic.List[object[]]]::new()
    $current = [System.Collections.Generic.List[object]]::new()
    $currentBytes = 2    # "[]" framing
    foreach ($row in $Rows) {
        $json = $row | ConvertTo-Json -Depth 100 -Compress
        $rowBytes = [System.Text.Encoding]::UTF8.GetByteCount($json) + 1   # +1 for comma
        if (($currentBytes + $rowBytes) -gt $MaxBytes -and $current.Count -gt 0) {
            $chunks.Add($current.ToArray())
            $current = [System.Collections.Generic.List[object]]::new()
            $currentBytes = 2
        }
        $current.Add($row)
        $currentBytes += $rowBytes
    }
    if ($current.Count -gt 0) { $chunks.Add($current.ToArray()) }
    ,$chunks.ToArray()
}

# -----------------------------------------------------------------------------
# Send-ToDce — POST one or more chunks to DCE Logs Ingestion API
# -----------------------------------------------------------------------------
function Send-ToDce {
    [CmdletBinding()][OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$DceEndpoint,         # e.g. https://dce-xdr-westeurope.westeurope-1.ingest.monitor.azure.com
        [Parameter(Mandatory)][string]$DcrImmutableId,
        [Parameter(Mandatory)][string]$StreamName,          # e.g. Custom-Defender_TenantContext_CL
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
        [int]$MaxRetries = 3,
        [scriptblock]$DlqHandler                            # invoked with (Rows, StatusCode, Body) on terminal 4xx
    )
    if ($Rows.Count -eq 0) {
        return [pscustomobject]@{ Sent = 0; Chunks = 0; Failed = 0; Dlq = 0 }
    }

    $token = Get-MiBearerToken
    $uri   = "$($DceEndpoint.TrimEnd('/'))/dataCollectionRules/$DcrImmutableId/streams/$StreamName`?api-version=2023-01-01"
    $chunks = Split-IngestBatch -Rows $Rows
    $sent = 0; $failed = 0; $dlqCount = 0

    foreach ($chunk in $chunks) {
        $bodyJson = $chunk | ConvertTo-Json -Depth 100 -Compress
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($bodyJson)

        $ms = [System.IO.MemoryStream]::new()
        $gz = [System.IO.Compression.GZipStream]::new($ms, [System.IO.Compression.CompressionLevel]::Optimal)
        $gz.Write($bodyBytes, 0, $bodyBytes.Length); $gz.Dispose()
        $gzBytes = $ms.ToArray(); $ms.Dispose()

        $headers = @{
            'Authorization'    = "Bearer $token"
            'Content-Type'     = 'application/json'
            'Content-Encoding' = 'gzip'
        }

        $attempt = 0
        $delivered = $false
        do {
            $attempt++
            $resp = $null
            try {
                $resp = Invoke-WebRequest -Uri $uri -Method POST -Headers $headers -Body $gzBytes `
                    -SkipHttpErrorCheck -UseBasicParsing -ErrorAction Stop
            } catch {
                $resp = [pscustomobject]@{
                    StatusCode = -1
                    Headers    = $null
                    Content    = $_.Exception.Message
                }
            }
            if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300) {
                $sent += $chunk.Count; $delivered = $true; break
            }
            if ($resp.StatusCode -eq 429 -and $attempt -le $MaxRetries) {
                $delay = 5
                if ($resp.Headers -and $resp.Headers['Retry-After']) {
                    $ra = [string]($resp.Headers['Retry-After'])
                    if ($ra -match '^\d+$') { $delay = [math]::Min(60, [int]$ra) }
                }
                Start-Sleep -Seconds $delay
                continue
            }
            # Terminal 4xx → DLQ; do not retry
            if ($resp.StatusCode -ge 400 -and $resp.StatusCode -lt 500) {
                if ($DlqHandler) { & $DlqHandler -Rows $chunk -StatusCode $resp.StatusCode -Body $resp.Content }
                $dlqCount += $chunk.Count
                $failed   += $chunk.Count
                break
            }
            # 5xx → backoff and retry
            if ($attempt -le $MaxRetries) {
                Start-Sleep -Seconds ([math]::Min(60, [math]::Pow(2, $attempt)))
                continue
            }
            $failed += $chunk.Count
            break
        } while ($true)
    }

    [pscustomobject]@{
        Sent   = $sent
        Failed = $failed
        Dlq    = $dlqCount
        Chunks = $chunks.Count
    }
}

# -----------------------------------------------------------------------------
# Write-Heartbeat — single liveness row · Reinforcement-B/C columns (P-5)
# -----------------------------------------------------------------------------
function Write-Heartbeat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DceEndpoint,
        [Parameter(Mandatory)][string]$DcrImmutableId,
        [string]$StreamName       = 'Custom-XdrConnectorHealth_CL',
        [ValidateSet('OK','AuthFatal','Error','Degraded','Capability')]
        [string]$Status           = 'OK',
        [string]$Portal           = 'Defender',
        [string]$Note             = '',
        [string]$ConnectorVersion = '0.1.0',
        [int]$SentLastCycle       = 0,
        [int]$FailedLastCycle     = 0,
        [bool]$CircuitOpen        = $false,
        [int]$ReauthCount         = 0,                  # Reinforcement-B telemetry · in-cycle reauth count
        [int]$SkippedThisCycle    = 0,                  # Reinforcement-C · endpoints filtered by RequiresProducts
        [hashtable]$Capabilities,                       # ProductSnapshot · only for Status='Capability' rows
        [string[]]$OpenCircuits   = @()                 # Π11.4g · sub-areas with Open circuit at cycle end · operator visibility without grepping App Insights
    )
    $row = [pscustomobject]@{
        TimeGenerated    = (Get-Date).ToUniversalTime().ToString('o')
        Status           = $Status
        Portal           = $Portal
        Note             = $Note
        ConnectorVersion = $ConnectorVersion
        SourceSystem     = 'xdrlograider'
        Endpoint         = if ($Status -eq 'Capability') { 'capability-discovery' } else { 'heartbeat' }
        SuccessKind      = if ($Status -in 'OK','Capability') { 'live' } else { 'error' }
        SentLastCycle    = $SentLastCycle
        FailedLastCycle  = $FailedLastCycle
        CircuitOpen      = $CircuitOpen
        ReauthCount      = $ReauthCount                  # Reinforcement-B · Get-XdrPortalConfig refit
        SkippedThisCycle = $SkippedThisCycle             # Reinforcement-C · RequiresProducts filter count
        Capabilities     = if ($Capabilities) { $Capabilities } else { @{} }
        OpenCircuits     = if ($OpenCircuits) { @($OpenCircuits) } else { @() }   # Π11.4g
    }
    Send-ToDce -DceEndpoint $DceEndpoint -DcrImmutableId $DcrImmutableId `
        -StreamName $StreamName -Rows @($row)
}

# -----------------------------------------------------------------------------
# Invoke-XdrStorageTableEntity — Storage Table REST CRUD wrapper (P-4)
#
# Cherry-picked from xdrlograider-v3 Xdr.Sentinel.Ingest. MI bearer for
# https://storage.azure.com · backs XdrTenantCapabilities (Reinforcement-C
# durable cache) + XdrCheckpoint / XdrIngestDlq / XdrTierState (v0.2.0+).
#
# Five verbs: INSERT / UPDATE / GET / QUERY / DELETE.
# -----------------------------------------------------------------------------
function Invoke-XdrStorageTableEntity {
    [CmdletBinding()][OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$StorageAccount,
        [Parameter(Mandatory)][string]$Table,
        [Parameter(Mandatory)][ValidateSet('INSERT','UPDATE','UPSERT','GET','QUERY','DELETE')][string]$Verb,
        [string]$PartitionKey,
        [string]$RowKey,
        [hashtable]$Entity,
        [string]$Filter,
        [string]$BearerToken
    )
    if (-not $BearerToken) {
        try {
            $tok = Get-AzAccessToken -ResourceUrl 'https://storage.azure.com/' -ErrorAction Stop
            $BearerToken = if ($tok.Token -is [System.Security.SecureString]) {
                [System.Net.NetworkCredential]::new('', $tok.Token).Password
            } else { [string]$tok.Token }
        } catch {
            throw "Invoke-XdrStorageTableEntity: MI bearer acquisition failed: $($_.Exception.Message)"
        }
    }
    $base = "https://$StorageAccount.table.core.windows.net"
    $headers = @{
        Authorization  = "Bearer $BearerToken"
        'x-ms-version' = '2020-12-06'
        'x-ms-date'    = [datetime]::UtcNow.ToString('R')
        Accept         = 'application/json;odata=nometadata'
        'Content-Type' = 'application/json'
        'If-Match'     = '*'
    }
    $getStatus = {
        param($Err)
        if ($Err.Exception.Response -and $Err.Exception.Response.StatusCode) {
            return [int]$Err.Exception.Response.StatusCode
        }
        return 0
    }
    switch ($Verb) {
        'INSERT' {
            if (-not $PartitionKey -or -not $RowKey -or -not $Entity) { throw 'INSERT requires -PartitionKey -RowKey -Entity' }
            $payload = @{ PartitionKey = $PartitionKey; RowKey = $RowKey }
            foreach ($k in $Entity.Keys) { $payload[$k] = $Entity[$k] }
            try {
                $resp = Invoke-RestMethod -Uri "$base/$Table" -Method POST -Headers $headers `
                    -Body ($payload | ConvertTo-Json -Compress -Depth 8) -ErrorAction Stop
                return [pscustomobject]@{ StatusCode = 201; Entity = $resp; Error = $null }
            } catch { return [pscustomobject]@{ StatusCode = (& $getStatus $_); Entity = $null; Error = $_.Exception.Message } }
        }
        'UPDATE' {
            if (-not $PartitionKey -or -not $RowKey -or -not $Entity) { throw 'UPDATE requires -PartitionKey -RowKey -Entity' }
            $payload = @{ PartitionKey = $PartitionKey; RowKey = $RowKey }
            foreach ($k in $Entity.Keys) { $payload[$k] = $Entity[$k] }
            $uri = "$base/$Table(PartitionKey='$([uri]::EscapeDataString($PartitionKey))',RowKey='$([uri]::EscapeDataString($RowKey))')"
            try {
                $null = Invoke-RestMethod -Uri $uri -Method PUT -Headers $headers `
                    -Body ($payload | ConvertTo-Json -Compress -Depth 8) -ErrorAction Stop
                return [pscustomobject]@{ StatusCode = 204; Entity = $payload; Error = $null }
            } catch { return [pscustomobject]@{ StatusCode = (& $getStatus $_); Entity = $null; Error = $_.Exception.Message } }
        }
        'UPSERT' {
            # Π11 ITER2 · Azure Table REST PUT-with-If-Match:* is insert-or-replace by spec.
            # Alias to UPDATE handler · 3 prior run.ps1 callers (L564/L592/L689 circuit-breaker
            # write-backs) were using UPSERT against ValidateSet that didn't list it · would
            # ParameterBindingValidationException at runtime. Audit-found latent bug.
            if (-not $PartitionKey -or -not $RowKey -or -not $Entity) { throw 'UPSERT requires -PartitionKey -RowKey -Entity' }
            $payload = @{ PartitionKey = $PartitionKey; RowKey = $RowKey }
            foreach ($k in $Entity.Keys) { $payload[$k] = $Entity[$k] }
            $uri = "$base/$Table(PartitionKey='$([uri]::EscapeDataString($PartitionKey))',RowKey='$([uri]::EscapeDataString($RowKey))')"
            try {
                $null = Invoke-RestMethod -Uri $uri -Method PUT -Headers $headers `
                    -Body ($payload | ConvertTo-Json -Compress -Depth 8) -ErrorAction Stop
                return [pscustomobject]@{ StatusCode = 204; Entity = $payload; Error = $null }
            } catch { return [pscustomobject]@{ StatusCode = (& $getStatus $_); Entity = $null; Error = $_.Exception.Message } }
        }
        'GET' {
            if (-not $PartitionKey -or -not $RowKey) { throw 'GET requires -PartitionKey -RowKey' }
            $uri = "$base/$Table(PartitionKey='$([uri]::EscapeDataString($PartitionKey))',RowKey='$([uri]::EscapeDataString($RowKey))')"
            try {
                $resp = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers -ErrorAction Stop
                return [pscustomobject]@{ StatusCode = 200; Entity = $resp; Error = $null }
            } catch { return [pscustomobject]@{ StatusCode = (& $getStatus $_); Entity = $null; Error = $_.Exception.Message } }
        }
        'QUERY' {
            $uri = "$base/$Table()"
            if ($Filter) { $uri = "${uri}?`$filter=$([uri]::EscapeDataString($Filter))" }
            try {
                $resp = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers -ErrorAction Stop
                $entities = if ($resp.PSObject.Properties['value']) { @($resp.value) } else { @($resp) }
                return [pscustomobject]@{ StatusCode = 200; Entities = $entities; Error = $null }
            } catch { return [pscustomobject]@{ StatusCode = (& $getStatus $_); Entities = @(); Error = $_.Exception.Message } }
        }
        'DELETE' {
            if (-not $PartitionKey -or -not $RowKey) { throw 'DELETE requires -PartitionKey -RowKey' }
            $uri = "$base/$Table(PartitionKey='$([uri]::EscapeDataString($PartitionKey))',RowKey='$([uri]::EscapeDataString($RowKey))')"
            try {
                $null = Invoke-RestMethod -Uri $uri -Method DELETE -Headers $headers -ErrorAction Stop
                return [pscustomobject]@{ StatusCode = 204; Entity = $null; Error = $null }
            } catch { return [pscustomobject]@{ StatusCode = (& $getStatus $_); Entity = $null; Error = $_.Exception.Message } }
        }
    }
}

Export-ModuleMember -Function Send-ToDce, Write-Heartbeat, Split-IngestBatch, Get-MiBearerToken, Invoke-XdrStorageTableEntity
