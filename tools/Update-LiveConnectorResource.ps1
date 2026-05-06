<#
.SYNOPSIS
    Surgically update the LIVE Sentinel data-connector resource without
    redeploying the whole ARM template.

.DESCRIPTION
    SECTION R+ DEPLOYMENT GAP (2026-05-06):
    Section R+ fixed the connectorUiConfig block in deploy/compiled/mainTemplate.json
    (dataTypes from MDE_*_CL stream identifiers to Defender_*_CL workspace tables;
    connectivityCriterias plural -> connectivityCriteria singular; tightened
    IsConnectedQuery guard). However, the ARM template only describes resources
    AT DEPLOY TIME. The data-connector resource that ALREADY EXISTS in the
    operator's workspace was created from the PRE-Section-R+ template and still
    holds the old broken block.

    Restarting the Function App fetches the new function-app.zip but does NOT
    touch the Sentinel UI's dataConnector resource. Result: card stays
    "Disconnected" forever even after the FA restart.

    This script PATCHes the live dataConnector resource via the Azure
    Microsoft.SecurityInsights REST API. Only that one resource changes; FA,
    DCRs, KV, Storage, AppInsights, workbooks, rules, hunting, parsers all
    untouched.

.PARAMETER SubscriptionId
    Azure subscription containing the workspace.

.PARAMETER WorkspaceResourceGroup
    Resource group of the Log Analytics workspace.

.PARAMETER WorkspaceName
    Name of the Log Analytics workspace.

.PARAMETER ConnectorId
    Connector instance ID. Default 'XdrLogRaiderInternal' (matches solution
    deploy/compiled/mainTemplate.json variables.dataConnectorId).

.PARAMETER WhatIf
    Show the new connectorUiConfig block + the REST URL but do NOT execute the
    PUT. Use this FIRST to operator-review the change.

.PARAMETER Force
    Skip the operator confirmation prompt. Required for non-interactive use
    (CI / scripts). NEVER use without prior -WhatIf review.

