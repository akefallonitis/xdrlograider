# Probe-PortalEndpoints-V2.ps1 (senior-dev edition)
#
# Comprehensive live probe per portal:
#   - Reads metadata.json -> parameters[] from nodoc and AUTO-FILLS required query params (api-version, $top, etc.)
#   - Handles path-templated endpoints: skip {id} placeholders; for safe-defaults (e.g., 'me', 'current'), try them
#   - Classifies responses: live / live-empty / rate-limited / tenant-gated / request-shape-error / network-error
#   - Captures EVERY response (success or error) to live.json for forensic audit
#   - Production-tenant ready: respects pagination + time-filter params
#
# Auth uses universal Microsoft public client (1950a258 Azure PowerShell) OR per-portal client per nodoc.

#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$Portal,
    [string]$EnvFile        = "$PSScriptRoot\..\..\xdrlograider\tests\.env.local",
    [string]$ReferencesRoot = "$PSScriptRoot\..\references",
    [int]$MaxEndpoints      = 0
)

$ErrorActionPreference = 'Stop'
$v1Modules = "$PSScriptRoot\..\..\xdrlograider\src\Modules"

Get-Content $EnvFile | Where-Object { $_ -match '^[A-Z_]+=' } | ForEach-Object {
    $k,$v = $_ -split '=', 2; Set-Item -Path "env:$k" -Value $v
}

