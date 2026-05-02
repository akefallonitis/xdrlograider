# XdrLogRaider

**A Microsoft Sentinel custom data connector that ingests Microsoft Defender XDR portal-only telemetry — configuration, compliance, drift, exposure, governance — that public Microsoft APIs (Graph Security, Microsoft 365 Defender, MDE) don't expose.**

> **v0.1.0-beta — production-ready first publish.** The connector ingests Microsoft Defender XDR portal-only telemetry that public Microsoft APIs don't expose. Multi-portal forward-compat foundation in place — Defender ships today; additional Microsoft 365 portals are planned as additive modules. See [CHANGELOG.md](CHANGELOG.md) and [docs/ROADMAP.md](docs/ROADMAP.md).

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fakefallonitis%2Fxdrlograider%2Fv0.1.0-beta%2Fdeploy%2Fcompiled%2FmainTemplate.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fakefallonitis%2Fxdrlograider%2Fv0.1.0-beta%2Fdeploy%2Fcompiled%2FcreateUiDefinition.json)
[![CI](https://github.com/akefallonitis/xdrlograider/actions/workflows/ci.yml/badge.svg)](https://github.com/akefallonitis/xdrlograider/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

| Feature | Detail |
|---|---|
| Platform | Azure Functions (PowerShell 7.4), Log Analytics, Sentinel |
| Auth | Two unattended auto-refreshing methods: Credentials+TOTP, Software Passkey. DirectCookies for diagnostic / one-shot use. |
| Scope | Microsoft Defender XDR portal (`security.microsoft.com`) — telemetry streams across 10 functional categories (Endpoint Device Management, Endpoint Configuration, Vulnerability Management, Identity Protection, Configuration & Settings, Exposure Management, Threat Analytics, Action Center, Multi-Tenant Operations, Streaming API). Every stream documented + live-captured. Some streams activate only when the tenant provisions the underlying feature (MDI / TVM / MCAS / Intune / MDO / Custom Collection). |
| Prerequisite | **Existing Sentinel-enabled Log Analytics workspace** (any RG / subscription in the same tenant). This template does NOT create a workspace. |
| Deployment | One-click **Deploy to Azure** (button above) + one `./tools/Initialize-XdrLogRaiderAuth.ps1` run post-deploy. Cross-RG / cross-region workspace supported. |
| Content | 6 workbooks · 14 analytic rules · 9 hunting queries · 6 KQL drift parsers + 47 custom LA tables (45 telemetry + Heartbeat + AuthTestResult) — all auto-deployed via nested ARM. Every parser / rule / query / workbook column reference verified against live fixtures in CI. |
| License | MIT |

XdrLogRaider ingests the tenant-configuration surface that Microsoft's first-party APIs don't expose: suppression rule changes, exclusion list changes, data export destination adds, Live Response policy relaxations, XSPM attack paths + chokepoints + top targets, MDI identity service accounts, Action Center approval history, and more. **Drift happens on the KQL side** (pure query-time) — 6 category-scoped parsers feed 6 workbooks and analytic rules. `RawJson` is stored as `dynamic`; schema evolves without DCR redeploys. Every endpoint response shape is captured as a live fixture in `tests/fixtures/live-responses/` and all parsers + rules + queries + workbooks are verified against those fixtures in CI.

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
- Adds 47 custom tables + a Sentinel Data Connector UI card + 6 parsers / 6 workbooks / 14 analytic rules / 9 hunting queries to your existing workspace (via cross-RG nested deployments — no manual Sentinel-content install)
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

Open **Microsoft Sentinel → Data connectors** in your workspace and find the **XdrLogRaider** card. Within 5–10 minutes of step 2, **Status** flips to **Connected** — that's it. The card reads `MDE_Heartbeat_CL` via the connector's `connectivityCriterias` query, so any successful first poll lights it up.

If it stays Disconnected past 15 minutes, see [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

Production polling timers fire on their cadence: `fast` (10 min) ingests Action Center events first; `inventory` (daily 02:00 UTC) ingests the long-tail settings + identity + metadata streams. See [docs/STREAMS.md](docs/STREAMS.md) for the full per-tier breakdown.

## Documentation

- [Architecture](docs/ARCHITECTURE.md) — components, data flow, trust boundaries
- [Deployment](docs/DEPLOYMENT.md) — step-by-step walkthrough
- **[Permissions](docs/PERMISSIONS.md)** — consolidated setup + runtime + cross-RG reference
- [Auth](docs/AUTH.md) — both methods explained, CA compatibility, rotation
- [Getting Auth Material](docs/GETTING-AUTH-MATERIAL.md) — how to obtain TOTP / passkey / cookies
- [Bring Your Own Passkey](docs/BRING-YOUR-OWN-PASSKEY.md) — generating a software passkey JSON
- [Streams](docs/STREAMS.md) — full catalogue of telemetry streams + per-stream tier + category
- [Streams removed](docs/STREAMS-REMOVED.md) — historical record of removed streams with evidence
- [Workbooks](docs/WORKBOOKS.md) — what each dashboard shows
- [Drift](docs/DRIFT.md) — pure-KQL drift model explained
- [Runbook](docs/RUNBOOK.md) — daily ops, incidents, rotation
- [Troubleshooting](docs/TROUBLESHOOTING.md) — symptom → fix
- [Cost](docs/COST.md) — monthly estimate + tuning levers
- [References](docs/REFERENCES.md) — all sources cited

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
