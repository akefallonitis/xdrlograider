#Requires -Version 7.4
<#
.SYNOPSIS
    Live probe of the XdrLogRaider auth chain across one or all 5 Microsoft portals
    (Defender, Purview, Entra · 5 sub-portals, Intune · 2 sub-portals, SecurityCopilot).
    SA credentials from tests/.env.local.

.DESCRIPTION
    Empirical artefact for the WIRE-CAPTURE step of the autonomous-loop methodology
    (Claude memory feedback_autonomous_loop_v2.md). Locks "auth chain works for portal X"
    with real Microsoft responses on disk.

    For each requested portal:
      - Cookie portals (Defender, Purview): runs Get-EntraEstsAuth (ESTS+SCC chain).
        Submit-EntraFormPost is called internally; session ends with sccauth cookie.
      - Bearer portals (Entra/Intune/SecurityCopilot): runs Get-EntraBearerToken
        (cookie chain + auth_code → JWT exchange).

    Then exercises CapabilityEndpoint per portal (the canonical health-check endpoint
    in $script:PortalConfig) to capture a real Microsoft response.

    Outputs per portal under tests/fixtures/live/<Portal>[/<SubPortal>]/:
      - auth.json        - chain summary (cookies redacted · JWT exp/aud redacted token)
      - capability.json  - response from CapabilityEndpoint (parseable JSON)
      OR
      - unreachable.json - classification + status (license-gated / 401 / etc.)

    Aggregate output under tests/results/iter-<utc>/probe-auth-multi.json.

.PARAMETER Portal
    Defender | Purview | Entra | Intune | SecurityCopilot | All
    Default: Defender (backward-compatible with single-portal v0.0.2 usage).

.EXAMPLE
    pwsh ./tools/Probe-Auth-Local.ps1                    # Defender only (default)
    pwsh ./tools/Probe-Auth-Local.ps1 -Portal All        # All 5 portals · 10 sub-portals
    pwsh ./tools/Probe-Auth-Local.ps1 -Portal Entra      # All 5 Entra sub-portals

.NOTES
    Secret hygiene: cookie values are redacted as <REDACTED:length-N>; JWTs are
    not written to disk (only header.payload exp/aud claims). Local-only artefact.
#>

[CmdletBinding()]
param(
    [ValidateSet('Defender','Purview','Entra','Intune','SecurityCopilot','All')]
    [string]$Portal = 'Defender',
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\tests\.env.local'),
    [switch]$VerboseTrace
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Load env.local
if (Test-Path $EnvFile) {
    Get-Content $EnvFile | Where-Object { $_ -match '^\s*[^#].+=' } | ForEach-Object {
        $k, $v = $_ -split '=', 2
        Set-Item -Path "env:$($k.Trim())" -Value $v.Trim()
    }
}
foreach ($req in 'XDRLR_TEST_UPN','XDRLR_TEST_PASSWORD','XDRLR_TEST_TOTP_SECRET') {
    if (-not (Get-Item "env:$req" -ErrorAction SilentlyContinue).Value) {
        throw "Probe-Auth-Local: missing env var '$req'. Populate $EnvFile then retry."
    }
}

$repoRoot = Join-Path $PSScriptRoot '..'
Import-Module (Join-Path $repoRoot 'src\Modules\Xdr.Auth\Xdr.Auth.psd1') -Force

# Selected sub-portal entries from $script:PortalConfig
$selected = if ($Portal -eq 'All') {
    Get-XdrPortalConfig
} else {
    Get-XdrPortalConfig | Where-Object Portal -eq $Portal
}
if (-not $selected) { throw "Probe-Auth-Local: no PortalConfig entries matched -Portal '$Portal'." }

$ts0 = Get-Date
$iterDir = Join-Path $repoRoot ("tests/results/iter-" + (Get-Date -Format 'yyyyMMddTHHmmssZ'))
New-Item -ItemType Directory -Path $iterDir -Force | Out-Null

$creds = Get-XdrAuthFromKeyVault -FromEnvLocal
Clear-XdrCookieCache

$multi = [System.Collections.Generic.List[object]]::new()

# -----------------------------------------------------------------------------
# Probe helpers
# -----------------------------------------------------------------------------
function Save-PortalArtefacts {
    param(
        [Parameter(Mandatory)][hashtable]$Cfg,
        [Parameter(Mandatory)][hashtable]$Auth,
        $Capability     # response from CapabilityEndpoint or $null
    )
    $base = if ($Cfg.SubPortal) {
        Join-Path $repoRoot ("tests/fixtures/live/" + $Cfg.Portal + "/" + $Cfg.SubPortal)
    } else {
        Join-Path $repoRoot ("tests/fixtures/live/" + $Cfg.Portal)
    }
    New-Item -ItemType Directory -Path $base -Force | Out-Null
    $Auth | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $base 'auth.json') -Encoding UTF8

    if ($Capability -and $Capability.Status -ge 200 -and $Capability.Status -lt 300 -and $Capability.Parsed) {
        $Capability.Parsed | ConvertTo-Json -Depth 50 | Set-Content -Path (Join-Path $base 'capability.json') -Encoding UTF8
    } else {
        @{
            classification = if ($Capability) { $Capability.Classification } else { 'no-call' }
            statusCode     = if ($Capability) { $Capability.Status } else { $null }
            note           = 'License-gated or unreachable. NOT a chain failure if auth.json shows the chain worked. Operator may grant license and re-run probe.'
        } | ConvertTo-Json | Set-Content -Path (Join-Path $base 'unreachable.json') -Encoding UTF8
    }
}

