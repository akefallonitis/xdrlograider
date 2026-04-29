function Connect-DefenderPortalWithCookies {
    <#
    .SYNOPSIS
        L2 Defender — builds a session from browser-captured sccauth + XSRF cookies.

    .DESCRIPTION
        Fastest path to a working Defender portal session — skip the full login
        chain and use cookies you've already acquired interactively via browser.
        Same pattern XDRInternals uses for cookie-mode auth.

        The session created this way is read-only until cookies expire (sccauth
        ~1h). Use this for: local testing, proving the rest of the pipeline
        works, one-off investigations. For unattended production use, prefer
        Credentials+TOTP or Software Passkey via Connect-DefenderPortal.

    .PARAMETER Sccauth
        Value of the `sccauth` cookie from security.microsoft.com.
        Get it: log into security.microsoft.com in browser → F12 → Application tab
        → Cookies → security.microsoft.com → copy sccauth value.

    .PARAMETER XsrfToken
        Value of the `XSRF-TOKEN` cookie from security.microsoft.com.

    .PARAMETER Upn
        Optional — service account UPN, for cache key and logging.

    .PARAMETER PortalHost
        Default: security.microsoft.com.

    .OUTPUTS
        [pscustomobject] same shape as Connect-DefenderPortal.

    .EXAMPLE
        $session = Connect-DefenderPortalWithCookies `
            -Sccauth 'eyJhbGciOi...' `
            -XsrfToken 'abc123...' `
            -Upn 'svc-test@contoso.com'

        Invoke-DefenderPortalRequest -Session $session -Path '/api/settings/GetAdvancedFeaturesSetting'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Sccauth,
        [Parameter(Mandatory)] [string] $XsrfToken,
        [string] $Upn = 'cookie-session',
        [string] $PortalHost = 'security.microsoft.com'
    )

    $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
    $session.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

    # Inject cookies into the session's cookie container
    $uri = [System.Uri]::new("https://$PortalHost/")

    $sccauthCookie = [System.Net.Cookie]::new('sccauth', $Sccauth, '/', $PortalHost)
    $sccauthCookie.Secure = $true
    $sccauthCookie.HttpOnly = $true
    $session.Cookies.Add($uri, $sccauthCookie)

    $xsrfCookie = [System.Net.Cookie]::new('XSRF-TOKEN', $XsrfToken, '/', $PortalHost)
    $xsrfCookie.Secure = $true
    $session.Cookies.Add($uri, $xsrfCookie)

    # iter-14.0 Phase 14B: stamp a CorrelationId so downstream
    # Invoke-DefenderPortalRequest + Invoke-MDETierPoll calls stitch their
    # AI events on a stable operation id even for cookie-built sessions.
    $correlationId = [Guid]::NewGuid().ToString()

    $result = [pscustomobject]@{
        Session       = $session
        Upn           = $Upn
        PortalHost    = $PortalHost
        AcquiredUtc   = [datetime]::UtcNow
        CorrelationId = $correlationId
    }

    # Cache like Connect-DefenderPortal does
    $cacheKey = "$Upn::$PortalHost"
    $script:SessionCache[$cacheKey] = @{
        Session       = $session
        Upn           = $Upn
        PortalHost    = $PortalHost
        AcquiredUtc   = $result.AcquiredUtc
        CorrelationId = $correlationId
    }

    Write-Verbose "Connect-DefenderPortalWithCookies: session built for $Upn at $PortalHost"
    return $result
}
