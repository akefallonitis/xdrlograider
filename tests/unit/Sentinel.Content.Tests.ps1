#Requires -Module Pester
# V3 Sentinel content positive invariants: connectivityCriterias PLURAL,
# freshness KQL targets a table the DCR emits, sampleQuery references a
# deployed table, instructionSteps present, V3 apiVersion shape, permissions
# block declares operator-required surfaces. Positive contract checks only;
# no defensive blocks against legacy-naming or prior-fork bug classes.

BeforeAll {
    $script:RepoRoot   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:SentinelJs = Join-Path $script:RepoRoot 'deploy\sentinelContent.json'
    $script:Arm        = Get-Content (Join-Path $script:RepoRoot 'deploy\mainTemplate.json') -Raw | ConvertFrom-Json
    $script:Content    = Get-Content $script:SentinelJs -Raw | ConvertFrom-Json
    $script:UiCfg      = $script:Content.resources[0].properties.connectorUiConfig
}

Describe 'sentinelContent.json V3 schema' -Tag 'sentinel' {

    It 'has exactly one dataConnectorDefinitions resource (no V2 dataConnectors + contentPackages mixed in)' {
        $defs = @($script:Content.resources | Where-Object { $_.type -like '*/dataConnectorDefinitions' })
        $defs.Count | Should -Be 1
        $defs[0].kind | Should -Be 'Customizable'
    }

    It 'uses connectivityCriterias PLURAL (Microsoft frozen-misspelling for FA-backed cards)' {
        @($script:UiCfg.PSObject.Properties.Name) | Should -Contain 'connectivityCriterias'
        @($script:UiCfg.PSObject.Properties.Name) | Should -Not -Contain 'connectivityCriteria'
    }

    It 'card freshness KQL queries XdrConnectorHealth_CL with Portal == Defender within the last 15 min (post-0m rename)' {
        $kql = $script:UiCfg.connectivityCriterias[0].value[0]
        $kql | Should -Match 'XdrConnectorHealth_CL'
        $kql | Should -Match "Portal == 'Defender'"
        $kql | Should -Match 'ago\(15m\)'
        $kql | Should -Match 'take 1'
    }

    It 'every dataTypes entry references a table the DCR provisions (φ.B · per-sub-area DCRs + 1 health DCR)' {
        # φ.B · gather streams from BOTH the health DCR (literal outputStream) AND the copy-loop
        # per-sub-area DCR (outputStream is ARM expression resolving to Custom-Defender_<SubArea>_CL).
        # Build expected stream set from ARM defenderSubAreas variable + health stream literal.
        $dcrResources = @($script:Arm.resources | Where-Object type -eq 'Microsoft.Insights/dataCollectionRules')
        $expectedStreams = [System.Collections.Generic.List[string]]::new()
        foreach ($dcr in $dcrResources) {
            $streamDecl = $dcr.properties.streamDeclarations.PSObject.Properties.Name
            foreach ($s in $streamDecl) {
                if ($s -match "Custom-Defender_',\s*variables\('defenderSubAreas'\)") {
                    # ARM copy loop · build all 19 from defenderSubAreas array
                    foreach ($sub in @($script:Arm.variables.defenderSubAreas)) {
                        [void]$expectedStreams.Add("Defender_${sub}_CL")
                    }
                } else {
                    [void]$expectedStreams.Add(($s -replace '^Custom-',''))
                }
            }
        }
        $dcrTables = @($expectedStreams | Sort-Object -Unique)
        foreach ($dt in $script:UiCfg.dataTypes) {
            $dt.name | Should -BeIn $dcrTables -Because "dataTypes references '$($dt.name)' but no DCR provisions that table (ARM defenderSubAreas: $($dcrTables -join ', '))"
        }
    }

    It 'every dataTypes entry has a non-empty lastDataReceivedQuery (used by card freshness)' {
        foreach ($dt in $script:UiCfg.dataTypes) {
            $dt.lastDataReceivedQuery | Should -Not -BeNullOrEmpty
            $dt.lastDataReceivedQuery | Should -Match $dt.name
        }
    }

    It 'every sampleQuery references a table the DCR actually provisions (φ.F · union Defender_*_CL allowed)' {
        # φ.F · gather expected table set same as dataTypes test · plus accept `union ... Defender_*_CL`
        # wildcard pattern (covers all 19 per-sub-area tables at runtime).
        $dcrResources = @($script:Arm.resources | Where-Object type -eq 'Microsoft.Insights/dataCollectionRules')
        $expectedStreams = [System.Collections.Generic.List[string]]::new()
        foreach ($dcr in $dcrResources) {
            $streamDecl = $dcr.properties.streamDeclarations.PSObject.Properties.Name
            foreach ($s in $streamDecl) {
                if ($s -match "Custom-Defender_',\s*variables\('defenderSubAreas'\)") {
                    foreach ($sub in @($script:Arm.variables.defenderSubAreas)) {
                        [void]$expectedStreams.Add("Defender_${sub}_CL")
                    }
                } else {
                    [void]$expectedStreams.Add(($s -replace '^Custom-',''))
                }
            }
        }
        $dcrTables = @($expectedStreams | Sort-Object -Unique)
        foreach ($sq in $script:UiCfg.sampleQueries) {
            $usedTable = $false
            # Accept wildcard union pattern that targets all per-sub-area tables
            if ($sq.query -match 'Defender_\*_CL') { $usedTable = $true }
            else {
                foreach ($t in $dcrTables) {
                    if ($sq.query -match [regex]::Escape($t)) { $usedTable = $true; break }
                }
            }
            $usedTable | Should -BeTrue -Because "sampleQuery '$($sq.description)' must reference a deployed table or use Defender_*_CL wildcard union"
        }
    }

    It 'has graphQueriesTableName set to XdrConnectorHealth_CL (post-0m rename · matches connectivityCriteria query target)' {
        $script:UiCfg.graphQueriesTableName | Should -Be 'XdrConnectorHealth_CL'
    }

    It 'instructionSteps has at least 3 steps for a clean operator flow' {
        @($script:UiCfg.instructionSteps).Count | Should -BeGreaterOrEqual 3
    }

    It 'apiVersion of dataConnectorDefinitions is a recognised Sentinel V3 release' {
        $script:Content.resources[0].apiVersion | Should -Match '^2023-(04|05|06|07|08|09|10|11|12)-\d+-preview$'
    }

    It 'permissions block declares both resourceProvider and customs (operator pre-req surface)' {
        $script:UiCfg.permissions.resourceProvider | Should -Not -BeNullOrEmpty
        $script:UiCfg.permissions.customs          | Should -Not -BeNullOrEmpty
    }
}
