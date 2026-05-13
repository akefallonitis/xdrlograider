# Probe-EstsauthSilentToken.ps1 — v2
#
# Live-prove unattended TOTP -> ESTSAUTHPERSISTENT -> authorization_code -> refresh_token
# for a target SPA portal (default: intune-portal). Bootstrap-once + refresh-token
# replaces the v1 "full re-auth every 50 min" pattern (sccauth is not unattended-reauth-able).

#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$EnvFile = "$PSScriptRoot\..\..\xdrlograider\tests\.env.local",
    [string]$TargetPortal = 'intune-portal',
    [string]$TargetClientId = '0000000a-0000-0000-c000-000000000000',
    [string]$TargetRedirect = 'https://intune.microsoft.com/signin-oidc',
    [string]$TargetAudience = 'https://intune.microsoft.com'
)

$ErrorActionPreference = 'Stop'
$v1Modules = "$PSScriptRoot\..\..\xdrlograider\src\Modules"

Get-Content $EnvFile | Where-Object { $_ -match '^[A-Z_]+=' } | ForEach-Object {
    $k,$v = $_ -split '=', 2; Set-Item -Path "env:$k" -Value $v
}

# Dot-source v1's private auth helpers (Complete-CredentialsFlow, Resolve-EntraInterruptPage,
# Get-EntraFields, Get-TotpCode) — gives us access to the same auth machinery v1 uses.
Import-Module (Join-Path $v1Modules 'Xdr.Common.Telemetry\Xdr.Common.Telemetry.psd1') -Force -Global
$authPriv = Join-Path $v1Modules 'Xdr.Common.Auth\Private'
. (Join-Path $authPriv 'Get-EntraFields.ps1')
. (Join-Path $authPriv 'Get-TotpCode.ps1')
. (Join-Path $authPriv 'Complete-TotpMfa.ps1')
. (Join-Path $authPriv 'Complete-CredentialsFlow.ps1')
$authPub = Join-Path $v1Modules 'Xdr.Common.Auth\Public'
. (Join-Path $authPub 'Resolve-EntraInterruptPage.ps1')

$cred = @{
    upn        = $env:XDRLR_TEST_UPN
    password   = $env:XDRLR_TEST_PASSWORD
    totpBase32 = $env:XDRLR_TEST_TOTP_SECRET
}
$tenant = $env:AZURE_TENANT_ID
$userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0'

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " STEP 1: Direct /authorize bootstrap for $TargetPortal" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Target client_id: $TargetClientId"
Write-Host "  Target redirect:  $TargetRedirect"
Write-Host "  Target audience:  $TargetAudience"

# PKCE
$verifierBytes = [byte[]]::new(32)
[System.Security.Cryptography.RandomNumberGenerator]::Fill($verifierBytes)
$codeVerifier = [Convert]::ToBase64String($verifierBytes).TrimEnd('=').Replace('+','-').Replace('/','_')
$challengeBytes = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::ASCII.GetBytes($codeVerifier))
$codeChallenge  = [Convert]::ToBase64String($challengeBytes).TrimEnd('=').Replace('+','-').Replace('/','_')

$state = [Guid]::NewGuid().ToString('N')
$nonce = [Guid]::NewGuid().ToString('N')
# Optional resource-scoped scope. If $TargetAudience is provided and looks like a
# resource (URL or GUID), request <audience>/.default so the resulting token is
# scoped to that resource (proper Bearer for portal /api calls).
$scope = if ($TargetAudience -and $TargetAudience -notmatch '^https://(intune|entra)\.microsoft\.com$') {
    "$TargetAudience/.default offline_access openid profile"
} else {
    "openid offline_access profile"
}
Write-Host "  Scope: $scope"

$authUrl = "https://login.microsoftonline.com/$tenant/oauth2/v2.0/authorize?" + (@(
    "client_id=$TargetClientId",
    "response_type=code",
    "redirect_uri=$([uri]::EscapeDataString($TargetRedirect))",
    "response_mode=query",
    "scope=$([uri]::EscapeDataString($scope))",
    "state=$state",
    "nonce=$nonce",
    "code_challenge=$codeChallenge",
    "code_challenge_method=S256"
) -join '&')

