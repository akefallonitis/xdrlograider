# Xdr.Auth.psm1 — Defender XDR portal auth chain
#
# Full TOTP chain wired (Login → SAS BeginAuth → EndAuth → ProcessAuth
#          → KMSI walker → form_post). Ported canonical patterns from
#          xdrlograider/ (v1) Get-EntraEstsAuth + Complete-CredentialsFlow +
#          Complete-TotpMfa + Resolve-EntraInterruptPage + Submit-EntraFormPost
#          + Get-EntraFields helpers, consolidated into a single module file.
#
# Public exports:
#   Connect-DefenderPortal     — orchestrator with cache (driven by Get-XdrCookieExpiry, NOT 50-min hardcode)
#   Get-XdrCookieExpiry        — earliest expiry across (ESTSAUTHPERSISTENT, sccauth, ESTSAUTH)
#   Resolve-EntraResponse      — classifier (auth-ok | aadsts-<code> | html-* | throttle-mfa | unknown)
#   Invoke-XdrAuthHttp         — HTTP wrapper with B-25 `-isnot [string]` guard FIRST
#   Get-XdrTotpCode            — RFC 6238 TOTP
#   Get-XdrAuthFromKeyVault    — KV read (+ env.local fallback for local probe)
#   Clear-XdrCookieCache       — test seam
#
# Constants:
#   $script:DefenderClientId = '80ccca67-54bd-44ab-8625-4b79c4dc7775'  (Defender XDR public client)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Module-scope state
$script:DefenderClientId = '80ccca67-54bd-44ab-8625-4b79c4dc7775'
$script:SessionCache = @{}    # key: '<upn>::<host>' → @{ Session; Upn; PortalHost; TenantId; AcquiredUtc; _Method; _Credential }
$script:UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0'

# ITER11 HIGH7 · Explicit TLS 1.2+ enforcement (production-grade compliance).
# PowerShell 7.4+ defaults to Tls12|Tls13 but is platform-dependent · pin explicitly so
# old TLS 1.0/1.1 negotiation NEVER attempted regardless of platform default.
# Side-effect: also applies to any .NET HttpClient instantiated downstream.
try {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13
} catch {
    # PS 7.4+ on .NET 8 may not have Tls13 enum constant on Linux · fallback to Tls12 only
    try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch {}
}

#region Entra HTML/JSON $Config helpers (private)
function Test-EntraField {
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $false }
    (@($Object.PSObject.Properties.Name) -contains $Name)
}

function Get-EntraField {
    param($Object, [Parameter(Mandatory)][string]$Name, $Default = $null)
    if (Test-EntraField -Object $Object -Name $Name) { return $Object.$Name }
    $Default
}

function Get-EntraConfigBlob {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Html)
    if ([string]::IsNullOrEmpty($Html)) { return $null }
    $patterns = @(
        '\$Config\s*=\s*(\{.*?\});\s*\n',
        '\$Config\s*=\s*(\{.*?\});\s*</script>'
    )
    foreach ($pattern in $patterns) {
        $m = [regex]::Match($Html, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
        if ($m.Success) {
            try { return $m.Groups[1].Value | ConvertFrom-Json }
            catch { Write-Verbose "Get-EntraConfigBlob: parse failed: $($_.Exception.Message)" }
        }
    }
    $null
}

function Get-EntraErrorMessage {
    param([Parameter(Mandatory)][string]$Code, [string]$DefaultText)
    $messages = @{
        '50126'  = 'Invalid username or password.'
        '50053'  = 'Account is locked (too many failed sign-in attempts).'
        '50057'  = 'Account is disabled.'
        '50055'  = 'Password has expired.'
        '50056'  = 'Invalid or null password.'
        '50034'  = 'User account not found in this directory.'
        '50058'  = 'Session information insufficient for single-sign-on.'
        '50080'  = 'Malformed login request (often the [string] -is [pscustomobject] type-trap; check Invoke-XdrAuthHttp).'
        '50196'  = 'Authentication throttled — wait + retry.'
        '53003'  = 'Access blocked by a Conditional Access policy.'
        '500121' = 'MFA authentication failed.'
        '700016' = 'Application not found in directory.'
        '900144' = 'Malformed login request (missing client_id).'
    }
    if ($messages.ContainsKey($Code)) { return $messages[$Code] }
    if ($DefaultText) { return $DefaultText }
    "Entra error $Code"
}

function Test-MfaEndAuthSuccess {
    param([Parameter(Mandatory)]$EndAuth)
    if ($null -eq $EndAuth) { return $false }
    if ((Get-EntraField -Object $EndAuth -Name 'Success') -eq $true) { return $true }
    $rv = Get-EntraField -Object $EndAuth -Name 'ResultValue'
    ($rv -in @('AuthenticationSucceeded','Success'))
}
#endregion

#region HTTP type-trap-safe wrapper (B-25 lock)
function Invoke-XdrAuthHttp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][ValidateSet('GET','POST','PUT','DELETE','PATCH')][string]$Method,
        [hashtable]$Headers,
        $Body,
        [string]$ContentType = 'application/x-www-form-urlencoded',
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [int]$MaximumRedirection = 0,
        [int]$TimeoutSec = 30
    )
    # B-25: `-isnot [string]` FIRST. Pre-encoded JSON string passes through.
    $payload = if ($null -eq $Body) { $null }
        elseif ($Body -isnot [string] -and $ContentType -match 'json') { $Body | ConvertTo-Json -Depth 10 -Compress }
        else { $Body }
    $newSession = $null
    $params = @{
        Uri=$Uri; Method=$Method; ContentType=$ContentType; MaximumRedirection=$MaximumRedirection
        TimeoutSec=$TimeoutSec; ErrorAction='Stop'; SkipHttpErrorCheck=$true; UseBasicParsing=$true
    }
    if ($Headers) { $params.Headers = $Headers }
    if ($Session) { $params.WebSession = $Session } else { $params.SessionVariable = 'newSession' }
    if ($null -ne $payload) { $params.Body = $payload }
    try {
        $response = Invoke-WebRequest @params
        [pscustomobject]@{
            StatusCode = $response.StatusCode; Headers = $response.Headers
            Content = $response.Content; Session = if ($Session) { $Session } else { $newSession }
        }
    } catch {
        $statusCode = -1
        if ($_.Exception -and ($_.Exception.PSObject.Properties.Name -contains 'Response')) {
            $resp = $_.Exception.Response
            if ($resp -and ($resp.PSObject.Properties.Name -contains 'StatusCode')) { $statusCode = [int]$resp.StatusCode }
        }
        [pscustomobject]@{
            StatusCode = $statusCode; Headers = $null
            Content = $_.Exception.Message; Session = $Session; Error = $_
        }
    }
}
#endregion

#region Response classifier
function Resolve-EntraResponse {
    [CmdletBinding()][OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowNull()]$Response, [string]$ExpectedStage)
    if ($null -eq $Response) {
        return [pscustomobject]@{ Classification = 'unknown'; Reason = 'null response' }
    }
    $code = [int]$Response.StatusCode
    $body = [string]$Response.Content
    if ($body -match 'AADSTS50196|AuthenticationThrottled') {
        return [pscustomobject]@{ Classification = 'throttle-mfa'; Reason = 'throttled by Entra (50196)' }
    }
    if ($body -match 'AADSTS(\d+)') {
        return [pscustomobject]@{ Classification = "aadsts-$($Matches[1])"; Reason = "Entra error $($Matches[1])" }
    }
    # 200+HTML body BEFORE generic 2xx auth-ok (SPA shell at JSON endpoint = auth lost)
    if ($code -ge 200 -and $code -lt 300 -and $body -match '^\s*<!DOCTYPE html|^\s*<html') {
        return [pscustomobject]@{ Classification = 'html-terminal'; Reason = 'SPA HTML shell returned at JSON endpoint' }
    }
    if (($code -ge 300 -and $code -lt 400) -and $body -match '<!DOCTYPE html|<html') {
        $stagesIntermediate = @('CredentialPost','BeginAuth','EndAuth','ProcessAuth','KmsiInterrupt')
        if ($ExpectedStage -in $stagesIntermediate) {
            return [pscustomobject]@{ Classification = 'auth-redirect-intermediate'; Reason = "HTTP $code at $ExpectedStage" }
        }
        return [pscustomobject]@{ Classification = 'html-redirect-terminal'; Reason = "unexpected HTML redirect at $ExpectedStage" }
    }
    if ($code -ge 200 -and $code -lt 300) {
        return [pscustomobject]@{ Classification = 'auth-ok'; Reason = "HTTP $code" }
    }
    [pscustomobject]@{ Classification = 'unknown'; Reason = "HTTP $code; body head: $($body.Substring(0,[math]::Min(80,$body.Length)))" }
}
#endregion

#region Cookie expiry (primitive — wired into Connect-DefenderPortal cache decision)
function Get-XdrCookieExpiry {
    [CmdletBinding()][OutputType([Nullable[datetime]])]
    param([Parameter(Mandatory)][AllowNull()]$Session)
    if ($null -eq $Session) { return $null }
    $cookies = $null
    try { $cookies = $Session.Cookies.GetAllCookies() } catch { return $null }
    if (-not $cookies) { return $null }
    $priority = @('ESTSAUTHPERSISTENT','sccauth','ESTSAUTH')
    $expiries = foreach ($name in $priority) {
        $c = $cookies | Where-Object Name -eq $name | Select-Object -First 1
        if ($c -and $c.Expires -and $c.Expires -gt [datetime]::MinValue) { $c.Expires.ToUniversalTime() }
    }
    if (-not $expiries) { return $null }
    ($expiries | Sort-Object | Select-Object -First 1)
}
#endregion

#region Cross-runspace session cache · v2 B-19 fix (TOTP cascade across cold-starts)
# WHY: PS Function App workers spawn fresh runspaces per Durable activity. Module-scope
# $script:SessionCache is empty in each runspace · forces full TOTP chain per activity.
# Microsoft Authenticator rejects duplicate TOTP within 30-sec window · cascade failure.
# FIX: Persist session to /tmp/xdrlr-session.json (atomic write · 50-min cap) ·
# next runspace reads + reconstructs WebRequestSession · ZERO TOTP burn.

function _Get-XdrSessionCachePath {
    [CmdletBinding()][OutputType([string])] param()
    if ($env:XDR_SESSION_CACHE_PATH) { return $env:XDR_SESSION_CACHE_PATH }
    # Cross-platform: /tmp on Linux FA · %TEMP% on Windows dev
    $tempDir = [System.IO.Path]::GetTempPath()
    Join-Path $tempDir 'xdrlr-session.json'
}

function Save-XdrSessionToCache {
    <#
    .SYNOPSIS
        Persist WebRequestSession to cross-runspace file cache · atomic write pattern.
        v2 B-19 fix · enables next-runspace reuse without TOTP burn.
    .NOTES
        Cookie array preserves Name/Value/Domain/Path/Expires/Secure/HttpOnly · sufficient
        to fully reconstruct CookieContainer state in Read-XdrSessionFromCache.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [Parameter(Mandatory)][string]$Upn,
        [Parameter(Mandatory)][string]$PortalHost,
        [string]$TenantId = '',
        [string]$RefreshType = 'unknown'
    )
    try {
        $cookies = @($Session.Cookies.GetAllCookies() | ForEach-Object {
            @{
                Name     = [string]$_.Name
                Value    = [string]$_.Value
                Domain   = [string]$_.Domain
                Path     = if ($_.Path) { [string]$_.Path } else { '/' }
                Expires  = if ($_.Expires -and $_.Expires -gt [datetime]::MinValue) { $_.Expires.ToUniversalTime().ToString('o') } else { $null }
                Secure   = [bool]$_.Secure
                HttpOnly = [bool]$_.HttpOnly
            }
        })
        $payload = [pscustomobject]@{
            SchemaVersion = '1.0'
            Upn           = $Upn
            PortalHost    = $PortalHost
            TenantId      = $TenantId
            AcquiredUtc   = [datetime]::UtcNow.ToString('o')
            RefreshType   = $RefreshType
            UserAgent     = $Session.UserAgent
            CookieCount   = $cookies.Count
            Cookies       = $cookies
        }
        $cachePath = _Get-XdrSessionCachePath
        $tempPath = "$cachePath.tmp"
        $json = $payload | ConvertTo-Json -Depth 10 -Compress
        # ITER11 HIGH4 · max-size guard (256KB · pathological cookie growth → bail with telemetry,
        # don't write unbounded JSON to /tmp on Y1 Linux Consumption · file system caps at 500MB total).
        $maxSizeBytes = 262144   # 256KB
        $sizeBytes = [System.Text.Encoding]::UTF8.GetByteCount($json)
        if ($sizeBytes -gt $maxSizeBytes) {
            _Emit-AuthTelemetry -Level Warning -EventName 'Session.CacheSizeExceeded' `
                -Message ("Session cache payload {0} bytes exceeds {1}-byte cap · skipping persist · in-memory cache still valid this run" -f $sizeBytes, $maxSizeBytes) `
                -Properties @{ Upn=$Upn; PortalHost=$PortalHost; SizeBytes=$sizeBytes; MaxBytes=$maxSizeBytes; CookieCount=$cookies.Count }
            return
        }
        # Π11.C1 · Named-mutex protected atomic write · prevents multi-worker corruption
        # (Y1 Consumption single-worker today · Premium/EP scale-out safe · Durable activities multi-runspace safe).
        # Π11 ITER3 · OS-aware mutex name · Windows uses Global\ (cross-process kernel object · all sessions);
        # Linux .NET 7+ supports named mutexes but Global\ prefix has no special meaning · use bare name to
        # avoid confusing telemetry. WaitOne(5000) timeout still yields best-effort write either way.
        $mutexName = if ($IsWindows -or [System.Environment]::OSVersion.Platform -eq 'Win32NT') {
            'Global\XdrLrSessionCache'
        } else {
            'XdrLrSessionCache'
        }
        $mutex = $null
        $acquired = $false
        try {
            $mutex = [System.Threading.Mutex]::new($false, $mutexName)
            $acquired = $mutex.WaitOne(5000)   # 5s timeout · safety against hung writer
            if (-not $acquired) {
                _Emit-AuthTelemetry -Level Warning -EventName 'Session.CacheLockTimeout' `
                    -Message "Could not acquire session-cache write mutex within 5s · proceeding without lock (best-effort)" `
                    -Properties @{ Upn=$Upn; PortalHost=$PortalHost; MutexName=$mutexName }
            }
            # Atomic write: write to .tmp then rename (mutex-protected when held)
            [System.IO.File]::WriteAllText($tempPath, $json, [System.Text.UTF8Encoding]::new($false))
            if (Test-Path $cachePath) { Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue }
            Move-Item -LiteralPath $tempPath -Destination $cachePath -Force
        } finally {
            if ($acquired -and $mutex) { try { $mutex.ReleaseMutex() } catch {} }
            if ($mutex) { try { $mutex.Dispose() } catch {} }
        }
        _Emit-AuthTelemetry -Level Information -EventName 'Session.CacheWrite' `
            -Message "Saved session to file cache for $Upn::$PortalHost ($($cookies.Count) cookies)" `
            -Properties @{ Upn=$Upn; PortalHost=$PortalHost; TenantId=$TenantId; RefreshType=$RefreshType; CookieCount=$cookies.Count; CachePath=$cachePath }
    } catch {
        _Emit-AuthTelemetry -Level Warning -EventName 'Session.CacheWriteFail' `
            -Message "Failed to persist session cache: $($_.Exception.Message)" `
            -Properties @{ Upn=$Upn; PortalHost=$PortalHost; Error=$_.Exception.Message }
    }
}

