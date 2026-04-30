// XdrLogRaider — main deployment template.
//
// Topology (v0.1.0-beta): the customer ALREADY HAS a Sentinel-enabled Log
// Analytics workspace. This template does NOT create or modify the workspace
// itself. It deploys:
//   - Connector resources in the target RG (Function App + plan + KV + Storage + App Insights + DCE + DCR)
//   - 47 custom tables (46 data + Heartbeat) inside the customer's workspace (cross-RG if needed)
//   - A Sentinel Solution package (XdrLogRaider) + GenericUI Data Connector card so the connector
//     appears in Sentinel → Data Connectors alongside Microsoft Defender XDR / MDE / etc.
//     (kind=GenericUI + apiVersion=2021-03-01-preview is the canonical pair for FA-based
//     community connectors per Trend Micro Vision One reference, verified active in
//     Azure-Sentinel master 2026-04-24)
//   - Sentinel content (parsers + 14 analytic rules + 9 hunting queries + 6 workbooks)
//     when deploySentinelContent=true (default)
//
// Cross-RG / cross-region is supported: the workspace can live in any RG of any subscription
// in the same tenant. DCE + DCR are created in the workspace's region (regional constraint of
// Azure Monitor Logs Ingestion API). Connector resources (FA, KV, Storage, AI) live in the
// target RG's region — they don't share the workspace's regional constraint.

targetScope = 'resourceGroup'

// ============================================================================
// PARAMETERS — all wizard-surfaced
// ============================================================================

@description('Project prefix — used in resource names. 3-12 lowercase alphanumeric.')
@minLength(3)
@maxLength(12)
param projectPrefix string = 'xdrlr'

@description('Environment tag. Used in resource names when legacyEnvInName=true (default for in-place upgrade compatibility with existing deployments); always emitted as the `environment` Azure resource tag regardless.')
@allowed([ 'dev', 'staging', 'prod' ])
param env string = 'prod'

@description('When true (default), resource names include the environment token (e.g. xdrlr-prod-fn-n2hhhc) for backward-compat with existing deployments. When false, resource names are environment-neutral (e.g. xdrlr-fn-n2hhhc) and environment is applied as a tag on every resource. The v1.2 Marketplace baseline flips this to false.')
param legacyEnvInName bool = true

@description('Region for connector resources (Function App, KV, Storage, App Insights). Defaults to the target RG region.')
param connectorLocation string = resourceGroup().location

@description('REQUIRED: Full ARM resource ID of the existing Sentinel-enabled Log Analytics workspace. The workspace must exist before deployment. Can be in any RG of any subscription in the same tenant.')
@minLength(1)
param existingWorkspaceId string

@description('REQUIRED: Azure region of the existing workspace. DCE + DCR MUST be in this region (regional constraint of Azure Monitor). Example: eastus, westeurope.')
@minLength(1)
param workspaceLocation string

@description('UPN of the dedicated service account the connector authenticates AS. Must be read-only: Security Reader + MDE Analyst roles.')
param serviceAccountUpn string

@description('Auth method the connector uses for portal sign-in. Both are unattended and auto-refreshing.')
@allowed([ 'credentials_totp', 'passkey' ])
param authMethod string = 'credentials_totp'

@description('Function App hosting plan tier. Trade-off: cost vs security/reliability. See docs/HOSTING-PLANS.md.\n  consumption-y1 (DEFAULT): cheapest (~$0-10/mo); partial Managed Identity (AzureWebJobsStorage uses MI; the content share still uses a shared key — Microsoft platform limit on Y1 Linux); residual PrivEsc risk if a Function App Contributor identity is compromised. Recommended for lab / dev / cost-constrained / non-sensitive XDR data.\n  flex-fc1     : production-hardened (~$10-30/mo); FULL Managed Identity (no shared keys anywhere); closed PrivEsc chain. Recommended for production / business-critical.\n  premium-ep1  : regulated / compliance (~$140-300/mo); full MI + always-warm + private-endpoint capable. Recommended for financial / healthcare / government.')
@allowed([ 'consumption-y1', 'flex-fc1', 'premium-ep1' ])
param hostingPlan string = 'consumption-y1'

@description('Restrict public network access on Storage / Key Vault / App Insights to the Function App outbound IP range. Default false for v0.1.0-beta (works in any tenant). Set true for Marketplace v1.2 / regulated deploys (operator must have VNet + private endpoints ready).')
param restrictPublicNetwork bool = false

