# Roadmap

Capability ladder for the connector. Each version below is a discrete shipping milestone with explicit deliverables.

The connector's purpose is **portal-only telemetry from Microsoft Defender XDR (and, in v0.2.0+, additional Microsoft 365 portals) that is not exposed by official Microsoft Graph / public APIs**. Surfaces already covered by Microsoft Graph Security or by the Microsoft 365 Defender Public APIs are explicitly out of scope — operators should use the corresponding official Microsoft Sentinel data connectors for those.

---

## v0.1.0 GA — pure Defender connector (current release)

Production-grade unattended ingestion of Microsoft Defender XDR portal-only telemetry into a customer-owned Sentinel workspace.

**Architecture**:

- **72 portal-only data streams** (71 live + 1 deprecated) + 1 operational ops table (XdrConnectorHealth_CL) = 73 streamDecls total, partitioned across **13 DCRs** (per-category split — Azure 10-flow cap respected per DCR) sharing 1 DCE.
- DCR `transformKql='source | extend SourceName='<Stream>''` injects per-stream identity into per-category tables (Microsoft Learn canonical pattern + SourceName-injection).
- **5 cadence tiers** with universal portal-agnostic dispatcher (`Xdr-Refresh` 1-min timer): `ActionCenter` (10 min — 2 streams), `XspmGraph` (1h — 18), `Configuration` (6h — 16), `Inventory` (24h — 27), `Maintenance` (7d — 1+1 deprecated). Tenant-feature-gated streams (MDI / TVM / MCAS / Intune / MDO / Custom Collection) classify dynamically at runtime via `Get-MDEEndpointLastResult.SuccessKind` (live / live-empty / tenant-gated / error).
- **11 consolidated workspace tables**: 10 `Defender_<Category>_CL` per nathanmcnulty 10-category taxonomy + 1 `XdrConnectorHealth_CL` ops table.
- Per-stream typed columns at ingest via DCR `ProjectionMap`; `RawJson` preserved on every row for forensic queries.
- Drift detection via 4 cadence-tier KQL parsers (`MDE_Drift_Configuration` / `MDE_Drift_Inventory` / `MDE_Drift_Exposure` / `MDE_Drift_Maintenance`) using `mv-apply set_union(CurrentFields, PreviousFields)` field-level diff.
- **7 PowerShell modules**: L1 Common (Auth + Manifest + Telemetry) + L1 Sentinel.Ingest + L2 Defender.Auth + L3 Defender.Client + L4 Connector.Orchestrator. Pure Defender connector — no multi-portal stubs in v0.1.0.
- **4 Function App functions** (post Section R consolidation): Xdr-Refresh (universal portal-agnostic dispatcher; 1-min timer reading XdrTierState __schedule__ rows) + Xdr-PollOrchestrator (Durable orchestration; per-tier fan-out) + Xdr-PollStream (Durable activity; per-stream auth/poll/ingest with PerEntityFanout / PerPlatformFanout / Pagination support) + Connector-Heartbeat (5-min timer; aggregates XdrTierState into XdrConnectorHealth_CL).
- Manifest-driven dispatch: 1 `Invoke-MDEEndpoint` for all 71 live streams (no per-stream handlers).
- Auth: Credentials+TOTP + Software Passkey (MFA-enforced unattended) + DirectCookies (test/diagnostic).
- KV TTL cache (60min default) for credential reuse; cache-eviction telemetry to AppInsights.
- DLQ (`xdrIngestDlq`) + checkpoint table (`connectorCheckpoints`) on shared Storage Account, SAMI-accessed.
- AppInsights NATIVE telemetry (no extra workspace diag-settings): `AppRequests` + `AppDependencies` + `AppExceptions` + `AppTraces` + `AppEvents` + `AppMetrics` (incl. `xdr.auth.chain_step_duration_ms` / `xdr.dlq.depth` / `xdr.ingest.row_count_per_hour` cost-budget gate).

**Sentinel content**:

- 10 workbooks: ConnectorHealth (9 panels) + ConnectorOps (Hot-Fix 17 — ingestion velocity + DLQ + auth retry + 429 storms + FA invocation success rate + Hot-Fix 7 truncation events) + DeviceInventory_Unified (Hot-Fix 14 — per-device 360° drilldown across 4 workspace tables) + 7 functional-area dashboards (ActionCenter, ComplianceDashboard, DriftReport, ExposureMap, GovernanceScorecard, IdentityPosture, ResponseAudit).
- 21 analytic rules (14 detection + 7 XdrOps incl. RowVolumeSpike cost-budget runtime gate + StreamWentDry per-stream stale alert + AuthChainStaleness). 16/21 rules with populated `entityMappings` (Account + Host) for Sentinel investigation graph drilldown — 5 XdrOps rules deliberately skip (operator/connector telemetry, not security alerts). All ship `enabled: false` per Microsoft Sentinel Solution best practice.
- 12 hunting queries.
- 4 cadence-tier drift parsers — Hot-Fix 5 cardinality refinement (1 summary "Added"/"Removed" per entity; per-field for "Modified"). Three-path union (modifiedRows + addedRows + removedRows).
- 360+ sample queries (every active stream has 5-query operator anchor; 5 × 71 ≈ 355 + cross-stream queries).