function Read-XdrSessionFromCache {
    <#
    .SYNOPSIS
        Reconstruct WebRequestSession from cross-runspace file cache · age-gated.
        Returns $null if cache missing · stale · or doesn't match Upn/PortalHost.
    .PARAMETER MaxAgeMinutes
        Cap session reuse · default 50min (Microsoft sccauth ~1h with 10min safety margin · D-25).
    #>
    [CmdletBinding()][OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Upn,
        [Parameter(Mandatory)][string]$PortalHost,
        [int]$MaxAgeMinutes = 50
    )
    $cachePath = _Get-XdrSessionCachePath
    if (-not (Test-Path $cachePath)) {
        _Emit-AuthTelemetry -Level Verbose -EventName 'Session.CacheMiss' `
            -Message "No session cache file at $cachePath" `
            -Properties @{ Upn=$Upn; PortalHost=$PortalHost; Reason='no-file' }
        return $null
    }
    try {
        $raw = Get-Content -Raw -LiteralPath $cachePath -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            _Emit-AuthTelemetry -Level Warning -EventName 'Session.CacheCorrupt' `
                -Message "Cache file is empty" `
                -Properties @{ CachePath=$cachePath; Error='empty-file' }
            return $null
        }
        $payload = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        _Emit-AuthTelemetry -Level Warning -EventName 'Session.CacheCorrupt' `
            -Message "Failed to parse cache file: $($_.Exception.Message)" `
            -Properties @{ CachePath=$cachePath; Error=$_.Exception.Message }
        return $null
    }
    # Null-safety after parse (ConvertFrom-Json '' returns $null · same for non-object payloads)
    if ($null -eq $payload -or -not $payload.PSObject.Properties['Upn'] -or -not $payload.PSObject.Properties['PortalHost']) {
        _Emit-AuthTelemetry -Level Warning -EventName 'Session.CacheCorrupt' `
            -Message "Cache file payload missing required fields (Upn/PortalHost)" `
            -Properties @{ CachePath=$cachePath; Error='missing-required-fields' }
        return $null
    }
    # Match-check: cache must be for this Upn + PortalHost (prevents cross-tenant pollution)
    if ($payload.Upn -ne $Upn -or $payload.PortalHost -ne $PortalHost) {
        _Emit-AuthTelemetry -Level Verbose -EventName 'Session.CacheMiss' `
            -Message "Cache mismatch · cached=$($payload.Upn)::$($payload.PortalHost) requested=$Upn::$PortalHost" `
            -Properties @{ Upn=$Upn; PortalHost=$PortalHost; CachedUpn=$payload.Upn; CachedHost=$payload.PortalHost; Reason='upn-host-mismatch' }
        return $null
    }
    # Age-cap: D-25 cookie-expiry-driven · falls back to 50min if cookie-exp ambiguous
    # NOTE: ConvertFrom-Json in PS7 auto-parses ISO date strings into [datetime] · handle both shapes
    $acquiredUtc = if ($payload.AcquiredUtc -is [datetime]) {
        $payload.AcquiredUtc.ToUniversalTime()
    } else {
        [datetime]::Parse([string]$payload.AcquiredUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    }
    $ageMin = ([datetime]::UtcNow - $acquiredUtc).TotalMinutes
    if ($ageMin -ge $MaxAgeMinutes) {
        _Emit-AuthTelemetry -Level Verbose -EventName 'Session.CacheStale' `
            -Message "Cache age $([math]::Round($ageMin,1))min ≥ $MaxAgeMinutes min · stale" `
            -Properties @{ Upn=$Upn; PortalHost=$PortalHost; AgeMinutes=[math]::Round($ageMin,1); MaxAgeMinutes=$MaxAgeMinutes }
        return $null
    }
    # Reconstruct WebRequestSession + populate cookie jar
    $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
    if ($payload.UserAgent) { $session.UserAgent = $payload.UserAgent } else { $session.UserAgent = $script:UserAgent }
    $restored = 0
    foreach ($c in @($payload.Cookies)) {
        try {
            $nc = [System.Net.Cookie]::new($c.Name, $c.Value)
            $nc.Domain   = $c.Domain
            $nc.Path     = if ($c.Path) { $c.Path } else { '/' }
            if ($c.Expires) {
                $nc.Expires = if ($c.Expires -is [datetime]) {
                    $c.Expires.ToUniversalTime()
                } else {
                    [datetime]::Parse([string]$c.Expires, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
                }
            }
            $nc.Secure   = [bool]$c.Secure
            $nc.HttpOnly = [bool]$c.HttpOnly
            $session.Cookies.Add($nc)
            $restored++
        } catch {
            # Skip individual cookie failures · continue restore
        }
    }
    _Emit-AuthTelemetry -Level Information -EventName 'Session.CacheHit' `
        -Message "Loaded session from file cache · age=$([math]::Round($ageMin,1))min · $restored/$($payload.CookieCount) cookies restored" `
        -Properties @{ Upn=$Upn; PortalHost=$PortalHost; TenantId=$payload.TenantId; AgeMinutes=[math]::Round($ageMin,1); CookiesRestored=$restored; CookieCount=$payload.CookieCount; RefreshType=$payload.RefreshType }
    return [pscustomobject]@{
        Session     = $session
        Upn         = $payload.Upn
        PortalHost  = $payload.PortalHost
        TenantId    = $payload.TenantId
        AcquiredUtc = $acquiredUtc
        RefreshType = $payload.RefreshType
    }
}

function Remove-XdrSessionFromCache {
    <#
    .SYNOPSIS
        Delete the cross-runspace session cache file · operator-callable for cleanup or testing.
    #>
    [CmdletBinding()] param()
    $cachePath = _Get-XdrSessionCachePath
    if (Test-Path $cachePath) {
        Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
        _Emit-AuthTelemetry -Level Information -EventName 'Session.CacheClear' `
            -Message "Cleared session file cache at $cachePath" `
            -Properties @{ CachePath=$cachePath }
    }
}
#endregion

#region KMSI SSO re-mint · proper D-25 implementation (avoids TOTP when KMSI valid)
function Get-XdrKmsiCookie {
    [CmdletBinding()][OutputType([System.Net.Cookie])]
    param([Parameter(Mandatory)][AllowNull()]$Session)
    if ($null -eq $Session) { return $null }
    try {
        $cookies = $Session.Cookies.GetAllCookies()
        $kmsi = $cookies | Where-Object Name -eq 'ESTSAUTHPERSISTENT' | Select-Object -First 1
        if ($kmsi -and $kmsi.Expires -gt [datetime]::UtcNow.AddMinutes(5)) {
            return $kmsi
        }
    } catch { }
    return $null
}

function Invoke-XdrKmsiSsoRefresh {
    <#
    .SYNOPSIS
        Refreshes an expired cookie-portal session using ESTSAUTHPERSISTENT (KMSI) cookie.
        Avoids the TOTP burn when only sccauth/ESTSAUTH are expired and KMSI is still valid.
    .DESCRIPTION
        D-25 LOCKED · operator-corrected 2026-05-18 reauth path:
          1. Verify prior session has valid ESTSAUTHPERSISTENT (90d KMSI)
          2. Build NEW session seeded with PERSISTENT cookies (ESTSAUTHPERSISTENT + ESTSAUTH if still valid)
          3. GET portal-root URL · ESTS auto-SSO via persistent cookies · issues fresh sccauth
          4. Verify success: final response is portal JSON/HTML (not login form) AND new sccauth cookie present
          5. Return refreshed session OR $null if KMSI also expired/revoked OR tenant CA blocks SSO

        Cookie-jar strategy: copy ALL non-expired cookies from prior session (not just KMSI).
        ESTSAUTHPERSISTENT alone is insufficient · ESTS needs more state context for SSO re-mint.
        Empirical: cookies like esctx · ESTSAUTHLIGHT · brcap · fpc all carry tenant/region state.

        TOTP burn: ZERO when ESTS auto-SSOs. Falls through to full TOTP chain otherwise.
    #>
    [CmdletBinding()][OutputType([Microsoft.PowerShell.Commands.WebRequestSession])]
    param(
        [Parameter(Mandatory)][Microsoft.PowerShell.Commands.WebRequestSession]$PrevSession,
        [Parameter(Mandatory)][string]$PortalHost
    )
    $kmsi = Get-XdrKmsiCookie -Session $PrevSession
    if (-not $kmsi) {
        Write-Verbose "Invoke-XdrKmsiSsoRefresh: no valid ESTSAUTHPERSISTENT cookie · cannot SSO-refresh · TOTP chain required"
        return $null
    }
    # Build NEW session seeded with ALL valid (non-expired) cookies from prior session.
    # ESTS needs more than just ESTSAUTHPERSISTENT for SSO re-mint · empirically requires
    # esctx · ESTSAUTHLIGHT · fpc · brcap · stsservicecookie etc. for tenant-context.
    $newSession = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
    $newSession.UserAgent = $script:UserAgent
    $copiedCount = 0
    try {
        $prevCookies = $PrevSession.Cookies.GetAllCookies()
        foreach ($c in $prevCookies) {
            if (-not $c -or -not $c.Name) { continue }
            # Skip cookies that already expired (session cookies have Expires=MinValue · accept those)
            if ($c.Expires -and $c.Expires -gt [datetime]::MinValue -and $c.Expires -lt [datetime]::UtcNow) { continue }
            try {
                $nc = [System.Net.Cookie]::new($c.Name, $c.Value)
                $nc.Domain   = $c.Domain
                $nc.Path     = if ($c.Path) { $c.Path } else { '/' }
                if ($c.Expires -and $c.Expires -gt [datetime]::MinValue) { $nc.Expires = $c.Expires }
                $nc.Secure   = $c.Secure
                $nc.HttpOnly = $c.HttpOnly
                $newSession.Cookies.Add($nc)
                $copiedCount++
            } catch {
                Write-Verbose "Invoke-XdrKmsiSsoRefresh: skip cookie $($c.Name): $($_.Exception.Message)"
            }
        }
    } catch {
        Write-Verbose "Invoke-XdrKmsiSsoRefresh: failed to enumerate prior cookies: $($_.Exception.Message)"
        return $null
    }
    Write-Verbose "Invoke-XdrKmsiSsoRefresh: copied $copiedCount cookies from prior session (KMSI + companions)"

    # Attempt SSO re-mint: GET portal-root with full cookie state · ESTS should auto-SSO and issue fresh sccauth
    try {
        $resp = Invoke-WebRequest -Uri "https://$PortalHost/" -WebSession $newSession `
            -Method Get -UseBasicParsing -MaximumRedirection 10 -SkipHttpErrorCheck -ErrorAction Stop
    } catch {
        Write-Verbose "Invoke-XdrKmsiSsoRefresh: portal-root GET failed: $($_.Exception.Message)"
        return $null
    }
    # Success criteria:
    # 1. New session has sccauth cookie issued by ESTS SSO (session-scope or future-dated)
    #    NOTE: Microsoft issues sccauth as a SESSION COOKIE with Expires=DateTime.MinValue.
    #    Earlier check `$_.Expires -gt UtcNow` rejected these · WRONG · session cookies are valid.
    # 2. Response is not an ESTS login/MFA form (KMSI accepted · auto-SSO succeeded · we're on portal)
    $newCookies = try { $newSession.Cookies.GetAllCookies() } catch { @() }
    $hasSccauth = @($newCookies | Where-Object {
        $_.Name -eq 'sccauth' -and (
            (-not $_.Expires) -or                               # Cookie has no expiry attribute → valid
            ($_.Expires -le [datetime]::MinValue) -or            # Session cookie sentinel · browser-life · valid
            ($_.Expires -gt [datetime]::UtcNow)                  # Future-dated · explicitly valid
        )
    }).Count -gt 0
    # ESTS-form detection · separate REAL login forms (no walk possible · need TOTP)
    # from walkable INTERRUPT pages (KmsiInterrupt / CmsiInterrupt / ConvergedProofUpRedirect)
    # · this distinction is φ.AUTH.3 · prior code lumped both together as 'ests-form-returned'.
    $body = if ($resp.Content) { [string]$resp.Content } else { '' }
    $isLoginForm = ($body -match '(?i)<form[^>]*action="[^"]*\/(common|organizations)\/login') -or `
                   ($body -match '(?i)login\.srf') -or `
                   ($body -match '(?i)"pgid"\s*:\s*"(LoginPage|MfaPage|CredentialsPage|UsernamePage|PasswordPage)"')
    $interruptPgidMatch = [regex]::Match($body, '(?i)"pgid"\s*:\s*"(KmsiInterrupt|CmsiInterrupt|ConvergedProofUpRedirect)"')
    $isInterruptForm = $interruptPgidMatch.Success
    if ($hasSccauth -and -not $isLoginForm -and -not $isInterruptForm) {
        Write-Verbose "Invoke-XdrKmsiSsoRefresh: SUCCESS · sccauth issued by ESTS SSO · portal page returned · no TOTP needed"
        _Emit-AuthTelemetry -Level Information -EventName 'Auth.KmsiSsoSuccess' `
            -Message "KMSI SSO re-mint succeeded for $PortalHost (no TOTP)" `
            -Properties @{ PortalHost=$PortalHost; CookiesCopied=$copiedCount; SsoLatencyMs=$null }
        return $newSession
    }
    # φ.AUTH.3 · ESTS returned an INTERRUPT page (Kmsi/Cmsi/ConvergedProofUpRedirect) · WALK it
    # · interrupt pages are post-credentials checkpoints that just need a continue-POST · prior
    # code gave up here and forced TOTP burn · the walker now closes those cases without TOTP.
    if ($isInterruptForm) {
        $initialPgid = $interruptPgidMatch.Groups[1].Value
        Write-Verbose "Invoke-XdrKmsiSsoRefresh: detected interrupt pgid='$initialPgid' · walking via Resolve-EntraInterruptPage (φ.AUTH.3)"
        _Emit-AuthTelemetry -Level Information -EventName 'Auth.KmsiSsoInterruptWalked' `
            -Message "Walking ESTS interrupt page (pgid=$initialPgid) on KMSI SSO path" `
            -Properties @{ PortalHost=$PortalHost; InitialPgid=$initialPgid }
        try {
            $state = Get-EntraConfigBlob -Html $body
            if ($state) {
                $walked = Resolve-EntraInterruptPage -Session $newSession -AuthResult @{ State = $state; LastResponse = $resp }
                # Re-check sccauth + form state on the walked response
                $newCookies2  = try { $newSession.Cookies.GetAllCookies() } catch { @() }
                $hasSccauth2  = @($newCookies2 | Where-Object {
                    $_.Name -eq 'sccauth' -and (
                        (-not $_.Expires) -or
                        ($_.Expires -le [datetime]::MinValue) -or
                        ($_.Expires -gt [datetime]::UtcNow)
                    )
                }).Count -gt 0
                $body2 = if ($walked.LastResponse -and $walked.LastResponse.Content) { [string]$walked.LastResponse.Content } else { '' }
                $isLoginForm2  = ($body2 -match '(?i)<form[^>]*action="[^"]*\/(common|organizations)\/login') -or `
                                 ($body2 -match '(?i)login\.srf') -or `
                                 ($body2 -match '(?i)"pgid"\s*:\s*"(LoginPage|MfaPage|CredentialsPage|UsernamePage|PasswordPage)"')
                $isInterruptForm2 = $body2 -match '(?i)"pgid"\s*:\s*"(KmsiInterrupt|CmsiInterrupt|ConvergedProofUpRedirect)"'
                if ($hasSccauth2 -and -not $isLoginForm2 -and -not $isInterruptForm2) {
                    Write-Verbose "Invoke-XdrKmsiSsoRefresh: interrupt walked SUCCESS · sccauth present · portal page · no TOTP needed"
                    _Emit-AuthTelemetry -Level Information -EventName 'Auth.KmsiSsoInterruptResolved' `
                        -Message "ESTS interrupt walked to success on $PortalHost (no TOTP)" `
                        -Properties @{ PortalHost=$PortalHost; InitialPgid=$initialPgid; CookiesCopied=$copiedCount }
                    return $newSession
                }
                _Emit-AuthTelemetry -Level Warning -EventName 'Auth.KmsiSsoInterruptUnresolved' `
                    -Message "ESTS interrupt walked but still no portal page (pgid=$initialPgid · loginForm=$isLoginForm2 · interruptForm=$isInterruptForm2)" `
                    -Properties @{ PortalHost=$PortalHost; InitialPgid=$initialPgid; HasSccauthAfter=$hasSccauth2; LoginFormAfter=$isLoginForm2; InterruptFormAfter=$isInterruptForm2 }
            } else {
                _Emit-AuthTelemetry -Level Warning -EventName 'Auth.KmsiSsoInterruptUnresolved' `
                    -Message "ESTS interrupt detected but `$Config blob unparseable (pgid=$initialPgid)" `
                    -Properties @{ PortalHost=$PortalHost; InitialPgid=$initialPgid; FailReason='config-blob-unparseable' }
            }
        } catch {
            _Emit-AuthTelemetry -Level Warning -EventName 'Auth.KmsiSsoInterruptUnresolved' `
                -Message "Interrupt walker threw: $($_.Exception.Message)" `
                -Properties @{ PortalHost=$PortalHost; InitialPgid=$initialPgid; FailReason='walker-exception'; Error=$_.Exception.Message }
        }
    }
    # Diagnostic: distinguish failure modes for operator visibility · all emit Auth.KmsiSsoFail
    $failReason = if (-not $hasSccauth -and -not $isLoginForm -and -not $isInterruptForm) {
        "no-sccauth-no-form"
    } elseif ($isLoginForm) {
        "ests-login-form-returned"   # tenant CA blocks SSO · or KMSI revoked · genuine TOTP needed
    } elseif ($isInterruptForm) {
        "ests-interrupt-walk-failed" # walker tried but couldn't reach portal page
    } else {
        "sccauth-with-form-ambiguous"
    }
    Write-Verbose "Invoke-XdrKmsiSsoRefresh: KMSI SSO failed · reason=$failReason · TOTP chain required"
    _Emit-AuthTelemetry -Level Warning -EventName 'Auth.KmsiSsoFail' `
        -Message "KMSI SSO re-mint failed for $PortalHost · falls back to TOTP" `
        -Properties @{ PortalHost=$PortalHost; FailReason=$failReason; CookiesCopied=$copiedCount; HasSccauth=$hasSccauth; HasLoginForm=$isLoginForm; HasInterruptForm=$isInterruptForm }
    return $null
}

# Internal telemetry wrapper · uses Write-XdrTelemetry when Xdr.Common.Telemetry is loaded ·
# falls back to Write-Verbose otherwise (test isolation · standalone usage).
function _Emit-AuthTelemetry {
    [CmdletBinding()]
    param(
        [ValidateSet('Verbose','Information','Warning','Error','Critical')][string]$Level = 'Information',
        [Parameter(Mandatory)][string]$EventName,
        [Parameter(Mandatory)][string]$Message,
        [hashtable]$Properties = @{}
    )
    if (Get-Command Write-XdrTelemetry -ErrorAction SilentlyContinue) {
        try {
            Write-XdrTelemetry -Level $Level -Message $Message -Properties $Properties -EventName $EventName
        } catch {
            # Never let telemetry failure break auth · log + swallow
            Write-Verbose ("Xdr.Auth: telemetry emit failed for $EventName · " + $_.Exception.Message)
        }
    } else {
        Write-Verbose ("[$Level] [$EventName] $Message")
    }
}
#endregion

#region TOTP (RFC 6238)
function Get-XdrTotpCode {
    [CmdletBinding()][OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Base32Secret,
        [int]$Period = 30,
        [int]$Digits = 6,
        [datetime]$Now = [datetime]::UtcNow
    )
    $b32 = $Base32Secret.ToUpper().Replace('=','').Replace(' ','')
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
    $bits = ''
    foreach ($ch in $b32.ToCharArray()) {
        $i = $alphabet.IndexOf($ch)
        if ($i -lt 0) { throw "Invalid base32 char: $ch" }
        $bits += [Convert]::ToString($i,2).PadLeft(5,'0')
    }
    $bytes = New-Object byte[] ([math]::Floor($bits.Length / 8))
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $bytes[$i] = [Convert]::ToByte($bits.Substring($i * 8, 8), 2)
    }
    $epoch  = [datetime]::new(1970,1,1,0,0,0,[DateTimeKind]::Utc)
    $nowUtc = if ($Now.Kind -eq [DateTimeKind]::Utc) { $Now } else { $Now.ToUniversalTime() }
    $counter = [int64][math]::Floor(($nowUtc - $epoch).TotalSeconds / $Period)
    $ctrBytes = [BitConverter]::GetBytes($counter)
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($ctrBytes) }
    $hmac = New-Object System.Security.Cryptography.HMACSHA1(,$bytes)
    $hash = $hmac.ComputeHash($ctrBytes)
    $offset = $hash[$hash.Length - 1] -band 0xF
    $binary = (([int]$hash[$offset]     -band 0x7F) -shl 24) -bor `
              (([int]$hash[$offset + 1] -band 0xFF) -shl 16) -bor `
              (([int]$hash[$offset + 2] -band 0xFF) -shl 8)  -bor `
              ( [int]$hash[$offset + 3] -band 0xFF)
    $otp = $binary % [math]::Pow(10,$Digits)
    $otp.ToString().PadLeft($Digits,'0')
}
#endregion

#region Key Vault / env.local credential reader
function Get-XdrAuthFromKeyVault {
    <#
    .SYNOPSIS
        Read service-account credentials from Key Vault (KV mode) or env.local (test mode).
        φ.AUTH.1 · TTL cache prevents throttle on hot poll cycles · default 60min · KV.CacheEvicted telemetry.
    .DESCRIPTION
        KV throttle limit: 16K reads / 10min per vault. Without cache · every 5-min FA timer
        burns 3 reads (defender-upn/password/totp). At 5 portals × 5min cycles · ≈180 reads/hr
        from single FA worker · cascade to throttle territory at scale (multi-worker / MSSP).

        TTL cache (in-memory module-scope · `$script:CredentialCache`) holds the credential
        bundle for `Ttl` minutes (default 60 · `KV_CACHE_TTL_MINUTES` env override · `-Force`
        param bypasses). Cache key = `"$VaultUri|$SecretPrefix|$AuthMethod"` so v0.3.0 multi-portal
        Connect-*Portal can share cache across portals using same SA.

        Cache miss / eviction emits KV.CacheEvicted telemetry (reason: first-fetch | ttl |
        manual) · observable in AppInsights for ops to track auth cost.
    .PARAMETER KeyVaultName
        KV resource name (FA runtime mode).
    .PARAMETER FromEnvLocal
        Dev / test mode · reads creds from $env:XDRLR_TEST_* · no KV / no cache.
    .PARAMETER SecretPrefix
        Per-portal secret name prefix (default 'defender'). Future: 'purview' · etc.
    .PARAMETER Ttl
        TTL in minutes for in-memory cache · default 60 · override via $env:KV_CACHE_TTL_MINUTES.
    .PARAMETER Force
        Bypass cache · always re-fetch from KV (emits KV.CacheEvicted reason=manual).
    #>
    [CmdletBinding()][OutputType([pscustomobject])]
    param(
        [string]$KeyVaultName,
        [switch]$FromEnvLocal,
        [string]$SecretPrefix = 'defender',
        [int]$Ttl             = $(if ($env:KV_CACHE_TTL_MINUTES) { [int]$env:KV_CACHE_TTL_MINUTES } else { 60 }),
        [switch]$Force
    )

    # env.local mode · no KV · no cache (dev / test path)
    if ($FromEnvLocal -or -not $KeyVaultName) {
        if (-not $env:XDRLR_TEST_UPN) {
            throw "Get-XdrAuthFromKeyVault -FromEnvLocal requires XDRLR_TEST_UPN/PASSWORD/TOTP_SECRET env vars."
        }
        return [pscustomobject]@{
            Upn        = $env:XDRLR_TEST_UPN
            Password   = $env:XDRLR_TEST_PASSWORD
            TotpSecret = $env:XDRLR_TEST_TOTP_SECRET
            AuthMethod = 'CredentialsTotp'
        }
    }

    # KV mode · check TTL cache first
    $authMethod = 'CredentialsTotp'   # v0.1.0 default · φ.AUTH.6 expands to Passkey
    $cacheKey = "${KeyVaultName}|${SecretPrefix}|${authMethod}"
    # StrictMode-safe init · Get-Variable-then-assign pattern avoids "variable not set" throws
    if (-not (Get-Variable -Scope Script -Name CredentialCache -ErrorAction SilentlyContinue)) {
        $script:CredentialCache = @{}
    }
    if (-not (Get-Variable -Scope Script -Name CredentialCacheExpiry -ErrorAction SilentlyContinue)) {
        $script:CredentialCacheExpiry = @{}
    }

    if (-not $Force.IsPresent -and $script:CredentialCache.ContainsKey($cacheKey)) {
        $expiry = $script:CredentialCacheExpiry[$cacheKey]
        if ($expiry -and $expiry -gt [datetime]::UtcNow) {
            $remainMin = [math]::Round(($expiry - [datetime]::UtcNow).TotalMinutes, 1)
            _Emit-AuthTelemetry -Level Verbose -EventName 'KV.CacheHit' `
                -Message "KV credential cache hit for $cacheKey · expires in ${remainMin}min" `
                -Properties @{ CacheKey=$cacheKey; ExpiresInMinutes=$remainMin; Ttl=$Ttl; KeyVaultName=$KeyVaultName }
            return $script:CredentialCache[$cacheKey]
        }
        # Expired
        _Emit-AuthTelemetry -Level Information -EventName 'KV.CacheEvicted' `
            -Message "KV credential cache evicted (TTL expired)" `
            -Properties @{ CacheKey=$cacheKey; Reason='ttl'; Ttl=$Ttl; KeyVaultName=$KeyVaultName }
        $script:CredentialCache.Remove($cacheKey) | Out-Null
        $script:CredentialCacheExpiry.Remove($cacheKey) | Out-Null
    } elseif ($Force.IsPresent -and $script:CredentialCache.ContainsKey($cacheKey)) {
        _Emit-AuthTelemetry -Level Information -EventName 'KV.CacheEvicted' `
            -Message "KV credential cache evicted (-Force manual)" `
            -Properties @{ CacheKey=$cacheKey; Reason='manual'; KeyVaultName=$KeyVaultName }
        $script:CredentialCache.Remove($cacheKey) | Out-Null
        $script:CredentialCacheExpiry.Remove($cacheKey) | Out-Null
    } else {
        # First fetch · log for visibility
        _Emit-AuthTelemetry -Level Information -EventName 'KV.CacheEvicted' `
            -Message "KV credential cache first-fetch (no prior cache)" `
            -Properties @{ CacheKey=$cacheKey; Reason='first-fetch'; Ttl=$Ttl; KeyVaultName=$KeyVaultName }
    }

    # Fetch from KV (3 mandatory + 2 optional Passkey secrets · φ.AUTH.6b · D-2026-05-18b)
    # Π11.C2 · KV exponential backoff (3 attempts · 250ms · 1s · 4s ± jitter) for 429/503 survival.
    # Without backoff: first 429 (KV throttle at 2000 ops/10s) trips auth-failure circuit → cascade.
    # With backoff: most transient throttles absorbed silently · only persistent failure trips circuit.
    function _Invoke-KvSecretWithRetry {
        param([string]$VaultName, [string]$Name, [switch]$Optional)
        $delays = @(250, 1000, 4000)   # ms · 3 attempts total
        $attempt = 0
        foreach ($d in $delays) {
            $attempt++
            try {
                if ($Optional) {
                    return Get-AzKeyVaultSecret -VaultName $VaultName -Name $Name -AsPlainText -ErrorAction SilentlyContinue
                } else {
                    return Get-AzKeyVaultSecret -VaultName $VaultName -Name $Name -AsPlainText -ErrorAction Stop
                }
            } catch {
                $msg = $_.Exception.Message
                $is429or503 = ($msg -match '\b(429|503|429-)\b|TooManyRequests|ServiceUnavailable|throttl|temporary')
                if (-not $is429or503 -or $attempt -ge $delays.Count) {
                    if ($Optional) { return $null }
                    throw
                }
                $jitter = Get-Random -Minimum -50 -Maximum 50
                $sleepMs = [Math]::Max(50, $d + $jitter)
                _Emit-AuthTelemetry -Level Warning -EventName 'KV.RetryAttempt' `
                    -Message ("KV transient fault on '{0}' · attempt {1}/{2} · sleeping {3}ms · {4}" -f $Name, $attempt, $delays.Count, $sleepMs, $msg) `
                    -Properties @{ SecretName=$Name; Attempt=$attempt; SleepMs=$sleepMs; Error=$msg }
                Start-Sleep -Milliseconds $sleepMs
            }
        }
        if ($Optional) { return $null }
        throw "KV retry exhausted for secret '$Name'"
    }
    try {
        Import-Module Az.KeyVault -ErrorAction Stop
        $upn      = _Invoke-KvSecretWithRetry -VaultName $KeyVaultName -Name "$SecretPrefix-upn"
        $password = _Invoke-KvSecretWithRetry -VaultName $KeyVaultName -Name "$SecretPrefix-password"
        $totpSeed = _Invoke-KvSecretWithRetry -VaultName $KeyVaultName -Name "$SecretPrefix-totp"
        # φ.AUTH.6b · OPTIONAL Passkey secrets (operator picks per SA)
        $kvAuthMethod = _Invoke-KvSecretWithRetry -VaultName $KeyVaultName -Name "$SecretPrefix-auth-method" -Optional
        $passkeyPem   = _Invoke-KvSecretWithRetry -VaultName $KeyVaultName -Name "$SecretPrefix-passkey-pem" -Optional
        # Resolve AuthMethod · KV secret overrides default (CredentialsTotp)
        $resolvedAuthMethod = if ($kvAuthMethod -and $kvAuthMethod.Trim() -in @('CredentialsTotp','Passkey')) { $kvAuthMethod.Trim() } else { 'CredentialsTotp' }
        # If Passkey selected but PEM missing · throw early (no silent fallback to TOTP)
        if ($resolvedAuthMethod -eq 'Passkey' -and -not $passkeyPem) {
            throw "Get-XdrAuthFromKeyVault: $SecretPrefix-auth-method='Passkey' but $SecretPrefix-passkey-pem is missing/empty in KV."
        }
        $bundle = [pscustomobject]@{
            Upn        = $upn
            Password   = $password
            TotpSecret = $totpSeed
            AuthMethod = $resolvedAuthMethod
            # Passkey field populated when Method=Passkey · PSCustomObject matching
            # Invoke-XdrPasskeyChallenge contract (credentialId + privateKeyPem + rpId)
            Passkey    = if ($passkeyPem) {
                [pscustomobject]@{
                    credentialId  = $upn  # using UPN as credential identifier (operator may parametrize later)
                    privateKeyPem = $passkeyPem
                    rpId          = 'login.microsoft.com'
                }
            } else { $null }
        }
    } catch {
        _Emit-AuthTelemetry -Level Error -EventName 'KV.FetchFailed' `
            -Message "Failed to read KV secret bundle: $($_.Exception.Message)" `
            -Properties @{ CacheKey=$cacheKey; KeyVaultName=$KeyVaultName; Error=$_.Exception.Message }
        throw
    }

    # Populate cache + set expiry
    $script:CredentialCache[$cacheKey]       = $bundle
    $script:CredentialCacheExpiry[$cacheKey] = [datetime]::UtcNow.AddMinutes($Ttl)
    _Emit-AuthTelemetry -Level Information -EventName 'KV.CacheWrite' `
        -Message "KV credential bundle fetched and cached for ${Ttl}min" `
        -Properties @{ CacheKey=$cacheKey; Ttl=$Ttl; KeyVaultName=$KeyVaultName; SecretPrefix=$SecretPrefix }
    return $bundle
}

function Clear-XdrCredentialCache {
    <#
    .SYNOPSIS
        φ.AUTH.1 · Operator/test cleanup of in-memory KV credential cache.
    #>
    [CmdletBinding()] param()
    # StrictMode-safe · use Get-Variable to test existence without throwing
    if (Get-Variable -Scope Script -Name CredentialCache -ErrorAction SilentlyContinue) {
        if ($script:CredentialCache) { $script:CredentialCache.Clear() }
    }
    if (Get-Variable -Scope Script -Name CredentialCacheExpiry -ErrorAction SilentlyContinue) {
        if ($script:CredentialCacheExpiry) { $script:CredentialCacheExpiry.Clear() }
    }
    _Emit-AuthTelemetry -Level Information -EventName 'KV.CacheClear' `
        -Message "KV credential cache cleared" -Properties @{}
}
#endregion

#region φ.AUTH.2 · Auth-failure sliding-window circuit-breaker (port from v2 · B-21 fix)
# Goal · prevent TOTP cascade-retry · Microsoft Authenticator rejects duplicate codes within
# 30-sec window · concurrent Durable activities that all hit AuthChainBroken would each retry
# TOTP burn = guaranteed duplicate-code rejection cascade.
#
# Design · per-cache-key list of failure DateTimes · prune entries older than -WindowMinutes ·
# trip when count >= -TripThreshold · OPEN circuit throws AuthCircuitOpenException on Test ·
# successful auth Reset clears the window for the key. Recovery is automatic (sliding window
# decays · once window empty the next attempt resumes normal chain).
#
# Cache key recommended · "$upn::$PortalHost" (matches in-memory SessionCache) so each
# UPN+portal pair has independent circuit (multi-portal cold-start can't trip each other).

# Π11.C3 · Persist auth-failure circuit state across cold-start (FA recycle).
# Without this · FA restart loses $script:AuthFailureWindow · re-opens fresh circuit · allows
# 2 more TOTP-burn attempts before retripping (in the rare KMSI-cookie-also-expired scenario).
# Path lives next to SessionCache file (operator-local · /tmp on Y1 Linux · gitignored).
function _Get-XdrAuthCircuitStatePath {
    $base = if ($env:XDR_AUTH_CIRCUIT_STATE_PATH) { $env:XDR_AUTH_CIRCUIT_STATE_PATH }
            else { Join-Path ([System.IO.Path]::GetTempPath()) 'xdrlr-auth-circuit-state.json' }
    return $base
}
function _Save-XdrAuthCircuitState {
    try {
        if (-not (Get-Variable -Scope Script -Name AuthFailureWindow -ErrorAction SilentlyContinue)) { return }
        if (-not $script:AuthFailureWindow -or $script:AuthFailureWindow.Count -eq 0) {
            # No state · ensure file removed
            $p = _Get-XdrAuthCircuitStatePath
            if (Test-Path $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
            return
        }
        $serial = @{}
        foreach ($k in $script:AuthFailureWindow.Keys) {
            $serial[$k] = @($script:AuthFailureWindow[$k] | ForEach-Object { ([datetime]$_).ToString('o') })
        }
        $p = _Get-XdrAuthCircuitStatePath
        $tmp = "$p.tmp"
        [System.IO.File]::WriteAllText($tmp, ($serial | ConvertTo-Json -Depth 4 -Compress), [System.Text.UTF8Encoding]::new($false))
        if (Test-Path $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
        Move-Item -LiteralPath $tmp -Destination $p -Force
    } catch {
        # Best-effort persistence · non-fatal
    }
}
function _Load-XdrAuthCircuitState {
    try {
        $p = _Get-XdrAuthCircuitStatePath
        if (-not (Test-Path $p)) { return }
        $raw = Get-Content -Raw -LiteralPath $p -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return }
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        $cutoff = [datetime]::UtcNow.AddMinutes(-5)   # prune-on-load · 5-min sliding window invariant
        if (-not (Get-Variable -Scope Script -Name AuthFailureWindow -ErrorAction SilentlyContinue)) {
            $script:AuthFailureWindow = @{}
        }
        foreach ($k in $obj.PSObject.Properties.Name) {
            $dts = @($obj.$k | ForEach-Object {
                try { [datetime]::Parse([string]$_, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { $null }
            } | Where-Object { $_ -and $_ -gt $cutoff })
            if ($dts.Count -gt 0) { $script:AuthFailureWindow[$k] = $dts }
        }
    } catch {
        # Best-effort restore · non-fatal · empty state acceptable on parse failure
    }
}
# Load persisted circuit state at module-load (idempotent · prune-on-load enforces 5-min invariant)
_Load-XdrAuthCircuitState

function Test-XdrAuthCircuitOpen {
    <#
    .SYNOPSIS
        φ.AUTH.2 · Sliding-window circuit-breaker check · returns $true when OPEN (caller
        MUST refuse to attempt auth and either fall back to cached session or throw).
    .DESCRIPTION
        Prunes entries older than -WindowMinutes (default 5) · returns $true when remaining
        failure count >= -TripThreshold (default 2). Emits Auth.FailureCircuit.OpenSkip
        verbose telemetry when OPEN. Pure read-only · does NOT mutate state.
    .PARAMETER Key
        Circuit key · recommended "$upn::$PortalHost".
    .PARAMETER WindowMinutes
        Sliding window length · default 5.
    .PARAMETER TripThreshold
        Failure count that trips OPEN · default 2.
    #>
    [CmdletBinding()][OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Key,
        [int]$WindowMinutes = 5,
        [int]$TripThreshold = 2
    )
    if (-not (Get-Variable -Scope Script -Name AuthFailureWindow -ErrorAction SilentlyContinue)) {
        $script:AuthFailureWindow = @{}
    }
    if (-not $script:AuthFailureWindow.ContainsKey($Key)) { return $false }
    $cutoff = [datetime]::UtcNow.AddMinutes(-$WindowMinutes)
    $recent = @($script:AuthFailureWindow[$Key] | Where-Object { $_ -gt $cutoff })
    $script:AuthFailureWindow[$Key] = $recent
    $isOpen = ($recent.Count -ge $TripThreshold)
    if ($isOpen) {
        _Emit-AuthTelemetry -Level Warning -EventName 'Auth.FailureCircuit.OpenSkip' `
            -Message ("Auth circuit OPEN for {0} · skipping chain ({1} failures in {2}min · trip={3})" -f $Key, $recent.Count, $WindowMinutes, $TripThreshold) `
            -Properties @{ Key=$Key; FailureCount=$recent.Count; WindowMinutes=$WindowMinutes; TripThreshold=$TripThreshold }
    }
    return $isOpen
}

function Add-XdrAuthCircuitFailure {
    <#
    .SYNOPSIS
        φ.AUTH.2 · Record an auth failure timestamp · trips circuit at threshold.
    .DESCRIPTION
        Appends [datetime]::UtcNow to the per-key window · prunes entries older than
        -WindowMinutes · emits Auth.FailureCircuit.Recorded telemetry · Auth.FailureCircuit.Tripped
        when count crosses -TripThreshold (first trip only).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Key,
        [int]$WindowMinutes = 5,
        [int]$TripThreshold = 2,
        [string]$Reason = 'unspecified'
    )
    if (-not (Get-Variable -Scope Script -Name AuthFailureWindow -ErrorAction SilentlyContinue)) {
        $script:AuthFailureWindow = @{}
    }
    if (-not $script:AuthFailureWindow.ContainsKey($Key)) {
        $script:AuthFailureWindow[$Key] = @()
    }
    $cutoff = [datetime]::UtcNow.AddMinutes(-$WindowMinutes)
    $before = @($script:AuthFailureWindow[$Key] | Where-Object { $_ -gt $cutoff })
    $after  = @($before + [datetime]::UtcNow)
    $script:AuthFailureWindow[$Key] = $after
    _Emit-AuthTelemetry -Level Warning -EventName 'Auth.FailureCircuit.Recorded' `
        -Message ("Auth failure recorded for {0} ({1} in {2}min · reason={3})" -f $Key, $after.Count, $WindowMinutes, $Reason) `
        -Properties @{ Key=$Key; FailureCount=$after.Count; WindowMinutes=$WindowMinutes; TripThreshold=$TripThreshold; Reason=$Reason }
    if ($before.Count -lt $TripThreshold -and $after.Count -ge $TripThreshold) {
        _Emit-AuthTelemetry -Level Error -EventName 'Auth.FailureCircuit.Tripped' `
            -Message ("Auth circuit TRIPPED OPEN for {0} ({1} failures in {2}min)" -f $Key, $after.Count, $WindowMinutes) `
            -Properties @{ Key=$Key; FailureCount=$after.Count; WindowMinutes=$WindowMinutes; TripThreshold=$TripThreshold; Reason=$Reason }
    }
    # Π11.C3 · persist circuit state across cold-start (FA recycle)
    _Save-XdrAuthCircuitState
}

function Reset-XdrAuthCircuit {
    <#
    .SYNOPSIS
        φ.AUTH.2 · Clear failure window for a key (call after successful auth).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Key)
    if (-not (Get-Variable -Scope Script -Name AuthFailureWindow -ErrorAction SilentlyContinue)) {
        return
    }
    if ($script:AuthFailureWindow.ContainsKey($Key)) {
        $had = @($script:AuthFailureWindow[$Key]).Count
        $script:AuthFailureWindow.Remove($Key) | Out-Null
        if ($had -gt 0) {
            _Emit-AuthTelemetry -Level Information -EventName 'Auth.FailureCircuit.Reset' `
                -Message "Auth circuit reset for $Key (cleared $had failures)" `
                -Properties @{ Key=$Key; ClearedCount=$had }
        }
        # Π11.C3 · persist circuit state across cold-start
        _Save-XdrAuthCircuitState
    }
}

function Clear-XdrAuthCircuit {
    <#
    .SYNOPSIS
        φ.AUTH.2 · Operator/test cleanup of all auth-failure windows.
    #>
    [CmdletBinding()] param()
    if (Get-Variable -Scope Script -Name AuthFailureWindow -ErrorAction SilentlyContinue) {
        if ($script:AuthFailureWindow) { $script:AuthFailureWindow.Clear() }
    }
    _Emit-AuthTelemetry -Level Information -EventName 'Auth.FailureCircuit.ClearAll' `
        -Message "All auth-failure circuits cleared" -Properties @{}
}
#endregion

#region φ.AUTH.6 · Passkey path (port from v1 · ECDSA-P256 WebAuthn assertion · /common/fido/get)
# Goal · unattended SA auth without TOTP burn · D-2026-05-18b · Passkey IN v0.1.0.
#
# Crypto primitives (NOT exported · pure helpers · StrictMode-safe):
#   ConvertTo-XdrBase64Url   · base64url encode (trim '=' · '+'→'-' · '/'→'_')
#   ConvertFrom-XdrBase64Url · base64url decode (reverse · pad to mod-4)
#   Invoke-XdrPasskeyChallenge · WebAuthn assertion sign · ECDSA-P256 · returns
#       { credentialId; clientDataJSON; authenticatorData; signature } base64url-encoded
#   Complete-XdrPasskeyFlow   · ESTS /common/fido/get pre-verify → /common/login submit →
#       SSO reload → returns { State; LastResponse } for interrupt-walker handoff
#
# Test vector · tests/unit/Auth.Passkey.Tests.ps1 uses fixed ECDSA-P256 PEM + fixed
# challenge + verifies signature with corresponding public key (deterministic · offline).

function ConvertTo-XdrBase64Url {
    [CmdletBinding()][OutputType([string])]
    param([Parameter(Mandatory)][byte[]]$Bytes)
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
}

function ConvertFrom-XdrBase64Url {
    [CmdletBinding()][OutputType([byte[]])]
    param([Parameter(Mandatory)][string]$Text)
    $padded = $Text.Replace('-','+').Replace('_','/')
    $mod = $padded.Length % 4
    if ($mod) { $padded = $padded + ('=' * (4 - $mod)) }
    [Convert]::FromBase64String($padded)
}

function Invoke-XdrPasskeyChallenge {
    <#
    .SYNOPSIS
        φ.AUTH.6 · Sign a WebAuthn authentication assertion with an ECDSA-P256 software passkey.
    .DESCRIPTION
        Pure crypto · NO network IO · NO state mutation. Returns the 4-tuple WebAuthn assertion
        components that Complete-XdrPasskeyFlow will submit to /common/login.

        Spec reference · W3C WebAuthn Level 2 §7.2 "Verifying an Authentication Assertion":
          1. Build clientDataJSON · {type:'webauthn.get', challenge, origin}
          2. Compute rpIdHash = SHA-256(rpId)
          3. Build authData · rpIdHash(32B) || flags(1B · 0x05=UP+UV) || signCount(4B · 0)
          4. Sign(authData || SHA-256(clientDataJSON)) with ECDSA-P256 · DER format
          5. Return base64url-encoded fields

        Default rpId · 'login.microsoft.com' (Entra issues passkey assertions for ALL portals
        via this RP regardless of target portal · Defender/Purview/Intune all delegate here).
    .PARAMETER PasskeyJson
        PSCustomObject with required fields:
          - credentialId  · base64url string (the registered passkey credential ID)
          - privateKeyPem · PEM-encoded ECDSA-P256 private key
          - rpId          · OPTIONAL · defaults to 'login.microsoft.com'
    .PARAMETER Challenge
        Base64url-encoded challenge bytes from the ESTS server (oGetCredTypeResult.Credentials.FidoParams.Challenge).
    .PARAMETER Origin
        Origin URL embedded in clientDataJSON · defaults 'https://login.microsoft.com'.
    .OUTPUTS
        [hashtable] · keys: credentialId · clientDataJSON · authenticatorData · signature
        (all base64url-encoded · ready to submit in /common/login assertion body)
    #>
    [CmdletBinding()][OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][pscustomobject]$PasskeyJson,
        [Parameter(Mandatory)][string]$Challenge,
        [string]$Origin = 'https://login.microsoft.com'
    )
    # Required field validation (StrictMode-safe · Test-EntraField guards)
    if (-not (Test-EntraField -Object $PasskeyJson -Name 'credentialId') -or -not $PasskeyJson.credentialId) {
        throw "Invoke-XdrPasskeyChallenge: PasskeyJson.credentialId required (base64url)"
    }
    if (-not (Test-EntraField -Object $PasskeyJson -Name 'privateKeyPem') -or -not $PasskeyJson.privateKeyPem) {
        throw "Invoke-XdrPasskeyChallenge: PasskeyJson.privateKeyPem required (ECDSA-P256 PEM)"
    }
    # 1. clientDataJSON · ordered JSON · WebAuthn spec requires this exact 3-field shape
    $clientData = [ordered]@{ type = 'webauthn.get'; challenge = $Challenge; origin = $Origin }
    $clientDataBytes = [System.Text.Encoding]::UTF8.GetBytes(($clientData | ConvertTo-Json -Compress))
    # 2. rpIdHash = SHA-256(rpId UTF-8 bytes)
    $rpId = if ((Test-EntraField -Object $PasskeyJson -Name 'rpId') -and $PasskeyJson.rpId) { $PasskeyJson.rpId } else { 'login.microsoft.com' }
    $rpIdHash = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($rpId))
    # 3. authData · rpIdHash(32) || flags(1 · 0x05=UP+UV) || signCount(4 · 0 for software auth)
    $authData = [byte[]]::new(37)
    [array]::Copy($rpIdHash, 0, $authData, 0, 32)
    $authData[32] = [byte]0x05
    [array]::Copy([byte[]]@(0,0,0,0), 0, $authData, 33, 4)
    # 4. signature base · authData || SHA-256(clientDataJSON)
    $clientDataHash = [System.Security.Cryptography.SHA256]::HashData($clientDataBytes)
    $toSign = [byte[]]::new($authData.Length + $clientDataHash.Length)
    [array]::Copy($authData, 0, $toSign, 0, $authData.Length)
    [array]::Copy($clientDataHash, 0, $toSign, $authData.Length, $clientDataHash.Length)
    # 5. Sign · ECDSA-P256 · DER format (WebAuthn requires RFC3279 DER · NOT IEEE P1363 raw)
    $ecdsa = [System.Security.Cryptography.ECDsa]::Create()
    try {
        $ecdsa.ImportFromPem($PasskeyJson.privateKeyPem)
        $sig = $ecdsa.SignData($toSign, [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.DSASignatureFormat]::Rfc3279DerSequence)
    } finally {
        $ecdsa.Dispose()
    }
    @{
        credentialId      = $PasskeyJson.credentialId
        clientDataJSON    = ConvertTo-XdrBase64Url -Bytes $clientDataBytes
        authenticatorData = ConvertTo-XdrBase64Url -Bytes $authData
        signature         = ConvertTo-XdrBase64Url -Bytes $sig
    }
}

