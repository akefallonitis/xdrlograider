// XdrLogRaider Sentinel Solution + Data Connector card.
//
// Emits the THREE resources canonical to a Function-App-based community
// Sentinel solution (compare: Solutions/Trend Micro Vision One/Package/
// mainTemplate.json — the production reference for FA-push community
// connectors that surface in Sentinel → Data Connectors blade):
//
//   1. Microsoft.OperationalInsights/workspaces/providers/contentPackages
//        — the Solution wrapper. Makes "XdrLogRaider" appear in Content Hub.
//
//   2. Microsoft.OperationalInsights/workspaces/providers/dataConnectors (GenericUI)
//        — the actual connector card visible in Sentinel → Data Connectors,
//          alongside Microsoft Defender XDR / MDE / etc.
//        — kind=GenericUI is the canonical kind for community FA-based
//          connectors (Trend Micro Vision One, Auth0, etc). StaticUI is for
//          first-party Microsoft solutions (Defender XDR, MDE, Office 365)
//          and is treated differently by the Sentinel UI blade indexer when
//          the publisher is non-Microsoft.
//        — apiVersion 2021-03-01-preview is the older stable API used by
//          the community connector references in Azure-Sentinel master.
//
//   3. Microsoft.OperationalInsights/workspaces/providers/metadata (DataConnector)
//        — links the data connector instance back to the solution. parentId
//          uses extensionResourceId() form per Trend Micro reference.
//
// NOTE: We intentionally DO NOT emit a metadata kind=Solution resource. The
// AbnormalSecurity reference and Trend Micro reference both omit it; ARM
// rejects the deploy with `properties.contentId must match properties.parentId`
// when both metadata-Solution and contentPackages exist with different IDs.
// contentPackages alone provides the Solution catalog entry.
//
// Deployed unconditionally: even with deploySentinelContent=false the operator
// still sees a "XdrLogRaider" solution + connector card. Sentinel content
// (rules, hunting, workbooks, parsers) is deployed separately and links to the
// same solution via per-item metadata in sentinelContent.json.

@description('Log Analytics / Sentinel workspace name.')
param workspaceName string

// Stable identifiers — DO NOT change without a Solution version bump or every
// installation will appear as a new Solution side-by-side. The IDs match the
// Sentinel Solutions naming convention (`<publisher>.<solution-key>` —
// e.g. `azuresentinel.azure-sentinel-solution-abnormalsecurity`,
// `community.xdrlograider`).
var solutionId           = 'community.xdrlograider'
var solutionVersion      = '0.1.0-beta'
var solutionName         = 'XdrLogRaider'
var solutionPublisher    = 'Community'

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
//
// Required properties (Microsoft Sentinel content schema 3.0.0, verified against
// reference solutions in Azure-Sentinel repo, e.g. Solutions/Akamai Security
// Events/Package/mainTemplate.json):
//   - version              : the package version
//   - kind                 : 'Solution' (legacy field, paired with contentKind)
//   - contentSchemaVersion : '3.0.0' (REQUIRED — first deploy attempt was
//                            rejected with `properties.contentSchemaVersion is
//                            required` BadRequestException)
//   - displayName, publisherDisplayName, descriptionHtml
//   - contentKind          : 'Solution'
//   - contentProductId     : globally-unique product id (slug + version)
//   - id                   : same as contentProductId per Sentinel convention
//   - contentId            : the solution slug (stable across versions)
//   - parentId             : same as contentId (Sentinel uses this to chain content)
//   - source / author / support / providers / categories / firstPublishDate
//
// `icon` is a full HTML <img> tag pointing at the SVG logo in the repo at the
// pinned release tag. Empty-string causes Content Hub UI glitches; reference
// solutions emit either a full HTML img tag or omit the property entirely.
resource solutionPackage 'Microsoft.OperationalInsights/workspaces/providers/contentPackages@2023-04-01-preview' = {
  name: '${workspaceName}/Microsoft.SecurityInsights/${solutionId}'
  properties: {
    version:              solutionVersion
    kind:                 'Solution'
    contentSchemaVersion: '3.0.0'
    displayName:          solutionName
    publisherDisplayName: solutionPublisher
    description:          'Microsoft Sentinel custom connector ingesting Defender XDR portal-only telemetry — 45 streams across 7 tiers (configuration, compliance, drift, exposure, governance, identity/MDI, audit, metadata). Includes 47 custom tables, 6 KQL parsers, 14 analytic rules (ship disabled per best practice), 9 hunting queries, 6 workbooks. PowerShell 7.4 Function App authenticates to security.microsoft.com via Credentials+TOTP or Software Passkey. Source: https://github.com/akefallonitis/xdrlograider'
    descriptionHtml:      '<p>Microsoft Sentinel custom connector ingesting Defender XDR portal-only telemetry — 45 streams across 7 tiers (configuration, compliance, drift, exposure, governance, identity/MDI, audit, metadata).</p><p>Includes 47 custom tables, 6 KQL parsers, 14 analytic rules (ship disabled per best practice), 9 hunting queries, 6 workbooks. PowerShell 7.4 Function App authenticates to <code>security.microsoft.com</code> via Credentials+TOTP or Software Passkey.</p><p>Source: <a href="https://github.com/akefallonitis/xdrlograider">github.com/akefallonitis/xdrlograider</a></p>'
    contentKind:          'Solution'
    contentProductId:     '${solutionId}-sl-${solutionVersion}'
    id:                   '${solutionId}-sl-${solutionVersion}'
    icon:                 '<img src="https://raw.githubusercontent.com/akefallonitis/xdrlograider/v${solutionVersion}/deploy/solution/Images/Logo.svg" width="75px" height="75px">'
    contentId:            solutionId
    parentId:             solutionId
    source:               solutionSource
    author:               solutionAuthor
    support:              solutionSupport
    dependencies:         { criteria: [] }
    firstPublishDate:     '2026-04-25'
    lastPublishDate:      '2026-04-27'
    providers:            [ solutionName ]
    categories: {
      domains:   [ 'Security - Threat Protection' ]
      verticals: []
    }
    isPreview:            'true'
    isNew:                'true'
    threatAnalysisTactics:    [ 'InitialAccess', 'Persistence', 'PrivilegeEscalation', 'DefenseEvasion', 'CredentialAccess', 'Discovery', 'LateralMovement', 'Collection', 'CommandAndControl', 'Exfiltration', 'Impact' ]
    threatAnalysisTechniques: [ 'T1078', 'T1098', 'T1136', 'T1530', 'T1548', 'T1556', 'T1562', 'T1595' ]
  }
}

