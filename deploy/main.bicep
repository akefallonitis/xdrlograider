// XdrLogRaider — main deployment template.
//
// Topology (v0.1.0-beta): the customer ALREADY HAS a Sentinel-enabled Log
// Analytics workspace. This template does NOT create or modify the workspace
// itself. It deploys:
//   - Connector resources in the target RG (Function App + plan + KV + Storage + App Insights + DCE + DCR)
//   - 47 custom tables (45 data + Heartbeat + AuthTestResult) inside the customer's workspace (cross-RG if needed)
//   - A Sentinel Solution package (XdrLogRaider) + StaticUI Data Connector card so the connector
//     appears in Sentinel → Data Connectors alongside Microsoft Defender XDR / MDE / etc.
//   - Sentinel content (parsers + 14 analytic rules + 9 hunting queries + 6 workbooks)
//     when deploySentinelContent=true (default)
//
// Cross-RG / cross-region is supported: the workspace can live in any RG of any subscription
// in the same tenant. DCE + DCR are created in the workspace's region (regional constraint of
// Azure Monitor Logs Ingestion API). Connector resources (FA, KV, Storage, AI) live in the
// target RG's region — they don't share the workspace's regional constraint.

targetScope = 'resourceGroup'

// ============================================================================
// PARAMETERS — all wizard-surfaced
// ============================================================================

@description('Project prefix — used in resource names. 3-12 lowercase alphanumeric.')
@minLength(3)
@maxLength(12)
param projectPrefix string = 'xdrlr'

@description('Environment tag. Used in resource names.')
@allowed([ 'dev', 'staging', 'prod' ])
param env string = 'prod'

@description('Region for connector resources (Function App, KV, Storage, App Insights). Defaults to the target RG region.')
param connectorLocation string = resourceGroup().location

@description('REQUIRED: Full ARM resource ID of the existing Sentinel-enabled Log Analytics workspace. The workspace must exist before deployment. Can be in any RG of any subscription in the same tenant.')
@minLength(1)
param existingWorkspaceId string

@description('REQUIRED: Azure region of the existing workspace. DCE + DCR MUST be in this region (regional constraint of Azure Monitor). Example: eastus, westeurope.')
@minLength(1)
param workspaceLocation string

@description('UPN of the dedicated service account the connector authenticates AS. Must be read-only: Security Reader + MDE Analyst roles.')
param serviceAccountUpn string

@description('Auth method the connector uses for portal sign-in. Both are unattended and auto-refreshing.')
@allowed([ 'credentials_totp', 'passkey' ])
param authMethod string = 'credentials_totp'

@description('Function App plan SKU. Y1 = Consumption (recommended; free tier for typical workload).')
@allowed([ 'Y1', 'EP1', 'EP2' ])
param functionPlanSku string = 'Y1'

@description('Function App code version. "latest" pulls newest GitHub Release; or pin with v1.0.0.')
param functionAppZipVersion string = 'latest'

@description('GitHub repo owner/name for the Function App code ZIP. Override only if you forked.')
param githubRepo string = 'akefallonitis/xdrlograider'

@description('Deploy Sentinel content (parsers/hunting/analytic rules/workbooks). Set false for connector-only deploys.')
param deploySentinelContent bool = true

@description('Optional. Service account password (credentials_totp method). Empty = upload via post-deploy script.')
@secure()
param servicePassword string = ''

@description('Optional. TOTP Base32 seed (credentials_totp method). Empty = upload via post-deploy script or no MFA.')
@secure()
param totpSeed string = ''

@description('Optional. Passkey JSON blob (passkey method). Empty = upload via post-deploy script.')
@secure()
param passkeyJson string = ''

// ============================================================================
// DERIVED VARIABLES
// ============================================================================

var uniq      = uniqueString(resourceGroup().id, projectPrefix, env)
var suffix    = substring(uniq, 0, 6)
var prefix    = '${projectPrefix}-${env}'

// Connector-local resource names (all live in the target RG, at connectorLocation)
var funcName  = '${prefix}-fn-${suffix}'
var planName  = '${prefix}-plan'
var kvName    = '${prefix}-kv-${suffix}'
var stName    = toLower(replace('${projectPrefix}${env}st${suffix}', '-', ''))
var dceName   = '${prefix}-dce'
var dcrName   = '${prefix}-dcr'
var aiName    = '${prefix}-ai'

// Parse the workspace resource ID to extract subscription + RG for cross-RG deploys.
// Format: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<name>
var workspaceSubscriptionId = split(existingWorkspaceId, '/')[2]
var workspaceResourceGroup  = split(existingWorkspaceId, '/')[4]
var workspaceName           = last(split(existingWorkspaceId, '/'))

var packageUrl = functionAppZipVersion == 'latest'
  ? 'https://github.com/${githubRepo}/releases/latest/download/function-app.zip'
  : 'https://github.com/${githubRepo}/releases/download/v${functionAppZipVersion}/function-app.zip'

// ============================================================================
// MODULES — workspace-scoped (cross-RG into the customer's Sentinel RG)
// ============================================================================

