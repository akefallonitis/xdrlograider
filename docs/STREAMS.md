# Streams catalogue (v1.0.2)

**47 portal-only streams** ingested by XdrLogRaider, grouped by cadence tier.
Of those, **25 are actively polled** on a Security Reader + Defender XDR Analyst
service account, and **22 are deferred** (endpoint returns 4xx/5xx until a
tenant-side feature is enabled, a POST body is HAR-captured, or the service
account is elevated). Each deferred entry carries a machine-readable
`DeferReason` tag in [`src/Modules/XdrLogRaider.Client/endpoints.manifest.psd1`].

**Source of truth**: the manifest PSD1. Paths below are taken directly from it
and reflect the live-verified 2026-04-23 audit. DeferReason prefixes:

| Tag | Meaning |
|---|---|
| `FEATURE_NOT_ENABLED` | Path is correct per nodoc / XDRInternals / DefenderHarvester research; 4xx/5xx live because the tenant hasn't provisioned the feature. Auto-activates once the feature is turned on. |
| `POST_BODY_UNKNOWN` | Path + method (POST) correct; body filter schema not documented anywhere public. Needs operator HAR capture from browser session (v1.1 scope). |
| `NEEDS_HIGHER_PRIV` | Endpoint requires Defender XDR Operator or MCAS Administrator role — Security Reader insufficient. |

## P0 — Security configuration (hourly, 15 streams)

**Active (10)**

| Table | Path | Notes |
|---|---|---|
| `MDE_AdvancedFeatures_CL` | `/apiproxy/mtp/settings/GetAdvancedFeaturesSetting` | Tenant advanced-feature flags (PUA, TamperProtection, etc.) |
| `MDE_PreviewFeatures_CL` | `/apiproxy/mtp/settings/GetPreviewExperienceSetting` | Preview experience opt-in state |
| `MDE_AlertServiceConfig_CL` | `/apiproxy/mtp/alertsApiService/workloads/disabled` | Alert workloads currently disabled |
| `MDE_AlertTuning_CL` | `/apiproxy/mtp/alertsEmailNotifications/email_notifications` | Email-notification rules |
| `MDE_SuppressionRules_CL` | `/apiproxy/mtp/suppressionRulesService/suppressionRules` | Active alert-suppression rules (filter=fromDate) |
| `MDE_CustomDetections_CL` | `/apiproxy/mtp/huntingService/rules/unified` | Custom detection KQL + schedule (filter=fromDate) |
| `MDE_DeviceControlPolicy_CL` | `/apiproxy/mtp/siamApi/Onboarding` | MDE onboarding + device-control policy state |
| `MDE_WebContentFiltering_CL` | `/apiproxy/mtp/webThreatProtection/WebContentFiltering/Reports/TopParentCategories` | Web-filtering active categories |
| `MDE_SmartScreenConfig_CL` | `/apiproxy/mtp/webThreatProtection/webThreats/reports/webThreatSummary` | SmartScreen detection summary |
| `MDE_LiveResponseConfig_CL` | `/apiproxy/mtp/liveResponseApi/get_properties` | Live Response policy (unsigned scripts, etc.) |

**Deferred (5)**

| Table | Path | DeferReason |
|---|---|---|
| `MDE_AuthenticatedTelemetry_CL` | `/apiproxy/mtp/deviceManagement/configuration/AuthenticatedTelemetry` | `FEATURE_NOT_ENABLED` — tenant hasn't provisioned authenticated telemetry |
| `MDE_PUAConfig_CL` | `/apiproxy/mtp/deviceManagement/configuration/PotentiallyUnwantedApplications` | `FEATURE_NOT_ENABLED` — tenant PUA protection not configured |
| `MDE_AntivirusPolicy_CL` | `/apiproxy/mtp/unifiedExperience/mde/configurationManagement/mem/securityPolicies/filters` | `POST_BODY_UNKNOWN` — HAR needed from MEM security policies page |
| `MDE_TenantAllowBlock_CL` | `/apiproxy/mtp/papin/api/cloud/public/internal/indicators/filterValues` | `POST_BODY_UNKNOWN` — HAR needed from Indicators page |
| `MDE_CustomCollection_CL` | `/apiproxy/mtp/mdeCustomCollection/model` | `NEEDS_HIGHER_PRIV` — 403 as Security Reader, requires Defender XDR Operator |

