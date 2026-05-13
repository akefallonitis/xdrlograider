function Connect-XdrPortal {
    <#
    .SYNOPSIS
        Portal-routing entry point for establishing an authenticated portal
        session. Routes the request to the right per-portal connect function
        based on the -Portal value.

    .DESCRIPTION
        Today routes 'Defender' to Connect-DefenderPortal (Xdr.Defender.Auth).
        Future portals (Purview, Intune, Entra) will be added by extending the
        internal portal-routing table; the operator-facing surface stays the
        same.

        The function performs:
          1. -Portal value validation against the routing table.
          2. Verification the target L2 auth module is loaded.
          3. Pass-through call to the per-portal connect function with all
             remaining parameters splatted unchanged.

    .PARAMETER Portal
        Portal name. Must match an entry in the orchestrator's routing table.
        Currently supported: 'Defender'.

    .PARAMETER Method
        Authentication method. Forwarded to the per-portal connect function.
        Defender accepts: CredentialsTotp | Passkey (alias: credentials_totp,
        passkey).

    .PARAMETER Credential
        Hashtable of credentials. Forwarded to the per-portal connect function.

    .PARAMETER PortalHost
        Optional hostname override. Defaults to the per-portal default
        (security.microsoft.com for Defender) if omitted.

    .PARAMETER TenantId
        Optional tenant id. Forwarded to the per-portal connect function.

    .PARAMETER Force
        Forwarded to the per-portal connect function (ignores cached session).

    .OUTPUTS
        [pscustomobject] PortalSession from the per-portal connect function.

    .EXAMPLE
        $session = Connect-XdrPortal -Portal 'Defender' -Method 'CredentialsTotp' -Credential $cred
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Portal,

        [Parameter(Mandatory)]
        [ValidateSet('CredentialsTotp', 'Passkey', 'credentials_totp', 'passkey')]
        [string] $Method,

        [Parameter(Mandatory)] [hashtable] $Credential,

        [string] $PortalHost,

        [string] $TenantId,

        [switch] $Force
    )

    $route = Resolve-XdrPortalRoute -Portal $Portal

    # Default host comes from the routing entry if caller didn't override.
    if ([string]::IsNullOrWhiteSpace($PortalHost)) {
        $PortalHost = $route.DefaultHost
    }

    $args = @{
        Method     = $Method
        Credential = $Credential
        PortalHost = $PortalHost
    }
    if ($PSBoundParameters.ContainsKey('TenantId')) { $args['TenantId'] = $TenantId }
    if ($Force.IsPresent) { $args['Force'] = $true }

    $connectFn = $route.ConnectFn
    if (-not (Get-Command -Name $connectFn -ErrorAction SilentlyContinue)) {
        throw "Connect-XdrPortal: per-portal function '$connectFn' for portal '$Portal' is not available. Ensure module '$($route.AuthModule)' is imported."
    }

    # Dispatch through the per-portal auth module's session state. This is
    # both forward-scalable (each portal owns its module-internal helpers)
    # and Pester-friendly (mocks registered with -ModuleName 'Xdr.<Portal>.Auth'
    # are resolved when the call happens inside that module's scope).
    $authModule = Get-Module -Name $route.AuthModule
    if ($authModule) {
        & $authModule { param($Fn, $Splat) & $Fn @Splat } $connectFn $args
    } else {
        & $connectFn @args
    }
}
