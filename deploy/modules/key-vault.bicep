@description('Key Vault name.')
param keyVaultName string

@description('Azure region.')
param location string

@description('SKU.')
@allowed([ 'standard', 'premium' ])
param sku string = 'standard'

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: sku
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enablePurgeProtection: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
  }
}

output vaultName string = keyVault.name
output vaultId   string = keyVault.id
output vaultUri  string = keyVault.properties.vaultUri
