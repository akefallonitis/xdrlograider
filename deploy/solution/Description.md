# XdrLogRaider — Sentinel Solution Description

## What it does

XdrLogRaider ingests **Microsoft Defender XDR portal-only telemetry** into
Microsoft Sentinel — configuration, compliance, drift, exposure, and
governance data that the public Graph Security API, Defender XDR API, and
MDE public APIs don't expose. Think: Defender settings that only appear in
the `security.microsoft.com` portal UI (advanced features, alert tuning,
custom detections, RBAC device groups, XSPM attack paths, MDI service
accounts) — now queryable in KQL.

## Why

Microsoft ships a lot of security-posture state that's only readable through
portal web UI, not through public APIs. That leaves a visibility gap for:

- **Configuration drift** — "who changed AV exclusions last week?"
- **Compliance audit** — "are we still running all ASR rules we certified?"
- **Exposure posture trending** — "XSPM attack paths delta over 30 days"
- **RBAC governance** — "when did we add that device group?"
- **AIR / Action Center** — "what auto-remediations ran and who approved?"

XdrLogRaider fills the gap by polling the portal's internal APIs on a
schedule (poll cadence matches data-refresh rate per tier), normalising the
responses into `RawJson` custom-table rows, and running KQL drift parsers
that compare current snapshots to previous ones via `hash(RawJson)`. The
result: workbooks, analytic rules, and hunting queries that answer
"what changed, when, and how".

## What you get

| Asset | Count | Notes |
|-------|------:|-------|
| Custom Log Analytics tables | **47** | 45 data streams + `MDE_Heartbeat_CL` + `MDE_AuthTestResult_CL` |
| Data streams (endpoints polled) | **45** | Across 7 compliance tiers (P0 Compliance, P1 Pipeline, P2 Governance, P3 Exposure, P5 Identity, P6 Audit/AIR, P7 Metadata) |
| KQL drift parsers | **6** | Per-tier `MDE_Drift_P*` — schema-agnostic hash-based diff |
| Analytic rules | **14** | Ship `enabled: false` — customer enables selectively after review |
| Hunting queries | **9** | MITRE-tagged drift-detection queries |
| Workbooks | **6** | Compliance Dashboard, Drift Report, Exposure Map, Governance Scorecard, Identity Posture, Response Audit |
| Data Connector card | 1 | Lists all 47 tables; `IsConnectedQuery` monitors heartbeat |

## How it works

```
Admin (one-off)
   │
   └──▶ Initialize-XdrLogRaiderAuth.ps1 ──▶ Key Vault
                                                │
Function App (unattended, every N minutes)     │
   │                                            ▼
   ├── System-Assigned MI reads KV secrets
   ├── Connect-MDEPortal (CredentialsTotp OR Passkey)
   ├── Poll tier endpoints (9 timer-triggered functions)
   ├── Gzip-compress rows, POST to DCE
   └── Write heartbeat (Rate429Count, GzipBytes, streams counts)
                     │
                     ▼
             DCE ──▶ DCR ──▶ 47 MDE_*_CL custom tables in workspace
                                           │
                                           └──▶ Parsers + Workbooks + Rules + Hunting
```

## Requirements

- **Azure subscription** with Contributor to target resource group
- **Existing Sentinel-enabled Log Analytics workspace** (any RG / any subscription in the same tenant — this solution does NOT create one)
- **Entra service account** with `Security Reader` + `Defender XDR Analyst` roles
- **Auth material** — either TOTP Base32 seed OR software passkey JSON (see `docs/GETTING-AUTH-MATERIAL.md`)

## Deployment

One-click via **Deploy to Azure** button in the repo README. The wizard
prompts for workspace resource ID, region, auth method, and a project
prefix. End-to-end takes ~10 minutes; first poll cycle completes within
another 5 minutes.

## Design principles

- **Design A (RawJson + KQL drift)** — schema-agnostic. Unofficial API
  drift doesn't silently drop rows; drift is computed query-time.
- **Evidence-based endpoint inclusion** — every endpoint ships with
  XDRInternals v1.0.3 / nodoc / MDEAutomator / DefenderHarvester backing
  AND a live-captured 200 against a real admin account.
- **Unattended auth** — CredentialsTotp + Passkey auto-refresh via KV.
  DirectCookies is testing-only (no auto-refresh; KV writer refuses).
- **Defence-in-depth observability** — every timer fire writes a
  heartbeat row; `Rate429Count` + `GzipBytes` surface rate-limit pressure
  + DCE compression effectiveness in the same row.
- **Forward-scalable** — manifest `Portal=` field + helper `-Portal` param
  ready for v0.2.0 multi-portal expansion (admin/entra/compliance) with
  zero refactor of the auth or ingest modules.

## Support

See [Support.md](Support.md).

## Source

[github.com/akefallonitis/xdrlograider](https://github.com/akefallonitis/xdrlograider)
