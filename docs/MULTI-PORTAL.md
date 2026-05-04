# Multi-Portal Architecture (v0.2.0+ Roadmap)

> **v0.1.0 GA scope**: Defender XDR portal-only telemetry. Multi-portal scaffolding is in place (6 stub modules + L4 portal-routing dispatcher) but only `Portal=Defender` is implemented. v0.2.0+ fills in Entra/Purview/Intune content.

## TL;DR

XdrLogRaider's L4 orchestrator (`Xdr.Connector.Orchestrator`) routes by `-Portal` parameter. v0.1.0 GA ships:

- **1 live portal**: `Defender` (security.microsoft.com)
- **3 scaffolding stubs**: `Entra`, `Purview`, `Intune` — modules exist, functions throw `"v0.2.0 roadmap"` errors when called

This means v0.2.0+ multi-portal expansion is a CONTENT addition, NOT an architectural change. No mainTemplate.json refactor. No DCR redesign. No KQL migration.

## What's already in place (v0.1.0 GA)

### L1-L4 module layering

```
L1  Xdr.Common.Auth         portal-generic Entra (TOTP, passkey, ESTS) — UNCHANGED for multi-portal
L1  Xdr.Sentinel.Ingest     portal-generic ingest (DCE/DCR + Storage Table + AppInsights) — UNCHANGED
L2  Xdr.Defender.Auth       Defender-specific cookie exchange (sccauth + XSRF) — LIVE
L3  Xdr.Defender.Client     Defender manifest dispatcher — LIVE
L2  Xdr.Entra.Auth          STUB — placeholder throws "v0.2.0 roadmap"
L3  Xdr.Entra.Client        STUB
L2  Xdr.Purview.Auth        STUB
L3  Xdr.Purview.Client      STUB
L2  Xdr.Intune.Auth         STUB
L3  Xdr.Intune.Client       STUB
L4  Xdr.Connector.Orchestrator  Portal-routing dispatcher — Connect-XdrPortal -Portal Defender|Entra|Purview|Intune
```

### Portal routing table

`$script:PortalRoutes` in `Xdr.Connector.Orchestrator.psm1` declares 4 portal entries:

| Portal | Status | DefaultHost | AuthModule | ClientModule |
|---|---|---|---|---|
| `Defender` | live | security.microsoft.com | Xdr.Defender.Auth | Xdr.Defender.Client |
| `Entra` | scaffolding-stub | entra.microsoft.com | Xdr.Entra.Auth | Xdr.Entra.Client |
| `Purview` | scaffolding-stub | purview.microsoft.com | Xdr.Purview.Auth | Xdr.Purview.Client |
| `Intune` | scaffolding-stub | intune.microsoft.com | Xdr.Intune.Auth | Xdr.Intune.Client |

`Connect-XdrPortal -Portal Entra ...` calls `Connect-EntraPortal` from `Xdr.Entra.Auth` which currently throws `"NOT IMPLEMENTED in v0.1.0 — Entra portal is a v0.2.0 roadmap item"`.

### Forward-compatibility tested

`tests/unit/MultiPortalScaffolding.Tests.ps1` (9 tests) gates:
- All 6 stub module dirs exist + have valid psd1+psm1
- Each stub has `ModuleVersion 0.0.1` (vs live modules 1.0.0)
- Each stub psd1 has `scaffolding-stub` + `v0.2.0-roadmap` tags
- Stub functions throw "NOT IMPLEMENTED" + "v0.2.0" messages
- Orchestrator psd1 RequiredModules references all 6 stubs
- Orchestrator psm1 source declares all 4 portal route entries
- 3 stub portals have `Status='scaffolding-stub'`; Defender has `Status='live'`

## v0.2.0 expansion plan

To add a new portal (e.g., Entra), v0.2.0 fills in:

### 1. Auth module body (`Xdr.Entra.Auth`)

Replace placeholder `Connect-EntraPortal` with actual portal-specific auth:

```powershell
function Connect-EntraPortal {
    param(
        [Parameter(Mandatory)] [string] $UserPrincipalName,
        [pscredential] $Credential,
        [string] $TotpBase32Secret,
        [string] $PasskeyJsonPath,
        [hashtable] $ExistingCookies
    )
    # Use Get-EntraEstsAuth from Xdr.Common.Auth (portal-generic)
    # Then exchange ESTS auth for Entra portal session cookie (portal-specific)
    # Return [pscustomobject]@{ Upn, PortalHost, Method, Cookies, ExpiresUtc }
}
```

Same shape + same caller contract as `Connect-DefenderPortal`. The orchestrator dispatches identically.