.EXAMPLE
    # Step 1 -- preview the change
    pwsh tools/Update-LiveConnectorResource.ps1 -SubscriptionId 'xxx' `
        -WorkspaceResourceGroup 'sentinel-rg' `
        -WorkspaceName 'sentinel-ws' `
        -WhatIf

    # Step 2 -- apply after review
    pwsh tools/Update-LiveConnectorResource.ps1 -SubscriptionId 'xxx' `
        -WorkspaceResourceGroup 'sentinel-rg' `
        -WorkspaceName 'sentinel-ws'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [Parameter(Mandatory)] [string] $WorkspaceResourceGroup,
    [Parameter(Mandatory)] [string] $WorkspaceName,
    [string] $ConnectorId = 'XdrLogRaiderInternal',
    [switch] $WhatIf,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

# -----------------------------------------------------------------------------
# Step 1: extract the canonical connectorUiConfig block from mainTemplate.json
# -----------------------------------------------------------------------------
$tplPath = Join-Path $RepoRoot 'deploy/compiled/mainTemplate.json'
if (-not (Test-Path $tplPath)) {
    throw "mainTemplate.json not found at $tplPath"
}
$tpl = Get-Content -Raw $tplPath | ConvertFrom-Json -Depth 100

function Find-ConnectorBlock {
    param($node)
    if (-not $node) { return $null }
    if ($node.properties -and $node.properties.connectorUiConfig -and $node.properties.connectorUiConfig.dataTypes) {
        return $node.properties.connectorUiConfig
    }
    if ($node.resources) {
        foreach ($child in $node.resources) {
            $found = Find-ConnectorBlock -node $child
            if ($found) { return $found }
        }
    }
    if ($node.properties -and $node.properties.template -and $node.properties.template.resources) {
        foreach ($child in $node.properties.template.resources) {
            $found = Find-ConnectorBlock -node $child
            if ($found) { return $found }
        }
    }
    return $null
}

$connectorBlock = $null
foreach ($res in $tpl.resources) {
    $connectorBlock = Find-ConnectorBlock -node $res
    if ($connectorBlock) { break }
}
if (-not $connectorBlock) { throw "No connectorUiConfig block found in $tplPath" }

# Concretize ARM-template variables/parameters that show up in the block at runtime
# (mainTemplate.json carries `[variables('dataConnectorId')]` placeholders — for
# the live PUT we substitute the literal $ConnectorId).
$blockJson = $connectorBlock | ConvertTo-Json -Depth 100
$blockJson = $blockJson -replace "\[variables\('dataConnectorId'\)\]", $ConnectorId
$blockJson = $blockJson -replace "\[variables\('solutionPublisher'\)\]", 'akefallonitis'
$concreteBlock = $blockJson | ConvertFrom-Json -Depth 100

# -----------------------------------------------------------------------------
# Step 2: build the resource URL
# -----------------------------------------------------------------------------
$apiVersion = '2024-10-01-preview'
$resourcePath = "/subscriptions/$SubscriptionId/resourceGroups/$WorkspaceResourceGroup/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName/providers/Microsoft.SecurityInsights/dataConnectors/$ConnectorId"
$url = "${resourcePath}?api-version=$apiVersion"

# -----------------------------------------------------------------------------
# Step 3: build the PUT body
# -----------------------------------------------------------------------------
$body = @{
    kind       = 'GenericUI'
    properties = @{
        connectorUiConfig = $concreteBlock
    }
} | ConvertTo-Json -Depth 100

Write-Host '=== Update-LiveConnectorResource ===' -ForegroundColor Cyan
Write-Host ('  Subscription   : {0}' -f $SubscriptionId) -ForegroundColor DarkGray
Write-Host ('  Workspace RG   : {0}' -f $WorkspaceResourceGroup) -ForegroundColor DarkGray
Write-Host ('  Workspace      : {0}' -f $WorkspaceName) -ForegroundColor DarkGray
Write-Host ('  Connector ID   : {0}' -f $ConnectorId) -ForegroundColor DarkGray
Write-Host ('  REST URL       : {0}' -f $url) -ForegroundColor DarkGray
Write-Host ''

# Show the deltas the operator should see in the new block
Write-Host '=== Block summary (post-update) ===' -ForegroundColor Cyan
Write-Host ('  dataTypes count   : {0}' -f @($concreteBlock.dataTypes).Count)
Write-Host ('  dataTypes names   : {0}' -f (($concreteBlock.dataTypes.name) -join ', '))
$crit = $concreteBlock.connectivityCriteria
$critPlural = $concreteBlock.connectivityCriterias
$critLabel = if ($crit) { 'connectivityCriteria (singular - CORRECT)' } elseif ($critPlural) { 'connectivityCriterias (plural - WRONG, Sentinel UI ignores)' } else { 'NONE' }
Write-Host ('  criteria key     : {0}' -f $critLabel)
if ($crit) {
    Write-Host ('  IsConnectedQuery  : {0}' -f ($crit[0].value[0]))
}
Write-Host ''

# WhatIf mode: stop here.
if ($WhatIf) {
    Write-Host 'WhatIf set - NOT executing the PUT.' -ForegroundColor Yellow
    Write-Host 'Re-run without -WhatIf (and with -Force to skip the prompt) to apply.' -ForegroundColor Yellow
    return
}

# Operator confirmation prompt unless -Force.
if (-not $Force) {
    Write-Host 'About to PUT this block to the LIVE Sentinel data-connector resource.' -ForegroundColor Yellow
    Write-Host 'Confirm by typing UPDATE-CONNECTOR (case-sensitive):' -ForegroundColor Yellow -NoNewline
    Write-Host ' '
    $confirm = Read-Host
    if ($confirm -ne 'UPDATE-CONNECTOR') {
        Write-Host 'Operator did not confirm - aborting.' -ForegroundColor Red
        return
    }
}

# -----------------------------------------------------------------------------
# Step 4: execute the PUT via Invoke-AzRestMethod
# -----------------------------------------------------------------------------
Write-Host 'Executing PUT...' -ForegroundColor Cyan
try {
    $resp = Invoke-AzRestMethod -Path $url -Method PUT -Payload $body -ErrorAction Stop
    if ($resp.StatusCode -in 200, 201) {
        Write-Host ('OK - HTTP {0}' -f $resp.StatusCode) -ForegroundColor Green
        Write-Host 'Refresh the Sentinel UI Data Connectors blade; XdrLogRaider should now show the new connectivityCriteria query.' -ForegroundColor Green
    } else {
        Write-Host ('FAIL - HTTP {0}' -f $resp.StatusCode) -ForegroundColor Red
        Write-Host $resp.Content -ForegroundColor DarkRed
        exit 2
    }
} catch {
    Write-Host ('Exception: {0}' -f $_.Exception.Message) -ForegroundColor Red
    exit 2
}
