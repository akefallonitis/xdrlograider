# Nodoc catalog sweep — Tier B (SHOULD in v0.1.0 if budget)

Generated: 2026-05-04
Total Tier B: 20 (operator value 4/5)

| # | Suggested Stream | Category | Workspace Table | Cadence | TimeFilter | Value | Path | Summary |
|---|---|---|---|---|---|---|---|---|
| 1 | `MDE_AppGovernanceListPolicies_CL` | ConfigurationAndSettings | `Defender_ConfigurationAndSettings_CL` | Configuration | snapshot-full | 4 | `/m365appprotection/mapg-glsservice/compliance/policies` | List App Governance policies |
| 2 | `MDE_CloudAppsListPolicies_CL` | ConfigurationAndSettings | `Defender_ConfigurationAndSettings_CL` | Configuration | snapshot-full | 4 | `/mcas/cas/api/v1/policies` | List policies |
| 3 | `MDE_AdvancedHuntingListStreamingDetectionCompatibleRules_CL` | ConfigurationAndSettings | `Defender_ConfigurationAndSettings_CL` | Configuration | snapshot-full | 4 | `/mtp/huntingService/rules/streamingDetectionCompatibleRules` | List streaming-compatible detection rules |
| 4 | `MDE_PortalServicesGetMachineHealthStatus_CL` | ConfigurationAndSettings | `Defender_ConfigurationAndSettings_CL` | Configuration | snapshot-full | 4 | `/mtp/mdepDnH/reports/machineHealth/healthStatus` | Get machine health status report |
| 5 | `MDE_ConfigurationGetAssetRules_CL` | ConfigurationAndSettings | `Defender_ConfigurationAndSettings_CL` | Configuration | snapshot-full | 4 | `/mtp/ndr/rulesengine/rules` | Get asset rule management rules |
| 6 | `MDE_ConfigurationListWebCategoryPolicies_CL` | ConfigurationAndSettings | `Defender_ConfigurationAndSettings_CL` | Configuration | snapshot-full | 4 | `/mtp/responseApiPortal/webcategory/policies` | List web content filtering policies |
| 7 | `MDE_EndpointConfigurationListCustomCollectionRules_CL` | EndpointConfiguration | `Defender_EndpointConfiguration_CL` | Configuration | snapshot-full | 4 | `/mtp/customDataCollection/rules` | List custom data collection rules |
| 8 | `MDE_EndpointConfigurationListDevicePolicies_CL` | EndpointConfiguration | `Defender_EndpointConfiguration_CL` | Configuration | per-entity-snapshot | 4 | `/mtp/unifiedExperience/mde/configurationManagement/mem/device/{MachineId}/policies` | List device policy assignments |
| 9 | `MDE_EndpointDevicesGetSensorCompatibleMachines_CL` | EndpointDeviceManagement | `Defender_EndpointDeviceManagement_CL` | Inventory | snapshot-full | 4 | `/mtp/mdi/tri/defensor/onboarding/devices/sensor_compatible_machines` | Get MDI sensor-compatible machines |
| 10 | `MDE_ExposureManagementGetRecommendations_CL` | ExposureManagement | `Defender_ExposureManagement_CL` | XspmGraph | snapshot-full | 4 | `/mtp/exposureManagement/recommendations` | Get exposure recommendations |
| 11 | `MDE_IdentityGetAlertThresholdsRecommendedTestMode_CL` | IdentityProtection | `Defender_IdentityProtection_CL` | Configuration | snapshot-full | 4 | `/aatp/api/alertthresholds/withExpiry/recommendedTestMode` | Get recommended test mode alert thresholds |
| 12 | `MDE_IdentityGetInfrastructureInfo_CL` | IdentityProtection | `Defender_IdentityProtection_CL` | Inventory | snapshot-full | 4 | `/aatp/api/sensors/identityInfrastructuresInfo` | Get identity infrastructure inventory |
| 13 | `MDE_IdentityGetSensorsCoverage_CL` | IdentityProtection | `Defender_IdentityProtection_CL` | Configuration | snapshot-full | 4 | `/aatp/api/sensors/sensorsCoverage` | Get sensors coverage |
| 14 | `MDE_IdentityListSensorsOdata_CL` | IdentityProtection | `Defender_IdentityProtection_CL` | Configuration | snapshot-full | 4 | `/aatp/odata/sensors` | List sensors (OData) |
| 15 | `MDE_IdentityGetDomainControllerCoverage_CL` | IdentityProtection | `Defender_IdentityProtection_CL` | Inventory | snapshot-full | 4 | `/mdi/identity/identitiesapiservice/domainController/coverage` | Get domain controller coverage |
| 16 | `MDE_MultiTenantGetTenantContext_CL` | MultiTenantOperations | `Defender_MultiTenantOperations_CL` | Configuration | snapshot-full | 4 | `/mtoapi/mtp/sccManagement/mgmt/TenantContext` | Get MTO tenant context |
| 17 | `MDE_VulnerabilityManagementListAssetRecommendations_CL` | VulnerabilityManagement | `Defender_VulnerabilityManagement_CL` | Configuration | per-entity-snapshot | 4 | `/mtp/tvm/analytics/assets/{assetId}/recommendations` | List asset recommendations |
| 18 | `MDE_VulnerabilityManagementListRecommendations_CL` | VulnerabilityManagement | `Defender_VulnerabilityManagement_CL` | Configuration | snapshot-full | 4 | `/mtp/tvm/analytics/recommendations` | List all recommendations |
| 19 | `MDE_VulnerabilityManagementGetRecommendationAssetStats_CL` | VulnerabilityManagement | `Defender_VulnerabilityManagement_CL` | Configuration | per-entity-snapshot | 4 | `/mtp/tvm/analytics/recommendations/{recommendationId}/assetsStatistics` | Get recommendation asset statistics |
| 20 | `MDE_VulnerabilityManagementGetVaRecommendations_CL` | VulnerabilityManagement | `Defender_VulnerabilityManagement_CL` | Configuration | snapshot-full | 4 | `/mtp/tvm/analytics/recommendations/va` | Get vulnerability assessment recommendations |

