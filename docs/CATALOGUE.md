<!--
  GENERATED FILE -- do not hand-edit.
  Regenerate:  pwsh dev-tools/Export-CatalogueDoc.ps1
  Drift gate:  pwsh dev-tools/Export-CatalogueDoc.ps1 -Check   (exit 1 if stale)
  Sources: manifests/Defender/*.psd1 (deployed set) enriched by
           references/inventory/nodoc-defender-xdr/catalogue.json (value class, held reasons).
-->

# XdrLogRaider -- Operation Catalogue

This is the canonical, machine-generated inventory of every operation XdrLogRaider ships, plus a summary of the catalogued surface it deliberately holds back. Every number below is derived from the manifests and the catalogue at generation time -- nothing is hand-maintained.

XdrLogRaider is an authorized purple-team / detection-engineering data connector: it turns the Microsoft Defender XDR portal-internal (`/apiproxy/*`) surfaces -- the audit, reporting, configuration, and posture endpoints that have no public REST API -- into read-only Sentinel telemetry. The ship-set is *curated* telemetry, not a raw endpoint dump; the held surface below is the honest other half of that curation.

## At a glance

| Metric | Value | Derived from |
|---|---:|---|
| Portal | Defender | manifests |
| Shipped operations | 123 | manifest ops (== catalogue `Shipped == true`) |
| Shipped categories | 11 | distinct manifest category (== count of `.psd1` files) |
| Shipped Sentinel tables | 11 | one `Defender_<Category>_CL` per category |
| Shipped streams (subcategories) | 16 | distinct manifest subcategory |
| Ingestion modes | CURSOR x2, SNAPSHOT x120, WINDOW x1 | manifest `IngestionMode` |
| Cadence tiers | 10-min (T1) x3, Hourly (T2) x41, 6-hourly (T3) x69, Daily (T4) x10 | manifest `Cadence` |
| Value classes | ConfigState x48, CoreTelemetry x75 | catalogue `EffectiveValueClass` |
| Sub-portals touched | aatp x9, astgws x5, m365appprotection x4, mcas x7, mdc x1, mdi x6, mtoapi x4, mtp x87 | manifest `SubPortal` |
| Catalogued but held | 476 | catalogue `Shipped == false` |
| Catalogued total | 599 | catalogue `Operations` |

**Cadence tiers** map the distinct poll intervals: `10-min (T1)` `Hourly (T2)` `6-hourly (T3)` `Daily (T4)`.

**Value classes** -- what a stream *is*: **CoreTelemetry** = per-entity security event/state (the reason to deploy); **ConfigState** = configuration / policy / posture snapshots. Held-only classes never ship: **UiHelper** (portal chrome), **Noise** (pick-lists, bare-string catalogs, checksums), **Reference** (id catalogs).

## Categories

All shipped operations land in the Defender portal. Each category maps to exactly one Sentinel custom table. Categories with 0 shipped operations are held in full (see [Held surface](#held-surface)).

| Category | Sentinel table | Streams | Shipped | Held | Ingestion (shipped) | Cadence (shipped) | Value class (shipped) |
|---|---|---:|---:|---:|---|---|---|
| Advanced Hunting | `Defender_AdvancedHunting_CL` | 0 | 0 | 27 | - | - | - |
| Alerts & Incidents | `Defender_AlertsIncidents_CL` | 0 | 0 | 32 | - | - | - |
| Analytics & Data | `Defender_AnalyticsData_CL` | 1 | 3 | 40 | SNAPSHOT x3 | Hourly (T2) x3 | CoreTelemetry x3 |
| Attack Simulation | `Defender_AttackSimulation_CL` | 1 | 4 | 6 | SNAPSHOT x4 | Hourly (T2) x3, 6-hourly (T3) x1 | ConfigState x1, CoreTelemetry x3 |
| Cloud Apps | `Defender_CloudApps_CL` | 2 | 9 | 86 | SNAPSHOT x9 | Hourly (T2) x1, 6-hourly (T3) x8 | ConfigState x8, CoreTelemetry x1 |
| Configuration | `Defender_Configuration_CL` | 1 | 20 | 36 | SNAPSHOT x20 | 6-hourly (T3) x20 | ConfigState x11, CoreTelemetry x9 |
| Endpoint Management | `Defender_EndpointManagement_CL` | 2 | 25 | 57 | SNAPSHOT x24, WINDOW x1 | Hourly (T2) x17, 6-hourly (T3) x8 | ConfigState x8, CoreTelemetry x17 |
| Exposure Management | `Defender_ExposureManagement_CL` | 2 | 16 | 31 | SNAPSHOT x16 | 6-hourly (T3) x16 | ConfigState x2, CoreTelemetry x14 |
| File Investigation | `Defender_FileInvestigation_CL` | 0 | 0 | 38 | - | - | - |
| Identity | `Defender_Identity_CL` | 1 | 18 | 59 | SNAPSHOT x18 | Hourly (T2) x9, 6-hourly (T3) x9 | ConfigState x9, CoreTelemetry x9 |
| Operations | `Defender_Operations_CL` | 3 | 9 | 20 | CURSOR x1, SNAPSHOT x8 | 10-min (T1) x3, 6-hourly (T3) x6 | ConfigState x7, CoreTelemetry x2 |
| Portal Services | `Defender_PortalServices_CL` | 1 | 4 | 18 | SNAPSHOT x4 | Hourly (T2) x4 | CoreTelemetry x4 |
| Secure Score | `Defender_SecureScore_CL` | 1 | 5 | 3 | CURSOR x1, SNAPSHOT x4 | Hourly (T2) x4, 6-hourly (T3) x1 | CoreTelemetry x5 |
| Vulnerability Management | `Defender_VulnerabilityManagement_CL` | 1 | 10 | 23 | SNAPSHOT x10 | Daily (T4) x10 | ConfigState x2, CoreTelemetry x8 |
| **Total** | **11 tables** | **16** | **123** | **476** | CURSOR x2, SNAPSHOT x120, WINDOW x1 | 10-min (T1) x3, Hourly (T2) x41, 6-hourly (T3) x69, Daily (T4) x10 | ConfigState x48, CoreTelemetry x75 |

## Shipped operations

All 123 operations below are read-only and ship in v0.1.0. Each capability-gates at runtime and lights up only on a tenant that licenses the underlying product.

| Portal | Category | Stream | Operation | Sub-portal | Path | Mode | Cadence tier | Value class | Ship state |
|---|---|---|---|---|---|---|---|---|---|
| Defender | Analytics & Data | Threat Analytics | `ThreatAnalytics.GetEnrichedOutbreakData` | mtp | `/threatAnalytics/outbreaks/outbreaksEnrichedDataMtp` | SNAPSHOT | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Analytics & Data | Threat Analytics | `ThreatAnalytics.GetTopThreats` | mtp | `/threatAnalytics/outbreaks/topthreats` | SNAPSHOT | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Analytics & Data | Threat Analytics | `ThreatAnalytics.ListPortalOutbreaks` | mtp | `/threatAnalytics/outbreaks` | SNAPSHOT | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Attack Simulation | AttackSimulator | `AttackSimulator.GetCampaignSettings` | astgws | `/AttackSimulator/api/v1/campaignSettings` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Attack Simulation | AttackSimulator | `AttackSimulator.GetRecommendations` | astgws | `/AttackSimulator/api/v1/Recommendations` | SNAPSHOT | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Attack Simulation | AttackSimulator | `AttackSimulator.ListGlobalPayloads` | astgws | `/AttackSimulator/api/v1/GlobalPayloads` | SNAPSHOT | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Attack Simulation | AttackSimulator | `AttackSimulator.ListSimulations` | astgws | `/AttackSimulator/api/v1/Simulations` | SNAPSHOT | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Cloud Apps | AppGovernance | `AppGovernance.GetPolicy` | m365appprotection | `/mapg-glsservice/compliance/Policy` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Cloud Apps | AppGovernance | `AppGovernance.GetPolicyInsights` | m365appprotection | `/mapg-glsservice/compliance/policyinsights` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Cloud Apps | AppGovernance | `AppGovernance.ListPolicies` | m365appprotection | `/mapg-glsservice/compliance/policies` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Cloud Apps | CloudApps | `CloudApps.GetAppConnectorsLastActivity` | mcas | `/cas/api/v1/app_connectors/last_activity` | SNAPSHOT | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Cloud Apps | CloudApps | `CloudApps.GetDataEncryptionSettings` | mcas | `/cas/api/v1/data_encryption_settings/get` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Cloud Apps | CloudApps | `CloudApps.GetLcncSettings` | mcas | `/cas/api/v1/lcnc_settings` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Cloud Apps | CloudApps | `CloudApps.GetMailSettings` | mcas | `/cas/api/v1/mail_settings/get` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Cloud Apps | CloudApps | `CloudApps.GetSettings` | mcas | `/cas/api/v1/settings` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Cloud Apps | CloudApps | `CloudApps.ListPolicies` | mcas | `/cas/api/v1/policies` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Configuration | Configuration | `Configuration.GetAlertSharingStatus` | mtp | `/wdatpInternalApi/compliance/alertSharing/status` | SNAPSHOT | 6-hourly (T3) | CoreTelemetry | shipped |
| Defender | Configuration | Configuration | `Configuration.GetAssetRules` | mtp | `/ndr/rulesengine/rules` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Configuration | Configuration | `Configuration.GetAutoIrProperties` | mtp | `/autoIr/ui/properties` | SNAPSHOT | 6-hourly (T3) | CoreTelemetry | shipped |
| Defender | Configuration | Configuration | `Configuration.GetDataExportSettings` | mtp | `/wdatpApi/dataexportsettings` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Configuration | Configuration | `Configuration.GetDisabledAlertServices` | mtp | `/alertsApiService/workloads/disabled` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Configuration | Configuration | `Configuration.GetGlobalIdentityDisruptionExclusion` | mtp | `/disrupt/api/exclusions/Identity/global-exclusion` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Configuration | Configuration | `Configuration.GetIntuneOnboardingStatus` | mtp | `/responseApiPortal/onboarding/intune/status` | SNAPSHOT | 6-hourly (T3) | CoreTelemetry | shipped |
| Defender | Configuration | Configuration | `Configuration.GetMcasPreviewFeatures` | mcas | `/cas/api/v1/preview_features/get` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Configuration | Configuration | `Configuration.GetMdcPreviewFeatures` | mdc | `/management/optin` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Configuration | Configuration | `Configuration.GetSentinelOnboardedState` | mtp | `/sentinelOnboarding/sentinel/workspaces/isOnboarded` | SNAPSHOT | 6-hourly (T3) | CoreTelemetry | shipped |
| Defender | Configuration | Configuration | `Configuration.GetTopWebContentFilteringCategories` | mtp | `/webThreatProtection/WebContentFiltering/Reports/TopParentCategories` | SNAPSHOT | 6-hourly (T3) | CoreTelemetry | shipped |
| Defender | Configuration | Configuration | `Configuration.GetUnifiedRbacWorkload` | mtp | `/urbacConfiguration/gw/unifiedrbac/configuration/tenantinfo` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Configuration | Configuration | `Configuration.GetUserSettings` | mtp | `/settings/GetUserSettings` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Configuration | Configuration | `Configuration.ListConnectedApps` | mtp | `/responseApiPortal/apps/all` | SNAPSHOT | 6-hourly (T3) | CoreTelemetry | shipped |
| Defender | Configuration | Configuration | `Configuration.ListCriticalAssetClassifications` | mtp | `/xspmatlas/assetrules` | SNAPSHOT | 6-hourly (T3) | CoreTelemetry | shipped |
| Defender | Configuration | Configuration | `Configuration.ListIncidentNotificationSettings` | mtp | `/papin/api/cloud/public/internal/IncidentNotificationSettingsV2` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Configuration | Configuration | `Configuration.ListSuppressionRules` | mtp | `/suppressionRulesService/suppressionRules` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Configuration | Configuration | `Configuration.ListThreatIndicators` | mtp | `/responseApiPortal/ti/indicators` | SNAPSHOT | 6-hourly (T3) | CoreTelemetry | shipped |
| Defender | Configuration | Configuration | `Configuration.ListUnifiedConnectors` | mtp | `/unifiedConnectors/public/connectors` | SNAPSHOT | 6-hourly (T3) | CoreTelemetry | shipped |
| Defender | Configuration | Configuration | `Configuration.ListWebCategoryPolicies` | mtp | `/responseApiPortal/webcategory/policies` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Endpoint Management | Endpoint Configuration | `EndpointConfiguration.GetAdvancedFeaturesGet` | mtp | `/settings/GetAdvancedFeaturesSetting` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Endpoint Management | Endpoint Configuration | `EndpointConfiguration.GetAuthenticatedTelemetry` | mtp | `/deviceManagement/configuration/AuthenticatedTelemetry` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Endpoint Management | Endpoint Configuration | `EndpointConfiguration.GetDiscoveryEnabledTags` | mtp | `/mdiotSettingsService/settings/DiscoveryEnabledTags` | SNAPSHOT | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Endpoint Management | Endpoint Configuration | `EndpointConfiguration.GetIntuneConnection` | mtp | `/deviceManagement/configuration/IntuneConnection` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Endpoint Management | Endpoint Configuration | `EndpointConfiguration.GetMagellanFeatures` | mtp | `/mdiotSettingsService/settings/v2/MagellanFeatures` | SNAPSHOT | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Endpoint Management | Endpoint Configuration | `EndpointConfiguration.GetPreviewFeatures` | mtp | `/settings/GetPreviewExperienceSetting` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Endpoint Management | Endpoint Configuration | `EndpointConfiguration.GetPuaConfiguration` | mtp | `/deviceManagement/configuration/PotentiallyUnwantedApplications` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Endpoint Management | Endpoint Configuration | `EndpointConfiguration.GetPurviewSharing` | mtp | `/deviceManagement/configuration/PurviewSharing` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Endpoint Management | Endpoint Configuration | `EndpointConfiguration.ListAlertEmailNotifications` | mtp | `/alertsEmailNotifications/email_notifications` | SNAPSHOT | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Endpoint Management | Endpoint Configuration | `EndpointConfiguration.ListCustomCollectionRules` | mtp | `/customDataCollection/rules` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Endpoint Management | Endpoint Configuration | `EndpointConfiguration.ListManagedDevices` | mtp | `/unifiedExperience/mde/configurationManagement/mem/proxy/deviceManagement/managedDevices` | SNAPSHOT | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Endpoint Management | Endpoint Devices | `EndpointDevices.GetDataSensitivity` | mtp | `/getDataSensitivity/machines/{MachineId}/dataSensitivity` | SNAPSHOT | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Endpoint Management | Endpoint Devices | `EndpointDevices.GetLicenseReport` | mtp | `/deviceManagement/deviceLicenseReport` | SNAPSHOT | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Endpoint Management | Endpoint Devices | `EndpointDevices.GetMachineGroups` | mtp | `/rbacManagementApi/rbac/machine_groups` | SNAPSHOT | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Endpoint Management | Endpoint Devices | `EndpointDevices.GetMachinesWdatp` | mtp | `/wdatpApi/machines` | SNAPSHOT | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Endpoint Management | Endpoint Devices | `EndpointDevices.GetMachineTimelineEvents` | mtp | `/mdeTimelineExperience/machines/{MachineId}/events` | WINDOW | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Endpoint Management | Endpoint Devices | `EndpointDevices.GetNdrDeviceTypeDistribution` | mtp | `/ndr/machines/deviceTypeDistribution` | SNAPSHOT | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Endpoint Management | Endpoint Devices | `EndpointDevices.GetNdrInterceptingMachines` | mtp | `/ndr/machines/{MachineId}/InterceptingMachines` | SNAPSHOT | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Endpoint Management | Endpoint Devices | `EndpointDevices.GetNdrMachineExclusionDetails` | mtp | `/ndr/machines/{MachineId}/exclusionDetails` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Endpoint Management | Endpoint Devices | `EndpointDevices.GetRbacGroups` | mtp | `/rbacGroupAssignment/machineRbacGroupAssignments/{DeviceId}` | SNAPSHOT | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Endpoint Management | Endpoint Devices | `EndpointDevices.GetRbacGroupScopes` | mtp | `/rbacGroupAssignment/rbacGroupsScopes/{DeviceId}` | SNAPSHOT | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Endpoint Management | Endpoint Devices | `EndpointDevices.GetSensorCompatibleMachines` | mtp | `/mdi/tri/defensor/onboarding/devices/sensor_compatible_machines` | SNAPSHOT | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Endpoint Management | Endpoint Devices | `EndpointDevices.GetTags` | mtp | `/machineTag/machineTags/{DeviceId}` | SNAPSHOT | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Endpoint Management | Endpoint Devices | `EndpointDevices.GetTimeline` | mtp | `/deviceTimeline/timeline/{DeviceId}` | SNAPSHOT | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Endpoint Management | Endpoint Devices | `EndpointDevices.List` | mtp | `/ndr/machines` | SNAPSHOT | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Exposure Management | Attack Surface Reduction | `Asr.MachineSecurityStates` | mtp | `/tvm/analytics/asrconfiguration/MachineSecurityStates` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Exposure Management | Exposure Management | `ExposureManagement.GetAppsSecureScoreMetric` | mtp | `/posture/oversight/metrics/category_apps_secure_score` | SNAPSHOT | 6-hourly (T3) | CoreTelemetry | shipped |
| Defender | Exposure Management | Exposure Management | `ExposureManagement.GetDataSecureScoreMetric` | mtp | `/posture/oversight/metrics/category_data_secure_score` | SNAPSHOT | 6-hourly (T3) | CoreTelemetry | shipped |
| Defender | Exposure Management | Exposure Management | `ExposureManagement.GetIdentitySecureScoreMetric` | mtp | `/posture/oversight/metrics/category_identity_secure_score` | SNAPSHOT | 6-hourly (T3) | CoreTelemetry | shipped |
| Defender | Exposure Management | Exposure Management | `ExposureManagement.GetPostureOversightInitiative` | mtp | `/posture/oversight/initiatives/{InitiativeId}` | SNAPSHOT | 6-hourly (T3) | CoreTelemetry | shipped |
| Defender | Exposure Management | Exposure Management | `ExposureManagement.GetPostureOversightInitiativesSummarized` | mtp | `/posture/oversight/initiatives/summarized` | SNAPSHOT | 6-hourly (T3) | CoreTelemetry | shipped |
| Defender | Exposure Management | Exposure Management | `ExposureManagement.GetPostureOversightTenants` | mtp | `/posture/oversight/tenants` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Exposure Management | Exposure Management | `ExposureManagement.GetRecommendations` | mtp | `/exposureManagement/recommendations` | SNAPSHOT | 6-hourly (T3) | CoreTelemetry | shipped |
| Defender | Exposure Management | Exposure Management | `ExposureManagement.GetTvmRiskScore` | mtp | `/tvm/analytics/riskscore` | SNAPSHOT | 6-hourly (T3) | CoreTelemetry | shipped |
| Defender | Exposure Management | Exposure Management | `ExposureManagement.ListAttackSurfaceAttackPaths` | mtp | `/xspmatlas/attacksurface/attackpaths` | SNAPSHOT | 6-hourly (T3) | CoreTelemetry | shipped |
| Defender | Exposure Management | Exposure Management | `ExposureManagement.ListAttackSurfaceChokepoints` | mtp | `/xspmatlas/attacksurface/chokepoints/list` | SNAPSHOT | 6-hourly (T3) | CoreTelemetry | shipped |
| Defender | Exposure Management | Exposure Management | `ExposureManagement.ListPostureOversightInitiatives` | mtp | `/posture/oversight/initiatives` | SNAPSHOT | 6-hourly (T3) | CoreTelemetry | shipped |
| Defender | Exposure Management | Exposure Management | `ExposureManagement.ListPostureOversightMetrics` | mtp | `/posture/oversight/metrics` | SNAPSHOT | 6-hourly (T3) | CoreTelemetry | shipped |
| Defender | Exposure Management | Exposure Management | `ExposureManagement.ListPostureOversightRecommendations` | mtp | `/posture/oversight/recommendations` | SNAPSHOT | 6-hourly (T3) | CoreTelemetry | shipped |
| Defender | Exposure Management | Exposure Management | `ExposureManagement.ListPostureOversightUpdates` | mtp | `/posture/oversight/updates` | SNAPSHOT | 6-hourly (T3) | CoreTelemetry | shipped |
| Defender | Exposure Management | Exposure Management | `ExposureManagement.ListPostureSecurityEvents` | mtp | `/posture/oversight/securityEvents` | SNAPSHOT | 6-hourly (T3) | CoreTelemetry | shipped |
| Defender | Identity | Identity | `Identity.GetAlertThreshold` | mdi | `/identity/userapiservice/alertThreshold` | SNAPSHOT | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Identity | Identity | `Identity.GetAlertThresholdsRecommendedTestMode` | aatp | `/api/alertthresholds/withExpiry/recommendedTestMode` | SNAPSHOT | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Identity | Identity | `Identity.GetAlertThresholdsWithExpiry` | aatp | `/api/alertthresholds/withExpiry` | SNAPSHOT | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Identity | Identity | `Identity.GetDefensorConfiguration` | aatp | `/api/defensor/defensorConfiguration` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Identity | Identity | `Identity.GetGlobalExclusionEntities` | aatp | `/odata/ExclusionEntityDatas/Global` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Identity | Identity | `Identity.GetMachinesManagedByStatus` | mtp | `/siamApi/MachinesManagedByStatus` | SNAPSHOT | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Identity | Identity | `Identity.GetMemOnboardStatus` | mtp | `/siamApi/memonboardstatus` | SNAPSHOT | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Identity | Identity | `Identity.GetOnboardedMachinesStatus` | mtp | `/siamApi/OnboardedMachinesStatus` | SNAPSHOT | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Identity | Identity | `Identity.GetOnboardingStatus` | mdi | `/identity/userapiservice/status` | SNAPSHOT | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Identity | Identity | `Identity.GetPasswordDomainsPolicies` | mdi | `/identity/userapiservice/pdProtection/domainsPolicies` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Identity | Identity | `Identity.GetPasswordPolicyReportDefinitions` | mdi | `/identity/userapiservice/pdProtection/reportDefinitions/PasswordPolicies` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Identity | Identity | `Identity.GetPasswordPolicyReports` | mdi | `/identity/userapiservice/pdProtection/mdaReports/PasswordPolicies` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Identity | Identity | `Identity.GetRemediationActionsConfig` | aatp | `/api/remediationActions/configuration` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Identity | Identity | `Identity.GetSecurityAlertExclusions` | aatp | `/odata/SecurityAlertExclusionDatas` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Identity | Identity | `Identity.GetSyslogConfiguration` | aatp | `/api/workspace/configuration/syslog` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Identity | Identity | `Identity.GetUserTimeline` | mdi | `/identity/userapiservice/user/timeline` | SNAPSHOT | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Identity | Identity | `Identity.GetVpnConfiguration` | aatp | `/api/mtp/vpnConfiguration` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Identity | Identity | `Identity.GetWorkspaceMonitoringAlerts` | aatp | `/odata/workspaceMonitoringAlerts` | SNAPSHOT | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Operations | Action Center | `ActionCenter.GetHistory` | mtp | `/actionCenter/actioncenterui/history-actions` | CURSOR | 10-min (T1) | CoreTelemetry | shipped |
| Defender | Operations | Action Center | `ActionCenter.GetPending` | mtp | `/actionCenter/actioncenterui/pending-actions` | SNAPSHOT | 10-min (T1) | CoreTelemetry | shipped |
| Defender | Operations | Action Center | `ActionCenter.ListAutomationRules` | mtp | `/automation/internal/automation/{TenantId}/automationRules` | SNAPSHOT | 10-min (T1) | ConfigState | shipped |
| Defender | Operations | Multi-Tenant | `MultiTenant.GetEffectiveTenantGroup` | mtoapi | `/tenantGroups/effective/` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Operations | Multi-Tenant | `MultiTenant.GetTenantContext` | mtp | `/sccManagement/mgmt/TenantContext` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Operations | Multi-Tenant | `MultiTenant.GetWorkloadStatus` | mtoapi | `/tenants/{TenantId}/workloadStatus` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Operations | Multi-Tenant | `MultiTenant.ListAssignments` | mtoapi | `/assignments` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Operations | Multi-Tenant | `MultiTenant.ListTenantGroups` | mtoapi | `/tenantGroups` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Operations | Streaming API | `StreamingApi.GetConfiguration` | mtp | `/streamingapi/streamingApiConfiguration` | SNAPSHOT | 6-hourly (T3) | ConfigState | shipped |
| Defender | Portal Services | Portal Services | `PortalServices.CheckAppGovernanceOnboarding` | m365appprotection | `/mapg-glsservice/compliance/istenantonboarded` | SNAPSHOT | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Portal Services | Portal Services | `PortalServices.GetAttackSimUserCoverage` | astgws | `/AttackSimulator/api/v1/AdvanceReporting/chart/UserCoverage` | SNAPSHOT | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Portal Services | Portal Services | `PortalServices.GetMachineHealthStatus` | mtp | `/mdepDnH/reports/machineHealth/healthStatus` | SNAPSHOT | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Portal Services | Portal Services | `PortalServices.GetOptimizeRecommendations` | mtp | `/optimize/OptimizeRecommendation` | SNAPSHOT | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Secure Score | Secure Score | `SecureScore.GetControlProfilesV2` | mtp | `/secureScore/security/secureScoreControlProfilesV2` | SNAPSHOT | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Secure Score | Secure Score | `SecureScore.GetInsights` | mtp | `/secureScore/security/secureScoreInsights` | CURSOR | 6-hourly (T3) | CoreTelemetry | shipped |
| Defender | Secure Score | Secure Score | `SecureScore.GetSecureScoresV2` | mtp | `/secureScore/security/secureScoresV2` | SNAPSHOT | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Secure Score | Secure Score | `SecureScore.GetSecurityInitiativesV2` | mtp | `/secureScore/security/secureScoreSecurityInitiativesV2` | SNAPSHOT | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Secure Score | Secure Score | `SecureScore.GetTenantProfile` | mtp | `/secureScore/security/secureScoreTenantProfile` | SNAPSHOT | Hourly (T2) | CoreTelemetry | shipped |
| Defender | Vulnerability Management | Vulnerability Management | `VulnerabilityManagement.GetAsset` | mtp | `/tvm/analytics/assets/{assetId}` | SNAPSHOT | Daily (T4) | CoreTelemetry | shipped |
| Defender | Vulnerability Management | Vulnerability Management | `VulnerabilityManagement.GetTopSoftwareChangeEventsPerDay` | mtp | `/tvm/analytics/changeEvents/sca/topPerDay` | SNAPSHOT | Daily (T4) | CoreTelemetry | shipped |
| Defender | Vulnerability Management | Vulnerability Management | `VulnerabilityManagement.GetTopVaChangeEventsPerDay` | mtp | `/tvm/analytics/changeEvents/va/topPerDay` | SNAPSHOT | Daily (T4) | CoreTelemetry | shipped |
| Defender | Vulnerability Management | Vulnerability Management | `VulnerabilityManagement.ListAdvisories` | mtp | `/tvm/analytics/advisories` | SNAPSHOT | Daily (T4) | CoreTelemetry | shipped |
| Defender | Vulnerability Management | Vulnerability Management | `VulnerabilityManagement.ListAssetInstallations` | mtp | `/tvm/analytics/assets/{assetId}/installations` | SNAPSHOT | Daily (T4) | CoreTelemetry | shipped |
| Defender | Vulnerability Management | Vulnerability Management | `VulnerabilityManagement.ListCertificates` | mtp | `/tvm/analytics/certificates` | SNAPSHOT | Daily (T4) | ConfigState | shipped |
| Defender | Vulnerability Management | Vulnerability Management | `VulnerabilityManagement.ListChangeEvents` | mtp | `/tvm/analytics/changeEvents/` | SNAPSHOT | Daily (T4) | CoreTelemetry | shipped |
| Defender | Vulnerability Management | Vulnerability Management | `VulnerabilityManagement.ListExtensions` | mtp | `/tvm/analytics/extensions` | SNAPSHOT | Daily (T4) | ConfigState | shipped |
| Defender | Vulnerability Management | Vulnerability Management | `VulnerabilityManagement.ListProducts` | mtp | `/tvm/analytics/products` | SNAPSHOT | Daily (T4) | CoreTelemetry | shipped |
| Defender | Vulnerability Management | Vulnerability Management | `VulnerabilityManagement.ListTopVulnerableAssets` | mtp | `/tvm/analytics/assets/topVulnerable` | SNAPSHOT | Daily (T4) | CoreTelemetry | shipped |

## Held surface

476 catalogued operations are deliberately **held out of the ship-set** -- held is not dead. An operation is re-shipped the moment its basis changes (a new tenant capture, a runtime capability landing, a value re-classification). The dominant hold classes:

| Hold class | Count | Why held |
|---|---:|---|
| Official-API overlap | 120 | Served by a public Defender / Graph / ARM API -- XdrLogRaider ships only portal-unique telemetry, so overlapping endpoints are held. |
| Noise (pick-lists / bare-string catalogs / checksums) | 209 | Not per-entity telemetry -- UI filter lists, id catalogs, change-detection hashes. |
| UI helper (portal chrome) | 99 | Portal shell assets, summaries, and pickers -- not a telemetry stream. |
| Reference (id catalogs) | 17 | Bare id/name catalogs (which entities *exist*), not their keyed state. |
| Value/capability pending | 134 | CoreTelemetry-classed but blocked on a runtime capability (e.g. query/body entity fan-out) or an unresolved portal requirement -- re-ships once the basis lands. |
| Config state (held) | 17 | Config/posture endpoints held as duplicate or superseded by a shipped stream. |

44 held operations carry an explicit, recorded `ShipHeldReason` (the manually body-read / live-verified holds); the remainder are held by their value class or scope decision. Categories held in full: 

## Expansion surface

XdrLogRaider's engine is **portal-agnostic** -- the derivation, build, deploy, and verify pipeline does not hardcode anything Defender-specific. `references/inventory/` carries a researched surface of **1941 operations** across **119 categories** in **20 Microsoft portals** (Defender XDR, Entra, Purview, Teams, Intune, Power Platform, SharePoint, Exchange, and more).

v0.1.0 ships the Defender XDR slice: **123 of the 594** researched Defender operations (across 21 catalogued Defender category files). Contributors can wire any catalogued portal / category / stream the engine already supports -- the manifests and per-category schemas are generated the same way for every portal. The portal research under `references/` is public precisely so that expansion is a data exercise, not an engine rewrite.

## How this file is generated

This catalogue is emitted by `dev-tools/Export-CatalogueDoc.ps1` from two committed sources:

- **`manifests/Defender/*.psd1`** -- the deployed operation set (table, ingestion mode, cadence, path, sub-portal).
- **`references/inventory/nodoc-defender-xdr/catalogue.json`** -- value class, ship/held decision, and held reasons.

The generator asserts that the manifest operation count equals the catalogue `Shipped == true` count, so this doc can never silently drift from what actually deploys. Run `pwsh dev-tools/Export-CatalogueDoc.ps1 -Check` to fail a build on drift.

