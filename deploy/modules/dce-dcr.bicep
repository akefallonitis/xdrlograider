@description('DCE name.')
param dceName string

@description('DCR name.')
param dcrName string

@description('Azure region.')
param location string

@description('Log Analytics workspace resource ID.')
param workspaceResourceId string

// --- Data Collection Endpoint ---
// Note: `kind` property omitted intentionally. It's an AMA-era label used to pair
// VM-based Azure Monitor Agent configs; our connector sends via the HTTPS Logs
// Ingestion API, which accepts regardless of `kind`. Omitting keeps the resource
// generic for both Linux- and Windows-hosted senders.
resource dce 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name: dceName
  location: location
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

// --- Stream declarations — v1.0.2: 47 data streams + 2 operational = 49 total ---
// Removed in v1.0.2 (NO_PUBLIC_API): AsrRulesConfig, AntiRansomwareConfig,
// ControlledFolderAccess, NetworkProtectionConfig, ApprovalAssignments.
var dataStreamNames = [
  // P0 Compliance (15)
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
  // P1 Pipeline (7)
  'MDE_DataExportSettings_CL'
  'MDE_StreamingApiConfig_CL'
  'MDE_IntuneConnection_CL'
  'MDE_PurviewSharing_CL'
  'MDE_ConnectedApps_CL'
  'MDE_TenantContext_CL'
  'MDE_TenantWorkloadStatus_CL'
  // P2 Governance (6)
  'MDE_RbacDeviceGroups_CL'
  'MDE_UnifiedRbacRoles_CL'
  'MDE_DeviceCriticality_CL'
  'MDE_CriticalAssets_CL'
  'MDE_AssetRules_CL'
  'MDE_SAClassification_CL'
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
]

// Baseline 4-column schema for all data streams (flattening handled in FA).
var dataStreamDecls = toObject(dataStreamNames, s => 'Custom-${s}', s => {
  columns: [
    { name: 'TimeGenerated', type: 'datetime' }
    { name: 'SourceStream',  type: 'string' }
    { name: 'EntityId',      type: 'string' }
    { name: 'RawJson',       type: 'dynamic' }
  ]
})

// Heartbeat stream — extended schema matching Write-Heartbeat emission.
var heartbeatDecl = {
  'Custom-MDE_Heartbeat_CL': {
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
}

// AuthTestResult stream — extended schema matching Write-AuthTestResult emission.
var authTestResultDecl = {
  'Custom-MDE_AuthTestResult_CL': {
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
}

var streamDeclarations = union(dataStreamDecls, heartbeatDecl, authTestResultDecl)

var allStreamNames = concat(dataStreamNames, [ 'MDE_Heartbeat_CL', 'MDE_AuthTestResult_CL' ])

var dataFlows = [for s in allStreamNames: {
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
