# XdrLogRaider · Xdr.Common.Cache module
#
# Purpose: SecretStore (KV) + HotCache (in-memory) + StateStore (Storage Tables) facade.
# MutexStore (Blob Lease) lives in Xdr.Common.Lease — not here.
#
# 4 distinct storage primitives (NOT a tier hierarchy):
#   - SecretStore (Key Vault)          · long-lived secrets · cold-start read · rare write
#   - HotCache    (PowerShell vars)    · per-cycle hot data · cleared cold-start · cross-runspace mutex
#   - StateStore  (Storage Tables)     · persistent state · partition strategy documented at every write
#   - MutexStore  (Blob Lease)         · atomic mutex · lives in Xdr.Common.Lease
#
# Failure modes the design closes:
#   - SecretStore unavailable (transient KV throttle): exponential-backoff retry (3 attempts · jitter).
#   - HotCache cross-runspace concurrent write: named OS-level mutex.
#   - StateStore non-atomic upsert: HttpClient REST with ETag conditional (callers that need atomicity
#     use Set-XdrTableEntity directly with -IfMatchETag).
#   - JSON-serialization B-25 trap (`[string] -is [pscustomobject]` returns TRUE → double-encoded body
#     causing AADSTS50080): every ConvertTo-Json call site below uses `-isnot [string]` guard.

Set-StrictMode -Version Latest

# ─── HotCache (in-memory · per-runspace · cross-runspace mutex) ────────────────
$script:HotCache      = @{}
$script:HotCacheMutex = [System.Threading.Mutex]::new($false, 'XdrLogRaiderHotCache')

# ─── SecretStore bearer token (SAMI → vault.azure.net · MSI REST · NO Az dependency) ──
# iter#15 (2026-06-03): dropped the bundled Az.KeyVault + Az.Accounts modules. On the Legion
# Linux Consumption worker the bundled Az.KeyVault 6.5.0 could not bind its private assembly
# (Az.KeyVault.private) against the independently-pinned Az.Accounts 5.5.0 (Az.KeyVault.psd1
# RequiredModules is EMPTY so there is no version-coherence enforcement) — which cascade-failed
# the load of EVERY Xdr.* module (RequiredModules Az.KeyVault) and left Invoke-XdrEntryPoll
# unavailable. KV is now read via the data-plane REST API using the FA managed-identity token
# from IDENTITY_ENDPOINT — the identical pattern Xdr.Common.Storage already uses for Tables/Blob.
$script:KvBearerToken     = $null
$script:KvBearerExpiryUtc = [DateTime]::MinValue

function script:Get-XdrKeyVaultBearerToken {
    if ($script:KvBearerToken -and $script:KvBearerExpiryUtc -gt [DateTime]::UtcNow.AddMinutes(5)) {
        return $script:KvBearerToken
    }

    # Production path: FA-injected managed-identity endpoint (no Az PS dependency).
    $msiEndpoint = $env:IDENTITY_ENDPOINT
    $msiHeader   = $env:IDENTITY_HEADER
    if ($msiEndpoint -and $msiHeader) {
        $url = "$msiEndpoint" + "?resource=https://vault.azure.net&api-version=2019-08-01"
        $resp = Invoke-RestMethod -Method GET -Uri $url -Headers @{ 'X-IDENTITY-HEADER' = $msiHeader } -TimeoutSec 30 -ErrorAction Stop
        $script:KvBearerToken     = $resp.access_token
        # App Service MI returns expires_on (epoch sec · STRING); IMDS returns expires_in. Dot-access of an
        # absent prop throws under StrictMode — read via PSObject.Properties indexer + accept either shape.
        $rp = $resp.PSObject.Properties
        $lifeSec = if ($rp['expires_in'] -and $rp['expires_in'].Value) { [int]$rp['expires_in'].Value }
                   elseif ($rp['expires_on'] -and $rp['expires_on'].Value) { [Math]::Max(60, [long]$rp['expires_on'].Value - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) }
                   else { 3600 }
        $script:KvBearerExpiryUtc = [DateTime]::UtcNow.AddSeconds($lifeSec - 300)
        return $script:KvBearerToken
    }

    # Local-dev fallback ONLY (developer must have Az.Accounts installed; it is NOT bundled in the FA zip).
    if (Get-Command Get-AzAccessToken -ErrorAction SilentlyContinue) {
        $tok = Get-AzAccessToken -ResourceUrl 'https://vault.azure.net' -ErrorAction Stop
        $script:KvBearerToken     = $tok.Token
        $script:KvBearerExpiryUtc = if ($tok.ExpiresOn) { $tok.ExpiresOn.UtcDateTime } else { [DateTime]::UtcNow.AddMinutes(50) }
        return $script:KvBearerToken
    }

    throw "KeyVault bearer token unavailable (no MSI endpoint and Az SDK absent)"
}

