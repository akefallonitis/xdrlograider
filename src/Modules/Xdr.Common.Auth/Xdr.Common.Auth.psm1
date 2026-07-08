# XdrLogRaider · Xdr.Common.Auth module
#
# Auth orchestration · per-Portal handler dispatch.
#
# Architecture: this module ORCHESTRATES auth (cache · single-flight · session lifecycle).
# Per-portal HTTP/cookie flow is registered via Register-XdrPortalHandler from each
# Xdr.<Portal>.Auth module. Common.Auth handles the cache + lease + dispatch invariants
# independently of any specific portal's auth wire format.
#
# Invariants:
#   - Cookie + KMSI 90d SSO is the steady-state path (T2 cache refresh) — full headless
#     login (T3) fires only on KMSI expiry (~4×/year per UPN).
#   - TOTP AND Passkey are BOTH first-class · operator picks at deploy time via createUiDefinition.
#   - MutexStore lease (Xdr.Common.Lease) gates concurrent T3 reauth across FA workers —
#     prevents N concurrent TOTP burns when L2 cache is cold at first deploy.

Set-StrictMode -Version Latest

# Per-Portal handler registry · populated by per-Portal modules at module-load
$script:PortalHandlers = @{}

function Register-XdrPortalHandler {
    <#
    .SYNOPSIS
    Per-Portal module calls this at module-load to register its auth handler.
    Handler signature: { param($Credentials, $TenantId) -> session hashtable }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Portal,
        [Parameter(Mandatory)] [scriptblock] $Handler
    )
    $script:PortalHandlers[$Portal] = $Handler
}

function Get-XdrCredentials {
    <#
    .SYNOPSIS
    Resolve credentials from KeyVault. Returns @{ UPN, Password, AuthMethod, TotpSeed/PasskeyPem }.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $upn = $env:XDRLR_SERVICE_ACCOUNT_UPN
    $authMethod = $env:XDRLR_AUTH_METHOD
    if (-not $upn -or -not $authMethod) {
        throw (New-XdrException -Type AuthChainBroken -Message 'XDRLR_SERVICE_ACCOUNT_UPN / XDRLR_AUTH_METHOD env missing' -Properties @{ FailureStage = 'Credentials' })
    }

    $creds = @{
        UPN = $upn
        AuthMethod = $authMethod
        Password = Get-XdrCachedSecret -SecretName 'ServicePassword' -L1TtlSeconds 1800
        # Explicit contract: the Defender auth handler (Connect-DefenderPortal → Get-XdrEntraEstsAuth) reads
        # TenantId for Decision-16 resolution. Set it (env, or $null → the auth flow resolves via ESTS JWT /
        # tenant-context fallback) so the key always exists and dot/indexer reads never miss.
        TenantId = $env:XDRLR_TENANT_ID
    }

    if ($authMethod -eq 'TOTP') {
        $creds.TotpSeed = Get-XdrCachedSecret -SecretName 'TotpSecret' -L1TtlSeconds 1800
    } elseif ($authMethod -eq 'Passkey') {
        $creds.PasskeyPem = Get-XdrCachedSecret -SecretName 'PasskeyPem' -L1TtlSeconds 1800
    }

    return $creds
}

function ConvertTo-XdrSessionHashtable {
    <#
    .SYNOPSIS
    Normalize whatever a per-portal auth handler emitted into a PLAIN [hashtable] (or $null).

    .DESCRIPTION
    A handler (or a helper it calls) can leak stray pipeline output — making the return an array
    [leak,…,sessionHashtable] — or return a [pscustomobject] / [ordered] dictionary. Downstream
    Connect-XdrPortal does `$session.ContainsKey(...)` (ONLY [hashtable] has ContainsKey; an
    OrderedDictionary has .Contains, a pscustomobject has neither) and `$session.Portal = …`. Under
    StrictMode -Version Latest those throw PropertyNotFoundException on the wrong shape (the recurring
    "property 'Portal' cannot be found on this object"). This collapses an array to its last
    dict/object element, then rebuilds ANY non-Hashtable into a plain [hashtable] so all downstream
    member access is safe regardless of what the handler returned. Returns $null for null/empty input.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter()] $InputObject)

    $session = $InputObject
    if ($session -is [System.Array]) {
        $session = @($session | Where-Object {
            $_ -is [System.Collections.IDictionary] -or $_ -is [System.Management.Automation.PSCustomObject]
        }) | Select-Object -Last 1
    }
    if ($null -eq $session) { return $null }
    if ($session -is [hashtable]) { return $session }

    $rebuilt = @{}
    if ($session -is [System.Collections.IDictionary]) {
        foreach ($k in $session.Keys) { $rebuilt[$k] = $session[$k] }
    } else {
        foreach ($prop in @($session.PSObject.Properties)) { $rebuilt[$prop.Name] = $prop.Value }
    }
    return $rebuilt
}

