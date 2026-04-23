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
│  │   54 streams declared → routed to LA custom tables         │       │
│  │   (52 telemetry + MDE_Heartbeat + MDE_AuthTestResult)      │       │
│  └────────────────────────────────────────────────────────────┘       │
└────────────────────────────────────────────────────────────────────────┘
                                   │
                                   │ cross-RG nested deployments (2)
                                   │   tables-<uniq>           (54 LA tables)
                                   │   sentinelContent-<uniq>  (parsers + workbooks + rules)
                                   ▼
┌────────────────────────────────────────────────────────────────────────┐
│ AZURE — SENTINEL WORKSPACE RG (pre-existing, any RG / any subscription)│
│                                                                        │
│  ┌────────────────────────────────────────────────────────────┐       │
│  │ Existing Log Analytics workspace (Sentinel-enabled)        │       │
│  │                                                            │       │
│  │   54 custom tables written by cross-RG nested deployment:  │       │
│  │     MDE_*_CL  (52 telemetry tables)                        │       │
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

## References

See [REFERENCES.md](REFERENCES.md).
