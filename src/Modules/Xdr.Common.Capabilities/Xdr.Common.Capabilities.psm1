# XdrLogRaider · Xdr.Common.Capabilities module
#
# Purpose: dynamic tenant context + product/license discovery at FA cold-start.
#
# Why dynamic discovery (not static config):
#   - The same connector must work across operator tenants with different Defender SKUs.
#   - A manifest entry that requires MDI (RequiresProducts=@('MDI')) on a tenant that doesn't
#     have MDI must be skipped — not failed-open, not failed-closed, just not scheduled.
#   - The probe is single-endpoint per portal: /apiproxy/mtp/sccManagement/mgmt/TenantContext
#     returns ALL product flags (IsMdatpActive, IsMdiActive, IsMdcActive, …) in one response.
#     (LIVE-PROVEN 2026-06-04: the canonical path is sccManagement/mgmt/TenantContext per OpenAPI
#     Configuration.GetTenantContext · the prior '/configuration/tenantContext' 404'd → products=[(none)].)
#
# Cache strategy (NOT a tier hierarchy — distinct primitives per access pattern):
#   - HotCache (module-scoped in-memory) for hot reads within the same FA worker lifecycle.
#   - StateStore (TenantContext + TenantCapabilities tables) for cross-cold-start persistence.
#     PartitionKey = Portal · RowKey = TenantId · 24h TTL on `UpdatedUtc`.
#
# CRITICAL: profile.ps1 calls Get-XdrTenantCapabilities at cold-start. The module HotCache
# holds the result. TimerTrigger (XdrDefenderRefresh) re-calls Get-XdrTenantCapabilities
# rather than reading from profile's $script: scope (different runspace · different scope).
# This closes the prior-design F1 gap where Refresh's $script:TenantCapabilities was never
# populated and the R3 gate fail-opened.

Set-StrictMode -Version Latest

# ─── Module-scoped state ───────────────────────────────────────────────────────
$script:CapabilitiesCache = @{}    # keyed "<portal>::<tenantId>"
$script:CapabilitiesTtlSeconds = 86400  # 24h
$script:CapabilitiesMutex = [System.Threading.Mutex]::new($false, 'XdrLogRaider.Capabilities.Mutex')

# Per-portal probe endpoints (single endpoint returns both context + capability flags)
# P2 single-SoT consolidation (2026-06-14): the per-portal tenant-context probe endpoints moved INTO the Portal
# Registry (Xdr.Common.Runtime · $XdrPortalRegistry[Portal].ProbeEndpoint). This module reads them via the exported
# Get-XdrPortalConfig, so there is ONE portal-config source (transport + dispatch + probe). Defender's probe is
# LIVE-PROVEN (mtp/sccManagement/mgmt/TenantContext → 200 + Is*Active flags). Onboarding a portal = ONE registry row.