function Connect-XdrPortal {
    <#
    .SYNOPSIS
    Unified entry point · returns a Session for the requested Portal.
    L1 cache → L2 Storage Table → fresh auth (with L3 single-flight gate).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $Portal,
        [switch] $Force
    )

    $startedUtc = [DateTime]::UtcNow
    Track-XdrEvent -Name 'Auth.Connect.Started' -Properties @{ Portal = $Portal; Force = $Force.IsPresent }

    try {
        $upn = $env:XDRLR_SERVICE_ACCOUNT_UPN

        # 1. L1/L2 cache hit (unless forced)
        if (-not $Force) {
            # AU5 (audit 2026-06-12) · normalize at the cache-read SOURCE — a cache layer can leak a stray pipeline
            # object, making this an [Object[]]. Without this the array reaches `Test-XdrSessionAlive -Session
            # [hashtable]` AND the `return $cached` → the caller's `-Session [hashtable]` binding throws
            # ParameterBindingArgumentTransformationException (the live intermittent poll failure · 62903 lifetime).
            # Mirrors the fresh path's iter#18 handler-normalize; collapses an array to its session element.
            $cached = ConvertTo-XdrSessionHashtable -InputObject (Get-XdrCachedSession -Portal $Portal -UPN $upn)
            if ($cached) {
                # Optional liveness probe
                if (Test-XdrSessionAlive -Portal $Portal -Session $cached) {
                    Track-XdrEvent -Name 'Auth.Connect.Cached' -Properties @{ Portal = $Portal; DurationMs = ([int]((([DateTime]::UtcNow) - $startedUtc).TotalMilliseconds)) }
                    return $cached
                }
                # Cache stale · fall through to fresh auth
                Invalidate-XdrCache -L1KeyPrefix "session::$Portal::"
            }
        }

        # 2. Single-flight L3 lease (prevents concurrent reauth)
        # iter#16: Azure Blob Lease fixed-duration max is 60s (90 was REJECTED: "LeaseTtlSeconds must be
        # between 15 and 60") which failed the auth single-flight on every attempt. 60s covers a full
        # T3 OAuth (~5-10s); if it ever expires mid-flight another worker simply re-acquires (no deadlock).
        $leaseKey = "auth::$Portal::$upn"
        $leaseToken = Lock-XdrSingleFlight -ResourceKey $leaseKey -LeaseTtlSeconds 60
        if (-not $leaseToken) {
            # Another worker is reauthing · brief wait then retry cache.
            Start-Sleep -Seconds 5
            # AU5 (audit 2026-06-12) · normalize at the cache-read SOURCE — a cache layer can leak a stray pipeline
            # object, making this an [Object[]]. Without this the array reaches `Test-XdrSessionAlive -Session
            # [hashtable]` AND the `return $cached` → the caller's `-Session [hashtable]` binding throws
            # ParameterBindingArgumentTransformationException (the live intermittent poll failure · 62903 lifetime).
            # Mirrors the fresh path's iter#18 handler-normalize; collapses an array to its session element.
            $cached = ConvertTo-XdrSessionHashtable -InputObject (Get-XdrCachedSession -Portal $Portal -UPN $upn)
            # AU2 (audit 2026-06-12) · the contended re-read MUST be liveness-checked, exactly like the primary path
            # above. Returning $cached unconditionally could hand back the SAME dead session that triggered the peer's
            # reauth (the peer may still be mid-T2/T3 > the 5s wait), causing repeated 440s + a re-populated dead L1.
            # If it's not yet a live re-minted session, fail loud (AuthChainBroken) so this cycle retries cleanly.
            if ($cached -and (Test-XdrSessionAlive -Portal $Portal -Session $cached)) { return $cached }
            throw (New-XdrException -Type AuthChainBroken -Message "Single-flight contention on $Portal · peer worker reauth still pending" -Properties @{ Portal = $Portal; FailureStage = 'Lease' })
        }

        try {
            # 3. Per-Portal handler dispatch
            if (-not $script:PortalHandlers.ContainsKey($Portal)) {
                throw (New-XdrException -Type AuthChainBroken -Message "No handler registered for Portal=$Portal · Phase 1.4 module not loaded?" -Properties @{ Portal = $Portal; FailureStage = 'HandlerMissing' })
            }
            $handler = $script:PortalHandlers[$Portal]
            $creds = Get-XdrCredentials
            # -Force (self-heal reauth) must reach the per-portal handler so its OWN inner T1 cache-hit is bypassed:
            # Connect-XdrPortal's -Force only skips the OUTER cache (above). Without this the handler re-reads L1/L2 and
            # returns the SAME stale session (the empty-UPN self-heal path can't drop the L2 row) → re-loops the 440.
            if ($Force) { $creds['__ForceFresh'] = $true }

            # Call per-Portal Connect handler · returns session hashtable.
            # iter#18: normalize the handler return to a PLAIN [hashtable] before any member access —
            # collapses pipeline-leak arrays · rebuilds pscustomobject/ordered → hashtable. This is the
            # permanent fix for the recurring "property 'Portal' cannot be found" PropertyNotFoundException.
            $session = ConvertTo-XdrSessionHashtable -InputObject (& $handler $creds)

            # Validate session shape · cookie OR bearer (different per-portal · STEP 2.A.10)
            #   Defender / Purview  → Sccauth (cookie family)
            #   Entra / Intune / SecurityCopilot → AccessToken (OAuth bearer)
            if (-not $session) {
                throw (New-XdrException -Type AuthChainBroken -Message "Per-Portal handler returned null session" -Properties @{ Portal = $Portal; FailureStage = 'HandlerReturn' })
            }
            $hasCookie = $session.ContainsKey('Sccauth') -or $session.ContainsKey('Cookie')
            $hasBearer = $session.ContainsKey('AccessToken')
            if (-not ($hasCookie -or $hasBearer)) {
                throw (New-XdrException -Type AuthChainBroken -Message "Per-Portal handler returned invalid session (missing Sccauth/Cookie AND AccessToken)" -Properties @{ Portal = $Portal; FailureStage = 'HandlerReturn'; SessionKeys = ($session.Keys -join ',') })
            }

            # 4. Persist to L1/L2
            $session.SavedUtc = (Get-Date).ToUniversalTime().ToString('o')
            $session.Portal = $Portal
            # | Out-Null belt-and-suspenders (WS4.3): Save-XdrSession is now void at the source, but this fresh-auth
            # path is the one that leaked a stray [bool] into the return (@($true,$session) → [Object[]] → consumer
            # -Session [hashtable] bind throws). Suppressing here too keeps the return a single hashtable even if a
            # future edit re-introduces a Save-XdrSession return. Defense-in-depth for a much-recurring leak class.
            Save-XdrSession -Portal $Portal -UPN $upn -Session $session | Out-Null

            Track-XdrEvent -Name 'Auth.Connect.Succeeded' -Properties @{ Portal = $Portal; DurationMs = ([int]((([DateTime]::UtcNow) - $startedUtc).TotalMilliseconds)) }
            return $session
        } finally {
            Unlock-XdrSingleFlight -ResourceKey $leaseKey -LeaseToken $leaseToken | Out-Null
        }
    } catch {
        Track-XdrException -Exception $_.Exception -Properties @{ Portal = $Portal; FailureStage = (Get-XdrErrorClass -Exception $_.Exception) }
        throw
    }
}

