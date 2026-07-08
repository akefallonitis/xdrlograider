# XdrLogRaider · Xdr.Common.OAuthBearer module
# Bearer-token acquisition for Entra/Intune/SecurityCopilot via AUTHORIZATION-CODE over the SAME
# interactive cookie-OIDC + TOTP/Passkey ESTS chain the cookie portals use (plan §36.1/§37 · NOT ROPC).
# ROPC (grant_type=password) CANNOT satisfy interactive MFA (AADSTS50076) and is rejected on /common
# (AADSTS9001023) — both live-confirmed. The portals' bearer tokens are obtained the way the browser does:
# authorize(response_type=code, response_mode=form_post) → MFA → form_post → extract `code` → token exchange.
#
# Flow (Get-XdrOAuthToken):
# 1. L1/L2 cache hit (alive access_token) → return.
# 2. refresh_token fast-path (grant_type=refresh_token · ~14d · NO TOTP) → return. [silent reauth]
# 3. Full: PKCE → Get-XdrEntraEstsAuth -AuthProfile Bearer (shared ESTS+MFA · Xdr.Defender.Auth) →
#    extract auth code from FinalHtml → POST token (v2: scope=<aud>/.default | v1: resource=<aud>;
#    grant_type=authorization_code · code_verifier · redirect_uri) → access_token + refresh_token.
# 4. Cache (L1 + L2 XdrTierState keyed Portal::SubPortal::UPN) so refresh_token sustains silently.

Set-StrictMode -Version Latest

$script:TokenCache = @{}                   # in-memory L1 · keyed "<portal>::<subportal>::<upn>"
$script:TokenSemaphore = [System.Threading.SemaphoreSlim]::new(1, 1)
$script:RequestCount = 0

# ─── PKCE pair (RFC 7636 · S256) ─────────────────────────────────────────────────
function script:Get-XdrPkcePair {
    $bytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $verifier = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($verifier)) } finally { $sha.Dispose() }
    $challenge = [Convert]::ToBase64String($hash).TrimEnd('=').Replace('+','-').Replace('/','_')
    return [pscustomobject]@{ Verifier = $verifier; Challenge = $challenge }
}

