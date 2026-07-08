#Requires -Version 7.4
<#
.SYNOPSIS
GENERIC, MODULAR, DETERMINISTIC deploy-assembly factory · composes deploy/mainTemplate.json from
deploy/foundation.json + each SHIPPED category's per-category-schema artifact.

.DESCRIPTION
This is the assemble-from-parts replacement for the hand-inlined ARM pilot. It produces the Sentinel
one-click marketplace template (deploy/mainTemplate.json) so all Defender categories onboard identically:

    mainTemplate.json  =  foundation.json resources
                          + FOR EACH shipped category (deploy/per-category-schemas/<Portal>-<Category>.json):
                              (a) a cross-RG NESTED table deployment  (resourceGroup-only · NO subscriptionId)
                              (b) a TOP-LEVEL DCR                      (connector RG · streamDeclarations from artifact)
                              (c) the FA appSetting XDRLR_DCR_<PORTAL>_<CATEGORY> = reference(dcr).immutableId
                              (d) a per-DCR Monitoring Metrics Publisher role assignment (FA SAMI → that DCR)
                          + (the DCR dependsOn the nested via SIMPLE-NAME string form · the FA dependsOn the DCR)

foundation.json carries EVERYTHING ELSE (portal-agnostic): KeyVault(+secrets) · Storage(+tables/containers) ·
DataCollectionEndpoint · Function App · AppInsights · all foundation RBAC · and the Sentinel V3 content
(dataConnectorDefinition card + contentPackages) in the xdrlr-sentinel nested deployment. The Sentinel content
is carried THROUGH unchanged (contentId/contentProductId/connectivityCriteria preserved exactly).

