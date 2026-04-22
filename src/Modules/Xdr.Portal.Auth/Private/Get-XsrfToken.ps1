function Update-XsrfToken {
    <#
    .SYNOPSIS
        Refreshes the XSRF-TOKEN from the session cookie jar after a portal response.

    .DESCRIPTION
        The portal rotates XSRF-TOKEN roughly every 4 minutes and on every state-changing
        response. Before each API call we read the current value from the session's cookie
        jar (the WebRequestSession automatically accepts new cookies from responses) and
        return it so the caller can include it in the next request's X-XSRF-TOKEN header.

    .PARAMETER Session
        The authenticated WebRequestSession.

    .PARAMETER PortalHost
        The portal whose XSRF cookie we need.

    .OUTPUTS
        [string] the current XSRF-TOKEN value.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [Microsoft.PowerShell.Commands.WebRequestSession] $Session,
        [string] $PortalHost = 'security.microsoft.com'
    )

    $cookies = $Session.Cookies.GetCookies("https://$PortalHost")
    $xsrf = $cookies | Where-Object Name -eq 'XSRF-TOKEN' | Select-Object -First 1
    if (-not $xsrf) {
        throw "XSRF-TOKEN missing from session for $PortalHost. Session may be expired."
    }
    return $xsrf.Value
}
