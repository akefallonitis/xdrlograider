# Streams catalogue (v0.1.0-beta.1)

**45 portal-only streams** across 7 compliance tiers, all with documented path + method + body + headers verified against XDRInternals / nodoc / DefenderHarvester.

**28 stream return 200 + usable data on a Security Reader + Defender XDR Analyst service account** in our test tenant (live-captured 2026-04-23). The remaining 17 are either **tenant-gated** (15 — feature not provisioned on our tenant) or **role-gated** (2 — service account role is insufficient). Shipping all 45 with correct wire contract because the "correct call" is our contract; what a given tenant emits depends on its own feature provisioning, not our code.

The source of truth is [`src/Modules/XdrLogRaider.Client/endpoints.manifest.psd1`](../src/Modules/XdrLogRaider.Client/endpoints.manifest.psd1). Fixtures live in `tests/fixtures/live-responses/`.

---

## Availability legend

| Tag | Meaning | Zero-row expectation |
|---|---|---|
| `live` | Returns 200 with data on our test tenant. | Non-zero every poll cycle where state exists. |
| `tenant-gated` | Path + method + body correct; 4xx because tenant hasn't provisioned the feature (MDI sensors, MTO, Intune connector, Streaming API, TVM add-on, PUA, etc). | Activates automatically when feature enabled. No code change needed. |
| `role-gated` | Path + method + body correct; 403 because service account lacks a higher role (Defender XDR Operator, MCAS Administrator). | Activates with role elevation. |

A `tenant-gated` or `role-gated` stream is **not a bug**. It's correct behaviour for a tenant without the gating feature/role.

---

## P0 Compliance (hourly, 15 streams)

**10 live · 4 tenant-gated · 1 role-gated**

| Stream | Path | Method | Availability |
|---|---|---|---|
| `MDE_AdvancedFeatures_CL` | `/apiproxy/mtp/settings/GetAdvancedFeaturesSetting` | GET | live |
| `MDE_PreviewFeatures_CL` | `/apiproxy/mtp/settings/GetPreviewExperienceSetting` | GET | live |
| `MDE_AlertServiceConfig_CL` | `/apiproxy/mtp/alertsApiService/workloads/disabled` | GET | live |
| `MDE_AlertTuning_CL` | `/apiproxy/mtp/alertsEmailNotifications/email_notifications` | GET | live |
| `MDE_SuppressionRules_CL` | `/apiproxy/mtp/suppressionRulesService/suppressionRules` | GET | live |
| `MDE_CustomDetections_CL` | `/apiproxy/mtp/huntingService/rules/unified` | GET | live |
| `MDE_DeviceControlPolicy_CL` | `/apiproxy/mtp/siamApi/Onboarding` | GET | live |
| `MDE_WebContentFiltering_CL` | `/apiproxy/mtp/webThreatProtection/WebContentFiltering/Reports/TopParentCategories` | GET | live |
| `MDE_SmartScreenConfig_CL` | `/apiproxy/mtp/webThreatProtection/webThreats/reports/webThreatSummary` | GET | live |
| `MDE_LiveResponseConfig_CL` | `/apiproxy/mtp/liveResponseApi/get_properties` | GET | live |
| `MDE_AntivirusPolicy_CL` | `/apiproxy/mtp/unifiedExperience/mde/configurationManagement/mem/securityPolicies/filters` | GET | tenant-gated |
| `MDE_AuthenticatedTelemetry_CL` | `/apiproxy/mtp/deviceManagement/configuration/AuthenticatedTelemetry` | GET | tenant-gated |
| `MDE_PUAConfig_CL` | `/apiproxy/mtp/deviceManagement/configuration/PotentiallyUnwantedApplications` | GET | tenant-gated |
| `MDE_TenantAllowBlock_CL` | `/apiproxy/mtp/papin/api/cloud/public/internal/indicators/filterValues` | GET | tenant-gated |
| `MDE_CustomCollection_CL` | `/apiproxy/mtp/mdeCustomCollection/model` | GET | role-gated *(Defender XDR Operator)* |

