# Probe-PortalEndpoints.ps1
#
# Live-probe ALL GET endpoints for a target portal using v1's TOTP auth chain +
# per-portal {clientId, redirect_uri, audience, headers} from _AUTH_RESEARCH.json.
# Writes live.json per endpoint + updates metadata.successKind.
#
# Bootstraps ONCE per portal (one TOTP burn), reuses token across all endpoints.

#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$Portal,
    [string]$EnvFile        = "$PSScriptRoot\..\..\xdrlograider\tests\.env.local",
    [string]$ReferencesRoot = "$PSScriptRoot\..\references",
    [int]$MaxEndpoints      = 0   # 0 = all
)

$ErrorActionPreference = 'Stop'
$v1Modules = "$PSScriptRoot\..\..\xdrlograider\src\Modules"

Get-Content $EnvFile | Where-Object { $_ -match '^[A-Z_]+=' } | ForEach-Object {
    $k,$v = $_ -split '=', 2; Set-Item -Path "env:$k" -Value $v
}

# Per-portal auth materials (proven this session + nodoc docs)
$portalAuthMap = @{
    'entra-ibiza-iam' = @{
        ClientId='c44b4083-3bb0-49c1-b47d-974e53cbdf3c'
        Redirect='https://entra.microsoft.com'
        Audience='74658136-14ec-4630-ad9b-26e160ff0fc6'
        ApiBase='https://main.iam.ad.ext.azure.com/api'
        ExtraHeaders=@{ 'X-Ms-Client-Request-Id'='__GUID__' }
    }
    'entra-pim' = @{
        # Azure PowerShell public client — broadly pre-authorized for Azure RBAC/PIM scopes
        ClientId='1950a258-227b-4e31-a9cf-717495945fc2'
        Redirect='https://login.microsoftonline.com/common/oauth2/nativeclient'
        Audience='https://api.azrbac.mspim.azure.com'
        ApiBase='https://api.azrbac.mspim.azure.com'
        ExtraHeaders=@{ 'X-Ms-Client-Request-Id'='__GUID__' }
    }
    'entra-iga' = @{
        ClientId='c44b4083-3bb0-49c1-b47d-974e53cbdf3c'
        Redirect='https://entra.microsoft.com'
        Audience='https://elm.iga.azure.com'
        ApiBase='https://elm.iga.azure.com'
        ExtraHeaders=@{ 'X-Ms-Client-Request-Id'='__GUID__' }
    }
    'entra-idgov' = @{
        ClientId='1950a258-227b-4e31-a9cf-717495945fc2'
        Redirect='https://login.microsoftonline.com/common/oauth2/nativeclient'
        Audience='https://api.accessreviews.identitygovernance.azure.com'
        ApiBase='https://api.accessreviews.identitygovernance.azure.com'
        ExtraHeaders=@{ 'X-Ms-Client-Request-Id'='__GUID__' }
    }
    'entra-b2c' = @{
        ClientId='c44b4083-3bb0-49c1-b47d-974e53cbdf3c'
        Redirect='https://entra.microsoft.com'
        Audience='https://main.b2cadmin.ext.azure.com'
        ApiBase='https://main.b2cadmin.ext.azure.com'
        ExtraHeaders=@{ 'X-Ms-Client-Request-Id'='__GUID__' }
        ExtraQueryParams=@{ 'tenantId'='__TENANT__' }   # per nodoc
    }
    'intune-portal' = @{
        ClientId='1950a258-227b-4e31-a9cf-717495945fc2'   # Azure PowerShell public client — broadly pre-authorized
        Redirect='https://login.microsoftonline.com/common/oauth2/nativeclient'
        Audience='https://api.manage.microsoft.com'        # Microsoft Intune Service API
        ApiBase='https://api.manage.microsoft.com'
        ExtraHeaders=@{ 'x-ms-client-request-id'='__GUID__' }
    }
    'power-platform' = @{
        ClientId='1950a258-227b-4e31-a9cf-717495945fc2'
        Redirect='https://login.microsoftonline.com/common/oauth2/nativeclient'
        Audience='https://api.bap.microsoft.com'
        ApiBase='https://api.bap.microsoft.com'
        ExtraHeaders=@{ 'x-ms-client-request-id'='__GUID__' }
    }
    'security-copilot' = @{
        ClientId='1950a258-227b-4e31-a9cf-717495945fc2'
        Redirect='https://login.microsoftonline.com/common/oauth2/nativeclient'
        Audience='https://api.securitycopilot.microsoft.com'
        ApiBase='https://api.securitycopilot.microsoft.com'
        ExtraHeaders=@{}
    }
    'viva' = @{
        ClientId='c1c74fed-04c9-4704-80dc-9f79a2e515cb'   # Discovered from engage.cloud.microsoft JS bundle
        Redirect='https://engage.cloud.microsoft'
        Audience='https://www.yammer.com/user_impersonation'
        ApiBase='https://engage.cloud.microsoft'
        ExtraHeaders=@{}
    }
}

