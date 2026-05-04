# Architecture

## Overview

XdrLogRaider is a three-layer Sentinel Solution:

1. **Admin-side helper** (one-off, ~2 min) — uploads auth material to Key Vault
2. **Azure Function App** (unattended, forever) — polls Defender XDR portal, ingests to Log Analytics
3. **Sentinel content** (parsers + workbooks + analytic rules + hunting queries) — surfaces drift and posture

## Component diagram

```
┌────────────────────────────────────────────────────────────────────────┐
│ ADMIN WORKSTATION (one-off)                                            │
│                                                                        │
│  git clone → ./tools/Initialize-XdrLogRaiderAuth.ps1                   │
│      ├─ Validates passkey JSON or creds+TOTP inputs                    │
│      └─ Uploads secrets to Key Vault                                   │
└────────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
┌────────────────────────────────────────────────────────────────────────┐
│ AZURE — CONNECTOR RG (target of Deploy-to-Azure)                       │
│                                                                        │
│  ┌────────────────────────────────────────────────────────────┐       │
│  │ Function App (PowerShell 7.4 + System-Assigned MI)         │       │
│  │                                                            │       │
│  │  profile.ps1 (cold-start)                                  │       │
│  │    └─ Import 5 modules in dependency order                 │       │
│  │    └─ Connect-AzAccount -Identity                          │       │
│  │                                                            │       │
│  │  Modules/Xdr.Common.Auth          (L1 portal-generic)      │       │
│  │    ├─ Get-TotpCode (RFC 6238)                              │       │
│  │    ├─ Invoke-PasskeyChallenge (ECDSA-P256)                 │       │
│  │    ├─ Get-EntraEstsAuth → ESTS sign-in                     │       │
│  │    └─ Get-XdrAuthFromKeyVault                              │       │
│  │                                                            │       │
│  │  Modules/Xdr.Sentinel.Ingest       (L1 portal-generic)     │       │
│  │    ├─ Send-ToLogAnalytics (DCE batch writer + gzip + 413)  │       │
│  │    ├─ Write-Heartbeat                                      │       │
│  │    ├─ Send-XdrAppInsights* (AuthChain.* events)            │       │
│  │    └─ Get-/Set-CheckpointTimestamp                         │       │
│  │                                                            │       │
│  │  Modules/Xdr.Defender.Auth         (L2 cookie exchange)    │       │
│  │    ├─ Get-DefenderSccauth → sccauth exchange               │       │
│  │    └─ Connect-DefenderPortal / Invoke-DefenderPortalRequest│       │
│  │                                                            │       │
│  │  Modules/Xdr.Defender.Client       (L3 manifest dispatcher)│       │
│  │    ├─ endpoints.manifest.psd1 (46 stream entries)          │       │
│  │    └─ Invoke-MDEEndpoint / Invoke-MDETierPoll              │       │
│  │                                                            │       │
│  │  Modules/Xdr.Connector.Orchestrator (L4 portal routing)    │       │
│  │    └─ Connect-XdrPortal / Invoke-XdrTierPoll               │       │
│  │       (forward-scalable to multi-portal in v0.2.0+)        │       │
│  │                                                            │       │
│  │  Timer functions (6 total, all timer-triggered):           │       │
│  │    Connector-Heartbeat                                            │       │
│  │    Defender-ActionCenter-Refresh         (ActionCenter + MachineActions)   │       │
│  │    Defender-XspmGraph-Refresh      (XSPM graph + Exposure snapshots) │       │
│  │    Defender-Configuration-Refresh        (rules / RBAC / integrations)     │       │
│  │    Defender-Inventory-Refresh     (settings / identity / metadata)  │       │
│  │    Defender-Maintenance-Refresh   (DataExportSettings — rare-change)│       │
│  └────────────────────────────────────────────────────────────┘       │
│                                                                        │
│  ┌──────────────────┐  ┌──────────────────┐  ┌─────────────────────┐ │
│  │ Key Vault        │  │ Storage Account  │  │ App Insights        │ │
│  │ - mde-portal-*   │  │ - Checkpoints    │  │ - FA telemetry      │ │
│  │ (passkey / creds)│  │ - Heartbeats     │  │ - AuthChain.* events│ │
│  └──────────────────┘  └──────────────────┘  └─────────────────────┘ │
│                                                                        │
│  ┌────────────────────────────────────────────────────────────┐       │
│  │ DCE + DCR  (location = WORKSPACE region)                   │       │
│  │   47 streams declared → routed to LA custom tables         │       │
│  │   (46 data + MDE_Heartbeat operational)                    │       │
│  └────────────────────────────────────────────────────────────┘       │
└────────────────────────────────────────────────────────────────────────┘
                                   │
                                   │ cross-RG nested deployments (2)
                                   │   tables-<uniq>           (47 LA tables)
                                   │   sentinelContent-<uniq>  (parsers + workbooks + rules)
                                   ▼
┌────────────────────────────────────────────────────────────────────────┐
│ AZURE — SENTINEL WORKSPACE RG (pre-existing, any RG / any subscription)│
│                                                                        │
│  ┌────────────────────────────────────────────────────────────┐       │
│  │ Existing Log Analytics workspace (Sentinel-enabled)        │       │
│  │                                                            │       │
│  │   47 custom tables written by cross-RG nested deployment:  │       │
│  │     MDE_*_CL  (46 data tables)                             │       │
│  │     MDE_Heartbeat_CL                                       │       │
│  │                                                            │       │
│  │   Sentinel content written by cross-RG nested deployment:  │       │
│  │     4 Parsers (one per cadence tier with snapshot          │       │
│  │       semantics — Exposure, Configuration, Inventory,      │       │
│  │       Maintenance; the fast tier has events not snapshots) │       │
│  │     7 Workbooks                                            │       │
│  │     14 Analytic rules (scheduled, ship disabled)           │       │
│  │     9 Hunting queries                                      │       │
│  │     1 Data Connector UI card (XdrLogRaider)                │       │
│  └────────────────────────────────────────────────────────────┘       │
└────────────────────────────────────────────────────────────────────────┘
```

