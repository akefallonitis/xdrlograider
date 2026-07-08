# XdrLogRaider · Xdr.Entra.Auth · OAuth bearer JWT for Entra portal sub-portals
#
# Status: present · NOT used in v0.1.0 runtime (Defender-only dispatch · §4.18 · no IsActive flag · G16). The bearer auth flow is
# functional and unit-testable; activation is a manifest flip (no source code change).
#
# Sub-portals (derived from Postman + live captures at design time):
#   IAM    → main.iam.ad.ext.azure.com/api
#   PIM    → api.azrbac.mspim.azure.com
#   IDGov  → api.accessreviews.identitygovernance.azure.com
#   IGA    → elm.iga.azure.com
#   B2C    → main.b2cadmin.ext.azure.com

Set-StrictMode -Version Latest

# Per-sub-portal bearer config (§36.1 · authorization-code over the shared ESTS chain · v1 resource for the
# portal-internal admin API · mvp-proven values). IAM is the ONLY SPA client (Origin header on /token);
# all other sub-portals use the Azure CLI universal PublicClient. RedirectUri MUST be registered on the
# client (AADSTS50011 guard). Live 5-portal probe validates/corrects per sub-portal (§36.7).
$script:EntraSubPortalConfig = @{
    IAM = @{
        Audience    = 'https://main.iam.ad.ext.azure.com'
        ClientId    = 'c44b4083-3bb0-49c1-b47d-974e53cbdf3c'   # Azure Portal SPA · IAM-pre-consented (mvp-proven)
        ClientType  = 'SPA'                                     # → Origin header on /token (Decision D-39)
        Resource    = '74658136-14ec-4630-ad9b-26e160ff0fc6'   # ADIbizaUX AppId GUID · v1 resource (NOT the URL)
        RedirectUri = 'https://portal.azure.com/signin/index/'
        AuthVersion = 'v1'
    }
    PIM = @{
        Audience    = 'https://api.azrbac.mspim.azure.com'
        ClientId    = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'   # Azure CLI · universal PublicClient
        ClientType  = 'PublicClient'
        Resource    = 'https://api.azrbac.mspim.azure.com'
        RedirectUri = 'http://localhost'
        AuthVersion = 'v1'
    }
    IDGov = @{
        Audience    = 'https://api.accessreviews.identitygovernance.azure.com'
        ClientId    = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'
        ClientType  = 'PublicClient'
        Resource    = 'https://api.accessreviews.identitygovernance.azure.com'
        RedirectUri = 'http://localhost'
        AuthVersion = 'v1'
    }
    IGA = @{
        Audience    = 'https://elm.iga.azure.com'
        ClientId    = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'
        ClientType  = 'PublicClient'
        Resource    = 'https://elm.iga.azure.com'
        RedirectUri = 'http://localhost'
        AuthVersion = 'v1'
    }
    B2C = @{
        Audience    = 'https://main.b2cadmin.ext.azure.com'
        ClientId    = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'
        ClientType  = 'PublicClient'
        Resource    = 'https://main.b2cadmin.ext.azure.com'
        RedirectUri = 'http://localhost'
        AuthVersion = 'v1'
    }
}

function Connect-EntraPortal {
    <#
    .SYNOPSIS
    Returns an Entra OAuth bearer session for the requested sub-portal.
    .DESCRIPTION
    Delegates to Xdr.Common.OAuthBearer.Get-XdrOAuthToken with sub-portal Audience + ClientId.
    Returns @{ AccessToken; Audience; ExpiresUtc; TokenType='Bearer'; UPN; Portal='Entra'; SubPortal }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [hashtable] $Credentials,
        [ValidateSet('IAM','PIM','IDGov','IGA','B2C')] [string] $SubPortal = 'IAM'
    )
    $config = $script:EntraSubPortalConfig[$SubPortal]
    if (-not $config) { throw "Connect-EntraPortal: Unknown sub-portal '$SubPortal'" }
    # §36.1 · authorization-code over the shared ESTS+MFA chain · per-sub-portal v1 resource + client + redirect ·
    # IAM=SPA (Origin on /token) · others=PublicClient (http://localhost) · probe-validated (§36.7).
    return Get-XdrOAuthToken -Portal 'Entra' -SubPortal $SubPortal -Audience $config.Audience -ClientId $config.ClientId `
        -RedirectUri $config.RedirectUri -Resource $config.Resource -AuthVersion $config.AuthVersion -ClientType $config.ClientType -Credentials $Credentials
}

# Register dispatch handler at module load
Register-XdrPortalHandler -Portal 'Entra' -Handler {
    param([hashtable]$Credentials)
    # StrictMode-safe SubPortal default (ContainsKey vs `.SubPortal` PropertyNotFoundException)
    $sub = if ($Credentials.ContainsKey('SubPortal') -and $Credentials['SubPortal']) { $Credentials['SubPortal'] } else { 'IAM' }
    Connect-EntraPortal -Credentials $Credentials -SubPortal $sub
}

Export-ModuleMember -Function Connect-EntraPortal
