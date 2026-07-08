# XdrLogRaider · Xdr.Common.Storage module
#
# Purpose: low-level HttpClient REST helpers against Azure Storage (Tables + Blobs).
# SAMI bearer auth · token cached ~50min · shared by every consumer.
#
# Why direct REST (not the legacy AzTable PowerShell SDK):
#   - SDK Add-AzTableRow does NOT expose `If-Match: <etag>` or `If-None-Match: *` headers,
#     so two workers doing read-then-Add-AzTableRow can both succeed (TOCTOU on lease/checkpoint).
#   - Server-side ETag conditional writes are the only atomic primitive Azure Tables offers,
#     and Insert with `If-None-Match: *` is the only atomic "create-if-absent" path.
#   - Azure Blob Lease is the purpose-built distributed mutex (server-enforced TTL, atomic
#     acquire/release by lease-id) and likewise needs raw REST.
#
# Consumers:
#   - Xdr.Common.Cache       (StateStore: XdrTierState, TenantContext, TenantCapabilities, XdrCircuitState)
#   - Xdr.Common.Lease       (MutexStore: blob-lease single-flight gate)
#   - Xdr.Common.Runtime     (StateStore: XdrCheckpoint atomic write with ETag conditional)
#   - Xdr.Common.Capabilities(StateStore: TenantContext + TenantCapabilities)
#   - Xdr.Common.Ingest      (StateStore: XdrIngestDlq)
#
# All public functions return hashtables (never throw on HTTP 4xx) so callers can
# branch on StatusCode without try/catch. Network errors still throw.

Set-StrictMode -Version Latest

# ─── Bearer token cache (SAMI → storage.azure.com) ─────────────────────────────
$script:StorageBearerToken     = $null
$script:StorageBearerExpiryUtc = [DateTime]::MinValue
$script:StorageVersion         = '2020-12-06'   # Tables OAuth requires >=2019-12-12; Blob lease >=2012-02-12

function script:Get-XdrStorageBearerToken {
    if ($script:StorageBearerToken -and $script:StorageBearerExpiryUtc -gt [DateTime]::UtcNow.AddMinutes(5)) {
        return $script:StorageBearerToken
    }

    # Prefer the FA-injected MSI endpoint (no Az PS dependency). Fall back to Az SDK.
    $msiEndpoint = $env:IDENTITY_ENDPOINT
    $msiHeader   = $env:IDENTITY_HEADER

    if ($msiEndpoint -and $msiHeader) {
        $url = "$msiEndpoint" + "?resource=https://storage.azure.com/&api-version=2019-08-01"
        $resp = Invoke-RestMethod -Method GET -Uri $url -Headers @{ 'X-IDENTITY-HEADER' = $msiHeader } -TimeoutSec 30 -ErrorAction Stop
        $script:StorageBearerToken     = $resp.access_token
        # App Service MI (api 2019-08-01) returns expires_on (epoch seconds · STRING); IMDS returns expires_in.
        # Dot-access of an absent property THROWS under StrictMode -Version Latest — this was the live
        # PropertyNotFoundException that broke the blob-lease single-flight (-> AuthChainBroken contention -> 0 rows).
        # Read via PSObject.Properties indexer ($null-safe) and accept EITHER shape.
        $rp = $resp.PSObject.Properties
        $lifeSec = if ($rp['expires_in'] -and $rp['expires_in'].Value) { [int]$rp['expires_in'].Value }
                   elseif ($rp['expires_on'] -and $rp['expires_on'].Value) { [Math]::Max(60, [long]$rp['expires_on'].Value - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) }
                   else { 3600 }
        $script:StorageBearerExpiryUtc = [DateTime]::UtcNow.AddSeconds($lifeSec - 300)
        return $script:StorageBearerToken
    }

    # Az PS fallback (local-dev only)
    try {
        $tok = Get-AzAccessToken -ResourceUrl 'https://storage.azure.com/' -ErrorAction Stop
        $script:StorageBearerToken     = $tok.Token
        $script:StorageBearerExpiryUtc = if ($tok.ExpiresOn) { $tok.ExpiresOn.UtcDateTime } else { [DateTime]::UtcNow.AddMinutes(50) }
        return $script:StorageBearerToken
    } catch {
        throw "Storage bearer token unavailable (no MSI endpoint and Az SDK failed): $($_.Exception.Message)"
    }
}

