function Get-EstsCookie {
    <#
    .SYNOPSIS
        Performs the full Entra interactive-like login chain and returns a WebRequestSession
        with ESTSAUTHPERSISTENT set.

    .DESCRIPTION
        Real implementation of the Entra login flow, replicating what a browser does:

          1. GET the OAuth2 authorize endpoint with the Defender portal's public client_id.
             Entra responds with an HTML login page containing a `$Config` JSON blob with
             flow-control fields (flowToken, ctx, urlPost, urlGetCredentialType).

          2. Parse the $Config JSON from the HTML.

          3. POST to urlGetCredentialType with { username, flowToken } to determine MFA
             requirements and (for passkey path) get the FIDO2 challenge.

          4. Credentials+TOTP path:
             a. POST username+password to urlPost — receive fresh flowToken + ctx for MFA
             b. POST to /common/SAS/BeginAuth { AuthMethodId: PhoneAppOTP, Ctx, FlowToken }
             c. POST to /common/SAS/EndAuth with the TOTP code
             d. POST final form to urlPost completing the flow

          5. Passkey path: sign the FIDO2 challenge locally and POST assertion back.

          6. Follow the redirect chain; ESTSAUTHPERSISTENT cookie lands in the session.

    .PARAMETER Method
        'CredentialsTotp' or 'Passkey'.

    .PARAMETER Credential
        Hashtable with auth material (see Connect-MDEPortal).

    .PARAMETER PortalHost
        The portal we're targeting (e.g., 'security.microsoft.com').

    .PARAMETER CorrelationId
        For log correlation.

    .OUTPUTS
        [Microsoft.PowerShell.Commands.WebRequestSession]
    #>
    [CmdletBinding()]
    [OutputType([Microsoft.PowerShell.Commands.WebRequestSession])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('CredentialsTotp', 'Passkey')]
        [string] $Method,

        [Parameter(Mandatory)] [hashtable] $Credential,
        [Parameter(Mandatory)] [string] $PortalHost,
        [Guid] $CorrelationId = [Guid]::NewGuid()
    )

    Write-Verbose "Get-EstsCookie: method=$Method host=$PortalHost correlation=$CorrelationId"

    # Defender portal public client ID (well-known)
    $clientId = '80ccca67-54bd-44ab-8625-4b79c4dc7775'

    $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
    $session.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

    $upn = $Credential.upn
    if (-not $upn) { throw "Credential must contain 'upn'" }

    # --- Step 1: GET /authorize to get login form + $Config blob ---

    $authorizeUri = "https://login.microsoftonline.com/organizations/oauth2/v2.0/authorize?" +
        "client_id=$clientId" +
        "&response_type=code" +
        "&redirect_uri=https%3A%2F%2F$PortalHost%2F" +
        "&response_mode=query" +
        "&scope=openid+profile+offline_access" +
        "&login_hint=$([uri]::EscapeDataString($upn))" +
        "&client-request-id=$CorrelationId"

    $authorizeHtml = $null
    try {
        $resp = Invoke-WebRequest -Uri $authorizeUri -WebSession $session -UseBasicParsing -ErrorAction Stop
        $authorizeHtml = $resp.Content
    } catch {
        throw "Authorize endpoint GET failed: $_"
    }

    $config = Get-EntraConfigBlob -Html $authorizeHtml
    if (-not $config) {
        throw "Could not parse Entra `$Config blob from authorize response. Login flow has changed or tenant requires a different entry point."
    }

    # StrictMode-safe field checks (ConvertFrom-Json returns PSCustomObject; missing
    # properties throw under strict mode).
    $configFields = @($config.PSObject.Properties.Name)
    $hasField = { param($name) $configFields -contains $name }

    $fieldsRequired = @('sFT', 'sCtx', 'canary', 'urlGetCredentialType', 'urlPost', 'apiCanary')
    $missing = $fieldsRequired | Where-Object { -not (& $hasField $_) }
    if ($missing) {
        $present = ($configFields | Sort-Object) -join ', '
        throw "Entra `$Config blob is missing required fields: $($missing -join ', '). Fields present: $present. This usually means (a) Microsoft has changed the Entra login page structure, (b) the tenant requires a different entry point (e.g. /common vs /organizations), or (c) the authorize response was a redirect to a CA-challenged page. Re-run with -Verbose for more detail; file a bug_report issue with the raw response."
    }

    $canarySnip = if ($config.canary) { $config.canary.Substring(0, [math]::Min(10, $config.canary.Length)) } else { '<empty>' }
    Write-Verbose "Entra `$Config loaded: canary=${canarySnip}... sFT len=$($config.sFT.Length) fields=$($configFields.Count)"

    # --- Step 2: POST GetCredentialType to resolve MFA requirements / FIDO2 challenge ---

    $credTypeBody = @{
        username                       = $upn
        isOtherIdpSupported            = $true
        checkPhones                    = $false
        isRemoteNGCSupported           = $true
        isCookieBannerShown            = $false
        isFidoSupported                = ($Method -eq 'Passkey')
        originalRequest                = $config.sCtx
        country                        = 'US'
        forceotclogin                  = $false
        isExternalFederationDisallowed = $false
        isRemoteConnectSupported       = $false
        federationFlags                = 0
        isSignup                       = $false
        flowToken                      = $config.sFT
    } | ConvertTo-Json -Compress

    $credType = $null
    try {
        $credTypeResp = Invoke-WebRequest -Uri $config.urlGetCredentialType `
            -WebSession $session `
            -Method POST `
            -Body $credTypeBody `
            -ContentType 'application/json; charset=UTF-8' `
            -Headers @{
                'hpgrequestid'    = $CorrelationId
                'canary'          = $config.apiCanary
                'client-request-id' = $CorrelationId
            } `
            -UseBasicParsing `
            -ErrorAction Stop
        $credType = $credTypeResp.Content | ConvertFrom-Json
    } catch {
        throw "GetCredentialType failed: $_"
    }

    # Propagate any updated flow token
    if ($credType.FlowToken) { $config.sFT = $credType.FlowToken }

    # --- Step 3: branch by method ---

    switch ($Method) {
        'CredentialsTotp' {
            _Complete-CredentialsTotpFlow -Session $session -Config $config -Credential $Credential -CorrelationId $CorrelationId
        }
        'Passkey' {
            _Complete-PasskeyFlow -Session $session -Config $config -CredType $credType -Credential $Credential -CorrelationId $CorrelationId
        }
    }

    # --- Step 4: verify ESTSAUTHPERSISTENT cookie acquired ---

    $loginCookies = $session.Cookies.GetCookies('https://login.microsoftonline.com')
    $esthMarker = $loginCookies | Where-Object { $_.Name -in @('ESTSAUTHPERSISTENT', 'ESTSAUTH') }
    if (-not $esthMarker) {
        $cookieNames = ($loginCookies | ForEach-Object Name) -join ', '
        throw "Login flow completed but ESTSAUTHPERSISTENT not issued. Cookies present: $cookieNames. Likely causes: Conditional Access blocked sign-in, wrong password, wrong TOTP, or account disabled."
    }

    Write-Verbose "Get-EstsCookie: success, ESTSAUTH* acquired"
    return $session
}

function Get-EntraConfigBlob {
    <#
    .SYNOPSIS
        Extracts the `$Config = {...};` JSON blob embedded in Entra's login HTML.

    .DESCRIPTION
        Entra's login page includes a JSON config object assigned to `$Config` in an inline
        script. This function regex-extracts and parses it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Html)

    # Two common patterns — use the one that matches
    $patterns = @(
        '\$Config\s*=\s*(\{.*?\});\s*\n',
        '\$Config\s*=\s*(\{.*?\});\s*</script>'
    )

    foreach ($pattern in $patterns) {
        $match = [regex]::Match($Html, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
        if ($match.Success) {
            try {
                $json = $match.Groups[1].Value
                return $json | ConvertFrom-Json
            } catch {
                Write-Verbose "Pattern matched but JSON parse failed: $_"
            }
        }
    }
    return $null
}

function _Complete-CredentialsTotpFlow {
    [CmdletBinding()]
    param(
        [Microsoft.PowerShell.Commands.WebRequestSession] $Session,
        [pscustomobject] $Config,
        [hashtable] $Credential,
        [guid] $CorrelationId
    )

    $upn        = $Credential.upn
    $password   = $Credential.password
    $totpBase32 = $Credential.totpBase32

    if (-not $password)   { throw "CredentialsTotp requires 'password'" }
    if (-not $totpBase32) { throw "CredentialsTotp requires 'totpBase32'" }

    # --- Step 3a: POST credentials ---

    $loginBody = @{
        i13                 = '0'
        login               = $upn
        loginfmt            = $upn
        type                = '11'
        LoginOptions        = '3'
        lrt                 = ''
        lrtPartition        = ''
        hisRegion           = ''
        hisScaleUnit        = ''
        passwd              = $password
        ps                  = '2'
        psRNGCDefaultType   = ''
        psRNGCEntropy       = ''
        psRNGCSLK           = ''
        canary              = $Config.canary
        ctx                 = $Config.sCtx
        hpgrequestid        = $CorrelationId
        flowToken           = $Config.sFT
        PPSX                = ''
        NewUser             = '1'
        FoundMSAs           = ''
        fspost              = '0'
        i21                 = '0'
        CookieDisclosure    = '0'
        IsFidoSupported     = '0'
        isSignupPost        = '0'
        i19                 = '1000'
    }

    $loginResp = $null
    try {
        $loginResp = Invoke-WebRequest -Uri $Config.urlPost `
            -WebSession $Session `
            -Method POST `
            -Body $loginBody `
            -ContentType 'application/x-www-form-urlencoded' `
            -UseBasicParsing `
            -ErrorAction Stop
    } catch {
        throw "Password POST failed: $_"
    }

    # Response could be:
    #   A) HTML redirect to MFA page → parse new $Config
    #   B) HTML redirect straight to the relying party (no MFA required, rare for modern tenants)
    #   C) Error page with strServiceExceptionMessage set

    $nextConfig = Get-EntraConfigBlob -Html $loginResp.Content
    if (-not $nextConfig) {
        throw "Credential POST succeeded but no next-step `$Config found. Tenant may use a federated IdP not supported by this module."
    }

    if ($nextConfig.strServiceExceptionMessage) {
        throw "Entra rejected credentials: $($nextConfig.strServiceExceptionMessage)"
    }

    # Did MFA kick in?
    $userProofs = $nextConfig.arrUserProofs
    if (-not $userProofs -or $userProofs.Count -eq 0) {
        # No MFA required — look for auto-redirect URL in response (rare path)
        Write-Warning "No MFA challenge but account may not be fully authenticated. Proceeding to verify ESTSAUTH."
        return
    }

    # Find TOTP (PhoneAppOTP) proof
    $totpProof = $userProofs | Where-Object { $_.authMethodId -eq 'PhoneAppOTP' } | Select-Object -First 1
    if (-not $totpProof) {
        $methods = ($userProofs | ForEach-Object authMethodId) -join ', '
        throw "No PhoneAppOTP method registered for account. Available: $methods. Enroll TOTP via Authenticator app."
    }

    # --- Step 3b: BeginAuth for TOTP ---

    $beginAuthBody = @{
        AuthMethodId = 'PhoneAppOTP'
        Method       = 'BeginAuth'
        Ctx          = $nextConfig.sCtx
        FlowToken    = $nextConfig.sFT
    } | ConvertTo-Json -Compress

    $beginAuth = $null
    try {
        $beginAuthResp = Invoke-WebRequest -Uri 'https://login.microsoftonline.com/common/SAS/BeginAuth' `
            -WebSession $Session `
            -Method POST `
            -Body $beginAuthBody `
            -ContentType 'application/json; charset=UTF-8' `
            -Headers @{
                'hpgrequestid'    = $CorrelationId
                'canary'          = $nextConfig.apiCanary
                'client-request-id' = $CorrelationId
            } `
            -UseBasicParsing `
            -ErrorAction Stop
        $beginAuth = $beginAuthResp.Content | ConvertFrom-Json
    } catch {
        throw "BeginAuth failed: $_"
    }

    if (-not $beginAuth.Success) {
        throw "BeginAuth returned Success=false: $($beginAuth.Message)"
    }

    # --- Step 3c: EndAuth with TOTP code ---

    $totpCode = Get-TotpCode -Base32Secret $totpBase32

    $endAuthBody = @{
        Method             = 'EndAuth'
        SessionId          = $beginAuth.SessionId
        FlowToken          = $beginAuth.FlowToken
        Ctx                = $beginAuth.Ctx
        AuthMethodId       = 'PhoneAppOTP'
        AdditionalAuthData = $totpCode
        PollCount          = 1
    } | ConvertTo-Json -Compress

    $endAuth = $null
    try {
        $endAuthResp = Invoke-WebRequest -Uri 'https://login.microsoftonline.com/common/SAS/EndAuth' `
            -WebSession $Session `
            -Method POST `
            -Body $endAuthBody `
            -ContentType 'application/json; charset=UTF-8' `
            -Headers @{
                'hpgrequestid'    = $CorrelationId
                'canary'          = $nextConfig.apiCanary
                'client-request-id' = $CorrelationId
            } `
            -UseBasicParsing `
            -ErrorAction Stop
        $endAuth = $endAuthResp.Content | ConvertFrom-Json
    } catch {
        throw "EndAuth failed: $_"
    }

    if (-not $endAuth.Success) {
        $msg = if ($endAuth.ResultValue) { "$($endAuth.ResultValue) (ResultCode $($endAuth.ResultCode))" } else { 'unknown' }
        throw "TOTP verification failed: $msg. Check that the TOTP secret is correct and the system clock is not drifted."
    }

    # --- Step 3d: finalize via ProcessAuth ---

    $processAuthBody = @{
        request           = $endAuth.Ctx
        mfaLastPollStart  = ''
        mfaAuthMethod     = 'PhoneAppOTP'
        otc               = ''
        login             = $upn
        flowToken         = $endAuth.FlowToken
        hpgrequestid      = $CorrelationId
        canary            = $nextConfig.canary
        i2                = '1'
        i17               = ''
        i18               = ''
        i19               = '1000'
    }

    try {
        Invoke-WebRequest -Uri 'https://login.microsoftonline.com/common/SAS/ProcessAuth' `
            -WebSession $Session `
            -Method POST `
            -Body $processAuthBody `
            -ContentType 'application/x-www-form-urlencoded' `
            -UseBasicParsing `
            -ErrorAction Stop | Out-Null
    } catch [System.Net.WebException], [Microsoft.PowerShell.Commands.HttpResponseException] {
        # Expected — this endpoint usually returns 302 redirects that the session follows
    }

    # KMSI (Keep Me Signed In) prompt — auto-decline
    $kmsiBody = @{
        LoginOptions = '1'
        ctx          = $endAuth.Ctx
        hpgrequestid = $CorrelationId
        flowToken    = $endAuth.FlowToken
        canary       = $nextConfig.canary
        i2           = '1'
        i17          = ''
        i18          = ''
        i19          = '1000'
    }
    try {
        Invoke-WebRequest -Uri 'https://login.microsoftonline.com/kmsi' `
            -WebSession $Session `
            -Method POST `
            -Body $kmsiBody `
            -ContentType 'application/x-www-form-urlencoded' `
            -UseBasicParsing `
            -ErrorAction SilentlyContinue | Out-Null
    } catch {}

    Write-Verbose "_Complete-CredentialsTotpFlow: TOTP verified + ProcessAuth + KMSI sequence complete"
}