@description('Enable Azure Diagnostic Settings on Key Vault to send audit logs (Get/List Secrets, etc.) to the Sentinel workspace. Default true. Required for forensic visibility on credential access.')
param enableKeyVaultDiagnostics bool = true

@description('DEPRECATED: use `hostingPlan` instead. Retained for backward-compatibility with existing deployments; if `hostingPlan` is unset, this maps consumption-y1=Y1 / flex-fc1=FC1 / premium-ep1=EP1.')
@allowed([ 'Y1', 'FC1', 'EP1', 'EP2' ])
param functionPlanSku string = 'Y1'

@description('GitHub repo owner/name for the Function App code ZIP. Override only if you forked.')
param githubRepo string = 'akefallonitis/xdrlograider'

@description('Deploy Sentinel content (parsers/hunting/analytic rules/workbooks). Set false for connector-only deploys.')
param deploySentinelContent bool = true

@description('Optional. Service account password (credentials_totp method). Empty = upload via post-deploy script.')
@secure()
param servicePassword string = ''

@description('Optional. TOTP Base32 seed (credentials_totp method). Empty = upload via post-deploy script or no MFA.')
@secure()
param totpSeed string = ''

@description('Optional. Passkey JSON blob (passkey method). Empty = upload via post-deploy script.')
@secure()
param passkeyJson string = ''

// ============================================================================
// DERIVED VARIABLES
// ============================================================================

var uniq      = uniqueString(resourceGroup().id, projectPrefix, env)
var suffix    = substring(uniq, 0, 6)

// When legacyEnvInName=true, resource names embed the env token
// (xdrlr-prod-fn-n2hhhc) — preserves the names of existing deployments for
// in-place upgrade. When false, names are env-neutral (xdrlr-fn-n2hhhc) and
// the env signal is carried solely by the `environment` Azure tag (see
// commonTags below). The v1.2 Marketplace baseline flips this to false.
//
// Pattern: `${projectPrefix}-${envSegment}<typeShort>-${suffix}`
//   legacyEnvInName=true  → envSegment = '${env}-'   → xdrlr-prod-fn-abc123
//   legacyEnvInName=false → envSegment = ''          → xdrlr-fn-abc123
// Storage account form differs only by the missing dashes (3-24 lowercase alnum).
var envSegment    = legacyEnvInName ? '${env}-' : ''
var stEnvSegment  = legacyEnvInName ? env : ''

// Connector-local resource names (all live in the target RG, at connectorLocation)
var funcName  = '${projectPrefix}-${envSegment}fn-${suffix}'
var planName  = '${projectPrefix}-${envSegment}plan'
var kvName    = '${projectPrefix}-${envSegment}kv-${suffix}'
// Storage account name MUST be 3-24 lowercase alphanumeric, no hyphens.
var stName    = toLower(replace('${projectPrefix}${stEnvSegment}st${suffix}', '-', ''))
var dceName   = '${projectPrefix}-${envSegment}dce'
var dcrName   = '${projectPrefix}-${envSegment}dcr'
var aiName    = '${projectPrefix}-${envSegment}ai'

// Env-as-tag pattern. Every connector-local resource carries these tags so the
// environment signal is carried by ARM tags regardless of whether
// legacyEnvInName=true or false. The `environment` tag is the canonical
// signal; the others document provenance for operators.
var commonTags = {
  'managed-by':       'XdrLogRaider'
  environment:        env
  project:            projectPrefix
}

// Parse the workspace resource ID to extract subscription + RG for cross-RG deploys.
// Format: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<name>
var workspaceSubscriptionId = split(existingWorkspaceId, '/')[2]
var workspaceResourceGroup  = split(existingWorkspaceId, '/')[4]
var workspaceName           = last(split(existingWorkspaceId, '/'))

// WEBSITE_RUN_FROM_PACKAGE points at GitHub Releases /latest/download — Marketplace
// best practice for community connectors. Each release ships a `function-app.zip`
// asset; GitHub's /latest endpoint resolves to the most-recent non-prerelease tag.
// To pin a specific tag (e.g. for staged rollouts) override packageUrl directly.
// See docs/DEPLOY-METHODS.md → "Advanced: pinning a specific release".
var packageUrl = 'https://github.com/${githubRepo}/releases/latest/download/function-app.zip'

