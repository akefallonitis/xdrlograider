$tpl = Get-Content 'C:/Users/akefa/Desktop/repos/xdrlograider/deploy/compiled/mainTemplate.json' -Raw | ConvertFrom-Json
$manifest = Import-PowerShellDataFile -Path 'C:/Users/akefa/Desktop/repos/xdrlograider/src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1'

# Cast-hint → ARM column type mapping
$castToArmType = @{
    'tostring'   = 'string'
    'toint'      = 'int'
    'tobool'     = 'boolean'
    'todatetime' = 'datetime'
    'todouble'   = 'real'
    'todecimal'  = 'real'
    'tolong'     = 'long'
    'toguid'     = 'string'
    'json'       = 'dynamic'
}

# Build streamDecl + workspace-table lookup
$streamDeclTypes = @{}
foreach ($d in $tpl.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' }) {
    foreach ($prop in $d.properties.streamDeclarations.PSObject.Properties) {
        $streamName = $prop.Name -replace '^Custom-', ''
        $streamDeclTypes[$streamName] = @{}
        foreach ($col in $prop.Value.columns) {
            $streamDeclTypes[$streamName][$col.name] = $col.type
        }
    }
}

$tableTypes = @{}
foreach ($t in $tpl.resources | Where-Object { $_.type -eq 'Microsoft.OperationalInsights/workspaces/tables' }) {
    $tname = ($t.name -split '/')[-1]
    if (-not $t.properties.schema -or -not $t.properties.schema.columns) { continue }
    $tableTypes[$tname] = @{}
    foreach ($col in $t.properties.schema.columns) {
        $tableTypes[$tname][$col.name] = $col.type
    }
}

# Cross-check each manifest stream
$mismatches = @()
foreach ($e in $manifest.Endpoints) {
    if (-not $e.ProjectionMap) { continue }
    $stream = $e.Stream
    $tableName = $e.Table  # e.g. Defender_ThreatAnalytics_CL
    foreach ($k in $e.ProjectionMap.Keys) {
        $hint = $e.ProjectionMap[$k]
        if ($hint -isnot [string]) { continue }
        # Cast hint pattern: $<cast>:<path>  e.g. $tostring:Tags[*]  or  $json:Tags
        $cast = ''
        if ($hint -match '^\$([a-z]+):') {
            $cast = $Matches[1]
        }
        $expectedArm = if ($castToArmType.ContainsKey($cast)) { $castToArmType[$cast] } else { 'string' }
        $sd = if ($streamDeclTypes.ContainsKey($stream)) { $streamDeclTypes[$stream][$k] } else { '<no streamDecl>' }
        $tab = if ($tableName -and $tableTypes.ContainsKey($tableName)) { $tableTypes[$tableName][$k] } else { '<no table>' }

        if ($sd -and $sd -ne $expectedArm -or ($tab -and $tab -ne $expectedArm)) {
            $mismatches += [pscustomobject]@{
                Stream    = $stream
                Table     = $tableName
                Column    = $k
                Cast      = $cast
                Expected  = $expectedArm
                StreamDecl= $sd
                TableCol  = $tab
            }
        }
    }
}

if ($mismatches) {
    Write-Host ("=== {0} TYPE MISMATCHES FOUND ===" -f $mismatches.Count) -ForegroundColor Red
    $mismatches | Format-Table -AutoSize
} else {
    Write-Host "No type mismatches" -ForegroundColor Green
}
