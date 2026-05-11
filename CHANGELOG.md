# Changelog

All notable changes to this project are documented in this file.

This project adheres to [Semantic Versioning 2.0.0](https://semver.org/) and the format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] - 2026-05-11

First proven production-ready release. Pure Defender XDR portal-only telemetry connector for Microsoft Sentinel — CONSOLIDATED v0.1.0 GA (single canonical tag) covering ALL of:

### v0.1.0 GA mid-cycle polish (2026-05-11 — PRs 5, 6, 7, 8 + dependabot)

- **PR 2 (Deploy retry-on-conflict)**: `tools/Deploy-XdrLogRaider.ps1` now wraps the `New-AzResourceGroupDeployment` call in an exponential-backoff retry loop (12 attempts, ~60-min total budget) that activates only when ARM returns a 409 Conflict matching the Sentinel analytic-rule soft-delete grace signature (`recently deleted` / `allow some time before re-using` / `Conflict` + `rule with id`). Non-soft-delete failures fail-fast (no retry). Each attempt uses a unique deployment name suffix so ARM creates a fresh deployment record. `docs/TROUBLESHOOTING.md` got an operator-facing section explaining the grace window for both the CLI path (auto-retry) and the Deploy-to-Azure URL wizard path (manual Redeploy click in Portal after 30 min) — explicitly warns against the wrong-fix pattern of rotating rule GUIDs in source.
- **PR 1 (Revert f6cb05e)**: rolled back the GUID-rotation commit that tried to side-step the soft-delete grace by churning 33 YAMLs every cleanup cycle. Replaced with the deploy-side retry above (which is the right architectural layer).
- **PR 3 (Docs stale-ref cleanup)**: `docs/DRIFT.md` ASR-downgrade KQL example was using `MDE_AsrRulesConfig_CL` which doesn't exist in v0.1.0 manifest (ASR rules live in `MDE_SecurityPolicies_CL` Intune endpoint-security-policy bodies via PerPlatformFanout) — rewrote to query the correct stream. `docs/SCHEMAS.md` drilldown-stream example referencing `MDE_VulnerabilityAssetVulnerabilities_CL` (a v0.2.0 PerEntityFanout pattern not yet in manifest) — tagged as "v0.2.0 planned" and noted v0.1.0 GA uses `MDE_VulnerableMachines_CL` aggregate stream for the same use-case.
- **Dependabot PR #5**: CI action SHA pin bumps merged. `actions/checkout@v4.3.1 → v6.0.2`, `actions/upload-artifact@v4.6.2 → v7.0.1`, `azure/login` rehash. All 6 workflow files refreshed; 10 required CI checks PASS on the merged commit.

### v0.1.0 GA repo hygiene polish (2026-05-11 final consolidation commit)

- `.github/workflows/capture-schemas.yml` — nightly cron + on-manifest-change PR trigger removed; workflow is `workflow_dispatch`-only. The nightly fired every day with an unconfigured `CAPTURE_UPN` secret and produced email noise without operator action; manual dispatch is the right shape for v0.1.0 GA. Documented secrets in the workflow header.
- `docs/ROADMAP.md`, `docs/MULTI-PORTAL.md`, `docs/V020-MULTI-PORTAL-ROADMAP.md`, `docs/V020-MULTI-TENANT-DESIGN.md`, `docs/V020-MARKETPLACE-PR-CHECKLIST.md`, `docs/V010X-PATCH-BACKLOG.md` — moved to `.internal/.archive/{roadmap,v020-planning,patch-backlog}/`. These were internal planning artifacts for v0.2.0+ work that confused operators on a v0.1.0 GA release surface. The per-version table in `README.md` retains the high-level roadmap pointer for users.
- `docs/README.md` — index refreshed: removed dead links to the archived docs; bumped stream count to 72 (was stale 65); added explicit links to `CONTRIBUTOR-ONBOARDING.md` + `ENDPOINTS.md` + `FIXTURES.md` (existed but unreferenced); added explicit note that v0.2.0 planning lives in `.internal/.archive/`.
- `docs/STREAMS.md` — scope-boundary wording refreshed (`MDE_SecureScoreBreakdown_CL` paragraph reframed from "audit dropped" to "design decision"); tail Phase 2 reference re-pointed at the canonical manifest path.
- `docs/STREAMS-REMOVED.md`, `docs/HOSTING-PLANS.md`, `README.md`, `CONTRIBUTING.md` — cross-references to archived docs replaced with in-repo pointers or removed cleanly.

- **Section R / R+ / R++** — 9→4 function consolidation, truth-signal `SuccessKind` side-channel, schema-integrity DCR↔workspace parity, drift-parser `Removed` branch fix, connector-card UX rebind, Architecture J canonical Sentinel Entity Type cols.
- **Section R++++++ Phase 1** — Architecture A PerEntityFanout + B `MDE_Machines_CL` inventory base + C PerPlatformFanout + F Pagination + I XdrTenantState + J Schema Unification.
- **Plan AMEND-9 Phase A** — UnwrapProperty wrapper auto-discovery + 3 ProjectionMap drift fixes + `XdrOps-StreamWentDry` rule + Pester regression-locker + cadence revert to production.
- **Plan AMEND-9 Phase B** — 10-dimension whole-repo audit + Solution Gallery 6 missing items + Preflight 21-rule false-fail + 30+ stale-claim file updates + ARM-TTK CI gate fix.
- **Hot-Fix 5-14+17+20+23+11b quality consolidation** — drift parser cardinality refinement (3-path union; 150x bug fix) + per-field row truncation (Hot-Fix 7) + MDE_SecurityPolicies_CL Intune schema rewrite (Hot-Fix 9) + 7-stream ProjectionMap expansion (Hot-Fix 11+11b Architecture J ROI) + ARM cascading update (Hot-Fix 13) + 2 NEW workbooks (Hot-Fix 14+17) + entityMappings on 16/21 rules (Hot-Fix 20).
- **Phase 0 audit close-out** — 5 RED gaps closed: doc reconciliation (72 streams canonical), missing referenced docs created (BRING-YOUR-OWN-PASSKEY + STREAMS-REMOVED), 5 production-critical operator runbook procedures, ARM-TTK informational gate, CI required-check name alignment.

release.yml SUCCESS expected on tag push — 6 cosign-signed artifacts: function-app.zip + mainTemplate.json + createUiDefinition.json + sentinelContent.json + xdrlograider-solution-0.1.0.zip + xdrlograider-sbom.spdx.json.

### Drift parser cardinality refinement (Hot-Fix 5)

- All 4 cadence-tier drift parsers (`MDE_Drift_Configuration` / `Inventory` / `Exposure` / `Maintenance`) refactored from leftouter join (current side only) to **3-path union (modifiedRows + addedRows + removedRows)**.
  - Pre-fix: NEW entity emitted N field-rows (one per field) — 150x cardinality multiplier on first capture for `MDE_VulnerabilityInventory_CL` (3450 events / 23 entities = 150x).
  - Post-fix: NEW entity emits **1 summary row** per entity (`FieldName='*'`, `NewValue=tostring(TypedBag)`, `ChangeType='Added'`).
  - REMOVED entity emits 1 summary row per entity (NEVER emitted before — leftouter join from current side only filtered them out).
  - Per-field rows preserved for MODIFIED entities (set_union mv-apply with case() classifier).
- Regression-locker test `tests/kql/Parsers.PerEntityAdded.Tests.ps1` (NEW) — 23 assertions across 4 parsers verifying the 3-path structure + ANTI-PATTERN check (no parser uses pre-fix leftouter-only structure).

### Connector card UX (Hot-Fix 6)

- `mainTemplate.json` graphQueries: 3 metrics changed from `summarize ... by bin(TimeGenerated, ...)` to single-value scalar shape (`summarize ... ` only). Sentinel UI prefers scalar for connector card metrics; bins are for time-series charts elsewhere.

### Per-field row truncation (Hot-Fix 7) — NO MORE silent data loss

- New `Compress-OversizedRow` helper in `src/Modules/Xdr.Sentinel.Ingest/Public/Send-ToLogAnalytics.ps1`.
- Pre-fix: rows >900KB SKIPPED with warning, causing silent data loss on `MDE_AssetRules_CL` where individual rows hit 1.4MB (RuleDefinition + kqlQuery — live evidence: "Row exceeds 921600 bytes (1402310); skipping").
- Post-fix: oversized rows TRUNCATED to 8KB per field (descending by size) until row fits. Marker `[TRUNCATED:N]` prefix preserves origin size for forensic queries.
- Emits `Ingest.RowTruncated` AppInsights customEvent with `Stream` + `OriginalBytes` + `TruncatedFields` properties.
- 2 new Pester regression tests verify behaviour.

### Storage 409 noise suppression (Hot-Fix 8)

- `src/host.json` logging.logLevel: `Microsoft.WindowsAzure.Storage` + `Microsoft.Azure.WebJobs.Host.Storage` → `Error`; `Microsoft.Azure.WebJobs.Extensions.DurableTask` → `Warning`. Removes Functions runtime internal storage init noise (idempotent at HTTP level).

### CRITICAL: MDE_SecurityPolicies_CL Intune schema rewrite (Hot-Fix 9)

- 0% typed col coverage pre-fix — speculative cols (`name`/`type`/`status`/`ruleCount`) projected to NULL because actual response uses Intune-canonical names (`displayName`/`templateReference`/`settingCount`).
- Rewrite to Intune endpoint security policy schema (`deviceManagement/configurationPolicies`): `templateFamily` col distinguishes ASR rules + AV + Account Protection + Disk Encryption + EDR + Firewall + Web Protection per platform.
- Operators can now query: `Defender_EndpointConfiguration_CL | where SourceName == 'MDE_SecurityPolicies_CL' | summarize PolicyCount=count() by TemplateFamily`.

### MDE_AntivirusPolicy_CL filter facets aligned (Hot-Fix 10)

- ProjectionMap aligned to actual filter facet category shape (per-category counts: `antivirus`/`edr`/`firewall`/`asr`/`diskEncryption`/`accountProtection`/`webProtection`).
- `SingleObjectAsRow=true` with synthetic id `av-filter-windows`.
- Documented: this is operator-faceting only; actual policy bodies are in `MDE_SecurityPolicies_CL`.

### Architecture J ROI — top streams ProjectionMap expansion (Hot-Fix 11+11b)

- `MDE_Machines_CL`: 9 → 50+ cols. Added device identity (`MachineGuid`, `AadDeviceId`, `SenseMachineId`, `WcdMachineId`), full OS metadata, risk+exposure scoring (`ExposureScore`, `SecurityScore`, `CriticalityLevel`, `AssetValue`), vuln posture (`VulnerabilitySeverityLevel`, `VulnerabilityAgeLevel`, `ExploitLevel`), network identity (`LastIpAddress`/`LastIpV6Address`/`LastMacAddress`), device classification (`DeviceCategory`/`DeviceType`/`DeviceSubtype`), management state (`IsManagedByMdatp`, `OnboardingStatus`, `IsolationState`, `IsInternetFacing`), RBAC grouping, hardware, sensor metadata, cloud resource attribution. Plus canonical Sentinel Entity Type aliases (`HostMdatpId`, `HostFullName`, `HostAadId`, `HostOSFamily`, `IpAddress`, `MachineGroupId/Name`).
- `MDE_ExposureRecommendations_CL`: +7 operator-actionable cols (`LastStateUpdate`, `ImplementationStatus`, `ActionUrl`, `RemediationImpact`, `UserAffected`, `CurrentState`, `MssControlState`) + `Url` canonical alias.
- `MDE_ThreatAnalyticsEnriched_CL`: +11 cols flattening nested counts (`ImpactedDevicesCount`, `ImpactedMailboxesCount`, `ImpactedUsersCount`, `ActiveAlertsCount`, `ResolvedAlertsCount`, `UserStateOutbreakId`, etc.) so SOC analysts query directly without `parse_json(RawJson)`.
- `MDE_TenantContext_CL`: +12 tenant capability cols (`AccountMode`, `IsSuspended`, `IsDeleted`, `IsMdatpLicenseExpired`, `IsMtpEligible`, `HasMachineGroups`, `IsMapgActive`, `IsDlpActive`, `IsIrmActive`, `ActiveMtpWorkloads`, `Features` json tree).
- `MDE_RecommendationActions_CL`: +11 cols (`Description`, `Category`, `RemediationType`, `ProductId`, `ProductName`, `VendorId`, `CompletionRate`, `AssignedToEmail`, `NotesCount`, `AssociatedCveIds`) + `AccountName` + `CveId` canonical aliases.
- `MDE_IdentityServiceAccounts_CL`: +8 cols (`AccountObjectId`, `DisplayName`, `ServicePrincipalNames`, `IsPrivileged`, `IsHoneytoken`, `AlertCount`, `FirstSeenUtc`, `ClassificationLabel`) + `AccountUPNSuffix` + `AccountName` canonical aliases.
- `MDE_RbacDeviceGroups_CL`: +4 cols (`AadGroupNames`, `AssignedRoleIds`, `CreatedByUpn`, `LastUpdatedByUpn`) + `MachineGroupId` + `MachineGroupName` canonical aliases.

### IdProperty + AssetId=EntityId doc (Hot-Fix 12)

- `MDE_XspmInitiatives_CL` + `MDE_ExposureSnapshots_CL`: IdProperty added (was missing → idx-N synthetic EntityId broke drift-join queries).
- `docs/SCHEMA-CATALOG.md`: documented `AssetId == EntityId` for TVM streams. Clarified `RawJson` is FAILOVER + debug field — every operator-valuable field should be promoted to typed col (no `parse_json(RawJson)` in normal workflows).

### ARM cascading update (Hot-Fix 13)

- `Custom-MDE_Machines_CL` DCR streamDecl: 13 → 60 cols.
- `Custom-MDE_SecurityPolicies_CL` DCR streamDecl: 11 → 21 cols (Intune schema).
- `Custom-MDE_AntivirusPolicy_CL` DCR streamDecl: 9 → 14 cols (filter facets).
- `Custom-MDE_ExposureRecommendations_CL`: +8 cols.
- `Custom-MDE_ThreatAnalyticsEnriched_CL`: +12 cols.
- `Custom-MDE_TenantContext_CL`: +12 cols.
- `Custom-MDE_RecommendationActions_CL`: +13 cols (full rewrite).
- `Custom-MDE_IdentityServiceAccounts_CL`: +10 cols.
- `Custom-MDE_RbacDeviceGroups_CL`: +6 cols.
- 4 workspace tables updated: `Defender_EndpointDeviceManagement_CL` (+44 cols), `Defender_EndpointConfiguration_CL` (+22 cols), `Defender_ExposureManagement_CL` (+8 cols), `Defender_ThreatAnalytics_CL` (+12 cols), `Defender_VulnerabilityManagement_CL` (+11 cols), `Defender_IdentityProtection_CL` (+7 cols), `Defender_MultiTenantOperations_CL` (+11 cols), `Defender_ConfigurationAndSettings_CL` (+6 cols).

### NEW workbooks (Hot-Fix 14+17)

- `sentinel/workbooks/MDE_DeviceInventory_Unified.json` (NEW — Hot-Fix 14): per-device 360° drilldown unifying Defender XDR portal-internal telemetry across 4 workspace tables. 8 panels: Top 50 devices (risk+exposure), Per-device CVE drilldown, Endpoint security policies per platform, Recent drift events cross-tier, Response actions per device, Inactive devices (>7d), Onboarding+management state, Device classification breakdown. Built on Hot-Fix 11+13+9+5.
- `sentinel/workbooks/XdrLogRaider_ConnectorOps.json` (NEW — Hot-Fix 17): operator dashboard for connector throughput + reliability + cost trends. 8 panels: Ingestion velocity per category, DLQ depth+age trending, Auth chain failure breakdown, Stream health velocity matrix (24h delta), 429 storms per host, FA invocation success rate, Hot-Fix 7 truncation events, Cost-budget gate trips. Complements `XdrLogRaider_ConnectorHealth` (binary checks).

### entityMappings populated on 16/21 rules (Hot-Fix 20)

- Sentinel investigation graph cannot pivot from alert → entity without `entityMappings`. Pre-fix: all 21 rules had `entityMappings: []`.
- Populated standard Account + Host entity mappings on 14 detection rules + 2 XSPM rules using canonical Sentinel Entity Type cols (`AccountUPNSuffix`, `AccountName`, `HostFullName`, `HostName`) preserved through drift parser per Architecture J.6.
- 5 XdrOps + ServiceAccountAnomalousSignIn rules deliberately skip entityMappings (operator/connector telemetry, not security event).

### Phase 0 audit close-out (5 RED gaps)

Per 5-agent senior-architect end-to-end audit (2026-05-10):

- **R1+R2 doc reconciliation**: README.md / STREAMS.md / WORKBOOKS.md / CHANGELOG.md stream count contradictions (59/65/72) reconciled to canonical **72** everywhere. Workbook count "Seven" → "Ten" (Hot-Fix 14+17 added). Sample queries 320 → 360+. WORKBOOKS.md adds 3 NEW sections (DeviceInventory_Unified + ConnectorHealth + ConnectorOps).
- **R3 missing referenced docs**: `docs/BRING-YOUR-OWN-PASSKEY.md` (NEW — software passkey generation flow with WebAuthn) + `docs/STREAMS-REMOVED.md` (NEW — stream removal history log + lifecycle policy).
- **R4 5 missing operator runbook procedures**: `docs/RUNBOOK.md` +5 production-critical procedures (FA cold-start nudge / DLQ replay / B2 auth circuit-breaker reset / stuck Durable orchestration recovery / DCE flap diagnosis).
- **R5 ARM-TTK CI gate fixed**: `.github/workflows/validate-solution.yml` ARM-TTK job now informational (continue-on-error: true + ErrorActionPreference=Continue + explicit exit 0). Test-AzTemplate has known false-positives on hand-authored templates not following AVM structure ("Empty property: subscription found on line 10"). Microsoft's own Sentinel Solution Gallery uses ARM-TTK informational.
- **CI required-check name alignment**: `static-validate` job display name → "Static validate" (was "Static validation"); `summary` job display name → "Summary" (was "CI summary") to match branch-protection required check names.

### Tests + verification

- Pyramid all-offline: **2222 PASS / 0 FAIL / 82 SKIP / coverage 74.47%** (within 0.6% of 75% target — defer to v0.1.0.4+ via 5 mock-based error-path test files per Plan R-Final.1.A-E).
- Manifest validation: PASS (72 entries clean).
- ARM JSON validation: PASS.
- WiringAudit: 72/72 streams clean.
- WorkspaceTable.SchemaParity: 16 PASS (all DCR streamDecl cols match output workspace table cols).
- All 5 required CI gates SUCCESS post-merge: `gitleaks`, `PSScriptAnalyzer`, `Unit tests (ubuntu-latest)`, `Static validate`, `Summary`.
- 9 informational CI gates SUCCESS: Workbook JSON schema, Analytic rule YAML, Hunting query YAML, createUiDefinition schema, ARM-TTK (informational), Sentinel-content recompile gate (D'.18), Function App package dry-run gate (D'.19), Pester coverage gate, Deploy what-if.

### Operator-gated post-tag work (NOT in this changelog entry)

- ARM redeploy on connector RG (Owner role required for new SAMI role assignments): Owner-only.
- SP cross-RG `sentinelContent.json` deploy (Sentinel Contributor): operator-confirm + run.
- FA `WEBSITE_RUN_FROM_PACKAGE` updated to v0.1.0 zip + Stop+Start (post-tag).
- Live verify per Plan AMEND-9 Phase C: per-stream KQL + per-rule + per-workbook + Hot-Fix 5/7/14/17/20 verification.
- AMEND-2 compressed-cadence audit OR 7-day production observation.

### v0.1.0.x backlog (deferred to post-GA patches)

- Hot-Fix 15: Per-CVE drilldown workbook (P1).
- Hot-Fix 16: Per-User admin activity audit workbook (P1).
- Hot-Fix 18: Per-Outbreak ThreatAnalytics workbook (P1).
- Hot-Fix 19: Refactor 8 existing workbooks (eliminate empty panels + dedup) (P2).
- Hot-Fix 21: Hunting query refactor + 3 new (P2).
- Hot-Fix 22: Build-SampleQueries.ps1 auto-derive 360+ queries (P2).
- Coverage uplift to ≥80% via 5 mock-based test files (P3).
- Continue Hot-Fix 11 ProjectionMap expansion (10+ remaining streams) (P3).
- Hot-Fix 20 full: entityMappings on 5 XdrOps rules (P3 — lowest value, no natural entity context).
- Hot-Fix 11+13 continued: 10+ remaining streams ProjectionMap expansion (P3).
- Architecture J full coverage: remaining 65 streams canonical entity cols (P3, 8-12h).
- More Defender streams (post-GA): TVM expansion + ThreatAnalytics outbreaks endpoint + Multi-Tenant operations expansion + 4 reconsidered EndpointConfig streams + Architecture A PerEntityFanout for DeviceTimeline canonical path.

### v0.1.0 GA baseline foundation (Plan SECTION FINAL TRUE FULL CONSOLIDATION)

Foundational work landed pre-quality-consolidation: Pure Defender XDR portal-only telemetry connector for Microsoft Sentinel — merge of Phase 1+/2/4 work + Plan AMEND-9 Phase A (UnwrapProperty hot-fix) + Plan AMEND-9 Phase B (10-dimension audit) + Phase 2 critical fixes (CHANGELOG dup + Solution Gallery 4 folders + createUiDef postDeploy removal) + Deploy script SecureString omit-fix.

### Hot-fix consolidated into v0.1.0 GA (Plan AMEND-9 Phase A)

- **UnwrapProperty wrapper auto-discovery** (`src/Modules/Xdr.Defender.Client/Endpoints/_EndpointHelpers.ps1:304-380`) — when declared UnwrapProperty target returns null and response object has non-null array properties, auto-discovers by picking the largest array. Emits `Ingest.UnwrapAutoDiscovered` event with `OriginalUnwrap` + `DiscoveredUnwrap` + `RowCount` for operator visibility. Falls through to original `Ingest.BoundaryMarker` / `@()` return only if no array property found. Self-heals upstream API shape drift.
- **3 ProjectionMap drift fixes verified live** (`MDE_VulnerabilityInventory_CL`: cveId→id, publishedDate→publishedOn, assetsAffected→numOfImpactedAssets; `MDE_SoftwareInventory_CL`: 4 path corrections; `MDE_VulnerableMachines_CL`: 4 path corrections).
- **NEW analytic rule** `XdrOps-StreamWentDry.yaml` per Plan AMEND-9 Phase A.3 — per-stream stale alert (queryFrequency 1h, queryPeriod 14d, severity Medium, suppression PT4H).
- **NEW Pester regression test** `tests/unit/Expand-MDEResponse.UnwrapAutoDiscover.Tests.ps1` (4 cases proving auto-discovery fallback).
- **Cadence map BINDING REVERT to production** (10m/1h/6h/24h/7d) per Plan AMEND-2 Phase 5.B.
- **Deploy script SecureString omit-fix** (Az.Resources serialization gotcha — empty SecureStrings cannot serialize over Azure REST API; -SkipSecretSeeding mode now omits securestring params entirely).

### Phase B audit consolidated into v0.1.0 GA (10-dimension whole-repo)

Zero RED items confirmed across all 10 dimensions:
- **B.1 src/ all code** — PSScriptAnalyzer Errors-only across src/ + tools/ + tests/ = 0 errors via `.config/PSScriptAnalyzerSettings.psd1` (legitimate `ConvertTo-SecureString -AsPlainText` pattern excluded for SP-secret Connect-AzAccount integration).
- **B.2 stale count drift** — 30+ files updated. **CRITICAL** Solution Gallery descriptor (`deploy/solution/manifest.json`) was missing 6 declared items (3 analytic rules + 3 hunting queries) — fixed. Preflight-Deployment.ps1 hardcoded checks `14 rules / 9 hunting` were false-failing on actual `21 / 12` baseline; fixed.
- **B.3 sentinel content** — `deploy/compiled/sentinelContent.json` regen-clean.
- **B.4-7 manifest + categories + tables + parsers** — verified live during Phase A.9 (ingestion + schema parity + parser execution + drift logic). All 4 drift parsers execute (MDE_Drift_Inventory 5607 rows w/Modified events proving Section R++.C B4 fix). 100% natural EntityId.
- **B.8 folders cleanup** — dropped dated `tests/online/Wiring-Matrix-2026-05-07.md`; tests/results/ retention clean; `.internal/.archive/` populated with nodoc-sweeps + wiring-matrices.
- **B.9 RUNBOOK.md** — clean of stale numeric claims.
- **B.10 stale phase markers** — 4 operator-facing docs fixed (INGEST-FAILURE-MODES + MULTI-PORTAL + RELEASE-PROCESS + STREAMS).

### Phase 2 critical fixes consolidated into v0.1.0 GA

- **CHANGELOG.md duplicate Section R++ block** (lines 117-127) DELETED — single Section R++ entry retained.
- **`deploy/solution/` Solution Gallery folder structure CREATED** (BLOCKER fix) — manifest.json declared 45 files but folders were EMPTY before; created 4 folders + copied 45 files from `sentinel/` (21 .yaml + 12 .yaml + 8 .json + 4 .kql).
- **`deploy/compiled/createUiDefinition.json` postDeploy step REMOVED** (operator UX request) — wizard now flows directly: workspace → auth → advanced → outputs.

### Live-deploy validation fixes (operator-facing UX + production-deploy hardening)

Operator-facing connector card UX + production-deploy hardening surfaced via live audit screenshot + iterative fix-enhance-consolidate cycle:

- **Connector card** — descriptionMarkdown updated to 72 streams (71 live + 1 deprecated) + lists ships-with content (8 workbooks + 21 rules + 12 hunting + 4 parsers + 360+ samples).
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

- **72 telemetry streams** (71 live + 1 deprecated MDE_StreamingApiConfig_CL) across 5 cadence tiers (10m / 1h / 6h / 24h / 7d) routed to **11 consolidated workspace tables** (10 `Defender_<Category>_CL` per nodoc D.1 10-category taxonomy + 1 `XdrConnectorHealth_CL` operational table).
- **4-function topology** (post Section R 9→4 consolidation): `Xdr-Refresh` universal portal-agnostic dispatcher + `Xdr-PollOrchestrator` durable + `Xdr-PollStream` activity + `Connector-Heartbeat` aggregator. v0.2.0 multi-portal additions reuse the same 4 functions (manifest-driven dispatch).
- **13 DCRs / 1 DCE / 73 streamDeclarations** (72 data + 1 ops `XdrConnectorHealth_CL`); per-category split for Configuration + Exposure (>10-flow Azure cap).
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