if (-not $portalAuthMap.ContainsKey($Portal)) {
    Write-Host "Portal '$Portal' not in proven-auth-map. Known: $($portalAuthMap.Keys -join ', ')" -ForegroundColor Yellow
    exit 1
}
$auth = $portalAuthMap[$Portal]
$tenant = $env:AZURE_TENANT_ID
$userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0'

# Dot-source v1's auth helpers
Import-Module (Join-Path $v1Modules 'Xdr.Common.Telemetry\Xdr.Common.Telemetry.psd1') -Force -Global
$authPriv = Join-Path $v1Modules 'Xdr.Common.Auth\Private'
. (Join-Path $authPriv 'Get-EntraFields.ps1')
. (Join-Path $authPriv 'Get-TotpCode.ps1')
. (Join-Path $authPriv 'Complete-TotpMfa.ps1')
. (Join-Path $authPriv 'Complete-CredentialsFlow.ps1')
$authPub = Join-Path $v1Modules 'Xdr.Common.Auth\Public'
. (Join-Path $authPub 'Resolve-EntraInterruptPage.ps1')

$cred = @{ upn=$env:XDRLR_TEST_UPN; password=$env:XDRLR_TEST_PASSWORD; totpBase32=$env:XDRLR_TEST_TOTP_SECRET }

# ---------------------------------------------------------------------------
# Step 1: bootstrap auth (TOTP chain → access_token + refresh_token)
# ---------------------------------------------------------------------------
Write-Host "=== Bootstrap auth for $Portal ===" -ForegroundColor Cyan

$verifierBytes = [byte[]]::new(32)
[System.Security.Cryptography.RandomNumberGenerator]::Fill($verifierBytes)
$codeVerifier = [Convert]::ToBase64String($verifierBytes).TrimEnd('=').Replace('+','-').Replace('/','_')
$challengeBytes = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::ASCII.GetBytes($codeVerifier))
$codeChallenge  = [Convert]::ToBase64String($challengeBytes).TrimEnd('=').Replace('+','-').Replace('/','_')

$state = [Guid]::NewGuid().ToString('N')
$nonce = [Guid]::NewGuid().ToString('N')
$scope = "$($auth.Audience)/.default offline_access openid profile"

$authUrl = "https://login.microsoftonline.com/$tenant/oauth2/v2.0/authorize?" + (@(
    "client_id=$($auth.ClientId)",
    "response_type=code",
    "redirect_uri=$([uri]::EscapeDataString($auth.Redirect))",
    "response_mode=query",
    "scope=$([uri]::EscapeDataString($scope))",
    "state=$state",
    "nonce=$nonce",
    "code_challenge=$codeChallenge",
    "code_challenge_method=S256"
) -join '&')

$session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
$session.UserAgent = $userAgent

$initResp = Invoke-WebRequest -Uri $authUrl -WebSession $session -UseBasicParsing -MaximumRedirection 10
$sessionInfo = Get-EntraConfigBlob -Html $initResp.Content
if (-not $sessionInfo) { throw "No `$Config from /authorize" }
$urlPost = if ($sessionInfo.urlPost -match '^https?://') { $sessionInfo.urlPost } else { "https://login.microsoftonline.com$($sessionInfo.urlPost)" }

$correlationId = [Guid]::NewGuid()
$authResult = Complete-CredentialsFlow -Session $session -SessionInfo $sessionInfo -UrlPost $urlPost -Credential $cred -ClientId $auth.ClientId -CorrelationId $correlationId
$authResult = Resolve-EntraInterruptPage -Session $session -AuthResult $authResult