// (2) Data Connector instance — appears in Sentinel → Data Connectors.
//
// kind=GenericUI + apiVersion=2021-03-01-preview is the canonical pair for
// Function-App-based community connectors (Trend Micro Vision One reference).
// StaticUI is documented for first-party MS solutions (Defender XDR, MDE,
// Office 365); Sentinel's blade indexer treats StaticUI from non-Microsoft
// publishers differently than from MSFT, which causes the connector card to
// stay hidden in the Data Connectors blade after direct ARM deploy. GenericUI
// is the documented community kind that surfaces correctly without
// Marketplace/Content Hub install. Status comes from connectivityCriterias.
resource dataConnector 'Microsoft.OperationalInsights/workspaces/providers/dataConnectors@2021-03-01-preview' = {
  name: '${workspaceName}/Microsoft.SecurityInsights/${dataConnectorContentId}'
  kind: 'GenericUI'
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
      // 47-table dataTypes list (45 data + Heartbeat + AuthTestResult). Sourced
      // from deploy/solution/Data Connectors/XdrLogRaider_DataConnector.json
      // (single source of truth — keep both in sync).
      dataTypes: [
        { name: 'MDE_Heartbeat_CL',                lastDataReceivedQuery: 'MDE_Heartbeat_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_AuthTestResult_CL',           lastDataReceivedQuery: 'MDE_AuthTestResult_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_AdvancedFeatures_CL',         lastDataReceivedQuery: 'MDE_AdvancedFeatures_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_PreviewFeatures_CL',          lastDataReceivedQuery: 'MDE_PreviewFeatures_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_AlertServiceConfig_CL',       lastDataReceivedQuery: 'MDE_AlertServiceConfig_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_AlertTuning_CL',              lastDataReceivedQuery: 'MDE_AlertTuning_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_SuppressionRules_CL',         lastDataReceivedQuery: 'MDE_SuppressionRules_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_CustomDetections_CL',         lastDataReceivedQuery: 'MDE_CustomDetections_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_DeviceControlPolicy_CL',      lastDataReceivedQuery: 'MDE_DeviceControlPolicy_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_WebContentFiltering_CL',      lastDataReceivedQuery: 'MDE_WebContentFiltering_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_SmartScreenConfig_CL',        lastDataReceivedQuery: 'MDE_SmartScreenConfig_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_LiveResponseConfig_CL',       lastDataReceivedQuery: 'MDE_LiveResponseConfig_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_AuthenticatedTelemetry_CL',   lastDataReceivedQuery: 'MDE_AuthenticatedTelemetry_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_PUAConfig_CL',                lastDataReceivedQuery: 'MDE_PUAConfig_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_AntivirusPolicy_CL',          lastDataReceivedQuery: 'MDE_AntivirusPolicy_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_TenantAllowBlock_CL',         lastDataReceivedQuery: 'MDE_TenantAllowBlock_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_CustomCollection_CL',         lastDataReceivedQuery: 'MDE_CustomCollection_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_DataExportSettings_CL',       lastDataReceivedQuery: 'MDE_DataExportSettings_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_ConnectedApps_CL',            lastDataReceivedQuery: 'MDE_ConnectedApps_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_TenantContext_CL',            lastDataReceivedQuery: 'MDE_TenantContext_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_TenantWorkloadStatus_CL',     lastDataReceivedQuery: 'MDE_TenantWorkloadStatus_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_StreamingApiConfig_CL',       lastDataReceivedQuery: 'MDE_StreamingApiConfig_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_IntuneConnection_CL',         lastDataReceivedQuery: 'MDE_IntuneConnection_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_PurviewSharing_CL',           lastDataReceivedQuery: 'MDE_PurviewSharing_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_RbacDeviceGroups_CL',         lastDataReceivedQuery: 'MDE_RbacDeviceGroups_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_UnifiedRbacRoles_CL',         lastDataReceivedQuery: 'MDE_UnifiedRbacRoles_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_AssetRules_CL',               lastDataReceivedQuery: 'MDE_AssetRules_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_SAClassification_CL',         lastDataReceivedQuery: 'MDE_SAClassification_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_XspmInitiatives_CL',          lastDataReceivedQuery: 'MDE_XspmInitiatives_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_ExposureSnapshots_CL',        lastDataReceivedQuery: 'MDE_ExposureSnapshots_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        // iter-14.0: MDE_SecureScoreBreakdown_CL removed — Graph /security/secureScores covers
        { name: 'MDE_ExposureRecommendations_CL',  lastDataReceivedQuery: 'MDE_ExposureRecommendations_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_XspmAttackPaths_CL',          lastDataReceivedQuery: 'MDE_XspmAttackPaths_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_XspmChokePoints_CL',          lastDataReceivedQuery: 'MDE_XspmChokePoints_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_XspmTopTargets_CL',           lastDataReceivedQuery: 'MDE_XspmTopTargets_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_SecurityBaselines_CL',        lastDataReceivedQuery: 'MDE_SecurityBaselines_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_IdentityOnboarding_CL',       lastDataReceivedQuery: 'MDE_IdentityOnboarding_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_IdentityServiceAccounts_CL',  lastDataReceivedQuery: 'MDE_IdentityServiceAccounts_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_DCCoverage_CL',               lastDataReceivedQuery: 'MDE_DCCoverage_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_IdentityAlertThresholds_CL',  lastDataReceivedQuery: 'MDE_IdentityAlertThresholds_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_RemediationAccounts_CL',      lastDataReceivedQuery: 'MDE_RemediationAccounts_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_ActionCenter_CL',             lastDataReceivedQuery: 'MDE_ActionCenter_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_ThreatAnalytics_CL',          lastDataReceivedQuery: 'MDE_ThreatAnalytics_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_UserPreferences_CL',          lastDataReceivedQuery: 'MDE_UserPreferences_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_MtoTenants_CL',               lastDataReceivedQuery: 'MDE_MtoTenants_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_LicenseReport_CL',            lastDataReceivedQuery: 'MDE_LicenseReport_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
        { name: 'MDE_CloudAppsConfig_CL',          lastDataReceivedQuery: 'MDE_CloudAppsConfig_CL | summarize Time = max(TimeGenerated) | where isnotempty(Time)' }
      ]
      // connectivityCriterias: stronger summarize+project pattern per Trend
      // Micro Vision One + AbnormalSecurity reference. The legacy "| count |
      // where Count > 0" form caused "Disconnected" status in Sentinel UI
      // even with rows present.
      connectivityCriterias: [
        {
          type:  'IsConnectedQuery'
          value: [ 'MDE_Heartbeat_CL | summarize LastLogReceived = max(TimeGenerated) | project IsConnected = LastLogReceived > ago(1h)' ]
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

// (3) DataConnector → Solution metadata link.
//
// parentId uses extensionResourceId() form pointing at the
// 'Microsoft.SecurityInsights/dataConnectors' extension type — matches the
// Trend Micro Vision One reference and is required for Sentinel's blade
// indexer to chain the metadata back to the connector instance correctly.
// (Bicep symbolic `dataConnector.id` would compile to the
// `Microsoft.OperationalInsights/workspaces/providers/dataConnectors`
// resourceId() form, which the indexer treats as a different ID.)
resource dataConnectorMetadata 'Microsoft.OperationalInsights/workspaces/providers/metadata@2023-04-01-preview' = {
  name: '${workspaceName}/Microsoft.SecurityInsights/DataConnector-${dataConnectorContentId}'
  properties: {
    parentId:  extensionResourceId(resourceId('Microsoft.OperationalInsights/workspaces', workspaceName), 'Microsoft.SecurityInsights/dataConnectors', dataConnectorContentId)
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
