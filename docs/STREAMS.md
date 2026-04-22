# Streams catalogue

All 52 portal-only streams ingested by XdrLogRaider, grouped by cadence tier.

## P0 — Security configuration (hourly, 19 streams)

| Table | Endpoint | Description |
|---|---|---|
| `MDE_AdvancedFeatures_CL` | `/api/settings/GetAdvancedFeaturesSetting` | Tenant advanced-feature flags matrix |
| `MDE_PreviewFeatures_CL` | `/api/settings/previewFeatures` | Opt-in preview feature state |
| `MDE_AuthenticatedTelemetry_CL` | `/api/settings/authenticatedTelemetry` | Signed-telemetry enforcement state |
| `MDE_PUAConfig_CL` | `/api/settings/puaProtection` | PUA protection tenant policy |
| `MDE_AsrRulesConfig_CL` | `/api/endpoints/asr/rules` | Per-rule ASR mode (Block/Audit/Off) |
| `MDE_AntivirusPolicy_CL` | `/api/settings/antivirus/policy` | AV scan schedule + exclusions |
| `MDE_AntiRansomwareConfig_CL` | `/api/settings/antiRansomware` | Anti-ransomware posture |
| `MDE_ControlledFolderAccess_CL` | `/api/settings/controlledFolderAccess` | CFA protected folders + allowed apps |
| `MDE_NetworkProtectionConfig_CL` | `/api/settings/networkProtection` | NP mode + per-category exceptions |
| `MDE_DeviceControlPolicy_CL` | `/api/settings/deviceControl/policy` | Device-control rules (USB etc.) |
| `MDE_WebContentFiltering_CL` | `/api/settings/webContentFiltering/policies` | Web filtering rules |
| `MDE_SmartScreenConfig_CL` | `/api/settings/smartScreen` | SmartScreen tenant mode |
| `MDE_TenantAllowBlock_CL` | `/api/allowBlockList/entries` | URL/IP/hash/sender allow+block |
| `MDE_CustomCollection_CL` | `/api/settings/customCollectionRules` | Portal custom collection rules |
| `MDE_LiveResponseConfig_CL` | `/api/settings/liveResponse` | LR policy (unsigned scripts, timeouts) |
| `MDE_AlertServiceConfig_CL` | `/api/ine/alertsapiservice/workloads/disabled` | Alert service infrastructure |
| `MDE_AlertTuning_CL` | `/api/alertTuningRules` | Alert tuning rules |
| `MDE_SuppressionRules_CL` | `/api/ine/suppressionrulesservice/suppressionRules` | Suppression rule bodies |
| `MDE_CustomDetections_CL` | `/api/ine/huntingservice/rules` | Custom detection KQL + schedule |

## P1 — Integration + pipeline state (every 30 min, 7 streams)

| Table | Endpoint |
|---|---|
| `MDE_DataExportSettings_CL` | `/api/dataexportsettings` |
| `MDE_StreamingApiConfig_CL` | `/api/settings/streamingApi` |
| `MDE_IntuneConnection_CL` | `/api/settings/integrations/intune` |
| `MDE_PurviewSharing_CL` | `/api/settings/integrations/purview` |
| `MDE_ConnectedApps_CL` | `/api/cloud/portal/apps/all` |
| `MDE_TenantContext_CL` | `/api/tenant/context` |
| `MDE_TenantWorkloadStatus_CL` | `/api/tenant/workloadStatus` |

## P2 — Governance + RBAC (daily, 7 streams)

| Table | Endpoint |
|---|---|
| `MDE_RbacDeviceGroups_CL` | `/rbac/machine_groups` |
| `MDE_UnifiedRbacRoles_CL` | `/api/rbac/unified/roles` |
| `MDE_DeviceCriticality_CL` | `/api/assetManagement/devices/criticality` |
| `MDE_CriticalAssets_CL` | `/api/criticalAssets/classifications` |
| `MDE_AssetRules_CL` | `/api/assetManagement/rules` |
| `MDE_SAClassification_CL` | `/api/identities/serviceAccountClassifications` |
| `MDE_ApprovalAssignments_CL` | `/api/autoir/approvers` |

## P3 — Exposure / XSPM (hourly, 8 streams)

| Table | Endpoint |
|---|---|
| `MDE_XspmAttackPaths_CL` | `/api/xspm/attackPaths` |
| `MDE_XspmChokePoints_CL` | `/api/xspm/chokePoints` |
| `MDE_XspmTopTargets_CL` | `/api/xspm/topTargets` |
| `MDE_XspmInitiatives_CL` | `/api/xspm/initiatives` |
| `MDE_ExposureSnapshots_CL` | `/api/xspm/exposureSnapshots` |
| `MDE_SecureScoreBreakdown_CL` | `/api/secureScore/breakdown` |
| `MDE_SecurityBaselines_CL` | `/api/settings/securityBaselines` |
| `MDE_ExposureRecommendations_CL` | `/api/exposure/recommendations` |

## P5 — Identity / MDI (daily, 5 streams)

| Table | Endpoint |
|---|---|
| `MDE_IdentityServiceAccounts_CL` | `/api/identities/serviceAccounts` |
| `MDE_IdentityOnboarding_CL` | `/api/identities/onboardingStatus` |
| `MDE_DCCoverage_CL` | `/api/identities/domainControllerCoverage` |
| `MDE_IdentityAlertThresholds_CL` | `/api/identities/alertThresholds` |
| `MDE_RemediationAccounts_CL` | `/api/identities/remediationActionAccounts` |

## P6 — Audit + threat intel (every 10 min, 2 streams)

| Table | Endpoint |
|---|---|
| `MDE_ActionCenter_CL` | `/api/autoir/actioncenterui/history-actions` |
| `MDE_ThreatAnalytics_CL` | `/api/threatAnalytics/outbreaks` |

## P7 — Tenant metadata + licensing (daily, 4 streams)

| Table | Endpoint |
|---|---|
| `MDE_LicenseReport_CL` | `/api/licensing/report` |
| `MDE_UserPreferences_CL` | `/api/userPreferences` |
| `MDE_MtoTenants_CL` | `/api/mto/tenants` |
| `MDE_CloudAppsConfig_CL` | `/api/cloudApps/generalSettings` |

## Operational tables

| Table | Description |
|---|---|
| `MDE_Heartbeat_CL` | Per-timer-function invocation heartbeat (streams attempted, succeeded, rows ingested, latency) |
| `MDE_AuthTestResult_CL` | `validate-auth-selftest` timer results (per-stage timing, success/failure, failure reason) |

## Adding a new stream

See [CONTRIBUTING.md#adding-a-new-telemetry-stream](../CONTRIBUTING.md#adding-a-new-telemetry-stream).