ARM shapes reproduced EXACTLY from the proven committed pilot (≈30 prior ARM bug-fix iterations); this
Build-MainTemplate is the SOLE mainTemplate writer (gauntlet axes 14/20/21/23 + axis 36 regen->diff):
  · Nested cross-RG table deployment · apiVersion 2022-09-01 · resourceGroup=[variables('workspaceResourceGroup')]
    · expressionEvaluationOptions.scope=inner · NO subscriptionId (same-sub cross-RG · axis 20).
  · DCR · apiVersion 2023-03-11 · TOP-LEVEL (connector RG) · dependsOn [DCE-resourceId, <nested-simple-name>]
    (NOT resourceId() for the nested · ARM rejects that for cross-RG nested · iter#5 'InvalidOutputTable'; axis 21).
  · Table apiVersion 2023-09-01 · plan=Analytics. Columns set-equal table==DCR by construction (axis 14).
  · transformKql='source'. appSetting via reference(dcrName,'2023-03-11').immutableId.

DETERMINISM (hard requirement · run twice → byte-identical):
  · foundation + artifacts are read as PSCustomObject (ConvertFrom-Json · property order preserved from file).
  · Every constructed object is an [ordered] dictionary with explicit key order.
  · Column arrays are passed THROUGH from the artifact as-is (PSCustomObject name/type order preserved).
  · No plain (unordered) hashtables are serialized. Same inputs → identical ConvertTo-Json bytes.

IDEMPOTENT: a full rebuild from foundation + artifacts every run · the prior mainTemplate.json is overwritten.
Re-running with the same inputs reproduces byte-identical output (verified by -SelfCheckDeterminism).

.PARAMETER Categories
Explicit ordered list of '<Portal>/<Category>' (or '<Portal>-<Category>') to assemble, e.g. 'Defender/Operations'.
If omitted, ALL deploy/per-category-schemas/<Portal>-<Category>.json artifacts are discovered and assembled in a
STABLE sort order (portal, then category · case-insensitive). The pilot (Defender/Operations) is included like any
other category — there is no special-casing.

.PARAMETER FoundationPath
deploy/foundation.json (default).

.PARAMETER SchemaDir
deploy/per-category-schemas (default).

.PARAMETER OutputPath
deploy/mainTemplate.json (default).

.PARAMETER SelfCheckDeterminism
After writing, assemble a second time in-memory and assert the two serializations are byte-identical. Non-zero exit
on drift.

.PARAMETER WhatIf
Compute + report the resource plan WITHOUT writing OutputPath.

.PARAMETER SkipPackageCard
Do NOT (re)write the Content Hub solution card (Package/dataConnectors/...). Used by the regen->diff gauntlet axis,
which rebuilds mainTemplate.json to a TEMP path for comparison and must not side-effect the committed Package card.

.OUTPUTS
Exit 0 on success · non-zero on any failure (missing inputs · empty columns · determinism drift).
#>
[CmdletBinding()]
param(
    [string[]] $Categories,
    [string] $FoundationPath = (Join-Path (Resolve-Path "$PSScriptRoot\..").Path 'deploy\foundation.json'),
    [string] $SchemaDir      = (Join-Path (Resolve-Path "$PSScriptRoot\..").Path 'deploy\per-category-schemas'),
    [string] $OutputPath     = (Join-Path (Resolve-Path "$PSScriptRoot\..").Path 'deploy\mainTemplate.json'),
    [switch] $SelfCheckDeterminism,
    [switch] $SkipPackageCard,
    [switch] $WhatIf
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Blocker-fix · THE single canonical category tokenizer (Xdr.Common.Parser.Get-XdrCategoryToken) — the deploy assembler
# MUST tokenize category names the SAME way the catalogue/manifest/schema do (WorkspaceTable/DcrStreamName), so a spaced
# or '&' category ("Cloud Apps", "Exposure Management") yields matching, ARM-valid resource names. Was a latent BLOCKER:
# raw $Category kept the space -> '...-dcr-cloud apps-...' (ARM-invalid name / silent 0-rows) for 12 of 14 categories.
Import-Module (Join-Path $PSScriptRoot '..\src\Modules\Xdr.Common.Parser\Xdr.Common.Parser.psd1') -Force -DisableNameChecking -ErrorAction Stop

$JsonDepth = 60

# ─── helpers ─────────────────────────────────────────────────────────────────────────────────────
function Read-JsonObject {
    # ConvertFrom-Json (PSCustomObject) · preserves file property order → deterministic re-serialization.
    param([string] $Path)
    if (-not (Test-Path $Path)) { throw "[Build-MainTemplate] not found: $Path" }
    return (Get-Content $Path -Raw | ConvertFrom-Json -Depth $JsonDepth)
}

function Get-StreamInfo {
    # Returns @{ Stream=<name>; Columns=<array> } from an artifact DcrResource (single stream by construction).
    param($DcrResource)
    if (-not $DcrResource.properties.streamDeclarations) {
        throw '[Build-MainTemplate] artifact DcrResource missing properties.streamDeclarations'
    }
    $streamProp = @($DcrResource.properties.streamDeclarations.PSObject.Properties)[0]
    if (-not $streamProp) { throw '[Build-MainTemplate] artifact DcrResource streamDeclarations is empty' }
    # F1 (type-at-source · approach B · 2026-06-16) · carry the artifact's transformKql VERBATIM into the deploy
    # template (never hardcode it). GM-2 (2026-06-16): the carry is now ONE shared implementation — Parser's
    # Get-XdrArtifactTransformKql — that BOTH deploy writers (this SOLE marketplace writer + the surgical onboard)
    # call, so the structural invariant ('source' under B today, but never DROP/REWRITE a future non-identity
    # transform) can never drift between the two writers. Same single-source discipline as Get-XdrCategoryToken.
    $xform = Get-XdrArtifactTransformKql -DcrResource $DcrResource
    return @{ Stream = $streamProp.Name; Columns = @($streamProp.Value.columns); TransformKql = $xform }
}

function Resolve-CategoryArtifacts {
    # Determine the ordered (Portal,Category,Path) tuples to assemble.
    param([string[]] $Requested, [string] $Dir)
    if (-not (Test-Path $Dir)) { throw "[Build-MainTemplate] schema dir not found: $Dir" }

    if ($Requested -and $Requested.Count -gt 0) {
        $list = foreach ($spec in $Requested) {
            $norm = $spec -replace '/', '-'
            $parts = $norm -split '-', 2
            if ($parts.Count -ne 2) { throw "[Build-MainTemplate] bad -Categories entry '$spec' (want '<Portal>/<Category>')" }
            $p = Join-Path $Dir "$($parts[0])-$($parts[1]).json"
            if (-not (Test-Path $p)) { throw "[Build-MainTemplate] artifact not found for '$spec': $p · run dev-tools/Build-PerCategorySchema.ps1 first" }
            [pscustomobject]@{ Portal = $parts[0]; Category = $parts[1]; Path = $p }
        }
        return @($list)   # preserve caller-supplied order
    }

    # Discover · exclude the *-nested-deployment.json side artifacts. STABLE sort = deterministic output.
    $found = Get-ChildItem -Path $Dir -Filter '*.json' -File |
        Where-Object { $_.Name -notlike '*-nested-deployment.json' } |
        Sort-Object Name
    $list = foreach ($f in $found) {
        $stem = [IO.Path]::GetFileNameWithoutExtension($f.Name)
        $parts = $stem -split '-', 2
        if ($parts.Count -ne 2) { Write-Warning "[Build-MainTemplate] skipping unrecognized artifact name '$($f.Name)' (want '<Portal>-<Category>.json')"; continue }
        [pscustomobject]@{ Portal = $parts[0]; Category = $parts[1]; Path = $f.FullName }
    }
    $list = @($list) | Sort-Object Portal, Category
    if ($list.Count -eq 0) { throw "[Build-MainTemplate] no per-category-schema artifacts found in $Dir" }
    return @($list)
}

function New-CategoryResources {
    <#
      Build the FOUR per-category pieces for one category, in the canonical committed shapes.
      Returns @{ NestedNameExpr; DcrNameExpr; AppSettingName; Nested; Dcr; DcrRole }.
    #>
    param([string] $Portal, [string] $Category, $Artifact)

    $catToken = Get-XdrCategoryToken -Category $Category   # canonical token · single source w/ catalogue/manifest/schema (spaced/'&' names -> ARM-safe)
    $catLower = $catToken.ToLowerInvariant()

    $tableName = $Artifact.TableResource.properties.schema.name
    if (-not $tableName) { $tableName = "${Portal}_${Category}_CL" }   # fallback to canonical

    $tableCols = @($Artifact.TableResource.properties.schema.columns)
    $dcrInfo   = Get-StreamInfo -DcrResource $Artifact.DcrResource
    $dcrCols   = @($dcrInfo.Columns)
    $streamName = $dcrInfo.Stream
    $transformKql = $dcrInfo.TransformKql   # F1 (B) · the artifact's transformKql (uniform identity 'source' under B) · carried VERBATIM into the deploy DCR dataFlow, never hardcoded
    if ($tableCols.Count -eq 0) { throw "[Build-MainTemplate] $Portal/$Category · artifact TableResource columns empty" }
    if ($dcrCols.Count   -eq 0) { throw "[Build-MainTemplate] $Portal/$Category · artifact DcrResource stream columns empty" }

    # Outer-scope ARM name expressions (same idiom as the committed pilot · concat with namePrefix/suffix).
    # $dcrNameExpr is the BRACKETED form (used as a resource `name` value). $dcrNameInner is the BARE
    # expression (NO surrounding [ ]) for embedding INSIDE another ARM expression — ARM rejects a nested
    # `[...]` token inside an already-open `[...]` expression (empirical az validate: 'expected Identifier
    # actual LeftSquareBracket'). The pilot's working appSetting uses reference(resourceId(...)) with the
    # bare name expression · we reproduce that exactly.
    $nestedNameExpr = "[concat(variables('namePrefix'), '-table-$catLower-', variables('suffix'))]"
    $dcrNameExpr    = "[concat(variables('namePrefix'), '-dcr-$catLower-', variables('suffix'))]"
    $dcrNameInner   = "concat(variables('namePrefix'), '-dcr-$catLower-', variables('suffix'))"
    $appSettingName = "XDRLR_DCR_$($Portal.ToUpper())_$($catToken.ToUpper())"

    # ── (a) Nested cross-RG deployment · workspace table · resourceGroup-only (axis 20) ─────────────
    $nested = [ordered]@{
        comments      = "Assembled by Build-MainTemplate · per-category '$Portal/$Category' workspace table. Cross-RG nested deployment (resourceGroup-only · Microsoft canonical same-sub · NO subscriptionId · gauntlet axis 20). The custom table MUST exist before the DCR streamDeclarations bind (the DCR dependsOn this nested via SIMPLE-NAME string form · iter#5 InvalidOutputTable ordering fix)."
        type          = 'Microsoft.Resources/deployments'
        apiVersion    = '2022-09-01'
        name          = $nestedNameExpr
        resourceGroup = "[variables('workspaceResourceGroup')]"
        dependsOn     = @("[resourceId('Microsoft.Insights/dataCollectionEndpoints', variables('dceName'))]")
        properties    = [ordered]@{
            mode = 'Incremental'
            expressionEvaluationOptions = [ordered]@{ scope = 'inner' }
            parameters = [ordered]@{
                workspaceName = [ordered]@{ value = "[variables('workspaceName')]" }
                tableName     = [ordered]@{ value = $tableName }
            }
            template = [ordered]@{
                '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
                contentVersion = '1.0.0.0'
                parameters = [ordered]@{
                    workspaceName = [ordered]@{ type = 'string' }
                    tableName     = [ordered]@{ type = 'string' }
                }
                resources = @(
                    [ordered]@{
                        comments   = "Custom workspace table · $tableName · receives transformed rows via DCR · Analytics plan"
                        type       = 'Microsoft.OperationalInsights/workspaces/tables'
                        apiVersion = '2023-09-01'
                        name       = "[concat(parameters('workspaceName'), '/', parameters('tableName'))]"
                        properties = [ordered]@{
                            plan   = 'Analytics'
                            schema = [ordered]@{
                                name    = "[parameters('tableName')]"
                                columns = $tableCols
                            }
                        }
                    }
                )
                outputs = [ordered]@{}
            }
        }
    }

    # ── (b) Top-level DCR · connector RG · dependsOn DCE + nested(simple-name) (axis 21) ────────────
    $dcr = [ordered]@{
        comments   = "Assembled by Build-MainTemplate · per-category '$Portal/$Category' DCR. Same-RG as the Function App (operator architectural binding 2026-06-02 · DCR resource in connector RG · destination workspace cross-RG). dependsOn the nested table deployment via SIMPLE-NAME string form (NOT resourceId() · ARM rejects resourceId() for cross-RG nested · iter#5 'InvalidOutputTable' ordering fix · gauntlet axis 21). Columns set-equal to the table by construction (axis 14)."
        type       = 'Microsoft.Insights/dataCollectionRules'
        apiVersion = '2023-03-11'
        name       = $dcrNameExpr
        location   = "[parameters('location')]"
        tags       = "[variables('tags')]"
        dependsOn  = @(
            "[resourceId('Microsoft.Insights/dataCollectionEndpoints', variables('dceName'))]"
            $nestedNameExpr
        )
        properties = [ordered]@{
            dataCollectionEndpointId = "[resourceId('Microsoft.Insights/dataCollectionEndpoints', variables('dceName'))]"
            streamDeclarations = [ordered]@{
                $streamName = [ordered]@{ columns = $dcrCols }
            }
            destinations = [ordered]@{
                logAnalytics = @(
                    [ordered]@{
                        workspaceResourceId = "[parameters('workspaceResourceId')]"
                        name                = 'xdrlrWorkspace'
                    }
                )
            }
            dataFlows = @(
                [ordered]@{
                    streams      = @($streamName)
                    destinations = @('xdrlrWorkspace')
                    transformKql = $transformKql
                    outputStream = $streamName
                }
            )
        }
    }

    # ── (d) Per-DCR Monitoring Metrics Publisher grant · WS4.1 idempotent-by-principal ──────────────
    # The roleAssignment lives in a NESTED deployment so its NAME is seeded with the SAMI principalId (passed
    # as a parameter — ARM forbids reference() directly in a resource name). Same principal → same GUID →
    # re-running is an idempotent no-op; FA recreated (new principal) → NEW GUID → a fresh grant is CREATED —
    # the RoleAssignmentExists/RoleAssignmentUpdateNotPermitted whole-deployment-rollback class (live-proven
    # 2026-06-04) is structurally dead. Roles exist ONLY in the deployment (operator lock).
    $dcrRole = [ordered]@{
        comments   = "Assembled by Build-MainTemplate · WS4.1 · FA SAMI -> Monitoring Metrics Publisher on the '$Category' DCR via a principalId-seeded NESTED deployment (idempotent re-run · no RoleAssignmentExists rollback). Same-RG (FA + DCR both in connector RG); no Reader role needed (immutableId read via ARM-time reference())."
        type       = 'Microsoft.Resources/deployments'
        apiVersion = '2022-09-01'
        name       = "[concat('xdrlr-role-dcr-$catLower-', variables('suffix'))]"
        dependsOn  = @(
            "[resourceId('Microsoft.Web/sites', variables('functionAppName'))]"
            "[resourceId('Microsoft.Insights/dataCollectionRules', concat(variables('namePrefix'), '-dcr-$catLower-', variables('suffix')))]"
        )
        properties = [ordered]@{
            mode = 'Incremental'
            expressionEvaluationOptions = [ordered]@{ scope = 'inner' }
            parameters = [ordered]@{
                principalId      = [ordered]@{ value = "[reference(resourceId('Microsoft.Web/sites', variables('functionAppName')), '2024-11-01', 'full').identity.principalId]" }
                dcrName          = [ordered]@{ value = "[concat(variables('namePrefix'), '-dcr-$catLower-', variables('suffix'))]" }
                roleDefinitionId = [ordered]@{ value = "[variables('monitoringMetricsPublisherRoleId')]" }
            }
            template = [ordered]@{
                '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
                contentVersion = '1.0.0.0'
                parameters     = [ordered]@{
                    principalId      = [ordered]@{ type = 'string' }
                    dcrName          = [ordered]@{ type = 'string' }
                    roleDefinitionId = [ordered]@{ type = 'string' }
                }
                resources = @(
                    [ordered]@{
                        type       = 'Microsoft.Authorization/roleAssignments'
                        apiVersion = '2022-04-01'
                        name       = "[guid(resourceId('Microsoft.Insights/dataCollectionRules', parameters('dcrName')), parameters('principalId'), 'MMP-DCR-$catLower')]"
                        scope      = "[concat('Microsoft.Insights/dataCollectionRules/', parameters('dcrName'))]"
                        properties = [ordered]@{
                            roleDefinitionId = "[parameters('roleDefinitionId')]"
                            principalId      = "[parameters('principalId')]"
                            principalType    = 'ServicePrincipal'
                        }
                    }
                )
            }
        }
    }

    return @{
        NestedNameExpr = $nestedNameExpr
        DcrNameExpr    = $dcrNameExpr
        DcrNameInner   = $dcrNameInner
        AppSettingName = $appSettingName
        TableName      = $tableName
        StreamName     = $streamName
        TableColCount  = $tableCols.Count
        DcrColCount    = $dcrCols.Count
        Nested         = $nested
        Dcr            = $dcr
        DcrRole        = $dcrRole
    }
}

function New-XdrConnectorCardContent {
    <#
      FH-5 (2026-06-15) · Generate the SINGLE Sentinel V3 connector card's content arrays from the assembled
      per-category plan rows. There is exactly ONE dataConnectorDefinition (one card in the Data Connectors gallery)
      representing the whole XdrLogRaider connector; each shipped category contributes ONE dataTypes row (its table +
      last-received), ONE graphQueries series, generic sample queries, and ONE term in the SINGLE union'd connectivity
      badge. Pre-FH-5 these arrays were hardcoded to the pilot table -> a 2nd category was INVISIBLE in the gallery
      (no Connected badge, not in the data-types list). Sample queries use ONLY the universal envelope columns
      (TimeGenerated / Operation / Subcategory / CorrelationId — present in EVERY category table by construction) so
      they never assume category-specific columns (genericity · scales to any future category with zero edits).
    #>
    param([Parameter(Mandatory)][object[]] $PlanRows)

    $tables = @($PlanRows | ForEach-Object { $_.Table } | Select-Object -Unique)

    $dataTypes = @(foreach ($row in $PlanRows) {
        [ordered]@{
            name                  = $row.Table
            lastDataReceivedQuery = "$($row.Table)`n| summarize Time = max(TimeGenerated)`n| where isnotempty(Time)"
        }
    })

    $graphQueries = @(foreach ($row in $PlanRows) {
        $disp = ($row.Category -split '/')[-1]
        [ordered]@{
            metricName = "$disp events"
            legend     = $row.Table
            baseQuery  = $row.Table
        }
    })

    $sampleQueries = @(foreach ($row in $PlanRows) {
        $disp = ($row.Category -split '/')[-1]
        [ordered]@{
            description = "$disp · recent events (last 24h)"
            query       = "$($row.Table)`n| where TimeGenerated > ago(24h)`n| project TimeGenerated, Operation, Subcategory, CorrelationId`n| take 100"
        }
        [ordered]@{
            description = "$disp · volume by operation (last 7d)"
            query       = "$($row.Table)`n| where TimeGenerated > ago(7d)`n| summarize Count = count() by Operation`n| order by Count desc"
        }
    })

    # ONE connectivity badge = ANY shipped table has data in the last 3d. isfuzzy=true so a category whose table is
    # not yet materialised (first ingest still pending) never errors the criteria query (it just doesn't contribute).
    $unionExpr = $tables -join ', '
    $connectivityCriteria = @(
        [ordered]@{
            type  = 'IsConnectedQuery'
            value = @("union isfuzzy=true $unionExpr`n| summarize LastLogReceived = max(TimeGenerated)`n| project IsConnected = LastLogReceived > ago(3d)")
        }
    )

    return [ordered]@{
        dataTypes            = $dataTypes
        graphQueries         = $graphQueries
        sampleQueries        = $sampleQueries
        connectivityCriteria = $connectivityCriteria
    }
}

function New-XdrCardOnlyTemplate {
    <#
      WS-card-sync · Task E/C · build a STANDALONE, TARGETED ARM template carrying ONLY the Sentinel V3
      dataConnectorDefinition (the connector card) — NO foundation, NO roles, NO Function App, NO tables/DCRs.
      Deployable ALONE to the WORKSPACE resource group to sync the live card to the current shipped-category set
      (the live card froze at the initial 6-category deploy while the repo advanced to 10). Because it touches ONLY
      the card resource, it can never reset the FA zip or bounce/replace any foundation resource.

      Single-source: the card resource is EXTRACTED from the already-assembled mainTemplate (same card, same generated
      dataTypes/graphQueries/sampleQueries/connectivityCriteria via New-XdrConnectorCardContent) so the targeted
      template can never drift from the embedded one. The mainTemplate card references parameters('workspaceName'),
      parameters('connectorDefinitionName'), parameters('location') and parameters('tableName') — supplied here by the
      inner nested deployment. In the standalone form we resolve workspaceName + the primary tableName from the
      top-level workspaceResourceId, and keep connectorDefinitionName/location as top-level parameters. The card
      resource's parameters('workspaceName')/parameters('tableName') refs are rewritten to variables() so the single
      extracted resource is self-consistent at top level.

      Returns an [ordered] template object (deterministic by construction · same inputs → identical serialization).
    #>
    param(
        [Parameter(Mandatory)] $AssembledTemplate,
        [Parameter(Mandatory)][string] $PrimaryTableName
    )

    $nestedName = "[variables('nestedDeploymentName')]"
    $sentinelNested = $AssembledTemplate.resources | Where-Object { $_.PSObject.Properties['name'] -and $_.name -eq $nestedName } | Select-Object -First 1
    if (-not $sentinelNested) { throw '[Build-MainTemplate] cannot locate the Sentinel nested deployment to extract the connector card' }
    $cardSrc = $sentinelNested.properties.template.resources |
        Where-Object { $_.type -eq 'Microsoft.OperationalInsights/workspaces/providers/dataConnectorDefinitions' } |
        Select-Object -First 1
    if (-not $cardSrc) { throw '[Build-MainTemplate] cannot locate the dataConnectorDefinition card in the Sentinel nested deployment' }

    # Deep-clone the card resource (JSON round-trip) so the rewrite below never mutates the assembled mainTemplate.
    $card = $cardSrc | ConvertTo-Json -Depth $JsonDepth | ConvertFrom-Json -Depth $JsonDepth

    # Re-emit the card resource as an [ordered] dictionary, rewriting the two inner-nested param refs
    # (workspaceName · tableName) to top-level variables so the standalone single resource is self-consistent.
    # connectorDefinitionName + location stay parameter-driven at top level. Field order mirrors the source card.
    $cardOut = [ordered]@{
        comments   = 'WS-card-sync targeted card-only deploy · the SINGLE Sentinel V3 dataConnectorDefinition for the whole XdrLogRaider connector (one card, N category tables), EXTRACTED verbatim from deploy/mainTemplate.json by Build-MainTemplate (single-source · same generated dataTypes/graphQueries/sampleQueries/connectivityCriteria). Deploy this ALONE to the WORKSPACE resource group to sync the live connector card to the current shipped-category set without touching any foundation resource (no FA zip reset · no roles).'
        type       = 'Microsoft.OperationalInsights/workspaces/providers/dataConnectorDefinitions'
        apiVersion = [string]$card.apiVersion
        name       = "[concat(variables('workspaceName'), '/Microsoft.SecurityInsights/', parameters('connectorDefinitionName'))]"
        location   = "[parameters('location')]"
        kind       = [string]$card.kind
        properties = $card.properties
    }
    # Rewrite the graphQueriesTableName param ref to the derived primary-table variable (top level has no tableName param).
    if ($cardOut.properties.connectorUiConfig.PSObject.Properties['graphQueriesTableName']) {
        $cardOut.properties.connectorUiConfig.graphQueriesTableName = "[variables('primaryTableName')]"
    }

    return [ordered]@{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
        contentVersion = '1.0.0.0'
        metadata       = [ordered]@{
            _generator = [ordered]@{ name = 'XdrLogRaider'; version = '0.1.0'; tool = 'Build-MainTemplate (card-only)' }
            description = 'TARGETED card-only ARM template · ONLY the Sentinel V3 dataConnectorDefinition · deploy ALONE to the WORKSPACE resource group to sync the live connector card 6->N (no foundation/roles/FA touched). Single-sourced from deploy/mainTemplate.json by Build-MainTemplate.'
        }
        parameters     = [ordered]@{
            workspaceResourceId     = [ordered]@{
                type     = 'string'
                metadata = [ordered]@{ description = 'Resource ID of the existing Sentinel-enabled Log Analytics workspace whose connector card to sync. Must be in the resource group this deployment targets (the card is workspace-scoped).' }
            }
            connectorDefinitionName = [ordered]@{
                type         = 'string'
                defaultValue = 'XdrLogRaiderDefenderXdr'
                metadata     = [ordered]@{ description = 'Connector definition name · must match the value the foundation deploy used (variables.connectorDefinitionName) so this updates the SAME card.' }
            }
            location                = [ordered]@{
                type         = 'string'
                defaultValue = '[resourceGroup().location]'
                metadata     = [ordered]@{ description = 'Azure region for the card resource (default: the target resource group location).' }
            }
        }
        variables      = [ordered]@{
            workspaceName    = "[last(split(parameters('workspaceResourceId'), '/'))]"
            primaryTableName = $PrimaryTableName
        }
        resources      = @($cardOut)
        outputs        = [ordered]@{}
    }
}

function Build-AssembledTemplate {
    <#
      Pure function · returns the assembled template PSCustomObject (no IO). Deterministic by construction.
    #>
    param($Foundation, [array] $CategoryTuples, [ref] $Plan)

    # Deep-clone the foundation so repeated calls don't mutate the shared input (round-trip through JSON).
    $tpl = $Foundation | ConvertTo-Json -Depth $JsonDepth | ConvertFrom-Json -Depth $JsonDepth

    # Locate the Function App (Microsoft.Web/sites) to merge per-category appSettings + DCR dependsOn into.
    $fa = $tpl.resources | Where-Object { $_.type -eq 'Microsoft.Web/sites' } | Select-Object -First 1
    if (-not $fa) { throw '[Build-MainTemplate] foundation has no Microsoft.Web/sites · cannot wire DCR appSettings' }

    # Mutable working copies of the FA appSettings + dependsOn (arrays of PSCustomObject / string).
    $appSettings = [System.Collections.Generic.List[object]]::new()
    foreach ($s in @($fa.properties.siteConfig.appSettings)) { $appSettings.Add($s) }
    $faDeps = [System.Collections.Generic.List[object]]::new()
    foreach ($d in @($fa.dependsOn)) { $faDeps.Add($d) }

    # Foundation resources first (in their committed order), then per-category resources appended.
    $resources = [System.Collections.Generic.List[object]]::new()
    foreach ($r in @($tpl.resources)) { $resources.Add($r) }

    $planRows = [System.Collections.Generic.List[object]]::new()

    foreach ($tuple in $CategoryTuples) {
        $artifact = Read-JsonObject -Path $tuple.Path
        $built = New-CategoryResources -Portal $tuple.Portal -Category $tuple.Category -Artifact $artifact

        # (a) nested table deployment · (b) DCR · (d) DCR role — appended at top level.
        $resources.Add($built.Nested)
        $resources.Add($built.Dcr)
        $resources.Add($built.DcrRole)

        # (c) FA appSetting · XDRLR_DCR_<PORTAL>_<CATEGORY> → reference(dcr).immutableId.
        #     Idempotent within a single build (drop any same-named first · should not occur on clean foundation).
        $appName = $built.AppSettingName
        $kept = [System.Collections.Generic.List[object]]::new()
        foreach ($s in $appSettings) { if ($s.name -ne $appName) { $kept.Add($s) } }
        $appSettings = $kept
        # reference(resourceId('...dataCollectionRules', <bare-concat-name-expr>), '2023-03-11').immutableId
        # — matches the proven pilot form. Embedding the BRACKETED $dcrNameExpr here would emit
        #   [reference([concat(...)], ...)] which ARM rejects (nested '[' inside an open expression).
        $appSettings.Add([ordered]@{
            name  = $appName
            value = "[reference(resourceId('Microsoft.Insights/dataCollectionRules', $($built.DcrNameInner)), '2023-03-11').immutableId]"
        })

        # FA must provision AFTER the DCR (the appSetting reference() resolves the immutableId at deploy time).
        $dcrDepExpr = "[resourceId('Microsoft.Insights/dataCollectionRules', concat(variables('namePrefix'), '-dcr-$((Get-XdrCategoryToken -Category $tuple.Category).ToLowerInvariant())-', variables('suffix')))]"
        if (-not ($faDeps -contains $dcrDepExpr)) { $faDeps.Add($dcrDepExpr) }

        $planRows.Add([pscustomobject]@{
            Category     = "$($tuple.Portal)/$($tuple.Category)"
            Table        = $built.TableName
            Stream       = $built.StreamName
            TableCols    = $built.TableColCount
            DcrCols      = $built.DcrColCount
            AppSetting   = $appName
            NestedName   = $built.NestedNameExpr
            DcrName      = $built.DcrNameExpr
        })
    }

    # Write the merged appSettings + dependsOn back onto the FA.
    $fa.properties.siteConfig.appSettings = @($appSettings)
    $fa.dependsOn = @($faDeps)

    # WS4.2 · PRIMARY-CATEGORY rebind. foundation.json carries two values that must track the FIRST assembled
    # category (the pilot): the `dcrName` variable (the template outputs reference it) and the Sentinel V3
    # connector card's table (connectivityCriteria/graphQueries · the xdrlr-sentinel nested deployment's
    # `tableName` parameter value). Rebinding them HERE makes a pilot switch a PURE REGEN — zero foundation
    # edits, zero hand-edits (e.g. a future portal whose first nodoc GROUP is 'Configuration' would re-point the
    # card to Defender_Configuration_CL automatically — categories are ALWAYS the nodoc x-tagGroups, never invented).
    if (@($CategoryTuples).Count -gt 0) {
        $primCatLower   = (Get-XdrCategoryToken -Category $CategoryTuples[0].Category).ToLowerInvariant()
        $primTableName  = $planRows[0].Table
        $tpl.variables.dcrName = "[concat(variables('namePrefix'), '-dcr-$primCatLower-', variables('suffix'))]"
        $sentinelNested = $tpl.resources | Where-Object { $_.PSObject.Properties['name'] -and $_.name -eq "[variables('nestedDeploymentName')]" } | Select-Object -First 1
        if ($sentinelNested) {
            # The card's `tableName` PARAMETER still tracks the PRIMARY table (graphQueriesTableName default + legend
            # header). FH-5: the card CONTENT is now GENERATED to enumerate EVERY shipped category — ONE card, N tables
            # (dataTypes / graphQueries / sampleQueries + a SINGLE union'd connectivity badge). Pre-FH-5 these arrays
            # were hardcoded to the pilot table -> a 2nd category was invisible in the Sentinel Data Connectors gallery.
            $sentinelNested.properties.parameters.tableName.value = $primTableName
            $cardDef = $sentinelNested.properties.template.resources |
                Where-Object { $_.type -eq 'Microsoft.OperationalInsights/workspaces/providers/dataConnectorDefinitions' } |
                Select-Object -First 1
            if ($cardDef) {
                $cardContent = New-XdrConnectorCardContent -PlanRows $planRows
                $ui = $cardDef.properties.connectorUiConfig
                $ui.dataTypes            = $cardContent.dataTypes
                $ui.graphQueries         = $cardContent.graphQueries
                $ui.sampleQueries        = $cardContent.sampleQueries
                $ui.connectivityCriteria = $cardContent.connectivityCriteria
            }
        }
    }

    $tpl.resources = @($resources)
    if ($Plan) { $Plan.Value = $planRows }
    return $tpl
}

# ─── main ────────────────────────────────────────────────────────────────────────────────────────
$foundation = Read-JsonObject -Path $FoundationPath
$tuples = Resolve-CategoryArtifacts -Requested $Categories -Dir $SchemaDir

Write-Host "[Build-MainTemplate] foundation : $FoundationPath ($($foundation.resources.Count) resources)"
Write-Host "[Build-MainTemplate] categories : $($tuples.Count) · $((@($tuples | ForEach-Object { "$($_.Portal)/$($_.Category)" })) -join ', ')"

$plan = $null
$assembled = Build-AssembledTemplate -Foundation $foundation -CategoryTuples $tuples -Plan ([ref]$plan)
$json = $assembled | ConvertTo-Json -Depth $JsonDepth

Write-Host ''
Write-Host '─── per-category plan ─────────────────────────────────────────────────'
$plan | Format-Table -AutoSize | Out-String | Write-Host
Write-Host "[Build-MainTemplate] assembled resource count: $($assembled.resources.Count)"

if ($WhatIf) {
    Write-Host '[Build-MainTemplate] -WhatIf · OutputPath NOT written.'
    exit 0
}

# Write deterministically · UTF-8 (BOM-less by default in pwsh 7 Set-Content -Encoding UTF8 emits a BOM;
# use [IO.File]::WriteAllText with UTF8 (no BOM) to match the existing repo convention + keep diffs clean).
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($OutputPath, $json, $utf8NoBom)
Write-Host "[Build-MainTemplate] WROTE $OutputPath ($([Math]::Round((Get-Item $OutputPath).Length/1KB,1)) KB)"

# Validate the written file parses.
try { $null = Get-Content $OutputPath -Raw | ConvertFrom-Json -Depth $JsonDepth }
catch { Write-Error "[Build-MainTemplate] written mainTemplate.json does NOT parse: $($_.Exception.Message)"; exit 1 }

# ─── FH-5b · single-source the Content Hub solution's standalone connector card ─────────────────────
# Build-MainTemplate is the SOLE writer of BOTH cards: the ARM-embedded card (in mainTemplate.json above) AND the
# Package/dataConnectors card shipped in the Sentinel Content Hub solution zip. BOTH derive from the SAME
# New-XdrConnectorCardContent over the SAME plan -> guaranteed parity (no hand-maintained mirror that drifts -> a 2nd
# category invisible in the PUBLISHED solution). Only the 4 generated arrays + graphQueriesTableName are rewritten;
# title / description / publisher / permissions / instructionSteps are preserved as hand-authored. -SkipPackageCard is
# set by the regen->diff axis (it rebuilds mainTemplate to a TEMP path and must not touch the committed Package card).
if (-not $SkipPackageCard) {
    $repoRoot    = (Resolve-Path "$PSScriptRoot\..").Path
    $pkgCardPath = Join-Path $repoRoot 'Package\dataConnectors\XdrLogRaiderDataConnectorDefinition.json'
    if ((Test-Path $pkgCardPath) -and @($plan).Count -gt 0) {
        $pkgCard    = Get-Content $pkgCardPath -Raw | ConvertFrom-Json -Depth $JsonDepth
        $pkgContent = New-XdrConnectorCardContent -PlanRows $plan
        $pui = $pkgCard.properties.connectorUiConfig
        $pui.graphQueriesTableName = $plan[0].Table            # primary table · concrete (Content Hub card has no ARM params)
        $pui.dataTypes             = $pkgContent.dataTypes
        $pui.graphQueries          = $pkgContent.graphQueries
        $pui.sampleQueries         = $pkgContent.sampleQueries
        $pui.connectivityCriteria  = $pkgContent.connectivityCriteria
        $pkgJson = $pkgCard | ConvertTo-Json -Depth $JsonDepth
        [IO.File]::WriteAllText($pkgCardPath, $pkgJson, $utf8NoBom)
        Write-Host "[Build-MainTemplate] WROTE $pkgCardPath (Content Hub card · single-sourced · $(@($plan).Count) categories)"
        try { $null = Get-Content $pkgCardPath -Raw | ConvertFrom-Json -Depth $JsonDepth }
        catch { Write-Error "[Build-MainTemplate] written Package card does NOT parse: $($_.Exception.Message)"; exit 1 }
    }

    # ─── WS-card-sync · the TARGETED card-only deploy artifact (Task E/C · single-sourced from the assembled card) ──
    # deploy/connector-card-only.json carries ONLY the Sentinel V3 dataConnectorDefinition (extracted from the
    # mainTemplate card above) so the live card can be synced ALONE to the workspace RG (6->N) without touching any
    # foundation resource (no FA zip reset · no roles). Emitted from the SAME assembly so it can never drift from the
    # embedded card; -SkipPackageCard skips it for the regen->diff TEMP rebuild (same pattern as the Package card).
    if (@($plan).Count -gt 0) {
        $cardOnlyPath = Join-Path $repoRoot 'deploy\connector-card-only.json'
        $cardOnlyTpl  = New-XdrCardOnlyTemplate -AssembledTemplate $assembled -PrimaryTableName ([string]$plan[0].Table)
        $cardOnlyJson = $cardOnlyTpl | ConvertTo-Json -Depth $JsonDepth
        [IO.File]::WriteAllText($cardOnlyPath, $cardOnlyJson, $utf8NoBom)
        Write-Host "[Build-MainTemplate] WROTE $cardOnlyPath (targeted card-only deploy · single-sourced · $(@($plan).Count) categories)"
        try { $null = Get-Content $cardOnlyPath -Raw | ConvertFrom-Json -Depth $JsonDepth }
        catch { Write-Error "[Build-MainTemplate] written connector-card-only.json does NOT parse: $($_.Exception.Message)"; exit 1 }
    }
}

if ($SelfCheckDeterminism) {
    # Re-assemble from scratch + compare serializations byte-for-byte.
    $plan2 = $null
    $assembled2 = Build-AssembledTemplate -Foundation $foundation -CategoryTuples $tuples -Plan ([ref]$plan2)
    $json2 = $assembled2 | ConvertTo-Json -Depth $JsonDepth
    if ($json -ceq $json2) {
        Write-Host '[Build-MainTemplate] DETERMINISM self-check PASS · two assemblies byte-identical.'
    } else {
        Write-Error "[Build-MainTemplate] DETERMINISM self-check FAIL · serializations differ (len A=$($json.Length) B=$($json2.Length))."
        exit 1
    }
}

exit 0
