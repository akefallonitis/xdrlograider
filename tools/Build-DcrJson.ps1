<#
.SYNOPSIS
    Phase 0' Step 9.G · DATA-DRIVEN DCR generator · reads v3 manifests + schemas · emits deploy/dcrs/dcr-xdrlr-<subarea>.json.

.DESCRIPTION
    Per plan §3.7 + §20.C.9 + Decision D-40 (data-driven · NOT bulk-copy).
    For each ACTIVE portal × distinct SubArea:
      1. Read manifest entries (Step 5 candidates · post Step-7 classification)
      2. Read per-endpoint schema.json (Step 8 derivation) if present · else use 14 mandatory cols
      3. Aggregate column-typed declaration · merge curated ProjectionMap columns
      4. Emit Azure ARM DCR resource with streamDeclarations + dataFlows + destinations

    DCR streamDecl columns:
      - 14 mandatory (Gate E LOCKED)
      - 2 LiveStream extras when IngestionMode=LIVESTREAM
      - +N curated ProjectionMap columns (typed per Step 8 derivation)

    Idempotent: same v3 inputs → byte-identical DCRs (Test-Determinism foundation).

.PARAMETER Portal
    Default 'Defender' (only ACTIVE v0.1.0 portal). v0.3.0+ adds others.

.PARAMETER OutputDir
    Default deploy/dcrs/.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot,
    [string] $Portal = 'Defender',
    [string] $OutputDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $RepoRoot) { $RepoRoot = Split-Path $PSScriptRoot -Parent }
if (-not $OutputDir) { $OutputDir = Join-Path $RepoRoot 'deploy/dcrs' }
$null = New-Item -ItemType Directory -Path $OutputDir -Force

Import-Module (Join-Path $RepoRoot 'src/Modules/Xdr.Common.Manifest/Xdr.Common.Manifest.psd1') -Force

$manifest = Get-XdrEndpointManifest -Portal $Portal
Write-Host "Build-DcrJson · Portal=$Portal · $($manifest.EntryCount) entries"

# Group by SubArea
$subAreas = $manifest.Entries | Group-Object SubArea | Sort-Object Name

$mandatoryCols = @(
    @{ name='TimeGenerated'; type='datetime' }
    @{ name='RawJson'; type='string' }
    @{ name='RawResponseBody'; type='string' }
    @{ name='SubArea'; type='string' }
    @{ name='Stream'; type='string' }
    @{ name='ConnectorVersion'; type='string' }
    @{ name='CorrelationId'; type='string' }
    @{ name='SuccessKind'; type='string' }
    @{ name='StatusCode'; type='int' }
    @{ name='CapturedUtc'; type='datetime' }
    @{ name='entities'; type='dynamic' }
    @{ name='EventType'; type='string' }
    @{ name='PollCycleId'; type='string' }
    @{ name='EntryKey'; type='string' }
)

$liveStreamExtras = @(
    @{ name='_OriginalRowId'; type='string' }
    @{ name='IngestionMode'; type='string' }
)

$emitted = 0
foreach ($g in $subAreas) {
    $subArea = $g.Name
    $entries = @($g.Group)
    $tableName = Get-XdrCategoryTableName -Portal $Portal -SubArea $subArea
    $streamName = "Custom-$tableName"

    # Detect if ANY entry is LIVESTREAM (then add _OriginalRowId + IngestionMode)
    $hasLiveStream = @($entries | Where-Object { $_.IngestionMode -eq 'LIVESTREAM' }).Count -gt 0

    # Build columns: mandatory + livestream-extras + curated projection columns from Step 8
    $cols = [System.Collections.Generic.List[object]]::new()
    foreach ($c in $mandatoryCols) { $cols.Add(@{ name = $c.name; type = $c.type }) | Out-Null }
    if ($hasLiveStream) {
        foreach ($c in $liveStreamExtras) { $cols.Add(@{ name = $c.name; type = $c.type }) | Out-Null }
    }

    # Merge curated ProjectionMap columns (deterministic order via sorted keys)
    $projCols = @{}
    foreach ($e in $entries) {
        $pm = if ($e.ContainsKey('ProjectionMap')) { $e.ProjectionMap } else { @{} }
        foreach ($k in $pm.Keys) {
            if (-not $projCols.ContainsKey($k)) {
                $expr = [string]$pm[$k]
                $kqlType = if ($expr -match '^\$tostring:')  { 'string' }
                          elseif ($expr -match '^\$tolong:')  { 'long' }
                          elseif ($expr -match '^\$todouble:'){ 'real' }
                          elseif ($expr -match '^\$tobool:')  { 'bool' }
                          elseif ($expr -match '^\$todatetime:'){ 'datetime' }
                          elseif ($expr -match '^\$tojson:')   { 'dynamic' }
                          else { 'string' }
                $projCols[$k] = $kqlType
            }
        }
    }
    foreach ($k in ($projCols.Keys | Sort-Object)) {
        # Skip if column name collides with mandatory (mandatory wins · Gate E)
        if (@($mandatoryCols.name) -notcontains $k -and @($liveStreamExtras.name) -notcontains $k) {
            $cols.Add(@{ name = $k; type = $projCols[$k] }) | Out-Null
        }
    }

    # Emit DCR JSON (ARM-compatible · operator's DCE will reference)
    $dcr = [ordered]@{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
        contentVersion = '0.1.0'
        parameters     = @{}
        variables      = @{}
        resources = @(
            [ordered]@{
                type       = 'Microsoft.Insights/dataCollectionRules'
                apiVersion = '2023-03-11'
                name       = "[parameters('dcrName_$subArea')]"
                location   = "[parameters('location')]"
                properties = [ordered]@{
                    streamDeclarations = [ordered]@{
                        "$streamName" = [ordered]@{
                            columns = $cols.ToArray()
                        }
                    }
                    destinations = [ordered]@{
                        logAnalytics = @(
                            [ordered]@{
                                workspaceResourceId = "[parameters('workspaceResourceId')]"
                                name = 'sentinel-workspace'
                            }
                        )
                    }
                    dataFlows = @(
                        [ordered]@{
                            streams      = @($streamName)
                            destinations = @('sentinel-workspace')
                            outputStream = "Custom-$tableName"
                        }
                    )
                }
            }
        )
    }
    $outFile = Join-Path $OutputDir "dcr-xdrlr-$($subArea.ToLowerInvariant()).json"
    $dcr | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $outFile -Encoding UTF8
    Write-Host ("  · {0,-30} cols={1,3} entries={2,4} liveStream={3,-5} → {4}" -f $subArea, $cols.Count, $entries.Count, $hasLiveStream, (Split-Path $outFile -Leaf))
    $emitted++
}

Write-Host ""
Write-Host "✓ Emitted $emitted DCRs to $OutputDir"