# ─── Low-level REST invoker (returns parsed status + headers + body) ───────────
# B-25 trap guard: NEVER feed a non-string body to ConvertTo-Json from this layer —
# callers either pass a hashtable (we serialize) or a string (we pass through).
function script:Invoke-XdrStorageRest {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $Url,
        [Parameter(Mandatory)] [ValidateSet('GET','POST','PUT','DELETE','MERGE','HEAD')] [string] $Method,
        [hashtable] $ExtraHeaders = @{},
        [object]   $Body = $null,
        [string]   $ContentType = 'application/json',
        [int]      $TimeoutSec = 30
    )

    $token = Get-XdrStorageBearerToken

    $headers = @{
        'Authorization' = "Bearer $token"
        'x-ms-version'  = $script:StorageVersion
        'x-ms-date'     = ([DateTime]::UtcNow.ToString('R'))
    }
    foreach ($k in $ExtraHeaders.Keys) { $headers[$k] = $ExtraHeaders[$k] }

    $params = @{
        Method          = $Method
        Uri             = $Url
        Headers         = $headers
        TimeoutSec      = $TimeoutSec
        ErrorAction     = 'Stop'
        UseBasicParsing = $true
        SslProtocol     = 'Tls12, Tls13'   # TLS-1.2+ pinned code-side (§3) · Storage Tables/Blobs REST (Bearer + state)
    }
    if ($Method -in @('POST','PUT','MERGE')) {
        # B-25 guard: only objects get serialized; strings pass through verbatim.
        if ($null -eq $Body) {
            $params.Body = ''
        } elseif ($Body -isnot [string]) {
            $params.Body = $Body | ConvertTo-Json -Depth 15 -Compress
        } else {
            $params.Body = $Body
        }
        $params.ContentType = $ContentType
    }

    try {
        $resp = Invoke-WebRequest @params
        return @{
            Success    = $true
            StatusCode = [int]$resp.StatusCode
            Headers    = $resp.Headers
            Content    = $resp.Content
            # StrictMode-safe header read: $resp.Headers may be a generic Dictionary (.ETag property
            # throws PropertyNotFound) and an absent key via indexer throws KeyNotFoundException — the
            # try/catch returns $null for either (hashtable missing-key returns $null directly).
            ETag       = $(try { @($resp.Headers['ETag'])[0] } catch { $null })
            LeaseId    = $(try { @($resp.Headers['x-ms-lease-id'])[0] } catch { $null })
        }
    } catch {
        # Capture 4xx/5xx for structured branching at caller.
        # StrictMode-safe: $_.Exception.Response THROWS PropertyNotFound on a NON-HTTP exception
        # (storage 2s table-timeout / network / IOException — NOT an HttpResponseException). Reading
        # it unguarded surfaces a secondary "property 'Response' cannot be found" error that masks the
        # real transient and breaks the caller's retry → the checkpoint read/write fail-opens → the
        # cadence gate treats-all-due + skip-unchanged fails → SNAPSHOT dup-accumulation. Wrap the read
        # (same idiom as the ETag/LeaseId reads above + Xdr.Common.Ingest's HttpResponseException guard).
        $exResp = $(try { $_.Exception.Response } catch { $null })
        if ($exResp) {
            $sc      = [int]$exResp.StatusCode
            $eMsg    = ''
            try { $eMsg = $_.ErrorDetails.Message } catch { $eMsg = $_.Exception.Message }
            return @{
                Success    = $false
                StatusCode = $sc
                Headers    = $exResp.Headers
                Content    = $eMsg
                Error      = $_.Exception.Message
            }
        }
        # Network-level / transient (no HTTP response) — throw the ORIGINAL so the caller's retry sees it
        throw
    }
}

# ─── Public · Table entity I/O ────────────────────────────────────────────────
# Tables REST contract: keys go IN the URL as ('PartitionKey'='pk',RowKey='rk')
# Single-quote in a key value must be doubled (OData escape) per Azure spec.

function script:Format-XdrTableKey {
    param([string]$Key)
    if ($null -eq $Key) { return '' }
    return ($Key -replace "'", "''")
}

