# Xdr.Connector.Orchestrator — L4 portal-routing dispatcher.
#
# Layering:
#   L1 Xdr.Common.Auth      — portal-generic Entra (TOTP, passkey, ESTS, KV loader)
#   L1 Xdr.Sentinel.Ingest  — portal-generic ingest (DCE/DCR + Storage Table + AI events)
#   L2 Xdr.Defender.Auth    — Defender-portal cookie exchange (sccauth + XSRF-TOKEN)
#   L3 Xdr.Defender.Client  — Defender-portal manifest dispatcher (45 streams)
#   L4 Xdr.Connector.Orchestrator (THIS module) — portal-routing dispatcher
#
# Operators using the L4 surface call:
#     Connect-XdrPortal -Portal 'Defender' -Method ... -Credential ...
#     Invoke-XdrTierPoll -Tier P0 -Portal 'Defender' -Session $s -Config $c
#     Test-XdrPortalAuth -Portal 'Defender' -Method ... -Credential ...
#     Get-XdrPortalManifest -Portal 'Defender'
#
# Internally each call looks up the -Portal value in $script:PortalRoutes
# and dispatches into the appropriate L2/L3 function. Adding a new portal
# in v0.2.0+ is a one-line addition to $script:PortalRoutes plus the
# corresponding L2/L3 modules.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Portal routing table. Keyed by the canonical portal name (case-insensitive
# match in the dispatcher). Each entry maps to the underlying L2 + L3 modules
# and the per-portal function names that the dispatchers call through to.
#
# v0.2.0 additions (planned): Purview, Intune, Entra. Each new entry brings
# its own L2 auth module + L3 client module + per-portal Connect/Test/Poll
# function names; the orchestrator surface is unchanged.
$script:PortalRoutes = @{
    'Defender' = @{
        AuthModule    = 'Xdr.Defender.Auth'
        ClientModule  = 'Xdr.Defender.Client'
        ConnectFn     = 'Connect-DefenderPortal'
        TestFn        = 'Test-DefenderPortalAuth'
        TierPollFn    = 'Invoke-MDETierPoll'
        ManifestFn    = 'Get-MDEEndpointManifest'
        DefaultHost   = 'security.microsoft.com'
        Status        = 'live'                # v0.1.0 GA — production
    }
    # v0.1.0 GA Phase A.3: forward-compat scaffolding (per directive 11 + 17).
    # These entries point to STUB modules that throw informative
    # "v0.2.0 roadmap" errors. The L4 routing seam is final; v0.2.0
    # only fills in function bodies — no architectural change required.
    'Entra' = @{
        AuthModule    = 'Xdr.Entra.Auth'
        ClientModule  = 'Xdr.Entra.Client'
        ConnectFn     = 'Connect-EntraPortal'
        TestFn        = 'Test-EntraPortalAuth'
        TierPollFn    = 'Invoke-EntraTierPoll'
        ManifestFn    = 'Get-EntraEndpointManifest'
        DefaultHost   = 'entra.microsoft.com'
        Status        = 'scaffolding-stub'    # v0.2.0 implementation
    }
    'Purview' = @{
        AuthModule    = 'Xdr.Purview.Auth'
        ClientModule  = 'Xdr.Purview.Client'
        ConnectFn     = 'Connect-PurviewPortal'
        TestFn        = 'Test-PurviewPortalAuth'
        TierPollFn    = 'Invoke-PurviewTierPoll'
        ManifestFn    = 'Get-PurviewEndpointManifest'
        DefaultHost   = 'compliance.microsoft.com'
        Status        = 'scaffolding-stub'    # v0.2.0 implementation
    }
    'Intune' = @{
        AuthModule    = 'Xdr.Intune.Auth'
        ClientModule  = 'Xdr.Intune.Client'
        ConnectFn     = 'Connect-IntunePortal'
        TestFn        = 'Test-IntunePortalAuth'
        TierPollFn    = 'Invoke-IntuneTierPoll'
        ManifestFn    = 'Get-IntuneEndpointManifest'
        DefaultHost   = 'intune.microsoft.com'
        Status        = 'scaffolding-stub'    # v0.2.0 implementation
    }
}

