# Nodoc catalog sweep — 2026-05-04

Source: `.internal/nodoc-reference/specifications/nodoc-defender-xdr/specification/` (23 yml files)
Methodology: Phase J.F.NEW.0 (D'.58) — exhaustive sweep + audit-scope filter

## Tally

| Bucket | Count |
|---|---|
| Total ops parsed | 595 |
| Already in manifest | 45 |
| Write ops (excluded) | 141 |
| Public-API-covered (excluded) | 9 |
| Out-of-scope spec (excluded) | 123 |
| **IN SCOPE FOR v0.1.0** | **262** |

## In-scope endpoints by category

### 8. Action Center (7 ops)

**Workspace table**: `Defender_ActionCenter_CL`

| Method | Path | Summary | Spec |
|---|---|---|---|
| GET | `/mtp/actionCenter/actioncenterui/history-actions/export` | Export action center history | action_center |
| GET | `/mtp/actionCenter/actioncenterui/pending-actions` | Get pending actions | action_center |
| GET | `/mtp/actionCenter/actioncenterui/pending-actions/pending-actions-summary` | Get pending actions summary | action_center |
| GET | `/mtp/actionCenter/actioncenterui/tile` | Get action center tile summary | action_center |
| GET | `/mtp/CaseManagement/be/attachments` | List case attachments | action_center |
| GET | `/mtp/CaseManagement/be/cases/{CaseId}` | Get case details | action_center |
| GET | `/mtp/CaseManagement/be/cases/{CaseId}/activities` | List case activities | action_center |

### 5. Configuration and Settings (82 ops)

**Workspace table**: `Defender_ConfigurationAndSettings_CL`

| Method | Path | Summary | Spec |
|---|---|---|---|
| GET | `/m365appprotection/mapg-glsservice/compliance/apps` | List App Governance compliance apps | cloud_apps |
| GET | `/m365appprotection/mapg-glsservice/compliance/getLabels` | List App Governance compliance labels | cloud_apps |
| GET | `/m365appprotection/mapg-glsservice/compliance/getUserProfile` | Get App Governance user profile | cloud_apps |
| GET | `/m365appprotection/mapg-glsservice/compliance/istenantinsightsready` | Check App Governance insights ready | portal_services |
| GET | `/m365appprotection/mapg-glsservice/compliance/istenantonboarded` | Check App Governance onboarding | portal_services |
| GET | `/m365appprotection/mapg-glsservice/compliance/policies` | List App Governance policies | cloud_apps |
| GET | `/m365appprotection/mapg-glsservice/compliance/Policy` | Get App Governance policy | cloud_apps |
| GET | `/m365appprotection/mapg-glsservice/compliance/policyinsights` | Get App Governance policy insights | cloud_apps |
| GET | `/m365appprotection/mapg-glsservice/compliance/tenantdatatraffic` | Get App Governance tenant data traffic | cloud_apps |
| GET | `/m365appprotection/mapg-glsservice/compliance/tenantLabelMetric` | Get App Governance tenant label metric | cloud_apps |
| GET | `/m365appprotection/mapg-glsservice/compliance/tenantmetrics` | Get App Governance tenant metrics | cloud_apps |
| GET | `/mcas/cas/api/discovery/streams` | List discovery streams | cloud_apps |
| GET | `/mcas/cas/api/services` | List cloud app services | cloud_apps |
| GET | `/mcas/cas/api/stories/get_stories_details` | Get story details | cloud_apps |
| GET | `/mcas/cas/api/v1/activities_locations/by_user` | Get activity locations by user | cloud_apps |
| GET | `/mcas/cas/api/v1/app_connectors` | Get app connectors | cloud_apps |
| GET | `/mcas/cas/api/v1/app_connectors/last_activity` | Get app connectors last activity | cloud_apps |
| GET | `/mcas/cas/api/v1/app_connectors/table_config_values` | Get app connectors table config values | cloud_apps |
| GET | `/mcas/cas/api/v1/connected_services/apps` | List connected service apps | cloud_apps |
| GET | `/mcas/cas/api/v1/connected_services/instances` | List connected service instances | cloud_apps |
| GET | `/mcas/cas/api/v1/data_encryption_settings/get` | Get data encryption settings | cloud_apps |
| GET | `/mcas/cas/api/v1/discovery/categories` | List discovery categories | cloud_apps |
| GET | `/mcas/cas/api/v1/discovery/category_stats` | Get discovery category stats | cloud_apps |
| GET | `/mcas/cas/api/v1/discovery/constants` | Get discovery constants | cloud_apps |
| GET | `/mcas/cas/api/v1/discovery/get_locations` | Search discovery locations | cloud_apps |
| GET | `/mcas/cas/api/v1/discovery/service_locations` | Get discovery service locations | cloud_apps |
| GET | `/mcas/cas/api/v1/discovery/top_apps` | Get top discovered apps | cloud_apps |
| GET | `/mcas/cas/api/v1/discovery/top_categories` | Get top discovery categories | cloud_apps |
| GET | `/mcas/cas/api/v1/discovery/top_entities` | Get top discovered entities | cloud_apps |
| GET | `/mcas/cas/api/v1/invited_group_admins` | List invited group admins | cloud_apps |
| GET | `/mcas/cas/api/v1/policies` | List policies | cloud_apps |
| GET | `/mcas/cas/api/v1/user_queries` | List user queries | cloud_apps |
| GET | `/mdc/management/optin` | Get Defender for Cloud preview features | configuration |
| GET | `/msgraph/v1.0/subscribedSkus` | Get subscribed SKUs via Graph proxy | portal_services |
| GET | `/msgraph/v1.0/users` | List users via Graph proxy | portal_services |
| GET | `/msgraph/v1.0/users/{UserId}` | Get user via Graph proxy | portal_services |
| GET | `/mtp/CustomerSubmissionService/file/enterprise/query/{TenantId}` | List file submissions | configuration |
| GET | `/mtp/disrupt/api/exclusions/exclude-all` | Get all disruption exclusions | configuration |
| GET | `/mtp/disrupt/api/exclusions/Identity` | Get identity disruption exclusions | configuration |
| GET | `/mtp/disrupt/api/exclusions/Identity/global-exclusion` | Get global identity disruption exclusion | configuration |
| GET | `/mtp/huntingService/communityQueries` | Get community queries | advanced_hunting |
| GET | `/mtp/huntingService/documentation/GettingStarted` | Get getting started docs | advanced_hunting |
| GET | `/mtp/huntingService/documentation/GuidedHuntingGettingStarted` | Get guided hunting getting started docs | advanced_hunting |
| GET | `/mtp/huntingService/favorites` | Get hunting favorites | advanced_hunting |
| GET | `/mtp/huntingService/functions/defender/savedfunctions/{Id}` | Get saved function | advanced_hunting |
| GET | `/mtp/huntingService/guidedQueries/filterSchema` | Get guided queries filter schema | advanced_hunting |
| GET | `/mtp/huntingService/queries` | List hunting queries | advanced_hunting |
| GET | `/mtp/huntingService/queries/defender/communityqueries/{id}` | Get community query by ID | advanced_hunting |
| GET | `/mtp/huntingService/queries/defender/savedqueries/{id}` | Get saved query by ID | advanced_hunting |
| GET | `/mtp/huntingService/queries/encode` | Encode hunting query | advanced_hunting |
| GET | `/mtp/huntingService/reports/userHistory` | Get user hunting query history | advanced_hunting |
| GET | `/mtp/huntingService/rules/streamingDetectionCompatibleRules` | List streaming-compatible detection rules | advanced_hunting |
| GET | `/mtp/huntingService/savedFunctions` | List saved functions | advanced_hunting |
| GET | `/mtp/huntingService/schema` | Get advanced hunting table schema | advanced_hunting |
| GET | `/mtp/huntingService/schema/functions` | Get hunting schema functions | advanced_hunting |
| GET | `/mtp/licenses/mgmt/aadlicenses/mdc/status` | Get MDC license status | configuration |
| GET | `/mtp/licenses/mgmt/aadlicenses/sums` | Get license sums | configuration |
| GET | `/mtp/mdepDnH/reports/machineHealth/healthStatus` | Get machine health status report | portal_services |
| GET | `/mtp/ndr/rulesengine/rules` | Get asset rule management rules | configuration |
| GET | `/mtp/optimize/OptimizeRecommendation` | Get optimize recommendations | portal_services |
| GET | `/mtp/papin/api/cloud/public/internal/IncidentNotificationSettingsV2` | List incident notification settings | configuration |
| GET | `/mtp/papin/api/cloud/public/internal/indicators/count` | Get internal indicator count | configuration |
| GET | `/mtp/rbacManagementApi/rbac/aad_groups` | List RBAC Entra groups | configuration |
| GET | `/mtp/rbacManagementApi/rbac/user_roles` | Get current user RBAC roles | configuration |
| GET | `/mtp/responseApiPortal/ti/indicators` | List custom threat indicators | configuration |
| GET | `/mtp/responseApiPortal/webcategory/policies` | List web content filtering policies | configuration |
| GET | `/mtp/sccManagement/mgmt/ServicesUrls` | Get Defender service URLs | configuration |
| GET | `/mtp/sentinelOnboarding/sentinel/workspaces/isOnboarded` | Get Sentinel onboarding state | configuration |
| GET | `/mtp/settings/GetUserSettings` | Get Defender XDR user settings | configuration |
| GET | `/mtp/suppressionRulesService/suppressionRules/builtInRulesHash` | Get built-in suppression rules hash | configuration |
| GET | `/mtp/unifiedConnectors/public/connectors` | List unified connectors | configuration |
| GET | `/mtp/unifiedConnectors/public/connectors/checkrequirements` | Check unified connector requirements | configuration |
| GET | `/mtp/urbacConfiguration/gw/unifiedrbac/configuration/permissions` | Get unified RBAC permissions | configuration |
| GET | `/mtp/urbacConfiguration/gw/unifiedrbac/configuration/roleDefinitions/{RoleDefinitionId}/roleAssignments` | List unified RBAC role assignments | configuration |
| GET | `/mtp/urbacConfiguration/gw/unifiedrbac/configuration/tenantinfo` | Get unified RBAC workload configuration | configuration |
| GET | `/mtp/urbacConfiguration/gw/unifiedrbac/configuration/workspaces` | List unified RBAC workspaces | configuration |
| GET | `/mtp/userExposedRbacGroups/UserExposedRbacGroups` | Get user RBAC groups | advanced_hunting |
| GET | `/mtp/userPreferences/api/mgmt/userpreferencesservice/userPreference/advanced_hunting` | Get advanced hunting user preferences | advanced_hunting |
| GET | `/mtp/userPreferences/api/mgmt/userpreferencesservice/userPreference/alwaysUseUtc` | Get UTC preference | portal_services |
| GET | `/mtp/xspmatlas/assetrules/querybuilder/assets/{encodedRuleName}` | Query critical asset classification | configuration |
| GET | `/mtp/xspmatlas/assetrules/querybuilder/schema` | Get critical asset classification schema | configuration |
| GET | `/shell/api/shell/shellinfo` | Get shell info | portal_services |

### 2. Endpoint Configuration (12 ops)

**Workspace table**: `Defender_EndpointConfiguration_CL`

| Method | Path | Summary | Spec |
|---|---|---|---|
| GET | `/mtp/customDataCollection/rules` | List custom data collection rules | endpoint_configuration |
| GET | `/mtp/deviceManagement/configuration/AuthenticatedTelemetry` | Get authenticated telemetry configuration | endpoint_configuration |
| GET | `/mtp/deviceManagement/configuration/IntuneConnection` | Get Intune connection configuration | endpoint_configuration |
| GET | `/mtp/deviceManagement/configuration/PotentiallyUnwantedApplications` | Get PUA configuration | endpoint_configuration |
| GET | `/mtp/deviceManagement/configuration/PurviewSharing` | Get Purview sharing configuration | endpoint_configuration |
| GET | `/mtp/mdeCustomCollection/model` | Get custom data collection model | endpoint_configuration |
| GET | `/mtp/mdiotSettingsService/settings/DiscoveryEnabledTags` | Get device discovery enabled tags | endpoint_configuration |
| GET | `/mtp/mdiotSettingsService/settings/v2/MagellanFeatures` | Get device discovery feature flags | endpoint_configuration |
| GET | `/mtp/settings/overrideMdeFlavor` | Get MDE flavor override | endpoint_configuration |
| GET | `/mtp/unifiedExperience/mde/configurationManagement/mem/device/{MachineId}/policies` | List device policy assignments | endpoint_configuration |
| GET | `/mtp/unifiedExperience/mde/configurationManagement/mem/proxy/deviceManagement/managedDevices` | Resolve Intune managed device | endpoint_configuration |
| GET | `/mtp/unifiedExperience/mde/configurationManagement/mem/proxy/deviceManagement/managedDevices/{ManagedDeviceId}/users` | List managed device users | endpoint_configuration |

### 1. Endpoint Device Management (39 ops)

**Workspace table**: `Defender_EndpointDeviceManagement_CL`

| Method | Path | Summary | Spec |
|---|---|---|---|
| GET | `/mtp/deviceManagement/deviceLicenseReport` | Get endpoint license report | endpoint_devices |
| GET | `/mtp/deviceManagement/deviceModels` | List device models | endpoint_devices |
| GET | `/mtp/deviceManagement/deviceTotals` | Get device totals | endpoint_devices |
| GET | `/mtp/deviceManagement/deviceVendors` | List device vendors | endpoint_devices |
| GET | `/mtp/deviceManagement/osVersions` | List OS version friendly names | endpoint_devices |
| GET | `/mtp/deviceManagement/windowsReleaseVersions` | List Windows release versions | endpoint_devices |
| GET | `/mtp/deviceTimeline/timeline/{DeviceId}` | Get device timeline | endpoint_devices |
| GET | `/mtp/getDataSensitivity/machines/{MachineId}/dataSensitivity` | Get machine data sensitivity | endpoint_devices |
| GET | `/mtp/getLatestMachineIpsByIds/LatestMachineIpsByIds` | Get latest device IP addresses | endpoint_devices |
| GET | `/mtp/getMachine/machines` | Get endpoint device details | endpoint_devices |
| GET | `/mtp/getMachineMarkedEvents/machines/{MachineId}/eventMarks` | Get machine marked events | endpoint_devices |
| GET | `/mtp/getTopUsersByIds/TopUsersByIds` | Get top users for device | endpoint_devices |
| GET | `/mtp/machineTag/machineTags/{DeviceId}` | Get device tags | endpoint_devices |
| GET | `/mtp/mdeTimelineExperience/ips/{IpAddress}/events` | Get IP timeline events | endpoint_devices |
| GET | `/mtp/mdeTimelineExperience/machines/{MachineId}/events` | Get machine timeline events | endpoint_devices |
| GET | `/mtp/mdi/tri/defensor/onboarding/devices/sensor_compatible_machines` | Get MDI sensor-compatible machines | endpoint_devices |
| GET | `/mtp/ndr/machines` | List endpoint devices | endpoint_devices |
| GET | `/mtp/ndr/machines/{MachineId}/exclusionDetails` | Get NDR machine exclusion details | endpoint_devices |
| GET | `/mtp/ndr/machines/{MachineId}/InterceptingMachines` | Get NDR intercepting machines | endpoint_devices |
| GET | `/mtp/ndr/machines/allFirmwareVersions` | Get all firmware versions | endpoint_devices |
| GET | `/mtp/ndr/machines/allMachinesTags` | Get all machine tags | endpoint_devices |
| GET | `/mtp/ndr/machines/allModels` | Get all device models | endpoint_devices |
| GET | `/mtp/ndr/machines/allOsVersionFriendlyNames` | Get all OS version friendly names | endpoint_devices |
| GET | `/mtp/ndr/machines/allVendors` | Get all vendors | endpoint_devices |
| GET | `/mtp/ndr/machines/allWindowsReleaseVersions` | Get all Windows release versions | endpoint_devices |
| GET | `/mtp/ndr/machines/commandExport` | Export NDR machine inventory | endpoint_devices |
| GET | `/mtp/ndr/machines/devicesWithoutSiteTotals` | Get device counts without site totals | endpoint_devices |
| GET | `/mtp/ndr/machines/deviceTotalCount` | Get NDR device total count | endpoint_devices |
| GET | `/mtp/ndr/machines/deviceTotals` | Get device totals | endpoint_devices |
| GET | `/mtp/ndr/machines/deviceTypeDistribution` | Get NDR device type distribution | endpoint_devices |
| GET | `/mtp/ndr/machines/machineTags` | Get NDR machine tags | endpoint_devices |
| GET | `/mtp/rbacGroupAssignment/machineRbacGroupAssignments/{DeviceId}` | Get device RBAC group assignments | endpoint_devices |
| GET | `/mtp/rbacGroupAssignment/rbacGroupsScopes/{DeviceId}` | Get device RBAC group scopes | endpoint_devices |
| GET | `/mtp/responseApiPortal/requests/{ActionId}` | Get device action result | endpoint_devices |
| GET | `/mtp/responseApiPortal/requests/latest` | Get latest device response action | endpoint_devices |
| GET | `/mtp/responseApiPortal/requests/machine/any` | Check for any device response actions | endpoint_devices |
| GET | `/mtp/responseApiPortal/requests/machinestate` | Get device response action state | endpoint_devices |
| GET | `/mtp/responseApiPortal/requests/permissions` | Get device response action permissions | endpoint_devices |
| GET | `/mtp/wdatpApi/machines` | Get machines via WDATP API | endpoint_devices |

### 6. Exposure Management (15 ops)

**Workspace table**: `Defender_ExposureManagement_CL`

| Method | Path | Summary | Spec |
|---|---|---|---|
| GET | `/mtp/exposureManagement/recommendations` | Get exposure recommendations | exposure_management |
| GET | `/mtp/k8s/machines/deviceTotals` | Get Kubernetes device totals | exposure_management |
| GET | `/mtp/posture/oversight/initiatives/{InitiativeId}` | Get posture oversight initiative details | exposure_management |
| GET | `/mtp/posture/oversight/initiatives/summarized` | Get summarized posture initiatives | exposure_management |
| GET | `/mtp/posture/oversight/metrics` | List posture oversight metrics | exposure_management |
| GET | `/mtp/posture/oversight/metrics/category_apps_secure_score` | Get SaaS apps secure score metric | exposure_management |
| GET | `/mtp/posture/oversight/metrics/category_data_secure_score` | Get data secure score metric | exposure_management |
| GET | `/mtp/posture/oversight/metrics/category_identity_secure_score` | Get identity secure score metric | exposure_management |
| GET | `/mtp/posture/oversight/recommendations/aggregated` | Get aggregated posture recommendations | exposure_management |
| GET | `/mtp/posture/oversight/securityEvents` | List posture security events | exposure_management |
| GET | `/mtp/posture/oversight/tenants` | Get posture oversight tenant configuration | exposure_management |
| GET | `/mtp/tvm/analytics/riskscore` | Get TVM risk score | exposure_management |
| GET | `/mtp/xspmatlas/attacksurface/attackpaths` | List attack surface attack paths | exposure_management |
| GET | `/mtp/xspmatlas/attacksurface/chokepoints/list` | List attack surface choke points | exposure_management |
| GET | `/mtp/XspmConnectors/connectors/getAllConnectors` | List XSPM connectors | exposure_management |

### 4. Identity Protection (51 ops)

**Workspace table**: `Defender_IdentityProtection_CL`

| Method | Path | Summary | Spec |
|---|---|---|---|
| GET | `/aatp/api/alertthresholds/withExpiry/recommendedTestMode` | Get recommended test mode alert thresholds | identity |
| GET | `/aatp/api/defensor/defensorConfiguration` | Get defensor configuration | identity |
| GET | `/aatp/api/ispmReports/DormantEntities/newEntryCount` | Get dormant entities report delta | identity |
| GET | `/aatp/api/ispmReports/RiskyLateralMovementPath/newEntryCount` | Get risky lateral movement path delta | identity |
| GET | `/aatp/api/ispmReports/UnsecureDomainConfigurations` | List unsecure domain configurations | identity |
| GET | `/aatp/api/ispmReports/UnsecureDomainConfigurations/newEntryCount` | Get unsecure domain configuration delta | identity |
| GET | `/aatp/api/mtp/applicationData` | Get AATP application data | identity |
| GET | `/aatp/api/mtp/vpnConfiguration` | Get VPN configuration | identity |
| GET | `/aatp/api/sensors/identityInfrastructuresInfo` | Get identity infrastructure inventory | identity |
| GET | `/aatp/api/sensors/sensorsCoverage` | Get sensors coverage | identity |
| GET | `/aatp/api/unifiedrbac/scopes` | Get unified RBAC scopes | identity |
| GET | `/aatp/api/unifiedrbac/usedScopes` | Get used unified RBAC scopes | identity |
| GET | `/aatp/api/workspace/configuration/scopedHealthNotifications` | Get scoped health notifications | identity |
| GET | `/aatp/api/workspace/configuration/syslog` | Get syslog configuration | identity |
| GET | `/aatp/api/workspace/isActive` | Check workspace active status | identity |
| GET | `/aatp/api/workspaces/isWorkspaceExists` | Check if workspace exists | identity |
| GET | `/aatp/odata/directoryServices` | Get directory services accounts | identity |
| GET | `/aatp/odata/EntityRemediatorCredentials` | Get entity remediator credentials | identity |
| GET | `/aatp/odata/ExclusionEntityDatas/Global` | Get global excluded entities | identity |
| GET | `/aatp/odata/SecurityAlertExclusionDatas` | Get security alert exclusions by detection rule | identity |
| GET | `/aatp/odata/sensors` | List sensors (OData) | identity |
| GET | `/aatp/odata/TaggedSecurityPrincipals` | Get tagged security principals (sensitive) | identity |
| GET | `/aatp/odata/workspaceMonitoringAlerts` | Get workspace monitoring alerts | identity |
| GET | `/mdi/identity/identitiesapiservice/domainController/coverage` | Get domain controller coverage | identity |
| GET | `/mdi/identity/identitiesapiservice/remediationAccount` | Get remediation action account | identity |
| GET | `/mdi/identity/userapiservice/alertThreshold` | Get alert threshold | identity |
| GET | `/mdi/identity/userapiservice/directoryServiceAccount` | Get directory service account | identity |
| GET | `/mdi/identity/userapiservice/manager` | Get user manager | identity |
| GET | `/mdi/identity/userapiservice/pdProtection/domainsPolicies` | Get password domains and policies | identity |
| GET | `/mdi/identity/userapiservice/pdProtection/mdaReports/PasswordHygiene` | Get password hygiene reports | identity |
| GET | `/mdi/identity/userapiservice/pdProtection/mdaReports/PasswordPolicies` | Get password policy reports | identity |
| GET | `/mdi/identity/userapiservice/pdProtection/reportDefinitions/ExposedPasswords` | Get exposed-password report definitions | identity |
| GET | `/mdi/identity/userapiservice/pdProtection/reportDefinitions/LeakedCredentials` | Get leaked-credential report definitions | identity |
| GET | `/mdi/identity/userapiservice/pdProtection/reportDefinitions/PasswordHygiene` | Get password hygiene report definitions | identity |
| GET | `/mdi/identity/userapiservice/pdProtection/reportDefinitions/PasswordPolicies` | Get password policy report definitions | identity |
| GET | `/mdi/identity/userapiservice/serviceAccounts/count` | Get service accounts count | identity |
| GET | `/mdi/identity/userapiservice/statistics` | Get identity statistics | identity |
| GET | `/mdi/identity/userapiservice/status` | Get onboarding status | identity |
| GET | `/mdi/identity/userapiservice/user/timeline` | Get user timeline | identity |
| GET | `/mtp/siamApi/domaincontrollers/totals` | Get SIAM domain controller totals | identity |
| GET | `/mtp/siamApi/MachinesManagedByStatus` | Get SIAM managed-by status | identity |
| GET | `/mtp/siamApi/MdeAttachEnabled` | Get SIAM MDE attachment state | identity |
| GET | `/mtp/siamApi/memonboardstatus` | Get MEM onboarding status | identity |
| GET | `/mtp/siamApi/OnboardedMachinesStatus` | Get onboarded machines status | identity |
| GET | `/radius/api/radius/identities/getCriticalityScore` | Get identity criticality score | identity |
| GET | `/radius/api/radius/identities/getDefenderRiskKillChain` | Get Defender risk kill chain | identity |
| GET | `/radius/api/radius/identities/getDefenderRiskScoresOverTime` | Get Defender risk scores over time | identity |
| GET | `/radius/api/radius/identities/getDefenderRiskSummary` | Get Defender risk summary | identity |
| GET | `/radius/api/radius/identities/getIdentityType` | Get Radius identity type | identity |
| GET | `/radius/api/radius/identities/getTenantPartners` | Get Radius tenant partners | identity |
| GET | `/radius/api/radius/remediation/lmf/{Sid}` | Get Radius remediation state | identity |

### 9. Multi-Tenant Operations (10 ops)

**Workspace table**: `Defender_MultiTenantOperations_CL`

| Method | Path | Summary | Spec |
|---|---|---|---|
| GET | `/mtoapi/assignments` | List content distribution assignments | multi_tenant |
| GET | `/mtoapi/mtp/CaseManagement/be/cases` | List MTO cases | multi_tenant |
| GET | `/mtoapi/mtp/CaseManagement/be/templates/{TemplateId}` | Get MTO case template | multi_tenant |
| GET | `/mtoapi/mtp/huntingService/queries/` | List MTO hunting queries | multi_tenant |
| GET | `/mtoapi/mtp/sccManagement/mgmt/TenantContext` | Get MTO tenant context | multi_tenant |
| GET | `/mtoapi/mtp/userExposedRbacGroups/UserExposedRbacGroups` | Get MTO hunting RBAC groups | multi_tenant |
| GET | `/mtoapi/recentItems` | Get recent items | multi_tenant |
| GET | `/mtoapi/tenantGroups/effective/` | Get effective tenant group | multi_tenant |
| GET | `/mtoapi/tenants/{TenantId}/workloadStatus` | Get tenant workload status | multi_tenant |
| GET | `/mtp/userPreferences/api/mgmt/userpreferencesservice/userPreference/advanced_hunting_mto` | Get MTO advanced hunting preferences | multi_tenant |

### 7. Threat Analytics (15 ops)

**Workspace table**: `Defender_ThreatAnalytics_CL`

| Method | Path | Summary | Spec |
|---|---|---|---|
| GET | `/mtp/outbreaks/outbreaks/v2/{OutbreakId}/devices` | Get outbreak devices | threat_analytics |
| GET | `/mtp/threatAnalytics/outbreaks/{OutbreakId}/alertsOvertimeSummary` | Get outbreak alerts over time summary | threat_analytics |
| GET | `/mtp/threatAnalytics/outbreaks/{OutbreakId}/overview` | Get outbreak overview | threat_analytics |
| GET | `/mtp/threatAnalytics/outbreaks/{OutbreakId}/patchdata` | Get outbreak patch data | threat_analytics |
| GET | `/mtp/threatAnalytics/outbreaks/{OutbreakId}/relatedIntelligence` | Get outbreak related intelligence | threat_analytics |
| GET | `/mtp/threatAnalytics/outbreaks/outbreaksEnrichedDataMtp` | Get enriched outbreak data | threat_analytics |
| GET | `/mtp/threatAnalytics/outbreaks/topthreats` | Get top threats | threat_analytics |
| GET | `/mtp/threatAnalytics/outbreaks/v2/{OutbreakId}/impactedAssetsOvertime` | Get outbreak impacted assets over time | threat_analytics |
| GET | `/mtp/threatAnalytics/outbreaks/v2/{OutbreakId}/impactedAssetsSummary` | Get outbreak impacted assets summary | threat_analytics |
| GET | `/mtp/threatAnalytics/outbreaks/v2/{OutbreakId}/incidentsAlertsSummary` | Get outbreak incidents and alerts summary | threat_analytics |
| GET | `/mtp/threatAnalytics/outbreaks/v2/{OutbreakId}/tvmDetails` | Get outbreak TVM details | threat_analytics |
| GET | `/mtp/threatAnalytics/outbreaks/v2/{OutbreakId}/userExposure` | Get outbreak user exposure | threat_analytics |
| GET | `/mtp/threatAnalyticsAPI/outbreaks` | List threat analytics outbreaks | threat_analytics |
| GET | `/mtp/threatAnalyticsIndicators/stix/oneti/reputation` | Get indicator reputation | threat_analytics |
| GET | `/mtp/threatAnalyticsIndicators/stix/oneti/reputation/URL` | Get URL reputation | threat_analytics |

### 3. Vulnerability Management (31 ops)

**Workspace table**: `Defender_VulnerabilityManagement_CL`

| Method | Path | Summary | Spec |
|---|---|---|---|
| GET | `/mtp/tvm/analytics/advisories` | List security advisories | vulnerability_management |
| GET | `/mtp/tvm/analytics/assets/{assetId}` | Get TVM asset details | vulnerability_management |
| GET | `/mtp/tvm/analytics/assets/{assetId}/installations` | List asset installations | vulnerability_management |
| GET | `/mtp/tvm/analytics/assets/{assetId}/recommendations` | List asset recommendations | vulnerability_management |
| GET | `/mtp/tvm/analytics/assets/{assetId}/vulnerabilities` | List asset vulnerabilities | vulnerability_management |
| GET | `/mtp/tvm/analytics/assets/{assetId}/vulnerabilitiesDistribution` | Get asset vulnerability distribution | vulnerability_management |
| GET | `/mtp/tvm/analytics/assets/countByExposureLevel` | Get asset counts by exposure level | vulnerability_management |
| GET | `/mtp/tvm/analytics/assets/topVulnerable` | Get top vulnerable assets | vulnerability_management |
| GET | `/mtp/tvm/analytics/certificates` | List certificates | vulnerability_management |
| GET | `/mtp/tvm/analytics/certificates/algorithms` | Get certificate algorithm breakdown | vulnerability_management |
| GET | `/mtp/tvm/analytics/changeevents` | List change events | vulnerability_management |
| GET | `/mtp/tvm/analytics/changeEvents/` | List change events | vulnerability_management |
| GET | `/mtp/tvm/analytics/changeEvents/sca/topPerDay` | Get top software change events per day | vulnerability_management |
| GET | `/mtp/tvm/analytics/changeEvents/va/topPerDay` | Get top vulnerability change events per day | vulnerability_management |
| GET | `/mtp/tvm/analytics/dashboard` | Get TVM dashboard | vulnerability_management |
| GET | `/mtp/tvm/analytics/devicehealth` | Get TVM device health summary | vulnerability_management |
| GET | `/mtp/tvm/analytics/extensions` | List browser extensions | vulnerability_management |
| GET | `/mtp/tvm/analytics/products` | List software products | vulnerability_management |
| GET | `/mtp/tvm/analytics/recommendations` | List all recommendations | vulnerability_management |
| GET | `/mtp/tvm/analytics/recommendations/{recommendationId}/assetsStatistics` | Get recommendation asset statistics | vulnerability_management |
| GET | `/mtp/tvm/analytics/recommendations/va` | Get vulnerability assessment recommendations | vulnerability_management |
| GET | `/mtp/tvm/analytics/remediations` | List remediation tasks | vulnerability_management |
| GET | `/mtp/tvm/analytics/vulnerabilities` | List vulnerabilities | vulnerability_management |
| GET | `/mtp/tvm/analytics/vulnerabilities/{cveId}/assets` | Get vulnerability assets by CVE | vulnerability_management |
| GET | `/mtp/tvm/analytics/vulnerabilities/baseline` | Get vulnerability baseline | vulnerability_management |
| GET | `/mtp/tvm/analytics/vulnerabilities/summary` | Get vulnerability summary | vulnerability_management |
| GET | `/mtp/tvm/analytics/vulnerableDevicesReport` | Get vulnerable devices report | vulnerability_management |
| GET | `/mtp/tvm/orgsettings/provision/isEligible` | Check TVM provisioning eligibility | vulnerability_management |
| GET | `/mtp/tvm/remediation-tasks/allExceptions/aggregated` | List remediation task exceptions | vulnerability_management |
| GET | `/mtp/tvm/remediation-tasks/remediationTasks` | List remediation tasks | vulnerability_management |
| GET | `/mtp/tvm/remediation-tasks/remediationTasks/top` | Get top remediation tasks | vulnerability_management |

## Already-in-manifest cross-reference

| Path | Existing stream | Spec |
|---|---|---|
| `/aatp/api/alertthresholds/withExpiry` | MDE_IdentityAlertThresholds_CL | identity |
| `/aatp/api/remediationActions/configuration` | MDE_RemediationAccounts_CL | identity |
| `/aatp/api/sensors/domainControllerCoverage` | MDE_DCCoverage_CL | identity |
| `/mcas/cas/api/v1/settings` | MDE_CloudAppsConfig_CL | configuration |
| `/mcas/cas/api/v1/settings` | MDE_CloudAppsConfig_CL | cloud_apps |
| `/mdi/identity/userapiservice/serviceAccounts` | MDE_IdentityServiceAccounts_CL | identity |
| `/mtoapi/tenantGroups` | MDE_TenantWorkloadStatus_CL | multi_tenant |
| `/mtoapi/tenants/TenantPicker` | MDE_MtoTenants_CL | multi_tenant |
| `/mtp/actionCenter/actioncenterui/history-actions` | MDE_ActionCenter_CL | action_center |
| `/mtp/alertsApiService/workloads/disabled` | MDE_AlertServiceConfig_CL | configuration |
| `/mtp/alertsEmailNotifications/email_notifications` | MDE_AlertTuning_CL | endpoint_configuration |
| `/mtp/autoIr/ui/properties` | MDE_PUAConfig_CL | configuration |
| `/mtp/huntingService/rules/unified` | MDE_CustomDetections_CL | advanced_hunting |
| `/mtp/liveResponseApi/get_properties` | MDE_LiveResponseConfig_CL | live_response |
| `/mtp/papin/api/cloud/public/internal/indicators/filterValues` | MDE_TenantAllowBlock_CL | configuration |
| `/mtp/posture/oversight/initiatives` | MDE_XspmInitiatives_CL | exposure_management |
| `/mtp/posture/oversight/recommendations` | MDE_ExposureRecommendations_CL | exposure_management |
| `/mtp/posture/oversight/updates` | MDE_ExposureSnapshots_CL | exposure_management |
| `/mtp/rbacManagementApi/rbac/machine_groups` | MDE_RbacDeviceGroups_CL | endpoint_devices |
| `/mtp/responseApiPortal/apps/all` | MDE_ConnectedApps_CL | configuration |
| `/mtp/responseApiPortal/onboarding/intune/status` | MDE_IntuneConnection_CL | configuration |
| `/mtp/responseApiPortal/senseauth/allownonauthsense` | MDE_AuthenticatedTelemetry_CL | configuration |
| `/mtp/sccManagement/mgmt/TenantContext` | MDE_TenantContext_CL | configuration |
| `/mtp/settings/GetAdvancedFeaturesSetting` | MDE_AdvancedFeatures_CL | endpoint_configuration |
| `/mtp/settings/GetAdvancedFeaturesSetting` | MDE_AdvancedFeatures_CL | endpoint_configuration |
| `/mtp/settings/GetPreviewExperienceSetting` | MDE_PreviewFeatures_CL | endpoint_configuration |
| `/mtp/siamApi/domaincontrollers/list` | MDE_IdentityOnboarding_CL | identity |
| `/mtp/siamApi/Onboarding` | MDE_DeviceControlPolicy_CL | identity |
| `/mtp/streamingapi/streamingApiConfiguration` | MDE_StreamingApiConfig_CL | streaming |
| `/mtp/suppressionRulesService/suppressionRules` | MDE_SuppressionRules_CL | configuration |
| `/mtp/threatAnalytics/outbreaks` | MDE_ThreatAnalytics_CL | threat_analytics |
| `/mtp/unifiedExperience/mde/configurationManagement/mem/securityPolicies/filters` | MDE_AntivirusPolicy_CL | endpoint_configuration |
| `/mtp/urbacConfiguration/gw/unifiedrbac/configuration/roleDefinitions` | MDE_UnifiedRbacRoles_CL | configuration |
| `/mtp/userPreferences/api/mgmt/userpreferencesservice/userPreference` | MDE_UserPreferences_CL | portal_services |
| `/mtp/userPreferences/api/mgmt/userpreferencesservice/userPreference` | MDE_UserPreferences_CL | portal_services |
| `/mtp/wdatpApi/dataexportsettings` | MDE_DataExportSettings_CL | configuration |
| `/mtp/wdatpInternalApi/compliance/alertSharing/status` | MDE_PurviewSharing_CL | configuration |
| `/mtp/webThreatProtection/WebContentFiltering/Reports/TopParentCategories` | MDE_WebContentFiltering_CL | configuration |
| `/mtp/webThreatProtection/webThreats/reports/webThreatSummary` | MDE_SmartScreenConfig_CL | configuration |
| `/mtp/xspmatlas/assetrules` | MDE_AssetRules_CL | configuration |
| `/mtp/xspmatlas/assetrules` | MDE_AssetRules_CL | configuration |
| `/mtp/xspmatlas/assetrules` | MDE_AssetRules_CL | configuration |
| `/mtp/xspmatlas/assetrules` | MDE_AssetRules_CL | configuration |
| `/mtp/xspmatlas/attacksurface/query` | MDE_XspmTopTargets_CL | exposure_management |
| `/radius/api/radius/serviceaccounts/classificationrule/getall` | MDE_SAClassification_CL | configuration |