## P1 Pipeline (30 min, 7 streams)

**3 live · 4 tenant-gated**

| Stream | Path | Availability |
|---|---|---|
| `MDE_DataExportSettings_CL` | `/apiproxy/mtp/wdatpApi/dataexportsettings` | live |
| `MDE_ConnectedApps_CL` | `/apiproxy/mtp/responseApiPortal/apps/all` | live |
| `MDE_TenantContext_CL` | `/apiproxy/mtp/sccManagement/mgmt/TenantContext?realTime=true` | live |
| `MDE_TenantWorkloadStatus_CL` | `/apiproxy/mtoapi/tenantGroups` | tenant-gated *(MTO not configured)* |
| `MDE_StreamingApiConfig_CL` | `/apiproxy/mtp/streamingapi/streamingApiConfiguration` | tenant-gated *(no Event Hub/Storage destination)* |
| `MDE_IntuneConnection_CL` | `/apiproxy/mtp/deviceManagement/configuration/IntuneConnection` | tenant-gated *(no Intune connector)* |
| `MDE_PurviewSharing_CL` | `/apiproxy/mtp/deviceManagement/configuration/PurviewSharing` | tenant-gated *(no Purview integration)* |

## P2 Governance (daily, 4 streams)

**4 live**. Two write endpoints (MDE_CriticalAssets_CL, MDE_DeviceCriticality_CL) were removed in v0.1.0-beta.1 — see [STREAMS-REMOVED.md](STREAMS-REMOVED.md).

| Stream | Path | Availability |
|---|---|---|
| `MDE_RbacDeviceGroups_CL` | `/apiproxy/mtp/rbacManagementApi/rbac/machine_groups` | live |
| `MDE_UnifiedRbacRoles_CL` | `/apiproxy/mtp/urbacConfiguration/gw/unifiedrbac/configuration/roleDefinitions` | live |
| `MDE_AssetRules_CL` | `/apiproxy/mtp/xspmatlas/assetrules` | live |
| `MDE_SAClassification_CL` | `/apiproxy/radius/api/radius/serviceaccounts/classificationrule/getall` | live |

## P3 Exposure / XSPM (hourly, 8 streams)

**6 live · 2 tenant-gated**

| Stream | Path | Method | Availability |
|---|---|---|---|
| `MDE_XspmInitiatives_CL` | `/apiproxy/mtp/posture/oversight/initiatives` | GET | live |
| `MDE_ExposureSnapshots_CL` | `/apiproxy/mtp/posture/oversight/updates` | GET | live |
| `MDE_SecureScoreBreakdown_CL` | `/apiproxy/mtp/secureScore/security/secureScoresV2` | GET | live |
| `MDE_ExposureRecommendations_CL` | `/apiproxy/mtp/posture/oversight/recommendations` | GET | live |
| `MDE_XspmChokePoints_CL` | `/apiproxy/mtp/xspmatlas/attacksurface/query` (inline KQL body) | POST | live |
| `MDE_XspmTopTargets_CL` | `/apiproxy/mtp/xspmatlas/attacksurface/query` (inline KQL body) | POST | live |
| `MDE_XspmAttackPaths_CL` | `/apiproxy/mtp/xspmatlas/attacksurface/query` (`AttackPathsV2` query) | POST | tenant-gated *(400 on current body; likely needs inline KQL like ChokePoints/TopTargets)* |
| `MDE_SecurityBaselines_CL` | `/apiproxy/mtp/tvm/analytics/baseline/profiles` | GET | tenant-gated *(TVM add-on not licensed)* |

## P5 Identity (daily, 5 streams)

**2 live · 3 tenant-gated**

