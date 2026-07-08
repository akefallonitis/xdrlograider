#Requires -Version 7.4
# FH-5 (audit 2026-06-15) · the SINGLE Sentinel connector card's content is GENERATED from the shipped-category set
# (ONE card in the Data Connectors gallery, N category tables). New-XdrConnectorCardContent (in Build-MainTemplate.ps1)
# is the generator; the WS4.2 rebind overwrites the card's dataTypes/graphQueries/sampleQueries/connectivityCriteria.
# Pre-FH-5 those arrays were HARDCODED to the pilot table -> a 2nd category was invisible in the gallery (no Connected
# badge, not in the data-types list). Two layers of coverage:
#   1. the generator scales generically (N categories -> N dataTypes/graph rows, ONE union'd connectivity badge,
#      envelope-only sample queries) — exercised with a synthetic TWO-category plan the single-category pilot cannot.
#   2. the COMMITTED deploy/mainTemplate.json card covers EXACTLY the shipped per-category-schema set (artifact parity).

BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $scriptPath  = Join-Path $script:repo 'dev-tools\Build-MainTemplate.ps1'

    # Extract ONLY the generator function via AST — the script's main body needs foundation.json and would execute on
    # a naive dot-source. The function is pure (no module deps) so the isolated scriptblock runs standalone.
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
    $fn  = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-XdrConnectorCardContent' }, $true) | Select-Object -First 1
    if (-not $fn) { throw 'New-XdrConnectorCardContent not found in dev-tools/Build-MainTemplate.ps1' }
    . ([scriptblock]::Create($fn.Extent.Text))

    # Synthetic TWO-category plan — a SPACED-and-ampersanded category ('Alerts & Incidents') the single-category pilot
    # cannot exercise. (Table tokens are produced upstream; the generator just consumes .Category + .Table.)
    $script:rows2 = @(
        [pscustomobject]@{ Category = 'Defender/Operations';          Table = 'Defender_Operations_CL' }
        [pscustomobject]@{ Category = 'Defender/Alerts & Incidents';  Table = 'Defender_AlertsIncidents_CL' }
    )
    $script:card2  = New-XdrConnectorCardContent -PlanRows $script:rows2
    $script:card2b = New-XdrConnectorCardContent -PlanRows $script:rows2                       # determinism re-run
    $script:card1  = New-XdrConnectorCardContent -PlanRows @($script:rows2[0])                 # pilot (single category)
    $script:json2  = $script:card2  | ConvertTo-Json -Depth 8
    $script:json2b = $script:card2b | ConvertTo-Json -Depth 8

    # ── artifact (committed mainTemplate.json card vs shipped per-category-schema set) ──
    $mt = Get-Content (Join-Path $script:repo 'deploy\mainTemplate.json') -Raw | ConvertFrom-Json -Depth 60
    $nested = $mt.resources | Where-Object { $_.name -eq '[variables(''nestedDeploymentName'')]' } | Select-Object -First 1
    $card   = $nested.properties.template.resources | Where-Object { $_.type -eq 'Microsoft.OperationalInsights/workspaces/providers/dataConnectorDefinitions' } | Select-Object -First 1
    $script:cardTables    = @($card.properties.connectorUiConfig.dataTypes | ForEach-Object { $_.name })
    $script:cardConnQuery = $card.properties.connectorUiConfig.connectivityCriteria[0].value[0]
    $artifactDir = Join-Path $script:repo 'deploy\per-category-schemas'
    $script:shippedTables = @(Get-ChildItem $artifactDir -Filter '*.json' |
        Where-Object { $_.Name -notlike '*-nested-deployment.json' } |
        ForEach-Object { (Get-Content $_.FullName -Raw | ConvertFrom-Json).TableResource.properties.schema.name })

    # ── Package (Content Hub solution) card · FH-5b single-sourced by Build-MainTemplate from the SAME generator ──
    $pkgUi = (Get-Content (Join-Path $script:repo 'Package\dataConnectors\XdrLogRaiderDataConnectorDefinition.json') -Raw | ConvertFrom-Json -Depth 60).properties.connectorUiConfig
    $script:pkgTables    = @($pkgUi.dataTypes | ForEach-Object { $_.name })
    $script:pkgConnQuery = $pkgUi.connectivityCriteria[0].value[0]
    $script:pkgSampleQ   = @($pkgUi.sampleQueries | ForEach-Object { $_.query })
}

