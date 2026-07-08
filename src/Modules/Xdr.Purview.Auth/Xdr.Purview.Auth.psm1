# XdrLogRaider · Xdr.Purview.Auth · Cookie + XSRF (cookie-family parallel to Defender)
#
# Status: cookie-OIDC auth IMPLEMENTED + live-verified (§35.17/§35.19) · NOT polled in v0.1.0 (Defender-only dispatch · §4.18 · no IsActive flag · G16). Polling = v0.2.0.
#
# Purview uses cookie-based auth like Defender (sccauth + KMSI) · NOT OAuth bearer.
# This module mirrors Xdr.Defender.Auth's T1/T2/T3 pattern with Purview-specific endpoints.

Set-StrictMode -Version Latest

$script:PurviewConfig = @{
    Host          = 'purview.microsoft.com'
    ClientId      = '7f59a773-2eaf-429c-a059-50fc5bb28b44'   # Microsoft-owned RP-scoped to purview.microsoft.com
    AuthorizeUrl  = 'https://login.microsoftonline.com/common/oauth2/v2.0/authorize'
    CookieName    = 'sccauth'  # Purview shares sccauth cookie family with Defender
}

function Connect-PurviewPortal {
    <#
    .SYNOPSIS
    Purview cookie session handler (T1 cache / T2 KMSI silent refresh / T3 full cookie-OIDC). Returns a clean
    HASHTABLE session for Connect-XdrPortal (which owns L1/L2 cache + single-flight lease).
    .DESCRIPTION
    Reuses the SHARED Entra cookie-OIDC chain from Xdr.Defender.Auth (host-parameterized · §35.16) with the Purview
    portal-host ('purview.microsoft.com'). Purview is auth-VERIFIED but NOT polled in v0.1.0 (no XdrRefresh dispatch
    function for it · §4.18) — this handler exists + works so the all-5-portal-auth deliverable is real, and Purview
    activates by adding manifest Operations in v0.2.0 with ZERO auth changes.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)] [hashtable] $Credentials)

    $purviewHost = $script:PurviewConfig.Host   # purview.microsoft.com

    # T1 · cache hit (alive) → return. Indexer reads (StrictMode-safe partial sessions · dynamic ExpiresUtc).
    # SKIP T1 when __ForceFresh (Connect-XdrPortal -Force · self-heal reauth) — else a forced reauth re-returns the SAME
    # stale session that just 440'd, re-looping (parity with Defender.Auth:621 · AU5-reaudit 2026-06-12). T2 below
    # still fires → fresh sccauth, no TOTP.
    $cached = Get-XdrCachedSession -Portal 'Purview' -UPN $Credentials['UPN']
    if (-not $Credentials['__ForceFresh'] -and $cached -and $cached['Sccauth'] -and $cached['ExpiresUtc']) {
        try {
            if ((ConvertTo-XdrUtc $cached['ExpiresUtc']) -gt [DateTime]::UtcNow.AddMinutes(5)) { return $cached }
        } catch { <# parse fail → fall through · INTENTIONAL-FAIL-SAFE #> }
    }

    # T2 · KMSI silent refresh (re-mint sccauth from ESTSAUTHPERSISTENT · no TOTP) · shared chain w/ Purview host+portal
    if ($cached -and $cached['KmsiCookie']) {
        try { $r = Refresh-DefenderSccauth -CachedSession $cached -PortalHost $purviewHost -Portal 'Purview'; if ($r.Success) { return $r.Session } }
        catch { Track-XdrEvent -Name 'Purview.Auth.T2.Swallowed' -Properties @{ UPN = $Credentials['UPN']; Reason = $_.Exception.Message } }  # INTENTIONAL-FAIL-SAFE: T2 KMSI refresh failed -> fall through to T3 full auth · now observable (parity w/ Defender.Auth:629 · was a banned blind catch{})
    }

    # T3 · fresh cookie-OIDC chain (shared Entra ESTS helpers · Purview portal-host override)
    $method = switch (([string]$Credentials['AuthMethod'])) {
        'TOTP' { 'CredentialsTotp' }; 'CredentialsTotp' { 'CredentialsTotp' }; 'credentials_totp' { 'CredentialsTotp' }
        'Passkey' { 'Passkey' }; 'passkey' { 'Passkey' }; default { 'CredentialsTotp' }
    }
    $tenantHint = if ($Credentials['TenantId']) { [string]$Credentials['TenantId'] } elseif ($env:XDRLR_TENANT_ID) { $env:XDRLR_TENANT_ID } else { '' }

    Track-XdrEvent -Name 'Purview.Auth.T3.Started' -Properties @{ UPN = $Credentials['UPN']; AuthMethod = $method }
    $ests = Get-XdrEntraEstsAuth -Method $method -Credential $Credentials -PortalHost $purviewHost -TenantId $tenantHint
    $null = Submit-XdrAuthFormPost -FormPostHtml $ests.FinalHtml -WebSession $ests.Session -ExpectedActionHostname $purviewHost
    $scc = Get-XdrDefenderSccauth -WebSession $ests.Session -PortalHost $purviewHost -TenantId $tenantHint -Artifacts $ests
    $expiry = Get-XdrCookieExpiry -WebSession $ests.Session -PortalHost $purviewHost -AcquiredUtc $scc.AcquiredUtc
    $kmsiCookieVal = Get-XdrKmsiCookieValue -WebSession $ests.Session

    $session = @{
        UPN                  = $ests.Upn
        Sccauth              = $scc.Sccauth
        XsrfToken            = $scc.XsrfToken
        Cookie               = "sccauth=$($scc.Sccauth)"
        Portal               = 'Purview'
        TenantId             = $scc.TenantId
        TenantIdSource       = $scc.TenantIdSource
        KmsiActive           = [bool]$ests.KmsiAccepted
        KmsiCookie           = $kmsiCookieVal
        ExpiresUtc           = $expiry.ExpiresUtc.ToString('o')
        KmsiExpiresUtc       = if ($expiry.KmsiExpiresUtc) { $expiry.KmsiExpiresUtc.ToString('o') } else { '' }
        EarliestExpirySource = $expiry.EarliestExpirySource
        SavedUtc             = (Get-Date).ToUniversalTime().ToString('o')
        CreatedBy            = 'T3-cookie-oidc'
    }
    Track-XdrEvent -Name 'Purview.Auth.T3.Succeeded' -Properties @{ UPN = $ests.Upn; TenantIdSource = $scc.TenantIdSource }
    return $session
}

Register-XdrPortalHandler -Portal 'Purview' -Handler {
    param([hashtable]$Credentials)
    Connect-PurviewPortal -Credentials $Credentials
}

Export-ModuleMember -Function Connect-PurviewPortal
