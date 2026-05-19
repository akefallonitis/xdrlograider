# Xdr.Poll.psm1 — Defender XDR /apiproxy/ endpoint poll wrapper
#
# Public:
#   Invoke-DefenderApiproxy  — wrapped HTTP call to /apiproxy/<svc>/<path>
#   Test-ApiproxyPathPrefix  — pure validator; used by Gate O too
#
# Bug classes locked by this module:
#   /apiproxy/ prefix missing  → 96.8% of v2 endpoints returned HTML SPA shell
#   B-8 HTML login-redirect    → text/html or <!DOCTYPE marker → AuthLost
#   401 stale cookie           → one silent reauth + retry
#   429 throttling             → respect Retry-After

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ValidApiproxyServices = @(
    'mtp','aatp','mcas','mdi','mtoapi','radius','mdc',
    'm365appprotection','astgws','securityplatform','di','msgraph',
    'shell','medeina','gws','cdssecuritycopilot','arm',
    # 'admin' = portal-services tenant admin command surface (nodoc portal_services.yml:578 · /admin/Beta/{tenantId}/InvokeCommand)
    'admin'
)

# -----------------------------------------------------------------------------
# Test-ApiproxyPathPrefix — pure validator (used by Gate O + runtime)
# -----------------------------------------------------------------------------
function Test-ApiproxyPathPrefix {
    [CmdletBinding()][OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)
    $services = $script:ValidApiproxyServices -join '|'
    $Path -match "^/apiproxy/($services)/"
}