**Supply chain**:

- ARM-only deployment (single hand-authored `mainTemplate.json` source of truth; no Bicep auto-compile).
- Cosign keyless signing (Sigstore Fulcio + Rekor) on 6 release artifacts.
- SBOM SPDX-JSON via Anchore action.
- 8-job CI: secret-scan + lint + unit-tests + static-validate + deploy-whatif + auto-recompile-gate + auto-rezip-gate + coverage-gate.
- Dependabot weekly updates.

---

## v0.1.0.1 — remaining tooling polish (planned patch)

The DCR-per-category refactor SHIPPED in v0.1.0 (13 descriptive DCRs replacing the original 7 bucket-fill). The remaining v0.1.0.1 scope:

- **`tools/Build-SampleQueries.ps1`** — automated regen of the 5-query-per-stream sample set in `XdrLogRaider_DataConnector.json` so column renames don't require manual updates
- **CI: ARM-TTK adoption** — official Microsoft ARM Template Test Toolkit alongside the existing `Validate-ArmJson.ps1`
- **Per-table column data dictionary embedded in workbook hover-text** — operators don't need to leave the workbook to know which stream contributes which column
- **Pester parallelism** — CI run-time reduction
- **Manifest hot-load caching** for cadence-tier duration

> Originally v0.1.0.1 was scoped as the DCR refactor + tooling. The DCR refactor moved up to v0.1.0 and shipped with `tools/Build-DcrSection.ps1`, `tools/Audit-DcrSchema.ps1`, `tools/Verify-CosignArtifacts.ps1`, and `docs/SCHEMA.md`. v0.1.0.1 = polish, not architecture.

### v0.1.0 — DCR per-category refactor (SHIPPED)

Refactored the 7 bucket-fill DCRs (DCR-1 through DCR-7, sequential 10-flow buckets that each span 2-7 categories) into **13 category-scoped DCRs** with descriptive names. Identified during v0.1.0 GA preflight when consolidated-table column-type conflicts (Action/Scope/Tags) surfaced because multiple categories shared a single DCR but their streams had differing column types per shared column.

**Planned scope**:

