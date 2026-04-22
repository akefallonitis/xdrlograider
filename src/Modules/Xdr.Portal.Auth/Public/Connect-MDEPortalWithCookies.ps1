function Connect-MDEPortalWithCookies {
    <#
    .SYNOPSIS
        Builds an MDE portal session from browser-captured sccauth + XSRF cookies.

    .DESCRIPTION
        Fastest path to a working session — skip the full login chain and use cookies
        that you've already acquired interactively via browser. Same pattern XDRInternals
        uses for cookie-mode auth.

        The session created this way is read-only until cookies expire (sccauth ~1h).
        Use this for: local testing, proving the rest of the pipeline works, one-off
        investigations. For unattended production use, prefer Credentials+TOTP or
        Software Passkey.

    .PARAMETER Sccauth
        Value of the `sccauth` cookie from security.microsoft.com.
        Get it: log into security.microsoft.com in browser → F12 → Application tab
        → Cookies → security.microsoft.com → copy sccauth value.

    .PARAMETER XsrfToken
        Value of the `XSRF-TOKEN` cookie from security.microsoft.com.
        Same location as sccauth.

    .PARAMETER Upn
        Optional — service account UPN, for cache key and logging.

    .PARAMETER PortalHost
        Default: security.microsoft.com.

    .OUTPUTS
        [pscustomobject] same shape as Connect-MDEPortal — Session, Upn, PortalHost, AcquiredUtc.

    .EXAMPLE
        $session = Connect-MDEPortalWithCookies `
            -Sccauth 'eyJhbGciOi...' `
            -XsrfToken 'abc123...' `
            -Upn 'svc-test@contoso.com'

        Invoke-MDEPortalRequest -Session $session -Path '/api/settings/GetAdvancedFeaturesSetting'
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

    $result = [pscustomobject]@{
        Session     = $session
        Upn         = $Upn
        PortalHost  = $PortalHost
        AcquiredUtc = [datetime]::UtcNow
    }

    # Cache like Connect-MDEPortal does
    $cacheKey = "$Upn::$PortalHost"
    $script:SessionCache[$cacheKey] = @{
        Session     = $session
        Upn         = $Upn
        PortalHost  = $PortalHost
        AcquiredUtc = $result.AcquiredUtc
    }

    Write-Verbose "Connect-MDEPortalWithCookies: session built for $Upn at $PortalHost"
    return $result
}