function Test-CookieChain {
    param([Parameter(Mandatory)][hashtable]$Cfg)
    $portalHost = $Cfg.Host
    $credHash = @{ upn = $creds.Upn; password = $creds.Password; totpBase32 = $creds.TotpSecret }
    $ests = Get-EntraEstsAuth -Credential $credHash -ClientId $Cfg.ClientId `
        -PortalHost $portalHost -AuthProfile Cookie
    $session = $ests.Session
    $cookies = @($session.Cookies.GetAllCookies() | ForEach-Object {
        [pscustomobject]@{
            Name    = $_.Name
            Value   = "<REDACTED:length-$($_.Value.Length)>"
            Domain  = $_.Domain
            Expires = if ($_.Expires -gt [datetime]::MinValue) { $_.Expires.ToUniversalTime().ToString('o') } else { $null }
        }
    })
    $sccauthPresent = ($cookies | Where-Object Name -eq 'sccauth' | Measure-Object).Count -gt 0
    $kmsiPresent    = ($cookies | Where-Object Name -eq 'ESTSAUTHPERSISTENT' | Measure-Object).Count -gt 0
    $cookieExpiry   = Get-XdrCookieExpiry -Session $session

    @{
        AuthProfile    = 'Cookie'
        Success        = $sccauthPresent
        SccauthPresent = $sccauthPresent
        KmsiPresent    = $kmsiPresent
        CookieExpiry   = if ($cookieExpiry) { $cookieExpiry.ToString('o') } else { $null }
        Cookies        = $cookies
        Session        = $session   # caller uses to hit CapabilityEndpoint
        Upn            = $ests.Upn
    }
}

function Test-BearerChain {
    param([Parameter(Mandatory)][hashtable]$Cfg)
    $credHash = @{ upn = $creds.Upn; password = $creds.Password; totpBase32 = $creds.TotpSecret }
    # A-3b-2 · pass v1 OAuth + PKCE + ClientType params from PortalConfig.
    # Fields land in $Cfg via Get-XdrPortalConfig (A-3b-1 added AuthVersion/Resource/ClientType).
    $bearer = Get-EntraBearerToken -Credential $credHash -ClientId $Cfg.ClientId `
        -Scope $Cfg.Scope -RedirectUri $Cfg.RedirectUri `
        -AuthVersion $Cfg.AuthVersion -Resource $Cfg.Resource -ClientType $Cfg.ClientType
    @{
        AuthProfile      = 'Bearer'
        Success          = -not [string]::IsNullOrWhiteSpace($bearer.AccessToken)
        TokenType        = $bearer.TokenType
        Audience         = $bearer.Audience
        ExpiresUtc       = $bearer.ExpiresUtc.ToString('o')
        AccessTokenLen   = $bearer.AccessToken.Length
        RefreshTokenLen  = $bearer.RefreshToken.Length
        Scope            = $bearer.Scope
        TenantId         = $bearer.TenantId
        Upn              = $bearer.Upn
        AccessToken      = $bearer.AccessToken   # caller uses to hit CapabilityEndpoint
    }
}

function Test-CapabilityEndpoint {
    param(
        [Parameter(Mandatory)][hashtable]$Cfg,
        [Parameter(Mandatory)][hashtable]$ChainResult
    )
    if (-not $Cfg.CapabilityEndpoint) { return $null }
    $uri = "https://$($Cfg.Host)$($Cfg.CapabilityEndpoint)"

    $headers = @{}
    foreach ($k in $Cfg.ExtraHeaders.Keys) {
        $v = $Cfg.ExtraHeaders[$k]
        if ($v -eq '{NewGuid}') { $v = [guid]::NewGuid().ToString() }
        $headers[$k] = $v
    }

    if ($ChainResult.AuthProfile -eq 'Cookie') {
        $session = $ChainResult.Session
        $xsrf = ($session.Cookies.GetAllCookies() | Where-Object Name -eq 'XSRF-TOKEN' | Select-Object -First 1)
        if ($xsrf) { $headers['X-XSRF-TOKEN'] = [System.Web.HttpUtility]::UrlDecode($xsrf.Value) }
        $resp = Invoke-XdrAuthHttp -Uri $uri -Method GET -Headers $headers `
            -ContentType 'application/json' -Session $session -MaximumRedirection 0
    } else {
        $headers['Authorization'] = "Bearer $($ChainResult.AccessToken)"
        $resp = Invoke-XdrAuthHttp -Uri $uri -Method GET -Headers $headers `
            -ContentType 'application/json' -MaximumRedirection 0
    }
    $cls = Resolve-EntraResponse -Response $resp -ExpectedStage 'TenantContext'
    $parsed = $null
    if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300 -and $cls.Classification -eq 'auth-ok') {
        try { $parsed = $resp.Content | ConvertFrom-Json -Depth 100 -ErrorAction Stop } catch {}
    }
    @{
        Endpoint       = $Cfg.CapabilityEndpoint
        Status         = $resp.StatusCode
        Classification = $cls.Classification
        Parsed         = $parsed
    }
}

# -----------------------------------------------------------------------------
# Iterate selected sub-portals
# -----------------------------------------------------------------------------
foreach ($entry in $selected) {
    $key = $entry.Key
    Write-Host "`n=== Probe ${key} ===" -ForegroundColor Cyan
    $portalSummary = [ordered]@{
        Portal                   = $entry.Portal
        SubPortal                = $entry.SubPortal
        AuthProfile              = $entry.AuthProfile
        TimestampUtc             = (Get-Date).ToUniversalTime().ToString('o')
        ChainSuccess             = $false
        CapabilityStatus         = $null
        CapabilityClassification = 'no-call'
        Error                    = $null
    }
    try {
        $cfg = @{ Host = $entry.Host; ClientId = $entry.ClientId; Scope = $entry.Scope;
                  RedirectUri = $entry.RedirectUri; SubPortal = $entry.SubPortal;
                  Portal = $entry.Portal; CapabilityEndpoint = $entry.CapabilityEndpoint;
                  ExtraHeaders = $entry.ExtraHeaders;
                  # A-3b-2 · pack the bearer v1 OAuth fields so Test-BearerChain can read them
                  AuthVersion = $entry.AuthVersion; Resource = $entry.Resource; ClientType = $entry.ClientType }
        $chain = if ($entry.AuthProfile -eq 'Cookie') {
            Test-CookieChain -Cfg $cfg
        } else {
            Test-BearerChain -Cfg $cfg
        }
        $portalSummary['ChainSuccess'] = $chain.Success
        $portalSummary['AuthProfile']  = $chain.AuthProfile

        $cap = Test-CapabilityEndpoint -Cfg $cfg -ChainResult $chain
        $portalSummary['CapabilityStatus']         = if ($cap) { $cap.Status }         else { $null }
        $portalSummary['CapabilityClassification'] = if ($cap) { $cap.Classification } else { 'no-call' }

        # Write per-portal artefacts (strip the Session/AccessToken from disk)
        $authForDisk = $chain.Clone()
        $authForDisk.Remove('Session') | Out-Null
        if ($authForDisk.ContainsKey('AccessToken')) {
            $authForDisk['AccessToken'] = "<REDACTED:length-$($chain.AccessToken.Length)>"
        }
        Save-PortalArtefacts -Cfg $cfg -Auth $authForDisk -Capability $cap

        Write-Host ("  AuthProfile : {0}" -f $chain.AuthProfile)
        Write-Host ("  ChainSuccess: {0}" -f $chain.Success)
        Write-Host ("  Capability  : {0} ({1})" -f $portalSummary['CapabilityStatus'], $portalSummary['CapabilityClassification']) `
            -ForegroundColor $(if ($cap -and $cap.Status -ge 200 -and $cap.Status -lt 300 -and $cap.Classification -eq 'auth-ok') { 'Green' } else { 'Yellow' })
    } catch {
        $portalSummary['ChainSuccess'] = $false
        $portalSummary['Error']        = $_.Exception.Message
        Write-Host ("  ERROR       : {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
    $multi.Add([pscustomobject]$portalSummary) | Out-Null
}

# Aggregate output
$multiAggregate = [pscustomobject]@{
    TimestampUtc    = (Get-Date).ToUniversalTime().ToString('o')
    Upn             = $env:XDRLR_TEST_UPN
    Portal          = $Portal
    SecondsElapsed  = ((Get-Date) - $ts0).TotalSeconds
    ChainsRequested = @($selected | ForEach-Object Key)
    Probes          = @($multi)
    Summary         = [ordered]@{
        Total        = @($multi).Count
        ChainSuccess = @($multi | Where-Object ChainSuccess).Count
        Reachable    = @($multi | Where-Object { $_.CapabilityClassification -eq 'auth-ok' }).Count
    }
}
$aggregateFile = Join-Path $iterDir 'probe-auth-multi.json'
$multiAggregate | ConvertTo-Json -Depth 10 | Set-Content -Path $aggregateFile -Encoding UTF8

Write-Host ""
Write-Host "Probe-Auth-Local: $(@($multi).Count) sub-portal(s) probed in $([int]$multiAggregate.SecondsElapsed)s" -ForegroundColor Cyan
Write-Host "  ChainSuccess: $($multiAggregate.Summary.ChainSuccess)/$($multiAggregate.Summary.Total)"
Write-Host "  Reachable   : $($multiAggregate.Summary.Reachable)/$($multiAggregate.Summary.Total)"
Write-Host "  Aggregate   : $aggregateFile" -ForegroundColor DarkGray

$multiAggregate
