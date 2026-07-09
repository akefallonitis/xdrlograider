# XdrLogRaider

An open-source Microsoft Sentinel data connector for the **Microsoft Defender XDR portal-internal endpoints** — the audit, reporting, configuration, and posture surfaces that have no public REST API equivalent.

**Shipped surface:** v0.1.0 ships **123 read-only operations across 11 Defender categories** into 11 typed Sentinel tables — see the [operation catalogue](docs/CATALOGUE.md) (generated, always current). Each operation dynamically capability-gates (F18) and lights up only on a tenant that licenses the underlying product.

> **Disclaimer:** XdrLogRaider reads Defender XDR portal-internal (undocumented) APIs — these are unsupported by Microsoft and may change or break without notice. Use at your own risk; this is **not** a Microsoft product.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fakefallonitis%2Fxdrlograider%2Fmain%2Fdeploy%2FmainTemplate.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fakefallonitis%2Fxdrlograider%2Fmain%2Fdeploy%2FcreateUiDefinition.json)

## Why this exists

Microsoft Defender XDR documents three public API surfaces: Advanced Hunting, Incidents, and Streaming. Everything else — Action Center history, Configuration changes, Exposure Management posture, Identity dormant-account audits, Threat Analytics enrichments, and similar — lives behind the portal's internal `/apiproxy/*` HTTP surface with no Microsoft-supported export path. Security teams that need bulk audit and reporting coverage of those surfaces have nothing standardized to deploy.

This connector closes that gap. It runs as a self-hosted Azure Function App in the customer's subscription, authenticates as a dedicated service account, and ingests Defender XDR portal-internal responses into custom Log Analytics tables that Sentinel queries natively.

## Prior research & acknowledgments

XdrLogRaider is a production consumer of Defender XDR's undocumented, portal-internal `/apiproxy/*` surface — it did not discover that surface. It gratefully builds on the security-research community that first mapped it (all used under their MIT licenses):