- **Per-category DCR naming** — each consolidated workspace table gets a dedicated DCR (or 2 if its streams exceed Azure's 10-flow cap):

  | DCR name | Output table | Streams |
  |---|---|---|
  | `xdrlr-dcr-actioncenter` | `Defender_ActionCenter_CL` | 2 |
  | `xdrlr-dcr-configuration-1` | `Defender_ConfigurationAndSettings_CL` | 10 |
  | `xdrlr-dcr-configuration-2` | `Defender_ConfigurationAndSettings_CL` | 4 |
  | `xdrlr-dcr-endpoint-config` | `Defender_EndpointConfiguration_CL` | 9 |
  | `xdrlr-dcr-endpoint-device` | `Defender_EndpointDeviceManagement_CL` | 2 |
  | `xdrlr-dcr-exposure-1` | `Defender_ExposureManagement_CL` | 10 |
  | `xdrlr-dcr-exposure-2` | `Defender_ExposureManagement_CL` | 7 |
  | `xdrlr-dcr-identity` | `Defender_IdentityProtection_CL` | 6 |
  | `xdrlr-dcr-multitenant` | `Defender_MultiTenantOperations_CL` | 3 |
  | `xdrlr-dcr-streaming-api` | `Defender_StreamingApi_CL` | 2 |
  | `xdrlr-dcr-threat-analytics` | `Defender_ThreatAnalytics_CL` | 3 |
  | `xdrlr-dcr-vulnerability-mgmt` | `Defender_VulnerabilityManagement_CL` | 1 |
  | `xdrlr-dcr-ops` | `XdrConnectorHealth_CL` | 1 |

  Total: 13 DCRs (was 7), 60 streamDecls (unchanged).

- **Build script** (`tools/Build-DcrSection.ps1`) emits the DCR section + `DCR_IMMUTABLE_IDS_JSON` env-var construction + RBAC role-assignments deterministically from the manifest. ARM template stays hand-authored everywhere except this auto-regen window.
- **CI gate** updated: `SchemaConsistency.Tests.ps1` already enforces type consistency; bucket-fill cap tightens from 7 categories per DCR to 1.
- **RBAC**: 13 Monitoring Metrics Publisher role-assignments per DCR (was 7), 1 KV Secrets User, 1 Storage Table Data Contributor = 15 total (was 9).

**Operator impact**:

- Backward-compatible. Existing `Defender_<Category>_CL` tables + KQL queries continue to work UNCHANGED.
- Operator sees 13 DCRs in the connector RG instead of 7 — descriptive names make the topology self-documenting.
- Re-deploy migrates DCRs cleanly (workspace tables persist, only DCR resources replaced).

**Additional v0.1.0.1 scope (gaps surfaced during v0.1.0 GA preflight)**:

- **`tools/Build-DcrSection.ps1`** — codegen for the DCR resource block + `DCR_IMMUTABLE_IDS_JSON` env-var construction + RBAC role-assignments matrix. Eliminates the 1000-line hand-edit risk that introduced the column-conflict class in v0.1.0 GA.
- **`tools/Audit-DcrSchema.ps1`** — operator-runnable audit (mirror of `tests/arm/SchemaConsistency.Tests.ps1`) so they can verify schema integrity locally before deploying without invoking Pester.
- **`tools/Verify-CosignArtifacts.ps1`** — one-command Sigstore-cosign verify-blob over all 6 release artifacts; today operators copy/paste 6 separate commands.
- **Per-table data dictionary** in `docs/SCHEMA.md` — for each `Defender_<Category>_CL` table, list every column (typed + RawJson) with its source stream, type, and example. Closes the "which stream contributes which column" knowledge gap.
- **Sample-query refresh** — 5 queries per stream × 72 streams = 360 sample queries in `XdrLogRaider_DataConnector.json` need automated regen (`tools/Build-SampleQueries.ps1`) when columns are renamed. Today renames require manual sample-query updates.
- **CI: ARM-TTK** — adopt the official Microsoft ARM Template Test Toolkit alongside the existing `Validate-ArmJson.ps1`. Catches Marketplace-grade issues (apiVersion drift, idempotency, parameter coverage) before the v1.0.0 certification window.
- **CI: Deploy what-if with role-assignments** — grant the GitHub Actions SP `User Access Administrator` so what-if runs the full 32+15-role-assignment template and not the stripped 32-resource subset.
- **Per-tenant column documentation** — list "which streams populate which columns" in the workbook's hover text, so operators don't have to read `docs/SCHEMA.md`.

**Why deferred from v0.1.0 GA**: scope. v0.1.0 GA shipped with the column-type conflicts properly fixed via per-stream rename (no fallbacks) AND a CI gate (`SchemaConsistency.Tests.ps1`) preventing regression — the deployment works correctly today with full type fidelity. The above items are topology and developer-experience improvements, not functional bugs, so they ship as a separate v0.1.0.1 patch with its own observation cycle.

---

## v0.2.0 — multi-portal expansion + Function App multi-tenancy

Reintroduces multi-portal modules (with real bodies, not stubs) and adds Function App multi-tenancy support so one connector deployment polls multiple Defender (and v0.2.0+ Entra/Purview/Intune) tenants.

**Planned scope**:

- New L2 Auth + L3 Client modules: `Xdr.Entra.Auth` + `Xdr.Entra.Client` + `Xdr.Purview.Auth` + `Xdr.Purview.Client` + `Xdr.Intune.Auth` + `Xdr.Intune.Client` (6 modules — back from v0.2.0+ deferral).
- Per-portal workspace tables: `Entra_<Category>_CL`, `Purview_<Category>_CL`, `Intune_<Category>_CL` under the same nodoc 10-category taxonomy.
- `XdrConnectorHealth_CL.Portal` column populated with non-Defender values.
- Function App multi-tenancy: per-tenant secret namespacing in KV (`mde-portal-{tenant}-password` etc.). `Initialize-XdrLogRaiderAuth.ps1` adds multi-tenant seeding. New ARM parameters for tenant configuration matrix.
- Coverage gate raised to ≥75% (v0.1.0 GA Phase 5 reaches ≥50% intermediate).
- Pester parallelism for faster CI.
- Manifest hot-load caching for cadence-tier duration.

**Operator impact**:

- Existing `Defender_<Category>_CL` tables + KQL queries continue to work UNCHANGED.
- New ARM parameters for tenant matrix; existing single-tenant deploy stays valid.

---

## v1.0+ — Microsoft Sentinel Solution Gallery listing

Submission to the Microsoft Sentinel Content Hub Solutions Gallery as a partner-validated solution.

**Planned scope**:

- Multi-region / multi-tenant production matrix testing.
- Premium hosting plan default (Flex Consumption / EP1) for regulated workloads with `restrictPublicNetwork=true` and Private Endpoints.
- Solution Gallery package signed + partner-validated.
- ≥3 Solution Gallery screenshots demonstrating connector card + workbooks + analytic rule integration.

---

## Out of scope (architectural exclusions)

- **Container Apps migration**: Y1 Linux Consumption is sufficient for projected stream volume + cadence.
- **FA-side content-hash dedup**: drift parsers + time-series model already solve change detection.
- **Operator-side `arg_max` in ops queries**: drift parsers do change detection internally; operators query parser output.
- **Backward-compat code paths for v0.1.0 GA migration**: v0.1.0 is a clean baseline; no migration code paths kept.