# Auth map per portal (clientId + redirect + audience + apiBase + extra headers)
# Notes:
# - 1950a258 = Azure PowerShell public client (broadly pre-authorized for Azure-side resources)
# - c44b4083 = Microsoft Azure AD client (Azure portal + Entra family SPA)
# - 80ccca67 = Defender XDR / Purview (sccauth cookie chain)
# - 4765445b = M365 Admin / Exchange (cookie chain)
$portalAuthMap = @{
    'entra-ibiza-iam' = @{ ClientId='c44b4083-3bb0-49c1-b47d-974e53cbdf3c'; Redirect='https://entra.microsoft.com'; Audience='74658136-14ec-4630-ad9b-26e160ff0fc6'; ApiBase='https://main.iam.ad.ext.azure.com/api'; ExtraHeaders=@{ 'X-Ms-Client-Request-Id'='__GUID__' }; PortalIsCookie=$false }
    'entra-pim'       = @{ ClientId='1950a258-227b-4e31-a9cf-717495945fc2'; Redirect='https://login.microsoftonline.com/common/oauth2/nativeclient'; Audience='https://api.azrbac.mspim.azure.com'; ApiBase='https://api.azrbac.mspim.azure.com'; ExtraHeaders=@{ 'X-Ms-Client-Request-Id'='__GUID__' } }
    'entra-iga'       = @{ ClientId='c44b4083-3bb0-49c1-b47d-974e53cbdf3c'; Redirect='https://entra.microsoft.com'; Audience='https://elm.iga.azure.com'; ApiBase='https://elm.iga.azure.com'; ExtraHeaders=@{ 'X-Ms-Client-Request-Id'='__GUID__' } }
    'entra-idgov'     = @{ ClientId='1950a258-227b-4e31-a9cf-717495945fc2'; Redirect='https://login.microsoftonline.com/common/oauth2/nativeclient'; Audience='https://api.accessreviews.identitygovernance.azure.com'; ApiBase='https://api.accessreviews.identitygovernance.azure.com'; ExtraHeaders=@{ 'X-Ms-Client-Request-Id'='__GUID__' } }
    'entra-b2c'       = @{ ClientId='1950a258-227b-4e31-a9cf-717495945fc2'; Redirect='https://login.microsoftonline.com/common/oauth2/nativeclient'; Audience='https://main.b2cadmin.ext.azure.com'; ApiBase='https://main.b2cadmin.ext.azure.com'; ExtraHeaders=@{ 'X-Ms-Client-Request-Id'='__GUID__' }; ExtraQueryParams=@{ 'tenantId'='__TENANT__' } }
    'intune-portal'   = @{ ClientId='1950a258-227b-4e31-a9cf-717495945fc2'; Redirect='https://login.microsoftonline.com/common/oauth2/nativeclient'; Audience='https://api.manage.microsoft.com'; ApiBase='https://intune.microsoft.com'; ExtraHeaders=@{ 'x-ms-client-request-id'='__GUID__' } }
    'intune-autopatch'= @{ ClientId='1950a258-227b-4e31-a9cf-717495945fc2'; Redirect='https://login.microsoftonline.com/common/oauth2/nativeclient'; Audience='https://api.manage.microsoft.com'; ApiBase='https://services.autopatch.microsoft.com'; ExtraHeaders=@{ 'x-ms-client-request-id'='__GUID__' } }
    'power-platform'  = @{ ClientId='1950a258-227b-4e31-a9cf-717495945fc2'; Redirect='https://login.microsoftonline.com/common/oauth2/nativeclient'; Audience='https://api.bap.microsoft.com'; ApiBase='https://api.bap.microsoft.com'; ExtraHeaders=@{ 'x-ms-client-request-id'='__GUID__' } }
    'security-copilot'= @{ ClientId='1950a258-227b-4e31-a9cf-717495945fc2'; Redirect='https://login.microsoftonline.com/common/oauth2/nativeclient'; Audience='https://api.securitycopilot.microsoft.com'; ApiBase='https://api.securitycopilot.microsoft.com'; ExtraHeaders=@{} }
    'm365-admin'      = @{ ClientId='1950a258-227b-4e31-a9cf-717495945fc2'; Redirect='https://login.microsoftonline.com/common/oauth2/nativeclient'; Audience='https://admin.microsoft.com';    ApiBase='https://admin.microsoft.com';        ExtraHeaders=@{ 'x-portal-routekey'='AdminApp.MicrosoftAdminPortal'; 'x-adminapp-request'='hub' } }
    'teams'           = @{ ClientId='1950a258-227b-4e31-a9cf-717495945fc2'; Redirect='https://login.microsoftonline.com/common/oauth2/nativeclient'; Audience='https://api.spaces.skype.com';   ApiBase='https://admin.teams.microsoft.com'; ExtraHeaders=@{ 'x-ms-client-request-id'='__GUID__' } }
    'viva'            = @{ ClientId='c1c74fed-04c9-4704-80dc-9f79a2e515cb'; Redirect='https://engage.cloud.microsoft';                              Audience='https://www.yammer.com';           ApiBase='https://engage.cloud.microsoft';     ExtraHeaders=@{} }
    'm365-apps-config'= @{ ClientId='1950a258-227b-4e31-a9cf-717495945fc2'; Redirect='https://login.microsoftonline.com/common/oauth2/nativeclient'; Audience='https://manage.office.com';       ApiBase='https://config.office.com';          ExtraHeaders=@{ 'x-api-name'='admin-portal'; 'x-correlationid'='__GUID__'; 'x-requested-with'='XMLHttpRequest' } }
    'm365-apps-services'= @{ ClientId='1950a258-227b-4e31-a9cf-717495945fc2'; Redirect='https://login.microsoftonline.com/common/oauth2/nativeclient'; Audience='https://manage.office.com';     ApiBase='https://clients.config.office.net'; ExtraHeaders=@{ 'x-api-name'='admin-portal'; 'x-correlationid'='__GUID__'; 'x-requested-with'='XMLHttpRequest' } }
    'm365-apps-inventory'= @{ ClientId='1950a258-227b-4e31-a9cf-717495945fc2'; Redirect='https://login.microsoftonline.com/common/oauth2/nativeclient'; Audience='https://manage.office.com';   ApiBase='https://query.inventory.insights.office.net'; ExtraHeaders=@{ 'x-api-name'='inventory'; 'x-correlationid'='__GUID__'; 'x-requested-with'='XMLHttpRequest' } }
    'sharepoint'      = @{ ClientId='1950a258-227b-4e31-a9cf-717495945fc2'; Redirect='https://login.microsoftonline.com/common/oauth2/nativeclient'; Audience='00000003-0000-0ff1-ce00-000000000000'; ApiBase='https://cloudsectra-admin.sharepoint.com/_api'; ExtraHeaders=@{ 'accept'='application/json;odata=verbose' } }
    'purview-portal'  = @{ ClientId='80ccca67-54bd-44ab-8625-4b79c4dc7775'; Redirect='https://purview.microsoft.com';                                 Audience='https://purview.microsoft.com';   ApiBase='https://purview.microsoft.com';     ExtraHeaders=@{} }
}