# Map TenantContext probe response flags to product codes the manifest RequiresProducts uses
function script:ConvertTo-XdrProductList {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $TenantContext)

    $products = [System.Collections.Generic.List[string]]::new()
    # StrictMode-SAFE flag reads: $TenantContext is `ConvertFrom-Json -AsHashtable`; DOT-access of an ABSENT flag throws
    # PropertyNotFoundException under StrictMode (a tenant LACKING a product OMITS its flag) — which escaped
    # Get-XdrTenantCapabilities → fail-open (products=$null → R3 let ALL ops through). Read via the indexer with a
    # Contains guard so an absent flag resolves to $false (not a throw). Non-dictionary input (raw-string parse-fail) → {}.
    $ctx = if ($TenantContext -is [System.Collections.IDictionary]) { $TenantContext } else { @{} }
    # Defender XDR product family (each flag → one product code in manifest taxonomy)
    if ($ctx.Contains('IsMdatpActive') -and $ctx['IsMdatpActive'])       { $products.Add('MDE') }       # Defender for Endpoint
    if ($ctx.Contains('IsOatpActive')  -and $ctx['IsOatpActive'])        { $products.Add('MDO') }       # Defender for Office 365
    if (($ctx.Contains('IsItpActive') -and $ctx['IsItpActive']) -or ($ctx.Contains('IsMdiActive') -and $ctx['IsMdiActive'])) { $products.Add('MDI') }  # Defender for Identity
    if ($ctx.Contains('IsMdcActive')   -and $ctx['IsMdcActive'])         { $products.Add('MDC') }       # Defender for Cloud
    if ($ctx.Contains('IsMapgActive')  -and $ctx['IsMapgActive'])        { $products.Add('MAPG') }      # Attack Path Graph (XSPM input)
    if ($ctx.Contains('IsAadIpActive') -and $ctx['IsAadIpActive'])       { $products.Add('AAD-IP') }    # Entra Identity Protection
    if ($ctx.Contains('IsDlpActive')   -and $ctx['IsDlpActive'])         { $products.Add('DLP') }       # Purview DLP
    if ($ctx.Contains('IsIrmActive')   -and $ctx['IsIrmActive'])         { $products.Add('IRM') }       # Insider Risk
    if ($ctx.Contains('IsSentinelActive') -and $ctx['IsSentinelActive']) { $products.Add('Sentinel') }

    # MDVM bundled with MDE P2; XSPM requires MAPG. Document the inference inline.
    if ($products -contains 'MDE') { $products.Add('MDVM') }
    if ($products -contains 'MDE' -and $products -contains 'MAPG') { $products.Add('XSPM') }
    if ($ctx.Contains('IsMtpEligible') -and $ctx['IsMtpEligible']) { $products.Add('MTP') }
    if ($ctx.Contains('IsSecurityCopilotHasLicense') -and $ctx['IsSecurityCopilotHasLicense']) { $products.Add('SecurityCopilot') }
    # NOTE: MCAS (Defender for Cloud Apps) has no authoritative active flag in TenantContext, and MTO (Multi-Tenant
    # Org) is a cross-tenant construct with no single-tenant flag — so neither is derived here. Ops requiring them
    # FAIL-OPEN at Test-XdrRequiresProducts (attempt -> runtime capability-absent posture+backoff), NEVER a dead gate.
    # Keep $script:XdrDerivableProducts (below) in sync with the product codes Add()ed in this function.

    return $products.ToArray()
}

# The set of products THIS deriver can authoritatively produce (a direct tenant-context flag exists). Test-Xdr-
# RequiresProducts gates an op only on products in THIS set; a required product OUTSIDE it (e.g. MCAS, MTO) is
# NON-derivable -> the gate fails-open -> the op attempts and the runtime postures on the real HTTP response. This
# makes a "RequiresProducts value the deriver can't produce" structurally impossible to become a permanent dead gate.
$script:XdrDerivableProducts = @('MDE','MDO','MDI','MDC','MAPG','AAD-IP','DLP','IRM','Sentinel','MDVM','XSPM','MTP','SecurityCopilot')

# ─── PRIVATE · StateStore I/O via HttpClient REST (Xdr.Common.Storage) ────────
# Partition strategy LOCKED: PartitionKey=Portal, RowKey=TenantId (multi-tenant ready).
function script:Read-XdrCapabilitiesState {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$Portal, [string]$TenantId, [string]$TableName)

    try {
        $result = Get-XdrTableEntity -TableName $TableName -PartitionKey $Portal -RowKey $TenantId
        if (-not $result.Found) { return $null }
        $row = $result.Entity

        # 24h TTL
        if ($row.UpdatedUtc) {
            try {
                $age = [DateTime]::UtcNow - (ConvertTo-XdrUtc $row.UpdatedUtc)
                if ($age.TotalSeconds -gt $script:CapabilitiesTtlSeconds) { return $null }
            } catch { return $null }
        }

        # B-25 trap guard: DataJson is always a string from REST.
        if ($row.DataJson) {
            $jsonText = $row.DataJson
            if ($jsonText -isnot [string]) { $jsonText = [string]$jsonText }
            return $jsonText | ConvertFrom-Json -AsHashtable -Depth 25
        }
        return $null
    } catch {
        Write-Warning "[Capabilities] StateStore read failed for $Portal/$TenantId/$TableName : $($_.Exception.Message)"
        return $null
    }
}

