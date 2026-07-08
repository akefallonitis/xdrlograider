# XdrLogRaider — Roadmap

XdrLogRaider is a Microsoft Sentinel data connector for Microsoft Defender XDR's
portal-internal `/apiproxy/*` surface — the audit, reporting, configuration, and posture
endpoints that have no public REST API equivalent. It exists for authorized purple-team and
detection-engineering work: bulk, read-only ingestion of Defender telemetry that Sentinel
can query natively, with paired KQL detections.

This document describes **what ships today** and **where the connector can go next**. The
key idea for the roadmap is architectural:

> **The engine is portal-agnostic. Coverage is data.** The runtime (`src/`) doesn't know
> anything about Defender specifically — it drives a generic `/apiproxy`-style HTTP surface
> using pagination, time-filter, and per-tenant capability-gating mechanisms that are
> configured entirely by generated manifests and schemas. Any Microsoft portal that exposes
> the same shape of surface can be added as **pure data + regeneration**, with no engine
> changes. That makes the non-Defender portals below a genuine expansion surface, not a
> rewrite — and it's where contributions are most welcome.

---

## Release horizons

Coverage is data; the engine is done. The versioned roadmap:

| Version | Theme | What lands |
|---|---|---|
| **0.1.0 — GA (now)** | Engine + Defender XDR | The generic, self-healing ingestion engine · the full dynamically-curated Defender XDR surface · multi-portal headless service-account auth · dynamic per-tenant product/capability discovery · one-click ARM deploy · release-to-`latest`. |
| **0.2.0 — Content & Marketplace** | Turnkey in Sentinel | Paired **Sentinel content** — analytics rules, workbooks, hunting queries, and configuration-drift detections over the `_CL` tables · **Content Hub** packaging · **Azure Marketplace** listing (a StaticUI Function-App connector built through the Sentinel `createSolutionV3` solution pipeline). |
| **Selective ingestion** *(engine capability)* | Ingest only what you choose | Per-tenant **category/stream selection** — all tables/DCRs are onboarded at install (empty tables are free; cost is per-ingestion), and a runtime selection gate (`XDRLR_ENABLED_CATEGORIES` app setting) controls what actually polls · a deploy-time **setup UI** (`createUiDefinition` multi-select) to pick at install and change later, composing with the existing per-product discovery gate — so a category polls only when *user-enabled ∩ product-present ∩ cadence-due*. |
| **0.3.0 — Multi-portal** | Beyond Defender | Active ingestion for the other Microsoft portals below (Entra, M365, Purview, Intune, Teams, SharePoint, Exchange, Viva, Security Copilot, Power Platform) — the engine is already portal-agnostic; per-portal auth-cookie/ESTS extraction is the remaining gate. |

After 0.1.0, everything is **data expansion** — the engine itself does not change.

---

## Shipped: Microsoft Defender XDR (v0.1.0)

The shipped surface is **11 Defender categories**, each derived from the nodoc OpenAPI
`x-tagGroups` corpus and each landing into its own typed Log Analytics table
(`Defender_<Category>_CL`). Every operation is **capability-gated (F18)**: it activates only
on a tenant that licenses the underlying product, so a connector deployed to a tenant that
lacks (say) Defender for Identity simply doesn't emit those rows rather than erroring.

The categories are the ground truth in `manifests/Defender/*.psd1`. Per-operation counts are
**generated, never hardcoded** — the authoritative, always-current catalogue (operation
counts, streams, cadence, held/shipped status) is produced by the derivation engine into
`docs/CATALOGUE.md`. Treat that generated document as the source of truth for numbers; the
table below is the durable shape.

| Category | Log Analytics table | What it captures |
|---|---|---|
| **AnalyticsData** | `Defender_AnalyticsData_CL` | Threat Analytics reports and enrichment data. |
| **AttackSimulation** | `Defender_AttackSimulation_CL` | Attack Simulation Training campaigns and results. |
| **CloudApps** | `Defender_CloudApps_CL` | Defender for Cloud Apps and App Governance posture. |
| **Configuration** | `Defender_Configuration_CL` | Tenant/endpoint configuration and Attack Surface Reduction settings. |
| **EndpointManagement** | `Defender_EndpointManagement_CL` | Endpoint device inventory and endpoint configuration. |
| **ExposureManagement** | `Defender_ExposureManagement_CL` | Exposure Management posture, initiatives, and metrics. |
| **Identity** | `Defender_Identity_CL` | Defender for Identity audits (e.g. dormant/at-risk accounts). |
| **Operations** | `Defender_Operations_CL` | Action Center history, Multi-Tenant, and Streaming API configuration. |
| **PortalServices** | `Defender_PortalServices_CL` | Portal service and platform metadata. |
| **SecureScore** | `Defender_SecureScore_CL` | Microsoft Secure Score controls and history. |
| **VulnerabilityManagement** | `Defender_VulnerabilityManagement_CL` | Threat & Vulnerability Management (TVM) inventory and findings. |

