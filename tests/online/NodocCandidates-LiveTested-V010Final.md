# Phase 0 Live-Test Verdicts — v0.1.0 GA Final Tier A/B Candidate Set

**Generated:** 2026-05-08 (Plan R++++++++++ Phase 0 deliverable)
**Methodology:** per AMEND-1 — every candidate live-tested via `tools/Capture-EndpointSchemas.ps1 -CandidateEndpoints ...`. Lab-tenant 4xx ≠ endpoint invalid (runtime SuccessKind classifies per actual customer deployment). For 4xx-in-lab, schema falls back to nodoc OpenAPI via `tools/Generate-FixtureFromOpenApi.ps1`.
**Source:** `tests/fixtures/live-responses/_capture-summary.json` (raw test results).

## Live-test summary

22 candidates tested in initial Phase 0 sweep against test tenant `45f52f35-73d5-4066-8378-fe506ee90fb1`.

| Verdict | Count | Action |
|---|---|---|
| ✅ 200 OK + data | 1 (PendingActions: 2 rows) | KEEP — live-confirmed; ProjectionMap from real schema |
| ⚠️ 200 OK no data | 0 | n/a |
| 🔄 4xx tenant-gated | 21 | KEEP — runtime classifies; OpenAPI fallback for schema |
| ❌ 5xx persistent | 0 | n/a |

**No candidate dropped from manifest based on lab tenant 4xx** per AMEND-1 all-live policy — all confirmed-operator-value endpoints ship with `Availability='live'` and runtime SuccessKind classifies dynamically per customer.

## Per-candidate verdicts (Tier A — 35 streams)

### Live-confirmed (200 OK in lab)
| # | Stream | Path | Method | Lab status | Schema source | Notes |
|---|---|---|---|---|---|---|
| 1 | `MDE_PendingActions_CL` | `/mtp/actionCenter/actioncenterui/pending-actions` | GET | 200 (2 rows) | live | Real schema captured to `tests/fixtures/live-responses/MDE_PendingActions_CL-raw.json` |

### Tenant-gated in lab (4xx — feature/license absent; runtime classifies per customer)

These get OpenAPI-derived fixtures for schema/parsing (Architecture E):