function Complete-XdrPasskeyFlow {
    <#
    .SYNOPSIS
        φ.AUTH.6 · End-to-end passkey assertion submission · pre-verify + login + SSO reload.
    .DESCRIPTION
        Mirrors v1 Complete-PasskeyFlow but adapted to mvp monolith conventions:
          1. Extract FIDO challenge from ESTS $Config (oGetCredTypeResult.Credentials.FidoParams.Challenge
             or sFidoChallenge fallback)
          2. Invoke-XdrPasskeyChallenge · sign the assertion
          3. POST /common/fido/get?uiflavor=Web (pre-verify · returns updated $Config with new sCtx)
          4. POST signed assertion to /common/login (type=23)
          5. SSO reload POST (re-uses oGetCredTypeResult.FlowToken if present)
          6. Return { State; LastResponse } so caller can hand off to Resolve-EntraInterruptPage
             (KmsiInterrupt walk · same as TOTP flow exits)
    .PARAMETER Session
        WebRequestSession seeded with /authorize GET cookies + ESTS state.
    .PARAMETER SessionInfo
        $Config blob from the /authorize response · must contain sCtx · sFT · canary ·
        urlPost · oGetCredTypeResult (with Credentials.FidoParams).
    .PARAMETER Credential
        Hashtable with 'upn' + 'passkey' (PSCustomObject with credentialId · privateKeyPem · rpId).
    .PARAMETER CorrelationId
        Cycle correlation GUID for telemetry stitching.
    #>
    [CmdletBinding()][OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [Parameter(Mandatory)][pscustomobject]$SessionInfo,
        [Parameter(Mandatory)][hashtable]$Credential,
        [Parameter(Mandatory)][guid]$CorrelationId
    )
    $passkey = if ($Credential.ContainsKey('passkey')) { $Credential.passkey } else { $null }
    if (-not $passkey) { throw "Complete-XdrPasskeyFlow: Credential must include 'passkey' PSCustomObject" }
    # Extract FIDO challenge from $Config
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
        throw "Complete-XdrPasskeyFlow: passkey not available · HasFido=$hasFido ChallengePresent=$([bool]$challenge) · register passkey via mysignins.microsoft.com"
    }
    # Sign the WebAuthn assertion
    $assertion = Invoke-XdrPasskeyChallenge -PasskeyJson $passkey -Challenge $challenge -Origin 'https://login.microsoft.com'
    # XDRInternals pattern · pre-verify at /common/fido/get?uiflavor=Web (some tenants require this)
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
    Write-Verbose "Complete-XdrPasskeyFlow: pre-verify at /common/fido/get"
    $verifyResp = Invoke-WebRequest -Uri 'https://login.microsoft.com/common/fido/get?uiflavor=Web' `
        -WebSession $Session -Method Post -Body $verifyBody `
        -UseBasicParsing -MaximumRedirection 0 -SkipHttpErrorCheck
    $responseInfo = Get-EntraConfigBlob -Html $verifyResp.Content
    if (-not $responseInfo) {
        throw "Complete-XdrPasskeyFlow: pre-verify returned no parseable `$Config (HTTP $($verifyResp.StatusCode))"
    }
    # Submit signed assertion to /common/login (type=23 = passkey)
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
    Write-Verbose "Complete-XdrPasskeyFlow: POST assertion to /common/login"
    $loginResp = Invoke-WebRequest -Uri 'https://login.microsoftonline.com/common/login' `
        -WebSession $Session -Method Post -Body $loginBody `
        -UseBasicParsing -MaximumRedirection 0 -SkipHttpErrorCheck
    # SSO reload · re-POST with oGetCredTypeResult.FlowToken (when present)
    $reloadFlowToken = Get-EntraField -Object (Get-EntraField -Object $SessionInfo -Name 'oGetCredTypeResult') -Name 'FlowToken'
    if ($reloadFlowToken) {
        $loginBody.flowToken = $reloadFlowToken
        Write-Verbose "Complete-XdrPasskeyFlow: SSO reload POST"
        $reloadResp = Invoke-WebRequest -Uri 'https://login.microsoftonline.com/common/login?sso_reload=true' `
            -WebSession $Session -Method Post -Body $loginBody `
            -UseBasicParsing -MaximumRedirection 0 -SkipHttpErrorCheck
        $newState = Get-EntraConfigBlob -Html $reloadResp.Content
        if ($newState) { return @{ State = $newState; LastResponse = $reloadResp } }
        return @{ State = $null; LastResponse = $reloadResp }
    }
    # Fallback · no SSO reload available · return state pulled from initial SessionInfo
    $fallback = [pscustomobject]@{
        pgid          = ''
        sCtx          = (Get-EntraField -Object $SessionInfo -Name 'sCtx')
        sFT           = (Get-EntraField -Object $SessionInfo -Name 'sFT')
        canary        = (Get-EntraField -Object $SessionInfo -Name 'canary')
        correlationId = (Get-EntraField -Object $SessionInfo -Name 'correlationId' -Default $CorrelationId)
    }
    @{ State = $fallback; LastResponse = $loginResp }
}
#endregion