// hostingPlan tier derivations.
// `useFullManagedIdentity` is true when the operator picked a tier where Azure
// Functions supports MI for BOTH AzureWebJobsStorage AND
// WEBSITE_CONTENTAZUREFILECONNECTIONSTRING. Y1 Linux Consumption only supports
// MI for the former (Microsoft platform limit), so it falls back to shared
// key on the content share — that's the documented residual risk.
var useFullManagedIdentity = hostingPlan != 'consumption-y1'

// `disableSharedKey` flips `allowSharedKeyAccess: false` on the storage account.
// Only safe when both env vars use MI; on Y1, the content share still requires
// the shared key, so we MUST keep allowSharedKeyAccess: true on Y1.
var disableSharedKey = useFullManagedIdentity

// `serverfarmSku` maps hostingPlan → the actual SKU passed to Microsoft.Web/serverfarms.
var serverfarmSku = hostingPlan == 'consumption-y1' ? 'Y1' : (hostingPlan == 'flex-fc1' ? 'FC1' : 'EP1')

// `serverfarmTier` is the elastic-tier label. Y1 = Dynamic; FC1 = FlexConsumption; EP* = ElasticPremium.
var serverfarmTier = hostingPlan == 'consumption-y1' ? 'Dynamic' : (hostingPlan == 'flex-fc1' ? 'FlexConsumption' : 'ElasticPremium')

// `alwaysOn` = supported for EP*; on Y1 it's not allowed; on FC1 controlled by AlwaysReady instances (default 0).
var alwaysOn = hostingPlan == 'premium-ep1'

// ============================================================================
// MODULES — workspace-scoped (cross-RG into the customer's Sentinel RG)
// ============================================================================

// Custom tables: created as sub-resources of the EXISTING workspace. Deployed at
// the workspace's RG scope because sub-resource creation requires the workspace's
// own RG context (Azure RBAC + resource-provider semantics).
module customTables 'modules/custom-tables.bicep' = {
  name: 'tables-${uniq}'
  scope: resourceGroup(workspaceSubscriptionId, workspaceResourceGroup)
  params: {
    workspaceName: workspaceName
  }
}

// Sentinel Solution package + Data Connector card. Emits 3 workspace sub-
// resources (contentPackages + GenericUI dataConnector + DataConnector
// metadata) so XdrLogRaider appears in Content Hub AND in the Data Connectors
// blade alongside Microsoft Defender XDR / MDE / etc. — same shape Microsoft
// uses for community FA-based connectors (Trend Micro Vision One, Auth0, etc.,
// per Azure-Sentinel master verified 2026-04-26).
//
// metadata kind=Solution is intentionally NOT emitted (per AbnormalSecurity
// reference, 2026-02-17): keeping it triggered a Sentinel API
// parentId/contentId mismatch on FA-based community connectors.
//
// Always deploys (no condition) so the connector card and Solution wrapper
// are present even when deploySentinelContent=false. Per-item metadata links
// for analytic rules / hunting / workbooks / parsers live in sentinelContent
// and only deploy when that toggle is true.
module sentinelSolution 'modules/data-connector.bicep' = {
  name: 'solution-${uniq}'
  scope: resourceGroup(workspaceSubscriptionId, workspaceResourceGroup)
  params: {
    workspaceName: workspaceName
  }
  dependsOn: [
    customTables
  ]
}

// ============================================================================
// MODULES — connector-local (in target RG at connectorLocation)
// ============================================================================

// DCE + DCR must be in the WORKSPACE'S region (Azure Monitor constraint). They live
// in the target RG (connector-local) but use workspaceLocation for `location`.
module dceDcr 'modules/dce-dcr.bicep' = {
  name: 'dce-${uniq}'
  params: {
    dceName: dceName
    dcrName: dcrName
    location: workspaceLocation              // MUST match workspace region
    workspaceResourceId: existingWorkspaceId // full cross-RG resource ID
    tags: commonTags
  }
  dependsOn: [
    customTables
  ]
}

// Storage (checkpoint table)
module storage 'modules/storage.bicep' = {
  name: 'st-${uniq}'
  params: {
    storageAccountName: stName
    location: connectorLocation
    disableSharedKey: disableSharedKey
    restrictPublicNetwork: restrictPublicNetwork
    tags: commonTags
  }
}

// Key Vault
module keyVault 'modules/key-vault.bicep' = {
  name: 'kv-${uniq}'
  params: {
    keyVaultName: kvName
    location: connectorLocation
    restrictPublicNetwork: restrictPublicNetwork
    enableDiagnostics: enableKeyVaultDiagnostics
    workspaceResourceId: existingWorkspaceId
    tags: commonTags
  }
}