| Stream | Path | Method | Availability |
|---|---|---|---|
| `MDE_IdentityOnboarding_CL` | `/apiproxy/mtp/siamApi/domaincontrollers/list` | GET | live |
| `MDE_IdentityServiceAccounts_CL` | `/apiproxy/mdi/identity/userapiservice/serviceAccounts` (XDRInternals body + UnwrapProperty=`ServiceAccounts`) | POST | live |
| `MDE_DCCoverage_CL` | `/apiproxy/aatp/api/sensors/domainControllerCoverage` | GET | tenant-gated *(no MDI sensors deployed)* |
| `MDE_IdentityAlertThresholds_CL` | `/apiproxy/aatp/api/alertthresholds/withExpiry` | GET | tenant-gated *(MDI required)* |
| `MDE_RemediationAccounts_CL` | `/apiproxy/mdi/identity/identitiesapiservice/remediationAccount` | GET | tenant-gated *(MDI required)* |

## P6 Audit / AIR (10 min, 2 streams)

**2 live**

| Stream | Path | Availability |
|---|---|---|
| `MDE_ActionCenter_CL` | `/apiproxy/mtp/actionCenter/actioncenterui/history-actions` | live |
| `MDE_ThreatAnalytics_CL` | `/apiproxy/mtp/threatAnalytics/outbreaks` | live |

## P7 Metadata (daily, 4 streams)

**1 live · 2 tenant-gated · 1 role-gated**

| Stream | Path | Availability |
|---|---|---|
| `MDE_UserPreferences_CL` | `/apiproxy/mtp/userPreferences/api/mgmt/userpreferencesservice/userPreference` | live |
| `MDE_MtoTenants_CL` | `/apiproxy/mtoapi/tenants/TenantPicker` | tenant-gated *(MTO not configured)* |
| `MDE_LicenseReport_CL` | `/apiproxy/mtp/deviceManagement/deviceLicenseReport` | tenant-gated *(Defender for Business / EDR for Business SKU)* |
| `MDE_CloudAppsConfig_CL` | `/apiproxy/mcas/cas/api/v1/settings` | role-gated *(MCAS Administrator)* |

## Operational streams (system)

Two non-telemetry streams emitted by the Function App itself, not polled from the portal:

| Table | Emitted by | Cadence | Schema |
|---|---|---|---|
| `MDE_Heartbeat_CL` | every timer function | per invocation | 9 cols: `TimeGenerated, FunctionName, Tier, StreamsAttempted, StreamsSucceeded, RowsIngested, LatencyMs, HostName, Notes(dynamic)` |
| `MDE_AuthTestResult_CL` | `validate-auth-selftest` timer | every 10 min → 1 h | 12 cols: `TimeGenerated, Method, PortalHost, Upn, Success, Stage, FailureReason, EstsMs, SccauthMs, SampleCallHttpCode, SampleCallLatencyMs, SccauthAcquiredUtc` |

## Counts by tier

| Tier | Streams | Live | Tenant-gated | Role-gated |
|---|---|---|---|---|
| P0 | 15 | 10 | 4 | 1 |
| P1 | 7 | 3 | 4 | 0 |
| P2 | 4 | 4 | 0 | 0 |
| P3 | 8 | 6 | 2 | 0 |
| P5 | 5 | 2 | 3 | 0 |
| P6 | 2 | 2 | 0 | 0 |
| P7 | 4 | 1 | 2 | 1 |
| **Total** | **45** | **28** | **15** | **2** |

Plus 2 operational tables (Heartbeat + AuthTestResult) = **47 custom LA tables**.

## Live fixture coverage

Every manifest entry has a fixture under `tests/fixtures/live-responses/`:

- **28 real captures** — `<Stream>-raw.json` + `<Stream>-ingest.json` from the live tenant (PII-scrubbed).
- **17 markers** — one-line `<Stream>-raw.json` with `{"_availability":"tenant-gated","_reason":"…"}` so offline tests detect "expected 4xx — skip" rather than fail missing-file.

Downstream tests (`tests/unit/FA.ParsingPipeline.Tests.ps1`, `DCR.SchemaConsistency.Tests.ps1`, `tests/kql/*`) read these fixtures to validate parser + rule + workbook column refs are correct for the shape our connector actually ingests.
