@description('App Insights name.')
param appInsightsName string

@description('Azure region.')
param location string

@description('Log Analytics workspace resource ID to link to.')
param workspaceResourceId string

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspaceResourceId
    IngestionMode: 'LogAnalytics'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

output appInsightsName     string = appInsights.name
output connectionString    string = appInsights.properties.ConnectionString
output instrumentationKey  string = appInsights.properties.InstrumentationKey
