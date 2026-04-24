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

// --- Stream declarations — v0.1.0-beta.1: 45 data streams + 2 operational = 47 total ---
// Full removed-stream history (write endpoints, NO_PUBLIC_API, etc.) lives in
// docs/STREAMS-REMOVED.md. Do NOT inline removed stream names in this Bicep
// source — CI grep-gates the file against them.
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
  // P2 Governance (4) — see docs/STREAMS-REMOVED.md for removed write-endpoint history
  'MDE_RbacDeviceGroups_CL'
  'MDE_UnifiedRbacRoles_CL'
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

// Azure DCR has TWO interlocking quotas Microsoft enforces at preflight:
//   - max 10 dataFlows per rule
//   - max 20 streams per dataFlow
//
// v0.1.0-beta first compile: 47 dataFlows × 1 stream → tripped quota #1.
// v0.1.0-beta first fix:      1 dataFlow × 47 streams → tripped quota #2.
// Final shape: 3 dataFlows grouped by functional tier — each ≤ 20 streams,
// total ≤ 10 dataFlows. Still well under both quotas with headroom for
// future stream additions, and the grouping carries semantic meaning so an
// operator reading the DCR can see how streams cluster by purpose.
//
// `outputStream` is omitted on every dataFlow: each Custom-MDE_Foo_CL input
// routes by name to the like-named workspace table MDE_Foo_CL. Setting
// outputStream on a multi-stream dataFlow would COLLAPSE all streams into
// one output table — that would be a bug.
//
// Tier slices (kept explicit so a maintainer can audit composition trivially).
var p0Streams = [
  'Custom-MDE_AdvancedFeatures_CL'
  'Custom-MDE_PreviewFeatures_CL'
  'Custom-MDE_AuthenticatedTelemetry_CL'
  'Custom-MDE_PUAConfig_CL'
  'Custom-MDE_AntivirusPolicy_CL'
  'Custom-MDE_DeviceControlPolicy_CL'
  'Custom-MDE_WebContentFiltering_CL'
  'Custom-MDE_SmartScreenConfig_CL'
  'Custom-MDE_TenantAllowBlock_CL'
  'Custom-MDE_CustomCollection_CL'
  'Custom-MDE_LiveResponseConfig_CL'
  'Custom-MDE_AlertServiceConfig_CL'
  'Custom-MDE_AlertTuning_CL'
  'Custom-MDE_SuppressionRules_CL'
  'Custom-MDE_CustomDetections_CL'
]

var p1p2p3Streams = [
  // P1 Pipeline
  'Custom-MDE_DataExportSettings_CL'
  'Custom-MDE_StreamingApiConfig_CL'
  'Custom-MDE_IntuneConnection_CL'
  'Custom-MDE_PurviewSharing_CL'
  'Custom-MDE_ConnectedApps_CL'
  'Custom-MDE_TenantContext_CL'
  'Custom-MDE_TenantWorkloadStatus_CL'
  // P2 Governance
  'Custom-MDE_RbacDeviceGroups_CL'
  'Custom-MDE_UnifiedRbacRoles_CL'
  'Custom-MDE_AssetRules_CL'
  'Custom-MDE_SAClassification_CL'
  // P3 Exposure
  'Custom-MDE_XspmAttackPaths_CL'
  'Custom-MDE_XspmChokePoints_CL'
  'Custom-MDE_XspmTopTargets_CL'
  'Custom-MDE_XspmInitiatives_CL'
  'Custom-MDE_ExposureSnapshots_CL'
  'Custom-MDE_SecureScoreBreakdown_CL'
  'Custom-MDE_SecurityBaselines_CL'
  'Custom-MDE_ExposureRecommendations_CL'
]

var p5p6p7OpsStreams = [
  // P5 Identity
  'Custom-MDE_IdentityServiceAccounts_CL'
  'Custom-MDE_IdentityOnboarding_CL'
  'Custom-MDE_DCCoverage_CL'
  'Custom-MDE_IdentityAlertThresholds_CL'
  'Custom-MDE_RemediationAccounts_CL'
  // P6 Audit
  'Custom-MDE_ActionCenter_CL'
  'Custom-MDE_ThreatAnalytics_CL'
  // P7 Metadata
  'Custom-MDE_LicenseReport_CL'
  'Custom-MDE_UserPreferences_CL'
  'Custom-MDE_MtoTenants_CL'
  'Custom-MDE_CloudAppsConfig_CL'
  // Operational
  'Custom-MDE_Heartbeat_CL'
  'Custom-MDE_AuthTestResult_CL'
]

// transformKql is intentionally OMITTED on every dataFlow:
//   1. Microsoft DCR docs: "If you use a transformation, the data flow should
//      only use a single stream." Multi-stream + transform is invalid.
//   2. The transform `source | extend TimeGenerated = todatetime(TimeGenerated)`
//      is redundant — every streamDeclaration already declares TimeGenerated as
//      `datetime` type, so the column is already correctly typed at ingest.
var dataFlows = [
  {
    streams: p0Streams
    destinations: [ 'la-destination' ]
  }
  {
    streams: p1p2p3Streams
    destinations: [ 'la-destination' ]
  }
  {
    streams: p5p6p7OpsStreams
    destinations: [ 'la-destination' ]
  }
]

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