## Data flow

1. Timer function fires
2. Function reads auth secrets from Key Vault via Managed Identity
3. Xdr.Common.Auth + Xdr.Defender.Auth run the cookie chain (if cache miss) → sccauth + XSRF
4. For each stream in the tier: call the endpoint, parse response, append a row
5. All rows for the tier are batched into one DCE POST
6. DCR transforms the stream name → Log Analytics custom table
7. Heartbeat table gets an entry per successful tier poll
8. KQL parsers compute drift on query from workbooks / analytic rules

## Trust boundaries

- **Admin workstation ↔ Key Vault** — Az CLI with admin credentials, one-time
- **Function App ↔ Key Vault** — Managed Identity with KV Secrets User role (read-only)
- **Function App ↔ security.microsoft.com** — service account credentials (passkey or TOTP), scoped to Security Reader + MDE analyst read
- **Function App ↔ DCE** — Managed Identity with Monitoring Metrics Publisher role on DCR
- **Function App ↔ Storage** — Managed Identity with Storage Table Data Contributor
- **Sentinel ↔ Log Analytics** — same workspace, RBAC via Sentinel Contributor / Reader

## Security

- No secrets in code
- No secrets in deployment payload
- Managed Identity for all Azure-to-Azure auth
- Audit logs: Key Vault access, Function App App Insights, Log Analytics diagnostic settings
- Rotation: `az keyvault secret set` updates creds; Function App reads fresh on next cold start or cache expiry

## Design decisions

### Why Function App vs CCF
CCF supports only OAuth2/APIKey/Basic/JWT auth. The Defender XDR portal uses cookie-based auth (sccauth + XSRF rotation every 4 min) with TOTP or FIDO2 assertion signing. CCF cannot express this chain. See `REFERENCES.md` → "Create a codeless connector".

