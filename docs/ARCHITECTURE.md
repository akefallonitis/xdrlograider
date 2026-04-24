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
│  │    └─ Import Xdr.Portal.Auth, Client, Ingest              │       │
│  │    └─ Connect-AzAccount -Identity                          │       │
│  │                                                            │       │
│  │  Modules/Xdr.Portal.Auth                                  │       │
│  │    ├─ Get-TotpCode (RFC 6238)                              │       │
│  │    ├─ Invoke-PasskeyChallenge (ECDSA-P256)                 │       │
│  │    ├─ Get-EstsCookie → sccauth exchange                    │       │
│  │    └─ Connect-MDEPortal / Invoke-MDEPortalRequest          │       │
│  │                                                            │       │
│  │  Modules/XdrLogRaider.Client                           │       │
│  │    └─ Endpoints/Get-<55-endpoint-wrappers>                 │       │
│  │                                                            │       │
│  │  Modules/XdrLogRaider.Ingest                           │       │
│  │    ├─ Send-ToLogAnalytics (DCE batch writer)               │       │
│  │    ├─ Write-Heartbeat                                      │       │
│  │    └─ Get-CheckpointTimestamp                              │       │
│  │                                                            │       │
│  │  Timer functions (9 total, all timer-triggered):           │       │
│  │    heartbeat-5m                                            │       │
│  │    validate-auth-selftest (T+5m/T+1h/T+6h then off)        │       │
│  │    poll-p0-compliance-1h (19 streams)                      │       │
│  │    poll-p1-pipeline-30m (7 streams)                        │       │
│  │    poll-p2-governance-1d (7 streams)                       │       │
│  │    poll-p3-exposure-1h (8 streams)                         │       │
│  │    poll-p5-identity-1d (5 streams)                         │       │
│  │    poll-p6-audit-10m (2 streams)                           │       │
│  │    poll-p7-metadata-1d (4 streams)                         │       │
│  └────────────────────────────────────────────────────────────┘       │
│                                                                        │
│  ┌──────────────────┐  ┌──────────────────┐  ┌─────────────────────┐ │
│  │ Key Vault        │  │ Storage Account  │  │ App Insights        │ │
│  │ - mde-portal-*   │  │ - Checkpoints    │  │ - FA telemetry      │ │
│  │ (passkey / creds)│  │ - Heartbeats     │  │ - App Insights logs │ │
│  └──────────────────┘  └──────────────────┘  └─────────────────────┘ │
│                                                                        │
│  ┌────────────────────────────────────────────────────────────┐       │
│  │ DCE + DCR  (location = WORKSPACE region)                   │       │
│  │   47 streams declared → routed to LA custom tables         │       │
│  │   (45 telemetry + MDE_Heartbeat + MDE_AuthTestResult)      │       │
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
│  │     MDE_*_CL  (45 telemetry tables)                        │       │
│  │     MDE_Heartbeat_CL                                       │       │
│  │     MDE_AuthTestResult_CL                                  │       │
│  │                                                            │       │
│  │   Sentinel content written by cross-RG nested deployment:  │       │
│  │     6 Parsers (savedSearches / KQL functions)              │       │
│  │     6 Workbooks                                            │       │
│  │     15 Analytic rules (scheduled, ship disabled)           │       │
│  │     10 Hunting queries                                     │       │
│  │     1 Data Connector UI card (XdrLogRaider)                │       │
│  └────────────────────────────────────────────────────────────┘       │
└────────────────────────────────────────────────────────────────────────┘
```

## Data flow

1. Timer function fires
2. Function reads auth secrets from Key Vault via Managed Identity
3. Xdr.Portal.Auth runs cookie chain (if cache miss) → sccauth + XSRF
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
@{ Stream = 'MDE_AdvancedFeatures_CL'; Path = '/apiproxy/mtp/settings/...'; Tier = 'P0'; Availability = 'live' }

# Future v0.2.0 entry — explicit non-default portal
@{ Stream = 'AAD_CAPolicies_CL'; Path = '/apiproxy/...'; Tier = 'A0'; Portal = 'entra.microsoft.com'; Availability = 'live' }
```

### 2. Portal-agnostic auth module

`Xdr.Portal.Auth` takes `-PortalHost` on every public function. The full auth
chain (ests-cookie → TOTP/Passkey → sccauth) works identically against any
Microsoft portal that uses the same SSO stack (which all of them do). Zero
new code needed for v0.2.0 portals — just new manifest entries.

### 3. Shared timer helper

`Invoke-TierPollWithHeartbeat -Tier -FunctionName [-Portal]` has an optional
`-Portal` parameter defaulting to `security.microsoft.com`. v0.2.0 adds:

```
src/functions/poll-admin-a0-1h/run.ps1  (2-line wrapper):
    param($Timer)
    Invoke-TierPollWithHeartbeat -Tier 'A0' -FunctionName 'poll-admin-a0-1h' -Portal 'admin.microsoft.com'
```

No change to helper internals; `Invoke-MDETierPoll` already filters manifest
entries by `Portal` AND `Tier`.

### 4. Strictly acyclic module graph

```
Timer wrappers
    └→ XdrLogRaider.Client         (per-portal manifest + dispatcher)
           ├→ Xdr.Portal.Auth        (portal-agnostic auth primitives)
           └→ XdrLogRaider.Ingest    (portal-agnostic DCE + checkpoint + heartbeat)
```

Adding a sibling `XdrLogRaider.AdminPortal.Client` module for a second
portal doesn't touch Auth or Ingest. `tests/unit/ForwardScalability.Tests.ps1`
enforces this graph in CI.

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
files via `hash(RawJson)` comparison across time windows. This is Design A —
chosen over Design C (typed DCR columns per stream) for three reasons:

1. **Unofficial API drift doesn't silently drop rows.** Portal APIs change
   shape without notice. A typed DCR would reject rows with new/missing
   fields; we preserve them as `RawJson.dynamic` and let KQL parsers evolve.
2. **Schema is tunable without redeploy.** Parsers can add new extract-keys
   or change drift sensitivity without ARM redeployment; they're just
   `savedSearches` resources updated via `Build-SentinelContent.ps1`.
3. **Re-parseability.** If a v0.1.0-beta parser is imperfect, v0.2.0 can
   improve the query and re-run against the same historical `RawJson` rows.

Trade-off: query-time compute instead of ingest-time compute. Acceptable
for the low-volume config-drift domain where workbooks run intermittently
and not every few-seconds per ingestion burst.

## Error-handling + App Insights taxonomy (v0.1.0-beta)

Errors flow through a deliberate taxonomy so operators can triage in one
query instead of greping raw stack traces:

| Layer | Error type | Surfaces as | Operator KQL hook |
|-------|-----------|-------------|-------------------|
| Portal 429 | Rate-limited | `$script:Rate429Count` incremented; exhausted → `[MDERateLimited]` message prefix thrown | `MDE_Heartbeat_CL \| extend n = parse_json(Notes) \| summarize sum(toint(n.rate429Count))` |
| Portal 401/440 | Session expired | Reactive reauth via cached credentials; transparent to caller | `MDE_AuthTestResult_CL \| where Success == false \| project Stage, FailureReason` |
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