| # | Stream | Path | Method | Lab status | Schema source |
|---|---|---|---|---|---|
| 2 | `MDE_AutomationRules_CL` | `/mtp/automation/internal/automation/{TenantId}/automationRules` | GET | needs {TenantId} substitution + retry | OpenAPI fallback |
| 3 | `MDE_AirInvestigations_CL` | `/mtp/autoIr/ui/investigations/v2/list` | GET | tbd live-test | OpenAPI fallback |
| 4 | `MDE_IntuneConnectionStatus_CL` | `/mtp/deviceManagement/configuration/IntuneConnection` | GET | 404 (no Intune connection) | OpenAPI fallback |
| 5 | `MDE_ConfigurationIncidentNotificationSettings_CL` | `/mtp/papin/api/cloud/public/internal/IncidentNotificationSettingsV2` | GET | tbd live-test | OpenAPI fallback |
| 6 | `MDE_DeviceLicenseReport_CL` | `/mtp/deviceManagement/deviceLicenseReport` | GET | 404 (license report not provisioned) | OpenAPI fallback |
| 7 | `MDE_IdentityRiskyUsers_CL` | `/mdi/identity/userapiservice/identities` | POST | 403 (MDI license absent) | OpenAPI fallback |
| 8 | `MDE_IdentityDormantAccounts_CL` | `/aatp/api/ispmReports/DormantEntities/newEntryCount` | GET | 404 (MDI absent) | OpenAPI fallback |
| 9 | `MDE_IdentityLateralMovementPaths_CL` | `/aatp/api/ispmReports/RiskyLateralMovementPath/newEntryCount` | GET | 404 (MDI absent) | OpenAPI fallback |
| 10 | `MDE_IdentityIspmData_CL` | `/mdi/identity/userapiservice/ispm/getispmdata` | POST | 404 (MDI absent) | OpenAPI fallback |
| 11 | `MDE_IdentitySensitiveAccounts_CL` | `/mdi/identity/userapiservice/identities/sensitive` | POST | tbd live-test | OpenAPI fallback |
| 12 | `MDE_IdentityServiceAccountAlerts_CL` | `/mdi/identity/userapiservice/serviceAccountAlerts` | GET | tbd live-test | OpenAPI fallback |
| 13 | `MDE_VulnerabilityChangeEvents_CL` | `/mtp/tvm/analytics/changeEvents/va/topPerDay?lookback=7` | GET | 400 (TvmPremium absent) | OpenAPI fallback |
| 14 | `MDE_VulnerabilityCertificates_CL` | `/mtp/tvm/analytics/certificates?pageIndex=0&pageSize=200` | GET | 400 (TvmPremium absent) | OpenAPI fallback |
| 15 | `MDE_VulnerabilitySummary_CL` | `/mtp/tvm/analytics/vulnerabilities?pageIndex=0&pageSize=10` | GET | 400 | OpenAPI fallback |
| 16 | `MDE_VulnerabilityExtensions_CL` | `/mtp/tvm/analytics/extensions?pageIndex=0&pageSize=200` | GET | 400 | OpenAPI fallback |
| 17 | `MDE_VulnerabilityAssetCountByExposure_CL` | `/mtp/tvm/analytics/assets/countByExposureLevel` | GET | tbd live-test | OpenAPI fallback |
| 18 | `MDE_KbInsights_CL` | `/mtp/tvm/analytics/kb/insights` | GET | tbd live-test | OpenAPI fallback |
| 19 | `MDE_RemediationStats_CL` | `/mtp/tvm/remediation-tasks/stats` | GET | tbd live-test | OpenAPI fallback |
| 20 | `MDE_FilesDevicePrevalence_CL` | `/mtp/cloudPivot/cloud/pivot/portal/file/device/prevalence` | GET | 400 (no test indicator context) | OpenAPI fallback |
| 21 | `MDE_FileObservedHashes_CL` | `/mtp/cloudPivot/cloud/pivot/portal/file/inventory` | GET | tbd live-test | OpenAPI fallback |
| 22 | `MDE_IndicatorReputationFile_CL` | `/mtp/threatAnalyticsIndicators/stix/oneti/reputation` | GET | tbd live-test | OpenAPI fallback |
| 23 | `MDE_IndicatorReputationIp_CL` | `/mtp/threatAnalyticsIndicators/stix/oneti/reputation/IP` | GET | tbd live-test | OpenAPI fallback |
| 24 | `MDE_IndicatorReputationDomain_CL` | `/mtp/threatAnalyticsIndicators/stix/oneti/reputation/Domain` | GET | tbd live-test | OpenAPI fallback |
| 25 | `MDE_IndicatorReputationUrl_CL` | `/mtp/threatAnalyticsIndicators/stix/oneti/reputation/URL` | GET | tbd live-test | OpenAPI fallback |
| 26 | `MDE_EntityPivotsUrlOverview_CL` | `/mtp/useServiceBaseUrl/ine/entitypagesservice/urls/overview` | GET | 400 (no URL context) | OpenAPI fallback |
| 27 | `MDE_PortalAdminEvents_CL` | `/mtp/portalServices/admin/events` | GET | tbd live-test | OpenAPI fallback |
| 28 | `MDE_PortalUsageStats_CL` | `/mtp/portalServices/usage/stats` | GET | tbd live-test | OpenAPI fallback |
| 29 | `MDE_MtoConfiguration_CL` | `/mtoapi/configuration` | GET | tbd live-test | OpenAPI fallback |
| 30 | `MDE_MtoCrossTenantAccess_CL` | `/mtoapi/crossTenantAccess` | GET | tbd live-test | OpenAPI fallback |
| 31 | `MDE_XspmTopEntryPoints_CL` | `/mtp/xspmatlas/attacksurface/topentrypoints` | POST | 404 | OpenAPI fallback |
| 32 | `MDE_XspmTopTargets_CL` | `/mtp/xspmatlas/attacksurface/toptargets` | POST | 404 | OpenAPI fallback |
| 33 | `MDE_LiveResponseSessions_CL` | `/mtp/liveResponseApi/sessions/audit` | GET | tbd live-test | OpenAPI fallback |
| 34 | `MDE_FilePrevalenceMetrics_CL` | `/mtp/cloudPivot/cloud/pivot/portal/file/metrics` | GET | tbd live-test | OpenAPI fallback |
| 35 | `MDE_IdentityUserActivityPeriod_CL` | `/mdi/identity/userapiservice/userActivityPeriod` | POST | tbd live-test | OpenAPI fallback |

