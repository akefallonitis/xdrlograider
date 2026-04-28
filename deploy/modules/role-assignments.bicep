@description('Function App principal ID (from its managed identity).')
param functionAppPrincipalId string

@description('Key Vault name.')
param keyVaultName string

@description('Storage account name.')
param storageAccountName string

@description('DCR resource ID.')
param dcrResourceId string

@description('Iter 13.15: when true (FC1/EP1 hosting plans), grants the additional Storage roles needed for full Managed Identity AzureWebJobsStorage + WEBSITE_CONTENTAZUREFILECONNECTIONSTRING. When false (Y1), Storage Blob Data Owner + Storage Queue Data Contributor are still granted (FA runtime needs blob+queue), but Storage File Data SMB Share Contributor is NOT granted (Y1 uses shared key for the content share — Microsoft platform limit).')
param useFullManagedIdentity bool = false

// ============================================================================
// Built-in role definition IDs (canonical Microsoft GUIDs)
// ============================================================================
var kvSecretsUserRoleId             = '4633458b-17de-408a-b874-0445c86b69e6'  // Key Vault Secrets User (read secrets)
var storageTableContributorRoleId   = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'  // Storage Table Data Contributor (data plane on tables)
var monitoringMetricsPublisherRoleId = '3913510d-42f4-4e42-8a64-420c390055eb' // Monitoring Metrics Publisher (DCR ingest)
var storageBlobDataOwnerRoleId      = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'  // Storage Blob Data Owner (FA runtime AzureWebJobsStorage MI)
var storageQueueDataContributorRoleId = '974c5e8b-45b9-4653-ba55-5f855dd0fb88' // Storage Queue Data Contributor (FA runtime queue leases)
var storageFileSmbShareContributorRoleId = '0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb' // Storage File Data SMB Share Contributor (FC1/EP1 content share via MI)

// ============================================================================
// Existing resource references (for scoping role assignments to specific resources)
// ============================================================================
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' existing = {
  name: last(split(dcrResourceId, '/'))
}

// ============================================================================
// 1. Key Vault Secrets User — read mde-portal-auth at runtime
// ============================================================================
resource kvRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, functionAppPrincipalId, kvSecretsUserRoleId)
  scope: keyVault
  properties: {
    principalId: functionAppPrincipalId
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', kvSecretsUserRoleId)
    principalType: 'ServicePrincipal'
  }
}

// ============================================================================
// 2. Storage Table Data Contributor — connectorCheckpoints data plane
// ============================================================================
resource stTableRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionAppPrincipalId, storageTableContributorRoleId)
  scope: storageAccount
  properties: {
    principalId: functionAppPrincipalId
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', storageTableContributorRoleId)
    principalType: 'ServicePrincipal'
  }
}

// ============================================================================
// 3. Monitoring Metrics Publisher — DCE/DCR ingest
// ============================================================================
resource dcrRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dcr.id, functionAppPrincipalId, monitoringMetricsPublisherRoleId)
  scope: dcr
  properties: {
    principalId: functionAppPrincipalId
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisherRoleId)
    principalType: 'ServicePrincipal'
  }
}

// ============================================================================
// 4. Storage Blob Data Owner — Azure Functions runtime needs this for
//    AzureWebJobsStorage MI on ALL hosting plans (Y1/FC1/EP1).
//    Per Microsoft docs: https://learn.microsoft.com/azure/azure-functions/functions-reference#connecting-to-host-storage-with-an-identity
// ============================================================================
resource stBlobRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionAppPrincipalId, storageBlobDataOwnerRoleId)
  scope: storageAccount
  properties: {
    principalId: functionAppPrincipalId
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataOwnerRoleId)
    principalType: 'ServicePrincipal'
  }
}

// ============================================================================
// 5. Storage Queue Data Contributor — Functions runtime queue leases (singleton
//    locks, host instance leadership election). Required on all hosting plans.
// ============================================================================
resource stQueueRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionAppPrincipalId, storageQueueDataContributorRoleId)
  scope: storageAccount
  properties: {
    principalId: functionAppPrincipalId
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', storageQueueDataContributorRoleId)
    principalType: 'ServicePrincipal'
  }
}

// ============================================================================
// 6. Storage File Data SMB Share Contributor — ONLY when useFullManagedIdentity
//    is true (i.e., FC1 / EP1 hosting plans). Y1 Linux Consumption uses shared
//    key for the content share (Microsoft platform limit) so this role is not
//    needed on Y1 (FA wouldn't use MI for the content share anyway).
// ============================================================================
resource stFileRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (useFullManagedIdentity) {
  name: guid(storageAccount.id, functionAppPrincipalId, storageFileSmbShareContributorRoleId)
  scope: storageAccount
  properties: {
    principalId: functionAppPrincipalId
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', storageFileSmbShareContributorRoleId)
    principalType: 'ServicePrincipal'
  }
}
