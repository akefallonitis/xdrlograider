// XdrLogRaider Sentinel Solution + Data Connector card.
//
// Emits the four resources Microsoft uses for first-party Sentinel solutions
// (compare: Solutions/MicrosoftDefenderForEndpoint/Package/mainTemplate.json):
//
//   1. Microsoft.OperationalInsights/workspaces/providers/contentPackages
//        — the Solution wrapper. Makes "XdrLogRaider" appear in Content Hub.
//
//   2. Microsoft.OperationalInsights/workspaces/providers/metadata (Solution)
//        — links the solution package to the workspace.
//
//   3. Microsoft.OperationalInsights/workspaces/providers/dataConnectors (StaticUI)
//        — the actual connector card visible in Sentinel → Data Connectors,
//          alongside Microsoft Defender XDR / MDE / etc. The previous compile
//          used `dataConnectorDefinitions` which is a CCF-template type — it
//          surfaces in Content Hub but DOES NOT appear in Data Connectors.
//
//   4. Microsoft.OperationalInsights/workspaces/providers/metadata (DataConnector)
//        — links the data connector instance back to the solution.
//
// Deployed unconditionally: even with deploySentinelContent=false the operator
// still sees a "XdrLogRaider" solution + connector card. Sentinel content
// (rules, hunting, workbooks, parsers) is deployed separately and links to the
// same solution via per-item metadata in sentinelContent.json.

@description('Log Analytics / Sentinel workspace name.')
param workspaceName string

// Stable identifiers — DO NOT change without a Solution version bump or every
// installation will appear as a new Solution side-by-side. The IDs match the
// Sentinel Solutions naming convention (lowercase, dashed, repo-stable).
var solutionId           = 'xdrlograider'
var solutionVersion      = '0.1.0-beta'
var solutionName         = 'XdrLogRaider'
var solutionPublisher    = 'Community'
var solutionDescription  = 'Microsoft Sentinel custom connector ingesting Defender XDR portal-only telemetry (45 streams across 7 tiers) — configuration, compliance, drift, exposure, governance, identity (MDI), audit, metadata. PowerShell Function App + DCE/DCR + parsers + workbooks + analytic rules + hunting queries.'

var dataConnectorContentId = 'XdrLogRaiderInternal'
var dataConnectorTitle     = 'XdrLogRaider — Defender XDR portal telemetry'

// Author / support — surfaces under the Solution and Connector cards.
var solutionAuthor  = { name: 'Alex Kefallonitis',  email: 'al.kefallonitis@gmail.com' }
var solutionSupport = {
  name: 'XdrLogRaider'
  email: 'al.kefallonitis@gmail.com'
  tier:  'Community'
  link:  'https://github.com/akefallonitis/xdrlograider'
}
var solutionSource = { kind: 'Solution', name: solutionName, sourceId: solutionId }

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
}

// (1) Solution package — Content Hub catalog entry.
resource solutionPackage 'Microsoft.OperationalInsights/workspaces/providers/contentPackages@2023-04-01-preview' = {
  name: '${workspaceName}/Microsoft.SecurityInsights/${solutionId}'
  properties: {
    contentId:           solutionId
    contentKind:         'Solution'
    displayName:         solutionName
    publisherDisplayName: solutionPublisher
    description:         solutionDescription
    version:             solutionVersion
    source:              solutionSource
    author:              solutionAuthor
    support:             solutionSupport
    icon:                ''
    contentProductId:    '${solutionId}-sl-${solutionVersion}'
    providers: [ solutionName ]
    firstPublishDate: '2026-04-25'
    categories: {
      domains: [ 'Security - Threat Protection' ]
    }
  }
}

// (2) Solution-level metadata link.
resource solutionMetadata 'Microsoft.OperationalInsights/workspaces/providers/metadata@2023-04-01-preview' = {
  name: '${workspaceName}/Microsoft.SecurityInsights/Solution-${solutionId}'
  properties: {
    parentId:  solutionPackage.id
    contentId: solutionId
    kind:      'Solution'
    version:   solutionVersion
    source:    solutionSource
    author:    solutionAuthor
    support:   solutionSupport
  }
  dependsOn: [
    solutionPackage
  ]
}

