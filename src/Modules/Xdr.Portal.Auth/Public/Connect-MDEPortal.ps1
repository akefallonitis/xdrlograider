function Connect-MDEPortal {
    <#
    .SYNOPSIS
        Authenticates to the Microsoft Defender XDR portal and returns a reusable session.

    .DESCRIPTION
        Runs the full auth chain: login.microsoftonline.com → ESTSAUTHPERSISTENT →
        security.microsoft.com → sccauth + XSRF. Caches the resulting session in a
        module-scope dictionary keyed by UPN so subsequent calls within the same
        PowerShell process skip re-authentication.

        The cache entry is considered fresh for 50 minutes (sccauth lifetime ~1h with
        a 10-minute safety margin). After that the session is evicted and a fresh chain
        runs on the next call.

    .PARAMETER Method
        'CredentialsTotp' or 'Passkey'. Drives which fields are required on -Credential.

    .PARAMETER Credential
        Hashtable with auth material:
          CredentialsTotp: @{ upn = ''; password = ''; totpBase32 = '' }
          Passkey:         @{ upn = ''; passkey = <parsed JSON object> }

    .PARAMETER PortalHost
        Target portal hostname. Default: security.microsoft.com.

    .PARAMETER Force
        Bypass the cache and run a fresh auth chain.

    .OUTPUTS
        [pscustomobject] @{
            Session   = [WebRequestSession]
            Upn       = [string]
            PortalHost = [string]
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
        [ValidateSet('CredentialsTotp', 'Passkey')]
        [string] $Method,

        [Parameter(Mandatory)]
        [hashtable] $Credential,

        [string] $PortalHost = 'security.microsoft.com',

        [switch] $Force
    )

    $upn = $Credential.upn
    if (-not $upn) { throw "Credential hashtable must include 'upn'" }

    $cacheKey = "$upn::$PortalHost"

    # --- Cache check (skip if -Force). Pro-actively refresh at 50 min age. ---
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

    # --- Run the auth chain ---
    Write-Verbose "Connect-MDEPortal: authenticating $upn via $Method to $PortalHost"
    $session = Get-EstsCookie -Method $Method -Credential $Credential -PortalHost $PortalHost
    $exchange = Exchange-SccauthCookie -Session $session -PortalHost $PortalHost

    # --- Cache (including credential ref for auto re-auth on 401) ---
    $entry = [ordered]@{
        Session     = $exchange.Session
        Upn         = $upn
        PortalHost  = $PortalHost
        AcquiredUtc = $exchange.AcquiredUtc
        # Credential stored in memory to support auto-refresh on 401.
        # Never persisted, never logged, cleared on process exit.
        _Method     = $Method
        _Credential = $Credential
    }
    $script:SessionCache[$cacheKey] = $entry
    return [pscustomobject]$entry
}
