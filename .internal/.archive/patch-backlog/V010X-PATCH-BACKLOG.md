# v0.1.0.x Patch Backlog

> Per user directive (2026-05-09): **v0.1.0.x scope = MORE Defender endpoints + tiers DOCUMENTATION only** (no v0.2.0 multi-portal/multi-tenant work until v0.1.0 GA stable).

This file enumerates planned post-GA patches in priority order. Each patch is a single coordinated change set with its own observation cycle.

## v0.1.0.1 — Coverage uplift to ≥80%

**Effort**: 6-12 hours
**Owner**: dev
**Why**: line coverage today is 71%; senior architect target 80%

**Scope (5 mock-based test files per Plan R-Final.1.A-E)**:
- `tests/unit/Auth.ErrorPaths.Tests.ps1` (extend; ~10 tests)
- `tests/unit/PortalRequest.ErrorPaths.Tests.ps1` (~8 tests)
- `tests/unit/Ingest.ErrorPaths.Tests.ps1` (extend; ~10 tests)
- `tests/unit/Parser.EdgeCases.Tests.ps1` (~8 tests)
- `tests/unit/StorageTables.OptimisticConcurrency.Tests.ps1` (~6 tests)

**Acceptance**: `tests/results/coverage-all-offline.xml` line coverage ≥80%; CI coverage gate hard-fails at <80%.

## v0.1.0.2 — Build-SampleQueries.ps1 (auto-derive from manifest)

**Effort**: 4-6 hours

**Why**: Currently `deploy/solution/Data Connectors/XdrLogRaider_DataConnector.json` has manually-curated sample queries that drift from manifest. Auto-derivation from manifest at release-time prevents drift.

**Scope**:
- NEW `tools/Build-SampleQueries.ps1` — emits 5 standard KQL per stream (heartbeat / recent / count / freshness / field-discovery)
- Total: 360+ sample queries (5 × 72 streams)
- Wired into release.yml (regenerates DataConnector.json on every tag push)

## v0.1.0.3 — ARM-TTK CI gate

**Effort**: 2-3 hours

**Why**: Microsoft Sentinel content validation tool ARM-TTK catches solution-gallery-blocking issues pre-release.

**Scope**:
- Extend `.github/workflows/validate-solution.yml` with `arm-ttk` step
- Run on PR + push to main + tag push
- Target: 0 ARM-TTK errors before tag

## v0.1.0.4 — Workbook column hover-text (operator UX polish)

**Effort**: 4-6 hours

**Scope**:
- Add per-column tooltips to all 10 workbooks (incl. DeviceInventory_Unified + ConnectorOps from Hot-Fix 14+17)
- Shared snippets in `sentinel/_shared/` for consistency

## v0.1.0.5 — Pester parallelism + manifest hot-load caching

**Effort**: 2-4 hours

**Scope**:
- `tests/Run-Tests.ps1` — Pester `-Parallel` mode for unit tests (~50% CI speedup)
- `src/Modules/Xdr.Common.Manifest/Public/Get-XdrEndpointManifest.ps1` — hot-load cache (avoid re-parsing .psd1 per FA invocation)

## v0.1.0.6 — post-deploy-verify.yml auto-trigger

**Effort**: 30 min

**Scope**:
- Add `on: workflow_run: workflows: [release.yml] types: [completed]` trigger
- Auto-run P1-P14 verification post-tag publish

## v0.1.0.7 — More Defender endpoints + tiers DOCUMENTATION (per user directive)

**Effort**: 1-2 weeks

**Why**: per user 2026-05-09 — "v0.1.0.x = MORE Defender endpoints/tiers documentation only" (no v0.2.0 work until v0.1.0 GA stable).

**Scope**: documentation-only effort (no new streams in code yet) — captures research for v0.2.0 future implementation.

**Per-tier expansion candidates** (research catalogue, NOT for implementation in v0.1.0.x):

### ActionCenter tier (10m cadence)
- `MDE_PendingActions_CL` — actions awaiting approval (already shipping in v0.1.0 GA)
- `MDE_AirInvestigations_CL` — automated investigation lifecycle (deferred to v0.2.0a)

### XspmGraph tier (1h cadence)
- All 18 XSPM streams already shipping
- Future: `MDE_PostureExperiments_CL`, `MDE_AssetCriticality_CL`

### Configuration tier (6h cadence)
- All 16 Configuration streams already shipping
- Future: `MDE_AlertSuppressionMatrix_CL`, `MDE_DeviceGroupRBACPolicy_CL`

### Inventory tier (24h cadence)
- All 28 Inventory streams already shipping (post Phase 2 batches)
- Future: `MDE_SoftwareInventoryHistory_CL`, `MDE_DeviceCriticalitySummary_CL`

### Maintenance tier (7d cadence)
- 2 streams (DataExportSettings + StreamingApiConfig deprecated)
- Future: `MDE_StreamingDestinations_CL`, `MDE_StreamingFilters_CL`

**Per-category expansion priorities**:
- Threat Analytics: `MDE_ThreatAnalyticsOutbreaks_CL` (high value)
- Multi-Tenant Operations: `MDE_TenantConfiguration_CL`, `MDE_CrossTenantAccess_CL`
- Streaming API: `MDE_StreamingDestinations_CL`, `MDE_StreamingFilters_CL`

**Documentation deliverable**: Update `docs/ENDPOINTS.md` (auto-derived from manifest) + add a new `docs/EXPANSION-CANDIDATES.md` cataloguing all the streams above with nodoc canonical paths + sample responses + value rationale + RequiresLicense classification.

---

**v0.2.0 (post-GA, post-observation, post-v0.1.0.x patches)**: see `docs/V020-MULTI-PORTAL-ROADMAP.md` + `docs/V020-MULTI-TENANT-DESIGN.md` + `docs/V020-MARKETPLACE-PR-CHECKLIST.md`.
