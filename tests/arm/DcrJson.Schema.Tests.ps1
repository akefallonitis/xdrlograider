#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# DCR JSON invariants — locks Rule 8 mandatory cols + Rule 12 ConnectorHealth cols.

Describe 'DCR JSON schema invariants' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $script:DcrDir = Join-Path $script:RepoRoot 'deploy' 'dcrs'

        $script:Phase1MandatoryCols = @(
            'TimeGenerated','Endpoint','EntityId','SuccessKind','HttpStatus',
            'RawJson','RawResponseBody','SubArea','Tier','LicenseHint'
        )

        # ConnectorHealth schema (Decision 15 + H13): 11 typed cols + Notes (dynamic).
        # ConnectorVersion + ConnectorBuildId give operators at-a-glance "which build
        # is deployed" from latest heartbeat row. Notes carries lean aggregate JSON
        # (cardState, dlqDepth, openCircuits, fatalError) — NOT the bloated per-stream
        # state pilot used (that lives in XdrTierState Storage Table).
        $script:ConnectorHealthCols = @(
            'TimeGenerated','FunctionName','Tier','Portal',
            'StreamsAttempted','StreamsSucceeded','RowsIngested','LatencyMs',
            'ConnectorVersion','ConnectorBuildId','Notes'
        )
    }

    It 'has exactly 19 DCR JSON files (18 sub-area + 1 ConnectorHealth)' {
        $files = @(Get-ChildItem $script:DcrDir -Filter '*_dcr.json')
        $files.Count | Should -Be 19
    }

    It 'every DCR JSON parses cleanly' {
        $files = Get-ChildItem $script:DcrDir -Filter '*_dcr.json'
        foreach ($f in $files) {
            { Get-Content -Raw $f.FullName | ConvertFrom-Json -Depth 20 } | Should -Not -Throw -Because $f.Name
        }
    }

    It 'every per-sub-area DCR declares the 10 mandatory cols (Rule 8)' {
        $files = Get-ChildItem $script:DcrDir -Filter 'Defender_*_dcr.json'
        foreach ($f in $files) {
            $j = Get-Content -Raw $f.FullName | ConvertFrom-Json -Depth 20
            $streamName = ($j.properties.streamDeclarations | Get-Member -MemberType NoteProperty).Name | Select-Object -First 1
            $cols = @($j.properties.streamDeclarations.$streamName.columns | ForEach-Object { $_.name })
            foreach ($c in $script:Phase1MandatoryCols) {
                $cols | Should -Contain $c -Because "DCR $($f.Name) must declare column $c (Rule 8)"
            }
        }
    }

    It 'every DCR has dataFlows with transformKql' {
        $files = Get-ChildItem $script:DcrDir -Filter '*_dcr.json'
        foreach ($f in $files) {
            $j = Get-Content -Raw $f.FullName | ConvertFrom-Json -Depth 20
            $j.properties.dataFlows.Count | Should -BeGreaterThan 0
            $j.properties.dataFlows[0].transformKql | Should -Not -BeNullOrEmpty
        }
    }

    It 'XdrConnectorHealth_dcr.json declares 11 typed cols + Notes dynamic (Decision 15 / H13)' {
        $path = Join-Path $script:DcrDir 'XdrConnectorHealth_dcr.json'
        $j = Get-Content -Raw $path | ConvertFrom-Json -Depth 20
        $streamName = 'Custom-XdrConnectorHealth_CL'
        $cols = @($j.properties.streamDeclarations.$streamName.columns | ForEach-Object { $_.name })
        foreach ($c in $script:ConnectorHealthCols) {
            $cols | Should -Contain $c -Because "ConnectorHealth must declare $c (Decision 15)"
        }
        $cols.Count | Should -BeGreaterOrEqual 11 -Because '11 typed cols + Notes (10 base + ConnectorVersion + ConnectorBuildId per H13)'
        # Notes must be dynamic type for the lean aggregates JSON
        # (cardState/dlqDepth/openCircuits/fatalError per Decision 15).
        $notesCol = $j.properties.streamDeclarations.$streamName.columns | Where-Object { $_.name -eq 'Notes' }
        $notesCol.type | Should -Be 'dynamic'
        # ConnectorVersion + ConnectorBuildId must be string (operator-facing build pin)
        ($j.properties.streamDeclarations.$streamName.columns | Where-Object { $_.name -eq 'ConnectorVersion' }).type | Should -Be 'string'
        ($j.properties.streamDeclarations.$streamName.columns | Where-Object { $_.name -eq 'ConnectorBuildId' }).type | Should -Be 'string'
    }

    It 'every DCR depends on the DCE + customTables nested template' {
        $files = Get-ChildItem $script:DcrDir -Filter '*_dcr.json'
        foreach ($f in $files) {
            $j = Get-Content -Raw $f.FullName | ConvertFrom-Json -Depth 20
            $deps = @($j.dependsOn)
            ($deps | Where-Object { $_ -match 'dataCollectionEndpoints' }).Count | Should -BeGreaterThan 0
            ($deps | Where-Object { $_ -match 'customTables' }).Count | Should -BeGreaterThan 0
        }
    }
}