# ─── SecretStore (Key Vault · data-plane REST · HotCache front · exp-backoff 3 attempts) ──
# KV data-plane REST: GET https://<vault>.vault.azure.net/secrets/<name>?api-version=7.4
#   → { value: '<secret>', id, attributes, ... } · value is always a string (no B-25 trap).
# Rare cold-start reads only · HotCache (L1) absorbs repeats within the cycle.

function Get-XdrCachedSecret {
    <#
    .SYNOPSIS
    Get secret from SecretStore (KV data-plane REST) with HotCache front + exponential-backoff retry on KV throttle.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $SecretName,
        [string] $VaultName = $env:XDRLR_KEYVAULT_NAME,
        [int]    $L1TtlSeconds = 300,
        [switch] $BypassL1
    )

    if (-not $VaultName) { throw "XDRLR_KEYVAULT_NAME env var missing" }

    $hotKey = "kv::$VaultName::$SecretName"

    # HotCache check (unless bypassed)
    if (-not $BypassL1) {
        $script:HotCacheMutex.WaitOne(5000) | Out-Null
        try {
            if ($script:HotCache.ContainsKey($hotKey)) {
                $entry = $script:HotCache[$hotKey]
                if (([DateTime]::UtcNow - $entry.CachedUtc).TotalSeconds -lt $L1TtlSeconds) {
                    return $entry.Value
                }
            }
        } finally { $script:HotCacheMutex.ReleaseMutex() }
    }

    # SecretStore fetch via KV data-plane REST with exponential backoff (handles transient 429 throttle).
    $maxAttempts = 3
    $baseDelayMs = 200
    $secretUrl   = "https://$VaultName.vault.azure.net/secrets/$SecretName" + "?api-version=7.4"
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            $token  = Get-XdrKeyVaultBearerToken
            # TLS-1.2+ pinned code-side (§3) · KV data-plane secrets fetch (Bearer + secret value in transit)
            $resp   = Invoke-RestMethod -Method GET -Uri $secretUrl -Headers @{ 'Authorization' = "Bearer $token" } -TimeoutSec 30 -ErrorAction Stop -SslProtocol 'Tls12, Tls13'
            $secret = $resp.value
            if ($null -ne $secret) {
                $script:HotCacheMutex.WaitOne(5000) | Out-Null
                try {
                    $script:HotCache[$hotKey] = @{ Value = $secret; CachedUtc = [DateTime]::UtcNow }
                } finally { $script:HotCacheMutex.ReleaseMutex() }
                return $secret
            }
        } catch {
            if ($attempt -eq $maxAttempts) {
                throw (New-XdrException -Type Cache -Message "SecretStore KV REST fetch failed after $maxAttempts attempts: $($_.Exception.Message)" -Properties @{ Layer = 'SecretStore'; SecretName = $SecretName })
            }
            $delay = $baseDelayMs * ([math]::Pow(2, $attempt - 1)) + (Get-Random -Maximum 100)
            Start-Sleep -Milliseconds $delay
        }
    }
    return $null
}

# ─── StateStore (Storage Tables via HttpClient REST · partition strategy LOCKED) ──
# Partition strategy for XdrTierState (session cache):
#   PartitionKey = Portal     (e.g. 'Defender')
#   RowKey       = UPN        (e.g. 'svc-acct@contoso.com')
# Rationale: session lookups are always by (Portal, UPN). Multi-tenant ready: when we later
# add tenant-scoped sessions we extend RowKey to "tenant::upn". Single-partition reads are
# cheaper than cross-partition scans, and Tables guarantees strong consistency per partition.

function Get-XdrCachedSession {
    <#
    .SYNOPSIS
    Read session: HotCache → StateStore (XdrTierState table). Null on miss.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $Portal,
        [Parameter(Mandatory)] [string] $UPN
    )

    $hotKey = "session::$Portal::$UPN"

    # HotCache first
    $script:HotCacheMutex.WaitOne(5000) | Out-Null
    try {
        if ($script:HotCache.ContainsKey($hotKey)) {
            return $script:HotCache[$hotKey].Value
        }
    } finally { $script:HotCacheMutex.ReleaseMutex() }

    # StateStore (XdrTierState · PartitionKey=Portal, RowKey=UPN)
    try {
        $result = Get-XdrTableEntity -TableName 'XdrTierState' -PartitionKey $Portal -RowKey $UPN
        if (-not $result.Found) { return $null }
        $row = $result.Entity
        if ($row.SessionJson) {
            # B-25 trap guard: SessionJson is always a string from REST; verify before ConvertFrom-Json.
            $sessionText = $row.SessionJson
            if ($sessionText -isnot [string]) { $sessionText = [string]$sessionText }
            $sessionData = $sessionText | ConvertFrom-Json -AsHashtable -Depth 25

            $script:HotCacheMutex.WaitOne(5000) | Out-Null
            try {
                $script:HotCache[$hotKey] = @{ Value = $sessionData; CachedUtc = [DateTime]::UtcNow }
            } finally { $script:HotCacheMutex.ReleaseMutex() }
            return $sessionData
        }
    } catch {
        Write-Warning "[Cache] StateStore session read failed: $($_.Exception.Message)"
    }
    return $null
}