function Get-XdrTableEntity {
    <#
    .SYNOPSIS
    GET one Table entity by (PartitionKey, RowKey). 404 → Found=$false; other 4xx/5xx → throw.
    Returns @{ Found; Entity; ETag }. Entity is a hashtable of properties.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $TableName,
        [Parameter(Mandatory)] [string] $PartitionKey,
        [Parameter(Mandatory)] [string] $RowKey
    )
    $sa = $env:XDRLR_STORAGE_ACCOUNT
    if (-not $sa) { throw "XDRLR_STORAGE_ACCOUNT env var missing" }
    $pk = Format-XdrTableKey $PartitionKey
    $rk = Format-XdrTableKey $RowKey
    $url = "https://$sa.table.core.windows.net/$TableName(PartitionKey='$pk',RowKey='$rk')"

    $resp = Invoke-XdrStorageRest -Url $url -Method GET -ExtraHeaders @{ 'Accept' = 'application/json;odata=fullmetadata' }

    if (-not $resp.Success -and $resp.StatusCode -eq 404) {
        return @{ Found = $false; Entity = $null; ETag = $null }
    }
    if (-not $resp.Success) {
        throw "Get-XdrTableEntity failed · table=$TableName pk=$PartitionKey rk=$RowKey · status=$($resp.StatusCode) · $($resp.Error)"
    }

    # B-25 guard: response body is a string from Invoke-WebRequest
    $contentText = $resp.Content
    if ($contentText -isnot [string]) { $contentText = [string]$contentText }
    $entity = $contentText | ConvertFrom-Json -AsHashtable -Depth 25
    $etag = if ($entity.ContainsKey('odata.etag')) { $entity['odata.etag'] } else { $resp.ETag }
    return @{ Found = $true; Entity = $entity; ETag = $etag }
}

function Get-XdrTableEntities {
    <#
    .SYNOPSIS
    Query ALL Table entities for a PartitionKey in ONE logical read (paginating the Tables continuation token
    internally · loop-guarded). Returns @{ Found = $true; Entities = @(hashtable...) }; a 404 (table absent) →
    @{ Found = $false; Entities = @() }. F7 · lets a caller batch-read a whole partition once instead of O(N)
    per-row point-reads (the cadence gate's cold-start cost).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $TableName,
        [Parameter(Mandatory)] [string] $PartitionKey
    )
    $sa = $env:XDRLR_STORAGE_ACCOUNT
    if (-not $sa) { throw "XDRLR_STORAGE_ACCOUNT env var missing" }
    $pk = Format-XdrTableKey $PartitionKey
    $filter = [System.Uri]::EscapeDataString("PartitionKey eq '$pk'")
    $entities = [System.Collections.Generic.List[hashtable]]::new()
    $nextPk = $null; $nextRk = $null
    for ($page = 0; $page -lt 100; $page++) {   # loop-guard: 100 pages × 1000 rows ≫ any real partition
        $url = "https://$sa.table.core.windows.net/$TableName()?`$filter=$filter"
        if ($nextPk) { $url += "&NextPartitionKey=$([System.Uri]::EscapeDataString([string]$nextPk))" }
        if ($nextRk) { $url += "&NextRowKey=$([System.Uri]::EscapeDataString([string]$nextRk))" }
        $resp = Invoke-XdrStorageRest -Url $url -Method GET -ExtraHeaders @{ 'Accept' = 'application/json;odata=nometadata' }
        if (-not $resp.Success -and $resp.StatusCode -eq 404) { return @{ Found = $false; Entities = @() } }
        if (-not $resp.Success) { throw "Get-XdrTableEntities failed · table=$TableName pk=$PartitionKey · status=$($resp.StatusCode) · $($resp.Error)" }
        $contentText = $resp.Content; if ($contentText -isnot [string]) { $contentText = [string]$contentText }
        $body = $contentText | ConvertFrom-Json -AsHashtable -Depth 25
        if (($body -is [System.Collections.IDictionary]) -and $body.ContainsKey('value')) {
            foreach ($e in @($body['value'])) { if ($e -is [System.Collections.IDictionary]) { [void]$entities.Add($e) } }
        }
        # Tables continuation comes back as RESPONSE HEADERS · pass them as query params on the next request.
        $nextPk = $(try { @($resp.Headers['x-ms-continuation-NextPartitionKey'])[0] } catch { $null })
        $nextRk = $(try { @($resp.Headers['x-ms-continuation-NextRowKey'])[0] } catch { $null })
        if (-not $nextPk) { break }
    }
    return @{ Found = $true; Entities = @($entities) }
}

