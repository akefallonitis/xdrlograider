function Get-EstsCookie {
    <#
    .SYNOPSIS
        Performs the full non-browser Entra authentication flow against the DEFENDER
        PORTAL's own public client and returns a session that already has sccauth +
        XSRF-TOKEN cookies for security.microsoft.com. No second hop needed.

    .DESCRIPTION
        Why this approach over XDRInternals / larac2shell's Graph-client + second-hop
        pattern:

          - XDRInternals / larac2shell authenticate via the MSAL Graph public client
            (04b07795...) and then navigate to security.microsoft.com expecting the
            Graph-scoped ESTSAUTHPERSISTENT cookie to cover the portal RP.
            On modern tenants with strict ESTS cookie scoping this fails with
            AADSTS50058 — their own docstring recommends "use an incognito browsing
            session to obtain a new cookie" which defeats the point of unattended
            auth.

          - Using the Defender portal's OWN public client (80ccca67-54bd-44ab-8625-
            4b79c4dc7775) with redirect_uri=https://security.microsoft.com/, the ESTS
            cookie Entra issues is RP-scoped to the portal. After MFA + interrupt
            handling, the 302 chain naturally lands on security.microsoft.com and the
            sccauth + XSRF-TOKEN cookies drop in the SAME session. Zero Graph
            involvement, zero cross-RP cookie juggling.

          - The `client_id` field in the credential POST body is MANDATORY for web
            clients — omitting it triggers AADSTS900144.

        Auth sequence:
          1. GET /authorize with the portal's public client, sso_reload=true,
             redirect_uri=https://security.microsoft.com/.
          2. Parse the `$Config` blob (canary, sFT, sCtx, urlPost).
          3. POST credentials (with client_id) to urlPost.
          4. If MFA challenged: BeginAuth → EndAuth(TOTP, retry on duplicate code) →
             ProcessAuth.
          5. Resolve interrupt pages (KmsiInterrupt, CmsiInterrupt, etc.).
          6. Follow the 302 redirect chain back to security.microsoft.com — Entra
             calls the redirect_uri with `code`/`state`; the portal IdP consumes the
             code and drops sccauth + XSRF-TOKEN cookies.
          7. Verify both cookies, return the session + tenant ID.

        For Passkey, swap step 3 for FIDO challenge signing (ECDSA-P256) + assertion POST.

    .PARAMETER Method
        'CredentialsTotp' or 'Passkey'.

    .PARAMETER Credential
        Hashtable with auth material. See Connect-MDEPortal.

    .PARAMETER PortalHost
        Target portal. Default: security.microsoft.com. The client_id map below knows
        which client to use for each portal.

    .PARAMETER TenantId
        Optional. Short-circuits home-realm-discovery.

    .PARAMETER CorrelationId
        Correlation GUID for log stitching.

    .OUTPUTS
        [hashtable] @{ Session; Sccauth; XsrfToken; TenantId; AcquiredUtc }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('CredentialsTotp', 'Passkey')]
        [string] $Method,

        [Parameter(Mandatory)] [hashtable] $Credential,
        [Parameter(Mandatory)] [string] $PortalHost,
        [string] $TenantId,
        [Guid] $CorrelationId = [Guid]::NewGuid()
    )

    Write-Verbose "Get-EstsCookie: method=$Method host=$PortalHost correlation=$CorrelationId"

    $upn = $Credential.upn
    if (-not $upn) { throw "Credential must contain 'upn'" }

    # Portal-specific public client IDs. These are Microsoft-owned apps — no
    # registration required — but each is scoped to its own portal RP so ESTS
    # cookies issued under them are automatically accepted by the target portal.
    $portalClients = @{
        'security.microsoft.com' = '80ccca67-54bd-44ab-8625-4b79c4dc7775'  # Defender XDR portal
        'intune.microsoft.com'   = '0000000a-0000-0000-c000-000000000000'  # Intune
        'compliance.microsoft.com' = '80ccca67-54bd-44ab-8625-4b79c4dc7775'  # shares Defender client
    }
    if (-not $portalClients.ContainsKey($PortalHost)) {
        throw "Unknown portal host '$PortalHost' — add it to the portalClients map in Get-EstsCookie.ps1."
    }
    $clientId    = $portalClients[$PortalHost]
    $redirectUri = "https://$PortalHost/"
    $userAgent   = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0'

    $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
    $session.UserAgent = $userAgent

    # --- Step 1: START AT THE PORTAL ---
    # Why: the portal emits an OpenIdConnect.nonce cookie tied to the authorize
    # URL it constructs. Any code we obtain must be bound to THAT nonce; if we
    # construct our own authorize URL the nonces mismatch and the portal's
    # OIDC callback rejects the code. Let Invoke-WebRequest follow the 302 chain
    # automatically — we just need the final login HTML.
    Write-Verbose "Get-EstsCookie: GET $PortalHost to capture OIDC authorize redirect"
    $initialResponse = $null
    try {
        $initialResponse = Invoke-WebRequest -Uri "https://$PortalHost/" `
            -WebSession $session -Method Get `
            -UseBasicParsing -MaximumRedirection 10 -ErrorAction Stop
    } catch {
        throw "Portal GET failed: $($_.Exception.Message)"
    }

    Write-Verbose "Get-EstsCookie: final URL after redirects: $($initialResponse.BaseResponse.RequestMessage.RequestUri)"

    $sessionInfo = Get-EntraConfigBlob -Html $initialResponse.Content
    if (-not $sessionInfo) {
        throw "Could not parse Entra `$Config blob from authorize response. Tenant may redirect to an IdP we don't handle."
    }

    $required = @('canary', 'urlPost', 'sCtx', 'sFT')
    $missing  = $required | Where-Object { -not (Test-EntraField -Object $sessionInfo -Name $_) }
    if ($missing) {
        $present = ((Get-EntraFieldNames -Object $sessionInfo) | Sort-Object) -join ', '
        if (Test-EntraField -Object $sessionInfo -Name 'sErrorCode') {
            $errTxt = Get-EntraField -Object $sessionInfo -Name 'sErrTxt' -Default ''
            throw "Authorize endpoint returned error: AADSTS$($sessionInfo.sErrorCode) - $errTxt."
        }
        throw "Entra `$Config missing required fields: $($missing -join ', '). Present: $present."
    }

    $urlPost = $sessionInfo.urlPost
    if ($urlPost -notmatch '^https?://') {
        $urlPost = [uri]::new([uri]'https://login.microsoftonline.com/', $urlPost).AbsoluteUri
    }

    $pgid = Get-EntraField -Object $sessionInfo -Name 'pgid' -Default '<none>'
    Write-Verbose "Get-EstsCookie: login page parsed (pgid=$pgid urlPost=$urlPost)"

    # --- Step 2-5: method-specific auth ---
    switch ($Method) {
        'CredentialsTotp' {
            $authResult = Complete-CredentialsFlow `
                -Session       $session `
                -SessionInfo   $sessionInfo `
                -UrlPost       $urlPost `
                -Credential    $Credential `
                -ClientId      $clientId `
                -CorrelationId $CorrelationId
        }
        'Passkey' {
            $authResult = Complete-PasskeyFlow `
                -Session       $session `
                -SessionInfo   $sessionInfo `
                -Credential    $Credential `
                -ClientId      $clientId `
                -CorrelationId $CorrelationId
        }
    }

    $authResult = Resolve-InterruptPage -Session $session -AuthResult $authResult

    # DEBUG: dump what the auth flow returned
    if ($VerbosePreference -eq 'Continue' -or $env:XDRLR_DEBUG_AUTH -eq '1') {
        $lr = $authResult.LastResponse
        $stateJson = if ($authResult.State) { $authResult.State | ConvertTo-Json -Compress -Depth 3 -WarningAction SilentlyContinue } else { '<null>' }
        Write-Host "[DEBUG] After interrupts: state pgid=$(Get-EntraField -Object $authResult.State -Name 'pgid' -Default '<none>')"
        if ($lr) {
            Write-Host "[DEBUG] LastResponse status=$($lr.StatusCode) contentLen=$($lr.RawContentLength) finalUri=$($lr.BaseResponse.RequestMessage.RequestUri)"
            $inputNames = @()
            if ($lr.InputFields) {
                foreach ($if in $lr.InputFields) {
                    $props = @($if.PSObject.Properties.Name)
                    if ($props -contains 'Name') { $inputNames += $if.Name }
                    elseif ($props -contains 'name') { $inputNames += $if.name }
                }
            }
            Write-Host "[DEBUG] LastResponse InputFields: $(if ($inputNames) { $inputNames -join ',' } else { '<none>' })"
            # Snippet of content (first 500 chars, no HTML tags for readability)
            # Iter 13.9 (C2): guard $lr null AND $lr.Content null. If $lr is null
            # (very-edge web exception path), strict-mode access to $lr.Content
            # throws before the `if` test resolves.
            if ($null -ne $lr -and $lr.Content) {
                $snippet = $lr.Content.Substring(0, [math]::Min(400, $lr.Content.Length)) -replace '\s+', ' '
                Write-Host "[DEBUG] LastResponse snippet: $snippet"
            }
        }
    }

    # --- Step 6: submit final form_post back to portal OIDC callback ---
    Complete-PortalRedirectChain `
        -Session      $session `
        -PortalHost   $PortalHost `
        -LastResponse $authResult.LastResponse

    if ($VerbosePreference -eq 'Continue' -or $env:XDRLR_DEBUG_AUTH -eq '1') {
        $cookies = $session.Cookies.GetCookies("https://$PortalHost") | ForEach-Object Name
        Write-Host "[DEBUG] After Complete-PortalRedirectChain, $PortalHost cookies: $($cookies -join ',')"
    }

    # --- Step 7: verify portal cookies ---
    $portalCookies = $session.Cookies.GetCookies("https://$PortalHost")
    $sccauth = $portalCookies | Where-Object Name -eq 'sccauth'    | Select-Object -First 1
    $xsrf    = $portalCookies | Where-Object Name -eq 'XSRF-TOKEN' | Select-Object -First 1

    if (-not $sccauth -or [string]::IsNullOrWhiteSpace($sccauth.Value)) {
        $present = (@($portalCookies | ForEach-Object Name) -join ', ')
        throw "Auth flow completed but sccauth not issued. Portal cookies: $present. Common causes: CA policy, wrong credentials, TOTP drift, or account locked."
    }
    if (-not $xsrf -or [string]::IsNullOrWhiteSpace($xsrf.Value)) {
        # Some tenants mint XSRF only on first /apiproxy call — trigger one.
        Write-Verbose "Get-EstsCookie: XSRF missing, pinging portal"
        try {
            Invoke-WebRequest -Uri "https://$PortalHost/" -WebSession $session -UseBasicParsing -ErrorAction SilentlyContinue | Out-Null
        } catch {}
        $xsrf = $session.Cookies.GetCookies("https://$PortalHost") | Where-Object Name -eq 'XSRF-TOKEN' | Select-Object -First 1
    }
    if (-not $xsrf -or [string]::IsNullOrWhiteSpace($xsrf.Value)) {
        throw "Auth flow completed, sccauth issued, but XSRF-TOKEN not set on $PortalHost."
    }

    # --- Step 8: auto-harvest tenant ID from TenantContext if not supplied ---
    if (-not $TenantId) {
        try {
            $headers = @{ 'X-XSRF-TOKEN' = [System.Net.WebUtility]::UrlDecode($xsrf.Value) }
            $ctx = Invoke-RestMethod -Uri "https://$PortalHost/apiproxy/mtp/sccManagement/mgmt/TenantContext?realTime=true" `
                -WebSession $session -Headers $headers -ContentType 'application/json' `
                -Method Get -ErrorAction Stop
            if ($ctx -and $ctx.AuthInfo -and $ctx.AuthInfo.TenantId) {
                $TenantId = $ctx.AuthInfo.TenantId
                Write-Verbose "Get-EstsCookie: auto-resolved TenantId=$TenantId"
            }
        } catch {
            Write-Verbose "Get-EstsCookie: TenantContext lookup failed — $($_.Exception.Message)"
        }
    }

    Write-Verbose "Get-EstsCookie: success (sccauth len=$($sccauth.Value.Length) xsrf len=$($xsrf.Value.Length))"
    return @{
        Session     = $session
        Sccauth     = $sccauth.Value
        XsrfToken   = $xsrf.Value
        TenantId    = $TenantId
        AcquiredUtc = [datetime]::UtcNow
    }
}

function Test-EntraField {
    [CmdletBinding()]
    [OutputType([bool])]
    param($Object, [Parameter(Mandatory)] [string] $Name)
    if ($null -eq $Object) { return $false }
    return (@($Object.PSObject.Properties.Name) -contains $Name)
}

function Get-EntraField {
    [CmdletBinding()]
    param($Object, [Parameter(Mandatory)] [string] $Name, $Default = $null)
    if (Test-EntraField -Object $Object -Name $Name) { return $Object.$Name }
    return $Default
}

function Get-EntraFieldNames {
    [CmdletBinding()]
    [OutputType([string[]])]
    param($Object)
    if ($null -eq $Object) { return @() }
    return @($Object.PSObject.Properties.Name)
}

function Get-EntraConfigBlob {
    <#
    .SYNOPSIS
        Extracts `$Config = {...};` from Entra login HTML.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [string] $Html)

    if ([string]::IsNullOrEmpty($Html)) { return $null }

    $patterns = @(
        '\$Config\s*=\s*(\{.*?\});\s*\n',
        '\$Config\s*=\s*(\{.*?\});\s*</script>'
    )

    foreach ($pattern in $patterns) {
        $match = [regex]::Match($Html, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
        if ($match.Success) {
            try { return $match.Groups[1].Value | ConvertFrom-Json }
            catch { Write-Verbose "Get-EntraConfigBlob: `$Config parse failed: $($_.Exception.Message)" }
        }
    }

    # Fallback — outer-brace match (larac2shell pattern).
    if ($Html -match '\{(.*)\}') {
        try { return $Matches[0] | ConvertFrom-Json }
        catch { Write-Verbose "Get-EntraConfigBlob: fallback parse failed: $($_.Exception.Message)" }
    }
    return $null
}

function Complete-CredentialsFlow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [Microsoft.PowerShell.Commands.WebRequestSession] $Session,
        [Parameter(Mandatory)] [pscustomobject] $SessionInfo,
        [Parameter(Mandatory)] [string] $UrlPost,
        [Parameter(Mandatory)] [hashtable] $Credential,
        [Parameter(Mandatory)] [string] $ClientId,
        [Parameter(Mandatory)] [guid] $CorrelationId
    )

    $upn        = $Credential.upn
    $password   = $Credential.password
    $totpBase32 = $Credential.totpBase32

    if (-not $password)   { throw "CredentialsTotp requires 'password'" }
    if (-not $totpBase32) { throw "CredentialsTotp requires 'totpBase32'" }

    # Credential POST. client_id is MANDATORY for web-client flows — omitting
    # triggers AADSTS900144.
    $credBody = @{
        login        = $upn
        passwd       = $password
        type         = 11
        ps           = 2
        client_id    = $ClientId
        flowToken    = Get-EntraField -Object $SessionInfo -Name 'sFT'
        ctx          = Get-EntraField -Object $SessionInfo -Name 'sCtx'
        canary       = Get-EntraField -Object $SessionInfo -Name 'canary'
        hpgrequestid = Get-EntraField -Object $SessionInfo -Name 'correlationId' -Default $CorrelationId
    }

    Write-Verbose "Complete-CredentialsFlow: POST credentials to $UrlPost"
    $credResponse = Invoke-WebRequest -Uri $UrlPost `
        -WebSession $Session -Method Post -Body $credBody `
        -UseBasicParsing -MaximumRedirection 0 -SkipHttpErrorCheck

    $authState = Get-EntraConfigBlob -Html $credResponse.Content
    if (-not $authState) {
        throw "Password POST returned no response `$Config. Tenant may use a federated IdP not supported by non-browser auth."
    }

    $errCode = Get-EntraField -Object $authState -Name 'sErrorCode'
    if ($errCode) {
        $errTxt = Get-EntraField -Object $authState -Name 'sErrTxt' -Default ''
        $msg = Get-EntraErrorMessage -Code $errCode -DefaultText $errTxt
        # Iter 13.9 (C3): include UPN so operators can triage from
        # MDE_Heartbeat_CL.Notes alone without correlating App Insights.
        throw "Authentication failed for UPN='$upn' (AADSTS$errCode): $msg"
    }

    $pgid = Get-EntraField -Object $authState -Name 'pgid' -Default ''
    if ($pgid -eq 'ConvergedTFA') {
        $mfa = Complete-TotpMfa -Session $Session -AuthState $authState `
            -TotpBase32 $totpBase32 -CorrelationId $CorrelationId
        return $mfa
    }
    Write-Verbose "Complete-CredentialsFlow: no MFA (pgid=$pgid)"
    return @{ State = $authState; LastResponse = $credResponse }
}

function Complete-TotpMfa {
    <#
    .SYNOPSIS
        BeginAuth → EndAuth(TOTP, retry on dup) → ProcessAuth.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [Microsoft.PowerShell.Commands.WebRequestSession] $Session,
        [Parameter(Mandatory)] [pscustomobject] $AuthState,
        [Parameter(Mandatory)] [string] $TotpBase32,
        [Parameter(Mandatory)] [guid] $CorrelationId
    )

    Write-Verbose "Complete-TotpMfa: MFA challenge detected"

    $proofs = @()
    if (Test-EntraField -Object $AuthState -Name 'arrUserProofs') {
        $proofs = @($AuthState.arrUserProofs)
    }
    $totpProof = $proofs | Where-Object { $_.authMethodId -eq 'PhoneAppOTP' } | Select-Object -First 1
    if (-not $totpProof) {
        $methods = ($proofs | ForEach-Object authMethodId) -join ', '
        throw "No PhoneAppOTP method. Available: $methods. Enrol TOTP via mysignins.microsoft.com."
    }

    # BeginAuth
    $beginBody = @{
        AuthMethodId = 'PhoneAppOTP'
        Method       = 'BeginAuth'
        ctx          = Get-EntraField -Object $AuthState -Name 'sCtx'
        flowToken    = Get-EntraField -Object $AuthState -Name 'sFT'
    } | ConvertTo-Json -Compress

    $beginAuth = $null
    try {
        $beginAuth = Invoke-RestMethod -Uri 'https://login.microsoftonline.com/common/SAS/BeginAuth' `
            -WebSession $Session -Method Post -Body $beginBody -ContentType 'application/json' -ErrorAction Stop
    } catch { throw "SAS/BeginAuth failed: $($_.Exception.Message)" }

    if (-not (Get-EntraField -Object $beginAuth -Name 'Success' -Default $false)) {
        throw "BeginAuth Success=false: $(Get-EntraField -Object $beginAuth -Name 'Message' -Default 'unknown')"
    }
    Write-Verbose "Complete-TotpMfa: BeginAuth OK (SessionId=$(Get-EntraField -Object $beginAuth -Name 'SessionId'))"

    # EndAuth with retry on duplicate-code
    $endAuth = $null
    $attempt = 0
    while ($attempt -lt 3) {
        $attempt++
        if ($attempt -gt 1) {
            $now    = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $waitTo = [math]::Floor($now / 30) * 30 + 31
            $wait   = [math]::Max(1, $waitTo - $now)
            Write-Verbose "Complete-TotpMfa: waiting ${wait}s for next TOTP window"
            Start-Sleep -Seconds $wait
        }

        $code = Get-TotpCode -Base32Secret $TotpBase32

        $endBody = @{
            AuthMethodId       = 'PhoneAppOTP'
            Method             = 'EndAuth'
            SessionId          = Get-EntraField -Object $beginAuth -Name 'SessionId'
            FlowToken          = Get-EntraField -Object $beginAuth -Name 'FlowToken'
            Ctx                = Get-EntraField -Object $beginAuth -Name 'Ctx'
            AdditionalAuthData = $code
            PollCount          = $attempt
        } | ConvertTo-Json -Compress

        try {
            $endAuth = Invoke-RestMethod -Uri 'https://login.microsoftonline.com/common/SAS/EndAuth' `
                -WebSession $Session -Method Post -Body $endBody -ContentType 'application/json' -ErrorAction Stop
        } catch { throw "SAS/EndAuth failed: $($_.Exception.Message)" }

        if (Test-MfaEndAuthSuccess -EndAuth $endAuth) {
            Write-Verbose "Complete-TotpMfa: EndAuth OK (attempt $attempt)"
            break
        }

        $detail = (Get-EntraField -Object $endAuth -Name 'Message') ?? (Get-EntraField -Object $endAuth -Name 'ResultValue')
        if ($detail -match 'DuplicateCodeEntered' -and $attempt -lt 3) {
            Write-Verbose "Complete-TotpMfa: attempt $attempt got '$detail' — retry in next window"
            continue
        }
        throw "TOTP rejected on attempt ${attempt}: $detail. Check TOTP seed + system clock."
    }

    # ProcessAuth
    # The endpoint is form-urlencoded. If ContentType isn't explicitly set the
    # endpoint returns AADSTS9000410 "Malformed JSON" because PowerShell's default
    # for hashtable bodies on some versions is application/json.
    $processBody = @{
        type      = 22
        FlowToken = Get-EntraField -Object $endAuth -Name 'FlowToken'
        request   = Get-EntraField -Object $endAuth -Name 'Ctx'
        ctx       = Get-EntraField -Object $endAuth -Name 'Ctx'
    }
    $processResp = Invoke-WebRequest -Uri 'https://login.microsoftonline.com/common/SAS/ProcessAuth' `
        -WebSession $Session -Method Post -Body $processBody `
        -ContentType 'application/x-www-form-urlencoded' `
        -UseBasicParsing -MaximumRedirection 0 -SkipHttpErrorCheck

    # If ProcessAuth itself returned an error, surface it so we don't silently
    # claim success and fail to mint sccauth downstream.
    if ($processResp.StatusCode -ge 400) {
        $errBody = $processResp.Content
        if ($errBody -match 'AADSTS(\d+)[:\s]*([^"\\]+)') {
            $code = $Matches[1]; $msg = $Matches[2].Trim()
            throw "ProcessAuth failed: AADSTS$code - $msg"
        }
        throw "ProcessAuth failed with HTTP $($processResp.StatusCode). Body: $($errBody.Substring(0, [math]::Min(200, $errBody.Length)))"
    }

    $newState = Get-EntraConfigBlob -Html $processResp.Content
    if (-not $newState) {
        Write-Verbose "Complete-TotpMfa: ProcessAuth returned no parseable state — treating response as final redirect"
        return @{ State = $AuthState; LastResponse = $processResp }
    }
    $newPgid = Get-EntraField -Object $newState -Name 'pgid' -Default '<none>'
    Write-Verbose "Complete-TotpMfa: ProcessAuth OK (pgid=$newPgid)"
    return @{ State = $newState; LastResponse = $processResp }
}

function Complete-PasskeyFlow {
    <#
    .SYNOPSIS
        XDRInternals-faithful passkey flow: FIDO pre-verify at /common/fido/get →
        assertion POST at /common/login → SSO reload → interrupt-loop. No browser.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [Microsoft.PowerShell.Commands.WebRequestSession] $Session,
        [Parameter(Mandatory)] [pscustomobject] $SessionInfo,
        [Parameter(Mandatory)] [hashtable] $Credential,
        [Parameter(Mandatory)] [string] $ClientId,
        [Parameter(Mandatory)] [guid] $CorrelationId
    )

    $passkey = $Credential.passkey
    if (-not $passkey) { throw "Passkey method requires 'passkey' JSON object" }

    # Extract FIDO challenge from initial $Config. Modern authorize with sso_reload=true
    # pre-populates oGetCredTypeResult.Credentials.FidoParams.Challenge.
    $challenge = $null
    $hasFido   = $false
    $allowList = $null

    $cred = Get-EntraField -Object (Get-EntraField -Object $SessionInfo -Name 'oGetCredTypeResult') -Name 'Credentials'
    if ($cred) {
        $hasFido = [bool](Get-EntraField -Object $cred -Name 'HasFido' -Default $false)
        $fidoParams = Get-EntraField -Object $cred -Name 'FidoParams'
        if ($fidoParams) {
            $challenge = Get-EntraField -Object $fidoParams -Name 'Challenge'
            $allowList = Get-EntraField -Object $fidoParams -Name 'AllowList'
        }
    }
    if (-not $challenge) {
        $challenge = Get-EntraField -Object $SessionInfo -Name 'sFidoChallenge'
        if ($challenge) { $hasFido = $true }
    }
    if (-not $hasFido -or -not $challenge) {
        throw "Passkey not available. HasFido=$hasFido ChallengePresent=$([bool]$challenge). Account likely has no passkey registered."
    }

    $origin    = 'https://login.microsoft.com'
    $assertion = Invoke-PasskeyChallenge -PasskeyJson $passkey -Challenge $challenge -Origin $origin

    # XDRInternals pattern: pre-verify at /common/fido/get?uiflavor=Web
    $credentialsJson = if ($allowList) { ($allowList -join ',') } else { '' }
    $verifyBody = @{
        allowedIdentities = 2
        canary            = Get-EntraField -Object $SessionInfo -Name 'sFT'
        ServerChallenge   = Get-EntraField -Object $SessionInfo -Name 'sFT'
        postBackUrl       = Get-EntraField -Object $SessionInfo -Name 'urlPost'
        postBackUrlAad    = Get-EntraField -Object $SessionInfo -Name 'urlPostAad'
        postBackUrlMsa    = Get-EntraField -Object $SessionInfo -Name 'urlPostMsa'
        cancelUrl         = Get-EntraField -Object $SessionInfo -Name 'urlRefresh'
        resumeUrl         = Get-EntraField -Object $SessionInfo -Name 'urlResume'
        correlationId     = Get-EntraField -Object $SessionInfo -Name 'correlationId' -Default $CorrelationId
        credentialsJson   = $credentialsJson
        ctx               = Get-EntraField -Object $SessionInfo -Name 'sCtx'
        username          = $Credential.upn
        loginCanary       = Get-EntraField -Object $SessionInfo -Name 'canary'
    }
    Write-Verbose "Complete-PasskeyFlow: pre-verify at /common/fido/get"
    $verifyResp = Invoke-WebRequest -Uri 'https://login.microsoft.com/common/fido/get?uiflavor=Web' `
        -WebSession $Session -Method Post -Body $verifyBody `
        -UseBasicParsing -MaximumRedirection 0 -SkipHttpErrorCheck

    $responseInfo = Get-EntraConfigBlob -Html $verifyResp.Content
    if (-not $responseInfo) {
        throw "Passkey pre-verify returned no parseable `$Config at /common/fido/get. HTTP $($verifyResp.StatusCode)."
    }

    # Submit signed assertion to /common/login
    $fidoPayload = [ordered]@{
        id                = $passkey.credentialId
        clientDataJSON    = $assertion.clientDataJSON
        authenticatorData = $assertion.authenticatorData
        signature         = $assertion.signature
        userHandle        = Get-EntraField -Object $passkey -Name 'userHandle' -Default ''
    }
    $loginBody = @{
        type         = 23
        ps           = 23
        assertion    = ($fidoPayload | ConvertTo-Json -Compress -Depth 10)
        lmcCanary    = Get-EntraField -Object $responseInfo -Name 'sCrossDomainCanary'
        hpgrequestid = Get-EntraField -Object $responseInfo -Name 'sessionId' -Default $CorrelationId
        ctx          = Get-EntraField -Object $responseInfo -Name 'sCtx'
        canary       = Get-EntraField -Object $responseInfo -Name 'canary'
        flowToken    = Get-EntraField -Object $responseInfo -Name 'sFT'
    }
    Write-Verbose "Complete-PasskeyFlow: POST assertion to /common/login"
    $loginResp = Invoke-WebRequest -Uri 'https://login.microsoftonline.com/common/login' `
        -WebSession $Session -Method Post -Body $loginBody `
        -UseBasicParsing -MaximumRedirection 0 -SkipHttpErrorCheck

    # SSO reload — re-POST with the flowToken from oGetCredTypeResult.FlowToken
    $reloadFlowToken = Get-EntraField -Object (Get-EntraField -Object $SessionInfo -Name 'oGetCredTypeResult') -Name 'FlowToken'
    if ($reloadFlowToken) {
        $loginBody.flowToken = $reloadFlowToken
        Write-Verbose "Complete-PasskeyFlow: SSO reload POST"
        $reloadResp = Invoke-WebRequest -Uri 'https://login.microsoftonline.com/common/login?sso_reload=true' `
            -WebSession $Session -Method Post -Body $loginBody `
            -UseBasicParsing -MaximumRedirection 0 -SkipHttpErrorCheck

        $newState = Get-EntraConfigBlob -Html $reloadResp.Content
        if ($newState) { return @{ State = $newState; LastResponse = $reloadResp } }
        return @{ State = $null; LastResponse = $reloadResp }
    }

    $fallback = [pscustomobject]@{
        pgid          = ''
        sCtx          = (Get-EntraField -Object $SessionInfo -Name 'sCtx')
        sFT           = (Get-EntraField -Object $SessionInfo -Name 'sFT')
        canary        = (Get-EntraField -Object $SessionInfo -Name 'canary')
        correlationId = (Get-EntraField -Object $SessionInfo -Name 'correlationId' -Default $CorrelationId)
    }
    return @{ State = $fallback; LastResponse = $loginResp }
}