# Extract code from final URI
$authCode = $null
if ($authResult.LastResponse -and $authResult.LastResponse.BaseResponse) {
    $finalUri = [string]$authResult.LastResponse.BaseResponse.RequestMessage.RequestUri
    if ($finalUri -match 'code=([^&]+)') { $authCode = $matches[1] }
    Write-Host "  Final URI: $($finalUri.Substring(0,[Math]::Min(200,$finalUri.Length)))..."
}
if (-not $authCode) {
    Write-Host "  No code in final URI. Examining LastResponse state..." -ForegroundColor Yellow
    $state = $authResult.State
    if ($state) {
        $names = @($state.PSObject.Properties.Name)
        $pgid = if ($names -contains 'pgid') { $state.pgid } else { '<none>' }
        $errCode = if ($names -contains 'sErrorCode') { $state.sErrorCode } else { '<none>' }
        $errTxt = if ($names -contains 'sErrTxt') { $state.sErrTxt } else { '' }
        $svcErr = if ($names -contains 'strServiceExceptionMessage') { $state.strServiceExceptionMessage } else { '' }
        Write-Host "    pgid: $pgid"
        Write-Host "    sErrorCode: AADSTS$errCode"
        if ($errTxt) { Write-Host "    sErrTxt: $errTxt" }
        if ($svcErr) { Write-Host "    svcException: $($svcErr.Substring(0,[Math]::Min(400,$svcErr.Length)))" -ForegroundColor Yellow }
    }
    # Try retrying /authorize with the now-authenticated session
    Write-Host "  Retry /authorize with active session..."
    $retry = Invoke-WebRequest -Uri $authUrl -WebSession $session -MaximumRedirection 0 -SkipHttpErrorCheck -UseBasicParsing
    $loc = $retry.Headers.Location | Select-Object -First 1
    if ($loc -and ([string]$loc -match 'code=([^&]+)')) {
        $authCode = $matches[1]
        Write-Host "  Code obtained on retry (len=$($authCode.Length))" -ForegroundColor Green
    } elseif ($loc) {
        Write-Host "  Retry redirect: $loc" -ForegroundColor Yellow
    }
    if (-not $authCode) { throw "Could not extract authorization_code (see diagnostics above)" }
}
Write-Host "  Auth code obtained (len=$($authCode.Length))" -ForegroundColor Green