function Set-XdrTableEntity {
    <#
    .SYNOPSIS
    PUT (Insert-Or-Replace) a Table entity. Optional ETag conditional for atomic update.

    UPSERT (Insert-Or-Replace) semantics — with NO real ETag we send NO If-Match header so a FIRST-EVER
    write CREATES the entity. Sending `If-Match: *` is "Update Entity" semantics that 404s on a
    non-existent entity (the 050a5c0 checkpoint bug — was latent here for session/capability/DLQ/breaker,
    leaving those StateStore tables permanently EMPTY → no durable L2 session → TOTP burned every recycle):
    -IfMatchETag ''  (default) → upsert · no If-Match header · create-or-replace
    -IfMatchETag '*'           → upsert · treated as no-condition (legacy alias for '')
    -IfMatchETag '<real-etag>' → atomic conditional update · 412 Precondition Failed on concurrent change

    Returns @{ Success; StatusCode; ETag; Error } — does NOT throw on 412 (caller decides).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $TableName,
        [Parameter(Mandatory)] [string] $PartitionKey,
        [Parameter(Mandatory)] [string] $RowKey,
        [Parameter(Mandatory)] [hashtable] $Properties,
        [string] $IfMatchETag = ''
    )
    $sa = $env:XDRLR_STORAGE_ACCOUNT
    if (-not $sa) { throw "XDRLR_STORAGE_ACCOUNT env var missing" }
    $pk = Format-XdrTableKey $PartitionKey
    $rk = Format-XdrTableKey $RowKey
    $url = "https://$sa.table.core.windows.net/$TableName(PartitionKey='$pk',RowKey='$rk')"

    # Build entity body. PartitionKey + RowKey are mandatory members of the body.
    $body = @{
        PartitionKey = $PartitionKey
        RowKey       = $RowKey
    }
    foreach ($k in $Properties.Keys) { $body[$k] = $Properties[$k] }

    $headers = @{
        'Accept' = 'application/json;odata=nometadata'
        'Prefer' = 'return-no-content'
    }
    # UPSERT-by-default: only a REAL ETag becomes a conditional If-Match. '' and '*' send NO header →
    # Insert-Or-Replace (CREATES the entity). If-Match:* would 404 on a non-existent entity (050a5c0).
    if ($IfMatchETag -and $IfMatchETag -ne '*') { $headers['If-Match'] = $IfMatchETag }

    $resp = Invoke-XdrStorageRest -Url $url -Method PUT -ExtraHeaders $headers -Body $body

    # Indexer reads (StrictMode-safe): the FAILURE path of Invoke-XdrStorageRest returns a hashtable
    # WITHOUT an 'ETag' key; `$resp.ETag` (dot) throws PropertyNotFound under StrictMode (this was the
    # LIVE checkpoint-write crash 2026-06-04 · cursor never persisted → every cycle re-ingested · plan §39.11).
    return @{
        Success    = $resp['Success']
        StatusCode = $resp['StatusCode']
        ETag       = $resp['ETag']
        Error      = if (-not $resp['Success']) { $resp['Error'] } else { $null }
    }
}

function Remove-XdrTableEntity {
    <#
    .SYNOPSIS
    DELETE a Table entity. 404 treated as success (idempotent).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $TableName,
        [Parameter(Mandatory)] [string] $PartitionKey,
        [Parameter(Mandatory)] [string] $RowKey,
        [string] $IfMatchETag = '*'
    )
    $sa = $env:XDRLR_STORAGE_ACCOUNT
    if (-not $sa) { throw "XDRLR_STORAGE_ACCOUNT env var missing" }
    $pk = Format-XdrTableKey $PartitionKey
    $rk = Format-XdrTableKey $RowKey
    $url = "https://$sa.table.core.windows.net/$TableName(PartitionKey='$pk',RowKey='$rk')"

    $resp = Invoke-XdrStorageRest -Url $url -Method DELETE -ExtraHeaders @{ 'If-Match' = $IfMatchETag }
    return ($resp.Success -or $resp.StatusCode -eq 404)
}

# ─── Public · Blob primitives (used for MutexStore lease blobs) ────────────────

