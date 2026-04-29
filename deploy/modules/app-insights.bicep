@description('App Insights name.')
param appInsightsName string

@description('Azure region.')
param location string

@description('Log Analytics workspace resource ID to link to.')
param workspaceResourceId string

@description('When true, restricts public network access for query (operator must use Bastion or private endpoint to query traces). Ingestion stays open so the FA can write telemetry without VNet integration. Default false for v0.1.0-beta deployability; flips to true in the v1.2 Marketplace baseline.')
param restrictPublicNetwork bool = false

@description('Tags applied to every resource emitted by this module. The `environment` tag carries the env signal regardless of whether legacyEnvInName=true or false, so operators can filter by environment via Azure tag query.')
param tags object = {}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspaceResourceId
    IngestionMode: 'LogAnalytics'
    // Ingestion stays Enabled regardless — the FA needs to write telemetry,
    // and Microsoft-managed AI ingestion endpoints are widely allow-listed.
    publicNetworkAccessForIngestion: 'Enabled'
    // Query access can be locked down (operator queries via Sentinel workspace
    // or Azure Bastion). Default Enabled for deployability; restrict for prod.
    publicNetworkAccessForQuery: restrictPublicNetwork ? 'Disabled' : 'Enabled'
  }
}

output appInsightsName     string = appInsights.name
output connectionString    string = appInsights.properties.ConnectionString
output instrumentationKey  string = appInsights.properties.InstrumentationKey
