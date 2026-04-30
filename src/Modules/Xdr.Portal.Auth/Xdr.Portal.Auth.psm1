# Xdr.Portal.Auth — backward-compat shim for v0.1.0-beta operators + tests.
#
# The previous monolithic module was split into two cleanly-separated layers:
#   L1 Xdr.Common.Auth   — portal-generic Entra layer (TOTP, passkey, ESTS auth,
#                          MFA + interrupt handling, KV loader)
#   L2 Xdr.Defender.Auth — Defender-portal-specific cookie exchange (sccauth +
#                          XSRF-TOKEN), session cache, request wrapper, rate
#                          counter
#
# This shim retains the original module name + the original MDE-prefixed
# function names (Connect-MDEPortal, Invoke-MDEPortalRequest, …) by importing
# the two new modules and exposing pass-through wrapper functions. So:
#   - Existing files in the repo that reference Xdr.Portal.Auth /
#     Connect-MDEPortal / Invoke-MDEPortalRequest / Test-MDEPortalAuth /
#     Get-MDEAuthFromKeyVault / Connect-MDEPortalWithCookies all keep working
#     unchanged.
#   - Pester tests that `Mock -ModuleName 'Xdr.Portal.Auth' Connect-MDEPortal'
#     keep working — the wrapper functions live inside this module.
#   - Operator scripts that `Import-Module Xdr.Portal.Auth` and call the old
#     names keep working.
#
# v0.2.0 will deprecate this shim (operators migrate to Connect-DefenderPortal /
# Invoke-DefenderPortalRequest / etc). The shim STAYS during the v0.1.0-beta →
# v0.1.0 GA window so existing operators have zero migration friction.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Import the two new modules. profile.ps1 imports Xdr.Common.Auth + Xdr.Defender.Auth
# before this shim, so Get-Module finds them already loaded. Tests that import
# this shim directly trigger lazy load below.
$commonModule   = Get-Module -Name 'Xdr.Common.Auth'
$defenderModule = Get-Module -Name 'Xdr.Defender.Auth'

if (-not $commonModule) {
    $commonPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Xdr.Common.Auth' 'Xdr.Common.Auth.psd1'
    if (Test-Path -LiteralPath $commonPath) {
        Import-Module $commonPath -Force -Global -ErrorAction Stop
    } else {
        throw "Xdr.Portal.Auth shim: cannot locate Xdr.Common.Auth at $commonPath. Both modules must live under src/Modules/."
    }
}

if (-not $defenderModule) {
    $defenderPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Xdr.Defender.Auth' 'Xdr.Defender.Auth.psd1'
    if (Test-Path -LiteralPath $defenderPath) {
        Import-Module $defenderPath -Force -Global -ErrorAction Stop
    } else {
        throw "Xdr.Portal.Auth shim: cannot locate Xdr.Defender.Auth at $defenderPath."
    }
}

# Backward-compat wrapper functions. Each wraps the new-name function from
# Xdr.Defender.Auth (or Xdr.Common.Auth for the KV loader) with a 1:1 splat so
# all parameters pass through unchanged.

function Connect-MDEPortal {
    <#
    .SYNOPSIS
        Backward-compat alias for Connect-DefenderPortal (Xdr.Defender.Auth).
        See that function for full documentation.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('CredentialsTotp', 'Passkey', 'credentials_totp', 'passkey')]
        [string] $Method,
        [Parameter(Mandatory)] [hashtable] $Credential,
        [string] $PortalHost = 'security.microsoft.com',
        [string] $TenantId,
        [switch] $Force
    )
    Connect-DefenderPortal @PSBoundParameters
}

function Connect-MDEPortalWithCookies {
    <#
    .SYNOPSIS
        Backward-compat alias for Connect-DefenderPortalWithCookies.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Sccauth,
        [Parameter(Mandatory)] [string] $XsrfToken,
        [string] $Upn = 'cookie-session',
        [string] $PortalHost = 'security.microsoft.com'
    )
    Connect-DefenderPortalWithCookies @PSBoundParameters
}

function Invoke-MDEPortalRequest {
    <#
    .SYNOPSIS
        Backward-compat alias for Invoke-DefenderPortalRequest.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Session,
        [Parameter(Mandatory)] [string] $Path,
        [string] $Method = 'GET',
        $Body = $null,
        [string] $ContentType,
        [int] $TimeoutSec = 60,
        [hashtable] $AdditionalHeaders = @{}
    )
    Invoke-DefenderPortalRequest @PSBoundParameters
}

function Test-MDEPortalAuth {
    <#
    .SYNOPSIS
        Backward-compat alias for Test-DefenderPortalAuth.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('CredentialsTotp', 'Passkey', 'credentials_totp', 'passkey')]
        [string] $Method,
        [Parameter(Mandatory)] [hashtable] $Credential,
        [string] $PortalHost = 'security.microsoft.com'
    )
    Test-DefenderPortalAuth @PSBoundParameters
}

function Get-MDEAuthFromKeyVault {
    <#
    .SYNOPSIS
        Backward-compat alias for Get-XdrAuthFromKeyVault (Xdr.Common.Auth).
        Maps the legacy -SecretName parameter onto the new -SecretPrefix.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $VaultUri,
        [string] $SecretName = 'mde-portal-auth',
        [Parameter(Mandatory)]
        [ValidateSet('CredentialsTotp', 'Passkey', 'DirectCookies', 'credentials_totp', 'passkey', 'direct_cookies')]
        [string] $AuthMethod
    )
    # Legacy callers passed -SecretName (the auth-bundle name like 'mde-portal-auth').
    # The actual secret keys are <prefix>-upn / <prefix>-password / etc — the new
    # function takes that prefix directly. Strip the trailing '-auth' if present
    # to derive the prefix.
    $secretPrefix = if ($SecretName -like '*-auth') {
        $SecretName.Substring(0, $SecretName.Length - '-auth'.Length)
    } else {
        $SecretName
    }
    Get-XdrAuthFromKeyVault -VaultUri $VaultUri -SecretPrefix $secretPrefix -AuthMethod $AuthMethod
}

# Re-export the rate-counter functions (already public in Xdr.Defender.Auth).
# The shim wrappers ensure callers that imported Xdr.Portal.Auth specifically
# can still find the symbols.

function Get-XdrPortalRate429Count {
    [CmdletBinding()]
    [OutputType([int])]
    param()
    & (Get-Module -Name 'Xdr.Defender.Auth') { Get-XdrPortalRate429Count }
}

function Reset-XdrPortalRate429Count {
    [CmdletBinding()]
    param()
    & (Get-Module -Name 'Xdr.Defender.Auth') { Reset-XdrPortalRate429Count }
}

# Module-level session cache — kept for backward-compat with tests that mock
# this dictionary directly. The actual per-portal cache now lives in
# Xdr.Defender.Auth's $script:SessionCache; this shim cache is a compat proxy.
$script:SessionCache = @{}

Export-ModuleMember -Function @(
    'Connect-MDEPortal',
    'Connect-MDEPortalWithCookies',
    'Invoke-MDEPortalRequest',
    'Test-MDEPortalAuth',
    'Get-MDEAuthFromKeyVault',
    'Get-XdrPortalRate429Count',
    'Reset-XdrPortalRate429Count'
)
