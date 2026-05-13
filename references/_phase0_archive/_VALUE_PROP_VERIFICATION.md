# XdrLogRaider v2 — Value-prop verification

Generated: 2026-05-12 20:48:56 UTC

**Purpose:** prove the v2 nodoc catalogue covers every value-prop claimed in _PHASE_0_CONSOLIDATED.md, every v1 production stream, and the user-mandated critical paths.

## Section A — Critical user-mandated paths

| Capability | Nodoc path | Status | Sub-area/Slug | ReadSem |
|---|---|---|---|---|
| Device timeline (events) | `/mtp/mdeTimelineExperience/machines/{MachineId}/events` | PRESENT | endpoint_devices/GetMachineTimelineEvents | read |
| Device timeline (cache warm) | `/mtp/mdeTimelineExperience/machines/{MachineId}/prefetch` | PRESENT | endpoint_devices/PrefetchMachineTimeline | read |
| IP timeline | `/mtp/mdeTimelineExperience/ips/{IpAddress}/events` | PRESENT | endpoint_devices/GetIpTimelineEvents | read |
| ASR rule state (security policies) | `/mtp/unifiedExperience/mde/configurationManagement/mem/securityPolicies` | PRESENT | endpoint_configuration/ListSecurityPolicies | read |
| ASR policy filters | `/mtp/unifiedExperience/mde/configurationManagement/mem/securityPolicies/filters` | PRESENT | endpoint_configuration/GetSecurityPolicyFilters | read |
| Device policies | `/mtp/unifiedExperience/mde/configurationManagement/mem/device/{MachineId}/policies` | PRESENT | endpoint_configuration/ListDevicePolicies | read |
| Advanced Features (24 toggles) | `/mtp/settings/GetAdvancedFeaturesSetting` | PRESENT | endpoint_configuration/GetAdvancedFeaturesGet | read |
| Custom Collection rules | `/mtp/customDataCollection/rules` | PRESENT | endpoint_configuration/ListCustomCollectionRules | read |
| MDIoT magellan features | `/mtp/mdiotSettingsService/settings/v2/MagellanFeatures` | PRESENT | endpoint_configuration/GetMagellanFeatures | read |
| MDIoT discovery tags | `/mtp/mdiotSettingsService/settings/DiscoveryEnabledTags` | PRESENT | endpoint_configuration/GetDiscoveryEnabledTags | read |
| Suppression rules | `/mtp/suppressionRulesService/suppressionRules` | PRESENT | configuration/ListSuppressionRules | read |
| Suppression rules builtin hash | `/mtp/suppressionRulesService/suppressionRules/builtInRulesHash` | PRESENT | configuration/GetBuiltInSuppressionRulesHash | read |
| XSPM asset rules | `/mtp/xspmatlas/assetrules` | PRESENT | configuration/ListCriticalAssetClassifications | read |
| XSPM atlas asset rule schema | `/mtp/xspmatlas/assetrules/querybuilder/schema` | PRESENT | configuration/GetCriticalAssetClassificationSchema | read |
| Web Content Filtering policies | `/mtp/responseApiPortal/webcategory/policies` | PRESENT | configuration/ListWebCategoryPolicies | read |
| Critical asset classification | `/mtp/radius/api/radius/serviceaccounts/classificationrule/getall` | MISSING | - | - |
| NDR rules engine | `/mtp/ndr/rulesengine/rules` | PRESENT | configuration/GetAssetRules | read |

**Critical-path coverage: 16/17 PRESENT · 1 MISSING**

## Section B — v1 → v2 cross-reference

**v1 production manifest:** 72 MDE_* streams (xdrlograider/src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1)
**v2 nodoc catalogue:** 509 Defender endpoints across 18 sub-areas
**v1 streams mapped to v2:** 67 / 72 (93.1%)
**v1 streams unmapped:** 5 — investigate per row below

### B.1 — v1 streams covered in v2 catalogue