function Get-XdrSession {
    <#
    .SYNOPSIS
    Read-only session lookup (NO fresh auth · returns $null on miss).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)] [string] $Portal)
    return Get-XdrCachedSession -Portal $Portal -UPN $env:XDRLR_SERVICE_ACCOUNT_UPN
}

function Save-XdrSession {
    <#
    .SYNOPSIS
    Write session to L1/L2 (used after fresh auth · also by Refresh path).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Portal,
        [Parameter(Mandatory)] [string] $UPN,
        [Parameter(Mandatory)] [hashtable] $Session
    )
    # VOID by contract (WS4.3 root fix). Set-XdrCachedSession returns the L2-write [bool] $resp.Success.
    # Connect-XdrPortal (fresh-auth path) and the OAuthBearer handler BOTH call Save-XdrSession UNCAPTURED, so
    # propagating that bool leaks it into the caller's pipeline → `$session` becomes @($true, <hashtable>) =
    # [Object[]] → the downstream `-Session [hashtable]` bind throws ParameterBindingArgumentTransformationException
    # (live-observed 2026-06-14 · GetEffectiveTenantGroup · the fresh-auth lease winner during reset+reauth cache
    # churn). A save is a side-effect; write failures are already logged LOUD inside Set-XdrCachedSession. No caller
    # captures this return (verified), so suppressing it is safe and removes the leak at its source for every caller.
    $null = Set-XdrCachedSession -Portal $Portal -UPN $UPN -SessionData $Session
}

