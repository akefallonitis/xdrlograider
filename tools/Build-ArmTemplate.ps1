<#
.SYNOPSIS
    Generates deploy/mainTemplate.json from deploy/dcrs/*.json + sub-area list.

.DESCRIPTION
    Builds a Phase 1 ARM template programmatically — deterministic + diffable +
    testable. Inlines 19 DCRs, 19 workspace tables, and the appSettings DCR
    immutable-ID map. No Sentinel content (analytic rules/workbooks/hunting/parsers)
    per Phase 1 ship lock — those land in v0.3.0 via Build-SentinelSolution.ps1
    extension.

    Output is suitable for one-click `Deploy to Azure` against an existing
    Sentinel-enabled Log Analytics workspace.

.PARAMETER DcrDir
    Directory containing the 19 DCR JSON files (default: ../deploy/dcrs/).

.PARAMETER OutputPath
    Output ARM template path (default: ../deploy/mainTemplate.json).
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [string] $DcrDir     = (Join-Path $PSScriptRoot '..' 'deploy' 'dcrs'),
    [string] $OutputPath = (Join-Path $PSScriptRoot '..' 'deploy' 'mainTemplate.json')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$SubAreas = @(
    'action_center', 'attack_simulator', 'cloud_apps', 'configuration', 'data_lake',
    'endpoint_configuration', 'endpoint_devices', 'entity_pivots', 'exposure_management',
    'files', 'identity', 'multi_tenant', 'portal_services', 'secure_score',
    'sentinel_precision', 'streaming', 'threat_analytics', 'vulnerability_management'
)

function ConvertTo-PascalCase {
    param([Parameter(Mandatory)][string] $Snake)
    $parts = $Snake -split '_'
    ($parts | ForEach-Object {
        if ($_.Length -eq 0) { return '' }
        $_.Substring(0,1).ToUpperInvariant() + $_.Substring(1).ToLowerInvariant()
    }) -join ''
}

function ConvertTo-DashedSubArea {
    param([Parameter(Mandatory)][string] $Snake)
    $Snake -replace '_', '-'
}

# -----------------------------------------------------------------------------
# Parameters
# -----------------------------------------------------------------------------
$parameters = [ordered]@{
    projectPrefix = [ordered]@{
        type        = 'string'
        defaultValue = 'xdrlr'
        minLength   = 3
        maxLength   = 12
        metadata    = [ordered]@{ description = 'Project prefix used in resource names. 3-12 lowercase alphanumeric.' }
    }
    env = [ordered]@{
        type         = 'string'
        defaultValue = 'prod'
        allowedValues = @('dev','staging','prod')
        metadata     = [ordered]@{ description = 'Environment tag.' }
    }
    location = [ordered]@{
        type         = 'string'
        defaultValue = '[resourceGroup().location]'
        metadata     = [ordered]@{ description = 'Region for connector resources (Function App, Key Vault, Storage, Application Insights).' }
    }
    existingWorkspaceId = [ordered]@{
        type      = 'string'
        minLength = 1
        metadata  = [ordered]@{ description = 'Resource ID of an existing Sentinel-enabled Log Analytics workspace.' }
    }
    workspaceLocation = [ordered]@{
        type      = 'string'
        minLength = 1
        metadata  = [ordered]@{ description = 'Azure region of the existing workspace.' }
    }
    serviceAccountUpn = [ordered]@{
        type     = 'string'
        metadata = [ordered]@{ description = 'UPN of the read-only service account the connector authenticates as.' }
    }
    authMethod = [ordered]@{
        type          = 'string'
        defaultValue  = 'credentials_totp'
        allowedValues = @('credentials_totp','passkey')
        metadata      = [ordered]@{ description = 'Portal sign-in method.' }
    }
    planSku = [ordered]@{
        type          = 'string'
        defaultValue  = 'Y1'
        allowedValues = @('Y1','EP1','EP2','EP3')
        metadata      = [ordered]@{ description = 'Function App plan SKU. Y1 (Linux Consumption) is the cost-optimal default — pay-per-execution, ~$0 idle. EP1+ (Linux Premium ElasticPremium) is always-on (~$144/mo for EP1) with 60-min execution; pick if vulnerability_management first-poll (5M+ rows) exceeds Y1''s 10-min cap. Per-sub-area timer triggers + MaxPages caps (Rule 14) + LastCompletedPage checkpoint resume make Y1 viable for most tenants.' }
    }
    retentionInDays = [ordered]@{
        type         = 'int'
        defaultValue = 90
        minValue     = 30
        maxValue     = 730
        metadata     = [ordered]@{ description = 'Workspace table retention in days.' }
    }
    githubRepo = [ordered]@{
        type         = 'string'
        defaultValue = 'akefallonitis/xdrlograider'
        metadata     = [ordered]@{ description = 'GitHub repo hosting the Function App release.' }
    }
    releaseTag = [ordered]@{
        type         = 'string'
        defaultValue = 'latest'
        metadata     = [ordered]@{ description = 'GitHub release tag for function-app.zip download URL.' }
    }
    deployRoleAssignments = [ordered]@{
        type         = 'bool'
        defaultValue = $true
        metadata     = [ordered]@{ description = 'Deploy 3 role assignments to the FA SAMI (KV Secrets User on Key Vault, Storage Table Data Contributor on Storage, RG-scoped Monitoring Metrics Publisher). Default: true (initial deploy by Owner / User Access Administrator). Set FALSE when the deploying identity has only Contributor (cannot create role assignments) — operator then runs `az role assignment create` manually for the 3 grants after deploy succeeds.' }
    }
    deploySentinelContent = [ordered]@{
        type         = 'bool'
        defaultValue = $true
        metadata     = [ordered]@{ description = 'Deploy the Sentinel V2 content package (data connector card + 19 dataTypes) to the operator''s workspace so the connector appears in the Sentinel Content Hub Installed Solutions list. Default: true. Set false to deploy only the Function App + DCRs + Key Vault without registering the Sentinel solution.' }
    }
    sentinelContentTemplateUri = [ordered]@{
        type         = 'string'
        defaultValue = ''
        metadata     = [ordered]@{ description = 'URI of sentinelContent.json nested template. EMPTY (default) = relative-URI mode for Deploy-to-Azure URL deploys (resolved via uri(deployment().properties.templateLink.uri, ...)). Set explicitly to an absolute URL like https://github.com/akefallonitis/xdrlograider/releases/latest/download/sentinelContent.json for TemplateFile-based deploys where templateLink is null.' }
    }
    servicePassword = [ordered]@{
        type         = 'securestring'
        defaultValue = ''
        metadata     = [ordered]@{ description = 'Service account password (credentials_totp). Optional — operator can upload to KV later.' }
    }
    totpSeed = [ordered]@{
        type         = 'securestring'
        defaultValue = ''
        metadata     = [ordered]@{ description = 'TOTP Base32 seed (credentials_totp). Optional.' }
    }
    passkeyJson = [ordered]@{
        type         = 'securestring'
        defaultValue = ''
        metadata     = [ordered]@{ description = 'Passkey JSON blob (passkey). Optional.' }
    }
}

# -----------------------------------------------------------------------------
# Variables
# -----------------------------------------------------------------------------
$variables = [ordered]@{
    uniq    = "[uniqueString(resourceGroup().id, parameters('projectPrefix'), parameters('env'))]"
    suffix  = "[substring(variables('uniq'), 0, 6)]"
    funcName = "[concat(parameters('projectPrefix'), '-fn-', variables('suffix'))]"
    planName = "[concat(parameters('projectPrefix'), '-plan-', variables('suffix'))]"
    kvName   = "[concat(parameters('projectPrefix'), '-kv-', variables('suffix'))]"
    stName   = "[toLower(substring(concat(parameters('projectPrefix'), 'st', variables('suffix')), 0, 18))]"
    dceName  = "[concat(parameters('projectPrefix'), '-dce-', variables('suffix'))]"
    dcrName  = "[concat(parameters('projectPrefix'), '-dcr')]"
    aiName   = "[concat(parameters('projectPrefix'), '-ai-', variables('suffix'))]"
    packageUrl = "[concat('https://github.com/', parameters('githubRepo'), '/releases/', parameters('releaseTag'), '/download/function-app.zip')]"
    workspaceSubscriptionId = "[split(parameters('existingWorkspaceId'), '/')[2]]"
    workspaceResourceGroup  = "[split(parameters('existingWorkspaceId'), '/')[4]]"
    workspaceName           = "[last(split(parameters('existingWorkspaceId'), '/'))]"
    kvSecretsUserRoleId             = '4633458b-17de-408a-b874-0445c86b69e6'
    storageTableContributorRoleId   = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
    monitoringMetricsPublisherRoleId= '3913510d-42f4-4e42-8a64-420c390055eb'
    connectorVersion                = '0.1.0'
    connectorBuildId                = "[parameters('releaseTag')]"
    commonTag = [ordered]@{
        'managed-by' = 'XdrLogRaider'
        environment  = "[parameters('env')]"
        project      = "[parameters('projectPrefix')]"
        solution     = 'XdrLogRaider'
        repo         = "[parameters('githubRepo')]"
        managedBy    = 'ARM'
    }
}

# -----------------------------------------------------------------------------
# Resources — Storage Account + 4 tables
# -----------------------------------------------------------------------------
$resources = New-Object System.Collections.Generic.List[object]

$resources.Add([ordered]@{
    type       = 'Microsoft.Storage/storageAccounts'
    apiVersion = '2025-01-01'
    name       = "[variables('stName')]"
    location   = "[parameters('location')]"
    tags       = "[variables('commonTag')]"
    sku        = [ordered]@{ name = 'Standard_LRS' }
    kind       = 'StorageV2'
    properties = [ordered]@{
        minimumTlsVersion        = 'TLS1_2'
        allowBlobPublicAccess    = $false
        allowSharedKeyAccess     = $true
        supportsHttpsTrafficOnly = $true
    }
})

$tableServices = [ordered]@{
    type       = 'Microsoft.Storage/storageAccounts/tableServices'
    apiVersion = '2025-01-01'
    name       = "[concat(variables('stName'), '/default')]"
    dependsOn  = @("[resourceId('Microsoft.Storage/storageAccounts', variables('stName'))]")
    properties = @{}
}
$resources.Add($tableServices)

foreach ($tbl in @('connectorCheckpoints','xdrIngestDlq','XdrTierState','XdrTenantState')) {
    $resources.Add([ordered]@{
        type       = 'Microsoft.Storage/storageAccounts/tableServices/tables'
        apiVersion = '2025-01-01'
        name       = "[concat(variables('stName'), '/default/', '$tbl')]"
        dependsOn  = @("[resourceId('Microsoft.Storage/storageAccounts/tableServices', variables('stName'), 'default')]")
    })
}

# -----------------------------------------------------------------------------
# Resources — Key Vault + 5 secrets
# -----------------------------------------------------------------------------
$resources.Add([ordered]@{
    type       = 'Microsoft.KeyVault/vaults'
    apiVersion = '2024-11-01'
    name       = "[variables('kvName')]"
    location   = "[parameters('location')]"
    tags       = "[variables('commonTag')]"
    properties = [ordered]@{
        tenantId               = "[subscription().tenantId]"
        sku                    = [ordered]@{ family = 'A'; name = 'standard' }
        enableRbacAuthorization = $true
        # Soft-delete is mandatory in 2026 KV API versions; retention defaults to 7
        # (Azure default). Purge-protection is INTENTIONALLY left disabled — operators
        # enable per tenant compliance policy after deploy. Same with diagnostic
        # settings on KV/FA/Storage — operators wire them to their workspace via
        # operator-managed Diagnostic Settings, not via this connector's ARM.
        enableSoftDelete       = $true
        softDeleteRetentionInDays = 7
        enablePurgeProtection  = $false
        publicNetworkAccess    = 'Enabled'
    }
})

foreach ($s in @(
    [ordered]@{ Name = 'defender-upn';        Value = "[parameters('serviceAccountUpn')]" }
    [ordered]@{ Name = 'defender-password';   Value = "[parameters('servicePassword')]" }
    [ordered]@{ Name = 'defender-totp';       Value = "[parameters('totpSeed')]" }
    [ordered]@{ Name = 'defender-passkey';    Value = "[parameters('passkeyJson')]" }
    [ordered]@{ Name = 'defender-auth-method';Value = "[parameters('authMethod')]" }
)) {
    $resources.Add([ordered]@{
        type       = 'Microsoft.KeyVault/vaults/secrets'
        apiVersion = '2024-11-01'
        name       = "[concat(variables('kvName'), '/', '$($s.Name)')]"
        dependsOn  = @("[resourceId('Microsoft.KeyVault/vaults', variables('kvName'))]")
        properties = [ordered]@{ value = $s.Value }
    })
}

# -----------------------------------------------------------------------------
# Resources — Application Insights + App Service Plan (Linux Premium EP1)
# -----------------------------------------------------------------------------
$resources.Add([ordered]@{
    type       = 'Microsoft.Insights/components'
    apiVersion = '2020-02-02'
    name       = "[variables('aiName')]"
    location   = "[parameters('location')]"
    tags       = "[variables('commonTag')]"
    kind       = 'web'
    properties = [ordered]@{
        Application_Type = 'web'
        IngestionMode    = 'LogAnalytics'
        WorkspaceResourceId = "[parameters('existingWorkspaceId')]"
    }
})

$resources.Add([ordered]@{
    type       = 'Microsoft.Web/serverfarms'
    apiVersion = '2023-12-01'
    name       = "[variables('planName')]"
    location   = "[parameters('location')]"
    tags       = "[variables('commonTag')]"
    # Y1 (Consumption): sku.tier='Dynamic' kind='functionapp' reserved=true (Linux variant).
    # EP1+ (ElasticPremium): sku.tier='ElasticPremium' kind='linux' reserved=true + maximumElasticWorkerCount.
    sku        = "[if(equals(parameters('planSku'), 'Y1'), createObject('name', 'Y1', 'tier', 'Dynamic'), createObject('name', parameters('planSku'), 'tier', 'ElasticPremium'))]"
    kind       = "[if(equals(parameters('planSku'), 'Y1'), 'functionapp', 'linux')]"
    properties = "[if(equals(parameters('planSku'), 'Y1'), createObject('reserved', true()), createObject('reserved', true(), 'maximumElasticWorkerCount', 1))]"
})

# -----------------------------------------------------------------------------
# Resources — Data Collection Endpoint
# -----------------------------------------------------------------------------
$resources.Add([ordered]@{
    type       = 'Microsoft.Insights/dataCollectionEndpoints'
    apiVersion = '2023-03-11'
    name       = "[variables('dceName')]"
    location   = "[parameters('workspaceLocation')]"
    tags       = "[variables('commonTag')]"
    properties = [ordered]@{
        networkAcls = [ordered]@{ publicNetworkAccess = 'Enabled' }
    }
})

# -----------------------------------------------------------------------------
# Resources — Workspace tables (nested deployment, cross-RG safe)
# -----------------------------------------------------------------------------
$tableSchemas = @{}
# Per-sub-area: use the Rule 8 mandatory 10 cols
$mandatoryCols = @(
    [ordered]@{ name = 'TimeGenerated'; type = 'datetime' }
    [ordered]@{ name = 'Endpoint'; type = 'string' }
    [ordered]@{ name = 'EntityId'; type = 'string' }
    [ordered]@{ name = 'SuccessKind'; type = 'string' }
    [ordered]@{ name = 'HttpStatus'; type = 'int' }
    [ordered]@{ name = 'RawJson'; type = 'dynamic' }
    [ordered]@{ name = 'RawResponseBody'; type = 'string' }
    [ordered]@{ name = 'SubArea'; type = 'string' }
    [ordered]@{ name = 'Tier'; type = 'string' }
    [ordered]@{ name = 'LicenseHint'; type = 'string' }
)

$nestedTableResources = New-Object System.Collections.Generic.List[object]
foreach ($sub in $SubAreas) {
    $pascal = ConvertTo-PascalCase -Snake $sub
    $tableName = "Defender_${pascal}_CL"
    $nestedTableResources.Add([ordered]@{
        type       = 'Microsoft.OperationalInsights/workspaces/tables'
        apiVersion = '2023-09-01'
        name       = "[concat(parameters('workspaceName'), '/', '$tableName')]"
        properties = [ordered]@{
            plan                  = 'Analytics'
            retentionInDays       = "[parameters('retentionInDays')]"
            totalRetentionInDays  = "[parameters('retentionInDays')]"
            schema = [ordered]@{
                name    = $tableName
                columns = $mandatoryCols
            }
        }
    })
}

# ConnectorHealth workspace table (Decision 15 + H13): 11 typed cols + Notes dynamic.
# ConnectorVersion + ConnectorBuildId give operators at-a-glance "which build is
# deployed" from latest heartbeat row. Notes carries the LEAN aggregate JSON only
# (cardState, dlqDepth, openCircuits, fatalError) — per-stream detail lives in
# XdrTierState Storage Table (richer/cheaper queries, no LA cost).
$connectorHealthCols = @(
    [ordered]@{ name = 'TimeGenerated'; type = 'datetime' }
    [ordered]@{ name = 'FunctionName'; type = 'string' }
    [ordered]@{ name = 'Tier'; type = 'string' }
    [ordered]@{ name = 'Portal'; type = 'string' }
    [ordered]@{ name = 'StreamsAttempted'; type = 'int' }
    [ordered]@{ name = 'StreamsSucceeded'; type = 'int' }
    [ordered]@{ name = 'RowsIngested'; type = 'int' }
    [ordered]@{ name = 'LatencyMs'; type = 'int' }
    [ordered]@{ name = 'ConnectorVersion'; type = 'string' }
    [ordered]@{ name = 'ConnectorBuildId'; type = 'string' }
    [ordered]@{ name = 'Notes'; type = 'dynamic' }
)
$nestedTableResources.Add([ordered]@{
    type       = 'Microsoft.OperationalInsights/workspaces/tables'
    apiVersion = '2023-09-01'
    name       = "[concat(parameters('workspaceName'), '/', 'XdrConnectorHealth_CL')]"
    properties = [ordered]@{
        plan                 = 'Analytics'
        retentionInDays      = "[parameters('retentionInDays')]"
        totalRetentionInDays = "[parameters('retentionInDays')]"
        schema = [ordered]@{
            name    = 'XdrConnectorHealth_CL'
            columns = $connectorHealthCols
        }
    }
})

$resources.Add([ordered]@{
    type            = 'Microsoft.Resources/deployments'
    apiVersion      = '2024-03-01'
    name            = "[concat('customTables-', variables('suffix'))]"
    resourceGroup   = "[variables('workspaceResourceGroup')]"
    subscriptionId  = "[variables('workspaceSubscriptionId')]"
    properties = [ordered]@{
        mode       = 'Incremental'
        parameters = [ordered]@{
            workspaceName   = [ordered]@{ value = "[variables('workspaceName')]" }
            retentionInDays = [ordered]@{ value = "[parameters('retentionInDays')]" }
        }
        template = [ordered]@{
            '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
            contentVersion = '1.0.0.0'
            parameters     = [ordered]@{
                workspaceName   = [ordered]@{ type = 'string' }
                retentionInDays = [ordered]@{ type = 'int' }
            }
            resources      = $nestedTableResources.ToArray()
        }
    }
})

# -----------------------------------------------------------------------------
# Resources — 19 DCRs (inlined from deploy/dcrs/*.json)
# -----------------------------------------------------------------------------
$DcrDir = (Resolve-Path $DcrDir).Path
$dcrFiles = Get-ChildItem $DcrDir -Filter '*_dcr.json' | Sort-Object Name
$dcrStreamToInnerExpr = [ordered]@{}
foreach ($f in $dcrFiles) {
    $j = Get-Content -Raw $f.FullName | ConvertFrom-Json -Depth 30 -AsHashtable
    $resources.Add($j)
    # DCR's name field is a bracketed ARM expression like "[concat(variables('dcrName'), '-action-center')]".
    # For embedded ARM (inside DCR_IMMUTABLE_IDS_JSON concat), we need the INNER expression
    # without the outer brackets so the parent concat() can splice it cleanly.
    $name = [string]$j.name
    if ($name -match '^\[(.+)\]$') {
        $innerExpr = $matches[1]
    } else {
        # Literal name fallback — wrap in single quotes for ARM string literal
        $innerExpr = "'$name'"
    }
    foreach ($streamName in @($j.properties.streamDeclarations.Keys)) {
        $cleanStream = $streamName -replace '^Custom-', ''
        $dcrStreamToInnerExpr[$cleanStream] = $innerExpr
    }
}

# -----------------------------------------------------------------------------
# Resources — Function App (WEBSITE_RUN_FROM_PACKAGE + SAMI)
# -----------------------------------------------------------------------------
# Build the DCR_IMMUTABLE_IDS_JSON expression: a concat() that resolves each
# DCR's immutableId at deploy time and produces a JSON dict like:
#   {"Defender_ActionCenter_CL":"dcr-abc...","Defender_AttackSimulator_CL":"dcr-def...",...}
# ARM concat() pieces: literal '"<stream>":"' + reference(resourceId(...), api).immutableId + '"'.
# Separator between pairs: ',' literal.
$exprParts = New-Object System.Collections.Generic.List[string]
$exprParts.Add("'{'")  # opening brace
$first = $true
foreach ($streamCL in $dcrStreamToInnerExpr.Keys) {
    if (-not $first) { $exprParts.Add("','") }
    $first = $false
    $innerExpr = $dcrStreamToInnerExpr[$streamCL]
    # Pair piece: literal '"<stream>":"'
    $exprParts.Add("'`"$streamCL`":`"'")
    # Reference piece: reference(resourceId('Microsoft.Insights/dataCollectionRules', <innerExpr>), '2023-03-11').immutableId
    $exprParts.Add("reference(resourceId('Microsoft.Insights/dataCollectionRules', $innerExpr), '2023-03-11').immutableId")
    # Closing quote piece
    $exprParts.Add("'`"'")
}
$exprParts.Add("'}'")  # closing brace
$dcrIdsExpr = "[concat(" + ($exprParts -join ', ') + ")]"

$dcrDeps = New-Object System.Collections.Generic.List[string]
$dcrInnerExprs = New-Object System.Collections.Generic.List[string]
foreach ($f in $dcrFiles) {
    $j = Get-Content -Raw $f.FullName | ConvertFrom-Json -Depth 30
    $name = [string]$j.name
    $dcrDeps.Add($name)
    $inner = if ($name -match '^\[(.+)\]$') { $matches[1] } else { "'$name'" }
    $dcrInnerExprs.Add($inner)
}

$faAppSettings = [ordered]@{
    AzureWebJobsStorage                      = "[concat('DefaultEndpointsProtocol=https;AccountName=', variables('stName'), ';AccountKey=', listKeys(resourceId('Microsoft.Storage/storageAccounts', variables('stName')), '2025-01-01').keys[0].value, ';EndpointSuffix=', environment().suffixes.storage)]"
    # WEBSITE_CONTENTAZUREFILECONNECTIONSTRING + WEBSITE_CONTENTSHARE are required
    # for Y1 (Linux Consumption) — the runtime stores the package metadata in an
    # Azure Files share. EP1+ ignore these (harmless to keep, simplifies SKU switch).
    WEBSITE_CONTENTAZUREFILECONNECTIONSTRING = "[concat('DefaultEndpointsProtocol=https;AccountName=', variables('stName'), ';AccountKey=', listKeys(resourceId('Microsoft.Storage/storageAccounts', variables('stName')), '2025-01-01').keys[0].value, ';EndpointSuffix=', environment().suffixes.storage)]"
    WEBSITE_CONTENTSHARE                     = "[toLower(variables('funcName'))]"
    FUNCTIONS_EXTENSION_VERSION              = '~4'
    FUNCTIONS_WORKER_RUNTIME                 = 'powershell'
    FUNCTIONS_WORKER_RUNTIME_VERSION         = '7.4'
    FUNCTIONS_WORKER_PROCESS_COUNT           = '1'
    PSWorkerInProcConcurrencyUpperBound      = '1'
    APPLICATIONINSIGHTS_CONNECTION_STRING    = "[reference(resourceId('Microsoft.Insights/components', variables('aiName')), '2020-02-02').ConnectionString]"
    WEBSITE_RUN_FROM_PACKAGE                 = "[variables('packageUrl')]"
    CONNECTOR_VERSION                        = "[variables('connectorVersion')]"
    CONNECTOR_BUILD_ID                       = "[variables('connectorBuildId')]"
    AUTH_METHOD                              = "[parameters('authMethod')]"
    SERVICE_ACCOUNT_UPN                      = "[parameters('serviceAccountUpn')]"
    KEY_VAULT_URI                            = "[reference(resourceId('Microsoft.KeyVault/vaults', variables('kvName')), '2024-11-01').vaultUri]"
    AUTH_SECRET_NAME                         = 'defender'
    DCE_ENDPOINT                             = "[reference(resourceId('Microsoft.Insights/dataCollectionEndpoints', variables('dceName')), '2023-03-11').logsIngestion.endpoint]"
    DCR_IMMUTABLE_IDS_JSON                   = $dcrIdsExpr
    STORAGE_ACCOUNT_NAME                     = "[variables('stName')]"
    CHECKPOINT_TABLE_NAME                    = 'connectorCheckpoints'
    XDR_INGEST_DLQ_TABLE_NAME                = 'xdrIngestDlq'
    TENANT_ID                                = "[subscription().tenantId]"
    KV_CACHE_TTL_MINUTES                     = '60'
    APPLICATIONINSIGHTS_TELEMETRY_SAMPLING_EXCLUDED_TYPES = 'AuthChain.AADSTSError;AuthChain.RateLimited;AuthChain.BoundaryMarker'
}

$faSettingsArray = @($faAppSettings.GetEnumerator() | ForEach-Object {
    [ordered]@{ name = $_.Key; value = $_.Value }
})

$faDependsOn = @(
    "[resourceId('Microsoft.Storage/storageAccounts', variables('stName'))]"
    "[resourceId('Microsoft.KeyVault/vaults', variables('kvName'))]"
    "[resourceId('Microsoft.Insights/components', variables('aiName'))]"
    "[resourceId('Microsoft.Web/serverfarms', variables('planName'))]"
    "[resourceId('Microsoft.Insights/dataCollectionEndpoints', variables('dceName'))]"
)
foreach ($inner in $dcrInnerExprs) {
    $faDependsOn += "[resourceId('Microsoft.Insights/dataCollectionRules', $inner)]"
}

$resources.Add([ordered]@{
    type       = 'Microsoft.Web/sites'
    apiVersion = '2023-12-01'
    name       = "[variables('funcName')]"
    location   = "[parameters('location')]"
    tags       = "[variables('commonTag')]"
    kind       = 'functionapp,linux'
    identity   = [ordered]@{ type = 'SystemAssigned' }
    properties = [ordered]@{
        serverFarmId = "[resourceId('Microsoft.Web/serverfarms', variables('planName'))]"
        httpsOnly    = $true
        siteConfig = [ordered]@{
            linuxFxVersion = 'POWERSHELL|7.4'
            ftpsState      = 'Disabled'
            appSettings    = $faSettingsArray
        }
    }
    dependsOn  = $faDependsOn
})

# -----------------------------------------------------------------------------
# Diagnostic Settings INTENTIONALLY NOT EMITTED here. Operators wire FA/KV/Storage
# diagnostic settings to their own workspace per tenant compliance policy — the
# connector ARM template should not force a specific audit posture. Post-deploy
# operators can run: `az monitor diagnostic-settings create --name xdrlr-fa-diag
# --resource <FA> --workspace <ws> --logs '[...]'`.
#
# Role assignments — FA's SAMI receives:
#   KV Secrets User (read secrets) on Key Vault
#   Storage Table Data Contributor on Storage account
#   Monitoring Metrics Publisher on each of the 19 DCRs
# -----------------------------------------------------------------------------
$samiPrincipalId = "[reference(resourceId('Microsoft.Web/sites', variables('funcName')), '2023-12-01', 'Full').identity.principalId]"

# All 3 RAs are gated on parameters('deployRoleAssignments') so operators whose
# deploying identity lacks Microsoft.Authorization/roleAssignments/write can set
# the parameter to false. They then create the 3 grants manually post-deploy
# via `az role assignment create`. Pattern ported from v1 pilot (production-proven).
$resources.Add([ordered]@{
    type       = 'Microsoft.Authorization/roleAssignments'
    apiVersion = '2022-04-01'
    condition  = "[parameters('deployRoleAssignments')]"
    name       = "[guid(resourceId('Microsoft.KeyVault/vaults', variables('kvName')), variables('funcName'), variables('kvSecretsUserRoleId'))]"
    scope      = "[concat('Microsoft.KeyVault/vaults/', variables('kvName'))]"
    dependsOn  = @("[resourceId('Microsoft.Web/sites', variables('funcName'))]")
    properties = [ordered]@{
        roleDefinitionId = "[resourceId('Microsoft.Authorization/roleDefinitions', variables('kvSecretsUserRoleId'))]"
        principalId      = $samiPrincipalId
        principalType    = 'ServicePrincipal'
    }
})

$resources.Add([ordered]@{
    type       = 'Microsoft.Authorization/roleAssignments'
    apiVersion = '2022-04-01'
    condition  = "[parameters('deployRoleAssignments')]"
    name       = "[guid(resourceId('Microsoft.Storage/storageAccounts', variables('stName')), variables('funcName'), variables('storageTableContributorRoleId'))]"
    scope      = "[concat('Microsoft.Storage/storageAccounts/', variables('stName'))]"
    dependsOn  = @("[resourceId('Microsoft.Web/sites', variables('funcName'))]")
    properties = [ordered]@{
        roleDefinitionId = "[resourceId('Microsoft.Authorization/roleDefinitions', variables('storageTableContributorRoleId'))]"
        principalId      = $samiPrincipalId
        principalType    = 'ServicePrincipal'
    }
})

# Monitoring Metrics Publisher — ONE RG-scoped assignment covers all 19 DCRs
# in the deploy RG (which createUiDefinition prompts operator to create fresh
# for this connector). Collapses 19 per-DCR RAs into 1 — 21 → 3 total RAs.
# Operators deploying into a shared RG with unrelated DCRs accept that SAMI
# can publish to those too; the fix is a dedicated RG, not 19 explicit RAs.
$resources.Add([ordered]@{
    type       = 'Microsoft.Authorization/roleAssignments'
    apiVersion = '2022-04-01'
    condition  = "[parameters('deployRoleAssignments')]"
    name       = "[guid(resourceGroup().id, variables('funcName'), variables('monitoringMetricsPublisherRoleId'))]"
    # No scope field → defaults to the deployment RG.
    dependsOn  = @(
        "[resourceId('Microsoft.Web/sites', variables('funcName'))]"
    )
    properties = [ordered]@{
        roleDefinitionId = "[resourceId('Microsoft.Authorization/roleDefinitions', variables('monitoringMetricsPublisherRoleId'))]"
        principalId      = $samiPrincipalId
        principalType    = 'ServicePrincipal'
    }
})

# -----------------------------------------------------------------------------
# Nested deployment: sentinelContent.json (v2 dataConnector card + contentPackage)
# Registers the XdrLogRaider solution in the operator's Sentinel Content Hub
# Installed Solutions list and provisions the data connector card. Without
# this nested deployment, Deploy-to-Azure only creates the FA + DCRs + KV
# and the connector card never appears in Sentinel UI.
#
# templateLink.uri resolution:
#   - Deploy-to-Azure URL deploys: templateLink.uri is set by Azure Portal to
#     the raw mainTemplate.json URL; we resolve sentinelContent.json relative
#     to it (uri(deployment().properties.templateLink.uri, 'sentinelContent.json')).
#   - az deployment group create --template-file: templateLink is null, so
#     the operator must pass sentinelContentTemplateUri explicitly (e.g. the
#     raw GitHub URL from a release).
# Pattern ported from the v1 pilot (production-proven across many tenants).
# -----------------------------------------------------------------------------
$resources.Add([ordered]@{
    type           = 'Microsoft.Resources/deployments'
    apiVersion     = '2024-03-01'
    name           = "[concat('sentinelContent-', variables('suffix'))]"
    condition      = "[parameters('deploySentinelContent')]"
    subscriptionId = "[variables('workspaceSubscriptionId')]"
    resourceGroup  = "[variables('workspaceResourceGroup')]"
    dependsOn      = @(
        "[concat('customTables-', variables('suffix'))]"
    )
    properties = [ordered]@{
        expressionEvaluationOptions = [ordered]@{ scope = 'inner' }
        mode = 'Incremental'
        templateLink = [ordered]@{
            uri            = "[if(empty(parameters('sentinelContentTemplateUri')), uri(deployment().properties.templateLink.uri, 'sentinelContent.json'), parameters('sentinelContentTemplateUri'))]"
            contentVersion = '1.0.0.0'
        }
        parameters = [ordered]@{
            workspaceName = [ordered]@{ value = "[variables('workspaceName')]" }
        }
    }
})

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
$outputs = [ordered]@{
    functionAppName    = [ordered]@{ type = 'string'; value = "[variables('funcName')]" }
    keyVaultName       = [ordered]@{ type = 'string'; value = "[variables('kvName')]" }
    storageAccountName = [ordered]@{ type = 'string'; value = "[variables('stName')]" }
    appInsightsName    = [ordered]@{ type = 'string'; value = "[variables('aiName')]" }
    dceEndpoint        = [ordered]@{ type = 'string'; value = "[reference(resourceId('Microsoft.Insights/dataCollectionEndpoints', variables('dceName')), '2023-03-11').logsIngestion.endpoint]" }
    dcrImmutableIdsJson= [ordered]@{ type = 'string'; value = $dcrIdsExpr }
}

# -----------------------------------------------------------------------------
# Assemble + emit
# -----------------------------------------------------------------------------
$template = [ordered]@{
    '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
    contentVersion = '1.0.0.0'
    metadata       = [ordered]@{
        _generator = [ordered]@{ name = 'Build-ArmTemplate.ps1 — deterministic single-source-of-truth' }
        comments   = 'XdrLogRaider GA v0.1.0 — Defender XDR portal-only telemetry connector. Requires an existing Sentinel-enabled Log Analytics workspace. Provisions 19 DCRs (18 per-sub-area + 1 ConnectorHealth) sharing 1 DCE; routes to 19 workspace tables (18 Defender_<Sub>_CL + 1 XdrConnectorHealth_CL). Operators bring their own KQL — no analytic rules/workbooks/hunting queries/parsers in Phase 1 ship.'
    }
    parameters     = $parameters
    variables      = $variables
    resources      = $resources.ToArray()
    outputs        = $outputs
}

$json = ($template | ConvertTo-Json -Depth 50) -replace "`r`n", "`n" -replace "`r", "`n"
[System.IO.File]::WriteAllText($OutputPath, $json, [System.Text.UTF8Encoding]::new($false))

# Verify it parses
$null = Get-Content -Raw $OutputPath | ConvertFrom-Json -Depth 50

$sizeKb = [math]::Round((Get-Item $OutputPath).Length / 1KB, 1)
$resCount = ($template.resources).Count
Write-Host "Wrote $OutputPath ($sizeKb KB · $resCount resources)"
Write-Host "  19 DCRs · 19 workspace tables (nested) · 3 role assignments (KV + Storage + RG-scoped MMP) · 4 storage tables · 5 KV secrets"