Each row carries a fixed 9-column envelope — `TimeGenerated`, `Portal`, `Category`,
`Subcategory`, `Operation`, `RecordId`, `ParentRecordId`, `CorrelationId`, `RawJson` — plus
the typed columns projected for that operation. The full raw response is retained per row in
`RawJson`, so nothing is lost even where the typed projection is partial.

**Deliberately excluded** (and enforced by `tools/Validate-Scope.ps1`): `advanced_hunting`,
`alerts_incidents`, and `live_response`. These already have supported public APIs or are out
of scope for a bulk audit/reporting connector.

### Near-term Defender work

- Deepen per-category operation coverage where the nodoc corpus and live captures support it
  (tracked as generated deltas in `docs/CATALOGUE.md`).
- Broaden paired KQL detection content for shipped categories.
- Continue hardening unattended auth (KMSI 90-day SSO refresh) and exactly-once ingestion.

---

## Planned: the portal expansion surface

The `references/` corpus already contains **research inventory (nodoc OpenAPI + Postman
collections)** for a range of non-Defender Microsoft portals — captured because they share
the same portal-internal `/apiproxy` architecture the engine already drives. These are the
**expansion surface**: each is a candidate for the same derive → catalogue → manifest →
schema → deploy pipeline that produces the Defender connector, with no engine changes.

They are **research, not shipped coverage.** The figures below are the size of the captured
research corpus (from `references/inventory/portals.json`), not commitments — the engine
re-derives and curates every operation from RAW at build time, and each portal ships only
after its categories are individually onboarded, verified live, and human-read.

| Portal (research family) | Corpus keys under `references/inventory/` | Indicative corpus size |
|---|---|---|
| **Entra ID / Azure IAM** | `nodoc-entra-b2c`, `nodoc-entra-idgov`, `nodoc-entra-iga`, `nodoc-entra-pim`, `nodoc-ibiza-iam` | ~36 categories · ~336 ops |
| **Microsoft 365 admin & apps** | `nodoc-m365-admin`, `nodoc-m365-apps-config`, `nodoc-m365-apps-inventory`, `nodoc-m365-apps-services` | ~27 categories · ~339 ops |
| **Microsoft Purview** | `nodoc-purview`, `nodoc-purview-portal` | ~19 categories · ~132 ops |
| **Microsoft Intune** | `nodoc-intune-autopatch`, `nodoc-intune-portal` | ~2 categories · ~58 ops |
| **Microsoft Teams** | `nodoc-teams` | ~1 category · ~99 ops |
| **SharePoint (admin)** | `nodoc-sharepoint-admin` | ~1 category · ~41 ops |
| **Exchange** | `nodoc-exchange-beta` | ~1 category · ~61 ops |
| **Power Platform** | `nodoc-power-platform` | ~9 categories · ~244 ops |
| **Microsoft Viva** | `nodoc-viva-engage` | ~1 category · ~5 ops |
| **Security Copilot** | `nodoc-security-copilot` | ~1 category · ~32 ops |

Notes:

- **Nothing above is enabled by default.** The shipped connector is Defender-only. A portal
  moves from research to shipped only through the full onboard-and-prove workflow.
- Some corpus files are infrastructure schemas with no operations and are skipped by the
  inventory step; the engine records those explicitly rather than inheriting a count.
- Priority is demand-driven. If a portal matters for your engagements, open an issue — that
  signal shapes ordering.

---

## How to contribute a stream, category, or portal

The roadmap is executable by contributors. Adding coverage is a data-and-regeneration
exercise, not an engine rewrite. Three scopes, smallest to largest:

- **Add a stream** — a new operation in an existing category.
- **Add a category** — a new Defender `x-tagGroup` with its own table and DCR stream.
- **Add a portal** — bring one of the expansion-surface portals above into the shipped set.

The step-by-step for all three — the derivation-engine pipeline
(`Build-EvidenceIndex → Build-Catalogue → Generate-Manifest → Build-PerCategorySchema →
Build-MainTemplate`), the deny-by-default public allowlist, the 38-axis pre-push gauntlet,
and the live prove-it-lands verification — is in **[CONTRIBUTING.md](../CONTRIBUTING.md)**.

---

*XdrLogRaider is an independent, open-source (MIT) project — not a Microsoft product. It reads
undocumented, unsupported Defender XDR portal-internal APIs that may change without notice.
Use only against tenants you own or are explicitly authorized to test.*
