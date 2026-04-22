function Exchange-SccauthCookie {
    <#
    .SYNOPSIS
        Exchanges an ESTSAUTHPERSISTENT cookie for a Defender XDR portal sccauth + XSRF-TOKEN.

    .DESCRIPTION
        After the login flow produces an ESTSAUTHPERSISTENT cookie, Defender XDR portal
        requires a second hop: navigate to security.microsoft.com which redirects to a
        portal-local idp endpoint; that endpoint issues `sccauth` + `XSRF-TOKEN` cookies.

        These cookies are what all subsequent /apiproxy calls authenticate with.

    .PARAMETER Session
        WebRequestSession from Get-EstsCookie (has ESTSAUTHPERSISTENT).

    .PARAMETER PortalHost
        The portal we're targeting. Default: security.microsoft.com.

    .OUTPUTS
        [hashtable] with:
          - Session     (the same session, now with sccauth + XSRF)
          - Sccauth     (cookie value)
          - XsrfToken   (cookie value)
          - AcquiredUtc (datetime — for staleness checks; sccauth ~1h)

    .NOTES
        See CloudBrothers April 2026 analysis referenced in docs/REFERENCES.md.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [Microsoft.PowerShell.Commands.WebRequestSession] $Session,
        [string] $PortalHost = 'security.microsoft.com'
    )

    # Step 1: hit the portal root with the login session — portal will redirect through
    # its own idp endpoint and issue sccauth + XSRF cookies along the way.
    $portalUri = "https://$PortalHost/"
    try {
        $resp = Invoke-WebRequest -Uri $portalUri -WebSession $Session -UseBasicParsing -MaximumRedirection 10 -ErrorAction Stop
    } catch [System.Net.WebException] {
        $resp = $_.Exception.Response
    }

    # Step 2: verify both cookies present
    $portalCookies = $Session.Cookies.GetCookies("https://$PortalHost")
    $sccauth = $portalCookies | Where-Object Name -eq 'sccauth' | Select-Object -First 1
    $xsrf    = $portalCookies | Where-Object Name -eq 'XSRF-TOKEN' | Select-Object -First 1

    if (-not $sccauth) {
        throw "Portal cookie exchange failed: sccauth not set after redirect chain. Host=$PortalHost. Verify ESTSAUTHPERSISTENT is present and account has access to the portal."
    }
    if (-not $xsrf) {
        throw "Portal cookie exchange failed: XSRF-TOKEN not set. Host=$PortalHost."
    }

    Write-Verbose "Exchange-SccauthCookie: success — sccauth+XSRF acquired from $PortalHost"

    return @{
        Session     = $Session
        Sccauth     = $sccauth.Value
        XsrfToken   = $xsrf.Value
        AcquiredUtc = [datetime]::UtcNow
    }
}
