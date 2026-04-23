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

// v1.0.2: 47 data tables + 2 operational tables = 49 total.
// Removed from v1.0.1 (5 streams, NO_PUBLIC_API): MDE_AsrRulesConfig_CL,
// MDE_AntiRansomwareConfig_CL, MDE_ControlledFolderAccess_CL,
// MDE_NetworkProtectionConfig_CL, MDE_ApprovalAssignments_CL.
// Reason: no portal API exists; these features are only in Intune/Graph scope.
// See src/Modules/XdrLogRaider.Client/endpoints.manifest.psd1 header for full audit.
//
// Schema strategy: common 4-column baseline for data streams (TimeGenerated,
// SourceStream, EntityId, RawJson). Heartbeat + AuthTestResult get extended
// schemas below because Write-Heartbeat / Write-AuthTestResult emit more fields.
var dataStreamTables = [
  'MDE_AdvancedFeatures_CL'
  'MDE_PreviewFeatures_CL'
  'MDE_AuthenticatedTelemetry_CL'
  'MDE_PUAConfig_CL'
  'MDE_AntivirusPolicy_CL'
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
]

resource dataStreamTablesResource 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = [for tbl in dataStreamTables: {
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

// Heartbeat table — extended schema matching Write-Heartbeat output.
// Write-Heartbeat emits: TimeGenerated, FunctionName, Tier, StreamsAttempted,
// StreamsSucceeded, RowsIngested, LatencyMs, HostName, Notes (dynamic).
resource heartbeatTable 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = {
  name: 'MDE_Heartbeat_CL'
  parent: workspace
  properties: {
    schema: {
      name: 'MDE_Heartbeat_CL'
      columns: [
        { name: 'TimeGenerated',    type: 'datetime' }
        { name: 'FunctionName',     type: 'string' }
        { name: 'Tier',             type: 'string' }
        { name: 'StreamsAttempted', type: 'int' }
        { name: 'StreamsSucceeded', type: 'int' }
        { name: 'RowsIngested',     type: 'int' }
        { name: 'LatencyMs',        type: 'int' }
        { name: 'HostName',         type: 'string' }
        { name: 'Notes',            type: 'dynamic' }
      ]
    }
    retentionInDays: retentionInDays
    totalRetentionInDays: retentionInDays
  }
}

// AuthTestResult table — extended schema matching Write-AuthTestResult output.
// Fields per src/Modules/XdrLogRaider.Ingest/Public/Write-AuthTestResult.ps1:
//   TimeGenerated, Method, PortalHost, Upn, Success, Stage, FailureReason,
//   EstsMs, SccauthMs, SampleCallHttpCode, SampleCallLatencyMs, SccauthAcquiredUtc.
resource authTestResultTable 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = {
  name: 'MDE_AuthTestResult_CL'
  parent: workspace
  properties: {
    schema: {
      name: 'MDE_AuthTestResult_CL'
      columns: [
        { name: 'TimeGenerated',       type: 'datetime' }
        { name: 'Method',              type: 'string' }
        { name: 'PortalHost',          type: 'string' }
        { name: 'Upn',                 type: 'string' }
        { name: 'Success',             type: 'boolean' }
        { name: 'Stage',               type: 'string' }
        { name: 'FailureReason',       type: 'string' }
        { name: 'EstsMs',              type: 'int' }
        { name: 'SccauthMs',           type: 'int' }
        { name: 'SampleCallHttpCode',  type: 'int' }
        { name: 'SampleCallLatencyMs', type: 'int' }
        { name: 'SccauthAcquiredUtc',  type: 'string' }
      ]
    }
    retentionInDays: retentionInDays
    totalRetentionInDays: retentionInDays
  }
}

output dataStreamTableCount int = length(dataStreamTables)
output totalTableCount int = length(dataStreamTables) + 2