function _Complete-PasskeyFlow {
    [CmdletBinding()]
    param(
        [Microsoft.PowerShell.Commands.WebRequestSession] $Session,
        [pscustomobject] $Config,
        [pscustomobject] $CredType,
        [hashtable] $Credential,
        [guid] $CorrelationId
    )

    $passkey = $Credential.passkey
    if (-not $passkey) { throw "Passkey method requires 'passkey' JSON object" }

    if (-not $CredType.Credentials.FidoParams) {
        throw "Entra did not return a FIDO2 challenge. The account may not have a passkey registered, or the tenant does not allow passkey sign-in."
    }

    $challenge = $CredType.Credentials.FidoParams.Challenge

    # Sign assertion
    $assertion = Invoke-PasskeyChallenge -PasskeyJson $passkey -Challenge $challenge -Origin 'https://login.microsoft.com'

    # POST signed assertion to the FIDO verification endpoint
    $fidoBody = @{
        type             = '29'
        assertionResult  = ($assertion | ConvertTo-Json -Compress)
        login            = $passkey.upn
        flowToken        = $Config.sFT
        ctx              = $Config.sCtx
        canary           = $Config.canary
        hpgrequestid     = $CorrelationId
    }

    try {
        Invoke-WebRequest -Uri $Config.urlPost `
            -WebSession $Session `
            -Method POST `
            -Body $fidoBody `
            -ContentType 'application/x-www-form-urlencoded' `
            -UseBasicParsing `
            -ErrorAction Stop | Out-Null
    } catch [System.Net.WebException], [Microsoft.PowerShell.Commands.HttpResponseException] {
        # Expected redirect
    }

    Write-Verbose "_Complete-PasskeyFlow: assertion signed + submitted"
}
