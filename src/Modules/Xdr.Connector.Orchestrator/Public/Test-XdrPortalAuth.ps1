function Test-XdrPortalAuth {
    <#
    .SYNOPSIS
        Portal-routing wrapper for the per-portal auth self-test. Routes to
        the per-portal test function based on the -Portal value.

    .DESCRIPTION
        Today routes 'Defender' to Test-DefenderPortalAuth (Xdr.Defender.Auth).
        Used by the auth-selftest flag setter (first successful poll-* sign-in) to verify the
        service-account credentials are accepted by the target portal before
        any tier-poll runs.

    .PARAMETER Portal
        Portal name. Must match an entry in the orchestrator's routing table.
        Currently supported: 'Defender'.

    .PARAMETER Method
        Authentication method to test. Defender accepts: CredentialsTotp |
        Passkey (alias: credentials_totp, passkey).

    .PARAMETER Credential
        Hashtable of credentials. Forwarded to the per-portal test function.

    .PARAMETER PortalHost
        Optional hostname override. Defaults to the per-portal default.

    .OUTPUTS
        [pscustomobject] result object from the per-portal test function
        (typically with Success / Reason / LatencyMs fields).

    .EXAMPLE
        $r = Test-XdrPortalAuth -Portal 'Defender' -Method 'CredentialsTotp' -Credential $cred
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Portal,

        [Parameter(Mandatory)]
        [ValidateSet('CredentialsTotp', 'Passkey', 'credentials_totp', 'passkey')]
        [string] $Method,

        [Parameter(Mandatory)] [hashtable] $Credential,

        [string] $PortalHost
    )

    $route = Resolve-XdrPortalRoute -Portal $Portal

    if ([string]::IsNullOrWhiteSpace($PortalHost)) {
        $PortalHost = $route.DefaultHost
    }

    $testFn = $route.TestFn
    if (-not (Get-Command -Name $testFn -ErrorAction SilentlyContinue)) {
        throw "Test-XdrPortalAuth: per-portal function '$testFn' for portal '$Portal' is not available. Ensure module '$($route.AuthModule)' is imported."
    }

    # Dispatch through the per-portal auth module's session state (Pester-friendly).
    $splat = @{ Method = $Method; Credential = $Credential; PortalHost = $PortalHost }
    $authModule = Get-Module -Name $route.AuthModule
    if ($authModule) {
        & $authModule { param($Fn, $Splat) & $Fn @Splat } $testFn $splat
    } else {
        & $testFn @splat
    }
}