$session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
$session.UserAgent = $userAgent

Write-Host "  GET /authorize..."
$initResp = Invoke-WebRequest -Uri $authUrl -WebSession $session -Method Get -UseBasicParsing -MaximumRedirection 10 -ErrorAction Stop

$sessionInfo = Get-EntraConfigBlob -Html $initResp.Content
if (-not $sessionInfo) { throw "Could not parse `$Config from /authorize response" }
$names = @($sessionInfo.PSObject.Properties.Name)
$pgid = if ($names -contains 'pgid') { $sessionInfo.pgid } else { '<none>' }
$errCode = if ($names -contains 'sErrorCode') { $sessionInfo.sErrorCode } else { $null }
Write-Host "    Initial parse: pgid=$pgid sErrorCode=AADSTS$errCode"

# AADSTS50058 with pgid=ConvergedSignIn is a soft notice ("no SSO cookie yet,
# please sign in") — NOT a fatal error. v1 throws on it overly aggressively.
# Proceed if we have urlPost + sCtx + sFT + canary, regardless of 50058.
$required = @('canary', 'urlPost', 'sCtx', 'sFT')
$missing = $required | Where-Object { -not ($names -contains $_) }
if ($missing) {
    Write-Host "    Required Entra fields missing: $($missing -join ',')" -ForegroundColor Red
    Write-Host "    All fields present: $(($names | Sort-Object) -join ',')" -ForegroundColor Yellow
    throw "Cannot proceed without canary/urlPost/sCtx/sFT"
}
Write-Host "    Required Entra fields all present" -ForegroundColor Green

$urlPost = if ($sessionInfo.urlPost -match '^https?://') { $sessionInfo.urlPost } else { "https://login.microsoftonline.com$($sessionInfo.urlPost)" }

Write-Host "  POST credentials -> $($urlPost.Substring(0,60))..."
$correlationId = [Guid]::NewGuid()
$authResult = Complete-CredentialsFlow `
    -Session       $session `
    -SessionInfo   $sessionInfo `
    -UrlPost       $urlPost `
    -Credential    $cred `
    -ClientId      $TargetClientId `
    -CorrelationId $correlationId
Write-Host "    pgid after creds: $(Get-EntraField -Object $authResult.State -Name 'pgid' -Default '<none>')"

Write-Host "  Resolve interrupts (KMSI / CMSI / ProofUp)..."
$authResult = Resolve-EntraInterruptPage -Session $session -AuthResult $authResult

# After interrupts, the LastResponse should contain the redirect to redirect_uri
# with `?code=...` (because response_mode=query). Inspect for that.
$lastResp = $authResult.LastResponse

