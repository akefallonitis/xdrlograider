#Requires -Version 7.0
<#
.SYNOPSIS
    Reads all Sentinel content source files (KQL parsers, workbooks, analytic rule YAMLs,
    hunting query YAMLs) and emits a linked ARM template that creates them in a workspace.

.DESCRIPTION
    Run locally or in CI to regenerate deploy/compiled/sentinelContent.json from the
    source-of-truth files under sentinel/. The main ARM template includes this as a
    nested deployment so one click installs ALL content.

    Output: deploy/compiled/sentinelContent.json

.EXAMPLE
    ./tools/Build-SentinelContent.ps1
#>

[CmdletBinding()]
param(
    [string] $RepoRoot  = (Split-Path -Parent $PSScriptRoot),
    [string] $OutputPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $OutputPath) {
    $OutputPath = Join-Path $RepoRoot 'deploy' 'compiled' 'sentinelContent.json'
}

$sentinelDir = Join-Path $RepoRoot 'sentinel'
$parsersDir   = Join-Path $sentinelDir 'parsers'
$workbooksDir = Join-Path $sentinelDir 'workbooks'
$rulesDir     = Join-Path $sentinelDir 'analytic-rules'
$huntingDir   = Join-Path $sentinelDir 'hunting-queries'

# --- Helpers ---

function ConvertFrom-YamlSimple {
    <#
    .SYNOPSIS
        Lightweight YAML → hashtable parser for our Sentinel YAMLs (id, name, description,
        severity, query, tactics, techniques, etc). Not a general YAML parser.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)] [string] $Yaml)

    $out = @{}
    $lines = $Yaml -split "`r?`n"
    $currentKey  = $null
    $currentList = $null
    $blockKey    = $null
    $blockLines  = $null

    foreach ($line in $lines) {
        # Block scalar continuation (after `key: |`)
        if ($null -ne $blockKey) {
            if ($line -match '^\s{2,}(\S.*)$') {
                $blockLines += $Matches[1]
                continue
            } elseif ($line -match '^\s*$') {
                # Blank line inside block
                $blockLines += ''
                continue
            } else {
                $out[$blockKey] = ($blockLines -join "`n").TrimEnd()
                $blockKey = $null
                $blockLines = $null
                # Fall through to parse this line normally
            }
        }

        # List item under a top-level key
        if ($line -match '^\s{2,}-\s+(\S.*)$' -and $currentList) {
            $out[$currentList] += @($Matches[1].Trim())
            continue
        }

        # Top-level key: value or key: | or key:
        if ($line -match '^([A-Za-z][A-Za-z0-9_]*)\s*:\s*(.*)$') {
            $key = $Matches[1]
            $val = $Matches[2]
            $currentKey  = $key
            $currentList = $null

            if ($val -eq '|') {
                $blockKey   = $key
                $blockLines = @()
            } elseif ($val -eq '') {
                # Either list-of-strings or nested object; treat as list until proven otherwise
                $out[$key] = @()
                $currentList = $key
            } else {
                $out[$key] = $val.Trim("'").Trim('"').Trim()
            }
            continue
        }
    }

    # Flush trailing block
    if ($null -ne $blockKey) {
        $out[$blockKey] = ($blockLines -join "`n").TrimEnd()
    }

    return $out
}

function Escape-ArmString {
    <#
    .SYNOPSIS
        Escapes a string for ARM JSON embedding (JSON.NET-style escaping is handled by ConvertTo-Json).
    #>
    param([string] $Text)
    if ($null -eq $Text) { return '' }
    return $Text
}

# --- 1. Load parsers ---

Write-Host "Loading parsers from $parsersDir..." -ForegroundColor Cyan
$parsers = @()
foreach ($file in Get-ChildItem -Path $parsersDir -Filter '*.kql') {
    $name = $file.BaseName
    $content = Get-Content $file.FullName -Raw

    # Default parameter signatures per parser. Lookback/window pairs reflect
    # the per-tier poll cadence so workbooks pick up sensible defaults when
    # callers invoke the parser without arguments.
    $params = switch ($name) {
        'MDE_Drift_Exposure'      { 'lookback:timespan = 7d,  window:timespan = 1h' }
        'MDE_Drift_Configuration' { 'lookback:timespan = 7d,  window:timespan = 6h' }
        'MDE_Drift_Inventory'     { 'lookback:timespan = 30d, window:timespan = 1d' }
        'MDE_Drift_Maintenance'   { 'lookback:timespan = 30d, window:timespan = 7d' }
        default                   { '' }
    }

    $parsers += @{
        Name       = $name
        Query      = $content
        Parameters = $params
    }
    Write-Host "  + $name ($([int]($content.Length / 1024)) KB)"
}

# --- 2. Load workbooks ---