### Why 9 functions vs 55
One function per stream = 55 cold starts, 55 App Insights streams, 55× the auth chain. One polymorphic function = single point of failure, hard to debug. Nine tier-batched functions balance isolation (per-tier) with cost (shared auth cookie, batched DCE POST).

### Why pure KQL drift
Connector stays stateless (no diff code, no previous-snapshot storage). Drift logic tunable without redeploy. Each workbook/rule can optimize its query for its data shape. Trade-off: query-time compute instead of ingest-time compute — acceptable for low-volume config data.

### Why Managed Identity + Key Vault vs client secret
MI eliminates rotation burden for Azure-to-Azure auth. User auth material (passkey/TOTP) still in KV because the portal is user-scope only — no MI path to portal APIs.

### Why PowerShell 7.4
Cross-platform (Linux Consumption plan is cheapest), built-in HTTP + WebSession + Crypto, aligns with the PowerShell-heavy security-research tooling ecosystem (XDRInternals, nodoc, DefenderHarvester).

## Multi-portal extensibility (v0.1.0-beta J2 — forward-scalable)

The architecture is designed so adding another Microsoft portal (e.g.
`admin.microsoft.com`, `entra.microsoft.com`, `compliance.microsoft.com`,
`intune.microsoft.com`) in v0.2.0+ is **additive only** — no edits to any
shipped module internals. Four invariants make this safe:

### 1. Manifest-level `Portal` annotation + loader default

`endpoints.manifest.psd1` declares `Defaults = @{ Portal = 'security.microsoft.com' }`.
`Get-MDEEndpointManifest` (in `_EndpointHelpers.ps1`) applies the default to
any entry that doesn't override. Entries can opt in to a different portal:

```powershell
# Current entry (v0.1.0-beta — security portal implicitly)
@{ Stream = 'MDE_AdvancedFeatures_CL'; Path = '/apiproxy/mtp/settings/...'; Tier = 'inventory'; Availability = 'live' }

# Future v0.2.0 entry — explicit non-default portal
@{ Stream = 'AAD_CAPolicies_CL'; Path = '/apiproxy/...'; Tier = 'A0'; Portal = 'entra.microsoft.com'; Availability = 'live' }
```

### 2. Portal-agnostic auth module

`Xdr.Common.Auth` is fully portal-generic — `Get-EntraEstsAuth` takes
`-ClientId` and `-PortalHost` as parameters; no Defender-specific symbols.
The cookie-exchange step lives in `Xdr.Defender.Auth`. v0.2.0 multi-portal
expansion is a 1-day file-add operation: copy `Xdr.Defender.Auth`, change
the public-client ID + portal host + cookie names, register in `profile.ps1`.
L1 unchanged.

### 3. Shared timer helper

`Invoke-TierPollWithHeartbeat -Tier -FunctionName [-Portal]` has an optional
`-Portal` parameter defaulting to `security.microsoft.com`. v0.2.0 adds:

```
src/functions/poll-admin-fast-10m/run.ps1  (2-line wrapper):
    param($Timer)
    Invoke-TierPollWithHeartbeat -Tier 'fast' -FunctionName 'poll-admin-fast-10m' -Portal 'admin.microsoft.com'
```

No change to helper internals; `Invoke-MDETierPoll` already filters manifest
entries by `Portal` AND `Tier`.

### 4. Strictly acyclic module graph

```
Timer wrappers
    └→ Xdr.Connector.Orchestrator     (L4 portal-routing dispatcher)
        ├→ Xdr.Defender.Client         (L3 manifest dispatcher)
        │      └→ Xdr.Defender.Auth    (L2 cookie exchange)
        │             └→ Xdr.Common.Auth  (L1 portal-generic Entra)
        └→ Xdr.Sentinel.Ingest         (L1 portal-generic ingest, standalone)
```

Adding a sibling `Xdr.AdminPortal.Auth` + `Xdr.AdminPortal.Client` pair for
a second portal doesn't touch the existing modules. Tests in
`tests/unit/ForwardScalability.Tests.ps1` and
`tests/unit/ModuleSplit.LayerBoundaries.Tests.ps1` enforce this graph in CI.

