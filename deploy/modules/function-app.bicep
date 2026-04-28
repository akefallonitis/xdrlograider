@description('Function App name.')
param functionAppName string

@description('App Service plan name.')
param planName string

@description('Azure region.')
param location string

@description('Storage account name (for FA runtime).')
param storageAccountName string

@description('App Insights connection string.')
param appInsightsConnectionString string

@description('Iter 13.15: serverfarm SKU derived from hostingPlan. Y1 = Consumption Dynamic; FC1 = Flex Consumption; EP1 = ElasticPremium.')
@allowed([ 'Y1', 'FC1', 'EP1', 'EP2' ])
param serverfarmSku string = 'Y1'

@description('Iter 13.15: serverfarm tier label. Dynamic for Y1; FlexConsumption for FC1; ElasticPremium for EP*.')
@allowed([ 'Dynamic', 'FlexConsumption', 'ElasticPremium' ])
param serverfarmTier string = 'Dynamic'

@description('Iter 13.15: when true, both AzureWebJobsStorage AND WEBSITE_CONTENTAZUREFILECONNECTIONSTRING use the identity-based __accountName form. Only safe on FC1/EP1 (Y1 Linux content-share is platform-limited to shared key).')
param useFullManagedIdentity bool = false

@description('Iter 13.15: AlwaysOn supported only on EP* tier. Y1 / FC1 reject it.')
param alwaysOn bool = false

@description('PowerShell version.')
param powerShellVersion string = '7.4'

@description('URL to the Function App code ZIP (from GitHub releases).')
param packageUrl string

@description('Key-value app settings to set on the Function App.')
param appSettings object

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: location
  sku: {
    name: serverfarmSku
    tier: serverfarmTier
  }
  kind: serverfarmSku == 'Y1' ? 'functionapp' : (serverfarmSku == 'FC1' ? 'functionapp,linux,flexconsumption' : 'elastic')
  properties: {
    reserved: true // Linux
  }
}

// ============================================================================
// Iter 13.15: tiered AzureWebJobsStorage + WEBSITE_CONTENTAZUREFILECONNECTIONSTRING
// ============================================================================
// Y1 Linux Consumption: shared-key (Microsoft platform limit on content share).
// FC1 / EP1: identity-based (__accountName) — full MI, closes PrivEsc chain.
//
// Threat model (closed by useFullManagedIdentity = true):
//   FA Contributor identity → reads connection-string app setting → extracts
//   Storage Account Key → writes Files share (the FA runtime code mount) →
//   next cold start runs attacker code as SAMI → SAMI reads Key Vault →
//   Defender XDR tenant compromise. CWE-269 privilege escalation.

var sharedKeyConnectionString = 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'

// AzureWebJobsStorage variants — exactly one consumed depending on tier
var azureWebJobsStorageBase = useFullManagedIdentity ? {
    AzureWebJobsStorage__accountName: storageAccount.name
} : {
    AzureWebJobsStorage: sharedKeyConnectionString
}

// WEBSITE_CONTENTAZUREFILECONNECTIONSTRING variants
var websiteContentBase = useFullManagedIdentity ? {
    // FC1/EP1: identity-based content share
    WEBSITE_CONTENTAZUREFILECONNECTIONSTRING__accountName: storageAccount.name
    WEBSITE_CONTENTSHARE: toLower(functionAppName)
} : {
    // Y1: shared-key content share (Microsoft platform limit)
    WEBSITE_CONTENTAZUREFILECONNECTIONSTRING: sharedKeyConnectionString
    WEBSITE_CONTENTSHARE: toLower(functionAppName)
}

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'POWERSHELL|${powerShellVersion}'
      powerShellVersion: powerShellVersion
      use32BitWorkerProcess: false
      // Iter 13.15: AlwaysOn only valid on EP*. Y1 + FC1 with AlwaysReady=0 cold-start.
      alwaysOn: alwaysOn
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      // Initial siteConfig.appSettings is intentionally minimal — full set is
      // applied via the followup 'config@appsettings' resource so caller-supplied
      // operator settings can be merged via union().
    }
  }
}

// ============================================================================
// FULL APP SETTINGS — composed via union() so caller-supplied operator
// settings (in $appSettings parameter) merge AFTER our base settings.
// ============================================================================
resource functionAppSettings 'Microsoft.Web/sites/config@2023-12-01' = {
  name: 'appsettings'
  parent: functionApp
  properties: union(
    {
      FUNCTIONS_EXTENSION_VERSION: '~4'
      FUNCTIONS_WORKER_RUNTIME: 'powershell'
      FUNCTIONS_WORKER_RUNTIME_VERSION: powerShellVersion
      APPLICATIONINSIGHTS_CONNECTION_STRING: appInsightsConnectionString
      WEBSITE_RUN_FROM_PACKAGE: packageUrl
      // Iter 13.15: cold-start optimisations (per Microsoft Linux Consumption guidance)
      WEBSITE_SKIP_RUNNING_KUDUAGENT: 'true'
      // Iter 13.3: single-runspace mode prevents $global state propagation
      // bugs across runspaces. Our timer functions never run concurrently
      // within an instance, so this is correct + safe.
      FUNCTIONS_WORKER_PROCESS_COUNT: '1'
      PSWorkerInProcConcurrencyUpperBound: '1'
    },
    azureWebJobsStorageBase,
    websiteContentBase,
    appSettings
  )
}

output functionAppName string = functionApp.name
output functionAppId   string = functionApp.id
output principalId     string = functionApp.identity.principalId
