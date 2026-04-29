function Get-DefenderSccauth {
    <#
    .SYNOPSIS
        L2 Defender — verifies the portal cookies (sccauth + XSRF-TOKEN) on a
        post-Entra-auth session and optionally auto-resolves TenantId.

    .DESCRIPTION
        Called immediately after L1 Get-EntraEstsAuth completes. Get-EntraEstsAuth's
        final form_post submission triggers the Defender portal's OIDC callback
        which mints sccauth + XSRF-TOKEN cookies on the same session. This helper
        verifies both are present, nudges the portal root if XSRF-TOKEN is missing
        (some tenants only mint it on the first /apiproxy call), and auto-resolves
        TenantId via TenantContext if not provided.

    .PARAMETER Session
        WebRequestSession returned by Get-EntraEstsAuth.

    .PARAMETER PortalHost
        Default 'security.microsoft.com'.

    .PARAMETER TenantId
        Optional. If not provided, auto-resolved via /apiproxy/mtp/sccManagement/mgmt/TenantContext.

    .OUTPUTS
        @{ Sccauth; XsrfToken; TenantId; AcquiredUtc }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [Microsoft.PowerShell.Commands.WebRequestSession] $Session,
        [string] $PortalHost = 'security.microsoft.com',
        [string] $TenantId
    )

    if ($VerbosePreference -eq 'Continue' -or $env:XDRLR_DEBUG_AUTH -eq '1') {
        $cookies = $Session.Cookies.GetCookies("https://$PortalHost") | ForEach-Object Name
        Write-Host "[DEBUG] Get-DefenderSccauth: $PortalHost cookies on entry: $($cookies -join ',')"
    }

    # --- Verify portal cookies ---
    $portalCookies = $Session.Cookies.GetCookies("https://$PortalHost")
    $sccauth = $portalCookies | Where-Object Name -eq 'sccauth'    | Select-Object -First 1
    $xsrf    = $portalCookies | Where-Object Name -eq 'XSRF-TOKEN' | Select-Object -First 1

    if (-not $sccauth -or [string]::IsNullOrWhiteSpace($sccauth.Value)) {
        $present = (@($portalCookies | ForEach-Object Name) -join ', ')
        throw "Auth flow completed but sccauth not issued. Portal cookies: $present. Common causes: CA policy, wrong credentials, TOTP drift, or account locked."
    }
    if (-not $xsrf -or [string]::IsNullOrWhiteSpace($xsrf.Value)) {
        # Some tenants mint XSRF only on first /apiproxy call — trigger one.
        Write-Verbose "Get-DefenderSccauth: XSRF missing, pinging portal"
        try {
            Invoke-WebRequest -Uri "https://$PortalHost/" -WebSession $Session -UseBasicParsing -ErrorAction SilentlyContinue | Out-Null
        } catch {}
        $xsrf = $Session.Cookies.GetCookies("https://$PortalHost") | Where-Object Name -eq 'XSRF-TOKEN' | Select-Object -First 1
    }
    if (-not $xsrf -or [string]::IsNullOrWhiteSpace($xsrf.Value)) {
        throw "Auth flow completed, sccauth issued, but XSRF-TOKEN not set on $PortalHost."
    }

    # --- Auto-harvest tenant ID from TenantContext if not supplied ---
    if (-not $TenantId) {
        try {
            $headers = @{ 'X-XSRF-TOKEN' = [System.Net.WebUtility]::UrlDecode($xsrf.Value) }
            $ctx = Invoke-RestMethod -Uri "https://$PortalHost/apiproxy/mtp/sccManagement/mgmt/TenantContext?realTime=true" `
                -WebSession $Session -Headers $headers -ContentType 'application/json' `
                -Method Get -ErrorAction Stop
            if ($ctx -and $ctx.AuthInfo -and $ctx.AuthInfo.TenantId) {
                $TenantId = $ctx.AuthInfo.TenantId
                Write-Verbose "Get-DefenderSccauth: auto-resolved TenantId=$TenantId"
            }
        } catch {
            Write-Verbose "Get-DefenderSccauth: TenantContext lookup failed — $($_.Exception.Message)"
        }
    }

    Write-Verbose "Get-DefenderSccauth: success (sccauth len=$($sccauth.Value.Length) xsrf len=$($xsrf.Value.Length))"
    return @{
        Sccauth     = $sccauth.Value
        XsrfToken   = $xsrf.Value
        TenantId    = $TenantId
        AcquiredUtc = [datetime]::UtcNow
    }
}
