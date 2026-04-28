@description('Key Vault name.')
param keyVaultName string

@description('Azure region.')
param location string

@description('SKU.')
@allowed([ 'standard', 'premium' ])
param sku string = 'standard'

@description('Iter 13.15: when true, restricts public network access on the Key Vault. Default false for v0.1.0-beta deployability; flips to true in v1.2 Marketplace baseline.')
param restrictPublicNetwork bool = false

@description('Iter 13.15: when true, deploys Microsoft.Insights/diagnosticSettings to send Key Vault audit logs (GetSecret/ListSecrets/etc.) to the Sentinel workspace. Default true — required for forensic visibility on credential access.')
param enableDiagnostics bool = true

@description('Sentinel workspace resource ID (target for diagnostic settings). Required only when enableDiagnostics=true.')
param workspaceResourceId string = ''

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
    publicNetworkAccess: restrictPublicNetwork ? 'Disabled' : 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: restrictPublicNetwork ? 'Deny' : 'Allow'
    }
  }
}

// ============================================================================
// Iter 13.15: KV diagnostic settings → Sentinel workspace
// ============================================================================
// Captures AuditEvent (every secret read/write/list) for forensic visibility.
// This is the audit trail an operator needs after a suspected breach to know
// WHO read the MDE service-account secret and WHEN. Without it, credential
// exfiltration leaves no record.
resource kvDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (enableDiagnostics && !empty(workspaceResourceId)) {
  scope: keyVault
  name: 'send-to-sentinel'
  properties: {
    workspaceId: workspaceResourceId
    logs: [
      {
        categoryGroup: 'audit'
        enabled: true
      }
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output vaultName string = keyVault.name
output vaultId   string = keyVault.id
output vaultUri  string = keyVault.properties.vaultUri
