# XdrLogRaider · Xdr.Common.Ingest module
#
# Purpose: DCE/DCR ingest with DLQ on terminal AND transient-exhausted failures.
#
# Invariants:
#   - 5xx after MaxRetries → DLQ (NEVER silent-dropped · no data loss surface).
#   - Network errors → DLQ (no special-cased silent path · same DLQ contract).
#   - Hashtable → JSON string serialized ONCE per ingest path (single-encode discipline:
#     re-encoding a string yields a double-quoted JSON literal · classic foot-gun).
#   - SAMI-only auth via Get-AzAccessToken · no connection strings · no SAS · no storage keys.

Set-StrictMode -Version Latest

$script:DceTokenCache = $null
$script:DceTokenExpiryUtc = [DateTime]::MinValue

function Get-XdrDcrAuthToken {
    <#
    .SYNOPSIS
    Acquire bearer token for DCR ingest scope (monitor.azure.com).
    Cached for ~50min (Azure tokens 60min · refresh 10min before expiry).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([switch] $Force)

    if (-not $Force -and $script:DceTokenCache -and ([DateTime]::UtcNow -lt $script:DceTokenExpiryUtc)) {
        return $script:DceTokenCache
    }

    # Production path: FA-injected managed-identity endpoint (no Az PS dependency · iter#15).
    $msiEndpoint = $env:IDENTITY_ENDPOINT
    $msiHeader   = $env:IDENTITY_HEADER
    if ($msiEndpoint -and $msiHeader) {
        try {
            $url  = "$msiEndpoint" + "?resource=https://monitor.azure.com&api-version=2019-08-01"
            $resp = Invoke-RestMethod -Method GET -Uri $url -Headers @{ 'X-IDENTITY-HEADER' = $msiHeader } -TimeoutSec 30 -ErrorAction Stop
            $script:DceTokenCache     = $resp.access_token
            # App Service MI returns expires_on (epoch sec · STRING); IMDS returns expires_in. Dot-access of an
            # absent prop throws under StrictMode — read via PSObject.Properties indexer + accept either shape.
            $rp = $resp.PSObject.Properties
            $lifeSec = if ($rp['expires_in'] -and $rp['expires_in'].Value) { [int]$rp['expires_in'].Value }
                       elseif ($rp['expires_on'] -and $rp['expires_on'].Value) { [Math]::Max(60, [long]$rp['expires_on'].Value - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) }
                       else { 3600 }
            $script:DceTokenExpiryUtc = [DateTime]::UtcNow.AddSeconds($lifeSec - 600)
            return $script:DceTokenCache
        } catch {
            throw (New-XdrException -Type Ingest -Message "Get-XdrDcrAuthToken (MSI REST) failed: $($_.Exception.Message)" -Properties @{ DcrId = ''; StreamName = ''; RowCount = 0 })
        }
    }

    # Local-dev fallback ONLY (developer must have Az.Accounts installed; it is NOT bundled in the FA zip).
    try {
        $tokenObj = Get-AzAccessToken -ResourceUrl 'https://monitor.azure.com' -ErrorAction Stop
        $script:DceTokenCache = $tokenObj.Token
        $script:DceTokenExpiryUtc = ([DateTime]::UtcNow).AddMinutes(50)  # safety margin
        return $script:DceTokenCache
    } catch {
        throw (New-XdrException -Type Ingest -Message "Get-XdrDcrAuthToken failed: $($_.Exception.Message)" -Properties @{ DcrId = ''; StreamName = ''; RowCount = 0 })
    }
}