# Token exchange
$tokenBody = @{
    client_id     = $auth.ClientId
    grant_type    = 'authorization_code'
    code          = $authCode
    redirect_uri  = $auth.Redirect
    code_verifier = $codeVerifier
    scope         = $scope
}
$originUri = [uri]$auth.Redirect
$originHeader = "$($originUri.Scheme)://$($originUri.Host)"
$tokenResp = Invoke-WebRequest -Uri "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token" `
    -WebSession $session -Method Post -Body $tokenBody `
    -Headers @{ Origin = $originHeader } `
    -ContentType 'application/x-www-form-urlencoded' -UseBasicParsing -SkipHttpErrorCheck

if ([int]$tokenResp.StatusCode -ne 200) { throw "Token exchange failed: $([string]$tokenResp.Content)" }
$tokens = $tokenResp.Content | ConvertFrom-Json
Write-Host "  access_token issued ($($tokens.access_token.Length) chars) for scope: $($tokens.scope)" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Step 2: iterate all GET endpoints, probe each, save live.json
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== Probing endpoints for $Portal ===" -ForegroundColor Cyan
$portalDir = Join-Path $ReferencesRoot $Portal
if (-not (Test-Path $portalDir)) { throw "Portal directory not found: $portalDir" }

$endpoints = Get-ChildItem -Path $portalDir -Recurse -Filter 'metadata.json'
Write-Host "  Found $($endpoints.Count) endpoints"
if ($MaxEndpoints -gt 0 -and $endpoints.Count -gt $MaxEndpoints) {
    $endpoints = $endpoints | Select-Object -First $MaxEndpoints
    Write-Host "  Probing first $MaxEndpoints only"
}

$stats = @{ probed=0; live=0; liveEmpty=0; error=0; nonGet=0 }
foreach ($epFile in $endpoints) {
    $epDir = Split-Path $epFile.FullName -Parent
    try {
        $meta = Get-Content $epFile.FullName -Raw | ConvertFrom-Json
    } catch { continue }

    # Only probe GET endpoints
    $methods = @($meta.methods | ForEach-Object { $_.ToString().ToLower() })
    if ($methods -notcontains 'get') { $stats.nonGet++; continue }

    # Build URL with portal extras
    $apiPath = $meta.path
    if (-not $apiPath) { continue }
    # Skip endpoints with path templates we can't fill in
    if ($apiPath -match '\{[^}]+\}') { continue }

    $url = "$($auth.ApiBase)$apiPath"
    if ($auth.ExtraQueryParams) {
        $qp = @()
        foreach ($k in $auth.ExtraQueryParams.Keys) {
            $v = $auth.ExtraQueryParams[$k]
            if ($v -eq '__TENANT__') { $v = $env:AZURE_TENANT_ID }
            $qp += "$k=$([uri]::EscapeDataString($v))"
        }
        $sep = if ($url -match '\?') { '&' } else { '?' }
        $url = $url + $sep + ($qp -join '&')
    }

    $hdrs = @{ Authorization = "Bearer $($tokens.access_token)"; Accept = 'application/json' }
    if ($auth.ExtraHeaders) {
        foreach ($k in $auth.ExtraHeaders.Keys) {
            $v = $auth.ExtraHeaders[$k]
            if ($v -eq '__GUID__') { $v = [Guid]::NewGuid().ToString() }
            $hdrs[$k] = $v
        }
    }

    $stats.probed++
    $resp = $null
    $err = $null
    try {
        $resp = Invoke-WebRequest -Uri $url -Method Get -Headers $hdrs -UseBasicParsing -TimeoutSec 20 -SkipHttpErrorCheck -ErrorAction Stop
    } catch { $err = $_.Exception.Message }

    $successKind = 'error'
    $statusCode = if ($resp) { [int]$resp.StatusCode } else { 0 }
    $body = if ($resp) { [string]$resp.Content } else { $err }
    $contentLen = if ($body) { $body.Length } else { 0 }

    if ($statusCode -eq 200) {
        # Determine live vs live-empty
        try {
            $j = $body | ConvertFrom-Json -ErrorAction Stop
            if ($j -is [array]) {
                $successKind = if ($j.Count -gt 0) { 'live' } else { 'live-empty' }
            } elseif ($j -is [pscustomobject]) {
                $names = @($j.PSObject.Properties.Name)
                if ($names.Count -gt 0 -and -not ($names -contains 'value' -and (@($j.value)).Count -eq 0)) {
                    $successKind = 'live'
                } else {
                    $successKind = 'live-empty'
                }
            } else {
                $successKind = 'live'
            }
        } catch {
            # Not JSON — text response
            $successKind = if ($contentLen -gt 0) { 'live' } else { 'live-empty' }
        }
    } elseif ($statusCode -eq 429) { $successKind = 'rate-limited' }

    # Truncate body in live.json
    $bodySnippet = if ($body -and $body.Length -gt 4000) { $body.Substring(0, 4000) + '...[truncated]' } else { $body }

    $live = [ordered]@{
        portal       = $Portal
        path         = $meta.path
        method       = 'GET'
        url          = $url
        httpStatus   = $statusCode
        successKind  = $successKind
        contentLen   = $contentLen
        rawSample    = $bodySnippet
        capturedUtc  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    $live | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $epDir 'live.json') -NoNewline

    # Update metadata with successKind
    $meta | Add-Member -NotePropertyName 'lastSuccessKind' -NotePropertyValue $successKind -Force
    $meta | Add-Member -NotePropertyName 'lastHttpStatus'  -NotePropertyValue $statusCode  -Force
    $meta | ConvertTo-Json -Depth 12 | Set-Content -Path $epFile.FullName -NoNewline

    switch ($successKind) {
        'live' { $stats.live++ }
        'live-empty' { $stats.liveEmpty++ }
        default { $stats.error++ }
    }

    $shortPath = if ($meta.path.Length -gt 50) { '...' + $meta.path.Substring($meta.path.Length-47) } else { $meta.path }
    $color = switch ($successKind) { 'live' {'Green'}; 'live-empty' {'DarkGray'}; default {'Yellow'} }
    Write-Host ("  [{0,-12}] {1,3} {2}" -f $successKind, $statusCode, $shortPath) -ForegroundColor $color
}

Write-Host ""
Write-Host "=== $Portal probe complete ===" -ForegroundColor Cyan
Write-Host "  Probed (GET, no path-params): $($stats.probed)"
Write-Host "  Live:        $($stats.live)" -ForegroundColor Green
Write-Host "  Live-empty:  $($stats.liveEmpty)"
Write-Host "  Error/other: $($stats.error)" -ForegroundColor Yellow
Write-Host "  Skipped (non-GET or path-templated): $($stats.nonGet)"