Write-Host "`nLoading workbooks from $workbooksDir..." -ForegroundColor Cyan
$workbooks = @()
foreach ($file in Get-ChildItem -Path $workbooksDir -Filter '*.json') {
    $name     = $file.BaseName
    $raw      = Get-Content $file.FullName -Raw
    # Parse to validate and normalize
    $parsed   = $raw | ConvertFrom-Json
    $serialized = $parsed | ConvertTo-Json -Depth 30 -Compress

    $displayName = switch ($name) {
        'MDE_ActionCenter'         { 'MDE Action Center' }
        'MDE_ComplianceDashboard'  { 'MDE Compliance Dashboard' }
        'MDE_DriftReport'          { 'MDE Drift Report' }
        'MDE_GovernanceScorecard'  { 'MDE Governance Scorecard' }
        'MDE_ExposureMap'          { 'MDE Exposure Map' }
        'MDE_IdentityPosture'      { 'MDE Identity Posture' }
        'MDE_ResponseAudit'        { 'MDE Response Audit' }
        default                    { $name }
    }

    $workbooks += @{
        Name          = $name
        DisplayName   = $displayName
        SerializedData = $serialized
    }
    Write-Host "  + $displayName ($([int]($serialized.Length / 1024)) KB)"
}

# --- 3. Load analytic rules (YAML) ---

Write-Host "`nLoading analytic rules from $rulesDir..." -ForegroundColor Cyan
$rules = @()
foreach ($file in Get-ChildItem -Path $rulesDir -Filter '*.yaml') {
    $yaml = Get-Content $file.FullName -Raw
    $parsed = ConvertFrom-YamlSimple -Yaml $yaml

    $rules += @{
        File          = $file.BaseName
        Id            = $parsed.id
        Name          = $parsed.name
        Description   = $parsed.description
        Severity      = if ($parsed.severity) { $parsed.severity } else { 'Medium' }
        Query         = $parsed.query
        QueryFrequency= if ($parsed.queryFrequency) { "PT$((($parsed.queryFrequency -replace '[^\d]', '') + 'M'))" } else { 'PT15M' }
        QueryPeriod   = if ($parsed.queryPeriod)    { "PT$((($parsed.queryPeriod    -replace '[^\d]', '') + 'H'))" } else { 'PT2H' }
        Tactics       = if ($parsed.tactics)  { $parsed.tactics } else { @() }
        Techniques    = if ($parsed.relevantTechniques) { $parsed.relevantTechniques } else { @() }
    }
    Write-Host "  + $($parsed.name) ($($parsed.severity))"
}

# --- 4. Load hunting queries (YAML) ---

Write-Host "`nLoading hunting queries from $huntingDir..." -ForegroundColor Cyan
$huntingQueries = @()
foreach ($file in Get-ChildItem -Path $huntingDir -Filter '*.yaml') {
    $yaml = Get-Content $file.FullName -Raw
    $parsed = ConvertFrom-YamlSimple -Yaml $yaml

    $huntingQueries += @{
        File         = $file.BaseName
        Id           = $parsed.id
        Name         = $parsed.name
        Description  = $parsed.description
        Query        = $parsed.query
        Tactics      = if ($parsed.tactics)  { $parsed.tactics } else { @() }
        Techniques   = if ($parsed.relevantTechniques) { $parsed.relevantTechniques } else { @() }
    }
    Write-Host "  + $($parsed.name)"
}

# --- 5. Emit linked ARM template ---

$armResources = @()

# Parsers as savedSearches in 'Functions' category
foreach ($p in $parsers) {
    $armResources += @{
        type       = 'Microsoft.OperationalInsights/workspaces/savedSearches'
        apiVersion = '2020-08-01'
        name       = "[concat(parameters('workspaceName'), '/', '$($p.Name)')]"
        properties = @{
            category           = 'Functions'
            displayName        = $p.Name
            query              = $p.Query
            functionAlias      = $p.Name
            functionParameters = $p.Parameters
            version            = 2
        }
    }
}

# Hunting queries as savedSearches in 'Hunting Queries' category
foreach ($q in $huntingQueries) {
    $tags = @()
    $tags += @{ name = 'description'; value = $q.Description }
    $tags += @{ name = 'tactics';     value = ($q.Tactics -join ',') }
    $tags += @{ name = 'techniques';  value = ($q.Techniques -join ',') }

    $armResources += @{
        type       = 'Microsoft.OperationalInsights/workspaces/savedSearches'
        apiVersion = '2020-08-01'
        name       = "[concat(parameters('workspaceName'), '/', '$($q.File)')]"
        properties = @{
            category    = 'Hunting Queries'
            displayName = $q.Name
            query       = $q.Query
            version     = 2
            tags        = $tags
        }
    }
}