function Resolve-InterruptPage {
    <#
    .SYNOPSIS
        Walk KmsiInterrupt / CmsiInterrupt / ConvergedProofUpRedirect pages.
        Accepts and returns an @{State; LastResponse} hashtable so the final
        form_post response is preserved for Complete-PortalRedirectChain.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [Microsoft.PowerShell.Commands.WebRequestSession] $Session,
        [Parameter(Mandatory)] [hashtable] $AuthResult
    )
    $state = $AuthResult.State
    $lastResponse = $AuthResult.LastResponse
    if (-not $state) { return $AuthResult }

    $lastPgid = $null
    $loops    = 0
    while ($state -and $loops -lt 10) {
        $pgid = Get-EntraField -Object $state -Name 'pgid' -Default ''
        if (-not $pgid -or $pgid -eq $lastPgid) { break }
        $lastPgid = $pgid
        $loops++

        $ctx    = Get-EntraField -Object $state -Name 'sCtx'
        $flowTk = Get-EntraField -Object $state -Name 'sFT'
        $canary = Get-EntraField -Object $state -Name 'canary'
        $corrId = Get-EntraField -Object $state -Name 'correlationId' -Default ([Guid]::NewGuid())
        $resp = $null; $handled = $false

        switch ($pgid) {
            'KmsiInterrupt' {
                Write-Verbose "Resolve-InterruptPage: KmsiInterrupt"
                $body = @{ LoginOptions = 1; type = 28; ctx = $ctx; hpgrequestid = $corrId; flowToken = $flowTk; canary = $canary; i19 = 4130 }
                $resp = Invoke-WebRequest -Uri 'https://login.microsoftonline.com/kmsi' `
                    -WebSession $Session -Method Post -Body $body `
                    -UseBasicParsing -MaximumRedirection 10 -SkipHttpErrorCheck
                $handled = $true
            }
            'CmsiInterrupt' {
                Write-Verbose "Resolve-InterruptPage: CmsiInterrupt"
                $body = @{ ContinueAuth = 'true'; i19 = (Get-Random -Minimum 1000 -Maximum 9999); canary = $canary; iscsrfspeedbump = 'false'; flowToken = $flowTk; hpgrequestid = $corrId; ctx = $ctx }
                $resp = Invoke-WebRequest -Uri 'https://login.microsoftonline.com/appverify' `
                    -WebSession $Session -Method Post -Body $body `
                    -UseBasicParsing -MaximumRedirection 10 -SkipHttpErrorCheck
                $handled = $true
            }
            'ConvergedProofUpRedirect' {
                $remaining = Get-EntraField -Object $state -Name 'iRemainingDaysToSkipMfaRegistration' -Default 0
                if ($remaining -gt 0) {
                    $proofState = Get-EntraField -Object $state -Name 'sProofUpAuthState' -Default $ctx
                    $body = @{ type = 22; FlowToken = $flowTk; request = $proofState; ctx = $proofState }
                    $resp = Invoke-WebRequest -Uri 'https://login.microsoftonline.com/common/SAS/ProcessAuth' `
                        -WebSession $Session -Method Post -Body $body `
                        -UseBasicParsing -MaximumRedirection 10 -SkipHttpErrorCheck
                    $handled = $true
                } else {
                    throw "MFA registration required; cannot skip. Enrol via mysignins.microsoft.com."
                }
            }
            default {
                # Iter 13.9 (O1): unknown pgid is a diagnostic event — Entra
                # introduced a new interrupt page we don't handle yet (e.g. a
                # newer "trust this tenant" / IdentityVerificationRequired /
                # ConfirmTenantSwitch surface). Capture diagnostic context at
                # Warning level so operators can root-cause from App Insights
                # traces. The auth chain still fails downstream (no sccauth)
                # but at least operators have actionable evidence.
                $sErrorCode = Get-EntraField -Object $state -Name 'sErrorCode' -Default ''
                $sErrTxt    = Get-EntraField -Object $state -Name 'sErrTxt'    -Default ''
                $contentLen = if ($lastResponse -and $lastResponse.Content) { $lastResponse.Content.Length } else { 0 }
                Write-Warning ("Resolve-InterruptPage: UNKNOWN pgid '$pgid' (sErrorCode='$sErrorCode' sErrTxt='$sErrTxt' contentLen=$contentLen). " +
                               "Auth chain cannot proceed. If this recurs, capture the HTML response and add a handler in Get-EstsCookie.ps1.")
                Write-Verbose "Resolve-InterruptPage: unknown pgid '$pgid' — exiting"
                break
            }
        }
        if (-not $handled) { break }
        Start-Sleep -Milliseconds 200
        $lastResponse = $resp
        $state = Get-EntraConfigBlob -Html $resp.Content
        if (-not $state) { break }
    }
    return @{ State = $state; LastResponse = $lastResponse }
}

