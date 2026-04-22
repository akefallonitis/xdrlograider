// XdrLogRaider — main deployment template.
// Deploys: Function App (PowerShell 7.4) + KV + Storage + DCE + DCR + Log Analytics (optional) + App Insights.

targetScope = 'resourceGroup'

@description('Project prefix — used in resource names. 3-12 alphanumeric.')
@minLength(3)
@maxLength(12)
param projectPrefix string = 'xdrlr'

@description('Environment tag. Typically dev/staging/prod.')
@allowed([ 'dev', 'staging', 'prod' ])
param env string = 'prod'

@description('Azure region.')
param location string = resourceGroup().location

@description('UPN of the service account the connector authenticates as.')
param serviceAccountUpn string

@description('Auth method the connector will use.')
@allowed([ 'passkey', 'credentials_totp' ])
param authMethod string = 'credentials_totp'

@description('Existing Log Analytics workspace resource ID. Leave empty to create new.')
param existingWorkspaceId string = ''

@description('Function App SKU. Y1 = Consumption (recommended).')
@allowed([ 'Y1', 'EP1', 'EP2' ])
param functionPlanSku string = 'Y1'

@description('Version of the Function App ZIP to deploy (from GitHub releases).')
param functionAppZipVersion string = 'latest'

@description('GitHub repo owner and name (owner/repo format) — used to build WEBSITE_RUN_FROM_PACKAGE URL.')
param githubRepo string = 'akefallonitis/xdrlograider'

// --- Naming ---
var uniq      = uniqueString(resourceGroup().id, projectPrefix, env)
var suffix    = substring(uniq, 0, 6)
var prefix    = '${projectPrefix}-${env}'
var funcName  = '${prefix}-fn-${suffix}'
var planName  = '${prefix}-plan'
var kvName    = '${prefix}-kv-${suffix}'
var stName    = toLower(replace('${projectPrefix}${env}st${suffix}', '-', ''))
var laName    = '${prefix}-la'
var dceName   = '${prefix}-dce'
var dcrName   = '${prefix}-dcr'
var aiName    = '${prefix}-ai'

var packageUrl = functionAppZipVersion == 'latest'
  ? 'https://github.com/${githubRepo}/releases/latest/download/function-app.zip'
  : 'https://github.com/${githubRepo}/releases/download/v${functionAppZipVersion}/function-app.zip'

// --- Log Analytics (create or reuse) ---
module logAnalytics 'modules/log-analytics.bicep' = if (empty(existingWorkspaceId)) {
  name: 'la-${uniq}'
  params: {
    workspaceName: laName
    location: location
  }
}

var workspaceId       = empty(existingWorkspaceId) ? logAnalytics.outputs.workspaceId       : existingWorkspaceId
var workspaceCustomerId = empty(existingWorkspaceId) ? logAnalytics.outputs.workspaceCustomerId : ''

// --- Custom tables (55 + heartbeat + authtest) ---
module customTables 'modules/custom-tables.bicep' = {
  name: 'tables-${uniq}'
  params: {
    workspaceName: empty(existingWorkspaceId) ? laName : last(split(existingWorkspaceId, '/'))
  }
  dependsOn: [
    logAnalytics
  ]
}

// --- DCE + DCR ---
module dceDcr 'modules/dce-dcr.bicep' = {
  name: 'dce-${uniq}'
  params: {
    dceName: dceName
    dcrName: dcrName
    location: location
    workspaceResourceId: workspaceId
  }
  dependsOn: [
    customTables
  ]
}

// --- Storage (checkpoints) ---
module storage 'modules/storage.bicep' = {
  name: 'st-${uniq}'
  params: {
    storageAccountName: stName
    location: location
  }
}

// --- Key Vault ---
module keyVault 'modules/key-vault.bicep' = {
  name: 'kv-${uniq}'
  params: {
    keyVaultName: kvName
    location: location
  }
}

// --- App Insights ---
module appInsights 'modules/app-insights.bicep' = {
  name: 'ai-${uniq}'
  params: {
    appInsightsName: aiName
    location: location
    workspaceResourceId: workspaceId
  }
  dependsOn: [
    logAnalytics
  ]
}

// --- Function App ---
module functionApp 'modules/function-app.bicep' = {
  name: 'fn-${uniq}'
  params: {
    functionAppName: funcName
    planName: planName
    location: location
    storageAccountName: storage.outputs.storageAccountName
    appInsightsConnectionString: appInsights.outputs.connectionString
    planSku: functionPlanSku
    packageUrl: packageUrl
    appSettings: {
      AUTH_METHOD: authMethod
      SERVICE_ACCOUNT_UPN: serviceAccountUpn
      KEY_VAULT_URI: keyVault.outputs.vaultUri
      AUTH_SECRET_NAME: 'mde-portal-auth'
      DCE_ENDPOINT: dceDcr.outputs.dceIngestionEndpoint
      DCR_IMMUTABLE_ID: dceDcr.outputs.dcrImmutableId
      STORAGE_ACCOUNT_NAME: storage.outputs.storageAccountName
      CHECKPOINT_TABLE_NAME: 'connectorCheckpoints'
    }
  }
}

// --- Role assignments ---
module roles 'modules/role-assignments.bicep' = {
  name: 'roles-${uniq}'
  params: {
    functionAppPrincipalId: functionApp.outputs.principalId
    keyVaultName: keyVault.outputs.vaultName
    storageAccountName: storage.outputs.storageAccountName
    dcrResourceId: dceDcr.outputs.dcrResourceId
  }
}

// --- Data Connector UI (Sentinel) ---
module dataConnector 'modules/data-connector.bicep' = {
  name: 'connector-${uniq}'
  params: {
    workspaceName: empty(existingWorkspaceId) ? laName : last(split(existingWorkspaceId, '/'))
    projectPrefix: projectPrefix
  }
  dependsOn: [
    customTables
    dceDcr
  ]
}

// --- Outputs ---
output functionAppName    string = functionApp.outputs.functionAppName
output functionAppId      string = functionApp.outputs.functionAppId
output principalId        string = functionApp.outputs.principalId
output keyVaultName       string = keyVault.outputs.vaultName
output keyVaultUri        string = keyVault.outputs.vaultUri
output dceEndpoint        string = dceDcr.outputs.dceIngestionEndpoint
output dcrImmutableId     string = dceDcr.outputs.dcrImmutableId
output storageAccountName string = storage.outputs.storageAccountName
output workspaceId        string = workspaceId

output postDeployInstructions string = '''
Next step — upload your auth secrets to Key Vault:

  ./tools/Initialize-XdrLogRaiderAuth.ps1 -KeyVaultName ${keyVault.outputs.vaultName}

The Function App self-test runs within 5 minutes of secret upload.
Check results with:

  MDE_AuthTestResult_CL | order by TimeGenerated desc | take 1

Runbook: docs/RUNBOOK.md
'''
