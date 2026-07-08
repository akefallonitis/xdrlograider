# Privacy Policy · XdrLogRaider v0.1.0

**Effective**: 2026-06-01
**Maintainer**: Alex Kefallonitis · al.kefallonitis@gmail.com
**Repository**: https://github.com/akefallonitis/xdrlograider

## What this connector does

XdrLogRaider is a Microsoft Sentinel data connector that polls **Microsoft Defender XDR portal-internal operations** (`security.microsoft.com/apiproxy/*` across Defender sub-portal namespaces · mtp · mcas · mdi · aatp · mdc · etc.) on a per-tenant basis and ingests the responses into `Defender_<Category>_CL` custom tables in your Log Analytics workspace.

The connector runs **entirely within your Azure subscription** as an Azure Functions resource. It uses cookie-based authentication (Entra ID MFA TOTP/Passkey + KMSI SSO 90-day persistent session) to access your tenant's Defender data.

## What data is collected

The connector collects exactly the Defender categories its deployed manifest declares — the set selected by the cataloguing ship-gate (it only ever polls what is in that manifest, and it grows per-category as the catalogue is curated). v0.1.0 ships **11 categories**, each landing in its own `Defender_<Category>_CL` table:

- **AnalyticsData** (`Defender_AnalyticsData_CL`) — Threat Analytics outbreaks / top-threats / custom-detection analytics.
- **AttackSimulation** (`Defender_AttackSimulation_CL`) — attack-simulation training campaigns + payloads.
- **CloudApps** (`Defender_CloudApps_CL`) — Defender for Cloud Apps (MCAS) policies + settings.
- **Configuration** (`Defender_Configuration_CL`) — tenant / endpoint configuration state.
- **EndpointManagement** (`Defender_EndpointManagement_CL`) — device inventory · groups · tags · timelines · RBAC scopes · NDR.
- **ExposureManagement** (`Defender_ExposureManagement_CL`) — security-posture + posture-oversight initiatives / metrics / recommendations + ASR rule states + TVM risk score.
- **Identity** (`Defender_Identity_CL`) — identity inventory + audits + risk signals.
- **Operations** (`Defender_Operations_CL`) — Action Center action history + automation rules + multi-tenant context.
- **PortalServices** (`Defender_PortalServices_CL`) — portal-services data.
- **SecureScore** (`Defender_SecureScore_CL`) — secure-score metrics + control profiles.
- **VulnerabilityManagement** (`Defender_VulnerabilityManagement_CL`) — TVM vulnerability + change telemetry.

Each operation **dynamically capability-gates** — it ships in the manifest and lights up only on a tenant that licenses the underlying Defender product, so a category's table may be empty if your tenant lacks that product. To see precisely which categories are active and populated in your environment, inspect the `Defender_*_CL` table names in your Log Analytics workspace: one table per active category (`Defender_<Category>_CL`), each holding the records polled for that category.

**Raw payloads:** every ingested row carries a `RawJson` column containing the COMPLETE raw API response for that record (the typed columns are a faithful projection of it · a 240 KB safety clamp prevents oversized-row truncation). The data collected is exactly what the Defender portal returns for the polled operations — nothing is added, and nothing is sent elsewhere.

**Roadmap (NOT yet collected — candidate categories added per-category as data in later increments, each via this same Privacy contract):** Files, ThreatAnalytics, DataLake, EntityPivots, and similar Defender Categories. Adding a Category is a curation-data change. (To confirm exactly what is collected today, always inspect the `Defender_*_CL` table names in your workspace rather than this list.)

## What we DO NOT collect

- **No data leaves your Azure subscription.** The connector runs inside your subscription and writes to your Log Analytics workspace.
- **No telemetry is sent to the maintainer or any third party.** Maintainer has zero access to your data.
- **No usage analytics.** The connector does not "phone home".
- **Credentials never leave Key Vault.** Service account credentials (UPN + password + TOTP + optional Passkey PEM) are stored in your Key Vault and accessed only by the Function App's Managed Identity at runtime.

## Where data is stored

- **Log Analytics workspace**: `Defender_<Category>_CL` custom tables in your designated workspace
- **Function App Storage Account**: Durable Function state · authentication session cache · checkpoint cursors · circuit-breaker state · DCR map (no portal data — orchestration state only)
- **Application Insights**: Telemetry events (no payload data — only event names + properties for operational diagnostics)
- **Dead Letter Queue (DLQ)**: Failed ingestion entries that exceed retry budget · stored in `XdrIngestDlq` Storage Table for operator inspection

## Data retention

Retention is controlled by your Log Analytics workspace settings (default 30 days, configurable up to 730 days). The connector does NOT modify your workspace retention.

DLQ entries: persist in the `XdrIngestDlq` Storage Table until an operator drains them (the dlq-drain runbook).
Azure Storage Tables have NO automatic TTL/expiry — the connector does not delete DLQ rows; plan periodic drains.

Authentication session cache: TTL based on cookie expiry (sccauth ~2 hours, ESTSAUTHPERSISTENT KMSI 90 days).

## Data handling

- All data in flight uses TLS 1.2+ (enforced).
- All data at rest is encrypted by Azure platform encryption.
- Function App uses Managed Identity (no SAS tokens · no connection strings with keys for v0.1.0 GA · LOCK 31 binding).
- Key Vault access via Managed Identity with `Get Secrets` permission only.
- Log Analytics workspace access via DCE → DCR ingestion path with MMP (Monitoring Metrics Publisher) RBAC role.

## Third party services used

- **Microsoft Entra ID** (authentication · your tenant)
- **Microsoft Defender XDR portal** (data source · `security.microsoft.com/apiproxy/*`)
- **Microsoft Sentinel + Log Analytics** (data destination · your workspace)
- **GitHub Releases** (signed Function App zip artifact distribution · `github.com/akefallonitis/xdrlograider/releases`)
- **cosign / Sigstore Rekor** (code signing · transparency log)

## User rights

You retain full control over:
- Your Log Analytics workspace data (you can delete tables at any time)
- Your Function App (you can stop or delete it at any time)
- Your service account credentials (you control Key Vault contents)

## Contact

For privacy questions: al.kefallonitis@gmail.com

For security disclosures: open a private security advisory at https://github.com/akefallonitis/xdrlograider/security/advisories/new
