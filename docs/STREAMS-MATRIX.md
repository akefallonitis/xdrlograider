# XdrLogRaider — Per-stream consolidated matrix

> v0.1.0 GA. The operational source-of-truth for every stream's current state, manifest contract, and verified live behavior.

This is the canonical reference for "what does each stream do, what's its current state, where does it land in operator KQL, and what's its v0.2.0+ roadmap." Auto-derived from `src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1` + live verification (workspace `3f75ec26-38a2-4f3d-9330-f439d90847bb`, 2026-05-03).

## Reading the matrix

| Column | Meaning |
|---|---|
| Stream | Custom Log Analytics table name (`MDE_<stream>_CL`) |
| Cadence | Polling tier: `fast` (10m), `exposure` (1h), `config` (6h), `inventory` (1d), `maintenance` (1w) |
| Avail | `live` (test tenant returns 2xx + has data), `tenant-gated` (correctly errors on test tenant — needs MDI/TVM/MEM/MCAS license), `deprecated` |
| Shape | Response-handling pattern (per `Expand-MDEResponse`): array, wrapper-array (UnwrapProperty), property-bag (Shape 3), scalar (Shape 4), single-object (SingleObjectAsRow) |
| Manifest | ✅ correct, ⚠️ rewritten in iter-14.0 Phase 1 |
| DCR | ✅ matches manifest ProjectionMap; legacy back-compat cols preserved |
| Live verified | ✅ healthy + row count, ⚠️ live-but-no-data, ⏳ within-cadence (next fire), ❌ correctly tenant-gated |

## Fast tier (10-min cadence)

| Stream | Avail | Shape | Manifest | DCR | Live verified |
|---|---|---|---|---|---|
| MDE_ActionCenter_CL | live | wrapper `Results` | ✅ | ✅ | ✅ healthy (per-action rows, ~30 in last fire) |
| MDE_MachineActions_CL | tenant-gated | wrapper `value` (verify) | ✅ | ✅ | ❌ no LR sessions in tenant — expected 404 |

## Exposure tier (1-hour cadence)

| Stream | Avail | Shape | Manifest | DCR | Live verified |
|---|---|---|---|---|---|
| MDE_AssetRules_CL | live | wrapper `rules` (iter-14.0) | ✅ | ✅ | ✅ healthy (130 critical-asset rules) |
| MDE_XspmInitiatives_CL | live | wrapper `results` (iter-14.0) | ✅ | ✅ | ✅ healthy (10 initiatives) |
| MDE_ExposureSnapshots_CL | live | wrapper `results` | ✅ | ✅ | ⏳ within-cadence (no recent posture updates) |
| MDE_ExposureRecommendations_CL | live | wrapper `results` | ✅ | ✅ | ✅ healthy (10 recommendations) |
| MDE_XspmAttackPaths_CL | live | wrapper `data` POST | ✅ | ✅ | ✅ healthy (12 paths) |
| MDE_XspmChokePoints_CL | live | wrapper `data` POST | ✅ | ✅ | ✅ healthy (12 chokepoints) |
| MDE_XspmTopTargets_CL | live | wrapper `data` POST | ✅ | ✅ | ✅ healthy (12 top targets) |

## Config tier (6-hour cadence)

| Stream | Avail | Shape | Manifest | DCR | Live verified |
|---|---|---|---|---|---|
| MDE_PreviewFeatures_CL | live | property-bag (Shape 3) | ⚠️ Phase 1 (FeatureName + Value) | ✅ | ✅ healthy (FeatureName populated; per-property cols back-compat null) |
| MDE_AlertServiceConfig_CL | live | array | ✅ | ✅ | ⏳ empty in tenant (no per-workload overrides) |
| MDE_AlertTuning_CL | live | wrapper `items` (iter-14.0 Phase 4) | ⚠️ Phase 4 added UnwrapProperty | ✅ | ⏳ empty in tenant (no email rules) |
| MDE_SuppressionRules_CL | live | array | ✅ | ✅ | ✅ healthy (18 rules) |
| MDE_CustomDetections_CL | live | wrapper `Rules` | ✅ | ✅ | ⏳ empty in tenant (no custom detections deployed) |
| MDE_TenantAllowBlock_CL | tenant-gated | facet | ⚠️ misrouted; v0.2.0 path correction | ✅ | ❌ tenant returns 500; v0.2.0 swap to `/indicators/getQuery` |
| MDE_RbacDeviceGroups_CL | live | wrapper `items` | ✅ | ✅ | ✅ healthy (4 device groups) |
| MDE_UnifiedRbacRoles_CL | live | wrapper `value` (iter-14.0 Phase 4) | ⚠️ Phase 4 added UnwrapProperty | ✅ | ⏳ empty in tenant |
| MDE_ConnectedApps_CL | live | single-object (iter-14.0 Phase 1) | ⚠️ Phase 1 SingleObjectAsRow | ✅ | ✅ healthy (1 connected app) |
| MDE_IntuneConnection_CL | live | scalar (Shape 4) | ⚠️ Phase 1 (FeatureName + Status + IsEnabled) | ✅ | ✅ healthy (Status=0, IsEnabled=false — Intune not connected) |
| MDE_PurviewSharing_CL | live | scalar (Shape 4) | ⚠️ Phase 1 (FeatureName + IsEnabled; legacy AlertSharingEnabled) | ✅ | ✅ healthy (false) |
| MDE_UserPreferences_CL | live | single-object (iter-14.0 Phase 1) | ⚠️ Phase 1 SingleObjectAsRow + UserPreferencesJson | ✅ | ✅ healthy (1 row with full operator preferences JSON) |
| MDE_ThreatAnalytics_CL | live | array (large) | ✅ | ✅ | ✅ healthy (2,960 outbreak rows) |