if (-not $portalAuthMap.ContainsKey($Portal)) {
    Write-Host "Portal '$Portal' not in auth map. Available: $($portalAuthMap.Keys -join ', ')" -ForegroundColor Yellow; exit 1
}
$auth = $portalAuthMap[$Portal]
$tenant = $env:AZURE_TENANT_ID
$userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0'

# Lift PS default redirect limit to 30 (some portals' MFA chains exceed PS default of 5)
$PSDefaultParameterValues['Invoke-WebRequest:MaximumRedirection'] = 30

# Dot-source v1's auth helpers
Import-Module (Join-Path $v1Modules 'Xdr.Common.Telemetry\Xdr.Common.Telemetry.psd1') -Force -Global
$authPriv = Join-Path $v1Modules 'Xdr.Common.Auth\Private'
. (Join-Path $authPriv 'Get-EntraFields.ps1')
. (Join-Path $authPriv 'Get-TotpCode.ps1')
. (Join-Path $authPriv 'Complete-TotpMfa.ps1')
. (Join-Path $authPriv 'Complete-CredentialsFlow.ps1')
$authPub = Join-Path $v1Modules 'Xdr.Common.Auth\Public'
. (Join-Path $authPub 'Resolve-EntraInterruptPage.ps1')

# v2 OVERRIDE: re-source Complete-TotpMfa from v2 module (MaximumRedirection=30 for SharePoint)
. "$PSScriptRoot\..\src\Modules\Xdr.Common.AuthV2\Private\Complete-TotpMfa.ps1"

$cred = @{ upn=$env:XDRLR_TEST_UPN; password=$env:XDRLR_TEST_PASSWORD; totpBase32=$env:XDRLR_TEST_TOTP_SECRET }

# ---------------------------------------------------------------------------
# Bootstrap auth (TOTP chain -> code -> access_token)
# ---------------------------------------------------------------------------
Write-Host "=== Bootstrap auth for $Portal ===" -ForegroundColor Cyan
$verifierBytes = [byte[]]::new(32)
[System.Security.Cryptography.RandomNumberGenerator]::Fill($verifierBytes)
$codeVerifier = [Convert]::ToBase64String($verifierBytes).TrimEnd('=').Replace('+','-').Replace('/','_')
$challengeBytes = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::ASCII.GetBytes($codeVerifier))
$codeChallenge  = [Convert]::ToBase64String($challengeBytes).TrimEnd('=').Replace('+','-').Replace('/','_')
$state = [Guid]::NewGuid().ToString('N'); $nonce = [Guid]::NewGuid().ToString('N')
$scope = "$($auth.Audience)/.default offline_access openid profile"
$authUrl = "https://login.microsoftonline.com/$tenant/oauth2/v2.0/authorize?" + (@(
    "client_id=$($auth.ClientId)", "response_type=code", "redirect_uri=$([uri]::EscapeDataString($auth.Redirect))",
    "response_mode=query", "scope=$([uri]::EscapeDataString($scope))",
    "state=$state", "nonce=$nonce", "code_challenge=$codeChallenge", "code_challenge_method=S256"
) -join '&')
$session = [Microsoft.PowerShell.Commands.WebRequestSession]::new(); $session.UserAgent = $userAgent
$initResp = Invoke-WebRequest -Uri $authUrl -WebSession $session -UseBasicParsing -MaximumRedirection 10
$sessionInfo = Get-EntraConfigBlob -Html $initResp.Content
if (-not $sessionInfo) { throw "Bootstrap: no `$Config" }
$urlPost = if ($sessionInfo.urlPost -match '^https?://') { $sessionInfo.urlPost } else { "https://login.microsoftonline.com$($sessionInfo.urlPost)" }
$correlationId = [Guid]::NewGuid()
$authResult = Complete-CredentialsFlow -Session $session -SessionInfo $sessionInfo -UrlPost $urlPost -Credential $cred -ClientId $auth.ClientId -CorrelationId $correlationId
$authResult = Resolve-EntraInterruptPage -Session $session -AuthResult $authResult