# Per-ROW total-byte clamp · a single row whose serialized size exceeds the DCE per-request limit (projected typed cols
# PLUS the 240KB-clamped RawJson can together exceed ~1MB) would 413 at DCE → classified terminal → DLQ → SILENT loss. Truncate
# the LARGEST string column (with a visible marker) until the row fits, preserving the envelope + a breadcrumb. The clamp
# is OBSERVABLE (Ingest.RowClamped event) — never a silent drop. Mutates + returns the row (hashtable is a reference).
function script:Limit-XdrRowBytes {
    param([Parameter(Mandatory)][hashtable] $Row, [int] $MaxBytes = 900KB, [string] $OperationKey = '')
    $clamped = $false
    for ($guard = 0; $guard -lt 8; $guard++) {
        $rb = [System.Text.Encoding]::UTF8.GetByteCount(($Row | ConvertTo-Json -Depth 25 -Compress))
        if ($rb -le $MaxBytes) { break }
        $largest = $null; $largestLen = -1
        foreach ($k in @($Row.Keys)) { $v = $Row[$k]; if ($v -is [string] -and $v.Length -gt $largestLen) { $largest = $k; $largestLen = $v.Length } }
        if (-not $largest -or $largestLen -lt 64) { break }   # nothing trimmable left
        $cut = [Math]::Max(256, [int](($rb - $MaxBytes) * 1.1))
        $keep = [Math]::Max(0, $Row[$largest].Length - $cut)
        $Row[$largest] = $Row[$largest].Substring(0, $keep) + "…[XDRLR-TRUNCATED col=$largest · row>$MaxBytes B]"
        $clamped = $true
    }
    if ($clamped -and (Get-Command Track-XdrEvent -ErrorAction SilentlyContinue)) {
        Track-XdrEvent -Name 'Ingest.RowClamped' -Properties @{ OperationKey = $OperationKey; MaxBytes = $MaxBytes }
    }
    return $Row
}

# SB2 backstop (audit 2026-06-12) · clamp ANY single string column to the LA per-column cap (~256KB) so LA never
# SILENTLY truncates it mid-value (which yields invalid JSON / lost data). RawJson is already parser-clamped
# head-preserving; this catches large PROJECTION columns too (e.g. RelatedEntitiesJson / AdditionalFieldsJson on a
# huge entity graph). Visible marker + observable Ingest.ColumnClamped event — never a silent drop. Mutates + returns.
function script:Limit-XdrColumnBytes {
    param([Parameter(Mandatory)][hashtable] $Row, [int] $MaxBytes = 245760, [string] $OperationKey = '')
    $clamped = [System.Collections.Generic.List[string]]::new()
    foreach ($k in @($Row.Keys)) {
        $v = $Row[$k]
        if ($v -is [string]) {
            $b = [System.Text.Encoding]::UTF8.GetByteCount($v)
            if ($b -gt $MaxBytes) {
                $marker = "…[XDRLR-COL-TRUNCATED col=$k orig=${b}B LAcap=$MaxBytes]"
                $budget = $MaxBytes - [System.Text.Encoding]::UTF8.GetByteCount($marker)
                $s = $v
                while ($s.Length -gt 0 -and [System.Text.Encoding]::UTF8.GetByteCount($s) -gt $budget) {
                    $over = [System.Text.Encoding]::UTF8.GetByteCount($s) - $budget
                    $s = $s.Substring(0, [Math]::Max(0, $s.Length - [Math]::Max(1, [int]($over * 1.1))))
                }
                $Row[$k] = $s + $marker
                $clamped.Add($k)
            }
        }
    }
    if ($clamped.Count -gt 0 -and (Get-Command Track-XdrEvent -ErrorAction SilentlyContinue)) {
        Track-XdrEvent -Name 'Ingest.ColumnClamped' -Properties @{ OperationKey = $OperationKey; Columns = ($clamped -join ','); MaxBytes = $MaxBytes }
    }
    return $Row
}