function Test-XdrSessionAlive {
    <#
    .SYNOPSIS
    Lightweight liveness check · returns $true if session looks usable.
    Defers full HTTP ping to per-Portal Client modules (avoids tight coupling).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $Portal,
        [Parameter(Mandatory)] [hashtable] $Session
    )
    # Indexer (not dot): a cached session may be partial; dot-access of a missing key throws under
    # StrictMode Latest, the indexer returns $null so the -not/if logic behaves correctly.
    # D5 session-shape symmetry: the credential-presence guard MUST match Connect-XdrPortal's contract
    # ($hasCookie = Sccauth OR Cookie · $hasBearer = AccessToken). The prior `-not $Session['Cookie']`
    # rejected a Sccauth-only cookie session AND every bearer (AccessToken) session → liveness FALSE →
    # reauth-every-cycle for any portal/path that doesn't also set 'Cookie' (latent for the 4 bearer portals).
    if (-not ($Session['Cookie'] -or $Session['Sccauth'] -or $Session['AccessToken'])) { return $false }

    # DYNAMIC TTL · prefer the REAL cookie expiry the auth module captured (session.ExpiresUtc — the
    # earliest of the sccauth Set-Cookie Expires and the ESTSAUTHPERSISTENT/KMSI JWT expiry) over any
    # hardcoded sliding window. Treat the session as dead 5 min BEFORE that instant so an in-flight poll
    # never races the expiry. Portal-agnostic (Defender + every future portal feed their own ExpiresUtc).
    # Falls back to the SavedUtc age heuristic only for older cache rows written before ExpiresUtc existed.
    try {
        if ($Session['ExpiresUtc']) {
            $expires = (ConvertTo-XdrUtc $Session['ExpiresUtc'])
            return ([DateTime]::UtcNow) -lt $expires.AddMinutes(-5)
        }
        if (-not $Session['SavedUtc']) { return $false }
        $saved = (ConvertTo-XdrUtc $Session['SavedUtc'])
        $ageMin = ([DateTime]::UtcNow - $saved).TotalMinutes
        if ($Session['KmsiActive']) { return $ageMin -lt (90 * 24 * 60) }  # 90d KMSI fallback
        # sccauth fallback floor · configurable via XDRLR_SESSION_TTL_MINUTES (default 110 · same as Get-XdrCookieExpiry)
        $ttlMin = if ($env:XDRLR_SESSION_TTL_MINUTES -match '^\d+$') { [int]$env:XDRLR_SESSION_TTL_MINUTES } else { 110 }
        return $ageMin -lt $ttlMin
    } catch {
        return $false
    }
}

Export-ModuleMember -Function Connect-XdrPortal, Get-XdrSession, Save-XdrSession, Test-XdrSessionAlive, Register-XdrPortalHandler, Get-XdrCredentials, ConvertTo-XdrSessionHashtable