Describe 'FH-5 · New-XdrConnectorCardContent · one card, N category tables (genericity)' {
    It 'emits one dataTypes row per category (every shipped table represented)' {
        @($script:card2.dataTypes).Count | Should -Be 2
        $names = @($script:card2.dataTypes | ForEach-Object { $_.name })
        $names | Should -Contain 'Defender_Operations_CL'
        $names | Should -Contain 'Defender_AlertsIncidents_CL'
    }
    It 'each dataTypes row carries a table-scoped lastDataReceivedQuery' {
        foreach ($dt in $script:card2.dataTypes) {
            $dt.lastDataReceivedQuery | Should -Match ([regex]::Escape($dt.name))
            $dt.lastDataReceivedQuery | Should -Match 'max\(TimeGenerated\)'
        }
    }
    It 'emits one graphQueries series per category (baseQuery = that table)' {
        @($script:card2.graphQueries).Count | Should -Be 2
        @($script:card2.graphQueries | ForEach-Object { $_.baseQuery }) | Should -Contain 'Defender_AlertsIncidents_CL'
    }
    It 'has a SINGLE connectivity badge that unions ALL category tables (isfuzzy)' {
        @($script:card2.connectivityCriteria).Count | Should -Be 1
        $script:card2.connectivityCriteria[0].type | Should -Be 'IsConnectedQuery'
        $q = $script:card2.connectivityCriteria[0].value[0]
        $q | Should -Match 'union isfuzzy=true'
        $q | Should -Match 'Defender_Operations_CL'
        $q | Should -Match 'Defender_AlertsIncidents_CL'
    }
    It 'sample queries reference ONLY universal envelope columns (no category-specific columns)' {
        $allQueries = @($script:card2.sampleQueries | ForEach-Object { $_.query })
        $allQueries.Count | Should -Be 4   # 2 per category
        foreach ($q in $allQueries) {
            $q | Should -Not -Match 'ActionType|DecidedBy|ActionStatus|ActionSource'
            $q | Should -Match 'TimeGenerated'
        }
    }
    It 'is deterministic — same input yields byte-identical JSON' {
        $script:json2 | Should -BeExactly $script:json2b
    }
    It 'a single-category plan still produces a valid one-table union badge (pilot parity)' {
        @($script:card1.dataTypes).Count | Should -Be 1
        $script:card1.connectivityCriteria[0].value[0] | Should -Match 'union isfuzzy=true Defender_Operations_CL'
    }
}

Describe 'FH-5 · committed deploy/mainTemplate.json card covers EXACTLY the shipped category set (artifact parity)' {
    It 'every shipped category table appears in the card dataTypes (no category invisible)' {
        @($script:shippedTables).Count | Should -BeGreaterThan 0
        foreach ($t in $script:shippedTables) {
            $script:cardTables | Should -Contain $t -Because "category table $t must be visible in the one connector card"
        }
    }
    It 'the card dataTypes carries NO extra tables beyond the shipped set' {
        foreach ($t in $script:cardTables) {
            $script:shippedTables | Should -Contain $t -Because "card table $t has no backing shipped category artifact (drift)"
        }
    }
    It 'the connectivity badge unions every shipped category table' {
        $script:cardConnQuery | Should -Match 'union isfuzzy=true'
        foreach ($t in $script:shippedTables) {
            $script:cardConnQuery | Should -Match ([regex]::Escape($t))
        }
    }
}

Describe 'FH-5b · Content Hub solution card is single-sourced (covers shipped set · parity with the ARM card)' {
    It 'every shipped category table appears in the Package card dataTypes (not invisible in the PUBLISHED solution)' {
        @($script:pkgTables).Count | Should -BeGreaterThan 0
        foreach ($t in $script:shippedTables) {
            $script:pkgTables | Should -Contain $t -Because "category table $t must be visible in the published Content Hub solution card"
        }
    }
    It 'the Package card dataTypes EQUALS the mainTemplate card dataTypes (the two cards never drift apart)' {
        @($script:pkgTables | Sort-Object) | Should -Be @($script:cardTables | Sort-Object)
    }
    It 'the Package card connectivity badge unions every shipped table (isfuzzy)' {
        $script:pkgConnQuery | Should -Match 'union isfuzzy=true'
        foreach ($t in $script:shippedTables) {
            $script:pkgConnQuery | Should -Match ([regex]::Escape($t))
        }
    }
    It 'the Package card sample queries are generic (the hand-authored ActionCenter columns are gone)' {
        foreach ($q in $script:pkgSampleQ) {
            $q | Should -Not -Match 'ActionType|DecidedBy|ActionStatus|ActionSource'
        }
    }
}
