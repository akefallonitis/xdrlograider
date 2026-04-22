@description('Storage account name. Must be globally unique, 3-24 lowercase alphanumeric.')
param storageAccountName string

@description('Azure region.')
param location string

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
    allowSharedKeyAccess: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
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