# ─── Extract auth `code` from the terminal form_post HTML (bearer chain · §36.1 step 3) ──
function script:Get-XdrAuthCodeFromHtml {
    [CmdletBinding()] param([Parameter(Mandatory)][AllowEmptyString()][string] $Html)
    if ([string]::IsNullOrWhiteSpace($Html)) { return '' }
    $m = [regex]::Match($Html, 'name="code"\s+value="([^"]+)"')
    if (-not $m.Success) { $m = [regex]::Match($Html, "name='code'\s+value='([^']+)'") }
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

function Get-XdrOAuthToken {
    <#
    .SYNOPSIS
    Obtain (or refresh) an OAuth bearer token for a non-Defender portal.

    .PARAMETER Portal
    Portal name (Entra · Intune · SecurityCopilot).

    .PARAMETER SubPortal
    Sub-portal key (e.g. IAM · PIM · Portal · Autopatch · api).

    .PARAMETER Audience
    Token audience (e.g. https://graph.microsoft.com or https://main.iam.ad.ext.azure.com).

    .PARAMETER ClientId
    Public client ID (Microsoft well-known · e.g. 74658136-... Azure Portal · 0000000a-... Intune).

    .PARAMETER Credentials
    Hashtable with UPN · Password · TenantId · AuthMethod · TotpSeed/PasskeyPem.

    .PARAMETER Force
    Skip cache · force refresh from token endpoint.

    .OUTPUTS
    Hashtable @{ AccessToken; RefreshToken; ExpiresUtc; TokenType='Bearer'; Audience; Scope; UPN; Portal; SubPortal }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [ValidateSet('Entra','Intune','SecurityCopilot')] [string] $Portal,
        [Parameter(Mandatory)] [string] $SubPortal,
        [Parameter(Mandatory)] [string] $Audience,
        [Parameter(Mandatory)] [string] $ClientId,
        [Parameter(Mandatory)] [hashtable] $Credentials,
        [Parameter(Mandatory)] [string] $RedirectUri,   # MUST be registered on the public client (else AADSTS50011)
        [string] $Resource,                              # v1 token endpoint resource (admin sub-portals · §36.1)
        [ValidateSet('v1','v2')][string] $AuthVersion = 'v2',
        [ValidateSet('PublicClient','SPA')][string] $ClientType = 'PublicClient',  # SPA → Origin header on /token (Decision D-39 · AADSTS9002327 guard)
        [switch] $Force
    )

    if (-not $Credentials.UPN)     { throw 'Get-XdrOAuthToken: UPN missing' }
    if (-not $Credentials.Password){ throw 'Get-XdrOAuthToken: Password missing' }
    # ROPC (grant_type=password) is REJECTED on the /common and /consumers endpoints (AADSTS9001023 ·
    # confirmed live by Probe-FullChain-Local -AllPortals). It requires a tenant-specific OR the
    # /organizations endpoint. Production passes a real TenantId (ARM sets XDRLR_TENANT_ID =
    # subscription().tenantId · §24.3 C2); the fallback must be 'organizations', NOT 'common'.
    $tenantId = if ([string]::IsNullOrWhiteSpace([string]$Credentials['TenantId'])) { 'organizations' } else { [string]$Credentials['TenantId'] }
    $cacheKey = "${Portal}::${SubPortal}::$($Credentials.UPN)"

    Track-XdrEvent -Name "$Portal.OAuth.Started" -Properties @{ SubPortal = $SubPortal; UPN = $Credentials.UPN; Force = $Force.IsPresent }

    # ─── L1 cache hit ────────────────────────────────────────────────────────
    if (-not $Force.IsPresent -and $script:TokenCache.ContainsKey($cacheKey)) {
        $cached = $script:TokenCache[$cacheKey]
        try {
            $expiry = (ConvertTo-XdrUtc $cached.ExpiresUtc)
            if ($expiry -gt [DateTime]::UtcNow.AddMinutes(5)) {
                Track-XdrEvent -Name "$Portal.OAuth.CacheHit" -Properties @{ SubPortal = $SubPortal }
                return $cached
            }
        } catch { <# Expiry parse failure → fall through to fresh-fetch · INTENTIONAL-FAIL-SAFE #> }
    }

    # ─── Single-flight gate ──────────────────────────────────────────────────
    $entered = $script:TokenSemaphore.Wait([TimeSpan]::FromSeconds(30))
    if (-not $entered) { throw 'Get-XdrOAuthToken: semaphore timeout' }

    try {
        # Re-check L1 after acquiring (another thread may have refreshed)
        if (-not $Force.IsPresent -and $script:TokenCache.ContainsKey($cacheKey)) {
            $cached = $script:TokenCache[$cacheKey]
            try {
                $expiry = (ConvertTo-XdrUtc $cached.ExpiresUtc)
                if ($expiry -gt [DateTime]::UtcNow.AddMinutes(5)) { return $cached }
            } catch { <# Expiry parse failure → fall through to fresh-fetch · INTENTIONAL-FAIL-SAFE #> }
        }

        # L2 cache (Storage Table)
        $session = Get-XdrCachedSession -Portal $Portal -UPN "${SubPortal}::$($Credentials.UPN)"
        $useRefreshToken = $false
        $refreshToken = $null
        if (-not $Force.IsPresent -and $session -and $session.RefreshToken) {
            $useRefreshToken = $true
            $refreshToken = $session.RefreshToken
        }

        # ─── Build token request (version-aware · §36.1) ─────────────────────
        $tokenEndpoint = if ($AuthVersion -eq 'v1') { "https://login.microsoftonline.com/$tenantId/oauth2/token" }
                         else { "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" }
        $scope = "$Audience/.default openid profile offline_access"
        $body = @{ client_id = $ClientId }
        if ($AuthVersion -eq 'v1') {
            $body.resource = if (-not [string]::IsNullOrWhiteSpace($Resource)) { $Resource } else { $Audience }
        } else {
            $body.scope = $scope
        }

        if ($useRefreshToken) {
            # ─── Silent reauth · refresh_token (~14d · NO TOTP · D-REAUTH) ───
            $body.grant_type    = 'refresh_token'
            $body.refresh_token = $refreshToken
        } else {
            # ─── Full · authorization-code over the SHARED interactive ESTS+MFA chain (§36.1 · NOT ROPC) ──
            $method = switch (([string]$Credentials['AuthMethod'])) {
                'TOTP' { 'CredentialsTotp' }; 'CredentialsTotp' { 'CredentialsTotp' }; 'credentials_totp' { 'CredentialsTotp' }
                'Passkey' { 'Passkey' }; 'passkey' { 'Passkey' }; default { 'CredentialsTotp' }
            }
            $pkce = Get-XdrPkcePair
            $estsResource = if (-not [string]::IsNullOrWhiteSpace($Resource)) { $Resource } else { $Audience }
            # Get-XdrEntraEstsAuth (Xdr.Defender.Auth · shared chain) runs authorize(code)+MFA → FinalHtml carrying the code.
            # AuthVersion threads through so the AUTHORIZE matches the token exchange (v1 resource= for admin APIs · §37.7).
            $ests = Get-XdrEntraEstsAuth -Method $method -Credential $Credentials -AuthProfile 'Bearer' `
                        -ClientId $ClientId -RedirectUri $RedirectUri -Scope $scope -CodeChallenge $pkce.Challenge -TenantId $tenantId `
                        -AuthVersion $AuthVersion -Resource $estsResource
            $authCode = Get-XdrAuthCodeFromHtml -Html $ests.FinalHtml
            if ([string]::IsNullOrWhiteSpace($authCode)) {
                $fh = [string]$ests.FinalHtml
                $diag = if ($fh.Length -gt 0) { $fh.Substring(0, [Math]::Min(900, $fh.Length)) } else { '(empty FinalHtml)' }
                Write-Host "[bearer-diag] $Portal/$SubPortal · FinalHtml len=$($fh.Length) · forms=$(([regex]::Matches($fh,'<form')).Count) · AADSTS=$(if($fh -match '(AADSTS\d+)'){$Matches[1]}else{'none'}) · preview:`n$diag" -ForegroundColor Yellow
                throw (New-XdrException -Type AuthChainBroken -Message "Bearer auth-code not in form_post for ${Portal}/${SubPortal} (FinalHtml len=$($fh.Length))" -Properties @{ Portal = $Portal; SubPortal = $SubPortal; FailureStage = 'AuthCodeExtract' })
            }
            $body.grant_type    = 'authorization_code'
            $body.code          = $authCode
            $body.redirect_uri  = $RedirectUri
            $body.code_verifier = $pkce.Verifier
        }

        # ─── POST token endpoint ─────────────────────────────────────────────
        # TLS-1.2+ pinned code-side (§3 · disallow TLS 1.0/1.1) — SocketsHttpHandler.SslOptions on the token POST.
        $tlsHandler = [System.Net.Http.SocketsHttpHandler]::new()
        $tlsHandler.SslOptions.EnabledSslProtocols = [System.Security.Authentication.SslProtocols]'Tls12, Tls13'
        $client = [System.Net.Http.HttpClient]::new($tlsHandler)
        $client.Timeout = [TimeSpan]::FromSeconds(45)
        # SPA public clients require an Origin header on the cross-origin /token POST matching the registered
        # web-origin (the RedirectUri authority) · else AADSTS9002327 (Decision D-39). PublicClient sends none.
        if ($ClientType -eq 'SPA') {
            try {
                $origin = ([uri]$RedirectUri).GetLeftPart([System.UriPartial]::Authority)   # e.g. https://portal.azure.com
                [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('Origin', $origin)
            } catch { <# malformed RedirectUri → skip Origin · token POST will surface the real AAD error · INTENTIONAL-FAIL-SAFE #> }
        }
        try {
            $form = [System.Collections.Generic.List[System.Collections.Generic.KeyValuePair[string,string]]]::new()
            foreach ($k in $body.Keys) { $form.Add([System.Collections.Generic.KeyValuePair[string,string]]::new($k, [string]$body[$k])) }
            $content = [System.Net.Http.FormUrlEncodedContent]::new($form)
            $response = $client.PostAsync($tokenEndpoint, $content).GetAwaiter().GetResult()
            $bodyText = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $bodyJson = $null
            try { $bodyJson = $bodyText | ConvertFrom-Json -AsHashtable -Depth 10 } catch { <# Non-JSON error body → $bodyJson stays $null · downstream throws with raw text · INTENTIONAL-FAIL-SAFE #> }

            if ([int]$response.StatusCode -ge 400) {
                # MFA-required path · AADSTS50076 · operator must provide MFA via TOTP/Passkey via subsequent flow
                # For v0.1.0 · operator's lab tenant runs without MFA on service account OR with TOTP available
                # If MFA-required is hit · escalate (caller treats as auth chain broken · documented behavior)
                $errBody = if ($bodyJson) { $bodyJson['error_description'] } else { $bodyText }
                throw (New-XdrException -Type AuthChainBroken -Message "OAuth token request failed for ${Portal}/${SubPortal}: $errBody" -Properties @{ Portal = $Portal; SubPortal = $SubPortal; StatusCode = [int]$response.StatusCode })
            }

            # $bodyJson is `ConvertFrom-Json -AsHashtable` (above) → a hashtable. Read fields via the INDEXER
            # `$bodyJson['k']` ($null-safe under StrictMode -Version Latest). Dot-access (`$bodyJson.k`) THROWS on a
            # missing key, and `.PSObject.Properties` enumerates the hashtable's CLR members (Count/Keys/…), NOT the
            # JSON keys — string-indexing that collection coerces to Int32 → "cannot convert 'access_token' to Int32".
            # Hashtable-key reads only (this corrects an earlier same-session PSObject.Properties mistake).
            if (-not $bodyJson -or -not $bodyJson['access_token']) {
                throw (New-XdrException -Type AuthChainBroken -Message "OAuth token response missing access_token for ${Portal}/${SubPortal}" -Properties @{ Portal = $Portal; SubPortal = $SubPortal })
            }

            $expiresIn = if ($bodyJson['expires_in']) { [int]$bodyJson['expires_in'] } else { 3600 }
            $expiresUtc = [DateTime]::UtcNow.AddSeconds($expiresIn).AddMinutes(-5)  # 5min safety margin

            $token = @{
                AccessToken  = $bodyJson['access_token']
                RefreshToken = $(if ($bodyJson['refresh_token']) { $bodyJson['refresh_token'] } else { $refreshToken })  # preserve if refresh response omits new one
                ExpiresUtc   = $expiresUtc.ToString('o')
                TokenType    = $(if ($bodyJson['token_type']) { $bodyJson['token_type'] } else { 'Bearer' })
                Audience     = $Audience
                Scope        = $(if ($bodyJson['scope']) { $bodyJson['scope'] } else { $scope })
                UPN          = $Credentials.UPN
                Portal       = $Portal
                SubPortal    = $SubPortal
                ObtainedUtc  = (Get-Date).ToUniversalTime().ToString('o')
                Source       = if ($useRefreshToken) { 'refresh_token' } else { 'authorization_code' }
            }

            # ─── Persist L1 + L2 ─────────────────────────────────────────────
            $script:TokenCache[$cacheKey] = $token
            Save-XdrSession -Portal $Portal -UPN "${SubPortal}::$($Credentials.UPN)" -Session $token

            Track-XdrEvent -Name "$Portal.OAuth.Succeeded" -Properties @{
                SubPortal = $SubPortal
                Source    = $token.Source
                ExpiresUtc = $token.ExpiresUtc
            }

            return $token
        } finally {
            $client.Dispose()
        }
    } catch {
        Track-XdrException -Exception $_.Exception -Properties @{ Portal = $Portal; SubPortal = $SubPortal; Stage = 'OAuthToken' }
        Track-XdrEvent -Name "$Portal.OAuth.Failed" -Properties @{ SubPortal = $SubPortal; ErrorMessage = $_.Exception.Message }
        throw
    } finally {
        $null = $script:TokenSemaphore.Release()
    }
}

function Test-XdrOAuthTokenAlive {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [hashtable] $Token)
    if (-not $Token.ExpiresUtc) { return $false }
    try {
        return ((ConvertTo-XdrUtc $Token.ExpiresUtc) -gt [DateTime]::UtcNow.AddMinutes(5))
    } catch { return $false }
}

Export-ModuleMember -Function Get-XdrOAuthToken, Test-XdrOAuthTokenAlive
