function Connect-DefenderPortal {
    <#
    .SYNOPSIS
        L2 Defender — full unattended auth chain to security.microsoft.com.

    .DESCRIPTION
        Combines L1 Get-EntraEstsAuth (Entra-layer credentials/passkey + MFA +
        interrupts + form_post) with L2 Get-DefenderSccauth (sccauth + XSRF-TOKEN
        cookie verification + TenantContext auto-resolution).

        Sessions are cached in a module-scope dictionary keyed by "<upn>::<host>"
        for 50 minutes (sccauth lifetime ~1h with 10-min safety margin). Subsequent
        calls hit the cache; -Force bypasses it.

        The original credential hashtable is retained in-memory on the cache entry
        under `_Credential` + `_Method` so that Invoke-DefenderPortalRequest can
        silently re-auth on HTTP 401/440 without another human in the loop. It is
        never persisted, never logged, and cleared with the process.

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
        home-realm-discovery redirect. Auto-resolved via TenantContext otherwise.

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
        $session = Connect-DefenderPortal -Method CredentialsTotp -Credential @{
            upn        = 'svc@contoso.com'
            password   = $password
            totpBase32 = 'JBSWY3DPEHPK3PXP'
        }

    .EXAMPLE
        $passkey = Get-Content ./passkey.json -Raw | ConvertFrom-Json
        $session = Connect-DefenderPortal -Method Passkey -Credential @{
            upn     = 'svc@contoso.com'
            passkey = $passkey
        }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        # iter-13.12: accept snake_case alias from ARM env-var passthrough.
        [ValidateSet('CredentialsTotp', 'Passkey', 'credentials_totp', 'passkey')]
        [string] $Method,

        [Parameter(Mandatory)]
        [hashtable] $Credential,

        [string] $PortalHost = 'security.microsoft.com',

        [string] $TenantId,

        [switch] $Force
    )

    # iter-13.12: normalize snake_case → PascalCase so downstream paths see one shape.
    $Method = switch ($Method) {
        'credentials_totp' { 'CredentialsTotp' }
        'passkey'          { 'Passkey' }
        default            { $Method }
    }

    $upn = $Credential.upn
    if (-not $upn) { throw "Credential hashtable must include 'upn'" }

    $cacheKey = "$upn::$PortalHost"

    # iter-14.0 Phase 14B: per-Connect correlation GUID stitched onto every AI
    # emission for this auth chain (cache evict / cold-start ESTS / sccauth /
    # downstream Invoke-DefenderPortalRequest 401-reauth retries). Stamped on
    # the cache entry so downstream wrappers can reuse it.
    $correlationId = [Guid]::NewGuid().ToString()

    # --- Cache check (skip if -Force). Evict at 50 min age. ---
    if (-not $Force.IsPresent -and $script:SessionCache.ContainsKey($cacheKey)) {
        $entry = $script:SessionCache[$cacheKey]
        $age = [datetime]::UtcNow - $entry.AcquiredUtc
        if ($age.TotalMinutes -lt 50) {
            Write-Verbose "Connect-DefenderPortal: cache hit for $cacheKey (age $([int]$age.TotalMinutes)m)"
            if (Get-Command -Name Send-XdrAppInsightsCustomEvent -ErrorAction SilentlyContinue) {
                Send-XdrAppInsightsCustomEvent -EventName 'AuthChain.CacheHit' -OperationId $correlationId -Properties @{
                    Upn            = $upn
                    PortalHost     = $PortalHost
                    Method         = $Method
                    CacheAgeMinutes = [int]$age.TotalMinutes
                }
            }
            return [pscustomobject]$entry
        }
        Write-Verbose "Connect-DefenderPortal: cache stale for $cacheKey (age $([int]$age.TotalMinutes)m), re-authenticating"
        if (Get-Command -Name Send-XdrAppInsightsCustomEvent -ErrorAction SilentlyContinue) {
            Send-XdrAppInsightsCustomEvent -EventName 'AuthChain.CacheEvict' -OperationId $correlationId -Properties @{
                Upn            = $upn
                PortalHost     = $PortalHost
                Method         = $Method
                CacheAgeMinutes = [int]$age.TotalMinutes
                Reason         = 'age-exceeded'
            }
        }
        $script:SessionCache.Remove($cacheKey)
    }

    # --- L1: Entra-layer auth (returns session with ESTS cookies + portal session
    # cookies set, since the L1 form_post submission triggers the Defender OIDC
    # callback in the same session). ---
    Write-Verbose "Connect-DefenderPortal: authenticating $upn via $Method to $PortalHost"
    if (Get-Command -Name Send-XdrAppInsightsCustomEvent -ErrorAction SilentlyContinue) {
        Send-XdrAppInsightsCustomEvent -EventName 'AuthChain.Started' -OperationId $correlationId -Properties @{
            Upn        = $upn
            PortalHost = $PortalHost
            Method     = $Method
        }
    }
    $authStartedUtc = [datetime]::UtcNow
    try {
        $entraAuth = Get-EntraEstsAuth `
            -Method     $Method `
            -Credential $Credential `
            -ClientId   $script:DefenderClientId `
            -PortalHost $PortalHost `
            -TenantId   $TenantId

        # --- L2: verify Defender portal cookies + auto-resolve TenantId ---
        $sccauth = Get-DefenderSccauth -Session $entraAuth.Session -PortalHost $PortalHost -TenantId $TenantId
    } catch {
        # AADSTS error trapping: if the L1/L2 chain raised an AADSTS<code>
        # message, emit a high-fidelity AuthChain.AADSTSError event before the
        # rethrow so operators get a structured customDimension feed AND the
        # original throw still propagates to callers.
        $msg = if ($null -ne $_.Exception) { $_.Exception.Message } else { [string]$_ }
        if (Get-Command -Name Send-XdrAppInsightsCustomEvent -ErrorAction SilentlyContinue) {
            $aadstsCode = $null
            $stage      = 'unknown'
            if ($msg -match 'AADSTS(\d+)') {
                $aadstsCode = $Matches[1]
                $stage = if ($msg -match 'ProcessAuth') { 'mfa' }
                         elseif ($msg -match 'Authentication failed') { 'credentials' }
                         elseif ($msg -match 'Authorize endpoint') { 'authorize' }
                         else { 'unknown' }
            }
            $eventProps = @{
                Upn        = $upn
                PortalHost = $PortalHost
                Method     = $Method
                Stage      = $stage
                Message    = $msg
            }
            if ($aadstsCode) { $eventProps['AADSTSCode'] = $aadstsCode }
            Send-XdrAppInsightsCustomEvent -EventName 'AuthChain.AADSTSError' -OperationId $correlationId -Properties $eventProps
        }
        throw
    }

    $authLatencyMs = [int]([datetime]::UtcNow - $authStartedUtc).TotalMilliseconds

    # --- Cache (including credential ref for auto re-auth on 401) ---
    $entry = [ordered]@{
        Session       = $entraAuth.Session
        Upn           = $upn
        PortalHost    = $PortalHost
        TenantId      = $sccauth.TenantId
        AcquiredUtc   = $sccauth.AcquiredUtc
        CorrelationId = $correlationId
        # Credential stored in memory to support auto-refresh on 401/440.
        # Never persisted, never logged, cleared on process exit.
        _Method     = $Method
        _Credential = $Credential
    }
    $script:SessionCache[$cacheKey] = $entry

    if (Get-Command -Name Send-XdrAppInsightsCustomEvent -ErrorAction SilentlyContinue) {
        Send-XdrAppInsightsCustomEvent -EventName 'AuthChain.Completed' -OperationId $correlationId -Properties @{
            Upn        = $upn
            PortalHost = $PortalHost
            Method     = $Method
            TenantId   = [string]$sccauth.TenantId
            LatencyMs  = $authLatencyMs
        }
    }
    return [pscustomobject]$entry
}
