@description('Log Analytics workspace name.')
param workspaceName string

@description('Retention (days).')
param retentionInDays int = 90

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
}

// 46 data tables + 2 operational tables = 48 total.
// (Was 45 data + 2 operational = 47 in v0.1.0-beta.1; subsequently dropped
// MDE_SecureScoreBreakdown_CL — Graph /security/secureScores covers — and
// added MDE_DeviceTimeline_CL + MDE_MachineActions_CL as portal-only surfaces
// not exposed by public Microsoft APIs.)
//
// Schema strategy: every non-deprecated table carries a typed-column schema
// derived from its manifest ProjectionMap (4 base columns +
// per-stream typed columns). The 1 deprecated stream
// (MDE_StreamingApiConfig_CL) keeps the 4-column baseline because it has no
// ProjectionMap entries to derive typed columns from. Heartbeat and
// AuthTestResult carry their own write-shape schemas — they're operational
// telemetry, not data rows.
//
// Each table's column list MUST match its DCR streamDeclaration in dce-dcr.bicep
// or the DCE silently drops typed columns at ingest. The DCR.TypedColumnCoverage
// test gate enforces this alignment against the manifest ProjectionMap.
//
// Full removed-stream history (write endpoints, NO_PUBLIC_API, publicly-API-covered)
// lives in docs/STREAMS-REMOVED.md. Do NOT inline removed stream names in this
// Bicep source — CI grep-gates the file against them.
var commonColumns = [
  { name: 'TimeGenerated', type: 'datetime' }
  { name: 'SourceStream',  type: 'string' }
  { name: 'EntityId',      type: 'string' }
  { name: 'RawJson',       type: 'dynamic' }
]

