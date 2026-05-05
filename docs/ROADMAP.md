# Roadmap

Capability ladder for the connector. Each version below is a discrete shipping milestone with explicit deliverables.

The connector's purpose is **portal-only telemetry from Microsoft Defender XDR (and, in v0.2.0+, additional Microsoft 365 portals) that is not exposed by official Microsoft Graph / public APIs**. Surfaces already covered by Microsoft Graph Security or by the Microsoft 365 Defender Public APIs are explicitly out of scope — operators should use the corresponding official Microsoft Sentinel data connectors for those.

---

## v0.1.0 GA — pure Defender connector (current release)

Production-grade unattended ingestion of Microsoft Defender XDR portal-only telemetry into a customer-owned Sentinel workspace.

**Architecture**:

- **59 portal-only data streams** + 1 operational heartbeat = 60 streams total, partitioned across **7 DCRs** (4×10 + 5(7) + 6(7) + 7(6) — Azure 10-flow cap respected) sharing 1 DCE.
- DCR `transformKql='source | extend SourceName='<Stream>''` injects per-stream identity into per-category tables (Microsoft Learn canonical pattern + SourceName-injection).
- **5 cadence tiers** with dedicated timer functions: `fast` (10 min — 2 streams), `exposure` (1h — 18), `config` (6h — 16), `inventory` (daily — 21), `maintenance` (weekly — 1). Tenant-feature-gated streams (MDI / TVM / MCAS / Intune / MDO / Custom Collection) skip cleanly when the tenant feature isn't licensed.
- **11 consolidated workspace tables**: 10 `Defender_<Category>_CL` per nathanmcnulty 10-category taxonomy + 1 `XdrConnectorHealth_CL` ops table.
- Per-stream typed columns at ingest via DCR `ProjectionMap`; `RawJson` preserved on every row for forensic queries.
- Drift detection via 4 cadence-tier KQL parsers (`MDE_Drift_Configuration` / `MDE_Drift_Inventory` / `MDE_Drift_Exposure` / `MDE_Drift_Maintenance`) using `mv-apply set_union(CurrentFields, PreviousFields)` field-level diff.
- **7 PowerShell modules**: L1 Common (Auth + Manifest + Telemetry) + L1 Sentinel.Ingest + L2 Defender.Auth + L3 Defender.Client + L4 Connector.Orchestrator. Pure Defender connector — no multi-portal stubs in v0.1.0.
- **8 Function App functions**: Connector-Heartbeat (5min) + 5 Defender-{Tier}-Refresh timers + Xdr-PollOrchestrator (Durable orchestration) + Xdr-PollStream (Durable activity).
- Manifest-driven dispatch: 1 `Invoke-MDEEndpoint` for all 59 streams (no per-stream handlers).
- Auth: Credentials+TOTP + Software Passkey (MFA-enforced unattended) + DirectCookies (test/diagnostic).
- KV TTL cache (60min default) for credential reuse; cache-eviction telemetry to AppInsights.
- DLQ (`xdrIngestDlq`) + checkpoint table (`connectorCheckpoints`) on shared Storage Account, SAMI-accessed.
- AppInsights NATIVE telemetry (no extra workspace diag-settings): `AppRequests` + `AppDependencies` + `AppExceptions` + `AppTraces` + `AppEvents` + `AppMetrics` (incl. `xdr.auth.chain_step_duration_ms` / `xdr.dlq.depth` / `xdr.ingest.row_count_per_hour` cost-budget gate).

**Sentinel content**:

- 8 workbooks (incl. ConnectorHealth with 9 panels: per-tier freshness, auth-chain failures, DLQ depth, freshness SLI, partial-success rate, service-account anomaly, per-stream workspace-side freshness).
- 20 analytic rules (14 detection + 6 XdrOps incl. RowVolumeSpike cost-budget runtime gate). All ship `enabled: false` per Microsoft Sentinel Solution best practice.
- 9 hunting queries.
- 4 cadence-tier drift parsers.
- 390 sample queries (every active stream has 5-query operator anchor).

**Supply chain**:

- ARM-only deployment (single hand-authored `mainTemplate.json` source of truth; no Bicep auto-compile).
- Cosign keyless signing (Sigstore Fulcio + Rekor) on 6 release artifacts.
- SBOM SPDX-JSON via Anchore action.
- 8-job CI: secret-scan + lint + unit-tests + static-validate + deploy-whatif + auto-recompile-gate + auto-rezip-gate + coverage-gate.
- Dependabot weekly updates.

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
