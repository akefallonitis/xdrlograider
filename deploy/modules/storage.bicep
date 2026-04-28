@description('Storage account name. Must be globally unique, 3-24 lowercase alphanumeric.')
param storageAccountName string

@description('Azure region.')
param location string

@description('Iter 13.15: when true, sets allowSharedKeyAccess: false. Only safe when AzureWebJobsStorage + WEBSITE_CONTENTAZUREFILECONNECTIONSTRING use Managed Identity (i.e., hostingPlan != consumption-y1). Y1 Linux Consumption keeps shared-key on the content share due to a Microsoft platform limit.')
param disableSharedKey bool = false

@description('Iter 13.15: when true, restricts public network access on the storage account (default deny + AzureServices bypass). Default false for v0.1.0-beta deployability; flips to true in v1.2 Marketplace baseline.')
param restrictPublicNetwork bool = false

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    // Iter 13.15: shared-key access is gated by disableSharedKey, which the
    // top-level main.bicep derives from hostingPlan. consumption-y1 leaves
    // it true (Y1 Linux platform requires it for the Files content share);
    // flex-fc1 / premium-ep1 set it false (full MI on both env vars).
    allowSharedKeyAccess: !disableSharedKey
    // Iter 13.15: public network access is gated by restrictPublicNetwork.
    // When true, defaultAction: 'Deny' + AzureServices bypass lets the FA
    // still reach the table data plane via its trusted-services exemption.
    publicNetworkAccess: restrictPublicNetwork ? 'Enabled' : 'Enabled'  // both states keep API enabled; deny is via networkAcls
    networkAcls: {
      defaultAction: restrictPublicNetwork ? 'Deny' : 'Allow'
      bypass: 'AzureServices'
    }
  }
}

resource tableService 'Microsoft.Storage/storageAccounts/tableServices@2023-05-01' = {
  name: 'default'
  parent: storageAccount
}

resource checkpointTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01' = {
  name: 'connectorCheckpoints'
  parent: tableService
}

output storageAccountName string = storageAccount.name
output storageAccountId   string = storageAccount.id