function Complete-PortalRedirectChain {
    <#
    .SYNOPSIS
        After auth + interrupts, Entra's final response is typically an HTML
        form_post targeting the portal's OIDC callback. Parse and submit it so
        the portal sees its own nonce-bound code and mints sccauth + XSRF-TOKEN.

    .DESCRIPTION
        The pattern from `response_mode=form_post`:
          <form action="https://security.microsoft.com/signin-oidc" method="POST">
              <input name="code" value="0.AAAA..."/>
              <input name="state" value="<state>"/>
              <input name="id_token" value="eyJ..."/>
              ...
          </form>
          <script>document.forms[0].submit();</script>

        We look for this form in the LAST HTTP response the session produced. If
        found, POST it. The portal's OIDC middleware validates the code against
        its OpenIdConnect.nonce cookie and drops sccauth on success.

        Fallback: ping the portal root — some portals emit sccauth directly on
        302 chains once the session carries the valid Entra cookies.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [Microsoft.PowerShell.Commands.WebRequestSession] $Session,
        [Parameter(Mandatory)] [string] $PortalHost,
        $LastResponse
    )

    # 1. Try to parse form_post from the last response body.
    if ($LastResponse -and $LastResponse.Content) {
        $formAction = $null
        # Match the <form ...> tag; attributes can appear in any order. We then
        # pull out the action=".." attribute value from within the tag.
        $tagMatch = [regex]::Match($LastResponse.Content, '<form\b[^>]*>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($tagMatch.Success) {
            $actionMatch = [regex]::Match($tagMatch.Value, 'action\s*=\s*[''"]([^''"]+)[''"]', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($actionMatch.Success) {
                $formAction = $actionMatch.Groups[1].Value
            }
        }

        # If form_post landed inside a $Config blob instead, check sPostBackUrl.
        if (-not $formAction) {
            $blob = Get-EntraConfigBlob -Html $LastResponse.Content
            if ($blob) {
                foreach ($fld in @('sPostBackUrl', 'urlPost', 'urlGoBack', 'urlResume')) {
                    $v = Get-EntraField -Object $blob -Name $fld
                    if ($v -and $v -match [regex]::Escape($PortalHost)) { $formAction = $v; break }
                }
            }
        }

        if ($env:XDRLR_DEBUG_AUTH -eq '1') {
            Write-Host "[DEBUG] Complete-PortalRedirectChain: formAction=$formAction"
        }

        if ($formAction -and $LastResponse.InputFields) {
            $body = @{}
            foreach ($field in $LastResponse.InputFields) {
                $fieldName = if (@($field.PSObject.Properties.Name) -contains 'Name') { $field.Name } elseif (@($field.PSObject.Properties.Name) -contains 'name') { $field.name } else { $null }
                $fieldValue = if (@($field.PSObject.Properties.Name) -contains 'Value') { $field.Value } elseif (@($field.PSObject.Properties.Name) -contains 'value') { $field.value } else { $null }
                if ($fieldName) { $body[$fieldName] = $fieldValue }
            }
            if ($body.Count -gt 0) {
                Write-Verbose "Complete-PortalRedirectChain: POST final form to $formAction with $($body.Count) fields ($(($body.Keys | Sort-Object) -join ','))"
                try {
                    Invoke-WebRequest -Uri $formAction -WebSession $Session `
                        -Method Post -Body $body `
                        -UseBasicParsing -MaximumRedirection 10 -ErrorAction SilentlyContinue | Out-Null
                } catch {
                    Write-Verbose "Complete-PortalRedirectChain: form POST raised $($_.Exception.Message) (often benign — redirect chain)"
                }
            }
        }
    }

    # 2. Nudge the portal root to mint any missing cookies.
    try {
        Invoke-WebRequest -Uri "https://$PortalHost/" -WebSession $Session `
            -UseBasicParsing -MaximumRedirection 10 -ErrorAction SilentlyContinue | Out-Null
    } catch {}
}

function Test-MfaEndAuthSuccess {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] $EndAuth)
    if ($null -eq $EndAuth) { return $false }
    $success = Get-EntraField -Object $EndAuth -Name 'Success'
    if ($success -eq $true) { return $true }
    $rv = Get-EntraField -Object $EndAuth -Name 'ResultValue'
    if ($rv -in @('AuthenticationSucceeded', 'Success')) { return $true }
    return $false
}

function Get-EntraErrorMessage {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Code, [string] $DefaultText)
    $messages = @{
        '50126'  = 'Invalid username or password.'
        '50053'  = 'Account is locked (too many failed sign-in attempts).'
        '50057'  = 'Account is disabled.'
        '50055'  = 'Password has expired.'
        '50056'  = 'Invalid or null password.'
        '50034'  = 'User account not found in this directory.'
        '50058'  = 'Session information is not sufficient for single-sign-on (ESTS cookie too narrow-scoped).'
        '53003'  = 'Access blocked by a Conditional Access policy.'
        '500121' = 'MFA authentication failed.'
        '700016' = 'Application not found in directory.'
        '900144' = 'Malformed login request (missing client_id). Auth-chain bug.'
    }
    if ($messages.ContainsKey($Code)) { return $messages[$Code] }
    if ($DefaultText) { return $DefaultText }
    return "Entra error $Code"
}
