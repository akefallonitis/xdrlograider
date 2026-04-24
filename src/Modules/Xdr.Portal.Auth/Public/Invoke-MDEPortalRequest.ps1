function Invoke-MDEPortalRequest {
    <#
    .SYNOPSIS
        Authenticated wrapper around Invoke-WebRequest for Defender XDR portal API calls.

    .DESCRIPTION
        Takes a session from Connect-MDEPortal and automatically adds the X-XSRF-TOKEN
        header with the current (just-rotated) value. Handles 401 transparently by
        forcing a re-auth and retrying once.

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

    $invoke = {
        param($retry)
        $xsrf = Update-XsrfToken -Session $Session.Session -PortalHost $portalHost
        $headers = @{
            'X-XSRF-TOKEN'     = $xsrf
            'Accept'           = 'application/json'
            'X-Requested-With' = 'XMLHttpRequest'
        }

        # Merge caller-supplied headers after defaults so caller values override
        # (enables e.g. XSPM's x-tid + x-ms-scenario-name without losing XSRF).
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

    try {
        $resp = & $invoke $false
    } catch [System.Net.WebException], [Microsoft.PowerShell.Commands.HttpResponseException] {
        $status = $_.Exception.Response.StatusCode
        $statusInt = try { [int]$status } catch { 0 }
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
