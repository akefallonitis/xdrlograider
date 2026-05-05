# XdrLogRaider

**A Microsoft Sentinel custom data connector that ingests Microsoft Defender XDR portal-only telemetry — configuration, compliance, drift, exposure, governance — that public Microsoft APIs (Graph Security, Microsoft 365 Defender, MDE) don't expose.**

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fakefallonitis%2Fxdrlograider%2Fv0.1.0%2Fdeploy%2Fcompiled%2FmainTemplate.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fakefallonitis%2Fxdrlograider%2Fv0.1.0%2Fdeploy%2Fcompiled%2FcreateUiDefinition.json)
[![CI](https://github.com/akefallonitis/xdrlograider/actions/workflows/ci.yml/badge.svg)](https://github.com/akefallonitis/xdrlograider/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

| Feature | Detail |
|---|---|
| Platform | Azure Functions (PowerShell 7.4), Log Analytics, Sentinel |
| Auth | Two unattended auto-refreshing methods: Credentials+TOTP, Software Passkey. DirectCookies for diagnostic / one-shot use. |
| Scope | Microsoft Defender XDR portal (`security.microsoft.com`) — telemetry streams across 10 functional categories (Endpoint Device Management, Endpoint Configuration, Vulnerability Management, Identity Protection, Configuration & Settings, Exposure Management, Threat Analytics, Action Center, Multi-Tenant Operations, Streaming API). Every stream documented + live-captured. Some streams activate only when the tenant provisions the underlying feature (MDI / TVM / MCAS / Intune / MDO / Custom Collection). |
| Prerequisite | **Existing Sentinel-enabled Log Analytics workspace** (any RG / subscription in the same tenant). This template does NOT create a workspace. |
| Deployment | One-click **Deploy to Azure** (button above) + one `./tools/Initialize-XdrLogRaiderAuth.ps1` run post-deploy. Cross-RG / cross-region workspace supported. |
| Content | 8 workbooks · 20 analytic rules (14 detection + 6 XdrOps incl. RowVolumeSpike cost-budget gate) · 9 hunting queries · 4 KQL drift parsers + 11 consolidated LA tables (10 `Defender_<Category>_CL` + 1 `XdrConnectorHealth_CL`) · 390 sample queries (5 per active stream) — all auto-deployed via nested ARM. Every parser / rule / query / workbook column reference verified against live fixtures in CI. |
| License | MIT |

XdrLogRaider ingests the tenant-configuration surface that Microsoft's first-party APIs don't expose: suppression rule changes, exclusion list changes, data export destination adds, Live Response policy relaxations, XSPM attack paths + chokepoints + top targets + asset classification schema, posture metrics + secure-score per-category, attack-surface analytical paths/chokepoints, threat-analytics enriched outbreaks + top threats, MDI identity service accounts, Action Center approval history, and more. **Drift happens on the KQL side** (pure query-time) — 4 cadence-tier parsers (`MDE_Drift_Configuration` / `MDE_Drift_Inventory` / `MDE_Drift_Exposure` / `MDE_Drift_Maintenance`) feed 8 workbooks and 20 analytic rules. `RawJson` is preserved on every row for forensic queries; typed columns are projected at ingest via DCR. Every endpoint response shape is captured as a live fixture in `tests/fixtures/live-responses/` and all parsers + rules + queries + workbooks are verified against those fixtures in CI (1357+ unit tests across 67 files, 72.51% coverage, plus 12-edge wiring audit per stream).

## Quick start

### 0. Prerequisites (one-time)

- **Existing Sentinel-enabled Log Analytics workspace**. Copy its full resource ID + region (Portal → workspace → Overview → JSON view).
- **Dedicated read-only Entra service account** (`svc-xdrlr@...`) with `Security Reader` + `Defender XDR Analyst` roles.
- **TOTP Base32 secret** (or **software passkey JSON**) for that account — see [docs/GETTING-AUTH-MATERIAL.md](docs/GETTING-AUTH-MATERIAL.md).
- **Contributor** on the target RG + **Log Analytics Contributor** on the workspace RG. Full breakdown in [docs/PERMISSIONS.md](docs/PERMISSIONS.md).

### 1. Click **Deploy to Azure** (badge above)

The button opens an Azure Portal wizard that:
- Asks for the workspace resource ID + workspace region (required), service account UPN, auth method, project prefix
- Provisions Function App + Plan + Key Vault + Storage + DCE + DCR + App Insights in your target RG
- Adds 11 custom tables (10 `Defender_<Category>_CL` consolidated category tables + 1 `XdrConnectorHealth_CL` ops table) + a Sentinel Data Connector UI card with 390 sample queries + 4 drift parsers / 8 workbooks / 20 analytic rules / 9 hunting queries to your existing workspace (via cross-RG nested deployments — no manual Sentinel-content install)
- Outputs `keyVaultName`, `dceEndpoint`, `dcrImmutableId`, and the exact `postDeployCommand` for step 2

> **Private repository note:** the Deploy button uses `raw.githubusercontent.com` URLs and requires the repo to be public for Azure Portal to fetch the templates. For private-repo deployment: use Azure Portal → **Deploy a custom template** → **Load template from file** with the JSONs in `deploy/compiled/` (or from the GitHub Release assets).

### 2. Upload auth material to Key Vault

```powershell
git clone https://github.com/akefallonitis/xdrlograider
cd xdrlograider
./tools/Initialize-XdrLogRaiderAuth.ps1 -KeyVaultName <KeyVaultName from step 1>
```

See [docs/GETTING-AUTH-MATERIAL.md](docs/GETTING-AUTH-MATERIAL.md) for how to obtain the TOTP Base32 secret / software passkey / cookies for the service account.

### 3. Confirm green

Open **Microsoft Sentinel → Data connectors** in your workspace and find the **XdrLogRaider** card. Within 5–10 minutes of step 2, **Status** flips to **Connected** — that's it. The card reads `XdrConnectorHealth_CL` via the connector's `connectivityCriteria` IsConnectedQuery (gates on `StreamsSucceeded > 0 AND RowsIngested > 0`), so any successful first poll with actual data flow lights it up.

If it stays Disconnected past 15 minutes, see [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

Production polling timers fire on their cadence: `fast` (10 min) ingests Action Center events first; `inventory` (daily 02:00 UTC) ingests the long-tail settings + identity + metadata streams. See [docs/STREAMS.md](docs/STREAMS.md) for the full per-tier breakdown.

## Roadmap

| Version | Focus | Highlights |
|---|---|---|
| **v0.1.0 GA** ← *current* | Pure Defender connector | 59 portal-only streams · 11 consolidated LA tables · 7 DCRs / 1 DCE · 8 workbooks · 20 analytic rules · 4 cadence-tier drift parsers · cosign-signed release artifacts |
| **v0.1.0.1** | DCR-per-category topology refactor | Renames the 7 bucket-fill DCRs (`xdrlr-dcr-defender-1..7`) to **13 descriptive per-category DCRs** (`xdrlr-dcr-actioncenter`, `xdrlr-dcr-configuration-1/2`, `xdrlr-dcr-exposure-1/2`, etc.). Backward-compatible — workspace tables + KQL queries unchanged. Improves operator UX + simplifies RBAC reasoning |
| **v0.2.0** | Multi-portal expansion + FA multi-tenancy | Adds `Xdr.Entra.*` + `Xdr.Purview.*` + `Xdr.Intune.*` modules · `Entra_<Category>_CL` / `Purview_<Category>_CL` / `Intune_<Category>_CL` per-portal tables · per-tenant secret namespacing in KV (one FA polls many tenants) · coverage gate raised to ≥75% |
| **v1.0.0** | Marketplace certification | Azure Marketplace + Microsoft Sentinel Solution Gallery certified listing · default `restrictPublicNetwork=true` baseline · private-endpoint hardening · dedicated SKU support · enterprise-grade tenant onboarding wizard |
| **v1.x** | Hardening + telemetry depth | 100% functional coverage on every public function · mutation testing · per-stream cost-budget enforcement · DLQ exponential backoff with circuit-breaker · custom workspace tiers per category |

Full per-version deliverables in [docs/ROADMAP.md](docs/ROADMAP.md). Streams are not marked as removed without [docs/STREAMS-REMOVED.md](docs/STREAMS-REMOVED.md) history. New streams get added to the manifest with live-captured fixtures and full 12-edge wiring before they ship.

## Documentation

- [Architecture](docs/ARCHITECTURE.md) — components, data flow, trust boundaries
- [Deployment](docs/DEPLOYMENT.md) — step-by-step walkthrough
- **[Permissions](docs/PERMISSIONS.md)** — consolidated setup + runtime + cross-RG reference
- [Auth](docs/AUTH.md) — both methods explained, CA compatibility, rotation
- [Getting Auth Material](docs/GETTING-AUTH-MATERIAL.md) — how to obtain TOTP / passkey / cookies
- [Bring Your Own Passkey](docs/BRING-YOUR-OWN-PASSKEY.md) — generating a software passkey JSON
- [Streams](docs/STREAMS.md) — full catalogue of telemetry streams + per-stream tier + category
- [Workbooks](docs/WORKBOOKS.md) — what each dashboard shows
- [Drift](docs/DRIFT.md) — pure-KQL drift model explained
- [Runbook](docs/RUNBOOK.md) — daily ops, incidents, rotation
- [Troubleshooting](docs/TROUBLESHOOTING.md) — symptom → fix
- [References](docs/REFERENCES.md) — all sources cited
- **[Roadmap](docs/ROADMAP.md)** — what's next: v0.2.0 multi-portal + multi-tenancy, v1.0.0 Marketplace certification, v1.x hardening

## Contributing

Community-driven. See [CONTRIBUTING.md](CONTRIBUTING.md) and the `good-first-issue` label.

Issue templates:
- Bug report
- Feature request
- **Portal endpoint broken** — specific template for reporting when Microsoft hardens an endpoint we depend on
- New stream request

## License

MIT — see [LICENSE](LICENSE).

## Security

See [SECURITY.md](SECURITY.md) for vulnerability disclosure.

Authentication patterns used in this project are based on publicly documented specifications (RFC 6238 TOTP, W3C WebAuthn) and publicly researched portal-cookie behavior. Microsoft's sccauth cookie-based Conditional-Access-bypass category has been disclosed and classified as moderate-severity, not-immediate-servicing — see [CloudBrothers April 2026 finding](https://cloudbrothers.info/en/avoid-entra-conditional-access-sccauth/).

This project is authorized research — MIT licensed, used only within tenants owned by the operator, with proper authorization. See [DISCLAIMER.md](DISCLAIMER.md).