# -----------------------------------------------------------------------------
# Invoke-DefenderApiproxy — the only HTTP path for /apiproxy/ endpoints
# -----------------------------------------------------------------------------
function Invoke-DefenderApiproxy {
    [CmdletBinding()][OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Session,
        [ValidateSet('GET','POST')][string]$Method = 'GET',
        $Body,
        [hashtable]$Headers = @{},
        [hashtable]$Query   = @{},       # ITER5 C1 · Postman-derived query params per entry
        [hashtable]$PathParams = @{},    # ITER5 C3 · {xxx} placeholder substitutions (subscriptionId · tenantId · workspaceName · etc.)
        [int]$MaxRetries = 1,
        [string]$BaseUri = 'https://security.microsoft.com'
    )

    # Gate O — runtime defense in depth. Reject paths without /apiproxy/<svc>/ prefix.
    if (-not (Test-ApiproxyPathPrefix -Path $Path)) {
        throw "Invoke-DefenderApiproxy: path '$Path' missing /apiproxy/<service>/ prefix. " +
              "Valid services: $($script:ValidApiproxyServices -join ', '). " +
              "Use Test-ApiproxyPathPrefix in Build-Manifest to lock this at CI time."
    }

    # ITER5 C3 · Path-param substitution · replace {key} with $PathParams[$key]
    # ITER6 R2 · GRACEFUL skip instead of throw when placeholders unresolved · caller (run.ps1) treats
    # the returned status=-2 "path-param-missing" as soft-skip + Runtime.PathParamMissing telemetry.
    # Throwing here previously caused 3-failure cascade → circuit OPEN per sub-area for ~110 entries.
    if ($Path -match '\{[^}]+\}') {
        $resolvedPath = $Path
        $unresolved = @()
        foreach ($m in [regex]::Matches($Path, '\{([^}]+)\}')) {
            $placeholder = $m.Groups[1].Value
            if ($PathParams.ContainsKey($placeholder) -and -not [string]::IsNullOrWhiteSpace([string]$PathParams[$placeholder])) {
                $resolvedPath = $resolvedPath.Replace('{' + $placeholder + '}', [string]$PathParams[$placeholder])
            } else { $unresolved += $placeholder }
        }
        if ($unresolved.Count -gt 0) {
            # Soft-return · caller logs Runtime.PathParamMissing + soft-skips · does NOT trip circuit
            return [pscustomobject]@{
                Path             = $Path
                StatusCode       = -2     # sentinel · run.ps1 treats as path-param-missing
                IsHtml           = $false
                Parsed           = $null
                RawContent       = ''
                Headers          = $null
                Attempts         = 0
                Reauthed         = $false
                UnresolvedParams = $unresolved
            }
        }
        $Path = $resolvedPath
    }

    # ITER6 D2 · Accept header · manifest Headers wins (Postman canonical may be text/csv for export endpoints).
    # Only default to application/json when manifest didn't set one. Prior code unconditionally set application/json
    # which silently dropped CSV responses (parsed=null → live-empty classification).
    if (-not $Headers.ContainsKey('Accept')) { $Headers['Accept'] = 'application/json' }

    # XSRF header rotation — copy current XSRF-TOKEN cookie value into header.
    $xsrf = $null
    try {
        $xsrf = ($Session.Cookies.GetAllCookies() | Where-Object Name -eq 'XSRF-TOKEN' | Select-Object -First 1).Value
    } catch { $xsrf = $null }
    if ($xsrf) { $Headers['X-XSRF-TOKEN'] = [System.Web.HttpUtility]::UrlDecode($xsrf) }

    # ITER5 C1 · Query-param injection · append manifest Query (from Postman fallback) to URL
    $uri = $BaseUri.TrimEnd('/') + $Path
    if ($Query -and $Query.Count -gt 0) {
        $qsBuilder = [System.Collections.Generic.List[string]]::new()
        foreach ($k in $Query.Keys) {
            $kEnc = [uri]::EscapeDataString([string]$k)
            $vEnc = [uri]::EscapeDataString([string]$Query[$k])
            [void]$qsBuilder.Add("$kEnc=$vEnc")
        }
        $sep = if ($uri.Contains('?')) { '&' } else { '?' }
        $uri = $uri + $sep + ($qsBuilder -join '&')
    }
    # ITER6 D3 · Content-Type ONLY for methods that have a body. GET endpoints rejecting CT-on-empty-body
    # contributed to error-400 noise on /apiproxy/mtp/* in lab probe.
    $hasBody = ($Method -in 'POST','PATCH','PUT') -and ($null -ne $Body)
    $effectiveCt = if ($hasBody) { 'application/json' } else { $null }
    $attempt = 0
    $authReauthed = $false
    do {
        $attempt++
        $authHttpArgs = @{
            Uri = $uri; Method = $Method; Headers = $Headers; Body = $Body
            Session = $Session; MaximumRedirection = 0
        }
        if ($effectiveCt) { $authHttpArgs.ContentType = $effectiveCt }
        $response = Invoke-XdrAuthHttp @authHttpArgs

        # B-8 HTML sniff — apiproxy expected to return JSON; HTML body means auth lost.
        $isHtml = $false
        if ($response.Content) {
            $head = ([string]$response.Content).TrimStart()
            $isHtml = $head -match '^<!DOCTYPE|^<html'
            if (-not $isHtml -and $response.Headers) {
                $ct = $null
                try { $ct = $response.Headers['Content-Type'] } catch { }
                if ($ct -and ($ct -join '') -match 'text/html') { $isHtml = $true }
            }
        }

        # ITER6 R4 + R5 · 401 / 440 / HTML at apiproxy → cookie stale.
        # Previously called `Get-XdrAuthFromKeyVault -FromEnvLocal` which throws in production FA
        # (requires XDRLR_TEST_* env vars · only present on operator laptop). Removed.
        # Instead: on second-attempt HTML/401, throw AuthChainBrokenException so the OUTER catch in
        # run.ps1 handles the proper -Force reauth via session-cache · keeps single auth-cascade path.
        $needsReauth = ($response.StatusCode -in 401,440) -or $isHtml
        if ($needsReauth -and -not $authReauthed -and $attempt -le $MaxRetries) {
            Write-Verbose "Invoke-DefenderApiproxy: stale session (status=$($response.StatusCode), html=$isHtml). Retry once."
            $authReauthed = $true
            continue   # ITER6 R4 · simple retry · let outer cycle handle reauth via AuthChainBrokenException below
        }
        if ($needsReauth -and $authReauthed) {
            # ITER6 R5 · 2nd attempt also HTML/401 · throw structured exception · run.ps1 outer catch
            # owns the -Force reauth + retry-once pattern (Auth.MidCycleReauth telemetry · Π11.5f).
            $stage = if ($isHtml) { 'PortalRequest.HtmlAtJson' } else { "PortalRequest.HttpStatus.$($response.StatusCode)" }
            throw [AuthChainBrokenException]::new("Apiproxy auth chain broken at $stage (path=$Path · attempts=$attempt)", $stage, [int]$response.StatusCode)
        }

        # 429 → backoff per Retry-After (cap 60s for safety).
        if ($response.StatusCode -eq 429 -and $attempt -le $MaxRetries) {
            $delay = 5
            if ($response.Headers -and $response.Headers['Retry-After']) {
                $ra = [string]($response.Headers['Retry-After'])
                if ($ra -match '^\d+$') { $delay = [math]::Min(60, [int]$ra) }
            }
            Write-Verbose "Invoke-DefenderApiproxy: 429 throttle; sleeping ${delay}s"
            Start-Sleep -Seconds $delay
            continue
        }

        # Success path — parse JSON; fall back to raw on parse failure.
        $parsed = $null
        if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300 -and -not $isHtml) {
            try { $parsed = $response.Content | ConvertFrom-Json -Depth 100 -AsHashtable } catch { $parsed = $null }
        }

        return [pscustomobject]@{
            Path        = $Path
            StatusCode  = $response.StatusCode
            IsHtml      = $isHtml
            Parsed      = $parsed
            RawContent  = [string]$response.Content
            Headers     = $response.Headers
            Attempts    = $attempt
            Reauthed    = $authReauthed
        }
    } while ($attempt -le $MaxRetries + 1)

    throw "Invoke-DefenderApiproxy: exhausted $MaxRetries retries for $Path"
}