## Schema lives in parsers, not DCR (Design A rationale)

The DCR `transformKql` is deliberately minimal — just `source` (pass-through
plus a `TimeGenerated` cast if the upstream field is a string). Every custom
table has the same baseline columns:

```
TimeGenerated  datetime
SourceStream   string     (the stream name — MDE_AdvancedFeatures_CL, etc.)
EntityId       string     (extracted per-manifest or fallback-inferred)
RawJson        dynamic    (the entire response row preserved verbatim)
```

Drift detection happens **query-time** in the 6 `sentinel/parsers/MDE_Drift_P*.kql`
files via a typed-column-bag diff: each parser builds a snapshot bag with
`pack_all() - metaCols` over the manifest's projected typed columns and
compares the current bag to the previous one via `hash(tostring(TypedBag))`.
The chosen approach combines the best of typed-at-ingest and
schema-agnostic-at-query:

1. **Per-stream typed columns at ingest.** The manifest's `ProjectionMap`
   projects portal responses into typed DCR columns so workbooks and
   rules query named columns directly (no JSON parsing in hot paths).
2. **Unofficial API drift doesn't silently drop rows.** `RawJson` is
   preserved on every row alongside the typed columns. New or renamed
   portal fields land in `RawJson` and stay queryable; the manifest's
   `ProjectionMap` evolves in a follow-up release without DCR redeploy
   pain.
3. **Re-parseability.** If a v0.1.0-beta projection is imperfect, v0.2.0
   can improve the projection and re-run drift against the same
   historical `RawJson` rows.

Trade-off: query-time compute instead of ingest-time compute. Acceptable
for the low-volume config-drift domain where workbooks run intermittently
and not every few-seconds per ingestion burst.

## Error-handling + App Insights taxonomy (v0.1.0-beta)

Errors flow through a deliberate taxonomy so operators can triage in one
query instead of greping raw stack traces:

| Layer | Error type | Surfaces as | Operator KQL hook |
|-------|-----------|-------------|-------------------|
| Portal 429 | Rate-limited | `$script:Rate429Count` incremented; exhausted → `[MDERateLimited]` message prefix thrown | `MDE_Heartbeat_CL \| extend n = parse_json(Notes) \| summarize sum(toint(n.rate429Count))` |
| Portal 401/440 | Session expired | Reactive reauth via cached credentials; transparent to caller | App Insights: `customEvents \| where name == 'AuthChain.AADSTSError' \| project timestamp, customDimensions` |
| Portal 403 | Auth OK but not permitted | Surfaced to caller; no reauth spin | Heartbeat `fatalError` note if persistent |
| Portal 4xx other | Request malformed | Stream-level error captured in tier-poll `Errors` hashtable; heartbeat `Notes.errors` | `MDE_Heartbeat_CL \| extend err = parse_json(tostring(parse_json(Notes).errors)) \| where isnotempty(err)` |
| Portal 5xx | Portal-side failure | Exponential backoff retry (5 attempts); final throw surfaces to caller | Same as above |
| DCE 413 | Payload too large | Batch halved + recursed (capped depth 3); transparent to caller | `traces \| where message startswith 'DCE 413'` |
| DCE 429/5xx | DCE throttling | Exponential backoff retry (5 attempts) inside `Send-ToLogAnalytics` | `traces \| where message contains 'DCE ingest transient'` |
| Timer fatal | Any exception not handled above | `Write-Heartbeat` with `Notes.fatalError = <message>`, then `throw` so App Insights catches | `MDE_Heartbeat_CL \| where parse_json(Notes).fatalError != ''` |
| Cold-start failure | Missing envvar / module load fail | `profile.ps1` throws hard → Function App host logs | App Insights `traces` severity=Error |

Full KQL cookbook in `docs/OPERATIONS.md`.

## References

See [REFERENCES.md](REFERENCES.md).