function Send-ToDce {
    <#
    .SYNOPSIS
    Ingest a row batch to a DCE → DCR stream, SPLIT into <1MB chunks (plan §35.6 B-DCE-BATCH). The DCE request
    limit is ~1MB; a large (cold-start) batch is greedily packed into <900KB chunks, each POSTed via
    Send-XdrDceChunk. RowsAccepted = sum across chunks; Success = ALL chunks 2xx (so the caller advances the
    cursor only when EVERY row landed — no silent partial loss on a big batch). A failed chunk is DLQ'd by
    Send-XdrDceChunk; the remaining chunks still attempt.

    G1 (exactly-once · partial-batch): rows are packed into chunks in SEND ORDER, so the CONTIGUOUS run of rows in
    the LEADING fully-2xx chunks (up to the FIRST failed chunk) is the set that provably landed AND is safe to
    checkpoint past — anything after the first failure was DLQ'd or not-yet-landed and must be re-polled next cycle.
    LandedContiguousRows reports that prefix length so Invoke-XdrEntryPoll can advance the high-water over EXACTLY
    the landed prefix on a partial failure (instead of re-ingesting the landed chunks next cycle = duplicates). On a
    full success LandedContiguousRows == RowsAccepted (all-or-nothing path is byte-identical). It is ADDITIVE —
    Success/RowsAccepted/StatusCode/ErrorClass/ErrorMessage are unchanged.

    Returns @{ Success; RowsAccepted; LandedContiguousRows; StatusCode; ErrorClass; ErrorMessage; DurationMs }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $DceEndpoint,
        [Parameter(Mandatory)] [string] $DcrId,
        [Parameter(Mandatory)] [string] $StreamName,
        [Parameter(Mandatory)] $Rows,
        [int] $MaxRetries = 3,
        [int] $TimeoutSec = 30,
        # E-MAJ5 · the op's REAL Portal_Category (checkpoint partition · DATA from the entry) so a DLQ row partitions
        # the SAME way the checkpoint does. Threaded to Send-XdrDceChunk → Send-XdrDlq. Absent ('') → the legacy
        # stream-name strip is used (back-compat), which MISMATCHES for a spaced category (e.g. 'Cloud Apps').
        [string] $PartitionKey = ''
    )
    $startedUtc = [DateTime]::UtcNow
    $rowList = @($Rows)
    if ($rowList.Count -eq 0) { return @{ Success = $true; RowsAccepted = 0; LandedContiguousRows = 0; StatusCode = 0; ErrorClass = $null; ErrorMessage = 'empty batch · skip'; DurationMs = 0 } }

    # Greedily pack rows into <900KB chunks (margin under the ~1MB DCE request limit). A single row that alone
    # exceeds the limit goes in its own chunk (a row can't be split · RawJson is already 240KB-clamped by B3).
    $maxBytes = 900KB
    $chunks = [System.Collections.Generic.List[object]]::new()
    $cur = [System.Collections.Generic.List[hashtable]]::new()
    $curBytes = 2  # the '[]' wrapper
    foreach ($row in $rowList) {
        $row = Limit-XdrColumnBytes -Row $row -MaxBytes 245760 -OperationKey $StreamName  # SB2 · per-column LA-256KB-safe (no silent column truncation)
        $row = Limit-XdrRowBytes -Row $row -MaxBytes $maxBytes -OperationKey $StreamName   # kill the silent oversized-row 413→DLQ
        $rb = [System.Text.Encoding]::UTF8.GetByteCount(($row | ConvertTo-Json -Depth 25 -Compress)) + 1  # +1 ≈ comma
        if ($cur.Count -gt 0 -and ($curBytes + $rb) -gt $maxBytes) { $chunks.Add($cur.ToArray()); $cur = [System.Collections.Generic.List[hashtable]]::new(); $curBytes = 2 }
        $cur.Add($row); $curBytes += $rb
    }
    if ($cur.Count -gt 0) { $chunks.Add($cur.ToArray()) }

    $agg = @{ Success = $true; RowsAccepted = 0; LandedContiguousRows = 0; StatusCode = 0; ErrorClass = $null; ErrorMessage = $null; DurationMs = 0 }
    # G1 · $prefixIntact tracks the LEADING run of fully-2xx chunks (send order). While it holds, each chunk's row
    # count extends the contiguous-landed prefix; the FIRST failed chunk freezes it (rows after a gap can't be
    # checkpointed past). On a full success the prefix == every row (all-or-nothing semantics unchanged).
    $prefixIntact = $true
    foreach ($chunk in $chunks) {
        $r = Send-XdrDceChunk -DceEndpoint $DceEndpoint -DcrId $DcrId -StreamName $StreamName -Rows $chunk -MaxRetries $MaxRetries -TimeoutSec $TimeoutSec -PartitionKey $PartitionKey
        $agg.RowsAccepted += [int]$r.RowsAccepted
        if ($r.StatusCode) { $agg.StatusCode = $r.StatusCode }
        if ($r.Success) {
            if ($prefixIntact) { $agg.LandedContiguousRows += @($chunk).Count }
        } else {
            $prefixIntact = $false   # freeze the contiguous-landed prefix at the first failure
            $agg.Success = $false; if (-not $agg.ErrorClass) { $agg.ErrorClass = $r.ErrorClass; $agg.ErrorMessage = $r.ErrorMessage }
            # IN2 (audit 2026-06-12) · STOP after the first failed chunk. A trailing chunk that 2xx's would land
            # ABOVE the contiguous-landed prefix (not checkpointed) → re-fetched next cycle → DUPLICATE. The failed
            # chunk is already DLQ'd by Send-XdrDceChunk; the remaining rows are re-polled next cadence (no loss).
            break
        }
    }
    $agg.DurationMs = [int]((([DateTime]::UtcNow) - $startedUtc).TotalMilliseconds)
    if ($chunks.Count -gt 1 -and (Get-Command Track-XdrEvent -ErrorAction SilentlyContinue)) {
        Track-XdrEvent -Name 'DCE.Ingest.Chunked' -Properties @{ DcrId = $DcrId; StreamName = $StreamName; Chunks = $chunks.Count; RowsAccepted = $agg.RowsAccepted; AllSucceeded = $agg.Success }
    }
    return $agg
}