# -----------------------------------------------------------------------------
# AuthChainBrokenException + stage-aware HTML classifier (Reinforcement-B · P-1)
# -----------------------------------------------------------------------------
class AuthChainBrokenException : System.Exception {
    [string]$Stage
    [int]$StatusCode
    AuthChainBrokenException([string]$Message, [string]$Stage, [int]$StatusCode) : base($Message) {
        $this.Stage = $Stage
        $this.StatusCode = $StatusCode
    }
}

# Stages where HTML response is EXPECTED (auth-chain in flight · login pages · KMSI · form_post)
$script:AuthChainStages = @('Authorize','CredentialPost','BeginAuth','EndAuth','KmsiInterrupt','FormPost')

# Stages where HTML response means BROKEN CHAIN (data stages · should return JSON)
$script:DataStages = @('PortalRequest','TenantContext','Apiproxy','OAuthToken','BearerPortalApi')

function Test-AuthChainHtmlResponse {
    <#
    .SYNOPSIS
        Stage-aware HTML classifier · returns 'expected' for auth-chain stages and 'broken' for data stages.
    .DESCRIPTION
        Reinforcement-B: HTML during auth-chain stages is expected (login SPA · KMSI · form_post).
        HTML during data stages is auth-chain failure → caller throws AuthChainBrokenException.
    #>
    [CmdletBinding()][OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ContentSnippet
    )
    $isHtml = ($ContentSnippet.TrimStart() -match '^<!DOCTYPE|^<html')
    if (-not $isHtml) { return 'not-html' }
    if ($Stage -in $script:AuthChainStages) { return 'expected' }
    if ($Stage -in $script:DataStages)      { return 'broken' }
    return 'unknown-stage'
}