#region Entra chain stages (private)
function Complete-TotpMfa {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [Parameter(Mandatory)][pscustomobject]$AuthState,
        [Parameter(Mandatory)][string]$TotpBase32,
        [Parameter(Mandatory)][guid]$CorrelationId
    )
    $proofs = @()
    if (Test-EntraField -Object $AuthState -Name 'arrUserProofs') { $proofs = @($AuthState.arrUserProofs) }
    $totpProof = $proofs | Where-Object { $_.authMethodId -eq 'PhoneAppOTP' } | Select-Object -First 1
    if (-not $totpProof) {
        throw "No PhoneAppOTP MFA method enabled for this UPN. Available: $(($proofs | ForEach-Object authMethodId) -join ', ')"
    }
    # BeginAuth — JSON body, pre-encoded to bypass any future serialization drift.
    $beginBody = @{
        AuthMethodId = 'PhoneAppOTP'; Method = 'BeginAuth'
        ctx = Get-EntraField -Object $AuthState -Name 'sCtx'
        flowToken = Get-EntraField -Object $AuthState -Name 'sFT'
    } | ConvertTo-Json -Compress
    $begin = Invoke-XdrAuthHttp -Uri 'https://login.microsoftonline.com/common/SAS/BeginAuth' `
        -Method POST -Body $beginBody -ContentType 'application/json' -Session $Session
    $beginObj = try { $begin.Content | ConvertFrom-Json } catch { $null }
    if (-not (Get-EntraField -Object $beginObj -Name 'Success' -Default $false)) {
        throw "SAS/BeginAuth Success=false: $($begin.Content.Substring(0,[math]::Min(200,$begin.Content.Length)))"
    }
    # EndAuth — retry on duplicate-code by waiting to next 30 s window
    $endObj = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if ($attempt -gt 1) {
            $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $waitTo = [math]::Floor($now / 30) * 30 + 31
            Start-Sleep -Seconds ([math]::Max(1, $waitTo - $now))
        }
        $code = Get-XdrTotpCode -Base32Secret $TotpBase32
        $endBody = @{
            AuthMethodId='PhoneAppOTP'; Method='EndAuth'
            SessionId = Get-EntraField -Object $beginObj -Name 'SessionId'
            FlowToken = Get-EntraField -Object $beginObj -Name 'FlowToken'
            Ctx = Get-EntraField -Object $beginObj -Name 'Ctx'
            AdditionalAuthData = $code; PollCount = $attempt
        } | ConvertTo-Json -Compress
        $end = Invoke-XdrAuthHttp -Uri 'https://login.microsoftonline.com/common/SAS/EndAuth' `
            -Method POST -Body $endBody -ContentType 'application/json' -Session $Session
        $endObj = try { $end.Content | ConvertFrom-Json } catch { $null }
        if (Test-MfaEndAuthSuccess -EndAuth $endObj) { break }
        $detail = (Get-EntraField -Object $endObj -Name 'Message') ?? (Get-EntraField -Object $endObj -Name 'ResultValue')
        if ($detail -match 'DuplicateCodeEntered' -and $attempt -lt 3) { continue }
        throw "TOTP rejected on attempt ${attempt}: $detail. Check TOTP seed + system clock skew."
    }
    # ProcessAuth — form-urlencoded (JSON content-type would return AADSTS9000410)
    $processBody = @{
        type = 22
        FlowToken = Get-EntraField -Object $endObj -Name 'FlowToken'
        request = Get-EntraField -Object $endObj -Name 'Ctx'
        ctx = Get-EntraField -Object $endObj -Name 'Ctx'
    }
    $processResp = Invoke-WebRequest -Uri 'https://login.microsoftonline.com/common/SAS/ProcessAuth' `
        -WebSession $Session -Method Post -Body $processBody `
        -ContentType 'application/x-www-form-urlencoded' `
        -UseBasicParsing -MaximumRedirection 0 -SkipHttpErrorCheck
    if ($processResp.StatusCode -ge 400) {
        if ($processResp.Content -match 'AADSTS(\d+)[:\s]*([^"\\]+)') {
            throw "ProcessAuth failed: AADSTS$($Matches[1]) - $($Matches[2].Trim())"
        }
        throw "ProcessAuth HTTP $($processResp.StatusCode): $($processResp.Content.Substring(0,[math]::Min(200,$processResp.Content.Length)))"
    }
    $newState = Get-EntraConfigBlob -Html $processResp.Content
    if (-not $newState) {
        return @{ State = $AuthState; LastResponse = $processResp }
    }
    return @{ State = $newState; LastResponse = $processResp }
}

function Complete-CredentialsFlow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [Parameter(Mandatory)][pscustomobject]$SessionInfo,
        [Parameter(Mandatory)][string]$UrlPost,
        [Parameter(Mandatory)][hashtable]$Credential,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][guid]$CorrelationId
    )
    $upn = $Credential.upn; $password = $Credential.password; $totp = $Credential.totpBase32
    if (-not $password) { throw "CredentialsTotp requires 'password' on Credential hashtable" }
    if (-not $totp) { throw "CredentialsTotp requires 'totpBase32' on Credential hashtable" }
    try {
        $credBody = @{
            login = $upn; passwd = $password; type = 11; ps = 2
            client_id = $ClientId
            flowToken = Get-EntraField -Object $SessionInfo -Name 'sFT'
            ctx = Get-EntraField -Object $SessionInfo -Name 'sCtx'
            canary = Get-EntraField -Object $SessionInfo -Name 'canary'
            hpgrequestid = Get-EntraField -Object $SessionInfo -Name 'correlationId' -Default $CorrelationId
        }
        $cred = Invoke-WebRequest -Uri $UrlPost -WebSession $Session -Method Post -Body $credBody `
            -UseBasicParsing -MaximumRedirection 0 -SkipHttpErrorCheck
        $authState = Get-EntraConfigBlob -Html $cred.Content
        if (-not $authState) {
            throw "Password POST returned no parseable `$Config. Tenant may use federated IdP."
        }
        $errCode = Get-EntraField -Object $authState -Name 'sErrorCode'
        if ($errCode) {
            $errTxt = Get-EntraField -Object $authState -Name 'sErrTxt' -Default ''
            throw "Authentication failed for UPN='$upn' (AADSTS$errCode): $(Get-EntraErrorMessage -Code $errCode -DefaultText $errTxt)"
        }
        $pgid = Get-EntraField -Object $authState -Name 'pgid' -Default ''
        if ($pgid -eq 'ConvergedTFA') {
            return Complete-TotpMfa -Session $Session -AuthState $authState -TotpBase32 $totp -CorrelationId $CorrelationId
        }
        return @{ State = $authState; LastResponse = $cred }
    } finally {
        Remove-Variable password,totp,credBody -ErrorAction SilentlyContinue
    }
}