function Send-XdrDceChunk {
    <#
    .SYNOPSIS
    POST a SINGLE <1MB row chunk to DCE → DCR stream. 5xx after MaxRetries routes to DLQ (no silent loss).
    Returns @{ Success; RowsAccepted; StatusCode; ErrorClass; ErrorMessage }.
    On terminal failure (4xx) routes to DLQ via Send-XdrDlq · returns Failed.
    On transient (5xx · 429 · network) retries with backoff · ultimately DLQs after MaxRetries.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $DceEndpoint,
        [Parameter(Mandatory)] [string] $DcrId,
        [Parameter(Mandatory)] [string] $StreamName,
        [Parameter(Mandatory)] $Rows,
        [int] $MaxRetries = 3,
        [int] $TimeoutSec = 30,
        [string] $PartitionKey = ''   # E-MAJ5 · the op's real Portal_Category · threaded to Send-XdrDlq (DLQ partition)
    )

    $startedUtc = [DateTime]::UtcNow
    $rowList = @($Rows)  # comma-operator preserves identity for single-row case
    $rowCount = $rowList.Count

    if ($rowCount -eq 0) {
        return @{ Success = $true; RowsAccepted = 0; StatusCode = 0; ErrorClass = $null; ErrorMessage = 'empty batch · skip' }
    }

    $result = @{
        Success = $false
        RowsAccepted = 0
        StatusCode = 0
        ErrorClass = $null
        ErrorMessage = $null
        DurationMs = 0
    }

    # Serialize once · use the string body everywhere downstream · no double-encode foot-gun.
    $bodyJson = $rowList | ConvertTo-Json -Depth 25 -Compress -AsArray
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($bodyJson)

    # URL: <DceEndpoint>/dataCollectionRules/<DcrImmutableId>/streams/<StreamName>?api-version=2023-01-01
    $url = "$($DceEndpoint.TrimEnd('/'))/dataCollectionRules/$DcrId/streams/$([uri]::EscapeDataString($StreamName))?api-version=2023-01-01"

    $lastException = $null
    $tokenForced = $false   # IN3 · whether we've already forced one MSI-token re-mint this chunk
    $forceToken  = $false
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            $token = Get-XdrDcrAuthToken -Force:$forceToken
            $forceToken = $false
            $headers = @{
                Authorization = "Bearer $token"
                'Content-Type' = 'application/json'
                'Content-Encoding' = ''  # No gzip in v0.1.0 · v0.2.0 backlog
            }
            # TLS-1.2+ pinned code-side (§3) · DCE ingest (operational data + Bearer to monitor.azure.com)
            $response = Invoke-WebRequest -Method Post -Uri $url -Headers $headers -Body $bodyBytes -TimeoutSec $TimeoutSec -ErrorAction Stop -UseBasicParsing -SslProtocol 'Tls12, Tls13'
            $result.Success = $true
            $result.StatusCode = [int]$response.StatusCode
            $result.RowsAccepted = $rowCount

            Track-XdrDependency -Name 'DCE.Ingest' -Type 'HTTP' -Data $url -Target $DceEndpoint -DurationMs ([int]((([DateTime]::UtcNow) - $startedUtc).TotalMilliseconds)) -Success $true -ResultCode $result.StatusCode -Properties @{
                DcrId = $DcrId; StreamName = $StreamName; RowCount = $rowCount
            }
            $result.DurationMs = [int]((([DateTime]::UtcNow) - $startedUtc).TotalMilliseconds)
            return $result

        } catch {
            $lastException = $_.Exception
            $statusCode = 0
            # StrictMode-safe: an exception WITHOUT a .Response (network/DNS/timeout · not an HttpResponseException)
            # would throw PropertyNotFound on dot-access here → mask the error AND skip DLQ → silent loss. Read via
            # the PSObject.Properties indexer ($null when absent) so network failures fall through to transient→DLQ.
            $exResp = $_.Exception.PSObject.Properties['Response']
            if ($exResp -and $exResp.Value) { try { $statusCode = [int]$exResp.Value.StatusCode } catch { $statusCode = 0 } }
            $result.StatusCode = $statusCode

            # Classify · 4xx (except 429) → terminal · others → transient/retry
            $isTerminal = ($statusCode -ge 400 -and $statusCode -lt 500 -and $statusCode -ne 429)
            $isLastAttempt = ($attempt -eq $MaxRetries)

            # IN3 (audit 2026-06-12) · a 401/403 from a STALE cached MSI token (clock skew / rotation mid-50min-window)
            # is recoverable: force ONE re-mint and retry BEFORE classifying terminal→DLQ. Not counted as terminal.
            if (($statusCode -eq 401 -or $statusCode -eq 403) -and -not $tokenForced -and -not $isLastAttempt) {
                $tokenForced = $true; $forceToken = $true
                if (Get-Command Track-XdrEvent -ErrorAction SilentlyContinue) { Track-XdrEvent -Name 'DCE.Ingest.TokenRefresh' -Properties @{ DcrId = $DcrId; StreamName = $StreamName; StatusCode = $statusCode } }
                Start-Sleep -Milliseconds 200
                continue
            }

            if ($isTerminal) {
                # Terminal · DLQ immediately · NO retry
                Send-XdrDlq -DcrId $DcrId -StreamName $StreamName -Rows $rowList -Reason "Terminal HTTP $statusCode" -ErrorBody ($_.Exception.Message) -PartitionKey $PartitionKey
                $result.ErrorClass = 'XdrPortalTerminalException'
                $result.ErrorMessage = "Terminal $statusCode · sent to DLQ"
                break  # do not retry terminal
            } elseif ($isLastAttempt) {
                # Transient · exhausted retries · DLQ (invariant: no silent drop on retry exhaustion)
                Send-XdrDlq -DcrId $DcrId -StreamName $StreamName -Rows $rowList -Reason "Transient $statusCode after $MaxRetries retries" -ErrorBody ($_.Exception.Message) -PartitionKey $PartitionKey
                $result.ErrorClass = 'XdrPortalTransientException'
                $result.ErrorMessage = "Transient $statusCode exhausted retries · sent to DLQ"
            } else {
                # Transient · backoff and retry. HONOR a server Retry-After (429/503 · anti-thundering-herd · portal
                # politeness) when present, else exponential + jitter. StrictMode-safe header read (indexer · try/catch).
                $retryAfterSec = 0
                try {
                    $hdrs = $exResp.Value.PSObject.Properties['Headers']
                    $ra = if ($hdrs -and $hdrs.Value) { $hdrs.Value.RetryAfter } else { $null }
                    if ($ra) {
                        if ($ra.Delta)     { $retryAfterSec = [int]$ra.Delta.TotalSeconds }
                        elseif ($ra.Date)  { $retryAfterSec = [int][Math]::Max(0, ($ra.Date.ToUniversalTime() - [DateTimeOffset]::UtcNow).TotalSeconds) }
                    }
                } catch { $retryAfterSec = 0 }
                $delaySec = if ($retryAfterSec -gt 0) { [Math]::Min(120, $retryAfterSec) } else { [Math]::Min(60, [Math]::Pow(2, $attempt) + (Get-Random -Maximum 5)) }
                Start-Sleep -Seconds $delaySec
                continue
            }
        }
    }

    $result.DurationMs = [int]((([DateTime]::UtcNow) - $startedUtc).TotalMilliseconds)
    Track-XdrDependency -Name 'DCE.Ingest' -Type 'HTTP' -Data $url -Target $DceEndpoint -DurationMs $result.DurationMs -Success $false -ResultCode $result.StatusCode -Properties @{
        DcrId = $DcrId; StreamName = $StreamName; RowCount = $rowCount; ErrorClass = $result.ErrorClass
    }
    if ($lastException) {
        Track-XdrException -Exception $lastException -Properties @{
            DcrId = $DcrId; StreamName = $StreamName; RowCount = $rowCount; StatusCode = $result.StatusCode
        }
    }
    return $result
}