## Inventory tier (1-day cadence)

| Stream | Avail | Shape | Manifest | DCR | Live verified |
|---|---|---|---|---|---|
| MDE_AdvancedFeatures_CL | live | property-bag (Shape 3) | ⚠️ Phase 1 (FeatureName + IsEnabled; legacy 4 per-property) | ✅ | ✅ healthy (32 feature rows) |
| MDE_DeviceControlPolicy_CL | live | property-bag | ⚠️ Phase 1 (FeatureName + Value; legacy 3 per-property) | ✅ | ✅ healthy (3 rows) |
| MDE_WebContentFiltering_CL | live | wrapper `TopParentCategories` (Shape 2 unwrap) | ⚠️ Phase 1 rewrite to Shape 2 | ✅ | ✅ healthy (per-category rows) |
| MDE_SmartScreenConfig_CL | live | property-bag | ⚠️ Phase 1 (FeatureName + Value; legacy 6 per-counter) | ✅ | ✅ healthy (10 counter rows) |
| MDE_LiveResponseConfig_CL | live | property-bag | ⚠️ Phase 1 (FeatureName + IsEnabled; legacy 3 per-property) | ✅ | ✅ healthy (3 rows) |
| MDE_AuthenticatedTelemetry_CL | live | scalar (Shape 4) | ⚠️ Phase 1 (FeatureName + IsEnabled; legacy AllowNonAuthSense) | ✅ | ✅ healthy (1 row, true) |
| MDE_PUAConfig_CL | live | property-bag | ⚠️ Phase 1 (FeatureName + IsEnabled; legacy 2 per-property) | ✅ | ✅ healthy (2 rows) |
| MDE_AntivirusPolicy_CL | tenant-gated | facet | ⚠️ misrouted; v0.2.0 path correction | ✅ | ❌ tenant 400 — no MEM in test tenant |
| MDE_CustomCollection_CL | tenant-gated | array | ✅ (iter-14.0) | ✅ | ❌ tenant 403 — needs role |
| MDE_TenantContext_CL | live | single-object (iter-14.0 Phase 1) | ⚠️ Phase 1 SingleObjectAsRow + 13 typed cols | ✅ | ✅ healthy (1 row with EnvironmentName/OrgId/Region/etc) |
| MDE_TenantWorkloadStatus_CL | live | single-object (iter-14.0 Phase 4) | ⚠️ Phase 4 SingleObjectAsRow | ✅ | ✅ healthy (1 row with tenant workgroup) |
| MDE_SAClassification_CL | live | wrapper (verify; tenant-empty) | ✅ | ✅ | ❌ no MDI service-account classification rules |
| MDE_IdentityOnboarding_CL | live | wrapper `DomainControllers` | ✅ | ✅ | ❌ no MDI in tenant |
| MDE_IdentityServiceAccounts_CL | live | wrapper `ServiceAccounts` POST | ✅ | ✅ | ❌ no MDI in tenant |
| MDE_DCCoverage_CL | tenant-gated | singleton | ⚠️ misrouted; v0.2.0 | ✅ | ❌ no MDI in tenant |
| MDE_IdentityAlertThresholds_CL | tenant-gated | wrapper `AlertThresholds` (iter-14.0) | ✅ + back-compat | ✅ | ❌ no MDI |
| MDE_RemediationAccounts_CL | tenant-gated | singleton config | ⚠️ misrouted; v0.2.0 | ✅ | ❌ no MDI |
| MDE_SecurityBaselines_CL | tenant-gated | wrapper `results` (iter-14.0) | ✅ + back-compat | ✅ | ❌ no TVM |
| MDE_DeviceTimeline_CL | tenant-gated | wrapper `Results` POST (verify Items vs Results in v0.2.0) | ✅ | ✅ | ❌ no timeline opt-in |
| MDE_MtoTenants_CL | live | wrapper `tenantInfoList` | ✅ | ✅ | ✅ healthy (1 tenant) |
| MDE_LicenseReport_CL | live | wrapper `sums` | ✅ | ✅ | ✅ healthy (per-SKU rollup rows) |
| MDE_CloudAppsConfig_CL | tenant-gated | singleton | ⚠️ misrouted; v0.2.0 | ✅ | ❌ no MCAS |