function script:Write-XdrCapabilitiesState {
    [CmdletBinding()]
    param([string]$Portal, [string]$TenantId, [string]$TableName, [hashtable]$Data)

    try {
        # B-25 guard: Data is always a hashtable here; serialize once.
        if ($Data -isnot [hashtable] -and $Data -isnot [System.Collections.IDictionary]) {
            throw "Write-XdrCapabilitiesState: Data must be hashtable (got $($Data.GetType().FullName))"
        }
        $props = @{
            DataJson   = ($Data | ConvertTo-Json -Depth 10 -Compress)
            UpdatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        }
        $resp = Set-XdrTableEntity -TableName $TableName -PartitionKey $Portal -RowKey $TenantId -Properties $props
        return $resp.Success
    } catch {
        Write-Warning "[Capabilities] StateStore write failed for $Portal/$TenantId/$TableName : $($_.Exception.Message)"
        return $false
    }
}

# ─── PUBLIC · Get-XdrTenantContext ─────────────────────────────────────────────
function Get-XdrTenantContext {
    <#
    .SYNOPSIS
    Probe per-portal tenant context endpoint · HotCache → StateStore → live probe.
    Cache 24h. Returns null if probe fails (caller decides degradation).

    .OUTPUTS
    Hashtable @{ TenantId; DisplayName; EnvironmentName; GeoRegion; AccountType; UpdatedUtc; RawProbeResponse }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $Portal,
        [switch] $Force
    )

    # F1.4d/P2 · registry-driven · the Portal Registry (Xdr.Common.Runtime · Get-XdrPortalConfig) is the ONE
    # portal-config SoT (transport + dispatch + probe). A portal with a registered ProbeEndpoint is onboardable as
    # DATA; throw the onboard-by-DATA contract for an unregistered portal (not a silent default).
    $portalCfg = try { Get-XdrPortalConfig -Portal $Portal } catch { $null }
    if (-not $portalCfg -or -not $portalCfg['ProbeEndpoint']) {
        throw "Get-XdrTenantContext: Portal '$Portal' has no registered probe endpoint (add a Portal Registry row with ProbeEndpoint — DATA, not an engine edit)"
    }

    Track-XdrEvent -Name 'PortalCapabilities.TenantContext.Started' -Properties @{ Portal = $Portal; Force = $Force.IsPresent }

    # Need a session to derive TenantId from the cookie/bearer
    $session = $null
    try {
        $session = Connect-XdrPortal -Portal $Portal
    } catch {
        Track-XdrException -Exception $_.Exception -Properties @{ Portal = $Portal; Stage = 'TenantContextSessionResolve' }
        return $null
    }
    if (-not $session -or -not $session.TenantId) {
        Track-XdrEvent -Name 'PortalCapabilities.TenantContext.Failed' -Properties @{ Portal = $Portal; Reason = 'NoSessionOrTenantId' }
        return $null
    }
    $tenantId = $session.TenantId

    # HotCache check
    $cacheKey = "$Portal::$tenantId"
    if (-not $Force.IsPresent -and $script:CapabilitiesCache.ContainsKey($cacheKey)) {
        $cached = $script:CapabilitiesCache[$cacheKey]
        try {
            $age = [DateTime]::UtcNow - (ConvertTo-XdrUtc $cached.UpdatedUtc)
            if ($age.TotalSeconds -lt $script:CapabilitiesTtlSeconds) { return $cached }
        } catch { <# HotCache UpdatedUtc parse/compare fail → treat as cache miss, fall through to StateStore · INTENTIONAL-FAIL-SAFE LOCK 9 #> }
    }

    # StateStore check
    if (-not $Force.IsPresent) {
        $state = Read-XdrCapabilitiesState -Portal $Portal -TenantId $tenantId -TableName 'TenantContext'
        if ($state) {
            $script:CapabilitiesCache[$cacheKey] = $state
            return $state
        }
    }

    # Live probe · endpoint from the Portal Registry (validated above · $portalCfg set at the registry-driven guard)
    $endpoint = $portalCfg['ProbeEndpoint']
    if (-not $endpoint) {
        Track-XdrEvent -Name 'PortalCapabilities.TenantContext.Failed' -Properties @{ Portal = $Portal; Reason = 'NoProbeEndpoint' }
        return $null
    }

    try {
        $entry = @{ Portal = $Portal; SubPortal = $endpoint.SubPortal; Path = $endpoint.Path; Method = $endpoint.Method }
        $url = New-XdrRequestUrl -Entry $entry
        $response = Invoke-XdrPortalHttp -Session $session -Method $endpoint.Method -Url $url

        # $response.Body is `ConvertFrom-Json -AsHashtable` (Invoke-XdrPortalHttp) → hashtable, OR the raw string
        # if the body wasn't JSON. DOT-access of an absent key throws PropertyNotFoundException under StrictMode
        # (this killed R3 capability discovery every cold-start — the real tenantContext response has none of
        # these keys). Guard on IDictionary, then read via the $null-safe indexer; absent keys → $null, not throw.
        $body = $response.Body
        $bodyIsDict = $body -is [System.Collections.IDictionary]
        $context = @{
            TenantId         = $tenantId
            DisplayName      = if ($bodyIsDict) { $body['DisplayName'] ?? $body['organizationName'] } else { $null }
            EnvironmentName  = if ($bodyIsDict) { $body['EnvironmentName'] } else { $null }
            GeoRegion        = if ($bodyIsDict) { $body['GeoRegion'] } else { $null }
            AccountType      = if ($bodyIsDict) { $body['AccountType'] } else { $null }
            DefaultDomain    = if ($bodyIsDict) { $body['DefaultDomain'] ?? $body['defaultDomain'] } else { $null }
            CountryCode      = if ($bodyIsDict) { $body['CountryCode'] ?? $body['countryLetterCode'] } else { $null }
            UpdatedUtc       = (Get-Date).ToUniversalTime().ToString('o')
            RawProbeResponse = $body
        }

        $script:CapabilitiesCache[$cacheKey] = $context
        $null = Write-XdrCapabilitiesState -Portal $Portal -TenantId $tenantId -TableName 'TenantContext' -Data $context

        Track-XdrEvent -Name 'PortalCapabilities.TenantContext.Succeeded' -Properties @{
            Portal = $Portal
            TenantId = $tenantId
            EnvironmentName = $context.EnvironmentName
            GeoRegion = $context.GeoRegion
        }
        return $context
    } catch {
        Track-XdrException -Exception $_.Exception -Properties @{ Portal = $Portal; Stage = 'TenantContextProbe' }
        Track-XdrEvent -Name 'PortalCapabilities.TenantContext.Failed' -Properties @{ Portal = $Portal; Reason = $_.Exception.Message }
        return $null
    }
}

