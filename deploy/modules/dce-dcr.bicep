@description('DCE name.')
param dceName string

@description('DCR name.')
param dcrName string

@description('Azure region.')
param location string

@description('Log Analytics workspace resource ID.')
param workspaceResourceId string

@description('Tags applied to every resource emitted by this module. The `environment` tag carries the env signal regardless of whether legacyEnvInName=true or false, so operators can filter by environment via Azure tag query.')
param tags object = {}

// --- Data Collection Endpoint ---
// Note: `kind` property omitted intentionally. It's an AMA-era label used to pair
// VM-based Azure Monitor Agent configs; our connector sends via the HTTPS Logs
// Ingestion API, which accepts regardless of `kind`. Omitting keeps the resource
// generic for both Linux- and Windows-hosted senders.
resource dce 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name: dceName
  location: location
  tags: tags
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

// --- Stream declarations — 46 data streams + 1 operational = 47 total ---
//
// Schema strategy: every non-deprecated stream carries a typed-column schema
// derived from its manifest ProjectionMap (4 base columns +
// per-stream typed columns). The 1 deprecated stream
// (MDE_StreamingApiConfig_CL) keeps the 4-column baseline because it has no
// ProjectionMap entries to derive typed columns from.
//
// Operators querying any data table get typed columns like
// `MDE_ActionCenter_CL | where ActionStatus == "Completed"` directly — no more
// `parse_json(RawJson) | extend …` boilerplate. Rows are typed at FA-side ingest
// (ConvertTo-MDEIngestRow honors the same ProjectionMap), so the DCR just needs
// to declare the matching columns or DCE silently drops them.
//
// The single operational stream (MDE_Heartbeat_CL) carries its own write-shape
// schema (no SourceStream/EntityId/RawJson — it's not a data row but
// connector-liveness telemetry). Auth chain diagnostics live in App Insights
// `customEvents` (AuthChain.* event names) instead of a dedicated workspace
// table.
//
// Full removed-stream history (write endpoints, NO_PUBLIC_API, publicly-API-covered)
// lives in docs/STREAMS-REMOVED.md. Do NOT inline removed stream names in this
// Bicep source — CI grep-gates the file against them.
var streamSchemas = {
  'Custom-MDE_ActionCenter_CL': {
    columns: [
      { name: 'TimeGenerated',     type: 'datetime' }
      { name: 'SourceStream',      type: 'string' }
      { name: 'EntityId',          type: 'string' }
      { name: 'RawJson',           type: 'dynamic' }
      { name: 'ActionDecision',    type: 'string' }
      { name: 'ActionId',          type: 'string' }
      { name: 'ActionSource',      type: 'string' }
      { name: 'ActionStatus',      type: 'string' }
      { name: 'ActionType',        type: 'string' }
      { name: 'Comment',           type: 'string' }
      { name: 'ComputerName',      type: 'string' }
      { name: 'EndTime',           type: 'datetime' }
      { name: 'EntityType',        type: 'string' }
      { name: 'EventTime',         type: 'datetime' }
      { name: 'InvestigationId',   type: 'string' }
      { name: 'MachineId',         type: 'string' }
      { name: 'Operator',          type: 'string' }
      { name: 'Product',           type: 'string' }
      { name: 'StartTime',         type: 'datetime' }
      { name: 'UserPrincipalName', type: 'string' }
    ]
  }
  'Custom-MDE_AdvancedFeatures_CL': {
    columns: [
      { name: 'TimeGenerated',                type: 'datetime' }
      { name: 'SourceStream',                 type: 'string' }
      { name: 'EntityId',                     type: 'string' }
      { name: 'RawJson',                      type: 'dynamic' }
      { name: 'AatpIntegrationEnabled',       type: 'boolean' }
      { name: 'AutoResolveInvestigatedAlerts', type: 'boolean' }
      { name: 'EnableMcasIntegration',        type: 'boolean' }
      { name: 'EnableWdavAntiTampering',      type: 'boolean' }
      { name: 'FeatureName',                  type: 'string' }
    ]
  }
  'Custom-MDE_AlertServiceConfig_CL': {
    columns: [
      { name: 'TimeGenerated',   type: 'datetime' }
      { name: 'SourceStream',    type: 'string' }
      { name: 'EntityId',        type: 'string' }
      { name: 'RawJson',         type: 'dynamic' }
      { name: 'IsEnabled',       type: 'boolean' }
      { name: 'LastModifiedUtc', type: 'datetime' }
      { name: 'ModifiedBy',      type: 'string' }
      { name: 'Name',            type: 'string' }
      { name: 'WorkloadId',      type: 'string' }
    ]
  }
  'Custom-MDE_AlertTuning_CL': {
    columns: [
      { name: 'TimeGenerated', type: 'datetime' }
      { name: 'SourceStream',  type: 'string' }
      { name: 'EntityId',      type: 'string' }
      { name: 'RawJson',       type: 'dynamic' }
      { name: 'CreatedBy',     type: 'string' }
      { name: 'CreatedTime',   type: 'datetime' }
      { name: 'IsEnabled',     type: 'boolean' }
      { name: 'Name',          type: 'string' }
      { name: 'RuleId',        type: 'string' }
      { name: 'Severity',      type: 'string' }
    ]
  }
  'Custom-MDE_AntivirusPolicy_CL': {
    columns: [
      { name: 'TimeGenerated', type: 'datetime' }
      { name: 'SourceStream',  type: 'string' }
      { name: 'EntityId',      type: 'string' }
      { name: 'RawJson',       type: 'dynamic' }
      { name: 'FilterName',    type: 'string' }
      { name: 'FilterValue',   type: 'string' }
      { name: 'IsEnabled',     type: 'boolean' }
      { name: 'Platform',      type: 'string' }
      { name: 'Scope',         type: 'string' }
    ]
  }
  'Custom-MDE_AssetRules_CL': {
    columns: [
      { name: 'TimeGenerated',        type: 'datetime' }
      { name: 'SourceStream',         type: 'string' }
      { name: 'EntityId',             type: 'string' }
      { name: 'RawJson',              type: 'dynamic' }
      { name: 'AffectedAssetsCount',  type: 'int' }
      { name: 'AssetType',            type: 'string' }
      { name: 'ClassificationValue',  type: 'string' }
      { name: 'CreatedBy',            type: 'string' }
      { name: 'CriticalityLevel',     type: 'int' }
      { name: 'Description',          type: 'string' }
      { name: 'IsEnabled',            type: 'boolean' }
      { name: 'Name',                 type: 'string' }
      { name: 'RuleId',               type: 'string' }
      { name: 'RuleType',             type: 'string' }
    ]
  }
  'Custom-MDE_AuthenticatedTelemetry_CL': {
    columns: [
      { name: 'TimeGenerated',     type: 'datetime' }
      { name: 'SourceStream',      type: 'string' }
      { name: 'EntityId',          type: 'string' }
      { name: 'RawJson',           type: 'dynamic' }
      { name: 'AllowNonAuthSense', type: 'boolean' }
      { name: 'FeatureName',       type: 'string' }
      { name: 'IsEnabled',         type: 'boolean' }
    ]
  }
  'Custom-MDE_CloudAppsConfig_CL': {
    columns: [
      { name: 'TimeGenerated', type: 'datetime' }
      { name: 'SourceStream',  type: 'string' }
      { name: 'EntityId',      type: 'string' }
      { name: 'RawJson',       type: 'dynamic' }
      { name: 'CreatedTime',   type: 'datetime' }
      { name: 'IsEnabled',     type: 'boolean' }
      { name: 'ModifiedBy',    type: 'string' }
      { name: 'Region',        type: 'string' }
      { name: 'SettingId',     type: 'string' }
    ]
  }
  'Custom-MDE_ConnectedApps_CL': {
    columns: [
      { name: 'TimeGenerated',      type: 'datetime' }
      { name: 'SourceStream',       type: 'string' }
      { name: 'EntityId',           type: 'string' }
      { name: 'RawJson',            type: 'dynamic' }
      { name: 'AppId',              type: 'string' }
      { name: 'IsEnabled',          type: 'boolean' }
      { name: 'LatestConnectivity', type: 'datetime' }
      { name: 'Name',               type: 'string' }
      { name: 'SettingsLink',       type: 'string' }
    ]
  }
  'Custom-MDE_CustomCollection_CL': {
    columns: [
      { name: 'TimeGenerated', type: 'datetime' }
      { name: 'SourceStream',  type: 'string' }
      { name: 'EntityId',      type: 'string' }
      { name: 'RawJson',       type: 'dynamic' }
      { name: 'CreatedBy',     type: 'string' }
      { name: 'CreatedTime',   type: 'datetime' }
      { name: 'IsEnabled',     type: 'boolean' }
      { name: 'Name',          type: 'string' }
      { name: 'RuleId',        type: 'string' }
      { name: 'Scope',         type: 'string' }
    ]
  }
  'Custom-MDE_CustomDetections_CL': {
    columns: [
      { name: 'TimeGenerated',   type: 'datetime' }
      { name: 'SourceStream',    type: 'string' }
      { name: 'EntityId',        type: 'string' }
      { name: 'RawJson',         type: 'dynamic' }
      { name: 'CreatedBy',       type: 'string' }
      { name: 'CreatedTime',     type: 'datetime' }
      { name: 'IsEnabled',       type: 'boolean' }
      { name: 'LastModifiedUtc', type: 'datetime' }
      { name: 'LastRunStatus',   type: 'string' }
      { name: 'Name',            type: 'string' }
      { name: 'RuleId',          type: 'string' }
      { name: 'Severity',        type: 'string' }
    ]
  }
  'Custom-MDE_DataExportSettings_CL': {
    columns: [
      { name: 'TimeGenerated',  type: 'datetime' }
      { name: 'SourceStream',   type: 'string' }
      { name: 'EntityId',       type: 'string' }
      { name: 'RawJson',        type: 'dynamic' }
      { name: 'ConfigId',       type: 'string' }
      { name: 'Destination',    type: 'string' }
      { name: 'EnabledLogs',    type: 'string' }
      { name: 'LogsCount',      type: 'int' }
      { name: 'ResourceGroup',  type: 'string' }
      { name: 'SubscriptionId', type: 'string' }
      { name: 'Workspace',      type: 'string' }
    ]
  }
  'Custom-MDE_DCCoverage_CL': {
    columns: [
      { name: 'TimeGenerated', type: 'datetime' }
      { name: 'SourceStream',  type: 'string' }
      { name: 'EntityId',      type: 'string' }
      { name: 'RawJson',       type: 'dynamic' }
      { name: 'DCName',        type: 'string' }
      { name: 'Domain',        type: 'string' }
      { name: 'IsActive',      type: 'boolean' }
      { name: 'LastSeenUtc',   type: 'datetime' }
      { name: 'Risk',          type: 'string' }
    ]
  }
  'Custom-MDE_DeviceControlPolicy_CL': {
    columns: [
      { name: 'TimeGenerated',  type: 'datetime' }
      { name: 'SourceStream',   type: 'string' }
      { name: 'EntityId',       type: 'string' }
      { name: 'RawJson',        type: 'dynamic' }
      { name: 'FeatureName',    type: 'string' }
      { name: 'HasPermissions', type: 'boolean' }
      { name: 'NotOnboarded',   type: 'int' }
      { name: 'Onboarded',      type: 'int' }
    ]
  }
  'Custom-MDE_DeviceTimeline_CL': {
    columns: [
      { name: 'TimeGenerated', type: 'datetime' }
      { name: 'SourceStream',  type: 'string' }
      { name: 'EntityId',      type: 'string' }
      { name: 'RawJson',       type: 'dynamic' }
      { name: 'EventId',       type: 'string' }
      { name: 'EventTime',     type: 'datetime' }
      { name: 'EventType',     type: 'string' }
      { name: 'FileName',      type: 'string' }
      { name: 'MachineId',     type: 'string' }
      { name: 'ProcessName',   type: 'string' }
      { name: 'Severity',      type: 'string' }
    ]
  }
  'Custom-MDE_ExposureRecommendations_CL': {
    columns: [
      { name: 'TimeGenerated',      type: 'datetime' }
      { name: 'SourceStream',       type: 'string' }
      { name: 'EntityId',           type: 'string' }
      { name: 'RawJson',            type: 'dynamic' }
      { name: 'Category',           type: 'string' }
      { name: 'ImplementationCost', type: 'string' }
      { name: 'IsDisabled',         type: 'boolean' }
      { name: 'LastSyncedUtc',      type: 'datetime' }
      { name: 'MaxScore',           type: 'real' }
      { name: 'Product',            type: 'string' }
      { name: 'RecommendationId',   type: 'string' }
      { name: 'Score',              type: 'real' }
      { name: 'Severity',           type: 'string' }
      { name: 'Source',             type: 'string' }
      { name: 'Status',             type: 'string' }
      { name: 'Title',              type: 'string' }
      { name: 'UserImpact',         type: 'string' }
    ]
  }
  'Custom-MDE_ExposureSnapshots_CL': {
    columns: [
      { name: 'TimeGenerated', type: 'datetime' }
      { name: 'SourceStream',  type: 'string' }
      { name: 'EntityId',      type: 'string' }
      { name: 'RawJson',       type: 'dynamic' }
      { name: 'CreatedTime',   type: 'datetime' }
      { name: 'InitiativeId',  type: 'string' }
      { name: 'MetricId',      type: 'string' }
      { name: 'Score',         type: 'real' }
      { name: 'ScoreChange',   type: 'real' }
      { name: 'SnapshotId',    type: 'string' }
    ]
  }
  'Custom-MDE_IdentityAlertThresholds_CL': {
    columns: [
      { name: 'TimeGenerated', type: 'datetime' }
      { name: 'SourceStream',  type: 'string' }
      { name: 'EntityId',      type: 'string' }
      { name: 'RawJson',       type: 'dynamic' }
      { name: 'AlertType',     type: 'string' }
      { name: 'ExpiresUtc',    type: 'datetime' }
      { name: 'IsEnabled',     type: 'boolean' }
      { name: 'ModifiedBy',    type: 'string' }
      { name: 'Threshold',     type: 'real' }
      { name: 'ThresholdId',   type: 'string' }
    ]
  }
  'Custom-MDE_IdentityOnboarding_CL': {
    columns: [
      { name: 'TimeGenerated', type: 'datetime' }
      { name: 'SourceStream',  type: 'string' }
      { name: 'EntityId',      type: 'string' }
      { name: 'RawJson',       type: 'dynamic' }
      { name: 'DCName',        type: 'string' }
      { name: 'Domain',        type: 'string' }
      { name: 'IpAddress',     type: 'string' }
      { name: 'IsActive',      type: 'boolean' }
      { name: 'LastSeenUtc',   type: 'datetime' }
      { name: 'SensorHealth',  type: 'string' }
    ]
  }
  'Custom-MDE_IdentityServiceAccounts_CL': {
    columns: [
      { name: 'TimeGenerated', type: 'datetime' }
      { name: 'SourceStream',  type: 'string' }
      { name: 'EntityId',      type: 'string' }
      { name: 'RawJson',       type: 'dynamic' }
      { name: 'AccountSid',    type: 'string' }
      { name: 'AccountType',   type: 'string' }
      { name: 'AccountUpn',    type: 'string' }
      { name: 'Domain',        type: 'string' }
      { name: 'IsActive',      type: 'boolean' }
      { name: 'LastSeenUtc',   type: 'datetime' }
      { name: 'Risk',          type: 'string' }
    ]
  }
  'Custom-MDE_IntuneConnection_CL': {
    columns: [
      { name: 'TimeGenerated', type: 'datetime' }
      { name: 'SourceStream',  type: 'string' }
      { name: 'EntityId',      type: 'string' }
      { name: 'RawJson',       type: 'dynamic' }
      { name: 'FeatureName',   type: 'string' }
      { name: 'IsEnabled',     type: 'boolean' }
      { name: 'Status',        type: 'int' }
    ]
  }
  'Custom-MDE_LicenseReport_CL': {
    columns: [
      { name: 'TimeGenerated', type: 'datetime' }
      { name: 'SourceStream',  type: 'string' }
      { name: 'EntityId',      type: 'string' }
      { name: 'RawJson',       type: 'dynamic' }
      { name: 'DetectedUsers', type: 'int' }
      { name: 'DeviceCount',   type: 'int' }
      { name: 'SkuName',       type: 'string' }
    ]
  }
  'Custom-MDE_LiveResponseConfig_CL': {
    columns: [
      { name: 'TimeGenerated',             type: 'datetime' }
      { name: 'SourceStream',              type: 'string' }
      { name: 'EntityId',                  type: 'string' }
      { name: 'RawJson',                   type: 'dynamic' }
      { name: 'AutomatedIrLiveResponse',   type: 'boolean' }
      { name: 'AutomatedIrUnsignedScripts', type: 'boolean' }
      { name: 'FeatureName',               type: 'string' }
      { name: 'LiveResponseForServers',    type: 'boolean' }
    ]
  }
  'Custom-MDE_MachineActions_CL': {
    columns: [
      { name: 'TimeGenerated',   type: 'datetime' }
      { name: 'SourceStream',    type: 'string' }
      { name: 'EntityId',        type: 'string' }
      { name: 'RawJson',         type: 'dynamic' }
      { name: 'ActionId',        type: 'string' }
      { name: 'ActionStatus',    type: 'string' }
      { name: 'ActionType',      type: 'string' }
      { name: 'CompletedTime',   type: 'datetime' }
      { name: 'CreatedTime',     type: 'datetime' }
      { name: 'InvestigationId', type: 'string' }
      { name: 'MachineId',       type: 'string' }
      { name: 'Operator',        type: 'string' }
      { name: 'ScriptOutput',    type: 'dynamic' }
    ]
  }
  'Custom-MDE_MtoTenants_CL': {
    columns: [
      { name: 'TimeGenerated',         type: 'datetime' }
      { name: 'SourceStream',          type: 'string' }
      { name: 'EntityId',              type: 'string' }
      { name: 'RawJson',               type: 'dynamic' }
      { name: 'IsHomeTenant',          type: 'boolean' }
      { name: 'IsSelected',            type: 'boolean' }
      { name: 'LostAccess',            type: 'boolean' }
      { name: 'TenantAadEnvironment',  type: 'int' }
      { name: 'TenantId',              type: 'string' }
      { name: 'TenantName',            type: 'string' }
    ]
  }
  'Custom-MDE_PreviewFeatures_CL': {
    columns: [
      { name: 'TimeGenerated', type: 'datetime' }
      { name: 'SourceStream',  type: 'string' }
      { name: 'EntityId',      type: 'string' }
      { name: 'RawJson',       type: 'dynamic' }
      { name: 'IsOptIn',       type: 'boolean' }
      { name: 'SettingId',     type: 'string' }
      { name: 'SliceId',       type: 'int' }
    ]
  }
  'Custom-MDE_PUAConfig_CL': {
    columns: [
      { name: 'TimeGenerated',                       type: 'datetime' }
      { name: 'SourceStream',                        type: 'string' }
      { name: 'EntityId',                            type: 'string' }
      { name: 'RawJson',                             type: 'dynamic' }
      { name: 'AutomatedIrPuaAsSuspicious',          type: 'boolean' }
      { name: 'FeatureName',                         type: 'string' }
      { name: 'IsAutomatedIrContainDeviceEnabled',   type: 'boolean' }
    ]
  }
  'Custom-MDE_PurviewSharing_CL': {
    columns: [
      { name: 'TimeGenerated',       type: 'datetime' }
      { name: 'SourceStream',        type: 'string' }
      { name: 'EntityId',            type: 'string' }
      { name: 'RawJson',             type: 'dynamic' }
      { name: 'AlertSharingEnabled', type: 'boolean' }
      { name: 'FeatureName',         type: 'string' }
      { name: 'IsEnabled',           type: 'boolean' }
    ]
  }
  'Custom-MDE_RbacDeviceGroups_CL': {
    columns: [
      { name: 'TimeGenerated',        type: 'datetime' }
      { name: 'SourceStream',         type: 'string' }
      { name: 'EntityId',             type: 'string' }
      { name: 'RawJson',              type: 'dynamic' }
      { name: 'AutoRemediationLevel', type: 'int' }
      { name: 'Description',          type: 'string' }
      { name: 'GroupId',              type: 'int' }
      { name: 'IsUnassigned',         type: 'boolean' }
      { name: 'LastUpdated',          type: 'datetime' }
      { name: 'MachineCount',         type: 'int' }
      { name: 'Name',                 type: 'string' }
      { name: 'Priority',             type: 'int' }
      { name: 'RuleCount',            type: 'int' }
    ]
  }
  'Custom-MDE_RemediationAccounts_CL': {
    columns: [
      { name: 'TimeGenerated', type: 'datetime' }
      { name: 'SourceStream',  type: 'string' }
      { name: 'EntityId',      type: 'string' }
      { name: 'RawJson',       type: 'dynamic' }
      { name: 'AccountType',   type: 'string' }
      { name: 'AccountUpn',    type: 'string' }
      { name: 'Domain',        type: 'string' }
      { name: 'IsActive',      type: 'boolean' }
      { name: 'LastSeenUtc',   type: 'datetime' }
    ]
  }
  'Custom-MDE_SAClassification_CL': {
    columns: [
      { name: 'TimeGenerated', type: 'datetime' }
      { name: 'SourceStream',  type: 'string' }
      { name: 'EntityId',      type: 'string' }
      { name: 'RawJson',       type: 'dynamic' }
      { name: 'AccountType',   type: 'string' }
      { name: 'Domain',        type: 'string' }
      { name: 'IsActive',      type: 'boolean' }
      { name: 'LastSeenUtc',   type: 'datetime' }
      { name: 'Name',          type: 'string' }
      { name: 'RuleId',        type: 'string' }
    ]
  }
  'Custom-MDE_SecurityBaselines_CL': {
    columns: [
      { name: 'TimeGenerated', type: 'datetime' }
      { name: 'SourceStream',  type: 'string' }
      { name: 'EntityId',      type: 'string' }
      { name: 'RawJson',       type: 'dynamic' }
      { name: 'BenchmarkName', type: 'string' }
      { name: 'Compliance',    type: 'boolean' }
      { name: 'DeviceCount',   type: 'int' }
      { name: 'LastScanUtc',   type: 'datetime' }
      { name: 'Name',          type: 'string' }
      { name: 'ProfileId',     type: 'string' }
      { name: 'Score',         type: 'real' }
    ]
  }
  'Custom-MDE_SmartScreenConfig_CL': {
    columns: [
      { name: 'TimeGenerated',   type: 'datetime' }
      { name: 'SourceStream',    type: 'string' }
      { name: 'EntityId',        type: 'string' }
      { name: 'RawJson',         type: 'dynamic' }
      { name: 'CustomIndicator', type: 'int' }
      { name: 'Exploit',         type: 'int' }
      { name: 'FeatureName',     type: 'string' }
      { name: 'LastModifiedUtc', type: 'datetime' }
      { name: 'Malicious',       type: 'int' }
      { name: 'Phishing',        type: 'int' }
      { name: 'TotalThreats',    type: 'int' }
    ]
  }
  // Deprecated stream — keeps the 4-col baseline (no ProjectionMap entries
  // to derive typed columns from). Operators should not query this stream.
  'Custom-MDE_StreamingApiConfig_CL': {
    columns: [
      { name: 'TimeGenerated', type: 'datetime' }
      { name: 'SourceStream',  type: 'string' }
      { name: 'EntityId',      type: 'string' }
      { name: 'RawJson',       type: 'dynamic' }
    ]
  }
  'Custom-MDE_SuppressionRules_CL': {
    columns: [
      { name: 'TimeGenerated',       type: 'datetime' }
      { name: 'SourceStream',        type: 'string' }
      { name: 'EntityId',            type: 'string' }
      { name: 'RawJson',             type: 'dynamic' }
      { name: 'Action',              type: 'int' }
      { name: 'AlertTitle',          type: 'string' }
      { name: 'CreatedBy',           type: 'string' }
      { name: 'CreatedTime',         type: 'datetime' }
      { name: 'IsEnabled',           type: 'boolean' }
      { name: 'IsReadOnly',          type: 'boolean' }
      { name: 'MatchingAlertsCount', type: 'int' }
      { name: 'Name',                type: 'string' }
      { name: 'RuleId',              type: 'string' }
      { name: 'Scope',               type: 'int' }
      { name: 'UpdateTime',          type: 'datetime' }
    ]
  }
  'Custom-MDE_TenantAllowBlock_CL': {
    columns: [
      { name: 'TimeGenerated', type: 'datetime' }
      { name: 'SourceStream',  type: 'string' }
      { name: 'EntityId',      type: 'string' }
      { name: 'RawJson',       type: 'dynamic' }
      { name: 'Action',        type: 'string' }
      { name: 'CreatedBy',     type: 'string' }
      { name: 'CreatedTime',   type: 'datetime' }
      { name: 'ExpiryTime',    type: 'datetime' }
      { name: 'IndicatorType', type: 'string' }
    ]
  }
  'Custom-MDE_TenantContext_CL': {
    columns: [
      { name: 'TimeGenerated',    type: 'datetime' }
      { name: 'SourceStream',     type: 'string' }
      { name: 'EntityId',         type: 'string' }
      { name: 'RawJson',          type: 'dynamic' }
      { name: 'AccountType',      type: 'string' }
      { name: 'DataCenter',       type: 'string' }
      { name: 'EnvironmentName',  type: 'string' }
      { name: 'IsHomeTenant',     type: 'boolean' }
      { name: 'IsMdatpActive',    type: 'boolean' }
      { name: 'IsSentinelActive', type: 'boolean' }
      { name: 'Region',           type: 'string' }
      { name: 'TenantId',         type: 'string' }
      { name: 'TenantName',       type: 'string' }
    ]
  }
  'Custom-MDE_TenantWorkloadStatus_CL': {
    columns: [
      { name: 'TimeGenerated',    type: 'datetime' }
      { name: 'SourceStream',     type: 'string' }
      { name: 'EntityId',         type: 'string' }
      { name: 'RawJson',          type: 'dynamic' }
      { name: 'AllTenantsCount',  type: 'int' }
      { name: 'CreatedTime',      type: 'datetime' }
      { name: 'EntityType',       type: 'string' }
      { name: 'LastUpdated',      type: 'datetime' }
      { name: 'LastUpdatedByUpn', type: 'string' }
      { name: 'TenantGroupId',    type: 'string' }
      { name: 'TenantId',         type: 'string' }
      { name: 'TenantName',       type: 'string' }
    ]
  }
  'Custom-MDE_ThreatAnalytics_CL': {
    columns: [
      { name: 'TimeGenerated', type: 'datetime' }
      { name: 'SourceStream',  type: 'string' }
      { name: 'EntityId',      type: 'string' }
      { name: 'RawJson',       type: 'dynamic' }
      { name: 'CreatedOn',     type: 'datetime' }
      { name: 'IsVNext',       type: 'boolean' }
      { name: 'Keywords',      type: 'string' }
      { name: 'LastUpdatedOn', type: 'datetime' }
      { name: 'LastVisitTime', type: 'datetime' }
      { name: 'OutbreakId',    type: 'string' }
      { name: 'ReportType',    type: 'string' }
      { name: 'Severity',      type: 'int' }
      { name: 'StartedOn',     type: 'datetime' }
      { name: 'Tags',          type: 'string' }
      { name: 'Title',         type: 'string' }
    ]
  }
  'Custom-MDE_UnifiedRbacRoles_CL': {
    columns: [
      { name: 'TimeGenerated', type: 'datetime' }
      { name: 'SourceStream',  type: 'string' }
      { name: 'EntityId',      type: 'string' }
      { name: 'RawJson',       type: 'dynamic' }
      { name: 'CreatedTime',   type: 'datetime' }
      { name: 'IsBuiltIn',     type: 'boolean' }
      { name: 'ModifiedBy',    type: 'string' }
      { name: 'Name',          type: 'string' }
      { name: 'RoleId',        type: 'string' }
      { name: 'Scope',         type: 'string' }
    ]
  }
  'Custom-MDE_UserPreferences_CL': {
    columns: [
      { name: 'TimeGenerated', type: 'datetime' }
      { name: 'SourceStream',  type: 'string' }
      { name: 'EntityId',      type: 'string' }
      { name: 'RawJson',       type: 'dynamic' }
      { name: 'CreatedBy',     type: 'string' }
      { name: 'CreatedTime',   type: 'datetime' }
      { name: 'IsEnabled',     type: 'boolean' }
      { name: 'Name',          type: 'string' }
      { name: 'Scope',         type: 'string' }
      { name: 'SettingId',     type: 'string' }
    ]
  }
  'Custom-MDE_WebContentFiltering_CL': {
    columns: [
      { name: 'TimeGenerated',          type: 'datetime' }
      { name: 'SourceStream',           type: 'string' }
      { name: 'EntityId',               type: 'string' }
      { name: 'RawJson',                type: 'dynamic' }
      { name: 'ActivityDeltaPercentage', type: 'int' }
      { name: 'CategoryName',           type: 'string' }
      { name: 'FeatureName',            type: 'string' }
      { name: 'TotalAccessRequests',    type: 'int' }
      { name: 'TotalBlockedCount',      type: 'int' }
      { name: 'UpdateTime',             type: 'datetime' }
    ]
  }
  'Custom-MDE_XspmAttackPaths_CL': {
    columns: [
      { name: 'TimeGenerated', type: 'datetime' }
      { name: 'SourceStream',  type: 'string' }
      { name: 'EntityId',      type: 'string' }
      { name: 'RawJson',       type: 'dynamic' }
      { name: 'CreatedTime',   type: 'datetime' }
      { name: 'HopCount',      type: 'int' }
      { name: 'PathId',        type: 'string' }
      { name: 'Severity',      type: 'string' }
      { name: 'Source',        type: 'string' }
      { name: 'SourceId',      type: 'string' }
      { name: 'Status',        type: 'string' }
      { name: 'Target',        type: 'string' }
      { name: 'TargetId',      type: 'string' }
    ]
  }
  'Custom-MDE_XspmChokePoints_CL': {
    columns: [
      { name: 'TimeGenerated',    type: 'datetime' }
      { name: 'SourceStream',     type: 'string' }
      { name: 'EntityId',         type: 'string' }
      { name: 'RawJson',          type: 'dynamic' }
      { name: 'AttackPathsCount', type: 'int' }
      { name: 'EntityType',       type: 'string' }
      { name: 'NodeId',           type: 'string' }
      { name: 'NodeName',         type: 'string' }
      { name: 'NodeType',         type: 'string' }
      { name: 'Severity',         type: 'string' }
    ]
  }
  'Custom-MDE_XspmInitiatives_CL': {
    columns: [
      { name: 'TimeGenerated',     type: 'datetime' }
      { name: 'SourceStream',      type: 'string' }
      { name: 'EntityId',          type: 'string' }
      { name: 'RawJson',           type: 'dynamic' }
      { name: 'ActiveMetricCount', type: 'int' }
      { name: 'InitiativeId',      type: 'string' }
      { name: 'IsFavorite',        type: 'boolean' }
      { name: 'MetricCount',       type: 'int' }
      { name: 'Name',              type: 'string' }
      { name: 'Programs',          type: 'string' }
      { name: 'TargetValue',       type: 'real' }
    ]
  }
  'Custom-MDE_XspmTopTargets_CL': {
    columns: [
      { name: 'TimeGenerated',    type: 'datetime' }
      { name: 'SourceStream',     type: 'string' }
      { name: 'EntityId',         type: 'string' }
      { name: 'RawJson',          type: 'dynamic' }
      { name: 'AttackPathsCount', type: 'int' }
      { name: 'Source',           type: 'string' }
      { name: 'Status',           type: 'string' }
      { name: 'TargetId',         type: 'string' }
      { name: 'TargetName',       type: 'string' }
    ]
  }
}