| v1 Stream | v1 Tier | v1 Category | v2 Sub-area/Slug | ReadSem |
|---|---|---|---|---|
| MDE_ActionCenter_CL | ActionCenter | Action Center | action_center/GetHistory | read |
| MDE_AdvancedFeatures_CL | Inventory | Endpoint Configuration | endpoint_configuration/GetAdvancedFeaturesGet | read |
| MDE_AlertServiceConfig_CL | Configuration | Configuration and Settings | configuration/GetDisabledAlertServices | read |
| MDE_AlertTuning_CL | Configuration | Configuration and Settings | endpoint_configuration/ListAlertEmailNotifications | read |
| MDE_AntivirusPolicy_CL | Inventory | Endpoint Configuration | endpoint_configuration/GetSecurityPolicyFilters | read |
| MDE_AppsSecureScore_CL | XspmGraph | Exposure Management (XSPM) | exposure_management/GetAppsSecureScoreMetric | read |
| MDE_AssetClassificationSchema_CL | XspmGraph | Configuration and Settings | configuration/GetCriticalAssetClassificationSchema | read |
| MDE_AssetRules_CL | XspmGraph | Exposure Management (XSPM) | configuration/ListCriticalAssetClassifications | read |
| MDE_AttackSurfaceAttackPaths_CL | XspmGraph | Exposure Management (XSPM) | exposure_management/ListAttackSurfaceAttackPaths | read |
| MDE_AttackSurfaceChokepoints_CL | XspmGraph | Exposure Management (XSPM) | exposure_management/ListAttackSurfaceChokepoints | read |
| MDE_AuthenticatedTelemetry_CL | Inventory | Endpoint Configuration | configuration/GetAllowNonAuthSense | read |
| MDE_CloudAppsConfig_CL | Configuration | Configuration and Settings | cloud_apps/GetSettings | read |
| MDE_ConnectedApps_CL | Configuration | Configuration and Settings | configuration/ListConnectedApps | read |
| MDE_DataExportSettings_CL | Maintenance | Streaming API | configuration/GetDataExportSettings | read |
| MDE_DataSecureScore_CL | XspmGraph | Exposure Management (XSPM) | exposure_management/GetDataSecureScoreMetric | read |
| MDE_DCCoverage_CL | Inventory | Identity Protection (MDI) | identity/GetDomainControllerCoverageAatp | read |
| MDE_DeviceControlPolicy_CL | Inventory | Endpoint Configuration | identity/GetOnboardingSummary | read |
| MDE_DeviceTimeline_CL | ActionCenter | Endpoint Device Management | endpoint_devices/GetMachineTimelineEvents | read |
| MDE_ExposureRecommendations_CL | XspmGraph | Exposure Management (XSPM) | exposure_management/ListPostureOversightRecommendations | read |
| MDE_ExposureSnapshots_CL | XspmGraph | Exposure Management (XSPM) | exposure_management/ListPostureOversightUpdates | read |
| MDE_IdentityAlertThresholds_CL | Inventory | Identity Protection (MDI) | identity/GetAlertThresholdsWithExpiry | read |
| MDE_IdentityDormantAccounts_CL | Configuration | Identity Protection (MDI) | identity/GetDormantEntitiesNewEntryCount | read |
| MDE_IdentityLateralMovementPaths_CL | XspmGraph | Identity Protection (MDI) | identity/GetRiskyLateralMovementPathNewEntryCount | read |
| MDE_IdentityOnboarding_CL | Inventory | Identity Protection (MDI) | identity/ListDomainControllers | read |
| MDE_IdentitySecureScore_CL | XspmGraph | Exposure Management (XSPM) | exposure_management/GetIdentitySecureScoreMetric | read |
| MDE_IdentityServiceAccounts_CL | Inventory | Identity Protection (MDI) | identity/ListServiceAccountsV2 | read |
| MDE_IntuneConnection_CL | Configuration | Configuration and Settings | configuration/GetIntuneOnboardingStatus | read |
| MDE_Machines_CL | Inventory | Endpoint Device Management | endpoint_devices/List | read |
| MDE_MtoTenants_CL | Inventory | Multi-Tenant Operations | multi_tenant/ListTenants | read |
| MDE_PendingActions_CL | ActionCenter | Action Center | action_center/GetPending | read |
| MDE_PostureInitiativesSummarized_CL | XspmGraph | Exposure Management (XSPM) | exposure_management/GetPostureOversightInitiativesSummarized | read |
| MDE_PostureMetrics_CL | XspmGraph | Exposure Management (XSPM) | exposure_management/ListPostureOversightMetrics | read |
| MDE_PostureSecurityEvents_CL | XspmGraph | Exposure Management (XSPM) | exposure_management/ListPostureSecurityEvents | read |
| MDE_PostureTenants_CL | XspmGraph | Exposure Management (XSPM) | exposure_management/GetPostureOversightTenants | read |
| MDE_PreviewFeatures_CL | Configuration | Configuration and Settings | endpoint_configuration/GetPreviewFeatures | read |
| MDE_PurviewSharing_CL | Configuration | Configuration and Settings | configuration/GetAlertSharingStatus | read |
| MDE_RbacDeviceGroups_CL | Configuration | Configuration and Settings | endpoint_devices/GetMachineGroups | read |
| MDE_RecommendationActions_CL | Inventory | Vulnerability Management (TVM) | vulnerability_management/ListRemediationTasks | read |
| MDE_RemediationAccounts_CL | Inventory | Identity Protection (MDI) | identity/GetRemediationActionsConfig | read |
| MDE_SAClassification_CL | Inventory | Identity Protection (MDI) | configuration/GetServiceAccountClassifications | read |
| MDE_SecurityBaselines_CL | Inventory | Vulnerability Management (TVM) | vulnerability_management/GetBaseline | read |
| MDE_SecurityPolicies_CL | Inventory | Endpoint Configuration | endpoint_configuration/ListSecurityPolicies | read |
| MDE_SmartScreenConfig_CL | Inventory | Endpoint Configuration | configuration/GetWebThreatSummary | read |
| MDE_SoftwareInventory_CL | Inventory | Vulnerability Management (TVM) | vulnerability_management/ListProducts | read |
| MDE_StreamingApiConfig_CL | Maintenance | Streaming API | streaming/GetConfiguration | read |
| MDE_SuppressionRules_CL | Configuration | Configuration and Settings | configuration/ListSuppressionRules | read |
| MDE_TenantAllowBlock_CL | Configuration | Configuration and Settings | configuration/ListThreatIndicators | read |
| MDE_TenantContext_CL | Inventory | Multi-Tenant Operations | configuration/GetTenantContext | read |
| MDE_TenantWorkloadStatus_CL | Inventory | Multi-Tenant Operations | multi_tenant/ListTenantGroups | read |
| MDE_ThreatAnalytics_CL | Configuration | Threat Analytics | threat_analytics/ListPortalOutbreaks | read |
| MDE_ThreatAnalyticsEnriched_CL | Configuration | Threat Analytics | threat_analytics/GetEnrichedOutbreakData | read |
| MDE_ThreatAnalyticsTopThreats_CL | Configuration | Threat Analytics | threat_analytics/GetTopThreats | read |
| MDE_UnifiedRbacRoles_CL | Configuration | Configuration and Settings | configuration/ListUnifiedRbacRoleDefinitions | read |
| MDE_UserPreferences_CL | Configuration | Configuration and Settings | portal_services/GetUserPreferences | read |
| MDE_VulnerabilityAdvisories_CL | Inventory | Vulnerability Management (TVM) | vulnerability_management/ListAdvisories | read |
| MDE_VulnerabilityAssetCountByExposure_CL | Inventory | Vulnerability Management (TVM) | vulnerability_management/GetAssetCountByExposureLevel | read |
| MDE_VulnerabilityCertificates_CL | Inventory | Vulnerability Management (TVM) | vulnerability_management/ListCertificates | read |
| MDE_VulnerabilityExtensions_CL | Inventory | Vulnerability Management (TVM) | vulnerability_management/ListExtensions | read |
| MDE_VulnerabilityInventory_CL | Inventory | Vulnerability Management (TVM) | vulnerability_management/ListVulnerabilities | read |
| MDE_VulnerabilitySummary_CL | Inventory | Vulnerability Management (TVM) | vulnerability_management/GetSummary | read |
| MDE_VulnerableMachines_CL | Inventory | Vulnerability Management (TVM) | vulnerability_management/ListTopVulnerableAssets | read |
| MDE_WebContentFiltering_CL | Inventory | Endpoint Configuration | configuration/GetTopWebContentFilteringCategories | read |
| MDE_XspmAttackPaths_CL | XspmGraph | Exposure Management (XSPM) | exposure_management/QueryAttackSurface | read |
| MDE_XspmChokePoints_CL | XspmGraph | Exposure Management (XSPM) | exposure_management/QueryAttackSurface | read |
| MDE_XspmConnectors_CL | XspmGraph | Exposure Management (XSPM) | exposure_management/ListXspmConnectors | read |
| MDE_XspmInitiatives_CL | XspmGraph | Exposure Management (XSPM) | exposure_management/ListPostureOversightInitiatives | read |
| MDE_XspmTopTargets_CL | XspmGraph | Exposure Management (XSPM) | exposure_management/QueryAttackSurface | read |