function Send-XdrDlq {
    <#
    .SYNOPSIS
    Persist a failed row batch to XdrIngestDlq Storage Table for operator inspection.
    Invariant: network-fault path (no Response object) ALSO routes here · no silent-loss carve-out.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $DcrId,
        [Parameter(Mandatory)] [string] $StreamName,
        [Parameter(Mandatory)] $Rows,
        [Parameter(Mandatory)] [string] $Reason,
        [string] $ErrorBody = '',
        # E-MAJ5 · the op's REAL Portal_Category (the SAME value the checkpoint partitions by · DATA from the entry,
        # threaded Send-ToDce→Send-XdrDceChunk→here). When supplied it is authoritative.
        [string] $PartitionKey = ''
    )

    try {
        $saName = $env:XDRLR_STORAGE_ACCOUNT
        if (-not $saName) {
            Write-Warning "[DLQ] XDRLR_STORAGE_ACCOUNT missing · cannot persist DLQ entry"
            return $false
        }

        $rowList = @($Rows)
        # E-MAJ5 · PartitionKey = the op's REAL Portal_Category (plan §4.3) so a DLQ row partitions the SAME way the
        # checkpoint does (§18.2 D11 inspects them by Op). Prefer the threaded Portal_Category (DATA from the entry); the
        # prior derivation string-stripped the stream name 'Custom-<Portal>_<TokenizedCategory>_CL', which MISMATCHES for
        # a SPACED category — the stream uses the tokenized 'CloudApps' while the checkpoint partition is 'Cloud Apps', so
        # DLQ and checkpoint landed in DIFFERENT partitions. The strip survives ONLY as the absent-param fallback (back-compat).
        $partitionKey = if (-not [string]::IsNullOrWhiteSpace($PartitionKey)) { $PartitionKey }
                        else { ($StreamName -replace '^Custom-', '' -replace '_CL$', '') }
        if ([string]::IsNullOrWhiteSpace($partitionKey)) { $partitionKey = $StreamName }
        $rowKey = "$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmssfff'))-$([Guid]::NewGuid().ToString('N').Substring(0,8))"

        # Storage Table 64KB limit per property · split if needed
        $rowsJson = $rowList | ConvertTo-Json -Depth 25 -Compress -AsArray
        $rowsB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($rowsJson))

        $props = @{
            DcrId = $DcrId
            StreamName = $StreamName
            RowCount = $rowList.Count
            Reason = $Reason
            ErrorBody = if ($ErrorBody.Length -gt 8000) { $ErrorBody.Substring(0, 8000) } else { $ErrorBody }
            RowsB64 = if ($rowsB64.Length -gt 60000) { $rowsB64.Substring(0, 60000) } else { $rowsB64 }
            QueuedUtc = (Get-Date).ToUniversalTime().ToString('o')
            QueuedBy = 'Xdr.Common.Ingest.Send-XdrDlq'
        }
        # MSI-REST upsert via the Storage module · NOT the Az Storage SDK. The runtime dropped bundled Az
        # (plan §19.2 all-REST/MSI); the SDK cmdlets would CommandNotFound at runtime → the DLQ path itself
        # crashes → silent data loss (inverts F6 "zero silent loss"). XdrIngestDlq is a StateStore table
        # provisioned by ARM (plan §4.3). Set-XdrTableEntity does NOT throw on 412 only; surface any other failure.
        $setResult = Set-XdrTableEntity -TableName 'XdrIngestDlq' -PartitionKey $partitionKey -RowKey $rowKey -Properties $props
        if (-not $setResult.Success) {
            throw "Set-XdrTableEntity (XdrIngestDlq) failed · status=$($setResult.StatusCode) · $($setResult.Error)"
        }

        Track-XdrEvent -Name 'Ingest.Dlq.Queued' -Properties @{
            DcrId = $DcrId; StreamName = $StreamName; RowCount = $rowList.Count; Reason = $Reason
        }
        return $true
    } catch {
        # DLQ persist failure is honest-fail: log loudly via AppInsights + Write-Warning.
        # If DLQ itself fails, we've lost data — surfacing it is the only honest recovery.
        Track-XdrException -Exception $_.Exception -Properties @{
            DcrId = $DcrId; StreamName = $StreamName; Reason = "DLQ persist FAILED: $Reason"
        }
        Write-Warning "[DLQ] Persist FAILED · data lost: $($_.Exception.Message)"
        return $false
    }
}

Export-ModuleMember -Function Send-ToDce, Send-XdrDlq, Get-XdrDcrAuthToken