// Heartbeat stream — operational telemetry, no SourceStream/EntityId/RawJson
// (Write-Heartbeat does not produce data rows; it produces tier roll-ups).
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

var streamDeclarations = union(streamSchemas, heartbeatDecl)

// Azure DCR has TWO interlocking quotas Microsoft enforces at preflight:
//   - max 10 dataFlows per rule
//   - max 20 streams per dataFlow
//
// v0.1.0-beta first compile: 47 dataFlows × 1 stream → tripped quota #1.
// v0.1.0-beta first fix:      1 dataFlow × 47 streams → tripped quota #2.
// (Current shape: 47 streams = 46 data + 1 system; same 3-flow grouping.)
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
  // P3 Exposure — MDE_SecureScoreBreakdown_CL dropped (Graph /security/secureScores covers)
  'Custom-MDE_XspmAttackPaths_CL'
  'Custom-MDE_XspmChokePoints_CL'
  'Custom-MDE_XspmTopTargets_CL'
  'Custom-MDE_XspmInitiatives_CL'
  'Custom-MDE_ExposureSnapshots_CL'
  'Custom-MDE_SecurityBaselines_CL'
  'Custom-MDE_ExposureRecommendations_CL'
  'Custom-MDE_DeviceTimeline_CL'
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
  'Custom-MDE_MachineActions_CL'
  // P7 Metadata
  'Custom-MDE_LicenseReport_CL'
  'Custom-MDE_UserPreferences_CL'
  'Custom-MDE_MtoTenants_CL'
  'Custom-MDE_CloudAppsConfig_CL'
  // Operational
  'Custom-MDE_Heartbeat_CL'
]

// transformKql is intentionally OMITTED on every dataFlow:
//   1. Microsoft DCR docs: "If you use a transformation, the data flow should
//      only use a single stream." Multi-stream + transform is invalid.
//   2. Each streamDeclaration already declares typed columns matching the
//      ConvertTo-MDEIngestRow row shape, so the DCE accepts and persists rows
//      without any transform. A `source | extend Foo = todatetime(Foo)`
//      transform would be redundant — the Foo column is already typed at
//      ingest. The FA-side projection is the authoritative path; transformKql
//      is reserved for cases where the FA cannot produce a typed column.
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
  tags: tags
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
