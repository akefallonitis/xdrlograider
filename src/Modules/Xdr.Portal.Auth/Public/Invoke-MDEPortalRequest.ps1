# Module-scope counter surfaced to the per-tier heartbeat via
# Get-XdrPortalRate429Count / Reset-XdrPortalRate429Count below.
# Invoke-MDETierPoll reads+resets at the top of each tier poll, aggregates into
# the Heartbeat Rate429Count column. Initialized unconditionally — module
# reimport naturally resets the counter (which is what we want).
$script:Rate429Count = 0

# Proactive session-refresh threshold. Portal sccauth sessions have an
# undocumented TTL around 4h; we force a fresh auth chain at 3h30m to
# avoid tripping reactive 401/440 refreshes mid-tier-poll.
$script:SessionMaxAgeMinutes = 210

function Invoke-MDEPortalRequest {
    <#
    .SYNOPSIS
        Authenticated wrapper around Invoke-WebRequest for Defender XDR portal API calls.

    .DESCRIPTION
        Takes a session from Connect-MDEPortal and automatically adds the X-XSRF-TOKEN
        header with the current (just-rotated) value. Handles 401 transparently by
        forcing a re-auth and retrying once.

        v0.1.0-beta hardening:
          * 429 Too Many Requests — parse Retry-After (seconds or HTTP-date),
            sleep + jitter, up to 3 retries. Increments $script:Rate429Count
            (surfaced to Heartbeat via Get-XdrPortalRate429Count). On 3rd
            exhaustion throws an exception whose message is prefixed with
            '[MDERateLimited]' so callers can regex-match the counter path.
          * Session TTL — if the cached $Session.AcquiredUtc is older than
            3h30m, force a fresh Connect-MDEPortal before the request. Cheap
            insurance against reactive 401/440 refresh latency mid-poll.
          * 401 / 440 reauth — unchanged from v0.1.0-beta.1.
          * 403 — unchanged; surfaces to caller without reauth spin.
          * 5xx — unchanged; caller handles via higher-level retry.

    .PARAMETER Session
        Object returned by Connect-MDEPortal (pscustomobject with .Session, .Upn, etc.)

    .PARAMETER Path
        Portal API path (e.g., '/api/settings/GetAdvancedFeaturesSetting').

    .PARAMETER Method
        HTTP method. Default: GET.

    .PARAMETER Body
        Request body (string or hashtable).

    .PARAMETER ContentType
        Defaults to 'application/json' for POST/PUT, omitted for GET.

    .PARAMETER TimeoutSec
        Per-request timeout. Default 60s.

    .PARAMETER AdditionalHeaders
        Optional extra HTTP headers. Merged AFTER the hardcoded defaults
        (X-XSRF-TOKEN, Accept, X-Requested-With) so caller-supplied values
        OVERRIDE the defaults. Used by XSPM endpoints that require
        `x-tid` (tenant GUID) + `x-ms-scenario-name` (portal telemetry tag).

    .OUTPUTS
        [pscustomobject] parsed JSON response body.

    .EXAMPLE
        $session = Connect-MDEPortal -Method CredentialsTotp -Credential $creds
        Invoke-MDEPortalRequest -Session $session -Path '/api/settings/GetAdvancedFeaturesSetting'

    .EXAMPLE
        # XSPM call with required scenario-name + tenant-id headers
        Invoke-MDEPortalRequest -Session $session `
            -Path '/apiproxy/mtp/xspmatlas/attacksurface/query' -Method POST `
            -Body @{query='AttackPathsV2'; options=@{top=100;skip=0}; apiVersion='v2'} `
            -AdditionalHeaders @{'x-tid'=$session.TenantId; 'x-ms-scenario-name'='AttackPathOverview_get_has_attack_paths'}
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Session,
        [Parameter(Mandatory)] [string] $Path,
        [string] $Method = 'GET',
        $Body = $null,
        [string] $ContentType,
        [int] $TimeoutSec = 60,
        [hashtable] $AdditionalHeaders = @{}
    )

    $portalHost = $Session.PortalHost

    # Path is used as-is. Caller is responsible for the right prefix — some APIs
    # live under /api/..., some under /apiproxy/mtp/..., some under /apiproxy/ngp/...
    # Our endpoints manifest knows the correct base for each stream; do NOT force
    # /apiproxy here or you'll rewrite /api/settings/... into /apiproxy/api/...
    # which the portal responds to with HTTP 500.
    if ($Path -notmatch '^/') { $Path = "/$Path" }
    $uri = "https://$portalHost$Path"

    # Session TTL check — proactively refresh at 3h30m to stay well under the
    # undocumented ~4h portal session cap. Reactive 401/440 reauth still runs
    # below as a safety net for tenants with shorter TTL.
    if ($Session.PSObject.Properties['AcquiredUtc'] -and $Session.AcquiredUtc) {
        $sessionAge = [datetime]::UtcNow - $Session.AcquiredUtc
        if ($sessionAge.TotalMinutes -gt $script:SessionMaxAgeMinutes) {
            Write-Verbose "Invoke-MDEPortalRequest: session age $([int]$sessionAge.TotalMinutes)m > ${script:SessionMaxAgeMinutes}m — forcing fresh auth"
            $cacheKey = "$($Session.Upn)::$portalHost"
            if ($script:SessionCache -and $script:SessionCache.ContainsKey($cacheKey)) {
                $cached = $script:SessionCache[$cacheKey]
                if ($cached._Method -and $cached._Credential) {
                    try {
                        $fresh = Connect-MDEPortal -Method $cached._Method -Credential $cached._Credential -PortalHost $portalHost -Force
                        $Session.Session     = $fresh.Session
                        $Session.AcquiredUtc = $fresh.AcquiredUtc
                    } catch {
                        Write-Warning "Invoke-MDEPortalRequest: proactive TTL refresh failed — continuing with old session (will retry on 401): $($_.Exception.Message)"
                    }
                }
            }
        }
    }

    $invoke = {
        param($retry)
        $xsrf = Update-XsrfToken -Session $Session.Session -PortalHost $portalHost
        # v0.1.0-beta: default-header set minimised to match XDRInternals v1.0.3
        # exactly (only X-XSRF-TOKEN). Previously we also sent Accept +
        # X-Requested-With headers, which the portal's XSPM / Antivirus / MTO /
        # TVM endpoints reject with 400 Bad Request. ContentType is passed via
        # Invoke-WebRequest -ContentType, which is sufficient for MIME routing.
        # Endpoints that need custom headers (e.g. XSPM's x-tid +
        # x-ms-scenario-name, MTO's mtoproxyurl) supply them via the manifest
        # Headers field which merges on top of this XSRF-only base.
        $headers = @{
            'X-XSRF-TOKEN' = $xsrf
        }

        # Merge caller-supplied headers after defaults so caller values override.
        if ($AdditionalHeaders -and $AdditionalHeaders.Count -gt 0) {
            foreach ($k in $AdditionalHeaders.Keys) {
                $headers[$k] = $AdditionalHeaders[$k]
            }
        }

        $params = @{
            Uri             = $uri
            WebSession      = $Session.Session
            Method          = $Method
            Headers         = $headers
            UseBasicParsing = $true
            TimeoutSec      = $TimeoutSec
            ErrorAction     = 'Stop'
        }
        if ($Body) {
            $ct = if ($ContentType) { $ContentType } else { 'application/json' }
            $params.ContentType = $ct
            $params.Body = if ($Body -is [hashtable] -or $Body -is [pscustomobject]) {
                $Body | ConvertTo-Json -Depth 10 -Compress
            } else {
                $Body
            }
        }

        Invoke-WebRequest @params
    }

    # Rate-limit retry loop — 429 Retry-After honoured with jitter, up to 3
    # attempts, then throw. Each 429 increments $script:Rate429Count regardless
    # of whether the retry eventually succeeds — operators want visibility on
    # "we got throttled" not just "we failed".
    $rateLimitAttempts = 0
    $maxRateLimitAttempts = 3

    while ($true) {
        try {
            $resp = & $invoke $false
            break  # success — exit retry loop
        } catch [System.Net.WebException], [Microsoft.PowerShell.Commands.HttpResponseException] {
            $status = $_.Exception.Response.StatusCode
            $statusInt = try { [int]$status } catch { 0 }

            # 429 Too Many Requests — backoff with Retry-After + jitter.
            if ($statusInt -eq 429) {
                $script:Rate429Count++
                if ($rateLimitAttempts -ge $maxRateLimitAttempts) {
                    throw "[MDERateLimited] 429 Too Many Requests persisted after $maxRateLimitAttempts retries for $uri. Increment Rate429Count=$($script:Rate429Count)."
                }
                $retryAfterHeader = $null
                try { $retryAfterHeader = $_.Exception.Response.Headers['Retry-After'] } catch {}
                $waitMs = if ($retryAfterHeader -match '^\d+$') {
                    [int]$retryAfterHeader * 1000
                } elseif ($retryAfterHeader) {
                    try {
                        $retryAt = [datetime]::Parse($retryAfterHeader).ToUniversalTime()
                        [math]::Max(0, ($retryAt - [datetime]::UtcNow).TotalMilliseconds)
                    } catch { 5000 }
                } else {
                    # No header → default to 5s × attempt (exponential-ish)
                    5000 * ([math]::Max(1, $rateLimitAttempts))
                }
                $waitMs = [int]$waitMs + (Get-Random -Minimum 100 -Maximum 500)
                Write-Warning "Invoke-MDEPortalRequest: 429 Too Many Requests for $uri — sleeping ${waitMs}ms (attempt $($rateLimitAttempts+1)/$maxRateLimitAttempts, Retry-After='$retryAfterHeader')"
                Start-Sleep -Milliseconds $waitMs
                $rateLimitAttempts++
                continue
            }

            # Portal emits TWO "session is no good" signals that we must treat as
            # "reauth needed":
            #   401 Unauthorized    - classic Entra rejection
            #   440 Session timeout - Microsoft-specific "your sccauth expired" status
            # 403 Forbidden is NOT a reauth signal — it means "authenticated but
            # not permitted" (e.g. service account missing Defender role). Surface
            # 403 to caller unchanged so they can fix permissions, not spin on retry.
            $needsReauth = ($statusInt -in @(401, 440)) -or
                           ($status -eq 'Unauthorized') -or
                           ($_.Exception.Message -match 'Session timeout|sccauth expired')

            if ($needsReauth) {
                Write-Verbose "Invoke-MDEPortalRequest: HTTP $statusInt — attempting auto-refresh + retry"

                # Look up the cached credential and force a fresh auth chain
                $cacheKey = "$($Session.Upn)::$portalHost"
                if ($script:SessionCache.ContainsKey($cacheKey)) {
                    $cached = $script:SessionCache[$cacheKey]
                    if ($cached._Method -and $cached._Credential) {
                        $fresh = Connect-MDEPortal -Method $cached._Method -Credential $cached._Credential -PortalHost $portalHost -Force
                        # Replace the caller's session in-place
                        $Session.Session     = $fresh.Session
                        $Session.AcquiredUtc = $fresh.AcquiredUtc
                        # Retry once with the fresh session
                        try {
                            $resp = & $invoke $true
                            break
                        } catch {
                            throw "Retry after auto-refresh also failed: $($_.Exception.Message). Check that credentials are still valid."
                        }
                    } else {
                        throw "Session 401 and no cached credentials for auto-refresh (session may be from Connect-MDEPortalWithCookies). Re-run Initialize-XdrLogRaiderAuth.ps1 to refresh cookies."
                    }
                } else {
                    throw "Session 401 but no cached session for Upn=$($Session.Upn). Call Connect-MDEPortal before retrying."
                }
            } else {
                throw
            }
        }
    }

    if ($resp.Content) {
        try {
            return $resp.Content | ConvertFrom-Json -Depth 20
        } catch {
            # Non-JSON response — return raw
            return $resp.Content
        }
    }
    return $null
}

# Counter accessor + reset functions moved to separate files per module convention:
#   Public/Get-XdrPortalRate429Count.ps1
#   Public/Reset-XdrPortalRate429Count.ps1
# They share the same module scope and read/write $script:Rate429Count above.