## Maintenance tier (1-week cadence)

| Stream | Avail | Shape | Manifest | DCR | Live verified |
|---|---|---|---|---|---|
| MDE_DataExportSettings_CL | live (hybrid) | wrapper `value` (iter-14.0 Phase 4) | ⚠️ Phase 4 added UnwrapProperty | ✅ | ✅ healthy (workspace destination row) |
| MDE_StreamingApiConfig_CL | deprecated | n/a | n/a | declared back-compat | ❌ 404 expected (deprecated path); v0.2.0 may remove entirely |

## Operator KQL conventions

### Property-bag streams (Shape 3) — query by FeatureName

```kql
MDE_AdvancedFeatures_CL
| where FeatureName == 'EnableMcasIntegration'
| project TimeGenerated, FeatureName, IsEnabled
| order by TimeGenerated desc
```

### Single-object streams (SingleObjectAsRow) — query latest row

```kql
MDE_TenantContext_CL
| top 1 by TimeGenerated desc
| project EnvironmentName, OrgId, Region, IsMdatpActive, IsSentinelActive, IsMdiActive
```

### Wrapper-array streams (UnwrapProperty) — query per-entity rows

```kql
MDE_ExposureRecommendations_CL
| where TimeGenerated > ago(1d)
| where Severity == 'high'
| project TimeGenerated, RecommendationId, Title, Severity, Status, Score, MaxScore
| order by Score desc
```

### Drift parsers (column-agnostic)

```kql
MDE_Drift_Inventory(7d, 1d) | where StreamName == 'MDE_AdvancedFeatures_CL' and ChangeType == 'Modified'
```

## Adding a new stream (the 9-step gated workflow per Section 3 of plan)

1. **CAPTURE** — `pwsh tools/Capture-EndpointSchemas.ps1 -EnvFile tests/.env.local`
2. **DESIGN** — add manifest entry against the captured fixture (UnwrapProperty / SingleObjectAsRow / IdProperty / ProjectionMap)
3. **DERIVE** — add DCR streamDeclaration cols + workspace table schema cols in `mainTemplate.json`
4. **CONTENT** — add parser/rule/workbook references if needed
5. **UNIT TEST** — `pwsh tests/Run-Tests.ps1 -Category all-offline` GREEN (FA.ParsingPipeline + Manifest.ProjectionResolution gates)
6. **ONLINE PREFLIGHT** — `pwsh tests/Run-Tests.ps1 -Category online-preflight` GREEN
7. **WHAT-IF** — `pwsh tests/Run-Tests.ps1 -Category whatif` GREEN
8. **DEPLOY** — Deploy-to-Azure URL or tag-push release
9. **POST-DEPLOY VERIFY** — `pwsh tools/Post-DeploymentVerification.ps1` P1-P14 GREEN

Skipping any step = trial-and-error = regression.

## v0.2.0+ roadmap (per Section 14 of senior-architect plan)

- 6 stream path corrections (TenantAllowBlock / AntivirusPolicy / DCCoverage / RemediationAccounts / DeviceTimeline / CloudAppsConfig) — switch to operator-richer canonical paths per `nodoc` + `XDRInternals` research
- 15-20 new portal-only streams (XSPM v3, Defender for Cloud config, Identity Protection alert tuning)
- Multi-portal expansion (Entra / Purview / Intune / admin.cloud.microsoft) — re-use auth chain
- $json: projection adoption (preserve nested objects: GroupRules, Features, scriptOutputs)
- Container Apps (ACA) hosting validation as Function-app deprecation insulation
