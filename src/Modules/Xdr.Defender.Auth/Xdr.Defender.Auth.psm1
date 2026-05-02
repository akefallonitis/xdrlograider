# Xdr.Defender.Auth — L2 Defender-portal-specific auth + request layer.
#
# Architecture (iter-14.0):
#   L1 Xdr.Common.Auth   ← portal-generic Entra-layer primitives (REQUIRED)
#   L2 Xdr.Defender.Auth ← THIS MODULE (Defender-specific cookie exchange)
#   L2 v0.2.0 siblings   ← Xdr.Purview.Auth, Xdr.Intune.Auth, Xdr.Entra.Auth
#
# Defender portal constants (test-gated by tests/unit/AuthLayerBoundaries.Tests.ps1):
#   - Public client ID: 80ccca67-54bd-44ab-8625-4b79c4dc7775
#   - Default portal:   security.microsoft.com
#   - Session cookie:   sccauth
#   - CSRF cookie:      XSRF-TOKEN (header: X-XSRF-TOKEN, URL-decoded value)
#   - Tenant context:   /apiproxy/mtp/sccManagement/mgmt/TenantContext

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Module-level session cache. Keyed by "<upn>::<host>". Holds WebRequestSession
# (cookies) + metadata + cached credentials for auto-refresh on 401/440.
# Lifetime: ~50 min (sccauth ~1h with 10-min safety margin).
$script:SessionCache = @{}

# Module-scope counter surfaced to per-tier heartbeat via Get-XdrPortalRate429Count
# / Reset-XdrPortalRate429Count. Initialized unconditionally — module reimport
# resets the counter (which is what we want).
$script:Rate429Count = 0

# Proactive session-refresh threshold. Portal sccauth has an undocumented TTL
# around 4h; we force a fresh auth chain at 3h30m to avoid tripping reactive
# 401/440 mid-tier-poll.
$script:SessionMaxAgeMinutes = 210

# iter-13.15 Phase C — count-based rotation. Beyond the time-based 3h30m refresh,
# also rotate after a request-count threshold to bound replay-window risk if
# the FA process is compromised. Defense-in-depth.
$script:RequestCount = 0
$script:RequestCountRotationThreshold = 100

# Defender public-client app ID (Microsoft-owned). Defender portal RP-scopes
# the ESTS cookie issued under this client so the OIDC redirect chain naturally
# lands on security.microsoft.com without a second hop.
$script:DefenderClientId = '80ccca67-54bd-44ab-8625-4b79c4dc7775'

$privatePath = Join-Path $PSScriptRoot 'Private'
$publicPath  = Join-Path $PSScriptRoot 'Public'

$private = @(Get-ChildItem -Path $privatePath -Filter *.ps1 -ErrorAction SilentlyContinue)
$public  = @(Get-ChildItem -Path $publicPath  -Filter *.ps1 -ErrorAction SilentlyContinue)

foreach ($file in $private + $public) {
    try {
        . $file.FullName
    } catch {
        Write-Error "Failed to load $($file.FullName): $_"
        throw
    }
}

Export-ModuleMember -Function $public.BaseName