$authCode = $null
if ($authResult.LastResponse -and $authResult.LastResponse.BaseResponse) {
    $finalUri = [string]$authResult.LastResponse.BaseResponse.RequestMessage.RequestUri
    if ($finalUri -match 'code=([^&]+)') { $authCode = $matches[1] }
}
if (-not $authCode) { throw "Bootstrap: no code in final URI: $finalUri" }
Write-Host "  Code: $($authCode.Length) chars" -ForegroundColor Green

$tokenBody = @{ client_id=$auth.ClientId; grant_type='authorization_code'; code=$authCode; redirect_uri=$auth.Redirect; code_verifier=$codeVerifier; scope=$scope }
$originUri = [uri]$auth.Redirect; $originHeader = "$($originUri.Scheme)://$($originUri.Host)"
$tokenResp = Invoke-WebRequest -Uri "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token" -WebSession $session -Method Post -Body $tokenBody -Headers @{ Origin = $originHeader } -ContentType 'application/x-www-form-urlencoded' -UseBasicParsing -SkipHttpErrorCheck
if ([int]$tokenResp.StatusCode -ne 200) { throw "Token exchange failed: $([string]$tokenResp.Content)" }
$tokens = $tokenResp.Content | ConvertFrom-Json
Write-Host "  access_token: $($tokens.access_token.Length) chars, scope=$($tokens.scope)" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Iterate ALL endpoints; auto-fill nodoc parameters per endpoint
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== Probing $Portal endpoints (V2: nodoc-param-aware) ===" -ForegroundColor Cyan
$portalDir = Join-Path $ReferencesRoot $Portal
$endpoints = Get-ChildItem -Path $portalDir -Recurse -Filter 'metadata.json'
Write-Host "  Found $($endpoints.Count) endpoint metadata files"
if ($MaxEndpoints -gt 0 -and $endpoints.Count -gt $MaxEndpoints) { $endpoints = $endpoints | Select-Object -First $MaxEndpoints }

$stats = @{ probed=0; live=0; liveEmpty=0; tenantGated=0; rateLimited=0; requestShape=0; networkErr=0; nonGet=0; pathTemplate=0 }