function Resolve-EntraInterruptPage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [Parameter(Mandatory)][hashtable]$AuthResult
    )
    $state = $AuthResult.State; $lastResponse = $AuthResult.LastResponse
    if (-not $state) { return $AuthResult }
    $lastPgid = $null; $loops = 0
    while ($state -and $loops -lt 10) {
        $pgid = Get-EntraField -Object $state -Name 'pgid' -Default ''
        if (-not $pgid -or $pgid -eq $lastPgid) { break }
        $lastPgid = $pgid; $loops++
        $ctx = Get-EntraField -Object $state -Name 'sCtx'
        $flowTk = Get-EntraField -Object $state -Name 'sFT'
        $canary = Get-EntraField -Object $state -Name 'canary'
        $corrId = Get-EntraField -Object $state -Name 'correlationId' -Default ([guid]::NewGuid())
        $resp = $null; $handled = $false
        switch ($pgid) {
            'KmsiInterrupt' {
                $body = @{ LoginOptions = 1; type = 28; ctx = $ctx; hpgrequestid = $corrId; flowToken = $flowTk; canary = $canary; i19 = 4130 }
                $resp = Invoke-WebRequest -Uri 'https://login.microsoftonline.com/kmsi' `
                    -WebSession $Session -Method Post -Body $body `
                    -UseBasicParsing -MaximumRedirection 10 -SkipHttpErrorCheck
                $handled = $true
            }
            'CmsiInterrupt' {
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
                    throw "MFA registration required; cannot skip. Enrol the SA via mysignins.microsoft.com."
                }
            }
            default {
                Write-Warning "Resolve-EntraInterruptPage: UNKNOWN pgid '$pgid'. Auth chain stops here."
                break
            }
        }
        if (-not $handled) { break }
        Start-Sleep -Milliseconds 200
        $lastResponse = $resp
        $state = Get-EntraConfigBlob -Html $resp.Content
        if (-not $state) { break }
    }
    @{ State = $state; LastResponse = $lastResponse }
}

