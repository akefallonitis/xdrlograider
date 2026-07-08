# XdrLogRaider · Xdr.SecurityCopilot.Auth · OAuth bearer JWT
#
# Status: present · NOT used in v0.1.0 runtime (Defender-only dispatch · §4.18 4-gate · no IsActive flag · G16). Activation = v0.2.0.

Set-StrictMode -Version Latest

# §36.1 · authorization-code over the shared ESTS chain · v1 resource · RedirectUri registered on the
# public client (AADSTS50011 guard) · research-derived starting set · live-probe-validated (§36.7).
$script:SecurityCopilotConfig = @{
    Default = @{
        Audience    = 'https://api.securitycopilot.microsoft.com'
        UiHost      = 'securitycopilot.microsoft.com'
        ClientId    = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'  # Azure CLI · universally pre-consented PublicClient (mvp-proven)
        ClientType  = 'PublicClient'
        Resource    = 'https://api.securitycopilot.microsoft.com'
        RedirectUri = 'http://localhost'                       # PublicClient redirect (NOT portal /signin)
        AuthVersion = 'v1'
    }
}

function Connect-SecurityCopilotPortal {
    <#
    .SYNOPSIS
    Returns a Security Copilot OAuth bearer session (authorization-code over the shared ESTS+MFA chain · §36.1).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [hashtable] $Credentials,
        [string] $SubPortal = 'Default'
    )
    $config = $script:SecurityCopilotConfig[$SubPortal]
    if (-not $config) { throw "Connect-SecurityCopilotPortal: Unknown sub-portal '$SubPortal'" }
    return Get-XdrOAuthToken -Portal 'SecurityCopilot' -SubPortal $SubPortal -Audience $config.Audience -ClientId $config.ClientId `
        -RedirectUri $config.RedirectUri -Resource $config.Resource -AuthVersion $config.AuthVersion -ClientType $config.ClientType -Credentials $Credentials
}

Register-XdrPortalHandler -Portal 'SecurityCopilot' -Handler {
    param([hashtable]$Credentials)
    Connect-SecurityCopilotPortal -Credentials $Credentials
}

Export-ModuleMember -Function Connect-SecurityCopilotPortal