// Per-table typed-column schemas — same shape as DCR streamDeclarations
// (drop the 'Custom-' prefix used internally by the DCR).
var tableSchemas = {
  'MDE_ActionCenter_CL': [
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
  'MDE_AdvancedFeatures_CL': [
    { name: 'TimeGenerated',                 type: 'datetime' }
    { name: 'SourceStream',                  type: 'string' }
    { name: 'EntityId',                      type: 'string' }
    { name: 'RawJson',                       type: 'dynamic' }
    { name: 'AatpIntegrationEnabled',        type: 'boolean' }
    { name: 'AutoResolveInvestigatedAlerts', type: 'boolean' }
    { name: 'EnableMcasIntegration',         type: 'boolean' }
    { name: 'EnableWdavAntiTampering',       type: 'boolean' }
    { name: 'FeatureName',                   type: 'string' }
  ]
  'MDE_AlertServiceConfig_CL': [
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
  'MDE_AlertTuning_CL': [
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
  'MDE_AntivirusPolicy_CL': [
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
  'MDE_AssetRules_CL': [
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
  'MDE_AuthenticatedTelemetry_CL': [
    { name: 'TimeGenerated',     type: 'datetime' }
    { name: 'SourceStream',      type: 'string' }
    { name: 'EntityId',          type: 'string' }
    { name: 'RawJson',           type: 'dynamic' }
    { name: 'AllowNonAuthSense', type: 'boolean' }
    { name: 'FeatureName',       type: 'string' }
    { name: 'IsEnabled',         type: 'boolean' }
  ]
  'MDE_CloudAppsConfig_CL': [
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
  'MDE_ConnectedApps_CL': [
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
  'MDE_CustomCollection_CL': [
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
  'MDE_CustomDetections_CL': [
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
  'MDE_DataExportSettings_CL': [
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
  'MDE_DCCoverage_CL': [
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
  'MDE_DeviceControlPolicy_CL': [
    { name: 'TimeGenerated',  type: 'datetime' }
    { name: 'SourceStream',   type: 'string' }
    { name: 'EntityId',       type: 'string' }
    { name: 'RawJson',        type: 'dynamic' }
    { name: 'FeatureName',    type: 'string' }
    { name: 'HasPermissions', type: 'boolean' }
    { name: 'NotOnboarded',   type: 'int' }
    { name: 'Onboarded',      type: 'int' }
  ]
  'MDE_DeviceTimeline_CL': [
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
  'MDE_ExposureRecommendations_CL': [
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
  'MDE_ExposureSnapshots_CL': [
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
  'MDE_IdentityAlertThresholds_CL': [
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
  'MDE_IdentityOnboarding_CL': [
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
  'MDE_IdentityServiceAccounts_CL': [
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
  'MDE_IntuneConnection_CL': [
    { name: 'TimeGenerated', type: 'datetime' }
    { name: 'SourceStream',  type: 'string' }
    { name: 'EntityId',      type: 'string' }
    { name: 'RawJson',       type: 'dynamic' }
    { name: 'FeatureName',   type: 'string' }
    { name: 'IsEnabled',     type: 'boolean' }
    { name: 'Status',        type: 'int' }
  ]
  'MDE_LicenseReport_CL': [
    { name: 'TimeGenerated', type: 'datetime' }
    { name: 'SourceStream',  type: 'string' }
    { name: 'EntityId',      type: 'string' }
    { name: 'RawJson',       type: 'dynamic' }
    { name: 'DetectedUsers', type: 'int' }
    { name: 'DeviceCount',   type: 'int' }
    { name: 'SkuName',       type: 'string' }
  ]
  'MDE_LiveResponseConfig_CL': [
    { name: 'TimeGenerated',              type: 'datetime' }
    { name: 'SourceStream',               type: 'string' }
    { name: 'EntityId',                   type: 'string' }
    { name: 'RawJson',                    type: 'dynamic' }
    { name: 'AutomatedIrLiveResponse',    type: 'boolean' }
    { name: 'AutomatedIrUnsignedScripts', type: 'boolean' }
    { name: 'FeatureName',                type: 'string' }
    { name: 'LiveResponseForServers',     type: 'boolean' }
  ]
  'MDE_MachineActions_CL': [
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
  'MDE_MtoTenants_CL': [
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
  'MDE_PreviewFeatures_CL': [
    { name: 'TimeGenerated', type: 'datetime' }
    { name: 'SourceStream',  type: 'string' }
    { name: 'EntityId',      type: 'string' }
    { name: 'RawJson',       type: 'dynamic' }
    { name: 'IsOptIn',       type: 'boolean' }
    { name: 'SettingId',     type: 'string' }
    { name: 'SliceId',       type: 'int' }
  ]
  'MDE_PUAConfig_CL': [
    { name: 'TimeGenerated',                       type: 'datetime' }
    { name: 'SourceStream',                        type: 'string' }
    { name: 'EntityId',                            type: 'string' }
    { name: 'RawJson',                             type: 'dynamic' }
    { name: 'AutomatedIrPuaAsSuspicious',          type: 'boolean' }
    { name: 'FeatureName',                         type: 'string' }
    { name: 'IsAutomatedIrContainDeviceEnabled',   type: 'boolean' }
  ]
  'MDE_PurviewSharing_CL': [
    { name: 'TimeGenerated',       type: 'datetime' }
    { name: 'SourceStream',        type: 'string' }
    { name: 'EntityId',            type: 'string' }
    { name: 'RawJson',             type: 'dynamic' }
    { name: 'AlertSharingEnabled', type: 'boolean' }
    { name: 'FeatureName',         type: 'string' }
    { name: 'IsEnabled',           type: 'boolean' }
  ]
  'MDE_RbacDeviceGroups_CL': [
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
  'MDE_RemediationAccounts_CL': [
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
  'MDE_SAClassification_CL': [
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
  'MDE_SecurityBaselines_CL': [
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
  'MDE_SmartScreenConfig_CL': [
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
  // Deprecated stream — keeps the 4-col baseline (no ProjectionMap entries
  // to derive typed columns from).
  'MDE_StreamingApiConfig_CL': [
    { name: 'TimeGenerated', type: 'datetime' }
    { name: 'SourceStream',  type: 'string' }
    { name: 'EntityId',      type: 'string' }
    { name: 'RawJson',       type: 'dynamic' }
  ]
  'MDE_SuppressionRules_CL': [
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
  'MDE_TenantAllowBlock_CL': [
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
  'MDE_TenantContext_CL': [
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
  'MDE_TenantWorkloadStatus_CL': [
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
  'MDE_ThreatAnalytics_CL': [
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
  'MDE_UnifiedRbacRoles_CL': [
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
  'MDE_UserPreferences_CL': [
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
  'MDE_WebContentFiltering_CL': [
    { name: 'TimeGenerated',           type: 'datetime' }
    { name: 'SourceStream',            type: 'string' }
    { name: 'EntityId',                type: 'string' }
    { name: 'RawJson',                 type: 'dynamic' }
    { name: 'ActivityDeltaPercentage', type: 'int' }
    { name: 'CategoryName',            type: 'string' }
    { name: 'FeatureName',             type: 'string' }
    { name: 'TotalAccessRequests',     type: 'int' }
    { name: 'TotalBlockedCount',       type: 'int' }
    { name: 'UpdateTime',              type: 'datetime' }
  ]
  'MDE_XspmAttackPaths_CL': [
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
  'MDE_XspmChokePoints_CL': [
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
  'MDE_XspmInitiatives_CL': [
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
  'MDE_XspmTopTargets_CL': [
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

// Bicep can't iterate the keys of an object in a `for` loop without a helper.
// Use `items()` to materialize each entry as { key, value } and create one
// table resource per entry.
resource dataStreamTablesResource 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = [for tbl in items(tableSchemas): {
  name: tbl.key
  parent: workspace
  properties: {
    // Explicit plan: 'Analytics' (not default-relied) — Content Hub best
    // practice. 'Analytics' enables analytic rules + hunting queries; 'Basic'
    // blocks them. Default is Analytics today but make it explicit to prevent
    // accidental downgrade on future API versions.
    plan: 'Analytics'
    schema: {
      name: tbl.key
      columns: tbl.value
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
    plan: 'Analytics'
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
    plan: 'Analytics'
  }
}

output dataStreamTableCount int = length(items(tableSchemas))
output totalTableCount int = length(items(tableSchemas)) + 2