# Workbooks
foreach ($w in $workbooks) {
    $armResources += @{
        type       = 'Microsoft.Insights/workbooks'
        apiVersion = '2022-04-01'
        name       = "[guid(resourceGroup().id, '$($w.Name)')]"
        location   = "[parameters('location')]"
        kind       = 'shared'
        properties = @{
            displayName    = $w.DisplayName
            serializedData = $w.SerializedData
            category       = 'sentinel'
            version        = '1.0'
            sourceId       = "[resourceId('Microsoft.OperationalInsights/workspaces', parameters('workspaceName'))]"
        }
    }
}

# Analytic rules — extension resources on Microsoft.SecurityInsights
foreach ($r in $rules) {
    $armResources += @{
        type       = 'Microsoft.OperationalInsights/workspaces/providers/alertRules'
        apiVersion = '2023-11-01'
        name       = "[concat(parameters('workspaceName'), '/Microsoft.SecurityInsights/', '$($r.Id)')]"
        kind       = 'Scheduled'
        properties = @{
            displayName         = $r.Name
            description         = $r.Description
            severity            = $r.Severity
            enabled             = $false  # ship disabled — per best practice
            query               = $r.Query
            queryFrequency      = $r.QueryFrequency
            queryPeriod         = $r.QueryPeriod
            triggerOperator     = 'GreaterThan'
            triggerThreshold    = 0
            suppressionDuration = 'PT5H'
            suppressionEnabled  = $false
            # Force array shape — Sentinel API rejects scalars on these fields
            # with `Error converting value "X" to type 'AttackTactic[]'`. The
            # simple YAML parser flattens 1-item lists to scalars; @(...) keeps
            # both 1-item and N-item cases as JSON arrays after ConvertTo-Json.
            tactics             = @($r.Tactics)
            # Sentinel alertRules `techniques` regex is ^T\d+$ — sub-techniques
            # (T1562.001) are rejected with `The technique 'T1562.001' is invalid.
            # The expected format is 'T####'`. Strip any `.NNN` suffix so the
            # parent tags the rule correctly. Sub-technique fidelity remains in
            # the corresponding hunting query's tags[] (savedSearches accepts it).
            techniques          = @($r.Techniques | ForEach-Object { ($_ -replace '\.\d+$', '') })
            eventGroupingSettings = @{
                aggregationKind = 'SingleAlert'
            }
        }
    }
}

# Solution Content Hub metadata blocks — register each parser, workbook,
# analytic rule, and hunting query under Microsoft.SecurityInsights so the
# Content Hub UI groups them under the XdrLogRaider solution row.

# Parsers (kind = Parser, parent = savedSearches function)
foreach ($p in $parsers) {
    $armResources += [ordered]@{
        type       = 'Microsoft.OperationalInsights/workspaces/providers/metadata'
        apiVersion = '2023-04-01-preview'
        name       = "[concat(parameters('workspaceName'), '/Microsoft.SecurityInsights/Parser-$($p.Name)')]"
        location   = "[parameters('location')]"
        properties = [ordered]@{
            parentId  = "[resourceId('Microsoft.OperationalInsights/workspaces/savedSearches', parameters('workspaceName'), '$($p.Name)')]"
            contentId = $p.Name
            kind      = 'Parser'
            version   = "[variables('solutionVersion')]"
            source    = "[variables('solutionSource')]"
            author    = "[variables('solutionAuthor')]"
            support   = "[variables('solutionSupport')]"
        }
        dependsOn = @(
            "[resourceId('Microsoft.OperationalInsights/workspaces/savedSearches', parameters('workspaceName'), '$($p.Name)')]"
        )
    }
}

# Hunting queries (kind = HuntingQuery, parent = savedSearches in Hunting Queries)
foreach ($q in $huntingQueries) {
    $armResources += [ordered]@{
        type       = 'Microsoft.OperationalInsights/workspaces/providers/metadata'
        apiVersion = '2023-04-01-preview'
        name       = "[concat(parameters('workspaceName'), '/Microsoft.SecurityInsights/HuntingQuery-$($q.File)')]"
        location   = "[parameters('location')]"
        properties = [ordered]@{
            parentId  = "[resourceId('Microsoft.OperationalInsights/workspaces/savedSearches', parameters('workspaceName'), '$($q.File)')]"
            contentId = $q.File
            kind      = 'HuntingQuery'
            version   = "[variables('solutionVersion')]"
            source    = "[variables('solutionSource')]"
            author    = "[variables('solutionAuthor')]"
            support   = "[variables('solutionSupport')]"
        }
        dependsOn = @(
            "[resourceId('Microsoft.OperationalInsights/workspaces/savedSearches', parameters('workspaceName'), '$($q.File)')]"
        )
    }
}