# -----------------------------------------------------------------------------
# Invoke-XdrPortalRequest facade · cookie | bearer dispatch (P-1)
# -----------------------------------------------------------------------------
function Invoke-XdrPortalRequest {
    <#
    .SYNOPSIS
        Auth-aware dispatcher · routes request through cookie (Defender/Purview) or bearer (Entra/Intune/SecurityCopilot).
    .DESCRIPTION
        v0.1.0 minimal · dispatches based on PortalConfig.AuthProfile:
          Cookie → existing Invoke-DefenderApiproxy (Defender) or analogous (Purview · v0.2.0+)
          Bearer → direct HTTP with bearer header (Entra/Intune/SecurityCopilot · v0.2.0+ active)
        Throws AuthChainBrokenException if data-stage response is HTML.
    #>
    [CmdletBinding()][OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$PortalConfigEntry,   # from Get-XdrPortalConfig
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('GET','POST','PUT','DELETE')][string]$Method = 'GET',
        $Body,
        [Parameter(Mandatory)]$Session,                              # cookie session OR bearer token object
        [hashtable]$Headers = @{}
    )

    $stage = 'PortalRequest'
    $authProfile = $PortalConfigEntry.AuthProfile

    if ($authProfile -eq 'Cookie') {
        # Defender + Purview · use existing /apiproxy/ wrapper (Path must include /apiproxy/<svc>/ prefix)
        return Invoke-DefenderApiproxy -Path $Path -Session $Session -Method $Method -Body $Body -Headers $Headers `
            -BaseUri "https://$($PortalConfigEntry.Host)"
    }

    if ($authProfile -eq 'Bearer') {
        # Bearer: $Session is the bearer-token object (AccessToken property)
        $bearer = if ($Session.PSObject.Properties['AccessToken']) { $Session.AccessToken } else { [string]$Session }
        if (-not $bearer) { throw "Invoke-XdrPortalRequest: bearer mode requires Session with AccessToken" }
        $Headers['Authorization'] = "Bearer $bearer"

        # Apply portal-specific ExtraHeaders (Intune x-ms-* etc.)
        if ($PortalConfigEntry.ExtraHeaders) {
            foreach ($k in $PortalConfigEntry.ExtraHeaders.Keys) {
                $v = $PortalConfigEntry.ExtraHeaders[$k]
                if ($v -eq '{NewGuid}') { $v = [Guid]::NewGuid().ToString() }
                $Headers[$k] = $v
            }
        }

        $uri = "https://$($PortalConfigEntry.Host)$Path"
        $resp = Invoke-XdrAuthHttp -Uri $uri -Method $Method -Headers $Headers -Body $Body `
            -ContentType 'application/json'

        # Reinforcement-B · stage-aware HTML sniff at data stage
        $cls = Test-AuthChainHtmlResponse -Stage $stage -ContentSnippet ([string]$resp.Content)
        if ($cls -eq 'broken') {
            throw [AuthChainBrokenException]::new(
                "Bearer data-stage response was HTML (auth chain broken) for $($PortalConfigEntry.Key) at $Path",
                $stage, $resp.StatusCode)
        }

        return [pscustomobject]@{
            Path       = $Path
            StatusCode = $resp.StatusCode
            IsHtml     = ($cls -ne 'not-html')
            RawContent = [string]$resp.Content
            Headers    = $resp.Headers
        }
    }

    throw "Invoke-XdrPortalRequest: unsupported AuthProfile '$authProfile' for portal '$($PortalConfigEntry.Key)'"
}

# -----------------------------------------------------------------------------
# Discover-XdrPortalCapabilities · cold-start hook (Reinforcement-C · P-3)
# -----------------------------------------------------------------------------
$script:CapabilityCache = @{}   # keyed TenantId · 24h TTL · in-memory · Storage Table durable (Invoke-XdrStorageTableEntity at P-4)