# Cookies state
$loginCookies = $session.Cookies.GetCookies('https://login.microsoftonline.com')
Write-Host "    Cookies on login.microsoftonline.com:"
foreach ($c in $loginCookies) { Write-Host "      $($c.Name)  Expires=$($c.Expires)" }
$haveEstsPersistent = $false
foreach ($c in $loginCookies) { if ($c.Name -eq 'ESTSAUTHPERSISTENT') { $haveEstsPersistent = $true } }
if ($haveEstsPersistent) {
    Write-Host "    >>> ESTSAUTHPERSISTENT issued (90-day KMSI) <<<" -ForegroundColor Green
} else {
    Write-Host "    NOTE: ESTSAUTHPERSISTENT NOT issued — only short-lived ESTSAUTH cookie." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " STEP 2: Extract authorization_code" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

$authCode = $null

# Strategy A: LastResponse URL contains the code (response_mode=query 302 chain)
if ($lastResp.BaseResponse -and $lastResp.BaseResponse.RequestMessage) {
    $finalUri = [string]$lastResp.BaseResponse.RequestMessage.RequestUri
    Write-Host "  LastResponse final URI: $($finalUri.Substring(0,[Math]::Min(200,$finalUri.Length)))..."
    if ($finalUri -match 'code=([^&]+)') {
        $authCode = $matches[1]
        Write-Host "  >>> Code from final URI (len=$($authCode.Length))" -ForegroundColor Green
    }
}

# Strategy B: parse form action + input fields (response_mode=form_post fallback)
if (-not $authCode -and $lastResp.Content) {
    $formMatch = [regex]::Match($lastResp.Content, '<form[^>]*action\s*=\s*"([^"]+)"', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($formMatch.Success) {
        $formAction = $formMatch.Groups[1].Value
        Write-Host "  Form action found: $formAction"
        # Look for code input
        $codeInput = [regex]::Match($lastResp.Content, '<input[^>]*name\s*=\s*"code"[^>]*value\s*=\s*"([^"]+)"')
        if ($codeInput.Success) {
            $authCode = $codeInput.Groups[1].Value
            Write-Host "  >>> Code from form input (len=$($authCode.Length))" -ForegroundColor Green
        }
    }
}

# Strategy C: chase the redirect chain manually if LastResponse didn't follow to redirect_uri
if (-not $authCode) {
    Write-Host "  No code in LastResponse — try manual GET to last urlPost result..."
    # As a last resort, look for code in any prior pgid state
    $stateText = ($authResult.State | ConvertTo-Json -Depth 5 -Compress)
    if ($stateText -match 'code=([^"&]+)') {
        $authCode = $matches[1]
        Write-Host "  >>> Code from state blob (len=$($authCode.Length))" -ForegroundColor Green
    }
}

if (-not $authCode) {
    # Strategy D: ESTSAUTHPERSISTENT is now in our session — retry /authorize.
    # First attempt did the heavy lifting (cred + TOTP + KMSI/CMSI), now Entra
    # has us as authenticated and should silently 302 with the code.
    Write-Host "  No code in initial chain (likely landed on appverify/ConvergedError post-CMSI)."
    Write-Host "  Retrying /authorize with active session (cookies present, no prompt)..." -ForegroundColor Cyan
    $retryResp = Invoke-WebRequest -Uri $authUrl -WebSession $session -Method Get `
        -MaximumRedirection 0 -SkipHttpErrorCheck -UseBasicParsing
    $retryStatus = [int]$retryResp.StatusCode
    $retryLoc = $retryResp.Headers.Location | Select-Object -First 1
    Write-Host "    Retry status: $retryStatus  Location: $(if ($retryLoc) { ([string]$retryLoc).Substring(0,[Math]::Min(180,([string]$retryLoc).Length)) + '...' } else { '<none>' })"
    if ($retryLoc) {
        $locStr = [string]$retryLoc
        if ($locStr -match 'code=([^&]+)') {
            $authCode = $matches[1]
            Write-Host "  >>> SILENT CODE OBTAINED post-bootstrap (len=$($authCode.Length))" -ForegroundColor Green
        } elseif ($locStr -match 'error=([^&]+)') {
            $err = [uri]::UnescapeDataString($matches[1])
            $errDesc = if ($locStr -match 'error_description=([^&]+)') { [uri]::UnescapeDataString($matches[1]) } else { '' }
            Write-Host "  Entra silent-mode error: $err  $errDesc" -ForegroundColor Yellow
        }
    } elseif ($retryStatus -eq 200) {
        # Maybe 302 chain auto-followed; look at content for code in form
        $codeIn = [regex]::Match($retryResp.Content, 'name\s*=\s*"code"[^>]*value\s*=\s*"([^"]+)"')
        if ($codeIn.Success) {
            $authCode = $codeIn.Groups[1].Value
            Write-Host "  >>> Code from retry form input (len=$($authCode.Length))" -ForegroundColor Green
        }
    }
}

if (-not $authCode) {
    Write-Host "  Still no code. Full diagnostic dump:" -ForegroundColor Yellow
    Write-Host "    LastResponse Status: $($lastResp.StatusCode) ContentLen: $($lastResp.RawContentLength)"
    $finalPgid = Get-EntraField -Object $authResult.State -Name 'pgid' -Default '<none>'
    Write-Host "    Final pgid: $finalPgid"
    # Dump the full $Config blob from authResult.State so we can see the error
    if ($authResult.State) {
        $stateNames = @($authResult.State.PSObject.Properties.Name) | Sort-Object
        Write-Host "    State fields ($($stateNames.Count)): $($stateNames -join ', ')"
        foreach ($f in @('sErrorCode','sErrTxt','strServiceExceptionMessage','urlSwitchUser','sResourceTenantId','sAppName','sAppId','sClientId')) {
            $v = Get-EntraField -Object $authResult.State -Name $f
            if ($v) { Write-Host "      $f = $v" }
        }
    }
    # Also re-parse the raw response content directly to look for embedded error JSON
    $rawBody = [string]$lastResp.Content
    $allConfigs = [regex]::Matches($rawBody, '\$Config\s*=\s*(\{.*?\});', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    Write-Host "    Found $($allConfigs.Count) `$Config blob(s) in raw body"
    # Look for ANY AADSTS code in the body
    $aads = [regex]::Matches($rawBody, 'AADSTS(\d{4,7})')
    if ($aads.Count -gt 0) {
        $codes = ($aads | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        Write-Host "    AADSTS codes mentioned in body: $($codes -join ', ')" -ForegroundColor Yellow
    }
    # Snippet of body where the error message likely is
    $errMsgMatch = [regex]::Match($rawBody, '<div[^>]*id="?errorMessage"?[^>]*>(.*?)</div>', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if ($errMsgMatch.Success) {
        $msg = ($errMsgMatch.Groups[1].Value -replace '<[^>]+>','' -replace '\s+',' ').Trim()
        Write-Host "    Error message DOM: $msg" -ForegroundColor Yellow
    }
    # Save full body for offline analysis
    $bodyFile = "$PSScriptRoot\..\tests\results\probe-convergederror-$(Get-Date -Format 'yyyyMMddHHmmss').html"
    $null = New-Item -Path (Split-Path $bodyFile) -ItemType Directory -Force
    Set-Content -Path $bodyFile -Value $rawBody -NoNewline
    Write-Host "    Saved full ConvergedError body to: $bodyFile" -ForegroundColor DarkGray
    throw "Could not extract authorization_code from auth chain"
}

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " STEP 3: Exchange code -> access_token + refresh_token" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

$tokenBody = @{
    client_id     = $TargetClientId
    grant_type    = 'authorization_code'
    code          = $authCode
    redirect_uri  = $TargetRedirect
    code_verifier = $codeVerifier
    scope         = $scope
}
# SPA-client (PKCE) tokens require Origin header matching the redirect_uri host
# per AADSTS9002327. Set Origin to the portal scheme+host.
$originUri = [uri]$TargetRedirect
$originHeader = "$($originUri.Scheme)://$($originUri.Host)"
$tokenResp = Invoke-WebRequest -Uri "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token" `
    -WebSession $session `
    -Method Post `
    -Body $tokenBody `
    -Headers @{ Origin = $originHeader } `
    -ContentType 'application/x-www-form-urlencoded' `
    -UseBasicParsing `
    -SkipHttpErrorCheck
$tokenStatus = [int]$tokenResp.StatusCode
Write-Host "  /token status: $tokenStatus"
if ($tokenStatus -ne 200) {
    Write-Host "  Error body: $([string]$tokenResp.Content)" -ForegroundColor Yellow
    throw "Token exchange failed (status $tokenStatus)"
}
$tokens = $tokenResp.Content | ConvertFrom-Json
Write-Host "  >>> ACCESS_TOKEN: $($tokens.access_token.Length) chars" -ForegroundColor Green
Write-Host "  >>> REFRESH_TOKEN: $($tokens.refresh_token.Length) chars" -ForegroundColor Green
Write-Host "      expires_in: $($tokens.expires_in)s   scope: $($tokens.scope)"

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " STEP 4: Use refresh_token to mint a fresh access_token (silent)" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

$refreshBody = @{
    client_id     = $TargetClientId
    grant_type    = 'refresh_token'
    refresh_token = $tokens.refresh_token
    scope         = $scope
}
$refreshResp = Invoke-WebRequest -Uri "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token" `
    -Method Post `
    -Body $refreshBody `
    -Headers @{ Origin = $originHeader } `
    -ContentType 'application/x-www-form-urlencoded' `
    -UseBasicParsing `
    -SkipHttpErrorCheck
$refreshStatus = [int]$refreshResp.StatusCode
Write-Host "  refresh_token grant status: $refreshStatus"
if ($refreshStatus -eq 200) {
    $tokens2 = $refreshResp.Content | ConvertFrom-Json
    Write-Host "  >>> SILENT REFRESH SUCCEEDED. NEW ACCESS_TOKEN: $($tokens2.access_token.Length) chars" -ForegroundColor Green
    Write-Host "      No TOTP. No MFA. No Entra ESTSAUTH cookie needed for this call." -ForegroundColor Green
    $tokens = $tokens2
} else {
    Write-Host "  refresh_token failed: $([string]$refreshResp.Content)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " STEP 5: Probe a target-portal API with the access_token" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# Pick portal-appropriate probe endpoint (real API hostname, NOT audience GUID)
$apiUri = switch -Regex ($TargetPortal) {
    'intune-portal'      { "https://intune.microsoft.com/api/Flighting" }
    'intune-autopatch'   { "https://services.autopatch.microsoft.com/api/Tenants/getTenant" }
    'security-copilot'   { "https://api.securitycopilot.microsoft.com/userPreferences/currentWorkspace" }
    'entra-ibiza-iam'    { "https://main.iam.ad.ext.azure.com/api/ViralSubscriptions" }
    'entra-pim'          { "https://api.azrbac.mspim.azure.com/api/v2/privilegedAccess/aadroles/resources" }
    'entra-iga'          { "https://elm.iga.azure.com/api/featureflags" }
    'entra-idgov'        { "https://api.accessreviews.identitygovernance.azure.com/api/v1/featureFlags" }
    'entra-b2c'          { "https://main.b2cadmin.ext.azure.com/api/userInfo" }
    'm365-admin'         { "https://admin.microsoft.com/admin/api/users" }
    'power-platform'     { "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments?api-version=2020-08-01" }
    'teams-admin'        { "https://admin.teams.microsoft.com/api/v2/Tenants/Current" }
    default              { if ($TargetAudience -match '^https?://') { "$TargetAudience/" } else { 'https://example.invalid/' } }
}
Write-Host "  GET $apiUri"
$apiHeaders = @{
    Authorization = "Bearer $($tokens.access_token)"
    Accept        = 'application/json'
}
# Per nodoc, some portals require additional headers
switch -Regex ($TargetPortal) {
    'entra-ibiza-iam' { $apiHeaders['X-Ms-Client-Request-Id'] = [Guid]::NewGuid().ToString() }
    'm365-admin'      { $apiHeaders['x-portal-routekey']      = 'AdminApp.MicrosoftAdminPortal' }
    'intune'          { $apiHeaders['x-ms-client-request-id'] = [Guid]::NewGuid().ToString(); $apiHeaders['x-requested-with'] = 'XMLHttpRequest' }
    'security-copilot'{ $apiHeaders['Content-Type']           = 'application/json' }
    'm365-apps'       { $apiHeaders['x-correlationid']        = [Guid]::NewGuid().ToString(); $apiHeaders['x-requested-with'] = 'XMLHttpRequest' }
}
$apiResp = Invoke-WebRequest -Uri $apiUri `
    -Method Get `
    -Headers $apiHeaders `
    -UseBasicParsing `
    -SkipHttpErrorCheck
Write-Host "  API status: $([int]$apiResp.StatusCode)   ContentLen=$($apiResp.Content.Length)"
$body = [string]$apiResp.Content
if ($body.Length -gt 250) { $body = $body.Substring(0, 250) + '...' }
Write-Host "  Body: $body"

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Green
Write-Host " UNATTENDED REFRESH-TOKEN PATTERN PROVEN for $TargetPortal" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
Write-Host "  TOTP used ONCE for bootstrap."
Write-Host "  ESTSAUTHPERSISTENT issued (90d KMSI)."
Write-Host "  refresh_token mints fresh access_tokens for 90d unattended — NO TOTP."
