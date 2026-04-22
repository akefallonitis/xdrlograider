@description('DCE name.')
param dceName string

@description('DCR name.')
param dcrName string

@description('Azure region.')
param location string

@description('Log Analytics workspace resource ID.')
param workspaceResourceId string

// --- Data Collection Endpoint ---
resource dce 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name: dceName
  location: location
  kind: 'Linux'
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

// --- Stream declarations for every MDE_*_CL table plus heartbeat + authtest ---
var streamNames = [
  // P0 Compliance (19)
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
  // P1 Pipeline (7)
  'MDE_DataExportSettings_CL'
  'MDE_StreamingApiConfig_CL'
  'MDE_IntuneConnection_CL'
  'MDE_PurviewSharing_CL'
  'MDE_ConnectedApps_CL'
  'MDE_TenantContext_CL'
  'MDE_TenantWorkloadStatus_CL'
  // P2 Governance (7)
  'MDE_RbacDeviceGroups_CL'
  'MDE_UnifiedRbacRoles_CL'
  'MDE_DeviceCriticality_CL'
  'MDE_CriticalAssets_CL'
  'MDE_AssetRules_CL'
  'MDE_SAClassification_CL'
  'MDE_ApprovalAssignments_CL'
  // P3 Exposure (8)
  'MDE_XspmAttackPaths_CL'
  'MDE_XspmChokePoints_CL'
  'MDE_XspmTopTargets_CL'
  'MDE_XspmInitiatives_CL'
  'MDE_ExposureSnapshots_CL'
  'MDE_SecureScoreBreakdown_CL'
  'MDE_SecurityBaselines_CL'
  'MDE_ExposureRecommendations_CL'
  // P5 Identity (5)
  'MDE_IdentityServiceAccounts_CL'
  'MDE_IdentityOnboarding_CL'
  'MDE_DCCoverage_CL'
  'MDE_IdentityAlertThresholds_CL'
  'MDE_RemediationAccounts_CL'
  // P6 Audit (2)
  'MDE_ActionCenter_CL'
  'MDE_ThreatAnalytics_CL'
  // P7 Metadata (4)
  'MDE_LicenseReport_CL'
  'MDE_UserPreferences_CL'
  'MDE_MtoTenants_CL'
  'MDE_CloudAppsConfig_CL'
  // Operational
  'MDE_Heartbeat_CL'
  'MDE_AuthTestResult_CL'
]

var streamDeclarations = toObject(streamNames, s => 'Custom-${s}', s => {
  columns: [
    { name: 'TimeGenerated', type: 'datetime' }
    { name: 'SourceStream', type: 'string' }
    { name: 'EntityId', type: 'string' }
    { name: 'RawJson', type: 'dynamic' }
  ]
})

var dataFlows = [for s in streamNames: {
  streams: [ 'Custom-${s}' ]
  destinations: [ 'la-destination' ]
  transformKql: 'source | extend TimeGenerated = todatetime(TimeGenerated)'
  outputStream: 'Custom-${s}'
}]

// --- Data Collection Rule ---
resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dcrName
  location: location
  properties: {
    dataCollectionEndpointId: dce.id
    streamDeclarations: streamDeclarations
    destinations: {
      logAnalytics: [
        {
          name: 'la-destination'
          workspaceResourceId: workspaceResourceId
        }
      ]
    }
    dataFlows: dataFlows
  }
}

output dceResourceId         string = dce.id
output dceIngestionEndpoint  string = dce.properties.logsIngestion.endpoint
output dcrResourceId         string = dcr.id
output dcrImmutableId        string = dcr.properties.immutableId