function Ensure-XdrBlobExists {
    <#
    .SYNOPSIS
    Idempotently create an empty BlockBlob (only if absent). 201 created or 412 already-exists — both OK.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $Container,
        [Parameter(Mandatory)] [string] $BlobName
    )
    $sa = $env:XDRLR_STORAGE_ACCOUNT
    if (-not $sa) { throw "XDRLR_STORAGE_ACCOUNT env var missing" }
    $url = "https://$sa.blob.core.windows.net/$Container/$BlobName"
    $headers = @{
        'x-ms-blob-type'   = 'BlockBlob'
        'If-None-Match'    = '*'
        'Content-Length'   = '0'
    }
    $resp = Invoke-XdrStorageRest -Url $url -Method PUT -ExtraHeaders $headers -Body ''
    return ($resp.Success -or $resp.StatusCode -in @(409, 412))
}

function Acquire-XdrBlobLease {
    <#
    .SYNOPSIS
    Acquire blob lease. Returns lease-id string on success; $null if blob is already leased.

    Lease duration: 15-60s (Azure limit) or -1 for infinite.
    Worker crash → lease auto-expires at duration → next worker can acquire. No deadlock.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Container,
        [Parameter(Mandatory)] [string] $BlobName,
        [int]    $LeaseDurationSeconds = 60,
        [string] $ProposedLeaseId = ''
    )
    $sa = $env:XDRLR_STORAGE_ACCOUNT
    if (-not $sa) { throw "XDRLR_STORAGE_ACCOUNT env var missing" }

    # Ensure target blob exists (idempotent — silently ok if already present).
    $null = Ensure-XdrBlobExists -Container $Container -BlobName $BlobName

    if (-not $ProposedLeaseId) { $ProposedLeaseId = [Guid]::NewGuid().ToString() }
    $url = "https://$sa.blob.core.windows.net/$Container/$BlobName" + "?comp=lease"
    $headers = @{
        'x-ms-lease-action'        = 'acquire'
        'x-ms-lease-duration'      = "$LeaseDurationSeconds"
        'x-ms-proposed-lease-id'   = $ProposedLeaseId
        'Content-Length'           = '0'
    }
    $resp = Invoke-XdrStorageRest -Url $url -Method PUT -ExtraHeaders $headers -Body ''

    if ($resp.Success -and $resp.StatusCode -eq 201) {
        # Azure echoes the lease-id in the x-ms-lease-id response header
        if ($resp.LeaseId) { return $resp.LeaseId }
        return $ProposedLeaseId
    }
    if ($resp.StatusCode -in @(409, 412)) { return $null }       # contended
    throw "Acquire-XdrBlobLease unexpected status $($resp.StatusCode) · $($resp.Error)"
}

function Release-XdrBlobLease {
    <#
    .SYNOPSIS
    Release a blob lease. 200 OK on success; 409 if lease already expired/released (treated success).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $Container,
        [Parameter(Mandatory)] [string] $BlobName,
        [Parameter(Mandatory)] [string] $LeaseId
    )
    $sa = $env:XDRLR_STORAGE_ACCOUNT
    if (-not $sa) { throw "XDRLR_STORAGE_ACCOUNT env var missing" }
    $url = "https://$sa.blob.core.windows.net/$Container/$BlobName" + "?comp=lease"
    $headers = @{
        'x-ms-lease-action' = 'release'
        'x-ms-lease-id'     = $LeaseId
        'Content-Length'    = '0'
    }
    $resp = Invoke-XdrStorageRest -Url $url -Method PUT -ExtraHeaders $headers -Body ''
    return ($resp.Success -or $resp.StatusCode -eq 409)
}

function Renew-XdrBlobLease {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $Container,
        [Parameter(Mandatory)] [string] $BlobName,
        [Parameter(Mandatory)] [string] $LeaseId
    )
    $sa = $env:XDRLR_STORAGE_ACCOUNT
    if (-not $sa) { throw "XDRLR_STORAGE_ACCOUNT env var missing" }
    $url = "https://$sa.blob.core.windows.net/$Container/$BlobName" + "?comp=lease"
    $headers = @{
        'x-ms-lease-action' = 'renew'
        'x-ms-lease-id'     = $LeaseId
        'Content-Length'    = '0'
    }
    $resp = Invoke-XdrStorageRest -Url $url -Method PUT -ExtraHeaders $headers -Body ''
    return $resp.Success
}

Export-ModuleMember -Function `
    Get-XdrTableEntity, Get-XdrTableEntities, Set-XdrTableEntity, Remove-XdrTableEntity, `
    Ensure-XdrBlobExists, Acquire-XdrBlobLease, Release-XdrBlobLease, Renew-XdrBlobLease
