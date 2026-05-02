function Get-XdrAuthFromKeyVault {
    <#
    .SYNOPSIS
        L1 portal-generic auth-material loader from Azure Key Vault, with TTL-bounded cache.

    .DESCRIPTION
        Reads the auth secrets for a given service account from Key Vault and returns
        a hashtable ready to pass as -Credential to a Connect-<Portal>Portal function.

        Secret naming pattern (parameterized via -SecretPrefix):
          <prefix>-upn         (always)
          <prefix>-password    (CredentialsTotp)
          <prefix>-totp        (CredentialsTotp; Base32 secret)
          <prefix>-passkey     (Passkey; JSON bundle)
          <prefix>-sccauth     (DirectCookies; Defender-specific cookie name)
          <prefix>-xsrf        (DirectCookies; Defender-specific cookie name)

        Default `-SecretPrefix = 'mde-portal'` for backward-compatibility with
        v0.1.0-beta deployments. v0.2.0 multi-portal deployments will use distinct
        prefixes per portal (e.g., `purview-portal`, `intune-portal`).

        v0.1.0-beta first publish — TTL CACHE (production-readiness gate):
          Pre-fix: secrets fetched on every call. KV throttles tenant-wide
          at 2,000 ops/10 sec/vault, and a tier-poll could read 3 secrets
          per stream × 47 streams = 141 reads/cycle. The 2026-04-30
          ballpit-tenant load-test caught us at 800+ KV reads/min during
          tier transitions.

          Pre-fix (alternate framing operators have seen): the FA worker
          process cached secrets in $script:CredentialCache for the
          lifetime of the worker (no TTL). Operator KV-secret rotation
          (annual / quarterly) was silently ignored until the worker
          restarted — the FA kept using the stale value for hours.

          Post-fix: $script:CredentialCache holds the resolved hashtable;
          $script:CredentialCacheExpiry holds the UTC eviction time. TTL
          is read from `KV_CACHE_TTL_MINUTES` env var (default 60). On
          each call we check expiry; if past, we evict + re-fetch.
          Cache key is "$VaultUri|$SecretPrefix|$Method" so multi-portal
          deployments (v0.2.0) cache distinct entries per portal.

          Operator-driven manual eviction: pass -Force to bypass + refresh
          unconditionally. Useful inside Connect-<Portal>Portal -Force
          paths so a 401-induced reauth always re-reads KV (catches the
          rotation case immediately rather than waiting for TTL expiry).

          App Insights event KV.CacheEvicted fires on every refresh with
          Reason in {first-fetch, ttl, manual}. Operators can KQL-query
          to verify rotation propagation:
            customEvents
            | where name == 'KV.CacheEvicted'
            | summarize count() by tostring(customDimensions.Reason),
              bin(timestamp, 1h)

    .PARAMETER VaultUri
        KV URI, e.g., https://myvault.vault.azure.net

    .PARAMETER SecretPrefix
        Prefix for secrets (default 'mde-portal'). Other portal modules will pass
        their own prefix (e.g., 'purview-portal' for Xdr.Purview.Auth in v0.2.0).

    .PARAMETER AuthMethod
        'CredentialsTotp', 'Passkey', or 'DirectCookies'. Snake-case aliases accepted
        (`credentials_totp`, `passkey`, `direct_cookies`) per ARM env-var convention.

    .PARAMETER Force
        Bypass the TTL cache + re-fetch from KV unconditionally. Emits
        KV.CacheEvicted with Reason='manual'. Used by reauth paths so a
        401 immediately picks up rotated secrets.

    .PARAMETER OperationId
        Optional correlation GUID for App Insights stitching of the
        KV.CacheEvicted event back to the auth chain.

    .OUTPUTS
        [hashtable] matching the target Connect-<Portal>Portal function's -Credential
        expectation.

    .NOTES
        DirectCookies returns Defender-specific cookie names (sccauth, xsrf). Other
        portals will need a portal-specific KV loader if they want DirectCookies
        support — but DirectCookies is testing-only and not the production auth path.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $VaultUri,
        [string] $SecretPrefix = 'mde-portal',
        [Parameter(Mandatory)]
        [ValidateSet('CredentialsTotp', 'Passkey', 'DirectCookies', 'credentials_totp', 'passkey', 'direct_cookies')]
        [string] $AuthMethod,
        [switch] $Force,
        [string] $OperationId
    )

    # Normalize method (ARM env-vars arrive in snake_case)
    $method = switch ($AuthMethod) {
        'credentials_totp' { 'CredentialsTotp' }
        'passkey'          { 'Passkey' }
        'direct_cookies'   { 'DirectCookies' }
        default            { $AuthMethod }
    }

    # Extract vault short name from URI
    $vaultName = ([uri]$VaultUri).Host.Split('.')[0]

    # ------------------------------------------------------------------------
    # TTL cache — v0.1.0-beta first publish.
    # ------------------------------------------------------------------------
    # $script:CredentialCache and $script:CredentialCacheExpiry are
    # initialised in the parent module (Xdr.Common.Auth.psm1) so they
    # survive across function invocations within the same FA worker
    # process. Strict-mode read pattern: check via .ContainsKey to avoid
    # PropertyNotFoundException.
    $cacheKey = "$VaultUri|$SecretPrefix|$method"
    $now = [datetime]::UtcNow
    $ttlMin = 60
    $envTtl = [Environment]::GetEnvironmentVariable('KV_CACHE_TTL_MINUTES')
    if (-not [string]::IsNullOrWhiteSpace($envTtl)) {
        $parsed = 0
        if ([int]::TryParse($envTtl, [ref] $parsed) -and $parsed -gt 0) {
            $ttlMin = $parsed
        }
    }

    $cacheHit = $false
    $evictionReason = $null
    if ($Force.IsPresent) {
        $evictionReason = 'manual'
    } elseif ($null -eq $script:CredentialCache -or -not $script:CredentialCache.ContainsKey($cacheKey)) {
        $evictionReason = 'first-fetch'
    } else {
        $expiry = $null
        if ($null -ne $script:CredentialCacheExpiry -and $script:CredentialCacheExpiry.ContainsKey($cacheKey)) {
            $expiry = $script:CredentialCacheExpiry[$cacheKey]
        }
        if ($null -ne $expiry -and $now -lt $expiry) {
            $cacheHit = $true
        } else {
            $evictionReason = 'ttl'
        }
    }

    if ($cacheHit) {
        # Cache HIT — return the cached entry. We still emit a low-volume
        # AI trace at Verbose so operators can correlate cache pressure
        # with KV throughput in the rare debug case (does NOT count toward
        # the rate-limit since we don't actually call KV).
        # v0.1.0-beta production-readiness polish: emit cache_hit metric so
        # operators can chart hit-rate distinct from miss-rate (the KV.
        # CacheEvicted event covers misses; this complements it).
        if (Get-Command -Name Send-XdrAppInsightsCustomMetric -ErrorAction SilentlyContinue) {
            Send-XdrAppInsightsCustomMetric -MetricName 'xdr.kv.cache_hit' -Value 1.0 `
                -Properties @{
                    VaultUri     = $VaultUri
                    SecretPrefix = $SecretPrefix
                    AuthMethod   = $method
                } -OperationId $OperationId
        }
        return $script:CredentialCache[$cacheKey]
    }

    # Cache MISS or eviction — re-fetch from KV.
    if (Get-Command -Name Send-XdrAppInsightsCustomEvent -ErrorAction SilentlyContinue) {
        $reasonStr = if ([string]::IsNullOrWhiteSpace($evictionReason)) { 'first-fetch' } else { $evictionReason }
        Send-XdrAppInsightsCustomEvent -EventName 'KV.CacheEvicted' -OperationId $OperationId -Properties @{
            VaultUri     = $VaultUri
            SecretPrefix = $SecretPrefix
            AuthMethod   = $method
            Reason       = $reasonStr
            TtlMinutes   = $ttlMin
        }
    }
    # v0.1.0-beta production-readiness polish: cache_miss metric (1 per miss
    # / first-fetch / TTL-evict / Force) so operators can chart KV pressure.
    if (Get-Command -Name Send-XdrAppInsightsCustomMetric -ErrorAction SilentlyContinue) {
        $reasonForMiss = if ([string]::IsNullOrWhiteSpace($evictionReason)) { 'first-fetch' } else { $evictionReason }
        Send-XdrAppInsightsCustomMetric -MetricName 'xdr.kv.cache_miss' -Value 1.0 `
            -Properties @{
                VaultUri     = $VaultUri
                SecretPrefix = $SecretPrefix
                AuthMethod   = $method
                Reason       = $reasonForMiss
            } -OperationId $OperationId
    }

    try {
        $result = switch ($method) {
            'CredentialsTotp' {
                $upnSecret   = Get-AzKeyVaultSecret -VaultName $vaultName -Name "$SecretPrefix-upn"      -AsPlainText -ErrorAction Stop
                $pwSecret    = Get-AzKeyVaultSecret -VaultName $vaultName -Name "$SecretPrefix-password" -AsPlainText -ErrorAction Stop
                $totpSecret  = Get-AzKeyVaultSecret -VaultName $vaultName -Name "$SecretPrefix-totp"     -AsPlainText -ErrorAction Stop
                @{
                    upn        = $upnSecret
                    password   = $pwSecret
                    totpBase32 = $totpSecret
                }
            }
            'Passkey' {
                $passkeyJson = Get-AzKeyVaultSecret -VaultName $vaultName -Name "$SecretPrefix-passkey" -AsPlainText -ErrorAction Stop
                $passkey = $passkeyJson | ConvertFrom-Json -ErrorAction Stop
                @{
                    upn     = $passkey.upn
                    passkey = $passkey
                }
            }
            'DirectCookies' {
                $upn     = Get-AzKeyVaultSecret -VaultName $vaultName -Name "$SecretPrefix-upn"     -AsPlainText -ErrorAction Stop
                $sccauth = Get-AzKeyVaultSecret -VaultName $vaultName -Name "$SecretPrefix-sccauth" -AsPlainText -ErrorAction Stop
                $xsrf    = Get-AzKeyVaultSecret -VaultName $vaultName -Name "$SecretPrefix-xsrf"    -AsPlainText -ErrorAction Stop
                @{
                    upn       = $upn
                    sccauth   = $sccauth
                    xsrfToken = $xsrf
                }
            }
        }
    } catch {
        # v0.1.0-beta production-readiness polish: emit TrackException for KV
        # read failures (rotation gone wrong, IAM regression, etc.) BEFORE
        # re-throw so AI's exceptions table catches the failure with a
        # stitched OperationId. Preserves stack trace via $_.Exception.
        if (Get-Command -Name Send-XdrAppInsightsException -ErrorAction SilentlyContinue) {
            Send-XdrAppInsightsException -Exception $_.Exception `
                -SeverityLevel 'Error' `
                -OperationId $OperationId `
                -Properties @{
                    VaultUri     = $VaultUri
                    SecretPrefix = $SecretPrefix
                    AuthMethod   = $method
                    Phase        = 'kv-secret-read'
                }
        }
        throw
    }

    # Populate cache (or refresh expiry on existing key).
    if ($null -eq $script:CredentialCache) {
        $script:CredentialCache = @{}
    }
    if ($null -eq $script:CredentialCacheExpiry) {
        $script:CredentialCacheExpiry = @{}
    }
    $script:CredentialCache[$cacheKey]       = $result
    $script:CredentialCacheExpiry[$cacheKey] = $now.AddMinutes($ttlMin)

    return $result
}


function Clear-XdrAuthKeyVaultCache {
    <#
    .SYNOPSIS
        Manually evicts the in-process KV secret cache. Useful for tests
        that want a fresh cache between scenarios + for operators wiring
        emergency rotation hooks.

    .DESCRIPTION
        Empties $script:CredentialCache + $script:CredentialCacheExpiry.
        Emits KV.CacheEvicted with Reason='manual-clear' so audit logs
        capture the eviction.

    .PARAMETER OperationId
        Optional correlation GUID for App Insights stitching.
    #>
    [CmdletBinding()]
    param(
        [string] $OperationId
    )

    $count = 0
    if ($null -ne $script:CredentialCache) {
        $count = $script:CredentialCache.Count
        $script:CredentialCache = @{}
    }
    if ($null -ne $script:CredentialCacheExpiry) {
        $script:CredentialCacheExpiry = @{}
    }

    if (Get-Command -Name Send-XdrAppInsightsCustomEvent -ErrorAction SilentlyContinue) {
        Send-XdrAppInsightsCustomEvent -EventName 'KV.CacheEvicted' -OperationId $OperationId -Properties @{
            Reason          = 'manual-clear'
            EntriesEvicted  = $count
        }
    }
}
