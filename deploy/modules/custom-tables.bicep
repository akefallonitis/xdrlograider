@description('Log Analytics workspace name.')
param workspaceName string

@description('Retention (days).')
param retentionInDays int = 90

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
}

var commonColumns = [
  { name: 'TimeGenerated', type: 'datetime' }
  { name: 'SourceStream', type: 'string' }
  { name: 'EntityId', type: 'string' }
  { name: 'RawJson', type: 'dynamic' }
]

// All 55 data tables + 2 operational tables.
// Wider schemas are overlaid per-stream by the DCR's transformKql if useful;
// for v1.0 we keep a common lean schema and rely on RawJson for detail.
var tableNames = [
  'MDE_AdvancedFeatures_CL'
  'MDE_PreviewFeatures_CL'
  'MDE_AuthenticatedTelemetry_CL'
  'MDE_PUAConfig_CL'
  'MDE_AsrRulesConfig_CL'
  'MDE_AntivirusPolicy_CL'
  'MDE_AntiRansomwareConfig_CL'
  'MDE_ControlledFolderAccess_CL'
  'MDE_NetworkProtectionConfig_CL'
  'MDE_DeviceControlPolicy_CL'
  'MDE_WebContentFiltering_CL'
  'MDE_SmartScreenConfig_CL'
  'MDE_TenantAllowBlock_CL'
  'MDE_CustomCollection_CL'
  'MDE_LiveResponseConfig_CL'
  'MDE_AlertServiceConfig_CL'
  'MDE_AlertTuning_CL'
  'MDE_SuppressionRules_CL'
  'MDE_CustomDetections_CL'
  'MDE_DataExportSettings_CL'
  'MDE_StreamingApiConfig_CL'
  'MDE_IntuneConnection_CL'
  'MDE_PurviewSharing_CL'
  'MDE_ConnectedApps_CL'
  'MDE_TenantContext_CL'
  'MDE_TenantWorkloadStatus_CL'
  'MDE_RbacDeviceGroups_CL'
  'MDE_UnifiedRbacRoles_CL'
  'MDE_DeviceCriticality_CL'
  'MDE_CriticalAssets_CL'
  'MDE_AssetRules_CL'
  'MDE_SAClassification_CL'
  'MDE_ApprovalAssignments_CL'
  'MDE_XspmAttackPaths_CL'
  'MDE_XspmChokePoints_CL'
  'MDE_XspmTopTargets_CL'
  'MDE_XspmInitiatives_CL'
  'MDE_ExposureSnapshots_CL'
  'MDE_SecureScoreBreakdown_CL'
  'MDE_SecurityBaselines_CL'
  'MDE_ExposureRecommendations_CL'
  'MDE_IdentityServiceAccounts_CL'
  'MDE_IdentityOnboarding_CL'
  'MDE_DCCoverage_CL'
  'MDE_IdentityAlertThresholds_CL'
  'MDE_RemediationAccounts_CL'
  'MDE_ActionCenter_CL'
  'MDE_ThreatAnalytics_CL'
  'MDE_LicenseReport_CL'
  'MDE_UserPreferences_CL'
  'MDE_MtoTenants_CL'
  'MDE_CloudAppsConfig_CL'
  'MDE_Heartbeat_CL'
  'MDE_AuthTestResult_CL'
]

resource tables 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = [for tbl in tableNames: {
  name: tbl
  parent: workspace
  properties: {
    schema: {
      name: tbl
      columns: commonColumns
    }
    retentionInDays: retentionInDays
    totalRetentionInDays: retentionInDays
  }
}]

output tableCount int = length(tableNames)
