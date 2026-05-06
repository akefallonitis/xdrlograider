#Requires -Version 7.4
<#
.SYNOPSIS
    Operator-runnable schema audit. Mirror of tests/arm/SchemaConsistency.Tests.ps1
    but runs without Pester so operators can verify deployment-readiness locally.

.DESCRIPTION
    Audits all 4 schema-consistency invariants:

      1. ProjectionMap cast hint matches DCR streamDecl column type
      2. Streams writing to same Defender_<Category>_CL agree on every shared column type
      3. DCR streamDecl column type matches workspace table column type for the dataFlow output stream
      4. Each DCR covers exactly 1 category (per-category architecture, no bucket-fill)

    Returns:
      - Exit 0 + GREEN summary if all invariants hold
      - Exit 1 + RED summary listing every violation if any layer drifts

.EXAMPLE
    pwsh tools/Audit-DcrSchema.ps1

    Use before clicking Deploy-to-Azure to confirm no schema regression
    has slipped into your branch.
#>
[CmdletBinding()]
param(
    [string] $TemplatePath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'deploy/compiled/mainTemplate.json'),
    [string] $ManifestPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1')
)

$ErrorActionPreference = 'Stop'

$tpl      = Get-Content -Raw $TemplatePath | ConvertFrom-Json -Depth 50
$manifest = Import-PowerShellDataFile -Path $ManifestPath

$castMap = @{
    'tostring' = 'string'; 'toint' = 'int'; 'tobool' = 'boolean'
    'todatetime' = 'datetime'; 'todouble' = 'real'; 'todecimal' = 'real'
    'tolong' = 'long'; 'toguid' = 'string'; 'json' = 'dynamic'
}

$categoryToTable = @{
    'Action Center'                 = 'Defender_ActionCenter_CL'
    'Configuration and Settings'    = 'Defender_ConfigurationAndSettings_CL'
    'Endpoint Configuration'        = 'Defender_EndpointConfiguration_CL'
    'Endpoint Device Management'    = 'Defender_EndpointDeviceManagement_CL'
    'Exposure Management (XSPM)'    = 'Defender_ExposureManagement_CL'
    'Identity Protection (MDI)'     = 'Defender_IdentityProtection_CL'
    'Multi-Tenant Operations'       = 'Defender_MultiTenantOperations_CL'
    'Streaming API'                 = 'Defender_StreamingApi_CL'
    'Threat Analytics'              = 'Defender_ThreatAnalytics_CL'
    'Vulnerability Management (TVM)'= 'Defender_VulnerabilityManagement_CL'
}

function Find-Tables {
    param($Node)
    $found = @()
    if ($Node -is [array]) {
        foreach ($r in $Node) { $found += Find-Tables -Node $r }
        return $found
    }
    if ($Node.type -eq 'Microsoft.OperationalInsights/workspaces/tables') { $found += $Node }
    if ($Node.type -eq 'Microsoft.Resources/deployments' -and
        $Node.PSObject.Properties.Name -contains 'properties' -and
        $Node.properties.PSObject.Properties.Name -contains 'template' -and
        $Node.properties.template.PSObject.Properties.Name -contains 'resources') {
        $found += Find-Tables -Node $Node.properties.template.resources
    }
    return $found
}

# Index DCR streamDecls + dataFlows
$dcrStreamDecls = @{}
$dcrFlows = @()
$dcrToCategoryCount = @{}
$streamToCategory = @{}
foreach ($e in $manifest.Endpoints) {
    if ($e.Category) { $streamToCategory[$e.Stream] = $e.Category }
}

foreach ($d in $tpl.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' }) {
    $dcrName = $d.name
    foreach ($prop in $d.properties.streamDeclarations.PSObject.Properties) {
        $sn = $prop.Name -replace '^Custom-', ''
        $cols = @{}
        foreach ($c in $prop.Value.columns) { $cols[$c.name] = $c.type }
        $dcrStreamDecls[$sn] = $cols

        $cat = if ($streamToCategory.ContainsKey($sn)) { $streamToCategory[$sn] } else { '<ops>' }
        if (-not $dcrToCategoryCount.ContainsKey($dcrName)) { $dcrToCategoryCount[$dcrName] = @{} }
        $dcrToCategoryCount[$dcrName][$cat] = $true
    }
    foreach ($df in $d.properties.dataFlows) {
        $sn = ($df.streams[0] -replace '^Custom-', '')
        $out = $df.outputStream -replace '^Custom-', ''
        $dcrFlows += @{ Stream = $sn; OutputStream = $out }
    }
}

# Index workspace tables
$tableCols = @{}
foreach ($t in (Find-Tables -Node $tpl.resources)) {
    $tname = $null
    if ($t.name -match "/([A-Za-z_]+_CL)'") { $tname = $Matches[1] }
    elseif ($t.name -match "concat\([^,]+,\s*'/(.+)'\)") { $tname = $Matches[1] }
    if (-not $tname -or -not $t.properties.schema.columns) { continue }
    $tableCols[$tname] = @{}
    foreach ($c in $t.properties.schema.columns) { $tableCols[$tname][$c.name] = $c.type }
}

$totalErrors = 0