### B.2 — v1 streams UNMAPPED in v2 (gap or path drift)

| v1 Stream | v1 Path | Normalized | v1 Tier | v1 Category |
|---|---|---|---|---|
| MDE_CustomCollection_CL | `/apiproxy/mtp/mdeCustomCollection/rules` | `/mtp/mdeCustomCollection/rules` | Inventory | Endpoint Configuration |
| MDE_CustomDetections_CL | `/apiproxy/mtp/huntingService/rules/unified?sortOrder=Ascending&isUnifiedRulesListEnabled=true` | `/mtp/huntingService/rules/unified` | Configuration | Configuration and Settings |
| MDE_LicenseReport_CL | `/apiproxy/mtp/k8sMachineApi/ine/machineapiservice/machines/skuReport` | `/mtp/k8sMachineApi/ine/machineapiservice/machines/skuReport` | Inventory | Endpoint Device Management |
| MDE_LiveResponseConfig_CL | `/apiproxy/mtp/liveResponseApi/get_properties?useV2Api=true&useV3Api=true` | `/mtp/liveResponseApi/get_properties` | Inventory | Endpoint Configuration |
| MDE_PUAConfig_CL | `/apiproxy/mtp/autoIr/ui/properties/` | `/mtp/autoIr/ui/properties/` | Inventory | Endpoint Configuration |

