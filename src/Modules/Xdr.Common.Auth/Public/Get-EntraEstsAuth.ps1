function Get-EntraEstsAuth {
    <#
    .SYNOPSIS
        L1 portal-generic Entra authentication. Performs the complete
        login.microsoftonline.com auth flow (credentials/passkey + MFA + interrupts +
        form_post submission) using the portal's own public-client app.

    .DESCRIPTION
        This is the canonical L1 entry point for any Microsoft 365 portal auth chain.
        Callers (the L2 portal modules — Xdr.Defender.Auth today; Xdr.Purview.Auth /
        Xdr.Intune.Auth in v0.2.0) supply the portal's public-client `-ClientId` and
        `-PortalHost`; this function returns a session that has:

          1. ESTSAUTHPERSISTENT cookie set on login.microsoftonline.com
          2. The portal's own session cookies set on $PortalHost (because the final
             form_post submits to the portal's OIDC callback, which mints them)

        The L2 module then calls its own Get-<Portal>Sccauth (or equivalent) helper
        to verify those portal cookies are present and to fetch any additional
        portal-context data (e.g., TenantContext for Defender).

        Why portal-OWN-public-client over Graph-client + second-hop:

          - XDRInternals / similar tools authenticate via the MSAL Graph public client
            (04b07795...) and then navigate to the portal expecting the Graph-scoped
            ESTSAUTHPERSISTENT cookie to cover the portal RP. On modern tenants with
            strict ESTS cookie scoping this fails AADSTS50058 — they recommend
            "use an incognito browsing session" which defeats unattended auth.

          - Using the portal's OWN public client with redirect_uri=https://<portal>/,
            the ESTS cookie Entra issues is RP-scoped to the portal. After MFA +
            interrupt handling, the 302 chain naturally lands on the portal and its
            session cookies drop in the SAME session. Zero Graph involvement.

          - The `client_id` field in the credential POST is MANDATORY for web
            clients — omitting triggers AADSTS900144.

        Auth sequence:
          1. GET https://$PortalHost/  → 302 chain to /authorize → login HTML
          2. Parse the `$Config` blob (canary, sFT, sCtx, urlPost)
          3. POST credentials (with -ClientId) to urlPost
          4. If MFA challenged: BeginAuth → EndAuth(TOTP) → ProcessAuth
             (Passkey: pre-verify at /common/fido/get → POST assertion to /common/login)
          5. Resolve-EntraInterruptPage walks KmsiInterrupt / CmsiInterrupt / ConvergedProofUpRedirect
          6. Submit final form_post back to portal OIDC callback (parsed from response HTML)

        Returns:
          @{
              Session       = [WebRequestSession]   (cookies for login + portal)
              State         = [pscustomobject]      (final $Config blob, if any)
              LastResponse  = [WebResponse]         (last HTTP response)
              AcquiredUtc   = [datetime]
              ClientId      = [string]              (echo of -ClientId for the L2 module)
              PortalHost    = [string]              (echo of -PortalHost for the L2 module)
          }

        Note: this function does NOT verify portal-specific cookies (sccauth, etc.).
        That is the L2 module's responsibility.

    .PARAMETER Method
        'CredentialsTotp' or 'Passkey'.

    .PARAMETER Credential
        Hashtable with auth material:
          CredentialsTotp: @{ upn; password; totpBase32 }
          Passkey:         @{ upn; passkey = <parsed JSON object> }

    .PARAMETER ClientId
        The portal's public-client app ID. Each portal has its own:
          - Defender XDR (security.microsoft.com): 80ccca67-54bd-44ab-8625-4b79c4dc7775
          - Intune (intune.microsoft.com):          0000000a-0000-0000-c000-000000000000
          - Purview (compliance.microsoft.com):     80ccca67-54bd-44ab-8625-4b79c4dc7775 (shares Defender)

    .PARAMETER PortalHost
        Target portal hostname (e.g., security.microsoft.com).

    .PARAMETER TenantId
        Optional. Improves first-hop latency by short-circuiting Entra's home-realm-
        discovery redirect. Auto-resolution of TenantId belongs to the L2 module.

    .PARAMETER CorrelationId
        Correlation GUID for log stitching.

    .OUTPUTS
        [hashtable] @{ Session; State; LastResponse; AcquiredUtc; ClientId; PortalHost }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('CredentialsTotp', 'Passkey')]
        [string] $Method,

        [Parameter(Mandatory)] [hashtable] $Credential,
        [Parameter(Mandatory)] [string] $ClientId,
        [Parameter(Mandatory)] [string] $PortalHost,
        [string] $TenantId,
        [Guid] $CorrelationId = [Guid]::NewGuid()
    )

    Write-Verbose "Get-EntraEstsAuth: method=$Method clientId=$ClientId portalHost=$PortalHost correlation=$CorrelationId"

    $upn = $Credential.upn
    if (-not $upn) { throw "Credential must contain 'upn'" }

    $userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0'

    $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
    $session.UserAgent = $userAgent

    # --- Step 1: START AT THE PORTAL ---
    # The portal emits an OpenIdConnect.nonce cookie tied to the authorize URL it
    # constructs. Any code we obtain must be bound to THAT nonce. Let
    # Invoke-WebRequest follow the 302 chain automatically — we just need the final
    # login HTML.
    Write-Verbose "Get-EntraEstsAuth: GET https://$PortalHost/ to capture OIDC authorize redirect"
    $initialResponse = $null
    try {
        $initialResponse = Invoke-WebRequest -Uri "https://$PortalHost/" `
            -WebSession $session -Method Get `
            -UseBasicParsing -MaximumRedirection 10 -ErrorAction Stop
    } catch {
        throw "Portal GET failed: $($_.Exception.Message)"
    }

    Write-Verbose "Get-EntraEstsAuth: final URL after redirects: $($initialResponse.BaseResponse.RequestMessage.RequestUri)"

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
    Write-Verbose "Get-EntraEstsAuth: login page parsed (pgid=$pgid urlPost=$urlPost)"

    # --- Step 2-5: method-specific auth ---
    switch ($Method) {
        'CredentialsTotp' {
            $authResult = Complete-CredentialsFlow `
                -Session       $session `
                -SessionInfo   $sessionInfo `
                -UrlPost       $urlPost `
                -Credential    $Credential `
                -ClientId      $ClientId `
                -CorrelationId $CorrelationId
        }
        'Passkey' {
            $authResult = Complete-PasskeyFlow `
                -Session       $session `
                -SessionInfo   $sessionInfo `
                -Credential    $Credential `
                -ClientId      $ClientId `
                -CorrelationId $CorrelationId
        }
    }

    $authResult = Resolve-EntraInterruptPage -Session $session -AuthResult $authResult

    # DEBUG: dump what the auth flow returned
    if ($VerbosePreference -eq 'Continue' -or $env:XDRLR_DEBUG_AUTH -eq '1') {
        $lr = $authResult.LastResponse
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
            if ($null -ne $lr -and $lr.Content) {
                $snippet = $lr.Content.Substring(0, [math]::Min(400, $lr.Content.Length)) -replace '\s+', ' '
                Write-Host "[DEBUG] LastResponse snippet: $snippet"
            }
        }
    }

    # --- Step 6: submit final form_post back to portal OIDC callback ---
    # This is portal-generic: parses <form action="..."> from response HTML and
    # submits the form fields. Each portal's signin-oidc callback URL appears
    # inside the form's action attribute.
    Submit-EntraFormPost -Session $session -PortalHost $PortalHost -LastResponse $authResult.LastResponse

    return @{
        Session      = $session
        State        = $authResult.State
        LastResponse = $authResult.LastResponse
        AcquiredUtc  = [datetime]::UtcNow
        ClientId     = $ClientId
        PortalHost   = $PortalHost
    }
}

function Submit-EntraFormPost {
    <#
    .SYNOPSIS
        L1 portal-generic form_post submitter. After Entra auth + interrupts, the
        final response is typically an HTML form_post targeting the portal's OIDC
        callback (signin-oidc, /api/auth/callback, etc.). Parses + submits whatever
        form is in the response. Each portal lands its own session cookies.

    .DESCRIPTION
        Pattern from `response_mode=form_post`:
          <form action="https://<portal>/<oidc-callback>" method="POST">
              <input name="code" value="0.AAAA..."/>
              <input name="state" value="<state>"/>
              <input name="id_token" value="eyJ..."/>
              ...
          </form>
          <script>document.forms[0].submit();</script>

        We look for this form in the LAST HTTP response. If found, POST it. The
        portal's OIDC middleware validates the code against its OpenIdConnect.nonce
        cookie and drops the portal's session cookies on success.

        Fallback: ping the portal root — some portals emit cookies directly on 302
        chains once the session carries the valid Entra ESTS cookie.

        This helper is portal-generic — it works for any portal whose OIDC callback
        URL is embedded in the response form. Each L2 module verifies the resulting
        portal-specific cookies after this returns.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [Microsoft.PowerShell.Commands.WebRequestSession] $Session,
        [Parameter(Mandatory)] [string] $PortalHost,
        $LastResponse
    )

    if ($LastResponse -and $LastResponse.Content) {
        $formAction = $null
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
            Write-Host "[DEBUG] Submit-EntraFormPost: formAction=$formAction"
        }

        if ($formAction -and $LastResponse.InputFields) {
            $body = @{}
            foreach ($field in $LastResponse.InputFields) {
                $fieldName = if (@($field.PSObject.Properties.Name) -contains 'Name') { $field.Name } elseif (@($field.PSObject.Properties.Name) -contains 'name') { $field.name } else { $null }
                $fieldValue = if (@($field.PSObject.Properties.Name) -contains 'Value') { $field.Value } elseif (@($field.PSObject.Properties.Name) -contains 'value') { $field.value } else { $null }
                if ($fieldName) { $body[$fieldName] = $fieldValue }
            }
            if ($body.Count -gt 0) {
                Write-Verbose "Submit-EntraFormPost: POST final form to $formAction with $($body.Count) fields ($(($body.Keys | Sort-Object) -join ','))"
                try {
                    Invoke-WebRequest -Uri $formAction -WebSession $Session `
                        -Method Post -Body $body `
                        -UseBasicParsing -MaximumRedirection 10 -ErrorAction SilentlyContinue | Out-Null
                } catch {
                    Write-Verbose "Submit-EntraFormPost: form POST raised $($_.Exception.Message) (often benign — redirect chain)"
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