// App Insights (workspace-based — telemetry lands in the same Sentinel workspace)
module appInsights 'modules/app-insights.bicep' = {
  name: 'ai-${uniq}'
  params: {
    appInsightsName: aiName
    location: connectorLocation
    workspaceResourceId: existingWorkspaceId
    restrictPublicNetwork: restrictPublicNetwork
    tags: commonTags
  }
}

// Function App
module functionApp 'modules/function-app.bicep' = {
  name: 'fn-${uniq}'
  params: {
    functionAppName: funcName
    planName: planName
    location: connectorLocation
    storageAccountName: storage.outputs.storageAccountName
    appInsightsConnectionString: appInsights.outputs.connectionString
    serverfarmSku: serverfarmSku
    serverfarmTier: serverfarmTier
    useFullManagedIdentity: useFullManagedIdentity
    alwaysOn: alwaysOn
    packageUrl: packageUrl
    tags: commonTags
    appSettings: {
      AUTH_METHOD:           authMethod
      SERVICE_ACCOUNT_UPN:   serviceAccountUpn
      KEY_VAULT_URI:         keyVault.outputs.vaultUri
      AUTH_SECRET_NAME:      'mde-portal-auth'
      DCE_ENDPOINT:          dceDcr.outputs.dceIngestionEndpoint
      DCR_IMMUTABLE_ID:      dceDcr.outputs.dcrImmutableId
      STORAGE_ACCOUNT_NAME:  storage.outputs.storageAccountName
      CHECKPOINT_TABLE_NAME: 'connectorCheckpoints'
      // App Insights adaptive-sampling exemption. These three custom-event
      // names carry critical operator-actionable signal (auth failures,
      // rate-limit pressure, ingest gaps) and MUST NOT be dropped under load.
      // The Functions host honours this env var across its TelemetryProcessor
      // pipeline. See:
      //   https://learn.microsoft.com/azure/azure-monitor/app/sampling-classic-api
      APPLICATIONINSIGHTS_TELEMETRY_SAMPLING_EXCLUDED_TYPES: 'AuthChain.AADSTSError;AuthChain.RateLimited;AuthChain.BoundaryMarker'
    }
  }
}

// Role assignments: grant the FA's Managed Identity the minimum roles it needs.
// Up to 6 roles depending on hostingPlan tier (3 for Y1; 6 for FC1/EP1 where
// the content share also moves to Managed Identity).
// All scoped to connector-local resources — no cross-RG / RG-level grants.
module roles 'modules/role-assignments.bicep' = {
  name: 'roles-${uniq}'
  params: {
    functionAppPrincipalId: functionApp.outputs.principalId
    keyVaultName:           keyVault.outputs.vaultName
    storageAccountName:     storage.outputs.storageAccountName
    dcrResourceId:          dceDcr.outputs.dcrResourceId
    useFullManagedIdentity: useFullManagedIdentity
  }
}

// ============================================================================
// OUTPUTS
// ============================================================================

output functionAppName     string = functionApp.outputs.functionAppName
output keyVaultName        string = keyVault.outputs.vaultName
output storageAccountName  string = storage.outputs.storageAccountName
output dceEndpoint         string = dceDcr.outputs.dceIngestionEndpoint
output dcrImmutableId      string = dceDcr.outputs.dcrImmutableId
output workspaceId         string = existingWorkspaceId
output workspaceRg         string = workspaceResourceGroup
output workspaceLocation   string = workspaceLocation

// Conditional next-step text. When the wizard supplied all required auth
// secrets via the secure parameters, the connector is fully bootstrapped and
// the operator only needs to wait for the first heartbeat / poll. Otherwise,
// surface the exact command to upload the secrets via the helper script.
var wizardSecretsProvided = (authMethod == 'credentials_totp' && length(servicePassword) > 0 && length(totpSeed) > 0) || (authMethod == 'passkey' && length(passkeyJson) > 0)
output postDeployCommand string = wizardSecretsProvided
  ? 'Auth secrets uploaded by deploy. Heartbeat expected within 5-10 minutes in workspace: MDE_Heartbeat_CL | top 1 by TimeGenerated. Auth chain diagnostics: App Insights customEvents | where name startswith "AuthChain.". KV: ${kvName}'
  : 'git clone https://github.com/${githubRepo} && cd xdrlograider && ./tools/Initialize-XdrLogRaiderAuth.ps1 -KeyVaultName ${kvName}'