## P1 — Integration + pipeline state (30-min, 7 streams)

**Active (3)**

| Table | Path |
|---|---|
| `MDE_DataExportSettings_CL` | `/apiproxy/mtp/wdatpApi/dataexportsettings` |
| `MDE_ConnectedApps_CL` | `/apiproxy/mtp/responseApiPortal/apps/all` |
| `MDE_TenantContext_CL` | `/apiproxy/mtp/sccManagement/mgmt/TenantContext?realTime=true` |

**Deferred (4)**

| Table | DeferReason |
|---|---|
| `MDE_TenantWorkloadStatus_CL` | `FEATURE_NOT_ENABLED` — MTO (Multi-Tenant Organization) not configured; live 400 on single-tenant |
| `MDE_StreamingApiConfig_CL` | `FEATURE_NOT_ENABLED` — streaming API not configured (no Event Hub/Storage destination) |
| `MDE_IntuneConnection_CL` | `FEATURE_NOT_ENABLED` — MDE-Intune connection not set up |
| `MDE_PurviewSharing_CL` | `FEATURE_NOT_ENABLED` — Purview integration not configured |

## P2 — Governance + RBAC (daily, 6 streams)

**Active (4)**

| Table | Path |
|---|---|
| `MDE_RbacDeviceGroups_CL` | `/apiproxy/mtp/rbacManagementApi/rbac/machine_groups` |
| `MDE_UnifiedRbacRoles_CL` | `/apiproxy/mtp/urbacConfiguration/gw/unifiedrbac/configuration/roleDefinitions` |
| `MDE_AssetRules_CL` | `/apiproxy/mtp/xspmatlas/assetrules` |
| `MDE_SAClassification_CL` | `/apiproxy/radius/api/radius/serviceaccounts/classificationrule/getall` |

**Deferred (2)** — v1.0.2 fixed paths to NDR endpoints per XDRInternals lines 68-69, body schema pending

| Table | Path | DeferReason |
|---|---|---|
| `MDE_DeviceCriticality_CL` | `/apiproxy/mtp/ndr/machines/assetValues` (POST) | `POST_BODY_UNKNOWN` |
| `MDE_CriticalAssets_CL` | `/apiproxy/mtp/ndr/machines/criticalityLevel` (POST) | `POST_BODY_UNKNOWN` |

## P3 — Exposure / XSPM (hourly, 8 streams)

**Active (4)**

| Table | Path |
|---|---|
| `MDE_XspmInitiatives_CL` | `/apiproxy/mtp/posture/oversight/initiatives` (filter=fromDate) |
| `MDE_ExposureSnapshots_CL` | `/apiproxy/mtp/posture/oversight/updates` (filter=fromDate) |
| `MDE_SecureScoreBreakdown_CL` | `/apiproxy/mtp/secureScore/security/secureScoresV2` |
| `MDE_ExposureRecommendations_CL` | `/apiproxy/mtp/posture/oversight/recommendations` |

**Deferred (4)**

| Table | DeferReason |
|---|---|
| `MDE_XspmAttackPaths_CL` | `POST_BODY_UNKNOWN` — XSPM attack-paths POST, filter body needs HAR |
| `MDE_XspmChokePoints_CL` | `POST_BODY_UNKNOWN` |
| `MDE_XspmTopTargets_CL` | `POST_BODY_UNKNOWN` |
| `MDE_SecurityBaselines_CL` | `FEATURE_NOT_ENABLED` — TVM baselines require Defender Vulnerability Management add-on |

## P5 — Identity / MDI (daily, 5 streams)