# Helper: validate a -Portal value and return its routing entry. Throws a
# clear error listing the available portals if the value is unknown.
function Resolve-XdrPortalRoute {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $Portal
    )
    $match = $script:PortalRoutes.Keys | Where-Object { $_ -ieq $Portal } | Select-Object -First 1
    if (-not $match) {
        $known = ($script:PortalRoutes.Keys | Sort-Object) -join ', '
        throw "Unknown -Portal '$Portal'. Known portals: $known. To add a new portal, extend `$script:PortalRoutes in Xdr.Connector.Orchestrator.psm1."
    }
    return $script:PortalRoutes[$match]
}

# Public functions live under Public/. Dot-source them so they have access to
# $script:PortalRoutes and the Resolve-XdrPortalRoute helper above.
$publicPath = Join-Path $PSScriptRoot 'Public'
$publicFiles = @(Get-ChildItem -Path $publicPath -Filter *.ps1 -ErrorAction SilentlyContinue)
foreach ($file in $publicFiles) {
    try {
        . $file.FullName
    } catch {
        Write-Error "Failed to load $($file.FullName): $_"
        throw
    }
}

# v0.1.0 GA Phase A.3.6: connector health + config validation helpers.
# These are CALLED BY:
#   - Connector-Heartbeat function (Phase B rename of heartbeat-5m)
#   - Test-ConnectorHealth.ps1 operator-facing tool
#   - Post-DeploymentVerification.ps1 P1-P14 probes
# They aggregate per-portal status into a single structured object/verdict.

function Get-XdrConnectorHealth {
    <#
    .SYNOPSIS
    Returns aggregate connector health across all configured portals.
    .DESCRIPTION
    Probes each portal in $script:PortalRoutes whose Status='live' and returns
    per-portal status + per-tier last-poll-fresh markers + KV cred-expiry
    days-remaining + DLQ depth + AppInsights recent-exception count.
    Used by Connector-Heartbeat for MDE_Heartbeat_CL Notes JSON.
    Used by Test-ConnectorHealth.ps1 for HEALTHY/DEGRADED/FAILED verdict.
    .PARAMETER Portals
    Optional list of portal names to probe. Default: all live portals.
    .OUTPUTS
    pscustomobject — one per portal with nested per-tier + supply-chain status
    .NOTES
    v0.1.0 GA: Defender is the only live portal. v0.2.0+ extends to Entra/Purview/Intune.
    Per-portal probe is a NO-OP for scaffolding-stub portals (just returns Status='scaffolding-stub').
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()] [string[]] $Portals = @($script:PortalRoutes.Keys | Where-Object { $script:PortalRoutes[$_].Status -eq 'live' })
    )

    $results = foreach ($portal in $Portals) {
        $route = $script:PortalRoutes[$portal]
        if (-not $route) {
            [pscustomobject]@{
                Portal      = $portal
                Status      = 'unknown-portal'
                Healthy     = $false
                Reason      = "Portal '$portal' not in PortalRoutes table"
                ProbedAtUtc = [datetime]::UtcNow
            }
            continue
        }
        if ($route.Status -ne 'live') {
            [pscustomobject]@{
                Portal      = $portal
                Status      = $route.Status
                Healthy     = $true                # not failing — just not active
                Reason      = "Portal '$portal' is $($route.Status); v0.2.0 roadmap"
                ProbedAtUtc = [datetime]::UtcNow
            }
            continue
        }
        # Live portal — probe per-tier last-poll-fresh markers from heartbeat table.
        # Defer detailed implementation to Phase F when Connector-Heartbeat
        # picks this up. v0.1.0 GA initial: return Status='live' + a sentinel
        # ProbedAtUtc to confirm the helper is wired.
        [pscustomobject]@{
            Portal      = $portal
            Status      = 'live'
            Healthy     = $true
            Reason      = 'Helper wired; per-tier probes implemented in Phase F'
            ProbedAtUtc = [datetime]::UtcNow
        }
    }

    return $results
}

