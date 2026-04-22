@description('Log Analytics workspace name.')
param workspaceName string

@description('Azure region.')
param location string

@description('SKU.')
param sku string = 'PerGB2018'

@description('Data retention in days.')
param retentionInDays int = 90

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  properties: {
    sku: {
      name: sku
    }
    retentionInDays: retentionInDays
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

output workspaceId         string = workspace.id
output workspaceName       string = workspace.name
output workspaceCustomerId string = workspace.properties.customerId
