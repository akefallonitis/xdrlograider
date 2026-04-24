@description('Function App principal ID (from its managed identity).')
param functionAppPrincipalId string

@description('Key Vault name.')
param keyVaultName string

@description('Storage account name.')
param storageAccountName string

@description('DCR resource ID.')
param dcrResourceId string

// --- Built-in role definition IDs ---
var kvSecretsUserRoleId       = '4633458b-17de-408a-b874-0445c86b69e6'  // Key Vault Secrets User
var storageTableContributor   = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'  // Storage Table Data Contributor
var monitoringMetricsPublisher = '3913510d-42f4-4e42-8a64-420c390055eb' // Monitoring Metrics Publisher

// --- Key Vault: Secrets User ---
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource kvRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, functionAppPrincipalId, kvSecretsUserRoleId)
  scope: keyVault
  properties: {
    principalId: functionAppPrincipalId
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', kvSecretsUserRoleId)
    principalType: 'ServicePrincipal'
  }
}

// --- Storage: Table Data Contributor ---
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource stRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionAppPrincipalId, storageTableContributor)
  scope: storageAccount
  properties: {
    principalId: functionAppPrincipalId
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', storageTableContributor)
    principalType: 'ServicePrincipal'
  }
}

// --- DCR: Monitoring Metrics Publisher ---
// Reference the DCR via an 'existing' symbolic resource so we can scope the role
// assignment to it directly (Bicep v0.20+ rejects string scopes on role-assignment
// resources; the compiled ARM JSON still emits a string scope under the hood).
resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' existing = {
  name: last(split(dcrResourceId, '/'))
}

resource dcrRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dcr.id, functionAppPrincipalId, monitoringMetricsPublisher)
  scope: dcr
  properties: {
    principalId: functionAppPrincipalId
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisher)
    principalType: 'ServicePrincipal'
  }
}
