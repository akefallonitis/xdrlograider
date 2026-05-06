#Requires -Modules Pester
<#
.SYNOPSIS
    Schema consistency gate — prevents the deployment-time type-mismatch
    class of error caught in the v0.1.0 GA preflight.

.DESCRIPTION
    Three layers of schema must agree per column:

      1. Manifest ProjectionMap cast hint  ($tostring/$toint/$tobool/$todatetime/
         $todouble/$todecimal/$tolong/$toguid/$json)  ->  ARM column type
         (string/int/boolean/datetime/real/long/dynamic)

      2. DCR streamDeclarations[].columns[].type
         (must match the ProjectionMap cast hint)

      3. Workspace table column type when explicit
         (must match the DCR streamDecl)

    PLUS the cross-stream constraint: when N streams write to the same
    consolidated workspace table (Defender_<Category>_CL), every shared column
    name across those streams must agree on type. Sentinel auto-derives the
    workspace table's column type from the FIRST DCR streamDecl that writes
    to it; subsequent streams with a different declared type fail with
    InvalidTransformOutput at deploy time.

    This test reads:
      - src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1 (manifest)
      - deploy/compiled/mainTemplate.json (DCR streamDecls + tables)

    and asserts every cross-layer / cross-stream type relationship agrees.

.NOTES
    Without this test the type conflicts that broke deployment in v0.1.0
    preflight (Action int vs string, Scope int vs string, Tags string vs
    dynamic, TotalAccessRequests int vs long) would silently regress.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $tplPath = Join-Path $script:RepoRoot 'deploy/compiled/mainTemplate.json'
    $manPath = Join-Path $script:RepoRoot 'src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1'

    $script:Tpl = Get-Content $tplPath -Raw | ConvertFrom-Json -Depth 30
    $script:Manifest = Import-PowerShellDataFile -Path $manPath

    $script:CastMap = @{
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

    $script:CategoryToTable = @{
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

    # Index DCR streamDecls
    $script:DcrStreamDecls = @{}  # streamName -> @{ name=type }
    foreach ($d in $script:Tpl.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' }) {
        foreach ($prop in $d.properties.streamDeclarations.PSObject.Properties) {
            $sn = $prop.Name -replace '^Custom-', ''
            $cols = @{}
            foreach ($c in $prop.Value.columns) { $cols[$c.name] = $c.type }
            $script:DcrStreamDecls[$sn] = $cols
        }
    }
}

Describe 'Schema Consistency — ProjectionMap cast hint vs DCR streamDecl' {

    It 'every manifest ProjectionMap cast hint matches the DCR streamDecl column type' {
        $mismatches = New-Object System.Collections.ArrayList
        foreach ($e in $script:Manifest.Endpoints) {
            if (-not $e.ProjectionMap) { continue }
            $stream = $e.Stream
            if (-not $script:DcrStreamDecls.ContainsKey($stream)) { continue }
            $cols = $script:DcrStreamDecls[$stream]
            foreach ($k in $e.ProjectionMap.Keys) {
                $hint = $e.ProjectionMap[$k]
                if ($hint -isnot [string]) { continue }
                if ($hint -notmatch '^\$([a-z]+):') { continue }
                $cast = $Matches[1]
                if (-not $script:CastMap.ContainsKey($cast)) { continue }
                $expected = $script:CastMap[$cast]
                if ($cols.ContainsKey($k) -and $cols[$k] -ne $expected) {
                    [void]$mismatches.Add(("{0}.{1} cast=`${2}('{3}') streamDecl='{4}'" -f $stream, $k, $cast, $expected, $cols[$k]))
                }
            }
        }
        if ($mismatches.Count -gt 0) {
            $mismatches | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        }
        $mismatches.Count | Should -Be 0 -Because 'manifest cast hint must match DCR streamDecl column type for the DCR to ingest correctly'
    }
}

Describe 'Schema Consistency — Cross-stream column type agreement per consolidated workspace table' {

    It 'streams writing to the same Defender_<Category>_CL table agree on every shared column type' {
        # Group streams by their target workspace table (derived from category)
        $tableToStreams = @{}
        foreach ($e in $script:Manifest.Endpoints) {
            if (-not $e.Category -or -not $script:CategoryToTable.ContainsKey($e.Category)) { continue }
            $table = $script:CategoryToTable[$e.Category]
            if (-not $tableToStreams.ContainsKey($table)) { $tableToStreams[$table] = @() }
            $tableToStreams[$table] += $e.Stream
        }

        $conflicts = New-Object System.Collections.ArrayList
        foreach ($table in ($tableToStreams.Keys | Sort-Object)) {
            $streams = $tableToStreams[$table]
            if ($streams.Count -le 1) { continue }
            # Per column: collect (stream -> type)
            $columnTypes = @{}
            foreach ($stream in $streams) {
                if (-not $script:DcrStreamDecls.ContainsKey($stream)) { continue }
                foreach ($colKvp in $script:DcrStreamDecls[$stream].GetEnumerator()) {
                    if (-not $columnTypes.ContainsKey($colKvp.Key)) { $columnTypes[$colKvp.Key] = @{} }
                    $columnTypes[$colKvp.Key][$stream] = $colKvp.Value
                }
            }
            # Find conflicts
            foreach ($col in $columnTypes.Keys) {
                $types = @($columnTypes[$col].Values | Select-Object -Unique)
                if ($types.Count -gt 1) {
                    $detail = ($columnTypes[$col].GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '
                    [void]$conflicts.Add(("{0}.{1}: {2}" -f $table, $col, $detail))
                }
            }
        }
        if ($conflicts.Count -gt 0) {
            $conflicts | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        }
        $conflicts.Count | Should -Be 0 -Because 'Sentinel auto-derives workspace-table column type from the FIRST DCR streamDecl that writes to it; subsequent streams with a different type fail with InvalidTransformOutput at deploy time'
    }
}

Describe 'Schema Consistency — DCR streamDecl vs Workspace Table column types' {

    It 'every DCR streamDecl column type matches the workspace table column type for the dataFlow output stream' {
        # Recursively find all workspace tables (top-level + nested deployment).
        function Find-Tables {
            param($Node)
            $found = @()
            if ($Node -is [array]) {
                foreach ($r in $Node) { $found += Find-Tables -Node $r }
                return $found
            }
            if ($Node.type -eq 'Microsoft.OperationalInsights/workspaces/tables') {
                $found += $Node
            }
            if ($Node.type -eq 'Microsoft.Resources/deployments' -and
                $Node.PSObject.Properties.Name -contains 'properties' -and
                $Node.properties.PSObject.Properties.Name -contains 'template' -and
                $Node.properties.template.PSObject.Properties.Name -contains 'resources') {
                $found += Find-Tables -Node $Node.properties.template.resources
            }
            return $found
        }
        $allTables = Find-Tables -Node $script:Tpl.resources

        # Index workspace table columns by table name
        $tableCols = @{}
        foreach ($t in $allTables) {
            $tname = $null
            if ($t.name -match "/([A-Za-z_]+_CL)'") { $tname = $Matches[1] }
            elseif ($t.name -match "concat\([^,]+,\s*'/(.+)'\)") { $tname = $Matches[1] }
            if (-not $tname -or -not $t.properties.schema.columns) { continue }
            $tableCols[$tname] = @{}
            foreach ($c in $t.properties.schema.columns) { $tableCols[$tname][$c.name] = $c.type }
        }

        # Index DCR dataFlows: stream -> outputStream
        $flows = @()
        foreach ($d in $script:Tpl.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' }) {
            foreach ($df in $d.properties.dataFlows) {
                $sn = ($df.streams[0] -replace '^Custom-', '')
                $out = $df.outputStream -replace '^Custom-', ''
                $flows += @{ Stream = $sn; OutputStream = $out }
            }
        }

        # Check: for each dataFlow, every column in the streamDecl must agree on type with the workspace table
        $mismatches = New-Object System.Collections.ArrayList
        foreach ($f in $flows) {
            if (-not $script:DcrStreamDecls.ContainsKey($f.Stream)) { continue }
            if (-not $tableCols.ContainsKey($f.OutputStream)) { continue }
            $sd = $script:DcrStreamDecls[$f.Stream]
            $tc = $tableCols[$f.OutputStream]
            foreach ($colKvp in $sd.GetEnumerator()) {
                if ($tc.ContainsKey($colKvp.Key) -and $tc[$colKvp.Key] -ne $colKvp.Value) {
                    [void]$mismatches.Add(("{0} -> {1}.{2}: streamDecl='{3}' tableCol='{4}'" -f $f.Stream, $f.OutputStream, $colKvp.Key, $colKvp.Value, $tc[$colKvp.Key]))
                }
            }
        }
        if ($mismatches.Count -gt 0) {
            $mismatches | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        }
        $mismatches.Count | Should -Be 0 -Because 'DCR transform output column type must match the workspace table column type, or Azure deployment fails with InvalidTransformOutput at provisioning time'
    }
}

Describe 'Schema Consistency — DCR-to-category coverage (bucket-fill detection)' {

    It '<dcrName> covers <maxCategories> or fewer categories' -ForEach @(
        # v0.1.0 GA: 13 per-category DCRs (one per consolidated table; categories
        # with >10 streams split into named semantic sub-domains). Each DCR
        # covers exactly 1 category (sub-domain split is within-category).
        @{ dcrName = 'any'; maxCategories = 1 }
    ) {
        $script:DcrToCategories = @{}
        $streamToCategory = @{}
        foreach ($e in $script:Manifest.Endpoints) {
            if ($e.Category) { $streamToCategory[$e.Stream] = $e.Category }
        }
        foreach ($d in $script:Tpl.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' }) {
            $dcrName = $d.name
            $cats = @{}
            foreach ($prop in $d.properties.streamDeclarations.PSObject.Properties) {
                $sn = $prop.Name -replace '^Custom-', ''
                $cat = if ($streamToCategory.ContainsKey($sn)) { $streamToCategory[$sn] } else { '<ops>' }
                $cats[$cat] = $true
            }
            $script:DcrToCategories[$dcrName] = $cats.Keys.Count
        }
        $worst = ($script:DcrToCategories.Values | Sort-Object -Descending)[0]
        $worst | Should -BeLessOrEqual $maxCategories
    }
}