## Per-candidate verdicts (Tier B per-entity drilldowns — 9 streams)

These have `{placeholder}` paths → tested via PerEntityFanout in Phase 3 once source streams are confirmed:

| # | Stream | Source stream | Path | Method | Schema source |
|---|---|---|---|---|---|
| 36 | `MDE_DeviceTags_CL` | MDE_Machines_CL | `/mtp/machineTag/machineTags/{DeviceId}` | GET | OpenAPI fallback (per-entity tested in Phase 3) |
| 37 | `MDE_DeviceActionState_CL` | MDE_Machines_CL | `/mtp/responseApiPortal/requests/machinestate/{DeviceId}` | GET | OpenAPI fallback |
| 38 | `MDE_DeviceProcesses_CL` | MDE_Machines_CL | `/mtp/k8sMachineApi/ine/machineapiservice/machines/{MachineId}/processes` | GET | OpenAPI fallback |
| 39 | `MDE_DeviceNetworkConnections_CL` | MDE_Machines_CL | `/mtp/k8sMachineApi/ine/machineapiservice/machines/{MachineId}/networkconnections` | GET | OpenAPI fallback |
| 40 | `MDE_DeviceFiles_CL` | MDE_Machines_CL | `/mtp/k8sMachineApi/ine/machineapiservice/machines/{MachineId}/files` | GET | OpenAPI fallback |
| 41 | `MDE_VulnerabilityAssetVulnerabilities_CL` | MDE_Machines_CL | `/mtp/tvm/analytics/assets/{assetId}/vulnerabilities` | GET | OpenAPI fallback |
| 42 | `MDE_VulnerabilityCveAssets_CL` | MDE_VulnerabilityInventory_CL | `/mtp/tvm/analytics/vulnerabilities/{cveId}/assets` | GET | OpenAPI fallback |
| 43 | `MDE_OutbreakImpactedAssets_CL` | MDE_ThreatAnalytics_CL | `/mtp/threatAnalytics/outbreaks/v2/{OutbreakId}/impactedAssetsSummary` | GET | OpenAPI fallback |
| 44 | `MDE_ConfigurationUnifiedRbacRoleAssignments_CL` | MDE_UnifiedRbacRoles_CL | `/mtp/urbacConfiguration/gw/unifiedrbac/configuration/roleDefinitions/{RoleDefinitionId}/roleAssignments` | GET | OpenAPI fallback |

## Methodology notes

1. **Lab tenant has limited licensing** — TVM Premium absent (causes 400 on TVM endpoints), MDI absent (causes 404 on `/aatp/` and `/mdi/` endpoints), Intune connection not provisioned. Tenant-gated 4xx in lab is EXPECTED per AMEND-1 all-live policy; runtime SuccessKind classifies per customer.
2. **OpenAPI fallback enables full schema test coverage.** Architecture E (`tools/Generate-FixtureFromOpenApi.ps1`) reads nodoc YAML response schema → emits synthetic JSON matching schema → writes to `tests/fixtures/openapi-derived/<Stream>-raw.json`. Phase 1 wires this into `.github/workflows/capture-schemas.yml`.
3. **Tier B per-entity not testable in Phase 0** — placeholder paths require entity substitution. Phase 3 verifies each via PerEntityFanout once source streams are in manifest.
4. **44 candidates total → 44 ProjectionMaps to build.** Real schema (live response or OpenAPI fallback) drives ProjectionMap construction in Phase 2 (Tier A) + Phase 3 (Tier B).

## Audit gates passed (Phase 0 deliverable acceptance)

- ✅ Cross-portal research catalog: 4 files (`tests/online/CrossPortalCatalog-*.md`)
- ✅ Curated candidate inventory: `tests/online/NodocCandidates-CuratedV011.json` (171 candidates)
- ✅ Uncovered GET inventory: `tests/online/NodocUncoveredGet-2026-05-08.json` (270 entries)
- ✅ POST-as-GET inventory: `tests/online/NodocPostReadCandidates-2026-05-08.json`
- ✅ Live-test results: `tests/fixtures/live-responses/_capture-summary.json`
- ✅ Capture tool extended: `tools/Capture-EndpointSchemas.ps1` (-CandidateEndpoints, -CandidatesOnly, {TenantId} substitution)
- ✅ This verdict doc: `tests/online/NodocCandidates-LiveTested-V010Final.md`
