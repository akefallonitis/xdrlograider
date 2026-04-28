function Connect-MDEPortal {
    <#
    .SYNOPSIS
        Authenticates to the Microsoft Defender XDR portal and returns a reusable session.

    .DESCRIPTION
        Runs the full non-browser auth chain:
          1. Get-EstsCookie  -> login.microsoftonline.com (credentials+TOTP or passkey)
                                returns the ESTSAUTHPERSISTENT cookie VALUE.
          2. Exchange-SccauthCookie -> fresh session, inject ESTS cookie, walk
                                security.microsoft.com authorization-code form,
                                end with sccauth + XSRF-TOKEN.

        The returned session is cached in a module-scope dictionary keyed by
        "<upn>::<host>" for 50 minutes (sccauth lifetime ~1h with 10-min safety
        margin). Subsequent calls hit the cache; -Force bypasses it.

        The original credential hashtable is retained in-memory on the cache entry
        under `_Credential` + `_Method` so that Invoke-MDEPortalRequest can silently
        re-auth on HTTP 401 without another human in the loop. It is never persisted,
        never logged, and cleared with the process.

    .PARAMETER Method
        'CredentialsTotp' or 'Passkey'. Drives which fields are required on -Credential.

    .PARAMETER Credential
        Hashtable with auth material:
          CredentialsTotp: @{ upn = ''; password = ''; totpBase32 = '' }
          Passkey:         @{ upn = ''; passkey = <parsed JSON object> }

    .PARAMETER PortalHost
        Target portal hostname. Default: security.microsoft.com.

    .PARAMETER TenantId
        Optional. Improves first-hop latency by short-circuiting Entra's
        home-realm-discovery redirect. Auto-resolved otherwise.

    .PARAMETER Force
        Bypass the cache and run a fresh auth chain.

    .OUTPUTS
        [pscustomobject] @{
            Session     = [WebRequestSession] (sccauth + XSRF-TOKEN)
            Upn         = [string]
            PortalHost  = [string]
            TenantId    = [string]
            AcquiredUtc = [datetime]
        }

    .EXAMPLE
        $session = Connect-MDEPortal -Method CredentialsTotp -Credential @{
            upn        = 'svc@contoso.com'
            password   = $password
            totpBase32 = 'JBSWY3DPEHPK3PXP'
        }

    .EXAMPLE
        $passkey = Get-Content ./passkey.json -Raw | ConvertFrom-Json
        $session = Connect-MDEPortal -Method Passkey -Credential @{
            upn     = 'svc@contoso.com'
            passkey = $passkey
        }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        # Iter 13.12: accept snake_case alias from ARM env var passthrough.
        [ValidateSet('CredentialsTotp', 'Passkey', 'credentials_totp', 'passkey')]
        [string] $Method,

        [Parameter(Mandatory)]
        [hashtable] $Credential,

        [string] $PortalHost = 'security.microsoft.com',

        [string] $TenantId,

        [switch] $Force
    )

    # Iter 13.12: normalize snake_case → PascalCase so downstream paths see one shape.
    $Method = switch ($Method) {
        'credentials_totp' { 'CredentialsTotp' }
        'passkey'          { 'Passkey' }
        default            { $Method }
    }

    $upn = $Credential.upn
    if (-not $upn) { throw "Credential hashtable must include 'upn'" }

    $cacheKey = "$upn::$PortalHost"

    # --- Cache check (skip if -Force). Evict at 50 min age. ---
    if (-not $Force.IsPresent -and $script:SessionCache.ContainsKey($cacheKey)) {
        $entry = $script:SessionCache[$cacheKey]
        $age = [datetime]::UtcNow - $entry.AcquiredUtc
        if ($age.TotalMinutes -lt 50) {
            Write-Verbose "Connect-MDEPortal: cache hit for $cacheKey (age $([int]$age.TotalMinutes)m)"
            return [pscustomobject]$entry
        }
        Write-Verbose "Connect-MDEPortal: cache stale for $cacheKey (age $([int]$age.TotalMinutes)m), re-authenticating"
        $script:SessionCache.Remove($cacheKey)
    }

    # --- Run the auth chain (single hop — Defender portal client_id mints
    # a portal-scoped ESTS cookie so sccauth drops directly, no second exchange). ---
    Write-Verbose "Connect-MDEPortal: authenticating $upn via $Method to $PortalHost"
    $auth = Get-EstsCookie -Method $Method -Credential $Credential -PortalHost $PortalHost -TenantId $TenantId

    # --- Cache (including credential ref for auto re-auth on 401) ---
    $entry = [ordered]@{
        Session     = $auth.Session
        Upn         = $upn
        PortalHost  = $PortalHost
        TenantId    = $auth.TenantId
        AcquiredUtc = $auth.AcquiredUtc
        # Credential stored in memory to support auto-refresh on 401.
        # Never persisted, never logged, cleared on process exit.
        _Method     = $Method
        _Credential = $Credential
    }
    $script:SessionCache[$cacheKey] = $entry
    return [pscustomobject]$entry
}