**Active (1)**

| Table | Path |
|---|---|
| `MDE_IdentityOnboarding_CL` | `/apiproxy/mtp/siamApi/domaincontrollers/list` |

**Deferred (4)**

| Table | DeferReason |
|---|---|
| `MDE_IdentityServiceAccounts_CL` | `POST_BODY_UNKNOWN` — 415 live, POST body + Content-Type needed |
| `MDE_DCCoverage_CL` | `FEATURE_NOT_ENABLED` — MDI sensor deployment required |
| `MDE_IdentityAlertThresholds_CL` | `FEATURE_NOT_ENABLED` — MDI deployment required |
| `MDE_RemediationAccounts_CL` | `FEATURE_NOT_ENABLED` — MDI deployment required |

## P6 — Audit / AIR (10-min, 2 streams, all ACTIVE)

| Table | Path |
|---|---|
| `MDE_ActionCenter_CL` | `/apiproxy/mtp/actionCenter/actioncenterui/history-actions` (filter=fromDate) |
| `MDE_ThreatAnalytics_CL` | `/apiproxy/mtp/threatAnalytics/outbreaks` (filter=fromDate) |

## P7 — Metadata (daily, 4 streams)

**Active (1)**

| Table | Path |
|---|---|
| `MDE_UserPreferences_CL` | `/apiproxy/mtp/userPreferences/api/mgmt/userpreferencesservice/userPreference` |

**Deferred (3)**

| Table | DeferReason |
|---|---|
| `MDE_MtoTenants_CL` | `FEATURE_NOT_ENABLED` — MTO tenant picker not applicable to single-tenant |
| `MDE_LicenseReport_CL` | `FEATURE_NOT_ENABLED` — Defender for Business / EDR for Business SKU |
| `MDE_CloudAppsConfig_CL` | `NEEDS_HIGHER_PRIV` — MCAS licence + MCAS Administrator role |

## Operational streams (system)

Two non-telemetry streams the Function App emits itself:

| Table | Emitted by | Cadence | Schema |
|---|---|---|---|
| `MDE_Heartbeat_CL` | every timer function | each invocation | 9 cols: TimeGenerated, FunctionName, Tier, StreamsAttempted, StreamsSucceeded, RowsIngested, LatencyMs, HostName, Notes |
| `MDE_AuthTestResult_CL` | `validate-auth-selftest` | every 10 min then 1 h | 12 cols: TimeGenerated, Method, PortalHost, Upn, Success, Stage, FailureReason, EstsMs, SccauthMs, SampleCallHttpCode, SampleCallLatencyMs, SccauthAcquiredUtc |

## Removed in v1.0.2 (5 streams)

These appeared in v1.0.1 but had no public portal API per any research source
(nodoc, XDRInternals, DefenderHarvester); the corresponding features (ASR rules,
Anti-Ransomware, CFA, NetworkProtection, Approval Assignments) are only
accessible via Intune / Graph `deviceManagement` APIs — out of scope for this
connector. They were removed at the manifest, DCR, custom-tables, parser, and
analytic-rule layers:

- `MDE_AsrRulesConfig_CL`
- `MDE_AntiRansomwareConfig_CL`
- `MDE_ControlledFolderAccess_CL`
- `MDE_NetworkProtectionConfig_CL`
- `MDE_ApprovalAssignments_CL`

## Live fixture coverage

Every ACTIVE stream has a `<Stream>-raw.json` + `<Stream>-ingest.json` fixture
under `tests/fixtures/live-responses/` captured via
`tools/Capture-EndpointSchemas.ps1`. These fixtures drive the offline tests in
`tests/unit/FA.ParsingPipeline.Tests.ps1`, `DCR.SchemaConsistency.Tests.ps1`,
and the `tests/kql/*` content-verification suite.

## References

See [REFERENCES.md](REFERENCES.md) for nodoc / XDRInternals / DefenderHarvester
line-number citations and the full 2026-04-23 live-audit result set.
