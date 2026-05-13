# Defender ReadSemantics audit

Generated: 2026-05-12 20:15:18 UTC

## Distribution

| Kind | Count |
|---|---:|
| read | 492 |
| write | 17 |
| unknown | 0 |
| **Total Defender** | **509** |

## Write-shaped endpoints (excluded from Phase 1 manifest — we are READ-ONLY connector)

| Sub-area | Slug | OperationId |
|---|---|---|
| cloud_apps | LogTranslationError | `CloudApps.LogTranslationError` |
| cloud_apps | UpdateUsageInfo | `CloudApps.UpdateUsageInfo` |
| configuration | SetMcasPreviewFeatures | `Configuration.SetMcasPreviewFeatures` |
| configuration | SetPreviewFeatures | `Configuration.SetPreviewFeatures` |
| endpoint_configuration | SetAdvancedFeatures | `EndpointConfiguration.SetAdvancedFeatures` |
| endpoint_configuration | UpdateCustomCollectionRule | `EndpointConfiguration.UpdateCustomCollectionRule` |
| endpoint_devices | InvokeAction | `EndpointDevices.InvokeAction` |
| endpoint_devices | SetAssetValue | `EndpointDevices.SetAssetValue` |
| endpoint_devices | SetCriticalityLevel | `EndpointDevices.SetCriticalityLevel` |
| endpoint_devices | SetExclusionState | `EndpointDevices.SetExclusionState` |
| endpoint_devices | SetRbacGroup | `EndpointDevices.SetRbacGroup` |
| endpoint_devices | SetTag | `EndpointDevices.SetTag` |
| exposure_management | RunHuntingQuery | `ExposureManagement.RunHuntingQuery` |
| files | CreateSampleCollectionRequest | `Files.CreateSampleCollectionRequest` |
| multi_tenant | RunHuntingQuery | `MultiTenant.RunHuntingQuery` |
| portal_services | InvokeAdminCommand | `PortalServices.InvokeAdminCommand` |
| threat_analytics | UpdateOutbreakUserState | `ThreatAnalytics.UpdateOutbreakUserState` |

## Unknown-classification endpoints (manual review needed)

_All unknowns auto-classified via semantic overrides._
