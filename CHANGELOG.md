# Changelog

All notable changes to this project are documented in this file.

This project adheres to [Semantic Versioning 2.0.0](https://semver.org/) and the format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0.1] - 2026-05-09

Hot-fix release per Plan AMEND-9 Phase A — UnwrapProperty resilience + per-stream stale-alert + manifest ProjectionMap drift fixes verified live.

### Fixed

- **UnwrapProperty wrapper auto-discovery** (`src/Modules/Xdr.Defender.Client/Endpoints/_EndpointHelpers.ps1:304-380`) — when declared UnwrapProperty target returns null and response object has non-null array properties, auto-discovers by picking the largest array. Emits `Ingest.UnwrapAutoDiscovered` event with `OriginalUnwrap` + `DiscoveredUnwrap` + `RowCount` for operator visibility. Falls through to original `Ingest.BoundaryMarker` / `@()` return only if no array property found. Self-heals upstream API shape drift.
- **MDE_VulnerabilityInventory_CL ProjectionMap drift** — 3 field paths corrected per live capture diff (`cveId` → `id`, `publishedDate` → `publishedOn`, `assetsAffected` → `numOfImpactedAssets`). IdProperty reordered with canonical first. ProductName kept (always-null in current API; additive-only schema rule).
- **MDE_SoftwareInventory_CL ProjectionMap drift** — 4 field paths corrected (`productId` → `id`, `productName` → `name`, `assetsCount` → `assetsStatistics.totalAssetCount`, `vulnerabilityCount` → `discoveredVulnerabilities`).
- **MDE_VulnerableMachines_CL ProjectionMap drift** — 4 field paths corrected (`assetId` → `id`, `assetName` → `name`, `totalVulnerabilities` → `discoveredVulnerabilities`, `riskScore` → `exposureLevel`).

### Added

- **NEW analytic rule** `XdrOps-StreamWentDry.yaml` per Plan AMEND-9 Phase A.3 — per-stream stale alert (queryFrequency 1h, queryPeriod 14d, severity Medium, suppression PT4H). Detects SourceName silent within still-flowing tier (Baseline7d>=100 + tier-cadence threshold 2x). Ships disabled per Microsoft Sentinel best practice.
- **NEW Pester regression test** `tests/unit/Expand-MDEResponse.UnwrapAutoDiscover.Tests.ps1` — 4 cases proving auto-discovery fallback (declared null + 1 array → auto-pick / declared null + 0 arrays → boundary marker / declared null + multi arrays → largest / declared valid → no auto-discover).

### Verified

- **Phase A.9 LIVE VERIFY GREEN** — 63/63 streams classified across 5 tiers (StreamsAttempted == StreamsSucceeded); all 4 FA functions firing healthy 0 failures; auth chain 19 starts/19 completes/44 cache hits; 4 drift parsers execute (MDE_Drift_Inventory 5607 rows w/Modified events proving Section R++.C B4 fix); 21 rules + 8 workbooks + 12 hunting deployed; 100% natural EntityId; 0 unexpected AppExceptions (all 403/404 = expected tenant-gated streams).
- **Compressed-cadence audit completed** — temporary override 1h-everything used for 1h audit window 14:08-14:51 UTC; full BINDING REVERT to production cadence (10m/1h/6h/24h/7d) per Plan AMEND-2 Phase 5.B; production cadence verified active (drastic invocation drop: compressed 25 PollOrch/44 PollStream/15min → production 3/2/10min).

### Phase B audit (2026-05-09 — 5 commits)

Whole-repo 10-dimension audit per Plan AMEND-9 expanded scope. **Zero RED items confirmed across all 10 dimensions before Phase D tag.**

- **B.1 src/ all code** — PSScriptAnalyzer Errors-only across src/ + tools/ + tests/ = 0 errors via `.config/PSScriptAnalyzerSettings.psd1` (legitimate `ConvertTo-SecureString -AsPlainText` pattern excluded for SP-secret Connect-AzAccount integration). Inline `[Diagnostics.CodeAnalysis.SuppressMessageAttribute(...)]` decorators added to 4 tools for code-reader documentation.
- **B.2 stale count drift** — 30+ files updated across 5 batches. **CRITICAL** Solution Gallery descriptor (`deploy/solution/manifest.json`) was missing 6 declared items (3 analytic rules + 3 hunting queries) — operators installing v0.1.0 GA from Sentinel Content Hub were NOT getting them; fixed. Preflight-Deployment.ps1 hardcoded checks `14 rules / 9 hunting` were false-failing on actual `21 / 12` baseline; fixed. README + ARCHITECTURE + ROADMAP + DEPLOYMENT + Sentinel Solution descriptors all reflect true v0.1.0 GA baseline (64/13/11/4/8/21/12/4).
- **B.3 sentinel content** — `deploy/compiled/sentinelContent.json` regen-clean (90 resources: 4 parsers + 8 workbooks + 21 rules + 12 hunting + 45 metadata back-links).
- **B.4-7 manifest + categories + tables + parsers** — verified live during Phase A.9 (ingestion + schema parity + parser execution + drift logic).
- **B.8 folders cleanup** — dropped dated `tests/online/Wiring-Matrix-2026-05-07.md`; tests/results/ retention clean; `.internal/.archive/` already populated with nodoc-sweeps + wiring-matrices.
- **B.9 RUNBOOK.md** — clean of stale numeric claims.
- **B.10 stale phase markers** — 4 operator-facing docs fixed (INGEST-FAILURE-MODES + MULTI-PORTAL + RELEASE-PROCESS + STREAMS) — `Phase J` / `Phase Q` / `Section R++` replaced with cadence-tier names + canonical v0.1.0 GA references.
- Pyramid 77/0 GREEN throughout Phase B; 5 commits: `2ed73f4` + `d661614` + `fd9c22c` + `0c930fe` + `ba4ba87`.

### Pending ARM redeploy

The 3 ProjectionMap drift fixes (VulnerabilityInventory + SoftwareInventory + VulnerableMachines) require ARM redeploy of `mainTemplate.json` + `sentinelContent.json` regen + Function App package refresh to take effect. Workspace cols already exist; only DCR `transformKql` + manifest dispatch updated. Defer to Phase D single deploy at v0.1.0 GA stable tag.

## [0.1.0] - 2026-05-07

First proven production-ready release. Pure Defender XDR portal-only telemetry connector for Microsoft Sentinel.

### Live-deploy validation fixes (post Phase 1, this turn)

Operator-facing connector card UX + production-deploy hardening surfaced via live audit screenshot + iterative fix-enhance-consolidate cycle:

- **Connector card** — descriptionMarkdown updated to 64 streams (63 live + 1 deprecated) + lists ships-with content (8 workbooks + 21 rules + 12 hunting + 4 parsers + 320+ samples).
- **Connector card** — `isPreview: false` on both `additionalRequirementBanner.isPreview` (string) + `availability.isPreview` (bool); GA v0.1.0 no longer advertises Preview.
- **Connector card chart** — graphQueries[0] (Rows ingested last 7d) was bound to `XdrConnectorHealth_CL.RowsIngested SUM` which double-counted: heartbeat aggregator wrote the same 24h-window sum every 5 min, so `sum() over time` re-counted 288 fires/day → chart showed 13,742 vs actual 106,466 in workspace tables (7.7× under-reporting). Rebound to `union Defender_*_CL | summarize Rows=count() by bin(TimeGenerated, 1d)`.
- **ARM template KV-secret preservation** — added 3-layer guard so ARM redeploy never wipes existing real credentials:
  - `Deploy-XdrLogRaider.ps1` defaults to passing empty SecureStrings (length 0) for ServicePassword/TotpSeed/PasskeyJson; ARM `condition: greater(length, 0)` skips secret deploy.
  - `Deploy-XdrLogRaider.ps1` adds `-SkipSecretSeeding` switch + named `-ServicePassword/-TotpSeed/-PasskeyJson` params for explicit seeding.
  - `mainTemplate.json` belt-and-suspenders: `condition` also rejects `'dummy-not-used-existing-kv-overrides'` sentinel so even if a future caller passes the dummy, secret is preserved.
- **Verify-EndToEndProduction.ps1 W1** — KQL `not Success` raised BadRequest (Success is string in AppDependencies schema, not bool). Replaced with explicit `Success == false` comparison.
- **`mainTemplate.json` workspace-table dedup** — `Defender_EndpointConfiguration_CL` had `Platform` col duplicated when MDE_SecurityPolicies_CL was added; ARM customTables nested deploy failed with "columns appear more than once". Deduped.
- **`SyntheticEntityId` row-builder wiring** (Section R++++++ Phase 1) — manifest declared `SyntheticEntityId='<stream>-singleton'` for SingleObjectAsRow streams (TenantContext, UserPreferences, ThreatAnalyticsTopThreats, AppsSecureScore, DataSecureScore, IdentitySecureScore, PostureTenants, etc.) but the row-builder NEVER consumed it → fell to idx-N fallback. Fixed `Resolve-MDEEntityPairs` to accept new `[string] $SyntheticEntityId` param + use it before idx-N; wired through `Invoke-MDEEndpoint` `$expandArgs`.
- **`$json:` cast array preservation** — PowerShell pipeline-unwrap quirk (`$value | ConvertTo-Json` collapses 1-element arrays to scalar) caused `$json:GroupRules` against MDE_RbacDeviceGroups_CL with one rule to emit `{"O":1}` instead of `[{"O":1}]`; workspace `dynamic` col stored scalar; operator queries against `array_length(GroupRules)` returned null. Fixed by re-walking source entity to detect array-shape + forcing `ConvertTo-Json -AsArray` on collapsed-single-element values; multi-element arrays serialize naturally without double-wrap.

### New tools (this turn)

- **`tools/Audit-DataQuality.ps1`** — schema-parsing + data-quality audit per stream (A1 row-count + recency, A2 EntityId fallback %, A3 RawJson parseability, A4 typed-col population). Goes beyond "did API return 200" to verify operator content actually queries the typed cols correctly. Exit code 2 on FAIL, 1 on WARN, 0 on PASS.

### Highlights

- **64 telemetry streams** (63 live + 1 deprecated MDE_StreamingApiConfig_CL) across 5 cadence tiers (10m / 1h / 6h / 24h / 7d) routed to **11 consolidated workspace tables** (10 `Defender_<Category>_CL` per nodoc D.1 10-category taxonomy + 1 `XdrConnectorHealth_CL` operational table).
- **4-function topology** (post Section R 9→4 consolidation): `Xdr-Refresh` universal portal-agnostic dispatcher + `Xdr-PollOrchestrator` durable + `Xdr-PollStream` activity + `Connector-Heartbeat` aggregator. v0.2.0 multi-portal additions reuse the same 4 functions (manifest-driven dispatch).
- **13 DCRs / 1 DCE / 65 streamDeclarations** (64 data + 1 ops `XdrConnectorHealth_CL`); per-category split for Configuration + Exposure (>10-flow Azure cap).
- **Connector card flips to Connected** as soon as any tier emits `StreamsSucceeded > 0` (Section R+ strict-mode fix landed via commit 0972e8c).
- **All-live AVAILABILITY policy** (Section R+++.4) — manifest entries are all `live`; tenant licensing detected at runtime via `Get-MDEEndpointLastResult.SuccessKind` (`live` / `live-empty` / `tenant-gated` / `error`) and surfaced on `XdrConnectorHealth_CL.Reason` per stream.

### Added (Section R++++++ Phase 1 — 2026-05-07)

- **Architecture B foundation** — `MDE_Machines_CL` per-machine inventory base stream (paginated `/mtp/ndr/machines`).
- **Architecture A — PerEntityFanout** — activity iterates per-entity from a source stream (e.g. MDE_Machines_CL → MDE_DeviceTimeline_CL `{MachineId}` substitution); composite checkpoint key `{Stream}|{EntityId}` for per-entity resume; MaxEntitiesPerCycle guardrail.
- **Architecture C — PerPlatformFanout** — single-stream multi-platform activity loop (Windows/Linux/macOS/iOS); `BodyOverride` POST-body merge + `Platform` col stamping. Applied to `MDE_SecurityPolicies_CL`.
- **Architecture F — Pagination** — pageIndex/pageSize/MaxPages loop in `Invoke-MDEEndpoint` with last-page detection. Applied to 4 TVM streams.
- **MDE_SecurityPolicies_CL** (G7) — POST `/mtp/unifiedExperience/mde/configurationManagement/mem/securityPolicies` returning ASR rules + AV settings + Account Protection + Disk Encryption + EDR + Firewall + Web Protection per platform (NOT duplicative of `MDE_AntivirusPolicy_CL` which is operator-side filter facets).
- **TVM expansion (G8)** — 4 streams: `MDE_VulnerableMachines_CL` + `MDE_VulnerabilityInventory_CL` + `MDE_SoftwareInventory_CL` + `MDE_RecommendationActions_CL` (all paginated).
- **41 silent col drops fixed** (Section R++.B2 class bug) across 3 workspace tables — DCR streamDecls had cols missing from destination workspace tables; operators querying those cols got `NULL` silently. Fixed: Defender_ThreatAnalytics_CL (+5 cols), Defender_ConfigurationAndSettings_CL (+3 cols), Defender_ExposureManagement_CL (+33 cols).
- **Drift parser execution test** (F5) — `tests/kql/Parsers.Execution.Tests.ps1`: simulates parser KQL semantics in PS to validate Added/Removed/Modified classification + asserts 9 required output cols + window/lookback parameterization across all 4 cadence-tier parsers.
- **Live workspace-table schema parity test** (P1.9) — `tests/arm/WorkspaceTable.SchemaParity.Tests.ps1`: catches B2-class silent col drops by asserting every DCR-declared col exists in destination workspace table.
- **Session-cache boundedness test** (HH) — `tests/unit/Auth.SessionCacheBoundedness.Tests.ps1` prevents EnumerationContext leaks.
- **PerPlatformFanout activity test** (Architecture C) — `tests/unit/Activity.PerPlatformFanout.Tests.ps1`.
- **3 hunting queries** for new streams: `MachineInventoryRiskScore.yaml` + `SecurityPoliciesPerPlatform.yaml` + `TvmTopVulnerableMachines.yaml`.
- F1 — `MDE_SecurityBaselines_CL` path corrected to `/apiproxy/mtp/tvm/analytics/vulnerabilities/baseline` per nodoc canonical.
- F2 — `SyntheticEntityId` added to PostureTenants/AppsSecureScore/DataSecureScore/IdentitySecureScore (eliminates idx-N drift-join breakage).
- F4 — 3 analytic rules cadence/window aligned: AlertTuningBroadened + TamperProtectionOff + RbacRoleToUnusualAccount.
- F7 — online-preflight.yml `tags: v*` trigger added so release.yml depends on its success.
- MM — RawJson scalar wrap in Shape-3 row-builder so `parse_json(RawJson)` works on bool/int values.

### Changed (Section R++++++)

- **Cadence map reverted to production** values (Section R++++++.4 F3): ActionCenter=10m / XspmGraph=1h / Configuration=6h / Inventory=24h / Maintenance=7d. Compressed-1h-everything was troubleshooting only.
- **release.yml gate 1b** baseline updated to 65 streamDecls (64 streams + 1 ops) for v0.1.0 GA baseline.
- `STREAMS-MATRIX.md` retired (Section R++++++.3): merged into `STREAMS.md` as appendix; per-stream operational matrix is auto-derived to `tests/online/Wiring-Matrix-<YYYY-MM-DD>.md` on every release.

### Changed (Section R++)

- **Truth-signal restoration** — `Invoke-MDEEndpoint` now exposes a 4-state `SuccessKind` (`live` / `live-empty` / `tenant-gated` / `error`) via the new `Get-MDEEndpointLastResult` accessor; the legacy `,@()` return contract is preserved so existing callers don't break. Activity (`Xdr-PollStream`) reads this side-channel and writes `Reason` + `HttpStatus` columns to `XdrTierState` so `Connector-Heartbeat` aggregator + connector card can distinguish "tenant doesn't have feature" from "real failure" from "live but no rows this poll".
- **Schema integrity** — `Defender_ThreatAnalytics_CL` workspace table extended with TopThreats typed cols (TotalActiveThreats, ThreatsExposure, TotalThreatRequiresAction, ThreatExposureCalculationStatus, CurrentAlertsCount); previously these landed via DCR but were silently dropped at the workspace-table layer.
- **Manifest** — added `IdProperty=@('__synthetic__')` + `SyntheticEntityId='<stream>-singleton'` for SingleObjectAsRow streams without natural id; added forward-compat `RequiresLicense` + `TenantContextProbe` schema fields; reclassified `MDE_UserPreferences_CL` to `Availability='requires-delegated-auth'`; `MDE_CloudAppsConfig_CL` switched to `SingleObjectAsRow=$true`.
- **Detection rules** — `MdiDcSensorDown.yaml` realigned: queryFrequency 15m→4h, queryPeriod 2h→P2D (matches Inventory cadence); FieldName "hasSensor" → "IsActive" (matches manifest typed col).
- **Hunting queries** — `ConfigChangesByUpn.yaml` join switched from exact-equality `==` to 5-min `bin()` bucket (sub-second equality never matched).
- **Workbooks** — `MDE_DriftReport.json` window args aligned to tier cadence (Inventory 1d, Configuration 6h) instead of 1h/30m which missed 23/24+ of poll cycles.
- **Drift parsers** — all 4 (Configuration / Inventory / Exposure / Maintenance) — corrected `ChangeType` classification: previously the "Removed" branch was unreachable (`isnull(TypedBag[field])` false for current-snapshot fields). Replaced with explicit `set_has_element` + `case()` so Added/Removed/Modified classify correctly.
- **Orchestrator** — `Xdr-PollOrchestrator` now filters `Availability='deprecated'` streams (e.g. `MDE_StreamingApiConfig_CL`) — saves auth-call budget + removes 4xx noise from AppExceptions.
- **Connector card UX** — Sentinel UI graphQueries now show `sum(RowsIngested)` over 7d + `max(StreamsSucceeded)` per tier instead of a single AppInsights customEvents counter.

[Unreleased]: scratch — Phase 2 (Architecture I XdrTenantState + Architecture E OpenAPI fixture generator) deferred to v0.1.0.1 / v0.2.0 per Section R++++++.7 future expansion roadmap.

### Changed (Section R++)

- **Truth-signal restoration** — `Invoke-MDEEndpoint` now exposes a 4-state `SuccessKind` (`live` / `live-empty` / `tenant-gated` / `error`) via the new `Get-MDEEndpointLastResult` accessor; the legacy `,@()` return contract is preserved so existing callers don't break. Activity (`Xdr-PollStream`) reads this side-channel and writes `Reason` + `HttpStatus` columns to `XdrTierState` so `Connector-Heartbeat` aggregator + connector card can distinguish "tenant doesn't have feature" from "real failure" from "live but no rows this poll".
- **Schema integrity** — `Defender_ThreatAnalytics_CL` workspace table extended with TopThreats typed cols (TotalActiveThreats, ThreatsExposure, TotalThreatRequiresAction, ThreatExposureCalculationStatus, CurrentAlertsCount); previously these landed via DCR but were silently dropped at the workspace-table layer.
- **Manifest** — added `IdProperty=@('__synthetic__')` + `SyntheticEntityId='<stream>-singleton'` for SingleObjectAsRow streams without natural id (`MDE_ThreatAnalyticsTopThreats_CL`, `MDE_UserPreferences_CL`, `MDE_CloudAppsConfig_CL`); added `IdProperty` for `MDE_DCCoverage_CL` + `MDE_RemediationAccounts_CL`; added forward-compat `RequiresLicense` + `TenantContextProbe` schema fields; reclassified `MDE_UserPreferences_CL` to `Availability='requires-delegated-auth'`; `MDE_CloudAppsConfig_CL` switched to `SingleObjectAsRow=$true`.
- **Detection rules** — `MdiDcSensorDown.yaml` realigned: queryFrequency 15m→4h, queryPeriod 2h→P2D (matches Inventory cadence); FieldName "hasSensor" → "IsActive" (matches manifest typed col).
- **Hunting queries** — `ConfigChangesByUpn.yaml` join switched from exact-equality `==` to 5-min `bin()` bucket (sub-second equality never matched).
- **Workbooks** — `MDE_DriftReport.json` window args aligned to tier cadence (Inventory 1d, Configuration 6h) instead of 1h/30m which missed 23/24+ of poll cycles.
- **Drift parsers** — all 4 (Configuration / Inventory / Exposure / Maintenance) — corrected `ChangeType` classification: previously the "Removed" branch was unreachable (`isnull(TypedBag[field])` false for current-snapshot fields). Replaced with explicit `set_has_element` + `case()` so Added/Removed/Modified classify correctly.
- **Orchestrator** — `Xdr-PollOrchestrator` now filters `Availability='deprecated'` streams (e.g. `MDE_StreamingApiConfig_CL`) — saves auth-call budget + removes 4xx noise from AppExceptions.
- **Connector card UX** — Sentinel UI graphQueries now show `sum(RowsIngested)` over 7d + `max(StreamsSucceeded)` per tier instead of a single AppInsights customEvents counter (the prior chart label "21" was misread as "21 rows landed").

### Added

- New module export `Get-MDEEndpointLastResult` (truth-signal accessor).
- Per-stream AppMetrics emit `xdr.stream.rows_emitted` + `xdr.stream.poll_duration_ms` (regression — was lost when Section R replaced Invoke-MDETierPoll).
- Manifest schema fields `RequiresLicense` (string[]) + `TenantContextProbe` (string) for forward-compat tenant-license short-circuit.
- Manifest schema fields `SyntheticEntityId` (string) for SingleObjectAsRow streams without natural id.
- Operator tool `tools/Update-LiveConnectorResource.ps1` — surgical PUT of corrected `connectorUiConfig` to live Sentinel resource (existing deployments don't auto-update from ARM).
- Operator tool `tools/Verify-EndToEndProduction.ps1` — consolidated 20-signal post-deploy verifier covering Provisioning / Wiring / Liveness / Coverage / Quality / Risk dimensions.
- Operator tool `tools/Audit-TimeFilterCoverage.ps1` — flags any unbounded workspace-table query in sentinel/ yaml.

### Fixed

- Connector card `connectivityCriteria` (was misspelled `connectivityCriterias` plural — Sentinel UI silently ignored).
- Connector card `dataTypes[]` (was MDE_*_CL DCR streamDecl identifiers — fixed to 11 live `Defender_<Category>_CL` workspace tables).
- 17 detection/hunting yaml files with malformed `where StreamName == "Defender_X_CL | where SourceName == 'MDE_Y_CL'"` filter (literal pipe inside string never matched).
- `Get-XdrTierStateAggregate` strict-mode crash on `__schedule__` rows lacking `TimestampUtc` (server-side OData filter `RowKey ne '__schedule__'` + per-property null-guards).
- `Invoke-XdrStorageTableEntity` `$base?` variable-token parse error under `Set-StrictMode -Version Latest` (used `${base}?` delimiter).
- Workbook ConnectorHealth Panel 1 — case() arms moved from FunctionName (always 'Connector-Heartbeat' post-Section R) to Portal+Tier.
- Workbook ComplianceDashboard — Tier filter from legacy 'P0' to live ValidateSet.
- Manifest projection corrections for AssetClassificationSchema (IdProperty=@('assetType')) + PreviewFeatures (SingleObjectAsRow) + PurviewSharing (UnwrapProperty='value') + DeviceTimeline (Tier ActionCenter for security-event 10-min cadence per operator directive).

### Internal

- Plan file `.claude/plans/immutable-splashing-waffle.md` Section R++ added documenting the 12 BLOCKING + 14 WARN + 8 INFO consolidated audit findings + 13-phase remediation + 24-box DoD.
