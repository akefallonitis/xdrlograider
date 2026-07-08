# XdrLogRaider · Xdr.Intune.Auth · OAuth bearer JWT for Intune portal sub-portals
#
# Status: present · NOT used in v0.1.0 runtime (Defender-only dispatch · §4.18 4-gate · no IsActive flag · G16). Activation = v0.2.0.
#
# Sub-portals (derived from Postman + live captures at design time):
#   Portal    → intune.microsoft.com
#   Autopatch → services.autopatch.microsoft.com (requires extra x-ms-* headers · captured in Client module)

Set-StrictMode -Version Latest

# Per-sub-portal bearer config (§36.1 · authorization-code over the shared ESTS chain · v1 resource for
# portal-internal admin APIs). RedirectUri MUST be registered on the public client (AADSTS50011 guard) ·
# values are the research-derived starting set · the live 5-portal probe validates + corrects per sub-portal (§36.7).
$script:IntuneSubPortalConfig = @{
    Portal = @{
        Audience    = 'https://api.manage.microsoft.com'        # backend Intune Device Mgmt API (mvp Bug-15 · NOT intune.microsoft.com)
        ClientId    = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'    # Azure CLI · universally pre-consented PublicClient (mvp-proven)
        ClientType  = 'PublicClient'
        RedirectUri = 'http://localhost'                        # PublicClient redirect (NOT portal /signin)
        AuthVersion = 'v1'
    }
    Autopatch = @{
        Audience    = 'https://services.autopatch.microsoft.com'
        ClientId    = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'
        ClientType  = 'PublicClient'
        RedirectUri = 'http://localhost'
        AuthVersion = 'v1'
    }
}

function Connect-IntunePortal {
    <#
    .SYNOPSIS
    Returns an Intune OAuth bearer session (authorization-code over the shared ESTS+MFA chain · §36.1).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [hashtable] $Credentials,
        [ValidateSet('Portal','Autopatch')] [string] $SubPortal = 'Portal'
    )
    $config = $script:IntuneSubPortalConfig[$SubPortal]
    if (-not $config) { throw "Connect-IntunePortal: Unknown sub-portal '$SubPortal'" }
    return Get-XdrOAuthToken -Portal 'Intune' -SubPortal $SubPortal -Audience $config.Audience -ClientId $config.ClientId `
        -RedirectUri $config.RedirectUri -Resource $config.Audience -AuthVersion $config.AuthVersion -ClientType $config.ClientType -Credentials $Credentials
}

Register-XdrPortalHandler -Portal 'Intune' -Handler {
    param([hashtable]$Credentials)
    # StrictMode-safe SubPortal default
    $sub = if ($Credentials.ContainsKey('SubPortal') -and $Credentials['SubPortal']) { $Credentials['SubPortal'] } else { 'Portal' }
    Connect-IntunePortal -Credentials $Credentials -SubPortal $sub
}

Export-ModuleMember -Function Connect-IntunePortal