## Section C — Net-new v2 endpoints (v2 catalogue endpoints with no v1 production equivalent)

**Net-new count:** 426 read-semantics endpoints (v2 catalogue captures these but v1 connector did NOT ingest them)

These represent NEW VALUE Phase 1 can deliver beyond v1. Top 50 by sub-area:

| Sub-area | Slug | OperationId |
|---|---|---|
| action_center | ExportHistory | `ActionCenter.ExportHistory` |
| action_center | GetCase | `ActionCenter.GetCase` |
| action_center | GetHistoryFilters | `ActionCenter.GetHistoryFilters` |
| action_center | GetPendingFilters | `ActionCenter.GetPendingFilters` |
| action_center | GetPendingSummary | `ActionCenter.GetPendingSummary` |
| action_center | GetTileSummary | `ActionCenter.GetTileSummary` |
| action_center | ListAutomationRules | `ActionCenter.ListAutomationRules` |
| action_center | ListCaseActivities | `ActionCenter.ListCaseActivities` |
| action_center | ListCaseAttachments | `ActionCenter.ListCaseAttachments` |
| attack_simulator | GetCampaignSettings | `AttackSimulator.GetCampaignSettings` |
| attack_simulator | GetRecommendations | `AttackSimulator.GetRecommendations` |
| attack_simulator | GetRepeatOffenderChartNRT | `AttackSimulator.GetRepeatOffenderChartNRT` |
| attack_simulator | GetTrainingCompletionChartNRT | `AttackSimulator.GetTrainingCompletionChartNRT` |
| attack_simulator | GetTrainingEfficacyChart | `AttackSimulator.GetTrainingEfficacyChart` |
| attack_simulator | GetUserProfileType | `AttackSimulator.GetUserProfileType` |
| attack_simulator | ListGlobalPayloads | `AttackSimulator.ListGlobalPayloads` |
| attack_simulator | ListSimulationAutomations | `AttackSimulator.ListSimulationAutomations` |
| attack_simulator | ListSimulations | `AttackSimulator.ListSimulations` |
| attack_simulator | ListTrainingCampaignsV2 | `AttackSimulator.ListTrainingCampaignsV2` |
| cloud_apps | AutocompleteAppPermissionNames | `CloudApps.AutocompleteAppPermissionNames` |
| cloud_apps | AutocompleteAppPermissionPermissions | `CloudApps.AutocompleteAppPermissionPermissions` |
| cloud_apps | AutocompleteDiscoveryAppTags | `CloudApps.AutocompleteDiscoveryAppTags` |
| cloud_apps | AutocompleteEntities | `CloudApps.AutocompleteEntities` |
| cloud_apps | AutocompleteScopedProfiles | `CloudApps.AutocompleteScopedProfiles` |
| cloud_apps | AutocompleteTags | `CloudApps.AutocompleteTags` |
| cloud_apps | AutocompleteTokens | `CloudApps.AutocompleteTokens` |
| cloud_apps | AutocompleteUsers | `CloudApps.AutocompleteUsers` |
| cloud_apps | CountSiemAgents | `CloudApps.CountSiemAgents` |
| cloud_apps | GetAboutInfo | `CloudApps.GetAboutInfo` |
| cloud_apps | GetAboutServerUrl | `CloudApps.GetAboutServerUrl` |
| cloud_apps | GetActivitiesCount | `CloudApps.GetActivitiesCount` |
| cloud_apps | GetActivitiesMetadata | `CloudApps.GetActivitiesMetadata` |
| cloud_apps | GetActivitiesThreatScores | `CloudApps.GetActivitiesThreatScores` |
| cloud_apps | GetActivityLocationsByUser | `CloudApps.GetActivityLocationsByUser` |
| cloud_apps | GetAppConnectorInstanceCountByApp | `CloudApps.GetAppConnectorInstanceCountByApp` |
| cloud_apps | GetAppConnectorsCount | `CloudApps.GetAppConnectorsCount` |
| cloud_apps | GetAppConnectorsLastActivity | `CloudApps.GetAppConnectorsLastActivity` |
| cloud_apps | GetAppConnectorsMetadata | `CloudApps.GetAppConnectorsMetadata` |
| cloud_apps | GetAppConnectorsTableConfigValues | `CloudApps.GetAppConnectorsTableConfigValues` |
| cloud_apps | GetAppPermissionsCount | `CloudApps.GetAppPermissionsCount` |
| cloud_apps | GetAppPermissionsMetadata | `CloudApps.GetAppPermissionsMetadata` |
| cloud_apps | GetAppsCountByStatus | `CloudApps.GetAppsCountByStatus` |
| cloud_apps | GetBootConstants | `CloudApps.GetBootConstants` |
| cloud_apps | GetCloudAppsFileCount | `Files.GetCloudAppsFileCount` |
| cloud_apps | GetComplianceAppMetadata | `AppGovernance.GetComplianceAppMetadata` |
| cloud_apps | GetDataEncryptionSettings | `CloudApps.GetDataEncryptionSettings` |
| cloud_apps | GetDiscoveredAppsCount | `CloudApps.GetDiscoveredAppsCount` |
| cloud_apps | GetDiscoveredAppsMetadata | `CloudApps.GetDiscoveredAppsMetadata` |
| cloud_apps | GetDiscoveryAppCatalogCount | `CloudApps.GetDiscoveryAppCatalogCount` |
| cloud_apps | GetDiscoveryAppCatalogMetadata | `CloudApps.GetDiscoveryAppCatalogMetadata` |