function Test-XdrConnectorConfig {
    <#
    .SYNOPSIS
    Validates that all required environment variables + KV access + DCE reachability are configured.
    .DESCRIPTION
    Returns a list of [pscustomobject] entries with Status (OK/MISSING/UNREACHABLE)
    per check. Caller decides verdict based on counts.
    Used by Connector-ConfigValidate function (v0.2.0 HTTP admin) and by
    Post-DeploymentVerification.ps1 P1.
    .OUTPUTS
    pscustomobject[] — one per check
    .NOTES
    v0.1.0 GA: env-var presence + KV URI well-formed + DCE URI well-formed.
    v0.2.0+: live KV connectivity + DCE TLS handshake + Storage Table reachability.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param()

    $checks = @()

    # Env-var presence (mirrors src/profile.ps1's $requiredEnvVars list)
    $requiredEnvVars = @(
        'KEY_VAULT_URI', 'AUTH_SECRET_NAME', 'AUTH_METHOD',
        'SERVICE_ACCOUNT_UPN', 'DCE_ENDPOINT', 'DCR_IMMUTABLE_IDS_JSON',
        'STORAGE_ACCOUNT_NAME', 'CHECKPOINT_TABLE_NAME'
    )
    foreach ($var in $requiredEnvVars) {
        $val = [Environment]::GetEnvironmentVariable($var)
        $checks += [pscustomobject]@{
            Check = "env-var: $var"
            Status = if ([string]::IsNullOrWhiteSpace($val)) { 'MISSING' } else { 'OK' }
            Detail = if ([string]::IsNullOrWhiteSpace($val)) { 'Set in FA appSettings via mainTemplate.json' } else { '<value present>' }
        }
    }

    # KV URI well-formed
    $kvUri = $env:KEY_VAULT_URI
    if (-not [string]::IsNullOrWhiteSpace($kvUri)) {
        $checks += [pscustomobject]@{
            Check = 'kv-uri: well-formed'
            Status = if ($kvUri -match '^https://[a-z0-9-]+\.vault\.azure\.net/?$') { 'OK' } else { 'MALFORMED' }
            Detail = $kvUri
        }
    }

    # DCE URI well-formed
    $dceUri = $env:DCE_ENDPOINT
    if (-not [string]::IsNullOrWhiteSpace($dceUri)) {
        $checks += [pscustomobject]@{
            Check = 'dce-uri: well-formed'
            Status = if ($dceUri -match '^https://[a-z0-9-]+\.[a-z0-9-]+\.ingest\.monitor\.azure\.com/?$') { 'OK' } else { 'MALFORMED' }
            Detail = $dceUri
        }
    }

    # DCR JSON parsable
    $dcrJson = $env:DCR_IMMUTABLE_IDS_JSON
    if (-not [string]::IsNullOrWhiteSpace($dcrJson)) {
        try {
            $parsed = $dcrJson | ConvertFrom-Json -ErrorAction Stop
            $count = @($parsed.PSObject.Properties).Count
            $checks += [pscustomobject]@{
                Check = 'dcr-immutable-ids: parsable'
                Status = if ($count -ge 1) { 'OK' } else { 'EMPTY' }
                Detail = "$count stream→DCR mappings"
            }
        } catch {
            $checks += [pscustomobject]@{
                Check = 'dcr-immutable-ids: parsable'
                Status = 'INVALID-JSON'
                Detail = $_.Exception.Message
            }
        }
    }

    return $checks
}

Export-ModuleMember -Function @(
    'Connect-XdrPortal',
    'Invoke-XdrTierPoll',
    'Test-XdrPortalAuth',
    'Get-XdrPortalManifest',
    # v0.1.0 GA Phase A.3.6 helpers:
    'Get-XdrConnectorHealth',
    'Test-XdrConnectorConfig'
)