function Submit-EntraFormPost {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [Parameter(Mandatory)][string]$PortalHost,
        $LastResponse
    )
    if ($LastResponse -and $LastResponse.Content) {
        $formAction = $null
        $tagMatch = [regex]::Match($LastResponse.Content, '<form\b[^>]*>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($tagMatch.Success) {
            $actionMatch = [regex]::Match($tagMatch.Value, 'action\s*=\s*[''"]([^''"]+)[''"]', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($actionMatch.Success) { $formAction = $actionMatch.Groups[1].Value }
        }
        if (-not $formAction) {
            $blob = Get-EntraConfigBlob -Html $LastResponse.Content
            if ($blob) {
                foreach ($fld in @('sPostBackUrl','urlPost','urlGoBack','urlResume')) {
                    $v = Get-EntraField -Object $blob -Name $fld
                    if ($v -and $v -match [regex]::Escape($PortalHost)) { $formAction = $v; break }
                }
            }
        }
        if ($formAction -and ($LastResponse.PSObject.Properties.Name -contains 'InputFields') -and $LastResponse.InputFields) {
            $body = @{}
            foreach ($field in $LastResponse.InputFields) {
                $names = @($field.PSObject.Properties.Name)
                $fName = if ($names -contains 'Name') { $field.Name } elseif ($names -contains 'name') { $field.name } else { $null }
                $fVal  = if ($names -contains 'Value') { $field.Value } elseif ($names -contains 'value') { $field.value } else { $null }
                if ($fName) { $body[$fName] = $fVal }
            }
            if ($body.Count -gt 0) {
                try {
                    Invoke-WebRequest -Uri $formAction -WebSession $Session -Method Post -Body $body `
                        -UseBasicParsing -MaximumRedirection 10 -SkipHttpErrorCheck | Out-Null
                } catch { Write-Verbose "Submit-EntraFormPost: redirect chain raised $($_.Exception.Message) (often benign)" }
            }
        }
    }
    try {
        Invoke-WebRequest -Uri "https://$PortalHost/" -WebSession $Session `
            -UseBasicParsing -MaximumRedirection 10 -SkipHttpErrorCheck | Out-Null
    } catch {}
}

function Get-EntraEstsAuth {
    <#
    .SYNOPSIS
        Multi-portal ESTS cookie auth chain · two entry-point strategies per AuthProfile.
    .DESCRIPTION
        AuthProfile=Cookie (Defender, Purview): enters at https://$PortalHost/.
        The portal redirects to login.microsoftonline.com with its own params.
        REVISIT-A1 proved this path works for Defender end-to-end.

        AuthProfile=Bearer (Entra/Intune/SecurityCopilot): enters at
        login.microsoftonline.com/<tenant>/oauth2/v2.0/authorize directly with
        response_type=code + redirect_uri (from PortalConfig). The form_post
        landing page contains <input name="code" value="..."/> for the bearer
        chain's auth_code extraction (Get-EntraBearerToken Stage 2).

        RedirectUri (required for Bearer) MUST be a value registered for
        ClientId. From PortalConfig:
          Entra (5 subs)   https://portal.azure.com/signin/index/
          Intune (2 subs)  https://intune.microsoft.com/signin/index/
          SecurityCopilot  https://securitycopilot.microsoft.com/signin/index/
    #>
    [CmdletBinding()][OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Credential,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$PortalHost,
        [string]$RedirectUri,
        [ValidateSet('Cookie','Bearer')][string]$AuthProfile = 'Cookie',
        # A-3b-2 · admin-portal v1 OAuth + PKCE (Decisions D-38/D-39 · Bugs 9/10/13)
        [ValidateSet('v1','v2')][string]$AuthVersion = 'v2',
        [string]$Resource,                                             # required when AuthVersion=v1 (URL or AppId)
        [string]$CodeChallenge,                                        # PKCE RFC 7636 · BASE64URL(SHA256(verifier))
        [string]$TenantId,
        [guid]$CorrelationId = [guid]::NewGuid(),
        # φ.AUTH.6b · MFA method dispatch · CredentialsTotp (default · D-24) or Passkey
        # (ECDSA-P256 WebAuthn · D-2026-05-18b · Passkey IN v0.1.0 NOT deferred · per
        # KV xdrlr-sa-auth-method secret · operators pick per SA)
        [ValidateSet('CredentialsTotp','Passkey')][string]$Method = 'CredentialsTotp'
    )
    $upn = $Credential.upn
    if (-not $upn) { throw "Credential must contain 'upn'" }
    if ($AuthProfile -eq 'Bearer' -and -not $RedirectUri) {
        throw "Get-EntraEstsAuth: -AuthProfile Bearer requires -RedirectUri (the value registered with ClientId)."
    }
    if ($AuthProfile -eq 'Bearer' -and $AuthVersion -eq 'v1' -and -not $Resource) {
        throw "Get-EntraEstsAuth: -AuthVersion v1 -AuthProfile Bearer requires -Resource (URL or AppId · admin-portal canonical · D-38)."
    }
    if ($Method -eq 'Passkey' -and -not (Test-EntraField -Object ([pscustomobject]$Credential) -Name 'passkey')) {
        throw "Get-EntraEstsAuth: -Method Passkey requires Credential.passkey (PSCustomObject with credentialId + privateKeyPem · loaded from KV xdrlr-sa-passkey-pem secret)."
    }
    $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
    $session.UserAgent = $script:UserAgent

    $entryUri = if ($AuthProfile -eq 'Cookie') {
        "https://$PortalHost/"
    } else {
        $effectiveTenantId = if ($TenantId) { $TenantId } else { 'organizations' }
        # A-3b-2 · v1 OAuth = /oauth2/authorize?resource=<URL>  (no scope)
        #         v2 OAuth = /oauth2/v2.0/authorize?scope=<...> (no resource)
        $authorizePath = if ($AuthVersion -eq 'v1') { 'oauth2/authorize' } else { 'oauth2/v2.0/authorize' }
        $url = "https://login.microsoftonline.com/$effectiveTenantId/$authorizePath" +
            "?response_type=code" +
            "&client_id=$ClientId" +
            "&redirect_uri=$([uri]::EscapeDataString($RedirectUri))" +
            "&response_mode=form_post" +
            "&login_hint=$([uri]::EscapeDataString($upn))" +
            "&prompt=login"
        if ($AuthVersion -eq 'v1') {
            $url += "&resource=$([uri]::EscapeDataString($Resource))"
        } else {
            $url += "&scope=$([uri]::EscapeDataString('openid profile offline_access'))"
        }
        # A-3b-2 PKCE · SPA clients require · PublicClient also accepts (D-39)
        if ($CodeChallenge) {
            $url += "&code_challenge=$([uri]::EscapeDataString($CodeChallenge))" +
                    "&code_challenge_method=S256"
        }
        $url
    }
    $initial = Invoke-WebRequest -Uri $entryUri -WebSession $session -Method Get `
        -UseBasicParsing -MaximumRedirection 10 -ErrorAction Stop
    $sessionInfo = Get-EntraConfigBlob -Html $initial.Content
    if (-not $sessionInfo) {
        throw "Could not parse Entra `$Config blob from authorize response. Tenant may redirect to a federated IdP."
    }
    foreach ($r in 'canary','urlPost','sCtx','sFT') {
        if (-not (Test-EntraField -Object $sessionInfo -Name $r)) {
            throw "Entra `$Config missing required field: $r. Cannot proceed with auth chain."
        }
    }
    $urlPost = $sessionInfo.urlPost
    if ($urlPost -notmatch '^https?://') {
        $urlPost = [uri]::new([uri]'https://login.microsoftonline.com/', $urlPost).AbsoluteUri
    }
    # φ.AUTH.6b · Dispatch by Method · CredentialsTotp (default) or Passkey (WebAuthn ECDSA-P256)
    if ($Method -eq 'Passkey') {
        _Emit-AuthTelemetry -Level Information -EventName 'Auth.PasskeyFlow.Dispatched' `
            -Message "Get-EntraEstsAuth dispatching to Passkey flow (zero TOTP burn)" `
            -Properties @{ Upn=$upn; PortalHost=$PortalHost; AuthProfile=$AuthProfile }
        $authResult = Complete-XdrPasskeyFlow -Session $session -SessionInfo $sessionInfo `
            -Credential $Credential -CorrelationId $CorrelationId
    } else {
        $authResult = Complete-CredentialsFlow -Session $session -SessionInfo $sessionInfo `
            -UrlPost $urlPost -Credential $Credential -ClientId $ClientId -CorrelationId $CorrelationId
    }
    $authResult = Resolve-EntraInterruptPage -Session $session -AuthResult $authResult

    # Capture FinalHtml + TenantIdCandidates + Upn BEFORE Submit-EntraFormPost.
    # The form_post POST consumes the auth_code (single-use); bearer-chain callers
    # (Get-EntraBearerToken, A-2) need the FinalHtml to extract auth_code before
    # the submit runs. Cookie-chain callers (Connect-DefenderPortal /
    # Connect-PurviewPortal) get the post-submit Session populated with sccauth
    # via the existing side-effect path — they ignore the new fields.
    $finalHtml = ''
    if ($authResult.LastResponse -and $authResult.LastResponse.Content) {
        $finalHtml = [string]$authResult.LastResponse.Content
    }
    $tenantIdCandidates = @()
    if ($TenantId) { $tenantIdCandidates += $TenantId }
    if ($authResult.State) {
        foreach ($f in 'tenantId','sTenantId','tenant') {
            $v = Get-EntraField -Object $authResult.State -Name $f
            if ($v -and ($tenantIdCandidates -notcontains $v)) { $tenantIdCandidates += [string]$v }
        }
    }
    if ($finalHtml -match 'tenantId["'']?\s*[:=]\s*["'']([0-9a-fA-F-]{36})["'']') {
        $cand = $Matches[1]
        if ($tenantIdCandidates -notcontains $cand) { $tenantIdCandidates += $cand }
    }

    Submit-EntraFormPost -Session $session -PortalHost $PortalHost -LastResponse $authResult.LastResponse

    @{
        Session             = $session
        State               = $authResult.State
        LastResponse        = $authResult.LastResponse
        AcquiredUtc         = [datetime]::UtcNow
        ClientId            = $ClientId
        PortalHost          = $PortalHost
        # NEW (bearer-chain support · captured BEFORE form_post submit)
        FinalHtml           = $finalHtml
        TenantIdCandidates  = $tenantIdCandidates
        Upn                 = $upn
    }
}
#endregion

#region Connect-DefenderPortal — public orchestrator
function Connect-DefenderPortal {
    [CmdletBinding()][OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Credentials,
        [string]$PortalHost = 'security.microsoft.com',
        [string]$TenantId,
        [switch]$Force,
        [int]$RefreshBeforeMinutes = 5
    )
    # Normalize credentials shape: accept either pscustomobject or hashtable.
    $upn = $Credentials.Upn ?? $Credentials.upn
    if (-not $upn) { throw "Credentials must include 'upn'" }
    $cacheKey = "${upn}::${PortalHost}"

    # Π11 ITER2-R2 · Passkey dispatch fix (was: hard-throw blocking ARM-exposed Passkey feature)
    # Get-XdrAuthFromKeyVault reads xdrlr-sa-auth-method KV secret + populates $Credentials.Passkey
    # (PSCustomObject with credentialId + privateKeyPem + rpId) when ARM operator picked Passkey.
    # We pass -Method $authMethod down to Get-EntraEstsAuth which dispatches Passkey properly
    # (Get-EntraEstsAuth L1490 [ValidateSet('CredentialsTotp','Passkey')] $Method param).
    $authMethod = $Credentials.AuthMethod ?? $Credentials.authMethod ?? 'CredentialsTotp'
    if ($authMethod -eq 'Passkey' -and -not ($Credentials.PSObject.Properties['Passkey'] -and $Credentials.Passkey)) {
        throw "Connect-DefenderPortal: AuthMethod='Passkey' requires Credentials.Passkey (PSCustomObject with credentialId + privateKeyPem · loaded from KV xdrlr-sa-passkey-pem secret · operator should pwsh tools/Rotate-Secrets.ps1 to populate)."
    }

    # CACHE DECISION — in-memory FIRST (same-runspace fast path · driven by Get-XdrCookieExpiry · D-25)
    $prevEntry = $null
    if ($script:SessionCache.ContainsKey($cacheKey)) {
        $prevEntry = $script:SessionCache[$cacheKey]
        if (-not $Force.IsPresent) {
            $expiry = Get-XdrCookieExpiry -Session $prevEntry.Session
            if ($expiry -and ($expiry -gt (Get-Date).ToUniversalTime().AddMinutes($RefreshBeforeMinutes))) {
                Write-Verbose "Connect-DefenderPortal: in-memory cache hit for $cacheKey (cookie expiry $expiry)"
                return [pscustomobject]$prevEntry
            }
            Write-Verbose "Connect-DefenderPortal: evicting $cacheKey (expiry=$expiry within $RefreshBeforeMinutes min OR null)"
        } else {
            Write-Verbose "Connect-DefenderPortal: -Force · attempting KMSI SSO re-mint before TOTP chain"
        }
        $script:SessionCache.Remove($cacheKey)
    } else {
        # φ.AUTH.0 · Cross-runspace file cache check (B-19 fix · ONLY when in-memory is empty)
        # FA Durable activities spawn fresh runspaces · in-memory cache empty · file cache
        # lets us reuse session across runspaces / cold-starts · ZERO TOTP.
        # ORDER: in-memory takes precedence in same runspace · file cache is secondary fallback.
        if (-not $Force.IsPresent) {
            $fileSession = Read-XdrSessionFromCache -Upn $upn -PortalHost $PortalHost
            if ($fileSession) {
                $entry = [ordered]@{
                    Session     = $fileSession.Session
                    Upn         = $upn
                    PortalHost  = $PortalHost
                    TenantId    = if ($fileSession.TenantId) { $fileSession.TenantId } else { $TenantId }
                    AcquiredUtc = $fileSession.AcquiredUtc
                    RefreshType = 'file-cache-restored'
                }
                $script:SessionCache[$cacheKey] = $entry
                Write-Verbose "Connect-DefenderPortal: file cache hit · cross-runspace reuse (NO TOTP)"
                return [pscustomobject]$entry
            }
        }
    }

    # KMSI SSO RE-MINT (D-25 proper · operator-corrected 2026-05-18) ───────────
    # If prior session had valid ESTSAUTHPERSISTENT (90d KMSI) cookie · use it to
    # SSO-refresh sccauth WITHOUT TOTP. Falls through to full chain only when KMSI
    # also expired/revoked. Avoids burning TOTP on every reauth.
    if ($prevEntry -and $prevEntry.Session) {
        $refreshedSession = Invoke-XdrKmsiSsoRefresh -PrevSession $prevEntry.Session -PortalHost $PortalHost
        if ($refreshedSession) {
            $entry = [ordered]@{
                Session     = $refreshedSession
                Upn         = $upn
                PortalHost  = $PortalHost
                TenantId    = $TenantId
                AcquiredUtc = [datetime]::UtcNow
                RefreshType = 'kmsi-sso'   # NEW · indicates ZERO TOTP burn
            }
            $script:SessionCache[$cacheKey] = $entry
            Write-Verbose "Connect-DefenderPortal: KMSI SSO re-mint succeeded (no TOTP) for $cacheKey"
            # φ.AUTH.0 · Persist to cross-runspace cache for next FA runspace reuse
            Save-XdrSessionToCache -Session $refreshedSession -Upn $upn -PortalHost $PortalHost -TenantId $TenantId -RefreshType 'kmsi-sso'
            return [pscustomobject]$entry
        }
    }

    # Fresh chain (TOTP burn · KMSI also expired or absent · AuthMethod gate checked above)
    # φ.AUTH.2 · Sliding-window circuit-breaker gate · prevents TOTP cascade-retry
    if (Test-XdrAuthCircuitOpen -Key $cacheKey) {
        throw "Auth circuit OPEN for $cacheKey · refusing TOTP burn (>=2 failures in last 5min · sliding window decays · retry later)"
    }
    $credHash = @{
        upn        = $upn
        password   = $Credentials.Password   ?? $Credentials.password
        totpBase32 = $Credentials.TotpSecret ?? $Credentials.totpSecret ?? $Credentials.totpBase32
    }
    # Π11 ITER2-R2 · Passkey credential payload (when AuthMethod=Passkey · Get-EntraEstsAuth L1500 asserts)
    if ($authMethod -eq 'Passkey') {
        $credHash.passkey = $Credentials.Passkey
    }
    # Cookie portal: portal-root entry (Defender redirects to ESTS naturally).
    _Emit-AuthTelemetry -Level Warning -EventName 'Auth.TotpBurn' `
        -Message "Auth chain burning · cold cache for $cacheKey · KMSI unavailable or expired · method=$authMethod" `
        -Properties @{ Upn=$upn; PortalHost=$PortalHost; TenantId=$TenantId; AuthMethod=$authMethod }
    try {
        $entra = Get-EntraEstsAuth -Credential $credHash -ClientId $script:DefenderClientId `
            -PortalHost $PortalHost -AuthProfile Cookie -TenantId $TenantId -Method $authMethod
    } catch {
        Add-XdrAuthCircuitFailure -Key $cacheKey -Reason "Defender:$($_.Exception.GetType().Name)"
        throw
    }

    $entry = [ordered]@{
        Session     = $entra.Session
        Upn         = $upn
        PortalHost  = $PortalHost
        TenantId    = $TenantId
        AcquiredUtc = $entra.AcquiredUtc
        RefreshType = 'full-totp-chain'   # NEW · indicates TOTP was burned
    }
    $script:SessionCache[$cacheKey] = $entry
    # φ.AUTH.2 · Success · clear any prior failure window for this key
    Reset-XdrAuthCircuit -Key $cacheKey
    # φ.AUTH.0 · Persist to cross-runspace cache for next FA runspace reuse · zero TOTP next time
    Save-XdrSessionToCache -Session $entra.Session -Upn $upn -PortalHost $PortalHost -TenantId $TenantId -RefreshType 'full-totp-chain'
    [pscustomobject]$entry
}
#endregion

#region Connect-PurviewPortal — cookie sibling of Defender (compliance.microsoft.com)
function Connect-PurviewPortal {
    [CmdletBinding()][OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Credentials,
        [string]$PortalHost = 'compliance.microsoft.com',
        [string]$TenantId,
        [switch]$Force,
        [int]$RefreshBeforeMinutes = 5
    )
    $upn = $Credentials.Upn ?? $Credentials.upn
    if (-not $upn) { throw "Credentials must include 'upn'" }
    $cacheKey = "${upn}::${PortalHost}"

    # Π11.C5 · In-memory-FIRST ordering · matches Connect-DefenderPortal pattern (L1540-1554)
    # In-memory cache is fastest · file cache is fallback for cross-runspace · ordering correction.
    $prevEntry = $null
    if ($script:SessionCache.ContainsKey($cacheKey)) {
        $prevEntry = $script:SessionCache[$cacheKey]
        if (-not $Force.IsPresent) {
            $expiry = Get-XdrCookieExpiry -Session $prevEntry.Session
            if ($expiry -and ($expiry -gt (Get-Date).ToUniversalTime().AddMinutes($RefreshBeforeMinutes))) {
                Write-Verbose "Connect-PurviewPortal: in-memory cache hit for $cacheKey (cookie expiry $expiry)"
                return [pscustomobject]$prevEntry
            }
            Write-Verbose "Connect-PurviewPortal: evicting $cacheKey (expiry=$expiry within $RefreshBeforeMinutes min OR null)"
        }
        $script:SessionCache.Remove($cacheKey)
    }

    # φ.AUTH.0 · Cross-runspace file cache check (B-19 fix · AFTER in-memory miss)
    if (-not $Force.IsPresent) {
        $fileSession = Read-XdrSessionFromCache -Upn $upn -PortalHost $PortalHost
        if ($fileSession) {
            $entry = [ordered]@{
                Session     = $fileSession.Session
                Upn         = $upn
                PortalHost  = $PortalHost
                Portal      = 'Purview'
                TenantId    = if ($fileSession.TenantId) { $fileSession.TenantId } else { $TenantId }
                AcquiredUtc = $fileSession.AcquiredUtc
                RefreshType = 'file-cache-restored'
            }
            $script:SessionCache[$cacheKey] = $entry
            return [pscustomobject]$entry
        }
    }

    # KMSI SSO RE-MINT (D-25 · same pattern as Connect-DefenderPortal · operator-corrected 2026-05-18)
    if ($prevEntry -and $prevEntry.Session) {
        $refreshedSession = Invoke-XdrKmsiSsoRefresh -PrevSession $prevEntry.Session -PortalHost $PortalHost
        if ($refreshedSession) {
            $entry = [ordered]@{
                Session     = $refreshedSession
                Upn         = $upn
                PortalHost  = $PortalHost
                Portal      = 'Purview'
                TenantId    = $TenantId
                AcquiredUtc = [datetime]::UtcNow
                RefreshType = 'kmsi-sso'
            }
            $script:SessionCache[$cacheKey] = $entry
            # φ.AUTH.0 · Persist to cross-runspace cache
            Save-XdrSessionToCache -Session $refreshedSession -Upn $upn -PortalHost $PortalHost -TenantId $TenantId -RefreshType 'kmsi-sso'
            return [pscustomobject]$entry
        }
    }

    # φ.AUTH.2 · Sliding-window circuit-breaker gate · prevents TOTP cascade-retry
    if (Test-XdrAuthCircuitOpen -Key $cacheKey) {
        throw "Auth circuit OPEN for $cacheKey · refusing TOTP burn (>=2 failures in last 5min · sliding window decays · retry later)"
    }
    $cfg = Get-XdrPortalConfig -Portal Purview
    # Π11 ITER2-R2 · Passkey dispatch · same pattern as Connect-DefenderPortal · honour KV xdrlr-sa-auth-method
    $authMethod = $Credentials.AuthMethod ?? $Credentials.authMethod ?? 'CredentialsTotp'
    if ($authMethod -eq 'Passkey' -and -not ($Credentials.PSObject.Properties['Passkey'] -and $Credentials.Passkey)) {
        throw "Connect-PurviewPortal: AuthMethod='Passkey' requires Credentials.Passkey (PSCustomObject with credentialId + privateKeyPem · loaded from KV xdrlr-sa-passkey-pem secret)."
    }
    $credHash = @{
        upn        = $upn
        password   = $Credentials.Password   ?? $Credentials.password
        totpBase32 = $Credentials.TotpSecret ?? $Credentials.totpSecret ?? $Credentials.totpBase32
    }
    if ($authMethod -eq 'Passkey') {
        $credHash.passkey = $Credentials.Passkey
    }
    _Emit-AuthTelemetry -Level Warning -EventName 'Auth.TotpBurn' `
        -Message "Auth chain burning · Purview cold cache for $cacheKey · method=$authMethod" `
        -Properties @{ Upn=$upn; PortalHost=$PortalHost; TenantId=$TenantId; AuthMethod=$authMethod }
    try {
        $entra = Get-EntraEstsAuth -Credential $credHash -ClientId $cfg.ClientId `
            -PortalHost $PortalHost -AuthProfile Cookie -TenantId $TenantId -Method $authMethod
    } catch {
        Add-XdrAuthCircuitFailure -Key $cacheKey -Reason "Purview:$($_.Exception.GetType().Name)"
        throw
    }

    $entry = [ordered]@{
        Session     = $entra.Session
        Upn         = $upn
        PortalHost  = $PortalHost
        Portal      = 'Purview'
        TenantId    = $TenantId
        AcquiredUtc = $entra.AcquiredUtc
        RefreshType = 'full-totp-chain'
    }
    $script:SessionCache[$cacheKey] = $entry
    # φ.AUTH.2 · Success · clear any prior failure window for this key
    Reset-XdrAuthCircuit -Key $cacheKey
    # φ.AUTH.0 · Persist to cross-runspace cache
    Save-XdrSessionToCache -Session $entra.Session -Upn $upn -PortalHost $PortalHost -TenantId $TenantId -RefreshType 'full-totp-chain'
    [pscustomobject]$entry
}
#endregion

#region Bearer cache helper · shared by Entra/Intune/SecurityCopilot Connect-*
function Get-XdrBearerSession {
    <#
    .SYNOPSIS
        Internal · cache-aware bearer session orchestrator. NOT exported.
    .DESCRIPTION
        Cache hit (within RefreshBeforeMinutes of expiry): return cached token.
        Near-expiry with RefreshToken: try Refresh-XdrBearerToken · fall back on failure.
        Miss: full Get-EntraBearerToken chain using PortalConfig (AuthVersion/Resource/ClientType).
    #>
    [CmdletBinding()][OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Credentials,
        [Parameter(Mandatory)][string]$Portal,
        [string]$SubPortal,
        [string]$TenantId,
        [switch]$Force,
        [int]$RefreshBeforeMinutes = 5
    )
    $upn = $Credentials.Upn ?? $Credentials.upn
    if (-not $upn) { throw "Credentials must include 'upn'" }
    $cacheKey = if ($SubPortal) { "${upn}::${Portal}::${SubPortal}" } else { "${upn}::${Portal}::" }
    $cfg = if ($SubPortal) { Get-XdrPortalConfig -Portal $Portal -SubPortal $SubPortal } else { Get-XdrPortalConfig -Portal $Portal }

    # Cache hit
    if (-not $Force.IsPresent -and $script:TokenCache.ContainsKey($cacheKey)) {
        $cached = $script:TokenCache[$cacheKey]
        $expiry = $cached.ExpiresUtc
        if ($expiry -and ($expiry -gt (Get-Date).ToUniversalTime().AddMinutes($RefreshBeforeMinutes))) {
            return [pscustomobject]$cached
        }
        # Near-expiry: try refresh-token fast path
        if ($cached.RefreshToken) {
            try {
                $refreshed = Refresh-XdrBearerToken -RefreshToken $cached.RefreshToken `
                    -ClientId $cfg.ClientId -Scope $cfg.Scope -TenantId $TenantId
                $newEntry = [ordered]@{
                    AccessToken  = $refreshed.AccessToken
                    RefreshToken = $refreshed.RefreshToken
                    TokenType    = $refreshed.TokenType
                    ExpiresUtc   = $refreshed.ExpiresUtc
                    Scope        = $refreshed.Scope
                    Audience     = $refreshed.Audience
                    Upn          = $upn
                    Portal       = $Portal
                    SubPortal    = $SubPortal
                    TenantId     = $refreshed.TenantId
                    AcquiredUtc  = [datetime]::UtcNow
                    Source       = 'refresh-token'
                }
                $script:TokenCache[$cacheKey] = $newEntry
                return [pscustomobject]$newEntry
            } catch {
                Write-Verbose "Get-XdrBearerSession: refresh-token failed · falling back to full cookie chain ($($_.Exception.Message))"
            }
        }
        $script:TokenCache.Remove($cacheKey)
    }

    # Full bearer chain (cookie + auth_code + token exchange)
    $credHash = @{
        upn        = $upn
        password   = $Credentials.Password   ?? $Credentials.password
        totpBase32 = $Credentials.TotpSecret ?? $Credentials.totpSecret ?? $Credentials.totpBase32
    }
    $bearer = Get-EntraBearerToken -Credential $credHash -ClientId $cfg.ClientId `
        -Scope $cfg.Scope -RedirectUri $cfg.RedirectUri `
        -AuthVersion $cfg.AuthVersion -Resource $cfg.Resource -ClientType $cfg.ClientType `
        -TenantId $TenantId

    $entry = [ordered]@{
        AccessToken  = $bearer.AccessToken
        RefreshToken = $bearer.RefreshToken
        TokenType    = $bearer.TokenType
        ExpiresUtc   = $bearer.ExpiresUtc
        Scope        = $bearer.Scope
        Audience     = $bearer.Audience
        Upn          = $upn
        Portal       = $Portal
        SubPortal    = $SubPortal
        TenantId     = $bearer.TenantId
        AcquiredUtc  = $bearer.AcquiredUtc
        Source       = 'full-chain'
    }
    $script:TokenCache[$cacheKey] = $entry
    [pscustomobject]$entry
}
#endregion

#region Connect-EntraPortal — bearer · 5 sub-portals (IAM/PIM/IDGov/IGA/B2C)
function Connect-EntraPortal {
    [CmdletBinding()][OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Credentials,
        [ValidateSet('IAM','PIM','IDGov','IGA','B2C')][string]$SubPortal = 'IAM',
        [string]$TenantId,
        [switch]$Force,
        [int]$RefreshBeforeMinutes = 5
    )
    Get-XdrBearerSession -Credentials $Credentials -Portal 'Entra' -SubPortal $SubPortal `
        -TenantId $TenantId -Force:$Force -RefreshBeforeMinutes $RefreshBeforeMinutes
}
#endregion

#region Connect-IntunePortal — bearer · 2 sub-portals (Portal/Autopatch) · x-ms-* headers
function Connect-IntunePortal {
    [CmdletBinding()][OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Credentials,
        [ValidateSet('Portal','Autopatch')][string]$SubPortal = 'Portal',
        [string]$TenantId,
        [switch]$Force,
        [int]$RefreshBeforeMinutes = 5
    )
    Get-XdrBearerSession -Credentials $Credentials -Portal 'Intune' -SubPortal $SubPortal `
        -TenantId $TenantId -Force:$Force -RefreshBeforeMinutes $RefreshBeforeMinutes
}
#endregion

#region Connect-SecurityCopilotPortal — bearer · multi-host (UiHost/Host split)
function Connect-SecurityCopilotPortal {
    [CmdletBinding()][OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Credentials,
        [string]$TenantId,
        [switch]$Force,
        [int]$RefreshBeforeMinutes = 5
    )
    Get-XdrBearerSession -Credentials $Credentials -Portal 'SecurityCopilot' -SubPortal '' `
        -TenantId $TenantId -Force:$Force -RefreshBeforeMinutes $RefreshBeforeMinutes
}
#endregion

function Clear-XdrCookieCache {
    [CmdletBinding()] param()
    $script:SessionCache = @{}
    $script:TokenCache   = @{}
}

# Module-scope bearer cache (sibling of $script:SessionCache for cookie portals).
# Keyed '<upn>::<portal>::<sub-portal>' → @{ AccessToken; RefreshToken; ExpiresUtc; ... }
$script:TokenCache = @{}

# -----------------------------------------------------------------------------
# Get-XdrBearerTokenExpiry — JWT exp-claim decoder for bearer-portal cache eviction
#
# Sibling primitive to Get-XdrCookieExpiry (cookie chain). For bearer portals
# (Entra/Intune/SecurityCopilot) the cached artefact is a JWT, not a cookie jar;
# this reads the `exp` claim from the JWT payload to compute ExpiresUtc.
#
# JWT structure: base64url-header.base64url-payload.base64url-signature
# Payload is JSON with `exp` (Unix epoch seconds) and `aud` (audience).
#
# Fallback to DefaultTtlMinutes when:
#   - Token is empty
#   - Token isn't 3 segments
#   - Payload isn't base64url-decodable or isn't JSON
#   - Payload lacks `exp` claim
# -----------------------------------------------------------------------------
function Get-XdrBearerTokenExpiry {
    [CmdletBinding()][OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$BearerToken,
        [int]$DefaultTtlMinutes = 50,
        [datetime]$AcquiredUtc = [datetime]::UtcNow
    )

    $token = ($BearerToken -replace '^Bearer\s+', '').Trim()
    if ([string]::IsNullOrWhiteSpace($token)) {
        return [pscustomobject]@{
            ExpiresUtc           = $AcquiredUtc.AddMinutes($DefaultTtlMinutes)
            TokenPresent         = $false
            EarliestExpirySource = 'default-ttl'
            Audience             = ''
        }
    }
    $segments = $token.Split('.')
    if ($segments.Count -ne 3) {
        return [pscustomobject]@{
            ExpiresUtc           = $AcquiredUtc.AddMinutes($DefaultTtlMinutes)
            TokenPresent         = $true
            EarliestExpirySource = 'malformed'
            Audience             = ''
        }
    }
    $payloadB64 = $segments[1]
    $rem = $payloadB64.Length % 4
    if ($rem -gt 0) { $payloadB64 = $payloadB64 + ('=' * (4 - $rem)) }
    $payloadB64 = $payloadB64.Replace('-', '+').Replace('_', '/')
    try {
        $payloadBytes = [Convert]::FromBase64String($payloadB64)
        $payloadJson  = [System.Text.Encoding]::UTF8.GetString($payloadBytes)
        $payload      = $payloadJson | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return [pscustomobject]@{
            ExpiresUtc           = $AcquiredUtc.AddMinutes($DefaultTtlMinutes)
            TokenPresent         = $true
            EarliestExpirySource = 'malformed'
            Audience             = ''
        }
    }
    $audience = if ($payload.PSObject.Properties['aud']) { [string]$payload.aud } else { '' }
    if (-not $payload.PSObject.Properties['exp']) {
        return [pscustomobject]@{
            ExpiresUtc           = $AcquiredUtc.AddMinutes($DefaultTtlMinutes)
            TokenPresent         = $true
            EarliestExpirySource = 'default-ttl'
            Audience             = $audience
        }
    }
    $expSeconds = [int64]$payload.exp
    $epoch      = [datetime]::new(1970, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
    [pscustomobject]@{
        ExpiresUtc           = $epoch.AddSeconds($expSeconds)
        TokenPresent         = $true
        EarliestExpirySource = 'jwt-exp'
        Audience             = $audience
    }
}

# -----------------------------------------------------------------------------
# Get-EntraBearerToken — L1 bearer chain (wraps cookie chain + auth_code → JWT)
#
# Used by bearer-auth portals (Entra IAM/PIM/IDGov/IGA/B2C, Intune Portal+
# Autopatch, SecurityCopilot). Reuses Get-EntraEstsAuth as Stage 1 — one ESTS
# session covers all bearer portals from the same operator.
#
# Stages:
#   1. ESTS cookie chain (Get-EntraEstsAuth) · FinalHtml captured (A-1)
#   2. Extract auth_code from FinalHtml (form_post response · single-use code)
#   3. POST /oauth2/v2.0/token with auth_code → JWT + refresh_token
#   4. Normalised token shape returned
# -----------------------------------------------------------------------------
function Get-EntraBearerToken {
    [CmdletBinding()][OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable]$Credential,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$Scope,                          # v2: 'URL/.default ...' · v1: 'user_impersonation'
        [Parameter(Mandatory)][string]$RedirectUri,
        # A-3b-2 · admin-portal v1 OAuth + PKCE + Origin (D-38/D-39 · Bugs 8/9/10/13/14/15)
        [ValidateSet('v1','v2')][string]$AuthVersion = 'v2',
        [ValidateSet('SPA','PublicClient')][string]$ClientType = 'PublicClient',
        [string]$Resource,                                              # required when AuthVersion=v1
        [string]$TenantId,
        [guid]$CorrelationId = [guid]::NewGuid()
    )
    if ($AuthVersion -eq 'v1' -and -not $Resource) {
        throw "Get-EntraBearerToken: -AuthVersion v1 requires -Resource (URL or AppId · D-38)."
    }

    # A-3b-2 PKCE (RFC 7636) — code_verifier (32 random bytes → base64url) +
    # code_challenge (BASE64URL(SHA256(verifier))). SPA REQUIRES per D-39 (Bug 10/11).
    # PublicClient also accepts · we generate for all bearer flows for consistency.
    $verifierBytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($verifierBytes)
    $codeVerifier  = [Convert]::ToBase64String($verifierBytes).TrimEnd('=').Replace('+','-').Replace('/','_')
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $challengeBytes = $sha256.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($codeVerifier))
    } finally { $sha256.Dispose() }
    $codeChallenge = [Convert]::ToBase64String($challengeBytes).TrimEnd('=').Replace('+','-').Replace('/','_')

    # Stage 1: bearer chain entry — authorize URL with form_post response_mode +
    # PKCE code_challenge. Embeds redirect_uri so form_post HTML carries auth_code.
    $portalHost = ([uri]$RedirectUri).Host
    $ests = Get-EntraEstsAuth -Credential $Credential -ClientId $ClientId `
        -PortalHost $portalHost -RedirectUri $RedirectUri -AuthProfile Bearer `
        -AuthVersion $AuthVersion -Resource $Resource -CodeChallenge $codeChallenge `
        -TenantId $TenantId -CorrelationId $CorrelationId

    # Stage 2: extract auth_code from form_post HTML.
    $finalHtml = [string]$ests.FinalHtml
    $authCode  = ''
    if ($finalHtml -match 'name="code"\s+value="([^"]+)"') {
        $authCode = $Matches[1]
    } elseif ($finalHtml -match "name='code'\s+value='([^']+)'") {
        $authCode = $Matches[1]
    } elseif ($finalHtml -match 'name="id_token"\s+value="([^"]+)"') {
        throw "Get-EntraBearerToken: form_post returned id_token (implicit flow) not code (auth-code flow). Change scope to request code flow."
    } else {
        # Dump full FinalHtml + key Microsoft error/state markers so the operator
        # can inspect what Microsoft is actually complaining about.
        $errorMsg = ''
        if ($finalHtml -match '"sErrorCode"\s*:\s*"(\d+)"') { $errorMsg += "sErrorCode=$($Matches[1]) " }
        if ($finalHtml -match '"sErrTxt"\s*:\s*"([^"]+)"')  { $errorMsg += "sErrTxt='$($Matches[1])' " }
        if ($finalHtml -match '"pgid"\s*:\s*"([^"]+)"')      { $errorMsg += "pgid=$($Matches[1]) " }
        if ($finalHtml -match 'AADSTS(\d+):\s*([^"<\\]+)')   { $errorMsg += "AADSTS$($Matches[1])=$($Matches[2]) " }
        $debugDir = $env:XDRLR_PROBE_DEBUG_DIR
        if ($debugDir) {
            New-Item -ItemType Directory -Path $debugDir -Force -ErrorAction SilentlyContinue | Out-Null
            $stamp = (Get-Date -Format 'yyyyMMddTHHmmssfffZ')
            $finalHtml | Set-Content -Path (Join-Path $debugDir "bearer-error-$ClientId-$stamp.html") -Encoding UTF8
        }
        $evidence = if ($finalHtml.Length -gt 512) { $finalHtml.Substring(0, 512) } else { $finalHtml }
        throw "Get-EntraBearerToken: form_post HTML did not contain auth code [$errorMsg]. Evidence prefix: $evidence"
    }

    # Stage 3: POST token endpoint · A-3b-2 · v1 vs v2 path + body shape (D-38).
    $effectiveTenantId = if ($TenantId) {
        $TenantId
    } elseif ($ests.TenantIdCandidates -and @($ests.TenantIdCandidates).Count -gt 0) {
        @($ests.TenantIdCandidates)[0]
    } else {
        'organizations'
    }
    $tokenPath = if ($AuthVersion -eq 'v1') { 'oauth2/token' } else { 'oauth2/v2.0/token' }
    $tokenUri  = "https://login.microsoftonline.com/$effectiveTenantId/$tokenPath"

    # v1 body: client_id + code + redirect_uri + grant_type + resource + scope (user_impersonation) + code_verifier
    # v2 body: client_id + code + redirect_uri + grant_type + scope (URL/.default + openid profile offline_access) + code_verifier
    $tokenBodyFields = [ordered]@{
        client_id     = $ClientId
        code          = $authCode
        redirect_uri  = $RedirectUri
        grant_type    = 'authorization_code'
        code_verifier = $codeVerifier                                  # A-3b-2 PKCE · RFC 7636
        scope         = $Scope
    }
    if ($AuthVersion -eq 'v1') {
        $tokenBodyFields['resource'] = $Resource
    }
    $tokenBody = ($tokenBodyFields.GetEnumerator() | ForEach-Object {
        "$([uri]::EscapeDataString($_.Key))=$([uri]::EscapeDataString([string]$_.Value))"
    }) -join '&'

    # A-3b-2 · SPA cross-origin requires Origin header on /token (Bug 13 · D-39).
    # PublicClient does not require Origin · http://localhost redirect.
    $tokenHeaders = $null
    if ($ClientType -eq 'SPA') {
        $redirectScheme = ([uri]$RedirectUri).Scheme
        $redirectHost   = ([uri]$RedirectUri).Host
        $tokenHeaders   = @{ Origin = "${redirectScheme}://${redirectHost}" }
    }

    $tokenResp = Invoke-XdrAuthHttp -Uri $tokenUri -Method POST -Body $tokenBody `
        -ContentType 'application/x-www-form-urlencoded' -Session $ests.Session `
        -Headers $tokenHeaders

    if ($tokenResp.StatusCode -lt 200 -or $tokenResp.StatusCode -ge 300) {
        $cls = Resolve-EntraResponse -Response $tokenResp -ExpectedStage 'CredentialPost'
        throw "Get-EntraBearerToken: token exchange failed (status=$($tokenResp.StatusCode) · classification=$($cls.Classification) · reason=$($cls.Reason))"
    }

    $tokenJson = $null
    try { $tokenJson = $tokenResp.Content | ConvertFrom-Json -ErrorAction Stop } catch {
        throw "Get-EntraBearerToken: token response not parseable as JSON (status=$($tokenResp.StatusCode))"
    }
    if (-not $tokenJson -or -not $tokenJson.PSObject.Properties['access_token']) {
        throw "Get-EntraBearerToken: token response missing access_token field"
    }

    $accessToken   = [string]$tokenJson.access_token
    $refreshToken  = if ($tokenJson.PSObject.Properties['refresh_token']) { [string]$tokenJson.refresh_token } else { '' }
    $tokenType     = if ($tokenJson.PSObject.Properties['token_type'])    { [string]$tokenJson.token_type    } else { 'Bearer' }
    $scopeReturned = if ($tokenJson.PSObject.Properties['scope'])         { [string]$tokenJson.scope         } else { $Scope }
    $exp           = Get-XdrBearerTokenExpiry -BearerToken $accessToken

    [pscustomobject]@{
        AccessToken   = $accessToken
        RefreshToken  = $refreshToken
        TokenType     = $tokenType
        ExpiresUtc    = $exp.ExpiresUtc
        Scope         = $scopeReturned
        Audience      = $exp.Audience
        Upn           = $ests.Upn
        ClientId      = $ClientId
        TenantId      = $effectiveTenantId
        AcquiredUtc   = [datetime]::UtcNow
        EstsArtifacts = $ests
    }
}

# -----------------------------------------------------------------------------
# Refresh-XdrBearerToken — OAuth2 refresh-token flow · skip cookie chain on
# bearer-portal near-expiry events.
#
# RFC 6749 §6 + Microsoft Identity:
#   POST https://login.microsoftonline.com/<tenant>/oauth2/v2.0/token
#   Content-Type: application/x-www-form-urlencoded
#   Body: grant_type=refresh_token & refresh_token=<rt> & client_id=<cid>
#         & scope=<scope including offline_access>
#
# On invalid_grant (rt expired/revoked) caller MUST fall back to
# Get-EntraBearerToken (full cookie chain). The thrown message contains
# "invalid_grant" so Connect-*Portal can pattern-match and decide.
# -----------------------------------------------------------------------------
function Refresh-XdrBearerToken {
    [CmdletBinding()][OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$RefreshToken,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$Scope,
        [string]$TenantId,
        [string]$Upn = '',
        [guid]$CorrelationId = [guid]::NewGuid()
    )

    if ([string]::IsNullOrWhiteSpace($RefreshToken)) {
        throw "Refresh-XdrBearerToken: RefreshToken is empty; caller must fall back to Get-EntraBearerToken (full cookie chain)."
    }

    $effectiveTenantId = if ($TenantId) { $TenantId } else { 'organizations' }
    $tokenUri = "https://login.microsoftonline.com/$effectiveTenantId/oauth2/v2.0/token"

    $bodyFields = @{
        grant_type    = 'refresh_token'
        refresh_token = $RefreshToken
        client_id     = $ClientId
        scope         = $Scope
    }
    $body = ($bodyFields.GetEnumerator() | ForEach-Object {
        "$([uri]::EscapeDataString($_.Key))=$([uri]::EscapeDataString([string]$_.Value))"
    }) -join '&'

    $resp = Invoke-XdrAuthHttp -Uri $tokenUri -Method POST -Body $body `
        -ContentType 'application/x-www-form-urlencoded'

    if ($resp.StatusCode -lt 200 -or $resp.StatusCode -ge 300) {
        $cls = Resolve-EntraResponse -Response $resp -ExpectedStage 'CredentialPost'
        $msg = if ($cls.Classification -match 'aadsts-(\d+)') {
            "Refresh-XdrBearerToken: invalid_grant (AADSTS$($Matches[1])) — refresh-token expired or revoked; caller must Get-EntraBearerToken (full cookie chain)."
        } else {
            "Refresh-XdrBearerToken: token-exchange failed (status=$($resp.StatusCode) · classification=$($cls.Classification))"
        }
        throw $msg
    }

    $tokenJson = $null
    try { $tokenJson = $resp.Content | ConvertFrom-Json -ErrorAction Stop } catch {
        throw "Refresh-XdrBearerToken: token response not parseable as JSON (status=$($resp.StatusCode))"
    }
    if (-not $tokenJson -or -not $tokenJson.PSObject.Properties['access_token']) {
        throw "Refresh-XdrBearerToken: token response missing access_token field"
    }

    $accessToken    = [string]$tokenJson.access_token
    $newRefreshTok  = if ($tokenJson.PSObject.Properties['refresh_token']) { [string]$tokenJson.refresh_token } else { $RefreshToken }
    $tokenType      = if ($tokenJson.PSObject.Properties['token_type'])    { [string]$tokenJson.token_type    } else { 'Bearer' }
    $scopeReturned  = if ($tokenJson.PSObject.Properties['scope'])         { [string]$tokenJson.scope         } else { $Scope }
    $exp            = Get-XdrBearerTokenExpiry -BearerToken $accessToken

    [pscustomobject]@{
        AccessToken   = $accessToken
        RefreshToken  = $newRefreshTok
        TokenType     = $tokenType
        ExpiresUtc    = $exp.ExpiresUtc
        Scope         = $scopeReturned
        Audience      = $exp.Audience
        Upn           = $Upn
        ClientId      = $ClientId
        TenantId      = $effectiveTenantId
        AcquiredUtc   = [datetime]::UtcNow
        EstsArtifacts = $null   # refresh skips the cookie chain
    }
}

# Canonical /apiproxy/ service list (kept here so Xdr.Auth has its own copy
# without depending on Xdr.Poll module load order; Xdr.Poll has the runtime
# validator Test-ApiproxyPathPrefix using the same set).
$script:ValidApiproxyServices = @(
    'mtp','aatp','mcas','mdi','mtoapi','radius','mdc',
    'm365appprotection','astgws','securityplatform','di','msgraph',
    'shell','medeina','gws','cdssecuritycopilot','arm'
)

# -----------------------------------------------------------------------------
# $script:PortalConfig — 5 portals × 10 sub-portals · single source of truth
#
# Values from xdrlograider-prod/references/_auth-chain.md + per-portal *.psm1
# config blocks (Microsoft-immutable: client IDs, scopes, redirect URIs). At
# L-1 the live probe may surface refinements (e.g. CapabilityEndpoint paths);
# any change here re-runs the probe.
#
# Keyed '<Portal>::<SubPortal>'. SubPortal is '' for portals without
# sub-portals (Defender, Purview, SecurityCopilot).
# Active flag drives runtime iteration; only Defender is Active=$true at
# v0.1.0. Activating Purview/Entra/Intune/SecurityCopilot is a single-portal
# data-only flip per v0.2.0+ minor-version commit.
# -----------------------------------------------------------------------------
$script:PortalConfig = @{
    'Defender::' = @{
        Portal       = 'Defender'
        SubPortal    = ''
        AuthProfile  = 'Cookie'
        Active       = $true
        Host         = 'security.microsoft.com'
        ApiPathBase  = '/apiproxy'
        ClientId     = '80ccca67-54bd-44ab-8625-4b79c4dc7775'
        Scope        = 'openid profile offline_access'
        RedirectUri  = 'https://security.microsoft.com/signin-oidc'
        ExtraHeaders = @{}
        CapabilityEndpoint = '/apiproxy/mtp/sccManagement/mgmt/TenantContext?realTime=true'
    }
    'Purview::' = @{
        Portal       = 'Purview'
        SubPortal    = ''
        AuthProfile  = 'Cookie'
        Active       = $false
        Host         = 'compliance.microsoft.com'
        ApiPathBase  = '/apiproxy'
        ClientId     = '7f59a773-2eaf-429c-a059-50fc5bb28b44'
        Scope        = 'openid profile offline_access'
        RedirectUri  = 'https://compliance.microsoft.com/signin-oidc'
        ExtraHeaders = @{}
        CapabilityEndpoint = '/apiproxy/mtp/sccManagement/mgmt/TenantContext?realTime=true'
    }
    # ─── Bearer portals · v3 proven pattern (2026-05-17 A-3b refit) ─────────────
    #
    # v3 evidence base (xdrlograider-v3):
    #   src/Modules/Xdr.Entra.Auth/Xdr.Entra.Auth.psm1:41-112
    #   src/Modules/Xdr.Intune.Auth/Xdr.Intune.Auth.psm1:12-47
    #   src/Modules/Xdr.SecurityCopilot.Auth/Xdr.SecurityCopilot.Auth.psm1:13-26
    #   references/_auth-chain.md  Bugs 8/9/10/13/14/15 + Decisions D-28..D-39
    #
    # 2 Microsoft pre-consented public clients (Decisions D-35 / D-39):
    #   c44b4083-3bb0-49c1-b47d-974e53cbdf3c · Azure Portal SPA · IAM-pre-consented only
    #   04b07795-8ddb-461a-bbee-02f9e1bf7b46 · Microsoft Azure CLI PublicClient · universally pre-consented
    #
    # v1 OAuth flow (Decision D-38) · admin portals MUST use v1:
    #   POST /common/oauth2/token  with  resource=<URL or AppId> & scope=user_impersonation
    # NOT v2 OAuth (scope=URL/.default) — prior commit 3dd6e77 used v2 → AADSTS50011.
    #
    # Per-ClientType token-endpoint contract (Decision D-39):
    #   SPA          → PKCE + Origin header on /token (cross-origin RFC 7636)
    #   PublicClient → PKCE only · http://localhost redirect · no Origin
    'Entra::IAM' = @{
        Portal       = 'Entra'
        SubPortal    = 'IAM'
        AuthProfile  = 'Bearer'
        Active       = $false
        Host         = 'main.iam.ad.ext.azure.com'
        ApiPathBase  = '/api'
        ClientId     = 'c44b4083-3bb0-49c1-b47d-974e53cbdf3c'                 # Azure Portal SPA · IAM-pre-consented (Bug 8 fix)
        ClientType   = 'SPA'
        Resource     = '74658136-14ec-4630-ad9b-26e160ff0fc6'                 # ADIbizaUX AppId · nodoc-ibiza-iam canonical
        Scope        = 'user_impersonation'                                   # v1 OAuth (Bug 9 fix)
        AuthVersion  = 'v1'
        RedirectUri  = 'https://portal.azure.com/signin/index/'
        ExtraHeaders = @{ 'X-Ms-Client-Request-Id' = '{NewGuid}' }
        CapabilityEndpoint = '/api/Directories/ADConnectStatus'
    }
    'Entra::PIM' = @{
        Portal       = 'Entra'
        SubPortal    = 'PIM'
        AuthProfile  = 'Bearer'
        Active       = $false
        Host         = 'api.azrbac.mspim.azure.com'
        ApiPathBase  = ''
        ClientId     = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'                 # Azure CLI PublicClient · universal pre-consent (Bug 14 fix)
        ClientType   = 'PublicClient'
        Resource     = 'https://api.azrbac.mspim.azure.com'
        Scope        = 'user_impersonation'
        AuthVersion  = 'v1'
        RedirectUri  = 'http://localhost'
        ExtraHeaders = @{}
        CapabilityEndpoint = '/api/v3/roleManagement/directory/roleAssignments?$top=1'
    }
    'Entra::IDGov' = @{
        Portal       = 'Entra'
        SubPortal    = 'IDGov'
        AuthProfile  = 'Bearer'
        Active       = $false
        Host         = 'api.accessreviews.identitygovernance.azure.com'
        ApiPathBase  = ''
        ClientId     = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'
        ClientType   = 'PublicClient'
        Resource     = 'https://api.accessreviews.identitygovernance.azure.com'
        Scope        = 'user_impersonation'
        AuthVersion  = 'v1'
        RedirectUri  = 'http://localhost'
        ExtraHeaders = @{}
        CapabilityEndpoint = '/api/identityGovernance/accessReviews/definitions?$top=1'
    }
    'Entra::IGA' = @{
        Portal       = 'Entra'
        SubPortal    = 'IGA'
        AuthProfile  = 'Bearer'
        Active       = $false
        Host         = 'elm.iga.azure.com'
        ApiPathBase  = ''
        ClientId     = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'
        ClientType   = 'PublicClient'
        Resource     = 'https://elm.iga.azure.com'
        Scope        = 'user_impersonation'
        AuthVersion  = 'v1'
        RedirectUri  = 'http://localhost'
        ExtraHeaders = @{}
        CapabilityEndpoint = '/api/identityGovernance/lifecycleWorkflows/workflows?$top=1'
    }
    'Entra::B2C' = @{
        Portal       = 'Entra'
        SubPortal    = 'B2C'
        AuthProfile  = 'Bearer'
        Active       = $false
        Host         = 'main.b2cadmin.ext.azure.com'
        ApiPathBase  = '/api'
        ClientId     = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'
        ClientType   = 'PublicClient'
        Resource     = 'https://main.b2cadmin.ext.azure.com'
        Scope        = 'user_impersonation'
        AuthVersion  = 'v1'
        RedirectUri  = 'http://localhost'
        ExtraHeaders = @{}
        CapabilityEndpoint = '/api/Tenants/getTenantPolicies'
    }
    'Intune::Portal' = @{
        Portal       = 'Intune'
        SubPortal    = 'Portal'
        AuthProfile  = 'Bearer'
        Active       = $false
        Host         = 'intune.microsoft.com'                                 # UI host
        ApiPathBase  = ''
        ClientId     = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'                 # Azure CLI (Bug 15 fix: was 0000000a-...)
        ClientType   = 'PublicClient'
        Resource     = 'https://api.manage.microsoft.com'                     # ACTUAL backend Intune Device Mgmt API (Bug 15 fix)
        Scope        = 'user_impersonation'
        AuthVersion  = 'v1'
        RedirectUri  = 'http://localhost'
        ExtraHeaders = @{
            'x-ms-client-request-id' = '{NewGuid}'
            'x-ms-client-session-id' = '{NewGuid}'
            'x-ms-effective-locale'  = 'en.en-us'
            'x-ms-extension-flags'   = '{}'
            'x-requested-with'       = 'XMLHttpRequest'
        }
        CapabilityEndpoint = '/api/v1.0/me/deviceConfiguration/getDeviceFirmwareConfigurationInterfacePolicies'
    }
    'Intune::Autopatch' = @{
        Portal       = 'Intune'
        SubPortal    = 'Autopatch'
        AuthProfile  = 'Bearer'
        Active       = $false
        Host         = 'services.autopatch.microsoft.com'
        ApiPathBase  = ''
        ClientId     = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'                 # Azure CLI
        ClientType   = 'PublicClient'
        Resource     = 'https://services.autopatch.microsoft.com'
        Scope        = 'user_impersonation'
        AuthVersion  = 'v1'
        RedirectUri  = 'http://localhost'
        ExtraHeaders = @{
            'x-ms-client-request-id' = '{NewGuid}'
            'x-ms-client-session-id' = '{NewGuid}'
            'x-requested-with'       = 'XMLHttpRequest'
        }
        CapabilityEndpoint = '/api/tenant/onboardingStatus'
    }
    'SecurityCopilot::' = @{
        Portal       = 'SecurityCopilot'
        SubPortal    = ''
        AuthProfile  = 'Bearer'
        Active       = $false
        Host         = 'api.securitycopilot.microsoft.com'
        UiHost       = 'securitycopilot.microsoft.com'
        ApiPathBase  = ''
        ClientId     = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'                 # Azure CLI (was 74658136)
        ClientType   = 'PublicClient'
        Resource     = 'https://api.securitycopilot.microsoft.com'
        Scope        = 'user_impersonation'
        AuthVersion  = 'v1'
        RedirectUri  = 'http://localhost'
        ExtraHeaders = @{}
        CapabilityEndpoint = '/api/capabilities/tenant'
    }
}

# -----------------------------------------------------------------------------
# Get-XdrPortalConfig — accessor + iterator for $script:PortalConfig
# Three call shapes:
#   Get-XdrPortalConfig -Portal Defender                  → Defender entry
#   Get-XdrPortalConfig -Portal Entra -SubPortal IAM      → Entra IAM entry
#   Get-XdrPortalConfig                                   → all 10 entries
#   Get-XdrPortalConfig -ActiveOnly                       → Active=true entries
# -----------------------------------------------------------------------------
function Get-XdrPortalConfig {
    [CmdletBinding()][OutputType([pscustomobject])]
    param(
        [ValidateSet('Defender','Purview','Entra','Intune','SecurityCopilot')]
        [string]$Portal,
        [string]$SubPortal,
        [switch]$ActiveOnly
    )
    $emit = {
        param($key, $cfg)
        [pscustomobject]@{
            Key                = $key
            Portal             = $cfg.Portal
            SubPortal          = $cfg.SubPortal
            AuthProfile        = $cfg.AuthProfile
            Active             = $cfg.Active
            Host               = $cfg.Host
            UiHost             = if ($cfg.ContainsKey('UiHost')) { $cfg.UiHost } else { $cfg.Host }
            ApiPathBase        = $cfg.ApiPathBase
            ClientId           = $cfg.ClientId
            # ClientType / AuthVersion / Resource — bearer-specific fields (A-3b refit) ·
            # cookie rows return $null for these so the Get-XdrPortalConfig shape stays uniform.
            ClientType         = if ($cfg.ContainsKey('ClientType')) { $cfg.ClientType } else { $null }
            AuthVersion        = if ($cfg.ContainsKey('AuthVersion')) { $cfg.AuthVersion } else { $null }
            Resource           = if ($cfg.ContainsKey('Resource')) { $cfg.Resource } else { $null }
            Scope              = $cfg.Scope
            RedirectUri        = $cfg.RedirectUri
            ExtraHeaders       = $cfg.ExtraHeaders
            CapabilityEndpoint = $cfg.CapabilityEndpoint
        }
    }
    if ($Portal) {
        $key = "${Portal}::${SubPortal}"
        if (-not $script:PortalConfig.ContainsKey($key)) {
            throw "Get-XdrPortalConfig: unknown portal key '$key'. Valid keys: $($script:PortalConfig.Keys -join ', ')"
        }
        $cfg = $script:PortalConfig[$key]
        if ($ActiveOnly.IsPresent -and -not $cfg.Active) { return $null }
        return (& $emit $key $cfg)
    }
    foreach ($k in ($script:PortalConfig.Keys | Sort-Object)) {
        $cfg = $script:PortalConfig[$k]
        if ($ActiveOnly.IsPresent -and -not $cfg.Active) { continue }
        & $emit $k $cfg
    }
}

# -----------------------------------------------------------------------------
# New-ApiproxyPath — engineered builder for /apiproxy/<service>/<path>?<query>
#
# Single source of truth for path construction. Used by manifest authors,
# by the FA runtime when building Defender/Purview URLs, and by future
# portal-activation commits (Purview is the next cookie sibling on
# compliance.microsoft.com using the same /apiproxy/ surface).
#
# Behaviour:
#   - Leading slash on -Path is normalised (caller does not have to think).
#   - Idempotent: an already-/apiproxy/<svc>/-prefixed -Path is returned as-is.
#   - -QueryParams hashtable → stable lexicographic order, url-encoded values.
#   - Unknown -Service throws with the canonical service list.
#   - Empty -Path throws (caller error).
# -----------------------------------------------------------------------------
function New-ApiproxyPath {
    [CmdletBinding()][OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Service,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [hashtable]$QueryParams
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "New-ApiproxyPath: Path is empty. Provide the part after '/apiproxy/<service>/'."
    }
    if ($Service -notin $script:ValidApiproxyServices) {
        throw "New-ApiproxyPath: unknown service '$Service'. Valid services: $($script:ValidApiproxyServices -join ', ')."
    }

    # Idempotent: caller already passed an /apiproxy/<svc>/ path → unchanged.
    $svcPattern = '^/apiproxy/(' + ($script:ValidApiproxyServices -join '|') + ')/'
    if ($Path -match $svcPattern) {
        return $Path
    }

    $cleanPath = $Path.TrimStart('/')
    $result    = "/apiproxy/$Service/$cleanPath"

    if ($QueryParams -and $QueryParams.Count -gt 0) {
        $pairs = @()
        foreach ($k in ($QueryParams.Keys | Sort-Object)) {
            $encoded = [System.Web.HttpUtility]::UrlEncode([string]$QueryParams[$k])
            $pairs += "$k=$encoded"
        }
        $result = $result + '?' + ($pairs -join '&')
    }
    $result
}

Export-ModuleMember -Function `
    Connect-DefenderPortal, `
    Connect-PurviewPortal, `
    Connect-EntraPortal, `
    Connect-IntunePortal, `
    Connect-SecurityCopilotPortal, `
    Get-XdrCookieExpiry, `
    Resolve-EntraResponse, `
    Invoke-XdrAuthHttp, `
    Get-XdrTotpCode, `
    Get-XdrAuthFromKeyVault, `
    Clear-XdrCookieCache, `
    Save-XdrSessionToCache, `
    Read-XdrSessionFromCache, `
    Remove-XdrSessionFromCache, `
    Clear-XdrCredentialCache, `
    Test-XdrAuthCircuitOpen, `
    Add-XdrAuthCircuitFailure, `
    Reset-XdrAuthCircuit, `
    Clear-XdrAuthCircuit, `
    New-ApiproxyPath, `
    Get-EntraEstsAuth, `
    Get-EntraBearerToken, `
    Get-XdrBearerTokenExpiry, `
    Refresh-XdrBearerToken, `
    Get-XdrPortalConfig