# ─── PUBLIC · Get-XdrTenantCapabilities ────────────────────────────────────────
function Get-XdrTenantCapabilities {
    <#
    .SYNOPSIS
    Derive product/license list from TenantContext probe response. 24h TTL.

    .OUTPUTS
    Hashtable @{ TenantId; Products = @('MDE','MDO',...); ActiveMtpWorkloads; UpdatedUtc }
    Returns $null on probe failure.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $Portal,
        [switch] $Force
    )

    # F1.4d/P2 · registry-driven (the ONE portal-config SoT · matches Get-XdrTenantContext): fail-fast onboard-by-DATA
    # contract for a portal without a registered probe endpoint.
    $capCfg = try { Get-XdrPortalConfig -Portal $Portal } catch { $null }
    if (-not $capCfg -or -not $capCfg['ProbeEndpoint']) {
        throw "Get-XdrTenantCapabilities: Portal '$Portal' has no registered probe endpoint (add a Portal Registry row with ProbeEndpoint — DATA, not an engine edit)"
    }

    Track-XdrEvent -Name 'PortalCapabilities.Discovery.Started' -Properties @{ Portal = $Portal; Force = $Force.IsPresent }

    $context = Get-XdrTenantContext -Portal $Portal -Force:$Force
    if (-not $context) {
        Track-XdrEvent -Name 'PortalCapabilities.Discovery.Failed' -Properties @{ Portal = $Portal; Reason = 'TenantContextProbeFailed' }
        return $null
    }

    # iter#16 StrictMode guard: $context can arrive from the StateStore cache (TenantContext table) as a
    # hashtable/PSObject that does NOT carry the transient RawProbeResponse. A missing-property access
    # throws under StrictMode (was: "property 'RawProbeResponse' cannot be found on this object"), which
    # crashed R3 discovery. Extract RawProbeResponse + ActiveMtpWorkloads defensively for both shapes.
    $rawProbe = $null
    if (($context -is [hashtable]) -or ($context -is [System.Collections.IDictionary])) {
        if ($context.Contains('RawProbeResponse')) { $rawProbe = $context['RawProbeResponse'] }
    } elseif ($context.PSObject -and ($context.PSObject.Properties.Name -contains 'RawProbeResponse')) {
        $rawProbe = $context.RawProbeResponse
    }

    $products = ConvertTo-XdrProductList -TenantContext $rawProbe

    $mtpWorkloads = @()
    if ($null -ne $rawProbe) {
        if (($rawProbe -is [hashtable]) -or ($rawProbe -is [System.Collections.IDictionary])) {
            if ($rawProbe.Contains('ActiveMtpWorkloads')) { $mtpWorkloads = @($rawProbe['ActiveMtpWorkloads']) }
        } elseif ($rawProbe.PSObject -and ($rawProbe.PSObject.Properties.Name -contains 'ActiveMtpWorkloads')) {
            $mtpWorkloads = @($rawProbe.ActiveMtpWorkloads)
        }
    }

    $capabilities = @{
        TenantId           = $context.TenantId
        Products           = $products
        ActiveMtpWorkloads = $mtpWorkloads
        UpdatedUtc         = (Get-Date).ToUniversalTime().ToString('o')
    }

    $null = Write-XdrCapabilitiesState -Portal $Portal -TenantId $context.TenantId -TableName 'TenantCapabilities' -Data $capabilities

    # Module HotCache holds capabilities too (so XdrDefenderRefresh can call Get-XdrTenantCapabilities
    # in a fresh runspace and get the cached value — closes prior $script:TenantCapabilities scope gap).
    $script:CapabilitiesCache["$Portal::$($context.TenantId)::capabilities"] = $capabilities

    Track-XdrEvent -Name 'PortalCapabilities.Discovery.Succeeded' -Properties @{
        Portal = $Portal
        TenantId = $context.TenantId
        ProductCount = $products.Count
        Products = ($products -join ',')
    }

    return $capabilities
}