// Custom tables: created as sub-resources of the EXISTING workspace. Deployed at
// the workspace's RG scope because sub-resource creation requires the workspace's
// own RG context (Azure RBAC + resource-provider semantics).
module customTables 'modules/custom-tables.bicep' = {
  name: 'tables-${uniq}'
  scope: resourceGroup(workspaceSubscriptionId, workspaceResourceGroup)
  params: {
    workspaceName: workspaceName
  }
}

// Sentinel Solution package + Data Connector card. Emits 4 workspace sub-
// resources (contentPackages + Solution metadata + StaticUI dataConnector +
// DataConnector metadata) so XdrLogRaider appears in Content Hub AND in the
// Data Connectors blade alongside Microsoft Defender XDR / MDE / etc. — same
// shape Microsoft uses for first-party solutions.
//
// Always deploys (no condition) so the connector card and Solution wrapper
// are present even when deploySentinelContent=false. Per-item metadata links
// for analytic rules / hunting / workbooks / parsers live in sentinelContent
// and only deploy when that toggle is true.
module sentinelSolution 'modules/data-connector.bicep' = {
  name: 'solution-${uniq}'
  scope: resourceGroup(workspaceSubscriptionId, workspaceResourceGroup)
  params: {
    workspaceName: workspaceName
  }
  dependsOn: [
    customTables
  ]
}

// ============================================================================
// MODULES — connector-local (in target RG at connectorLocation)
// ============================================================================

// DCE + DCR must be in the WORKSPACE'S region (Azure Monitor constraint). They live
// in the target RG (connector-local) but use workspaceLocation for `location`.
module dceDcr 'modules/dce-dcr.bicep' = {
  name: 'dce-${uniq}'
  params: {
    dceName: dceName
    dcrName: dcrName
    location: workspaceLocation              // MUST match workspace region
    workspaceResourceId: existingWorkspaceId // full cross-RG resource ID
  }
  dependsOn: [
    customTables
  ]
}

// Storage (checkpoint table)
module storage 'modules/storage.bicep' = {
  name: 'st-${uniq}'
  params: {
    storageAccountName: stName
    location: connectorLocation
  }
}

// Key Vault
module keyVault 'modules/key-vault.bicep' = {
  name: 'kv-${uniq}'
  params: {
    keyVaultName: kvName
    location: connectorLocation
  }
}

// App Insights (workspace-based — telemetry lands in the same Sentinel workspace)
module appInsights 'modules/app-insights.bicep' = {
  name: 'ai-${uniq}'
  params: {
    appInsightsName: aiName
    location: connectorLocation
    workspaceResourceId: existingWorkspaceId
  }
}

// Function App
module functionApp 'modules/function-app.bicep' = {
  name: 'fn-${uniq}'
  params: {
    functionAppName: funcName
    planName: planName
    location: connectorLocation
    storageAccountName: storage.outputs.storageAccountName
    appInsightsConnectionString: appInsights.outputs.connectionString
    planSku: functionPlanSku
    packageUrl: packageUrl
    appSettings: {
      AUTH_METHOD:           authMethod
      SERVICE_ACCOUNT_UPN:   serviceAccountUpn
      KEY_VAULT_URI:         keyVault.outputs.vaultUri
      AUTH_SECRET_NAME:      'mde-portal-auth'
      DCE_ENDPOINT:          dceDcr.outputs.dceIngestionEndpoint
      DCR_IMMUTABLE_ID:      dceDcr.outputs.dcrImmutableId
      STORAGE_ACCOUNT_NAME:  storage.outputs.storageAccountName
      CHECKPOINT_TABLE_NAME: 'connectorCheckpoints'
    }
  }
}

// Role assignments: grant the FA's Managed Identity the 3 minimum roles it needs
// (all scoped to connector-local resources — no cross-RG role grants required).
module roles 'modules/role-assignments.bicep' = {
  name: 'roles-${uniq}'
  params: {
    functionAppPrincipalId: functionApp.outputs.principalId
    keyVaultName:           keyVault.outputs.vaultName
    storageAccountName:     storage.outputs.storageAccountName
    dcrResourceId:          dceDcr.outputs.dcrResourceId
  }
}

// ============================================================================
// OUTPUTS
// ============================================================================

output functionAppName     string = functionApp.outputs.functionAppName
output functionAppId       string = functionApp.outputs.functionAppId
output principalId         string = functionApp.outputs.principalId
output keyVaultName        string = keyVault.outputs.vaultName
output keyVaultUri         string = keyVault.outputs.vaultUri
output dceEndpoint         string = dceDcr.outputs.dceIngestionEndpoint
output dcrImmutableId      string = dceDcr.outputs.dcrImmutableId
output storageAccountName  string = storage.outputs.storageAccountName
output workspaceId         string = existingWorkspaceId
output workspaceRg         string = workspaceResourceGroup
output workspaceLocation   string = workspaceLocation

output postDeployInstructions string = '''
Next step — upload your auth secrets to Key Vault:

  ./tools/Initialize-XdrLogRaiderAuth.ps1 -KeyVaultName ${keyVault.outputs.vaultName}

The Function App self-test runs within 5 minutes of secret upload.
Check results in your Sentinel workspace:

  MDE_AuthTestResult_CL | order by TimeGenerated desc | take 1

Runbook: docs/RUNBOOK.md
'''