// (3) Data Connector instance — appears in Sentinel → Data Connectors.
// kind=StaticUI is the same kind first-party MS solutions (Defender XDR, MDE,
// Office 365) use for connector cards that don't have an interactive
// Connect/Disconnect flow. Status comes from connectivityCriterias.
resource dataConnector 'Microsoft.OperationalInsights/workspaces/providers/dataConnectors@2023-04-01-preview' = {
  name: '${workspaceName}/Microsoft.SecurityInsights/${dataConnectorContentId}'
  kind: 'StaticUI'
  properties: {
    connectorUiConfig: {
      id:                  dataConnectorContentId
      title:               dataConnectorTitle
      publisher:           solutionPublisher
      descriptionMarkdown: 'Ingests Defender XDR portal-only telemetry — 45 streams of configuration, compliance, drift, exposure, governance, identity (MDI), audit, metadata that is **not** exposed by public Microsoft Graph Security / Defender XDR / MDE APIs.\n\n- 47 custom tables (45 data + Heartbeat + AuthTestResult)\n- 6 KQL parsers (drift via `hash(RawJson)`)\n- 14 analytic rules (ship disabled per best practice)\n- 9 hunting queries\n- 6 workbooks\n\nPowered by an unattended PowerShell Azure Function App authenticating to `security.microsoft.com` via Credentials+TOTP or Software Passkey.'
      graphQueriesTableName: 'MDE_Heartbeat_CL'
      graphQueries: [
        {
          metricName: 'Heartbeat (last 24h)'
          legend:     'XdrLogRaider heartbeats'
          baseQuery:  'MDE_Heartbeat_CL | where TimeGenerated > ago(24h) | summarize count() by bin(TimeGenerated, 1h)'
        }
      ]
      sampleQueries: [
        { description: 'Recent auth self-test results',                query: 'MDE_AuthTestResult_CL | order by TimeGenerated desc | take 10' }
        { description: 'Suppression rules modified in the last 24h',  query: 'MDE_SuppressionRules_CL | where TimeGenerated > ago(24h) | summarize arg_max(TimeGenerated, *) by EntityId | project TimeGenerated, EntityId, RawJson' }
      ]
      dataTypes: [
        { name: 'MDE_Heartbeat_CL',        lastDataReceivedQuery: 'MDE_Heartbeat_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_AuthTestResult_CL',   lastDataReceivedQuery: 'MDE_AuthTestResult_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_AdvancedFeatures_CL', lastDataReceivedQuery: 'MDE_AdvancedFeatures_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
      ]
      connectivityCriterias: [
        {
          type:  'IsConnectedQuery'
          value: [ 'MDE_Heartbeat_CL | where TimeGenerated > ago(1h) | count | where Count > 0' ]
        }
      ]
      availability: { status: 1, isPreview: true }
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
            description: 'Dedicated read-only Entra service account (Security Reader + MDE Analyst) with Credentials+TOTP or Software Passkey configured.'
          }
        ]
      }
      instructionSteps: [
        {
          title: 'Upload auth secrets to Key Vault'
          description: 'Either provide them via the deploy wizard (Authentication step → Upload via wizard) **or** run the helper script after deploy:'
          instructions: [
            { type: 'CopyableLabel', parameters: { label: 'git clone https://github.com/akefallonitis/xdrlograider && cd xdrlograider && ./tools/Initialize-XdrLogRaiderAuth.ps1 -KeyVaultName <from-deployment-output>' } }
          ]
        }
        {
          title: 'Wait for self-test'
          description: 'Within 5 minutes the Function App validates auth and writes to MDE_AuthTestResult_CL:'
          instructions: [
            { type: 'CopyableLabel', parameters: { label: 'MDE_AuthTestResult_CL | order by TimeGenerated desc | take 1 | project TimeGenerated, Success, Stage, FailureReason' } }
          ]
        }
      ]
    }
  }
  dependsOn: [
    solutionPackage
  ]
}

// (4) DataConnector → Solution metadata link.
resource dataConnectorMetadata 'Microsoft.OperationalInsights/workspaces/providers/metadata@2023-04-01-preview' = {
  name: '${workspaceName}/Microsoft.SecurityInsights/DataConnector-${dataConnectorContentId}'
  properties: {
    parentId:  dataConnector.id
    contentId: dataConnectorContentId
    kind:      'DataConnector'
    version:   solutionVersion
    source:    solutionSource
    author:    solutionAuthor
    support:   solutionSupport
  }
  dependsOn: [
    dataConnector
  ]
}

output solutionId            string = solutionId
output solutionVersion       string = solutionVersion
output dataConnectorId       string = dataConnectorContentId