foreach ($epFile in $endpoints) {
    $epDir = Split-Path $epFile.FullName -Parent
    try { $meta = Get-Content $epFile.FullName -Raw | ConvertFrom-Json } catch { continue }
    $methods = @($meta.methods | ForEach-Object { $_.ToString().ToLower() })
    if ($methods -notcontains 'get') { $stats.nonGet++; continue }
    if (-not $meta.path) { continue }
    # Well-known path-template substitutions per portal (avoid skipping every templated endpoint)
    $resolvedPath = $meta.path
    if ($resolvedPath -match '\{[^}]+\}') {
        $substitutions = @{
            '{provider}'      = 'aadroles'                  # PIM Azure AD roles (most common)
            '{tenantId}'      = $env:AZURE_TENANT_ID
            '{tenant}'        = $env:AZURE_TENANT_ID
            '{userId}'        = $env:XDRLR_TEST_UPN
            '{providerId}'    = 'aadroles'
            '{resourceScope}' = 'aadroles'
        }
        $missing = $false
        foreach ($k in $substitutions.Keys) { $resolvedPath = $resolvedPath -replace [regex]::Escape($k), $substitutions[$k] }
        if ($resolvedPath -match '\{[^}]+\}') { $stats.pathTemplate++; continue }
    }
    $meta.path = $resolvedPath  # for URL build below

    # Build URL with portal extras + nodoc-derived query params
    $url = "$($auth.ApiBase)$($meta.path)"
    $qpHash = [ordered]@{}

    # Portal-extra query params (e.g. tenantId for B2C)
    if ($auth.ExtraQueryParams) {
        foreach ($k in $auth.ExtraQueryParams.Keys) {
            $v = $auth.ExtraQueryParams[$k]
            if ($v -eq '__TENANT__') { $v = $env:AZURE_TENANT_ID }
            $qpHash[$k] = $v
        }
    }

    # nodoc parameters: auto-fill required + defaulted query params
    if ($meta.parameters) {
        foreach ($p in @($meta.parameters)) {
            if ($p.in -ne 'query') { continue }
            if (-not $p.name) { continue }
            # If URL already contains this param, skip
            if ($url -match "[?&]$([regex]::Escape($p.name))=") { continue }
            if ($qpHash.Contains($p.name)) { continue }
            # Auto-fill required or default-having params
            $val = $null
            if ($p.default) { $val = $p.default }
            elseif ($p.required) {
                # Heuristic defaults for common required params
                $val = switch -Regex ($p.name) {
                    '^api-version$'          { '2020-08-01' ; break }
                    '^x-ms-correlation-id$'  { [Guid]::NewGuid().ToString() ; break }
                    '^\$top$'                { '100' ; break }
                    '^\$skip$'               { '0' ; break }
                    '^top$'                  { '100' ; break }
                    '^pageSize$'             { '100' ; break }
                    '^limit$'                { '100' ; break }
                    '^pageIndex$'            { '1' ; break }
                    '^tenantId$'             { $env:AZURE_TENANT_ID ; break }
                    default                  { $null }
                }
            }
            if ($val) { $qpHash[$p.name] = $val }
        }
    }

    # Heuristic: if URL host is api.bap.microsoft.com or api.azrbac.mspim.azure.com,
    # always include api-version=2020-08-01 if not present
    if ($url -match 'api\.bap\.microsoft\.com|api\.azrbac\.mspim\.azure\.com|management\.azure\.com' -and -not $qpHash.Contains('api-version')) {
        $qpHash['api-version'] = '2020-08-01'
    }

    # Append qpHash to URL
    if ($qpHash.Count -gt 0) {
        $qpParts = @()
        foreach ($k in $qpHash.Keys) { $qpParts += "$k=$([uri]::EscapeDataString([string]$qpHash[$k]))" }
        $sep = if ($url -match '\?') { '&' } else { '?' }
        $url = $url + $sep + ($qpParts -join '&')
    }

    # Headers
    $hdrs = @{ Authorization = "Bearer $($tokens.access_token)"; Accept = 'application/json' }
    if ($auth.ExtraHeaders) {
        foreach ($k in $auth.ExtraHeaders.Keys) {
            $v = $auth.ExtraHeaders[$k]
            if ($v -eq '__GUID__') { $v = [Guid]::NewGuid().ToString() }
            $hdrs[$k] = $v
        }
    }

    # Probe
    $stats.probed++
    $resp = $null; $netErr = $null
    try {
        $resp = Invoke-WebRequest -Uri $url -Method Get -Headers $hdrs -UseBasicParsing -TimeoutSec 20 -SkipHttpErrorCheck -ErrorAction Stop
    } catch { $netErr = $_.Exception.Message }

    $statusCode = if ($resp) { [int]$resp.StatusCode } else { 0 }
    $body       = if ($resp) { [string]$resp.Content } else { $netErr }
    $contentLen = if ($body) { $body.Length } else { 0 }

    # Smart classification
    $successKind = 'unclassified'
    $diagnostic = $null
    if ($statusCode -eq 200) {
        try {
            $j = $body | ConvertFrom-Json -ErrorAction Stop
            if ($j -is [array]) {
                $successKind = if ($j.Count -gt 0) { 'live' } else { 'live-empty' }
            } elseif ($j -is [pscustomobject]) {
                $names = @($j.PSObject.Properties.Name)
                $hasEmptyValue = ($names -contains 'value') -and ((@($j.value)).Count -eq 0)
                $hasEmptyResults = ($names -contains 'results') -and ((@($j.results)).Count -eq 0)
                if ($hasEmptyValue -or $hasEmptyResults -or $names.Count -eq 0) { $successKind = 'live-empty' }
                else { $successKind = 'live' }
            } else { $successKind = if ($contentLen -gt 0) { 'live' } else { 'live-empty' } }
        } catch {
            $successKind = if ($contentLen -gt 0) { 'live' } else { 'live-empty' }
        }
    }
    elseif ($statusCode -in 401, 403, 404) {
        $successKind = 'tenant-gated'      # license / RBAC / feature-flag
        $diagnostic = if ($body -match 'AADSTS|access\s+denied|unauthorized|forbidden|not\s+found') { $matches[0] } else { 'license/RBAC' }
    }
    elseif ($statusCode -eq 429) {
        $successKind = 'rate-limited'
    }
    elseif ($statusCode -in 400, 422) {
        $successKind = 'request-shape-error'
        # Try to extract Microsoft error code
        if ($body -match '"error_description"\s*:\s*"([^"]+)"') { $diagnostic = $matches[1] }
        elseif ($body -match '"Message"\s*:\s*"([^"]+)"') { $diagnostic = $matches[1] }
        elseif ($body -match '"message"\s*:\s*"([^"]+)"') { $diagnostic = $matches[1] }
        elseif ($body.Length -lt 400) { $diagnostic = $body -replace '\s+',' ' }
    }
    elseif ($statusCode -ge 500) {
        $successKind = 'server-error'
        $diagnostic = "HTTP $statusCode"
    }
    elseif ($statusCode -eq 0) {
        $successKind = 'network-error'
        $diagnostic = $netErr
    }
    else {
        $successKind = 'other'
        $diagnostic = "HTTP $statusCode"
    }

    # Tally
    switch ($successKind) {
        'live' { $stats.live++ }
        'live-empty' { $stats.liveEmpty++ }
        'tenant-gated' { $stats.tenantGated++ }
        'rate-limited' { $stats.rateLimited++ }
        'request-shape-error' { $stats.requestShape++ }
        'network-error' { $stats.networkErr++ }
    }

    # Save live.json with full forensic trail
    $bodySnip = if ($body -and $body.Length -gt 8000) { $body.Substring(0, 8000) + '...[truncated]' } else { $body }
    $live = [ordered]@{
        portal=$Portal; path=$meta.path; method='GET'; finalUrl=$url
        httpStatus=$statusCode; successKind=$successKind; diagnostic=$diagnostic
        contentLen=$contentLen; rawSample=$bodySnip
        capturedUtc=(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    $live | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $epDir 'live.json') -NoNewline

    # Update metadata
    $meta | Add-Member -NotePropertyName 'lastSuccessKind' -NotePropertyValue $successKind -Force
    $meta | Add-Member -NotePropertyName 'lastHttpStatus'  -NotePropertyValue $statusCode  -Force
    if ($diagnostic) { $meta | Add-Member -NotePropertyName 'lastDiagnostic' -NotePropertyValue $diagnostic -Force }
    $meta | ConvertTo-Json -Depth 12 | Set-Content -Path $epFile.FullName -NoNewline

    $shortPath = if ($meta.path.Length -gt 60) { '...' + $meta.path.Substring($meta.path.Length-57) } else { $meta.path }
    $color = switch ($successKind) {
        'live' {'Green'}; 'live-empty' {'DarkGray'}
        'tenant-gated' {'Cyan'}; 'request-shape-error' {'Yellow'}
        'rate-limited' {'Magenta'}; default {'Red'}
    }
    Write-Host ("  [{0,-20}] {1,3} {2}" -f $successKind, $statusCode, $shortPath) -ForegroundColor $color
}

Write-Host ""
Write-Host "=== $Portal probe complete ===" -ForegroundColor Cyan
Write-Host "  Probed:                $($stats.probed)"
Write-Host "  Live (real data):      $($stats.live)"          -ForegroundColor Green
Write-Host "  Live-empty (200, 0 rows): $($stats.liveEmpty)"  -ForegroundColor DarkGray
Write-Host "  Tenant-gated (401/403/404): $($stats.tenantGated)" -ForegroundColor Cyan
Write-Host "  Request-shape (400/422): $($stats.requestShape)" -ForegroundColor Yellow
Write-Host "  Rate-limited (429):    $($stats.rateLimited)"   -ForegroundColor Magenta
Write-Host "  Network error:         $($stats.networkErr)"
Write-Host "  Skipped (non-GET):     $($stats.nonGet)"
Write-Host "  Skipped (path-template): $($stats.pathTemplate)"
