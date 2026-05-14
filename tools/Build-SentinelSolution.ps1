<#
.SYNOPSIS
    Generates deploy/sentinelContent.json — minimal Phase 1 Sentinel solution
    wrapper (contentPackage + dataConnector + metadata; NO analytic rules,
    workbooks, hunting queries, or parsers).

.DESCRIPTION
    Phase 1 ship-lock: data-connector card ONLY. The 19 data types (18
    `Defender_<Sub>_CL` + `XdrConnectorHealth_CL`) are advertised so Sentinel's
    Content Hub can show the card. Content (analytic rules / workbooks / hunting
    queries / parsers) lands in v0.3.0+ via builder extension.

    The data-connector card uses `connectivityCriteria` (singular per Sentinel
    V2 Microsoft.SecurityInsights/dataConnectors schema) with freshness-signal
    KQL: `XdrConnectorHealth_CL | where TimeGenerated > ago(15m) | take 1`.
    Existence of a row in 15m = Heartbeat fired = connector alive (= Connected).
    Per Decision 12: CardState is intentionally a Notes JSON field for operator
    diagnostics — the card MUST NOT depend on it (would couple card signal to
    heartbeat self-classification, defeating the freshness signal's purpose).

.PARAMETER OutputPath
    Output sentinelContent.json. Default: ../deploy/sentinelContent.json.

.EXAMPLE
    pwsh ./tools/Build-SentinelSolution.ps1
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [string] $OutputPath = (Join-Path $PSScriptRoot '..' 'deploy' 'sentinelContent.json')
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

# -----------------------------------------------------------------------------
# Build dataTypes list (19 tables)
# -----------------------------------------------------------------------------
$dataTypes = New-Object System.Collections.Generic.List[object]
foreach ($sub in $SubAreas) {
    $pascal = ConvertTo-PascalCase -Snake $sub
    $tbl = "Defender_${pascal}_CL"
    $dataTypes.Add([ordered]@{
        name      = $tbl
        lastDataReceivedQuery = "$tbl | where TimeGenerated > ago(24h) | summarize Time = max(TimeGenerated) by Type"
    })
}
$dataTypes.Add([ordered]@{
    name      = 'XdrConnectorHealth_CL'
    lastDataReceivedQuery = 'XdrConnectorHealth_CL | where TimeGenerated > ago(1h) | summarize Time = max(TimeGenerated) by Type'
})

# -----------------------------------------------------------------------------
# Build the GenericUI dataConnector resource
# -----------------------------------------------------------------------------
$connectorId = 'XdrLogRaiderInternal'

$dataConnector = [ordered]@{
    type       = 'Microsoft.OperationalInsights/workspaces/providers/dataConnectors'
    apiVersion = '2023-02-01-preview'
    name       = "[concat(parameters('workspaceName'), '/Microsoft.SecurityInsights/', '$connectorId')]"
    kind       = 'GenericUI'
    properties = [ordered]@{
        connectorUiConfig = [ordered]@{
            title       = 'XdrLogRaider'
            publisher   = 'Community'
            descriptionMarkdown = 'XdrLogRaider ingests Microsoft Defender XDR portal-only telemetry across 18 sub-areas via 492 read-only endpoints (Action Center · Attack Simulator · Cloud Apps · Configuration · Data Lake · Endpoint Configuration · Endpoint Devices · Entity Pivots · Exposure Management · Files · Identity · Multi-Tenant · Portal Services · Secure Score · Sentinel Precision · Streaming · Threat Analytics · Vulnerability Management). Authenticates via service-account sccauth+XSRF session cookies; auto-refreshes session every 50 min. Per-sub-area timer triggers with staggered cron, circuit-breaker resilience, and dynamic regionality via TenantContext. ConnectorHeartbeat emits liveness independent of poll state.'
            graphQueries = @(
                [ordered]@{
                    metricName = 'Total rows received'
                    legend     = 'XdrLogRaider rows'
                    baseQuery  = 'union withsource=Table Defender_*_CL, XdrConnectorHealth_CL'
                }
            )
            sampleQueries = @(
                [ordered]@{ description = 'ConnectorHeartbeat — last 24h'; query = 'XdrConnectorHealth_CL | where TimeGenerated > ago(24h) | order by TimeGenerated desc | take 50' }
                [ordered]@{ description = 'Per-sub-area row volume — last 24h'; query = 'union withsource=Table Defender_*_CL | where TimeGenerated > ago(24h) | summarize Rows=count() by Table' }
                [ordered]@{ description = 'License-blocked endpoints (LicenseHint populated)'; query = 'union withsource=Table Defender_*_CL | where TimeGenerated > ago(24h) and isnotempty(LicenseHint) | summarize Endpoints=dcount(Endpoint) by Table, LicenseHint' }
                [ordered]@{ description = 'Rate-limited cycles (HTTP 429) — last 24h'; query = 'union withsource=Table Defender_*_CL | where TimeGenerated > ago(24h) and SuccessKind == "rate-limited" | summarize Count=count() by Table, Endpoint' }
                [ordered]@{ description = 'Per-stream error rate — last 24h'; query = 'union withsource=Table Defender_*_CL | where TimeGenerated > ago(24h) | summarize Total=count(), Errors=countif(SuccessKind == "error") by Table, Endpoint | extend ErrorPct = round(100.0 * Errors / Total, 2) | order by ErrorPct desc' }
                [ordered]@{ description = 'Open circuit-breakers (aggregate count from latest heartbeat)'; query = 'XdrConnectorHealth_CL | where TimeGenerated > ago(15m) | top 1 by TimeGenerated desc | extend OpenCircuits = toint(parse_json(Notes).openCircuits) | project TimeGenerated, OpenCircuits, DlqDepth = toint(parse_json(Notes).dlqDepth), FatalError = tostring(parse_json(Notes).fatalError)' }
            )
            dataTypes = $dataTypes.ToArray()
            connectivityCriteria = @(
                [ordered]@{
                    type  = 'IsConnectedQuery'
                    value = @('XdrConnectorHealth_CL | where TimeGenerated > ago(15m) | take 1')
                }
            )
            availability = [ordered]@{
                status      = 1
                isPreview   = $false
            }
            permissions = [ordered]@{
                resourceProvider = @(
                    [ordered]@{
                        provider     = 'Microsoft.OperationalInsights/workspaces'
                        permissionsDisplayText = 'read and write permissions on the workspace are required.'
                        providerDisplayName = 'Workspace'
                        scope         = 'Workspace'
                        requiredPermissions = [ordered]@{ write = $true; read = $true; delete = $true }
                    }
                )
                customs = @(
                    [ordered]@{
                        name = 'Defender XDR service account'
                        description = 'A read-only service account with Sentinel Reader + Defender XDR read role. Unattended auth via Password+TOTP or FIDO2 passkey; provisioned by ARM into Key Vault.'
                    }
                )
            }
            instructionSteps = @(
                [ordered]@{
                    title = '1. Deploy the connector'
                    description = 'Use the Deploy to Azure button (or the included ARM template at deploy/mainTemplate.json) to provision the Function App + DCE + 19 DCRs + 19 workspace tables.'
                }
                [ordered]@{
                    title = '2. Upload service-account credentials to Key Vault'
                    description = 'If you skipped the inline credentials at deploy time, upload them to the Key Vault now: `defender-upn`, `defender-password`, `defender-totp` (or `defender-passkey`), `defender-auth-method`.'
                }
                [ordered]@{
                    title = '3. Verify deployment locally'
                    description = 'Run `pwsh ./tools/Verify-Deploy.ps1 -ResourceGroup <rg>` for a 14-phase post-deploy check (resources present · KV + SAMI · heartbeat liveness · DCR ingestion · circuit-breaker states).'
                }
            )
        }
    }
}

# -----------------------------------------------------------------------------
# Build the contentPackage
# -----------------------------------------------------------------------------
$contentPackage = [ordered]@{
    type       = 'Microsoft.OperationalInsights/workspaces/providers/contentPackages'
    apiVersion = '2023-04-01-preview'
    name       = "[concat(parameters('workspaceName'), '/Microsoft.SecurityInsights/community.xdrlograider')]"
    properties = [ordered]@{
        contentId    = 'community.xdrlograider'
        contentKind  = 'Solution'
        contentSchemaVersion = '3.0.0'
        displayName  = 'XdrLogRaider'
        version      = '0.1.0'
        author       = [ordered]@{ name = 'Alex Kefallonitis' }
        source       = [ordered]@{ kind = 'Community'; name = 'XdrLogRaider' }
        support      = [ordered]@{ tier = 'Community' }
        descriptionHtml = '<p><strong>XdrLogRaider v0.1.0</strong> — Microsoft Defender XDR portal-only telemetry connector for Microsoft Sentinel.</p>'
        dependencies = [ordered]@{ operator = 'AND'; criteria = @() }
        contentProductId = 'community.xdrlograider'
        packageId        = 'community.xdrlograider'
        packageKind      = 'Solution'
        packageName      = 'XdrLogRaider'
        packageVersion   = '0.1.0'
    }
}

# -----------------------------------------------------------------------------
# Build solution metadata (one resource describing the solution itself)
# -----------------------------------------------------------------------------
$solutionMetadata = [ordered]@{
    type       = 'Microsoft.OperationalInsights/workspaces/providers/metadata'
    apiVersion = '2023-04-01-preview'
    name       = "[concat(parameters('workspaceName'), '/Microsoft.SecurityInsights/community.xdrlograider')]"
    properties = [ordered]@{
        kind        = 'Solution'
        contentId   = 'community.xdrlograider'
        version     = '0.1.0'
        parentId    = "[concat(parameters('workspaceName'), '/Microsoft.SecurityInsights/community.xdrlograider')]"
        source      = [ordered]@{ kind = 'Community'; name = 'XdrLogRaider' }
        author      = [ordered]@{ name = 'Alex Kefallonitis' }
        support     = [ordered]@{ tier = 'Community' }
    }
}

$dataConnectorMetadata = [ordered]@{
    type       = 'Microsoft.OperationalInsights/workspaces/providers/metadata'
    apiVersion = '2023-04-01-preview'
    name       = "[concat(parameters('workspaceName'), '/Microsoft.SecurityInsights/DataConnector-XdrLogRaider')]"
    properties = [ordered]@{
        kind        = 'DataConnector'
        contentId   = 'XdrLogRaiderInternal'
        version     = '0.1.0'
        parentId    = "[concat(parameters('workspaceName'), '/Microsoft.SecurityInsights/community.xdrlograider')]"
        source      = [ordered]@{ kind = 'Community'; name = 'XdrLogRaider' }
        author      = [ordered]@{ name = 'Alex Kefallonitis' }
        support     = [ordered]@{ tier = 'Community' }
    }
}

# -----------------------------------------------------------------------------
# Assemble Sentinel content nested template
# -----------------------------------------------------------------------------
$template = [ordered]@{
    '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
    contentVersion = '1.0.0.0'
    metadata       = [ordered]@{
        _generator = [ordered]@{ name = 'Build-SentinelSolution.ps1 — Phase 1 minimal wrapper (data-connector card only)' }
        comments   = 'Phase 1 ship-lock: NO analytic rules, NO workbooks, NO hunting queries, NO parsers. Content lands in v0.3.0.'
    }
    parameters     = [ordered]@{
        workspaceName = [ordered]@{ type = 'string' }
    }
    resources = @(
        $contentPackage,
        $solutionMetadata,
        $dataConnector,
        $dataConnectorMetadata
    )
}

$json = ($template | ConvertTo-Json -Depth 30) -replace "`r`n", "`n" -replace "`r", "`n"

$outDir = Split-Path $OutputPath -Parent
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
[System.IO.File]::WriteAllText($OutputPath, $json, [System.Text.UTF8Encoding]::new($false))

# Phase 1 size budget: ≤30 KB
$sizeKb = [math]::Round((Get-Item $OutputPath).Length / 1KB, 1)
Write-Host "Wrote $OutputPath ($sizeKb KB · $($template.resources.Count) resources)"
Write-Host "  1 contentPackage · 2 metadata · 1 dataConnector card · 19 dataTypes · 6 sampleQueries"
if ($sizeKb -gt 30) {
    Write-Warning "Solution package $sizeKb KB exceeds Phase 1 30 KB target. Trim sampleQueries or instructionSteps."
}