function Set-XdrCachedSession {
    <#
    .SYNOPSIS
    Write session to HotCache + StateStore (XdrTierState · partition=Portal, rowkey=UPN).
    Upsert (no ETag conditional) — sessions are last-write-wins per (Portal, UPN).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Portal,
        [Parameter(Mandatory)] [string] $UPN,
        [Parameter(Mandatory)] [hashtable] $SessionData
    )

    $hotKey = "session::$Portal::$UPN"

    # B-25 guard: SessionData is always a hashtable here; we serialize once to a string.
    # If a future caller passes a string (it shouldn't), this guard preserves it verbatim.
    if ($SessionData -isnot [hashtable] -and $SessionData -isnot [System.Collections.IDictionary]) {
        throw "Set-XdrCachedSession: SessionData must be a hashtable (got $($SessionData.GetType().FullName))"
    }
    $sessionJson = $SessionData | ConvertTo-Json -Depth 10 -Compress

    # HotCache update first (fast path for next read on this worker)
    $script:HotCacheMutex.WaitOne(5000) | Out-Null
    try {
        $script:HotCache[$hotKey] = @{ Value = $SessionData; CachedUtc = [DateTime]::UtcNow }
    } finally { $script:HotCacheMutex.ReleaseMutex() }

    # StateStore write (XdrTierState · PartitionKey=Portal, RowKey=UPN)
    try {
        $props = @{
            SessionJson    = $sessionJson
            LastUpdatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        }
        $resp = Set-XdrTableEntity -TableName 'XdrTierState' -PartitionKey $Portal -RowKey $UPN -Properties $props
        if (-not $resp.Success) {
            # LOUD (host-mirror → AppTraces · reliable). A swallowed L2 write is exactly why XdrTierState
            # sat empty and every worker recycle burned a fresh TOTP auth. Never silent again.
            Write-Host "[evt] Cache.L2.WriteFailed table=XdrTierState portal=$Portal status=$($resp.StatusCode) err=$($resp.Error)"
            if (Get-Command Track-XdrEvent -ErrorAction SilentlyContinue) { Track-XdrEvent -Name 'Cache.L2.WriteFailed' -Properties @{ Table = 'XdrTierState'; Portal = $Portal; StatusCode = $resp.StatusCode } }
        }
        return $resp.Success
    } catch {
        Write-Host "[evt] Cache.L2.WriteFailed table=XdrTierState portal=$Portal exception=$($_.Exception.Message)"
        return $false
    }
}

function Invalidate-XdrCache {
    <#
    .SYNOPSIS
    Clear HotCache entries by prefix (e.g. on AuthChainBroken: prefix 'session::Defender::').
    #>
    [CmdletBinding()]
    param(
        [string] $L1KeyPrefix = ''
    )
    $script:HotCacheMutex.WaitOne(5000) | Out-Null
    try {
        if ($L1KeyPrefix) {
            $keysToRemove = @($script:HotCache.Keys | Where-Object { $_ -like "$L1KeyPrefix*" })
            foreach ($k in $keysToRemove) { $script:HotCache.Remove($k) }
        } else {
            $script:HotCache.Clear()
        }
    } finally { $script:HotCacheMutex.ReleaseMutex() }
}

# WS3.1 · Remove-XdrL2Session was REMOVED (operator no-compat directive · zero callers). It destroyed the L2 row —
# including the 90d ESTSAUTHPERSISTENT KmsiCookie — on every reactive 440, forcing a T3 TOTP burn each time (the
# verified-live root cause of the old 110-min cap). The KMSI-preserving self-heal (Invoke-XdrAuthenticated:
# L1-only Invalidate-XdrCache + Connect -Force) is the design now; a function that can silently reintroduce the
# TOTP-burn class does not ship.

Export-ModuleMember -Function `
    Get-XdrCachedSecret, `
    Get-XdrCachedSession, Set-XdrCachedSession, `
    Invalidate-XdrCache
