@description('Log Analytics / Sentinel workspace name.')
param workspaceName string

@description('Project prefix.')
param projectPrefix string

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
}

// Sentinel Data Connector UI definition — makes the connector appear in
// Sentinel → Data Connectors with its status, last-heartbeat, and setup instructions.
resource dataConnectorDefinition 'Microsoft.OperationalInsights/workspaces/providers/dataConnectorDefinitions@2023-04-01-preview' = {
  name: '${workspaceName}/Microsoft.SecurityInsights/XdrLogRaiderInternal'
  kind: 'Customizable'
  properties: {
    connectorUiConfig: {
      id: 'XdrLogRaiderInternal'
      title: 'XdrLogRaider — Defender XDR Internal Telemetry'
      publisher: 'Community'
      descriptionMarkdown: 'Ingests Defender XDR portal-only telemetry (configuration, compliance, drift, exposure, governance) that is not exposed by public Graph Security / Defender XDR / MDE public APIs.\\n\\n- 55 streams across 8 compliance tiers\\n- Drift detection via pure KQL in 6 category parsers\\n- 6 workbooks, 15 analytic rules, 10 hunting queries\\n\\nSee [repo README](https://github.com/akefallonitis/xdrlograider) for setup + runbook.'
      graphQueriesTableName: 'MDE_Heartbeat_CL'
      graphQueries: [
        {
          metricName: 'Heartbeat (last 24h)'
          legend: 'XdrLogRaider heartbeats'
          baseQuery: 'MDE_Heartbeat_CL | where TimeGenerated > ago(24h) | summarize count() by bin(TimeGenerated, 1h)'
        }
      ]
      sampleQueries: [
        {
          description: 'Recent auth self-test results'
          query: 'MDE_AuthTestResult_CL | order by TimeGenerated desc | take 10'
        }
        {
          description: 'ASR rules currently not in Block mode'
          query: 'MDE_AsrRulesConfig_CL | summarize arg_max(TimeGenerated, *) by EntityId | where parse_json(RawJson).mode != "Block"'
        }
      ]
      dataTypes: [
        { name: 'MDE_Heartbeat_CL',       lastDataReceivedQuery: 'MDE_Heartbeat_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_AuthTestResult_CL',  lastDataReceivedQuery: 'MDE_AuthTestResult_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_AdvancedFeatures_CL',lastDataReceivedQuery: 'MDE_AdvancedFeatures_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
      ]
      connectivityCriteria: [
        {
          type: 'IsConnectedQuery'
          value: [ 'MDE_Heartbeat_CL | where TimeGenerated > ago(1h) | count | where Count > 0' ]
        }
      ]
      availability: {
        status: 1
        isPreview: true
      }
      permissions: {
        resourceProvider: [
          {
            provider: 'Microsoft.OperationalInsights/workspaces'
            permissionsDisplayText: 'read and write permissions on the workspace are required'
            providerDisplayName: 'Workspace'
            scope: 'Workspace'
            requiredPermissions: { read: true, write: true, delete: true }
          }
        ]
        customs: [
          {
            name: 'Service account'
            description: 'Dedicated read-only Entra service account (Security Reader + MDE analyst read roles) with Credentials+TOTP or Software Passkey configured.'
          }
        ]
      }
      instructionSteps: [
        {
          title: 'Upload auth secrets to Key Vault'
          description: 'After deployment, run the initialization script from your local machine:'
          instructions: [
            {
              type: 'CopyableLabel'
              parameters: {
                label: 'git clone https://github.com/akefallonitis/xdrlograider && cd xdrlograider && ./tools/Initialize-XdrLogRaiderAuth.ps1 -KeyVaultName <from-deployment-output>'
              }
            }
          ]
        }
        {
          title: 'Wait for self-test'
          description: 'Within 5 minutes the Function App validates auth and writes to MDE_AuthTestResult_CL:'
          instructions: [
            {
              type: 'CopyableLabel'
              parameters: {
                label: 'MDE_AuthTestResult_CL | order by TimeGenerated desc | take 1 | project TimeGenerated, Success, Stage, FailureReason'
              }
            }
          ]
        }
      ]
    }
  }
}

output connectorDefinitionName string = 'XdrLogRaiderInternal'
