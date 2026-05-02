function Invoke-DefenderPortalRequest {
    <#
    .SYNOPSIS
        L2 Defender — authenticated wrapper around Invoke-WebRequest for portal API calls.

    .DESCRIPTION
        Takes a session from Connect-DefenderPortal and automatically adds the
        X-XSRF-TOKEN header with the current (just-rotated) value. Handles 401/440
        transparently by forcing a re-auth and retrying once.

        Hardening (carried forward from v0.1.0-beta):
          * 429 Too Many Requests — parse Retry-After (seconds or HTTP-date), sleep
            + jitter, up to 3 retries. Increments $script:Rate429Count (surfaced
            via Get-XdrPortalRate429Count). On 3rd exhaustion throws an exception
            prefixed '[MDERateLimited]' so callers can regex-match.
          * Session TTL — if cached $Session.AcquiredUtc is older than 3h30m,
            force a fresh Connect-DefenderPortal before the request.
          * 401 / 440 reauth — automatic via cached _Method + _Credential.
          * 403 — surfaces unchanged (not a reauth signal — auth succeeded but
            account lacks permission).
          * Request-count rotation — after 100 requests, force fresh auth chain
            to bound replay-window risk on the cached cookie.

    .PARAMETER Session
        Object returned by Connect-DefenderPortal (pscustomobject with .Session,
        .Upn, etc.).

    .PARAMETER Path
        Portal API path (e.g., '/api/settings/GetAdvancedFeaturesSetting' or
        '/apiproxy/mtp/...'). Caller is responsible for the right prefix.

    .PARAMETER Method
        HTTP method. Default: GET.

    .PARAMETER Body
        Request body (string or hashtable).

    .PARAMETER ContentType
        Defaults to 'application/json' for POST/PUT, omitted for GET.

    .PARAMETER TimeoutSec
        Per-request timeout. Default 60s.

    .PARAMETER AdditionalHeaders
        Optional extra HTTP headers. Merged AFTER X-XSRF-TOKEN so caller-supplied
        values override the default. Used by XSPM endpoints that require x-tid +
        x-ms-scenario-name, MTO endpoints that require mtoproxyurl, etc.

    .OUTPUTS
        [pscustomobject] parsed JSON response body.

    .EXAMPLE
        $session = Connect-DefenderPortal -Method CredentialsTotp -Credential $creds
        Invoke-DefenderPortalRequest -Session $session -Path '/api/settings/GetAdvancedFeaturesSetting'

    .EXAMPLE
        # XSPM call with required scenario-name + tenant-id headers
        Invoke-DefenderPortalRequest -Session $session `
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

    # iter-14.0 Phase 14B: reuse the auth-chain CorrelationId stamped by
    # Connect-DefenderPortal so the AI end-to-end transaction view stitches
    # auth -> portal request -> 429-retry -> 401-reauth on a single op id.
    # Falls back to a fresh GUID for sessions built via
    # Connect-DefenderPortalWithCookies (no auth chain ran).
    $correlationId = $null
    if ($Session.PSObject.Properties['CorrelationId'] -and $Session.CorrelationId) {
        $correlationId = [string]$Session.CorrelationId
    } else {
        $correlationId = [Guid]::NewGuid().ToString()
    }

    # Path is used as-is. Caller is responsible for the right prefix — some APIs
    # live under /api/..., some under /apiproxy/mtp/..., some under /apiproxy/ngp/....
    # Our endpoints manifest knows the correct base for each stream.
    if ($Path -notmatch '^/') { $Path = "/$Path" }
    $uri = "https://$portalHost$Path"

    # Count-based rotation. Forces a fresh auth chain after 100 requests to cap
    # replay-window risk on the cached sccauth cookie if the FA process is compromised.
    $script:RequestCount++
    $countTriggeredRotation = ($script:RequestCount -ge $script:RequestCountRotationThreshold)
    if ($countTriggeredRotation) {
        Write-Verbose "Invoke-DefenderPortalRequest: request count $($script:RequestCount) >= $($script:RequestCountRotationThreshold) — forcing fresh auth"
        $script:RequestCount = 0
    }

    # Session TTL check — proactively refresh at 3h30m to stay well under the
    # undocumented ~4h portal session cap. Reactive 401/440 reauth still runs
    # below as a safety net for tenants with shorter TTL.
    $needsRotation = $countTriggeredRotation
    $proactiveReason = if ($countTriggeredRotation) { 'count-based' } else { $null }
    $sessionAgeMin = 0
    if ($Session.PSObject.Properties['AcquiredUtc'] -and $null -ne $Session.AcquiredUtc) {
        $sessionAge = [datetime]::UtcNow - $Session.AcquiredUtc
        $sessionAgeMin = [int]$sessionAge.TotalMinutes
        if ($sessionAge.TotalMinutes -gt $script:SessionMaxAgeMinutes) {
            Write-Verbose "Invoke-DefenderPortalRequest: session age $([int]$sessionAge.TotalMinutes)m > ${script:SessionMaxAgeMinutes}m — forcing fresh auth"
            $needsRotation = $true
            if (-not $proactiveReason) { $proactiveReason = 'time-based' }
        }
    }
    if ($needsRotation -and $Session.PSObject.Properties['AcquiredUtc']) {
        if (Get-Command -Name Send-XdrAppInsightsCustomEvent -ErrorAction SilentlyContinue) {
            Send-XdrAppInsightsCustomEvent -EventName 'AuthChain.ProactiveRefresh' -OperationId $correlationId -Properties @{
                Upn             = [string]$Session.Upn
                PortalHost      = $portalHost
                Path            = $Path
                CacheAgeMinutes = $sessionAgeMin
                Reason          = if ($proactiveReason) { $proactiveReason } else { 'time-based' }
            }
        }
        $cacheKey = "$($Session.Upn)::$portalHost"
        if ($script:SessionCache -and $script:SessionCache.ContainsKey($cacheKey)) {
            $cached = $script:SessionCache[$cacheKey]
            $hasReauthInfo = $false
            if ($cached -is [System.Collections.IDictionary]) {
                $hasReauthInfo = $cached.Contains('_Method') -and $cached.Contains('_Credential') -and $cached['_Method'] -and $cached['_Credential']
            } elseif ($cached.PSObject.Properties['_Method'] -and $cached.PSObject.Properties['_Credential']) {
                $hasReauthInfo = $null -ne $cached._Method -and $null -ne $cached._Credential
            }
            if ($hasReauthInfo) {
                try {
                    $fresh = Connect-DefenderPortal -Method $cached._Method -Credential $cached._Credential -PortalHost $portalHost -Force
                    $Session.Session     = $fresh.Session
                    $Session.AcquiredUtc = $fresh.AcquiredUtc
                } catch {
                    Write-Warning "Invoke-DefenderPortalRequest: proactive TTL refresh failed — continuing with old session (will retry on 401): $($_.Exception.Message)"
                }
            }
        }
    }

    $invoke = {
        param($retry)
        $xsrf = Update-XsrfToken -Session $Session.Session -PortalHost $portalHost
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

        # v0.1.0-beta production-readiness polish: wrap the actual outgoing
        # request in TrackDependency so AI's end-to-end transaction view shows
        # each portal call (with retries appearing as separate dependency
        # records on the same OperationId). Stopwatch captures wall-clock
        # latency; success/resultCode are derived from the HTTP outcome.
        # SAFE-NULL: if Send-XdrAppInsightsDependency isn't loadable (cold-import
        # window) we skip the emission; the original invoke still proceeds.
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $depSuccess = $false
        $depResultCode = 0
        try {
            $resp = Invoke-WebRequest @params
            $depSuccess = $true
            $depResultCode = if ($resp -and $resp.PSObject.Properties['StatusCode']) { [int]$resp.StatusCode } else { 200 }
            return $resp
        } catch {
            $depSuccess = $false
            if ($null -ne $_.Exception -and
                $_.Exception.PSObject.Properties['Response'] -and
                $null -ne $_.Exception.Response -and
                $_.Exception.Response.PSObject.Properties['StatusCode']) {
                try { $depResultCode = [int]$_.Exception.Response.StatusCode } catch { $depResultCode = 0 }
            }
            throw
        } finally {
            $sw.Stop()
            if (Get-Command -Name Send-XdrAppInsightsDependency -ErrorAction SilentlyContinue) {
                Send-XdrAppInsightsDependency `
                    -Target      $portalHost `
                    -Name        $Path `
                    -Success     $depSuccess `
                    -DurationMs  ([int]$sw.ElapsedMilliseconds) `
                    -ResultCode  $depResultCode `
                    -Type        'HTTP' `
                    -OperationId $correlationId `
                    -Properties  @{
                        Method  = $Method
                        Retry   = [string]$retry
                    }
            }
        }
    }

    # Rate-limit retry loop — 429 Retry-After honoured with jitter, up to 3 attempts.
    $rateLimitAttempts = 0
    $maxRateLimitAttempts = 3

    while ($true) {
        try {
            $resp = & $invoke $false
            break  # success
        } catch [System.Net.WebException], [Microsoft.PowerShell.Commands.HttpResponseException] {
            $status = $null
            if ($null -ne $_.Exception -and
                $_.Exception.PSObject.Properties['Response'] -and
                $null -ne $_.Exception.Response -and
                $_.Exception.Response.PSObject.Properties['StatusCode']) {
                $status = $_.Exception.Response.StatusCode
            }
            $statusInt = try { [int]$status } catch { 0 }

            # 429 Too Many Requests — backoff with Retry-After + jitter.
            if ($statusInt -eq 429) {
                $script:Rate429Count++
                # v0.1.0-beta production-readiness polish: per-call 429 metric so
                # operators can chart per-stream throttle pressure (alongside
                # the cumulative Rate429Count surfaced via the heartbeat).
                if (Get-Command -Name Send-XdrAppInsightsCustomMetric -ErrorAction SilentlyContinue) {
                    Send-XdrAppInsightsCustomMetric -MetricName 'xdr.portal.rate429_count' -Value 1.0 `
                        -Properties @{ Path = $Path } -OperationId $correlationId
                }
                if ($rateLimitAttempts -ge $maxRateLimitAttempts) {
                    if (Get-Command -Name Send-XdrAppInsightsCustomEvent -ErrorAction SilentlyContinue) {
                        Send-XdrAppInsightsCustomEvent -EventName 'AuthChain.RateLimited' -OperationId $correlationId -Properties @{
                            Path             = $Path
                            RetryAttempt     = $rateLimitAttempts
                            RetryAfterMs     = 0
                            Rate429CountTotal = [int]$script:Rate429Count
                            Outcome          = 'exhausted'
                        }
                    }
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
                    5000 * ([math]::Max(1, $rateLimitAttempts))
                }
                $waitMs = [int]$waitMs + (Get-Random -Minimum 100 -Maximum 500)
                Write-Warning "Invoke-DefenderPortalRequest: 429 Too Many Requests for $uri — sleeping ${waitMs}ms (attempt $($rateLimitAttempts+1)/$maxRateLimitAttempts, Retry-After='$retryAfterHeader')"
                if (Get-Command -Name Send-XdrAppInsightsCustomEvent -ErrorAction SilentlyContinue) {
                    Send-XdrAppInsightsCustomEvent -EventName 'AuthChain.RateLimited' -OperationId $correlationId -Properties @{
                        Path             = $Path
                        RetryAttempt     = ($rateLimitAttempts + 1)
                        RetryAfterMs     = [int]$waitMs
                        Rate429CountTotal = [int]$script:Rate429Count
                        Outcome          = 'retrying'
                    }
                }
                Start-Sleep -Milliseconds $waitMs
                $rateLimitAttempts++
                continue
            }

            # 401 Unauthorized + 440 Session timeout = "reauth needed" signals.
            # 403 Forbidden ≠ reauth (means authenticated but unauthorized).
            $needsReauth = ($statusInt -in @(401, 440)) -or
                           ($status -eq 'Unauthorized') -or
                           ($_.Exception.Message -match 'Session timeout|sccauth expired')

            if ($needsReauth) {
                Write-Verbose "Invoke-DefenderPortalRequest: HTTP $statusInt — attempting auto-refresh + retry"
                if (Get-Command -Name Send-XdrAppInsightsCustomEvent -ErrorAction SilentlyContinue) {
                    $reauthReason = if ($statusInt -eq 401) { '401' }
                                    elseif ($statusInt -eq 440) { '440' }
                                    elseif ($_.Exception.Message -match 'sccauth expired|Session timeout') { 'CAE-revoked' }
                                    else { '401' }
                    Send-XdrAppInsightsCustomEvent -EventName 'AuthChain.Reauth' -OperationId $correlationId -Properties @{
                        Path   = $Path
                        Reason = $reauthReason
                    }
                }

                $cacheKey = "$($Session.Upn)::$portalHost"
                if ($script:SessionCache.ContainsKey($cacheKey)) {
                    $cached = $script:SessionCache[$cacheKey]
                    $hasReauthInfo = $false
                    if ($cached -is [System.Collections.IDictionary]) {
                        $hasReauthInfo = $cached.Contains('_Method') -and $cached.Contains('_Credential') -and $cached['_Method'] -and $cached['_Credential']
                    } elseif ($cached.PSObject.Properties['_Method'] -and $cached.PSObject.Properties['_Credential']) {
                        $hasReauthInfo = $null -ne $cached._Method -and $null -ne $cached._Credential
                    }
                    if ($hasReauthInfo) {
                        $fresh = Connect-DefenderPortal -Method $cached._Method -Credential $cached._Credential -PortalHost $portalHost -Force
                        $Session.Session     = $fresh.Session
                        $Session.AcquiredUtc = $fresh.AcquiredUtc
                        try {
                            $resp = & $invoke $true
                            break
                        } catch {
                            # v0.1.0-beta production-readiness polish: TrackException
                            # for the post-reauth-retry failure case so AI's
                            # exceptions table catches the auth-recovery dead-end
                            # with a stitched OperationId.
                            if (Get-Command -Name Send-XdrAppInsightsException -ErrorAction SilentlyContinue) {
                                Send-XdrAppInsightsException -Exception $_.Exception `
                                    -SeverityLevel 'Error' `
                                    -OperationId $correlationId `
                                    -Properties @{
                                        Path   = $Path
                                        Phase  = 'portal-retry-after-reauth'
                                    }
                            }
                            throw "Retry after auto-refresh also failed: $($_.Exception.Message). Check that credentials are still valid."
                        }
                    } else {
                        throw "Session 401 and no cached credentials for auto-refresh (session may be from Connect-DefenderPortalWithCookies). Re-run Initialize-XdrLogRaiderAuth.ps1 to refresh cookies."
                    }
                } else {
                    throw "Session 401 but no cached session for Upn=$($Session.Upn). Call Connect-DefenderPortal before retrying."
                }
            } else {
                # v0.1.0-beta production-readiness polish: emit TrackException
                # for non-reauth, non-429 errors before re-throwing so the
                # Defender portal failure mode (4xx other than 401/440, DNS,
                # TLS, timeout) lands in AI's exceptions table.
                if (Get-Command -Name Send-XdrAppInsightsException -ErrorAction SilentlyContinue) {
                    Send-XdrAppInsightsException -Exception $_.Exception `
                        -SeverityLevel 'Warning' `
                        -OperationId $correlationId `
                        -Properties @{
                            Path        = $Path
                            HttpStatus  = [string]$statusInt
                            Phase       = 'portal-request-non-reauth'
                        }
                }
                throw
            }
        }
    }

    if ($resp.Content) {
        try {
            return $resp.Content | ConvertFrom-Json -Depth 20
        } catch {
            return $resp.Content
        }
    }
    return $null
}
