# Section R++++++ P1.9 / Architecture H (2026-05-07): Live workspace table schema
# parity test (catches B2-class silent col drops).
#
# Section R++.B2 root cause: `Defender_ThreatAnalytics_CL` workspace table SILENTLY
# DROPPED every typed col from `MDE_ThreatAnalyticsTopThreats_CL` (TotalActiveThreats,
# ThreatsExposure, etc) because the consolidated-table column-derivation only kept
# the cols of the FIRST stream that wrote there. 230 rows landing every cycle, all
# typed cols silently lost.
#
# This test prevents regression by asserting: for every consolidated workspace table
# `Defender_<Category>_CL` declared in mainTemplate.json, every typed col declared in
# any DCR streamDecl that routes to that outputStream MUST also be declared in the
# workspace table's columns array.
#
# Without this gate, future stream additions can silently drop cols (the DCR
# transformKql succeeds but Log Analytics drops cols not in the workspace table).

#Requires -Modules Pester

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:ArmPath  = Join-Path $script:RepoRoot 'deploy' 'compiled' 'mainTemplate.json'
    $script:Arm      = Get-Content $script:ArmPath -Raw | ConvertFrom-Json -Depth 50

    # Extract workspace table cols (StrictMode-safe property guards)
    $script:WorkspaceTableCols = @{}
    foreach ($res in $script:Arm.resources) {
        if ($res.type -ne 'Microsoft.Resources/deployments') { continue }
        if (-not $res.PSObject.Properties['properties']) { continue }
        if (-not $res.properties.PSObject.Properties['template']) { continue }
        if (-not $res.properties.template.PSObject.Properties['resources']) { continue }
        foreach ($inner in $res.properties.template.resources) {
            if (-not $inner.PSObject.Properties['type']) { continue }
            if ($inner.type -notmatch 'workspaces/tables$') { continue }
            if (-not $inner.PSObject.Properties['properties']) { continue }
            if (-not $inner.properties.PSObject.Properties['schema']) { continue }
            $name = $inner.properties.schema.name
            if ($name -and $name -match '^Defender_\w+_CL$') {
                $script:WorkspaceTableCols[$name] = @($inner.properties.schema.columns.name)
            }
        }
    }

    # Extract DCR streamDecl cols + outputStream mapping
    $script:DcrStreamColsByOutput = @{}
    foreach ($res in $script:Arm.resources) {
        if ($res.type -eq 'Microsoft.Insights/dataCollectionRules') {
            $streamDecls = $res.properties.streamDeclarations
            $dataFlows = @($res.properties.dataFlows)
            foreach ($df in $dataFlows) {
                $outStream = [string]$df.outputStream  # e.g. Custom-Defender_EndpointConfiguration_CL
                $tableName = $outStream -replace '^Custom-', ''  # Defender_EndpointConfiguration_CL
                foreach ($inStream in $df.streams) {
                    $declName = [string]$inStream  # e.g. Custom-MDE_AdvancedFeatures_CL
                    if ($streamDecls.PSObject.Properties[$declName]) {
                        $cols = @($streamDecls.$declName.columns.name)
                        if (-not $script:DcrStreamColsByOutput.ContainsKey($tableName)) {
                            $script:DcrStreamColsByOutput[$tableName] = @{}
                        }
                        foreach ($c in $cols) {
                            $script:DcrStreamColsByOutput[$tableName][$c] = $declName
                        }
                    }
                }
            }
        }
    }
}

Describe 'WorkspaceTable.SchemaParity — every DCR-declared col exists in destination table' {
    It 'declared workspace tables exist (sanity check)' {
        @($script:WorkspaceTableCols.Keys).Count | Should -BeGreaterOrEqual 10 -Because 'expect 10 Defender_<Category>_CL tables (per nodoc D.1 taxonomy) + XdrConnectorHealth_CL'
    }

    It 'DCR streamDecls cover all 10 consolidated tables' {
        $covered = @($script:DcrStreamColsByOutput.Keys | Where-Object { $_ -match '^Defender_\w+_CL$' })
        @($covered).Count | Should -BeGreaterOrEqual 10
    }
}

Describe 'WorkspaceTable.SchemaParity — per-table col coverage' {
    BeforeDiscovery {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $arm = Get-Content (Join-Path $repoRoot 'deploy' 'compiled' 'mainTemplate.json') -Raw | ConvertFrom-Json -Depth 50

        $tableNames = @()
        foreach ($res in $arm.resources) {
            if ($res.type -ne 'Microsoft.Resources/deployments') { continue }
            if (-not $res.PSObject.Properties['properties']) { continue }
            if (-not $res.properties.PSObject.Properties['template']) { continue }
            if (-not $res.properties.template.PSObject.Properties['resources']) { continue }
            foreach ($inner in $res.properties.template.resources) {
                if (-not $inner.PSObject.Properties['type']) { continue }
                if ($inner.type -notmatch 'workspaces/tables$') { continue }
                if (-not $inner.PSObject.Properties['properties']) { continue }
                if (-not $inner.properties.PSObject.Properties['schema']) { continue }
                $name = $inner.properties.schema.name
                if ($name -match '^Defender_\w+_CL$') {
                    $tableNames += @{ Table = $name }
                }
            }
        }
        $script:Tables = $tableNames
    }

    It 'workspace table <Table> contains every col declared in DCR streamDecls that route here' -ForEach $script:Tables {
        $tableCols = @($script:WorkspaceTableCols[$Table])
        $declCols  = @($script:DcrStreamColsByOutput[$Table].Keys)

        if (-not $declCols -or $declCols.Count -eq 0) {
            Set-ItResult -Skipped -Because "no DCR streamDecls route to $Table (skip)"
            return
        }

        # Find DCR-declared cols that are NOT in workspace table → silent drops.
        $missing = @($declCols | Where-Object { $_ -notin $tableCols })
        $missing.Count | Should -Be 0 -Because @"
Workspace table '$Table' is MISSING cols declared in its DCR streamDecls.
This is the Section R++.B2 silent-col-drop class bug — DCR transformKql succeeds
but Log Analytics drops cols not in the workspace table schema.
Missing cols (with declaring streamDecl):
$( ($missing | ForEach-Object { $declStream = $script:DcrStreamColsByOutput[$Table][$_]; "  - $_ (from $declStream)" }) -join "`n" )

To fix: add these cols to the Defender_<Category>_CL workspace table cols
array in mainTemplate.json BEFORE the DCR streamDecl that declares them lands.
"@
    }
}