### 2. Client module body (`Xdr.Entra.Client`)

Replace placeholder with `Invoke-EntraTierPoll` + `Get-EntraEndpointManifest`:

```powershell
function Get-EntraEndpointManifest {
    # Loads manifest entries with Portal='Entra'
    # Returns same shape as Get-MDEEndpointManifest (manifest-driven dispatch)
}

function Invoke-EntraTierPoll {
    param(
        [Parameter(Mandatory)] [object] $Session,
        [Parameter(Mandatory)] [string] $Tier,
        [Parameter(Mandatory)] [object] $Config
    )
    # Same execution shape as Invoke-MDETierPoll:
    # foreach manifest stream where Tier == $Tier:
    #   Invoke-EntraEndpoint (or generic Invoke-XdrEndpoint with Portal-aware routing)
    #   Send-ToLogAnalytics
    # return [pscustomobject]@{ StreamsAttempted, StreamsSucceeded, RowsIngested, Errors }
}
```

### 3. Manifest entries with `Portal='Entra'`

Add Entra portal endpoints to `endpoints.manifest.psd1`:

```powershell
@{
    Stream         = 'Entra_ConditionalAccess_CL'
    Portal         = 'Entra'
    Path           = '/api/conditionalAccess/policies'
    Tier           = 'Configuration'
    Category       = 'Identity Protection (MDI)'
    NodocCategoryId= 4
    UnwrapProperty = 'value'
    IdProperty     = @('id')
    ProjectionMap  = @{ ... }
    Availability   = 'live'
    SchemaSource   = 'live-capture'
    SourceName     = 'Entra_ConditionalAccess_PortalApi'
    StreamSubtype  = 'portal-api'
}
```

### 4. Per-portal `<Portal>_<Category>_CL` workspace tables

After Phase J per-category table consolidation lands (v0.1.0):
- v0.1.0 has 9 `Defender_<Category>_CL` tables
- v0.2.0 adds 9× new tables per portal: `Entra_<Category>_CL`, `Purview_<Category>_CL`, `Intune_<Category>_CL`
- Same canonical schema (12 system cols + per-category typed cols union)
- Per-portal DCR streams + workspace tables in mainTemplate.json

### 5. Per-portal Function App timer functions (or shared)

Two options:
- **Per-portal timers** (clearer FA Overview): 6 timers per portal × 3 new portals = 24 new functions
- **Shared timers + Portal param** (simpler): keep 6 capability-named timers; each calls Invoke-XdrTierPoll with portal lookup from manifest entries

Recommend Option B for v0.2.0 to avoid FA function explosion.

## v0.2.0 scope (NOT v0.1.0)

- **22 new Defender streams** (5 device + 5 TVM + 4 identity + 3 XSPM + 3 RBAC + 2 misc per nodoc cmdlet catalog)
- **6 misroute path corrections** (TenantAllowBlock, AntivirusPolicy, DCCoverage, RemediationAccounts, DeviceTimeline, CloudAppsConfig)
- **Multi-portal CONTENT**: fill in Entra/Purview/Intune Auth+Client modules
- **Per-portal manifest entries** with Portal=Entra/Purview/Intune
- **`<Portal>_<Category>_CL` tables** per consolidated category
- **`$json:` nested object projection** for preserving GroupRules, Features, scriptOutputs without flattening
- **HTTP admin functions** (Connector-Status, Connector-ManifestInspect, Connector-StreamRefresh) IF measured operator demand

## v1.0 (3-6 months post-GA)

- Microsoft Sentinel Solution Gallery LISTING (signed package, partner-validated)
- Multi-region / multi-tenant deployment matrix
- Container Apps PRODUCTION migration (Y1 Linux EOL Sept 2028 insulation)
- Operator-friendly stream onboarding wizard

## NOT goal (permanent)

- Microsoft Graph Security / M365 Defender Public APIs (use official Microsoft connectors)
- CCF migration (incompatible with portal-only auth)
- Schema-lock without RawJson preservation

## References

- Xdr.Connector.Orchestrator source: `src/Modules/Xdr.Connector.Orchestrator/`
- Multi-portal scaffolding tests: `tests/unit/MultiPortalScaffolding.Tests.ps1`
- Module split layer test: `tests/unit/ModuleSplit.LayerBoundaries.Tests.ps1`
- Plan: `.claude/plans/immutable-splashing-waffle.md` (internal)
- Defender XDR portal API reference: https://nodoc.nathanmcnulty.com/defender (10-category authoritative taxonomy used for NodocCategoryId)