_(See _FULL_CATALOGUE.md for the complete listing.)_

**Net-new endpoints by sub-area:**

| Sub-area | Net-new |
|---|---:|
| action_center | 9 |
| attack_simulator | 10 |
| cloud_apps | 89 |
| configuration | 35 |
| data_lake | 7 |
| endpoint_configuration | 12 |
| endpoint_devices | 39 |
| entity_pivots | 19 |
| exposure_management | 27 |
| files | 18 |
| identity | 66 |
| multi_tenant | 14 |
| portal_services | 19 |
| secure_score | 8 |
| sentinel_precision | 16 |
| threat_analytics | 16 |
| vulnerability_management | 22 |

## Section D — Research-source coverage

v1 manifest header documents cross-checks with 3 research sources:
- **XDRInternals** (github.com/MSCloudInternals/XDRInternals) — 150 paths, working PowerShell client. Authoritative for POST body schemas.
- **nodoc** (github.com/nathanmcnulty/nodoc) — 576 operations (Defender XDR subset). Vendored at xdrlograider/.internal/nodoc-reference/. **Authoritative path + method catalogue.**
- **DefenderHarvester** (github.com/olafhartong/DefenderHarvester) — 12 classic MDE endpoints. HARDENED by Microsoft July 2024; historical reference only.

v2 catalogue inherits nodoc as primary source. Where postman collections exist (20 portals), they provide working POST body examples — see Build-FullCatalogue.ps1 cross-references.

## Section E — Phase 1 readiness assertions

- [ ] All user-mandated critical paths present in v2 catalogue
- [ ] All v1 production streams have v2 catalogue equivalents (no path drift)
- [x] No advanced_hunting / alerts_incidents / live_response endpoints in catalogue (wholesale exclusion holds)
- [x] No 'unknown' ReadSemantics endpoints (all classified)
- [x] v2 catalogue covers more value than v1 (426 net-new read endpoints)
- [x] Read-only connector confirmed: 17 write-shaped endpoints excluded from Phase 1 manifest (see _READ_SEMANTICS_AUDIT.md)