function Discover-XdrPortalCapabilities {
    <#
    .SYNOPSIS
        Cold-start capability discovery · per Active portal · per-tenant cache (24h TTL).
    .DESCRIPTION
        Reinforcement-C: FA cold-start invokes this for Get-XdrPortalConfig -ActiveOnly.
        For each Active portal:
          1. Use cached session/token (Connect-*Portal already populated cache)
          2. Call CapabilityEndpoint · parse response · extract product flags
          3. Cache snapshot keyed by TenantId
        v0.1.0: Defender only Active · Reinforcement-C applies but minimal in practice.
        v0.2.0+: 4 more portals activate · cache scales.
    #>
    [CmdletBinding()][OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [int]$TtlHours = 24,
        [switch]$Force
    )

    # Cache hit (within TTL)
    if (-not $Force.IsPresent -and $script:CapabilityCache.ContainsKey($TenantId)) {
        $cached = $script:CapabilityCache[$TenantId]
        if ($cached.ExpiresUtc -gt [datetime]::UtcNow) {
            return $cached
        }
    }

    # Build new snapshot
    $snapshot = @{
        TenantId    = $TenantId
        CapturedUtc = [datetime]::UtcNow
        ExpiresUtc  = [datetime]::UtcNow.AddHours($TtlHours)
        Portals     = @{}
    }

    foreach ($entry in (Get-XdrPortalConfig -ActiveOnly)) {
        # Minimal v0.1.0 · capability flag stub · operator probe at 0g populates real flags
        $snapshot.Portals[$entry.Key] = @{
            Reachable          = $true       # default · operator probe overrides
            CapabilityEndpoint = $entry.CapabilityEndpoint
            ProductsAvailable  = @()         # populated when capability endpoint queried
        }
    }

    $script:CapabilityCache[$TenantId] = $snapshot
    return $snapshot
}

function Test-XdrEndpointAllowedByCapabilities {
    <#
    .SYNOPSIS
        RequiresProducts filter · v0.1.0 BYPASSED · returns $true unconditionally.
    .DESCRIPTION
        Per-cycle iteration filter. In v0.2.0 this will check if endpoint's RequiresProducts
        intersects the dynamic CapabilitySnapshot.Portals.*.ProductsAvailable array.

        v0.1.0 BYPASS rationale:
        Discover-XdrPortalCapabilities (this module L239-286) is currently a stub that
        always returns ProductsAvailable=@() · so the filter would reject all 410 entries
        with non-empty RequiresProducts (CloudApps · Identity · MDE-licensed sub-areas).
        Until real capability discovery is implemented (v0.2.0) we bypass: every endpoint
        attempts naturally at runtime · the API itself returns 401/403/404 if license-blocked
        · DLQ catches errors · operator sees real per-endpoint behavior in the workspace.

        This bypass is operator-explicit decision (Π11 · session 2026-05-19): rather than
        ship a fake filter that hides legitimate endpoints, ship the unfiltered behavior
        and let production tenants' license matrix reveal itself through actual API responses.
    #>
    [CmdletBinding()][OutputType([bool])]
    param(
        [Parameter(Mandatory)][hashtable]$ManifestEntry,
        [Parameter(Mandatory)][hashtable]$CapabilitySnapshot
    )
    # v0.1.0 BYPASS · operator-explicit decision
    # v0.2.0 will restore the intersection logic with real ProductsAvailable
    return $true
}

function Clear-XdrCapabilityCache {
    [CmdletBinding()] param()
    $script:CapabilityCache = @{}
}

Export-ModuleMember -Function `
    Invoke-DefenderApiproxy, `
    Test-ApiproxyPathPrefix, `
    Test-AuthChainHtmlResponse, `
    Invoke-XdrPortalRequest, `
    Discover-XdrPortalCapabilities, `
    Test-XdrEndpointAllowedByCapabilities, `
    Clear-XdrCapabilityCache