Write-Host ""
Write-Host "===== Audit 1/4: ProjectionMap cast hint vs DCR streamDecl =====" -ForegroundColor Cyan
$layer1Errors = 0
foreach ($e in $manifest.Endpoints) {
    if (-not $e.ProjectionMap) { continue }
    $sn = $e.Stream
    if (-not $dcrStreamDecls.ContainsKey($sn)) { continue }
    foreach ($k in $e.ProjectionMap.Keys) {
        $hint = $e.ProjectionMap[$k]
        if ($hint -isnot [string] -or $hint -notmatch '^\$([a-z]+):') { continue }
        $cast = $Matches[1]
        if (-not $castMap.ContainsKey($cast)) { continue }
        $expected = $castMap[$cast]
        $sd = $dcrStreamDecls[$sn][$k]
        if ($sd -and $sd -ne $expected) {
            Write-Host ("  FAIL: {0}.{1} cast=`${2}('{3}') streamDecl='{4}'" -f $sn, $k, $cast, $expected, $sd) -ForegroundColor Red
            $layer1Errors++
        }
    }
}
if ($layer1Errors -eq 0) { Write-Host "  PASS" -ForegroundColor Green } else { $totalErrors += $layer1Errors }

Write-Host ""
Write-Host "===== Audit 2/4: Cross-stream column type agreement per consolidated table =====" -ForegroundColor Cyan
$layer2Errors = 0
$tableToStreams = @{}
foreach ($e in $manifest.Endpoints) {
    if (-not $e.Category -or -not $categoryToTable.ContainsKey($e.Category)) { continue }
    $tab = $categoryToTable[$e.Category]
    if (-not $tableToStreams.ContainsKey($tab)) { $tableToStreams[$tab] = @() }
    $tableToStreams[$tab] += $e.Stream
}
foreach ($tab in ($tableToStreams.Keys | Sort-Object)) {
    $streams = $tableToStreams[$tab]
    if ($streams.Count -le 1) { continue }
    $columnTypes = @{}
    foreach ($sn in $streams) {
        if (-not $dcrStreamDecls.ContainsKey($sn)) { continue }
        foreach ($colKvp in $dcrStreamDecls[$sn].GetEnumerator()) {
            if (-not $columnTypes.ContainsKey($colKvp.Key)) { $columnTypes[$colKvp.Key] = @{} }
            $columnTypes[$colKvp.Key][$sn] = $colKvp.Value
        }
    }
    foreach ($col in $columnTypes.Keys) {
        $types = @($columnTypes[$col].Values | Select-Object -Unique)
        if ($types.Count -gt 1) {
            $detail = ($columnTypes[$col].GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '
            Write-Host ("  FAIL: {0}.{1}: {2}" -f $tab, $col, $detail) -ForegroundColor Red
            $layer2Errors++
        }
    }
}
if ($layer2Errors -eq 0) { Write-Host "  PASS" -ForegroundColor Green } else { $totalErrors += $layer2Errors }

Write-Host ""
Write-Host "===== Audit 3/4: DCR streamDecl vs Workspace Table column types =====" -ForegroundColor Cyan
$layer3Errors = 0
foreach ($f in $dcrFlows) {
    if (-not $dcrStreamDecls.ContainsKey($f.Stream)) { continue }
    if (-not $tableCols.ContainsKey($f.OutputStream)) { continue }
    $sd = $dcrStreamDecls[$f.Stream]
    $tc = $tableCols[$f.OutputStream]
    foreach ($colKvp in $sd.GetEnumerator()) {
        if ($tc.ContainsKey($colKvp.Key) -and $tc[$colKvp.Key] -ne $colKvp.Value) {
            Write-Host ("  FAIL: {0} -> {1}.{2}: streamDecl='{3}' table='{4}'" -f $f.Stream, $f.OutputStream, $colKvp.Key, $colKvp.Value, $tc[$colKvp.Key]) -ForegroundColor Red
            $layer3Errors++
        }
    }
}
if ($layer3Errors -eq 0) { Write-Host "  PASS" -ForegroundColor Green } else { $totalErrors += $layer3Errors }

Write-Host ""
Write-Host "===== Audit 4/4: DCR-to-category coverage (per-category architecture) =====" -ForegroundColor Cyan
$layer4Errors = 0
foreach ($dcr in ($dcrToCategoryCount.Keys | Sort-Object)) {
    $catCount = $dcrToCategoryCount[$dcr].Keys.Count
    if ($catCount -gt 1) {
        $cats = ($dcrToCategoryCount[$dcr].Keys | Sort-Object) -join ', '
        Write-Host ("  FAIL: {0} covers {1} categories ({2}) — should be 1" -f $dcr, $catCount, $cats) -ForegroundColor Red
        $layer4Errors++
    }
}
if ($layer4Errors -eq 0) { Write-Host "  PASS" -ForegroundColor Green } else { $totalErrors += $layer4Errors }

Write-Host ""
if ($totalErrors -eq 0) {
    Write-Host "===== ALL 4 SCHEMA AUDITS PASS — DEPLOYMENT-READY =====" -ForegroundColor Green
    exit 0
} else {
    Write-Host ("===== {0} VIOLATION(S) — DEPLOYMENT WILL FAIL =====" -f $totalErrors) -ForegroundColor Red
    Write-Host "Run tools/Build-DcrSection.ps1 to regenerate DCR section, then re-audit." -ForegroundColor Yellow
    exit 1
}
