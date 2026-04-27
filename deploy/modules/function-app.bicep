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

@description('Plan SKU.')
@allowed([ 'Y1', 'EP1', 'EP2' ])
param planSku string = 'Y1'

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
    name: planSku
    tier: planSku == 'Y1' ? 'Dynamic' : 'ElasticPremium'
  }
  kind: planSku == 'Y1' ? 'functionapp' : 'elastic'
  properties: {
    reserved: true // Linux
  }
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
      alwaysOn: planSku != 'Y1'  // Consumption plan doesn't support AlwaysOn
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      appSettings: [
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'powershell'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME_VERSION'
          value: powerShellVersion
        }
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsightsConnectionString
        }
        {
          name: 'WEBSITE_RUN_FROM_PACKAGE'
          value: packageUrl
        }
        {
          name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
        }
        {
          name: 'WEBSITE_CONTENTSHARE'
          value: toLower(functionAppName)
        }
      ]
    }
  }
}

// Merge caller-provided appSettings with the base settings above.
// Bicep doesn't support appending to an array of app settings elegantly; we do
// a follow-up resource that sets the full list including the extras.
resource functionAppSettings 'Microsoft.Web/sites/config@2023-12-01' = {
  name: 'appsettings'
  parent: functionApp
  properties: union(
    {
      FUNCTIONS_EXTENSION_VERSION: '~4'
      FUNCTIONS_WORKER_RUNTIME: 'powershell'
      FUNCTIONS_WORKER_RUNTIME_VERSION: powerShellVersion
      AzureWebJobsStorage: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
      APPLICATIONINSIGHTS_CONNECTION_STRING: appInsightsConnectionString
      WEBSITE_RUN_FROM_PACKAGE: packageUrl
      WEBSITE_CONTENTAZUREFILECONNECTIONSTRING: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
      WEBSITE_CONTENTSHARE: toLower(functionAppName)
      // v0.1.0-beta cold-start optimisations:
      // - SKIP_RUNNING_KUDUAGENT eliminates the Kudu sidecar that spins up on
      //   every cold start (Consumption plan pays ~1-2s + extra RAM for
      //   nothing we use). Safe on Linux Consumption per MSFT guidance.
      // - WORKER_PROCESS_COUNT=1 is the PowerShell single-threaded model
      //   default; making it explicit prevents accidental multi-worker
      //   spawning (which fragments module caches + confuses App Insights).
      // - PSWorkerInProcConcurrencyUpperBound=1 disables the multi-runspace
      //   concurrency model (default 1000). With it >1, profile.ps1 runs per
      //   runspace and $global state may not propagate consistently — caused
      //   iter 13.x "$global:XdrLogRaiderConfig not set" production errors.
      //   Our timer functions never run concurrently within an instance, so
      //   single-runspace mode is correct AND fixes the propagation bug.
      WEBSITE_SKIP_RUNNING_KUDUAGENT: 'true'
      FUNCTIONS_WORKER_PROCESS_COUNT: '1'
      PSWorkerInProcConcurrencyUpperBound: '1'
    },
    appSettings
  )
}

output functionAppName string = functionApp.name
output functionAppId   string = functionApp.id
output principalId     string = functionApp.identity.principalId