# ─── PUBLIC · Test-XdrRequiresProducts (R3 gate) ───────────────────────────────
function Test-XdrRequiresProducts {
    <#
    .SYNOPSIS
    Test whether tenant has at least one of the products an Operation requires.

    .OUTPUTS
    $true  → manifest entry can be scheduled (intersection non-empty OR no requirement declared)
    $false → manifest entry must be skipped (RequiresProducts declared but tenant lacks all of them)

    NOTE: returns $true (fail-open) when TenantProducts is null/empty. This is intentional —
    if capability discovery failed transiently (KV throttle · network) we'd rather attempt
    the poll than silently drop data. The cycle telemetry will surface persistent failures.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        $RequiresProducts,
        $TenantProducts
    )

    if (-not $RequiresProducts -or @($RequiresProducts).Count -eq 0) { return $true }   # no requirement -> attempt
    if (-not $TenantProducts -or @($TenantProducts).Count -eq 0) { return $true }        # discovery unknown -> attempt

    # DEAD-GATE-PROOF (license-independence): skip ONLY when EVERY required product is authoritatively DERIVABLE and
    # the tenant has NONE of them. If ANY required product is NON-derivable (the deriver can't produce it for any
    # tenant — e.g. MCAS/MTO), fail-OPEN -> attempt -> the runtime postures on the real HTTP response. A required
    # product the connector doesn't know how to derive can therefore NEVER permanently disable an op.
    foreach ($req in @($RequiresProducts)) {
        if ($req -notin $script:XdrDerivableProducts) { return $true }   # non-derivable -> attempt-and-posture
        if ($TenantProducts -contains $req)           { return $true }   # tenant has it  -> attempt
    }
    return $false   # all required products derivable AND tenant has none -> clean skip (not a dead gate)
}

Export-ModuleMember -Function Get-XdrTenantContext, Get-XdrTenantCapabilities, Test-XdrRequiresProducts
