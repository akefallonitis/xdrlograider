# XdrLogRaider Wiring Matrix

Generated: 2026-05-09 05:13:57 +01:00

Total streams: 68  |  Full edges: 64  |  Missing/warning: 4

## Edge legend

| Edge | Description |
|------|-------------|
| E1   | Manifest entry has Stream/Path/Tier/Category/CategoryId/Purpose/Availability + ProjectionMap >=3 (non-deprecated) |
| E2   | tests/fixtures/live-responses/<Stream>-raw.json present |
| E3   | DCR streamDeclaration Custom-<Stream> in exactly one DCR |
| E4   | DCR dataFlow with outputStream=Custom-Defender_<Cat>_CL + transformKql injects SourceName |
| E5   | DCR_IMMUTABLE_IDS_JSON env-var maps stream to its DCR immutableId |
| E6   | Workspace category table Defender_<Cat>_CL declared in customTables nested deploy |
| E7   | Drift parser tier-file references the stream (or correctly absent for ActionCenter / deprecated) |
| E8   | At least one Sentinel content artifact references the stream |
| E9   | Function timer (function.json) for the tier has a non-empty description |
| E10  | Test coverage: parsing pipeline test or live fixture present |
| E11  | RawJson preserved per row (_EndpointHelpers.ps1) |
| E12  | docs/STREAMS.md or STREAMS-MATRIX.md references the stream |

## Per-stream wiring matrix

| Stream | Tier | Avail | E1 | E2 | E3 | E4 | E5 | E6 | E7 | E8 | E9 | E10 | E11 | E12 |
|--------|------|-------|----|----|----|----|----|----|----|----|----|-----|-----|-----|
| MDE_AdvancedFeatures_CL | Inventory | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_PreviewFeatures_CL | Configuration | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_AlertServiceConfig_CL | Configuration | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_AlertTuning_CL | Configuration | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_SuppressionRules_CL | Configuration | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_CustomDetections_CL | Configuration | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_DeviceControlPolicy_CL | Inventory | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_WebContentFiltering_CL | Inventory | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_SmartScreenConfig_CL | Inventory | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_LiveResponseConfig_CL | Inventory | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_AuthenticatedTelemetry_CL | Inventory | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_PUAConfig_CL | Inventory | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_AntivirusPolicy_CL | Inventory | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_SecurityPolicies_CL | Inventory | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_TenantAllowBlock_CL | Configuration | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_CustomCollection_CL | Inventory | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_DataExportSettings_CL | Maintenance | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_ConnectedApps_CL | Configuration | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_TenantContext_CL | Inventory | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_TenantWorkloadStatus_CL | Inventory | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_StreamingApiConfig_CL | Maintenance | deprecated | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_IntuneConnection_CL | Configuration | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_PurviewSharing_CL | Configuration | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_RbacDeviceGroups_CL | Configuration | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_UnifiedRbacRoles_CL | Configuration | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_AssetRules_CL | XspmGraph | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_SAClassification_CL | Inventory | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_XspmInitiatives_CL | XspmGraph | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_ExposureSnapshots_CL | XspmGraph | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_ExposureRecommendations_CL | XspmGraph | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_XspmAttackPaths_CL | XspmGraph | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_XspmChokePoints_CL | XspmGraph | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_XspmTopTargets_CL | XspmGraph | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_SecurityBaselines_CL | Inventory | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_VulnerableMachines_CL | Inventory | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_VulnerabilityInventory_CL | Inventory | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_SoftwareInventory_CL | Inventory | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_RecommendationActions_CL | Inventory | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_IdentityOnboarding_CL | Inventory | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_IdentityServiceAccounts_CL | Inventory | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_VulnerabilityCertificates_CL | Inventory | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_IdentityLateralMovementPaths_CL | XspmGraph | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_IdentityDormantAccounts_CL | Configuration | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_DCCoverage_CL | Inventory | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_IdentityAlertThresholds_CL | Inventory | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_RemediationAccounts_CL | Inventory | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_ActionCenter_CL | ActionCenter | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_PendingActions_CL | ActionCenter | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_ThreatAnalytics_CL | Configuration | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_UserPreferences_CL | Configuration | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_MtoTenants_CL | Inventory | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_LicenseReport_CL | Inventory | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_Machines_CL | Inventory | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_CloudAppsConfig_CL | Configuration | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_DeviceTimeline_CL | ActionCenter | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_AssetClassificationSchema_CL | XspmGraph | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_PostureInitiativesSummarized_CL | XspmGraph | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_PostureMetrics_CL | XspmGraph | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_AppsSecureScore_CL | XspmGraph | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_DataSecureScore_CL | XspmGraph | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_IdentitySecureScore_CL | XspmGraph | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_PostureSecurityEvents_CL | XspmGraph | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_PostureTenants_CL | XspmGraph | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_AttackSurfaceAttackPaths_CL | XspmGraph | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_AttackSurfaceChokepoints_CL | XspmGraph | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_XspmConnectors_CL | XspmGraph | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_ThreatAnalyticsEnriched_CL | Configuration | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |
| MDE_ThreatAnalyticsTopThreats_CL | Configuration | live | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK | OK |

## Issues (all warnings + errors)

### MDE_VulnerabilityCertificates_CL [Tier=Inventory Avail=live]
  - E8: WARNING no Sentinel content references MDE_VulnerabilityCertificates_CL (incremental — non-blocking)

### MDE_IdentityLateralMovementPaths_CL [Tier=XspmGraph Avail=live]
  - E8: WARNING no Sentinel content references MDE_IdentityLateralMovementPaths_CL (incremental — non-blocking)

### MDE_IdentityDormantAccounts_CL [Tier=Configuration Avail=live]
  - E8: WARNING no Sentinel content references MDE_IdentityDormantAccounts_CL (incremental — non-blocking)

### MDE_PendingActions_CL [Tier=ActionCenter Avail=live]
  - E8: WARNING no Sentinel content references MDE_PendingActions_CL (incremental — non-blocking)