# Workbooks (kind = Workbook, parent = Microsoft.Insights/workbooks resource)
foreach ($w in $workbooks) {
    $armResources += [ordered]@{
        type       = 'Microsoft.OperationalInsights/workspaces/providers/metadata'
        apiVersion = '2023-04-01-preview'
        name       = "[concat(parameters('workspaceName'), '/Microsoft.SecurityInsights/Workbook-$($w.Name)')]"
        location   = "[parameters('location')]"
        properties = [ordered]@{
            parentId  = "[resourceId('Microsoft.Insights/workbooks', guid(resourceGroup().id, '$($w.Name)'))]"
            contentId = $w.Name
            kind      = 'Workbook'
            version   = "[variables('solutionVersion')]"
            source    = "[variables('solutionSource')]"
            author    = "[variables('solutionAuthor')]"
            support   = "[variables('solutionSupport')]"
        }
        dependsOn = @(
            "[resourceId('Microsoft.Insights/workbooks', guid(resourceGroup().id, '$($w.Name)'))]"
        )
    }
}

# Analytic rules (kind = AnalyticsRule, parent = alertRules)
foreach ($r in $rules) {
    $armResources += [ordered]@{
        type       = 'Microsoft.OperationalInsights/workspaces/providers/metadata'
        apiVersion = '2023-04-01-preview'
        name       = "[concat(parameters('workspaceName'), '/Microsoft.SecurityInsights/AnalyticsRule-$($r.Id)')]"
        location   = "[parameters('location')]"
        properties = [ordered]@{
            parentId  = "[resourceId('Microsoft.OperationalInsights/workspaces/providers/alertRules', parameters('workspaceName'), 'Microsoft.SecurityInsights', '$($r.Id)')]"
            contentId = $r.Id
            kind      = 'AnalyticsRule'
            version   = "[variables('solutionVersion')]"
            source    = "[variables('solutionSource')]"
            author    = "[variables('solutionAuthor')]"
            support   = "[variables('solutionSupport')]"
        }
        dependsOn = @(
            "[resourceId('Microsoft.OperationalInsights/workspaces/providers/alertRules', parameters('workspaceName'), 'Microsoft.SecurityInsights', '$($r.Id)')]"
        )
    }
}

# --- 6. Wrap in ARM template ---

$armTemplate = [ordered]@{
    '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
    contentVersion = '1.0.0.0'
    metadata       = @{
        _generator = 'tools/Build-SentinelContent.ps1'
        description = 'XdrLogRaider — Sentinel content (parsers, workbooks, analytic rules, hunting queries).'
    }
    parameters = @{
        workspaceName = @{
            type = 'string'
            metadata = @{ description = 'Log Analytics workspace name.' }
        }
        location = @{
            type = 'string'
            defaultValue = '[resourceGroup().location]'
        }
    }
    # Solution Content Hub variables — every metadata block above references
    # these so the Sentinel UI groups installed content under the XdrLogRaider
    # solution row.
    variables  = [ordered]@{
        solutionId      = 'community.xdrlograider'
        solutionName    = 'XdrLogRaider'
        solutionVersion = '0.1.0-beta'
        solutionSource  = [ordered]@{ kind = 'Solution'; name = 'XdrLogRaider'; sourceId = 'community.xdrlograider' }
        solutionAuthor  = [ordered]@{ name = 'Alex Kefallonitis'; email = 'al.kefallonitis@gmail.com' }
        solutionSupport = [ordered]@{ name = 'XdrLogRaider'; email = 'al.kefallonitis@gmail.com'; tier = 'Community'; link = 'https://github.com/akefallonitis/xdrlograider' }
    }
    resources  = $armResources
    outputs    = @{
        parsersCount = @{ type = 'int'; value = $parsers.Count }
        workbooksCount = @{ type = 'int'; value = $workbooks.Count }
        rulesCount = @{ type = 'int'; value = $rules.Count }
        huntingQueriesCount = @{ type = 'int'; value = $huntingQueries.Count }
    }
}

# Write output
$parent = Split-Path -Parent $OutputPath
if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

$json = $armTemplate | ConvertTo-Json -Depth 30
Set-Content -Path $OutputPath -Value $json -Encoding UTF8

$size = (Get-Item $OutputPath).Length
Write-Host "`n✓ Wrote $OutputPath ($([int]($size / 1024)) KB)" -ForegroundColor Green
Write-Host "  Parsers:         $($parsers.Count)"
Write-Host "  Workbooks:       $($workbooks.Count)"
Write-Host "  Analytic rules:  $($rules.Count)"
Write-Host "  Hunting queries: $($huntingQueries.Count)"
Write-Host "  Total resources: $($armResources.Count)"