- **[DefenderHarvester](https://github.com/olafhartong/DefenderHarvester)** (Olaf Hartong, MIT) — the pioneering public tool that proved this telemetry could be harvested to a SIEM. Microsoft has since hardened the `/apiproxy` layer against it. Closing that gap is exactly what XdrLogRaider does — by authenticating **through** the portal the way a browser does, rather than bypassing the proxy.
- **[XDRInternals](https://github.com/MSCloudInternals/XDRInternals)** (Fabian Bader & Nathan McNulty, MIT · ~124★) — the community module documenting programmatic Defender XDR portal access. Our in-tree auth **adapts the delegated sign-in patterns it establishes** — the ESTS cookie chain with TOTP and passkey/FIDO2 MFA (the two methods we implement) — and we cross-validate pagination / time-filter / sub-portal conventions against it.
- **nodoc OpenAPI** — the endpoint-surface authority: the community Defender spec (576 portal-internal paths across 14 `x-tagGroups`) our catalogue is derived from and checked against. The same corpus spans other Microsoft portals (Entra, M365, Purview, Teams, Intune, …) as the [expansion surface](docs/ROADMAP.md).

These are undocumented, unsupported APIs that may change without notice; XdrLogRaider is **not** a Microsoft product. Full lineage, the `/apiproxy` auth model, and how this connector differs from a one-off harvester: **[docs/PRIOR-RESEARCH.md](docs/PRIOR-RESEARCH.md)**.

## Goals

- **Deploy in one click** to any Sentinel-enabled workspace via the Deploy-to-Azure button.
- **Run unattended** after the initial deploy — no operator interaction in steady state.
- **Survive cookie + KMSI rotation** transparently — 90-day SSO with silent refresh; full headless re-auth fires roughly four times per year.
- **Surface every event as a typed row** — one Sentinel row per Defender event, with the full raw response retained per row.
- **Extend per Category** without source code changes — new Defender Categories activate via manifest entries.
- **Stay observable** — every cycle, auth tier, parse outcome, and ingest result emits an AppInsights event with a correlation id.

## How it works

| | |
|---|---|
| Compute | Azure Functions · Y1 Linux Consumption · PowerShell 7.4 |
| Trigger | Durable Functions (TimerTrigger → Orchestrator → Activity fan-out) |
| Auth | Entra ID MFA (TOTP or Passkey) + KMSI 90-day SSO · fully unattended · single-flight via Azure Blob Lease |
| State | Azure Storage Tables (session · checkpoint · capabilities · DLQ · circuit breaker) via HttpClient REST |
| Data path | `/apiproxy/<sub-portal>/<path>` → Function App → Data Collection Rule → Log Analytics workspace |
| Tables | `Defender_<Category>_CL` · per-Category typed columns + 9-col envelope (TimeGenerated · Portal · Category · Subcategory · Operation · RecordId · ParentRecordId · CorrelationId · RawJson) |
| Sentinel content | V3 `dataConnectorDefinitions` + `contentPackages` (connector card · sample KQL · solution metadata) |
| Identity model | System-assigned managed identity · no service principal secrets in CI · Key Vault stores operator credentials |
| Cost profile | Y1 Consumption (free tier covers typical workload) + Log Analytics ingestion |

## Coverage

<!-- CATALOGUE:START -->
<!-- GENERATED by dev-tools/Export-CatalogueDoc.ps1 -- do not hand-edit. -->

**Shipped surface (v0.1.0):** 123 read-only operations across 11 Defender categories / 11 Sentinel tables / 16 streams. A further 476 operations are catalogued and deliberately held (see [docs/CATALOGUE.md](docs/CATALOGUE.md)).

| Category | Sentinel table | Ops | Streams | Cadence | Value class |
|---|---|---:|---:|---|---|
| Analytics & Data | `Defender_AnalyticsData_CL` | 3 | 1 | Hourly (T2) x3 | CoreTelemetry x3 |
| Attack Simulation | `Defender_AttackSimulation_CL` | 4 | 1 | Hourly (T2) x3, 6-hourly (T3) x1 | ConfigState x1, CoreTelemetry x3 |
| Cloud Apps | `Defender_CloudApps_CL` | 9 | 2 | Hourly (T2) x1, 6-hourly (T3) x8 | ConfigState x8, CoreTelemetry x1 |
| Configuration | `Defender_Configuration_CL` | 20 | 1 | 6-hourly (T3) x20 | ConfigState x11, CoreTelemetry x9 |
| Endpoint Management | `Defender_EndpointManagement_CL` | 25 | 2 | Hourly (T2) x17, 6-hourly (T3) x8 | ConfigState x8, CoreTelemetry x17 |
| Exposure Management | `Defender_ExposureManagement_CL` | 16 | 2 | 6-hourly (T3) x16 | ConfigState x2, CoreTelemetry x14 |
| Identity | `Defender_Identity_CL` | 18 | 1 | Hourly (T2) x9, 6-hourly (T3) x9 | ConfigState x9, CoreTelemetry x9 |
| Operations | `Defender_Operations_CL` | 9 | 3 | 10-min (T1) x3, 6-hourly (T3) x6 | ConfigState x7, CoreTelemetry x2 |
| Portal Services | `Defender_PortalServices_CL` | 4 | 1 | Hourly (T2) x4 | CoreTelemetry x4 |
| Secure Score | `Defender_SecureScore_CL` | 5 | 1 | Hourly (T2) x4, 6-hourly (T3) x1 | CoreTelemetry x5 |
| Vulnerability Management | `Defender_VulnerabilityManagement_CL` | 10 | 1 | Daily (T4) x10 | ConfigState x2, CoreTelemetry x8 |
| **Total** | **11 tables** | **123** | **16** | 10-min (T1) x3, Hourly (T2) x41, 6-hourly (T3) x69, Daily (T4) x10 | ConfigState x48, CoreTelemetry x75 |

Full operation-level detail: [docs/CATALOGUE.md](docs/CATALOGUE.md).
<!-- CATALOGUE:END -->

## Prerequisite — service account

Before deploying, create the dedicated account the connector signs in as:

1. **Create a cloud Entra ID user** in your tenant (e.g., `xdrlogreader@yourdomain.com`).
2. **Grant it read access to Defender XDR** — least-privilege **Microsoft Defender Unified RBAC** (recommended) or **Security Reader**. The connector is read-only; no write or admin roles are needed. See **[docs/RBAC.md](docs/RBAC.md)** for the exact roles, and **[docs/SECURITY-CONSIDERATIONS.md](docs/SECURITY-CONSIDERATIONS.md)** for why this unattended account should be scoped tightly and monitored.
3. **Register an MFA method whose secret you can export** — either a **TOTP** authenticator (keep the base32 seed shown at setup · recommended) or a **passkey** (keep its private-key PEM). The connector satisfies MFA headlessly.
4. **Set a password** you control (the deploy stores it in Key Vault, encrypted at rest).

The deploy asks for this account's UPN, password, MFA method, and the seed/PEM above.

## Deploy steps

1. Click **Deploy to Azure**.
2. Provide a resource group, a Sentinel-enabled Log Analytics workspace, and the service account UPN.
3. Choose the MFA method: TOTP seed or Passkey PEM.
4. Submit. ARM provisions Key Vault, Storage, Application Insights, Data Collection Endpoint, the Function App, and the Sentinel content package. The first cycle fires within ~1 minute of cold-start; the connector card transitions to Connected within ~10 minutes.

## Security model

The connector is **read-only**. No manifest entry uses an action verb (no approve / isolate / delete / restart); the scope validator rejects them at build time. The Function App's managed identity has Key Vault Secrets User, Storage Table + Blob + Queue Data Contributor (Queue is required for the Durable Functions control plane on a shared-key-disabled account), and Monitoring Metrics Publisher — nothing else. Operator credentials live in Key Vault; the Storage account has shared-key access disabled.

## Updates

The Function App runs from package: `WEBSITE_RUN_FROM_PACKAGE` is set (via the `functionAppPackageUri` ARM parameter) to a **version-pinned** release URL — `releases/download/v<connectorVersion>/function-app.zip`, derived from the template's `connectorVersion` — so a deploy always pulls the matching GA build and a restart re-adopts it. (It is a single-redirect URL that Azure's run-from-package fetcher can follow; a `releases/latest/…` pointer double-redirects and will not mount.) To pin a specific build, pass `functionAppPackageUri` explicitly (`releases/download/<tag>/function-app.zip`); the Function App then stays on that build until you change it.

Each release is built and published by `.github/workflows/release.yml`, which keyless-signs `function-app.zip` (and the Sentinel solution package, the SBOM, and `SHA256SUMS`) with cosign/Sigstore, generates an SPDX 2.3 SBOM, and publishes a `SHA256SUMS` checksum file alongside the signed `.cosign.bundle` artifacts on the GitHub release.

## Documentation

- **[docs/SETUP.md](docs/SETUP.md)** — service account + unattended MFA (TOTP / passkey) enrollment and deploy.
- **[docs/RBAC.md](docs/RBAC.md)** — least-privilege Defender Unified RBAC vs Security Reader.
- **[docs/SECURITY-CONSIDERATIONS.md](docs/SECURITY-CONSIDERATIONS.md)** — unattended-account posture + guardrails.
- **[docs/CRED-FLOW.md](docs/CRED-FLOW.md)** — how credentials flow (deploy → Key Vault → managed identity).
- **[docs/CATALOGUE.md](docs/CATALOGUE.md)** — the generated operation catalogue (shipped + held).
- **[docs/ROADMAP.md](docs/ROADMAP.md)** — release horizons (content · marketplace · selective ingestion · multi-portal).
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — add a stream, category, or portal.

## License

[MIT](LICENSE) · see also [PRIVACY](PRIVACY.md) · [TERMS](TERMS.md) · [SECURITY](SECURITY.md).

## Maintainer

**Alex Kefallonitis** · [al.kefallonitis@gmail.com](mailto:al.kefallonitis@gmail.com) · [LinkedIn](https://www.linkedin.com/in/alex-kefallonitis-3a8739a7)
