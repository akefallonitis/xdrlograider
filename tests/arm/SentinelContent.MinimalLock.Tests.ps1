#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Phase 1 ship-lock: data-connector card ONLY in sentinelContent.json.
# NO analytic rules, NO workbooks, NO hunting queries, NO parsers.

Describe 'sentinelContent.json Phase 1 minimal-lock invariants' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $script:Path = Join-Path $script:RepoRoot 'deploy' 'sentinelContent.json'
        $script:Content = Get-Content -Raw $script:Path | ConvertFrom-Json -Depth 30
    }

    It 'parses cleanly + has ARM template structure' {
        $script:Content.'$schema' | Should -Match 'deploymentTemplate.json'
        $script:Content.parameters.workspaceName | Should -Not -BeNullOrEmpty
        $script:Content.resources.Count | Should -BeGreaterThan 0
    }

    It 'size <= 30 KB (Phase 1 budget)' {
        (Get-Item $script:Path).Length | Should -BeLessThan 30720
    }

    It 'has exactly 1 contentPackage resource' {
        $cp = @($script:Content.resources | Where-Object { $_.type -match 'contentPackages' })
        $cp.Count | Should -Be 1
        $cp[0].properties.contentId | Should -Be 'community.xdrlograider'
        $cp[0].properties.version   | Should -Be '0.1.0'
    }

    It 'has exactly 1 dataConnector resource' {
        $dc = @($script:Content.resources | Where-Object { $_.type -match 'dataConnectors' })
        $dc.Count | Should -Be 1
        $dc[0].kind | Should -Be 'GenericUI'
        $dc[0].properties.connectorUiConfig.title | Should -Be 'XdrLogRaider'
    }

    It 'has NO analytic rules' {
        @($script:Content.resources | Where-Object { $_.type -match 'alertRules' }).Count | Should -Be 0
    }

    It 'has NO workbooks' {
        @($script:Content.resources | Where-Object { $_.type -match 'workbooks' }).Count | Should -Be 0
    }

    It 'has NO hunting queries' {
        @($script:Content.resources | Where-Object { $_.type -match 'huntingQueries' -or $_.type -match 'savedSearches' }).Count | Should -Be 0
    }

    It 'has NO parsers (savedSearches with category Functions/Parsers)' {
        # Parsers ship as savedSearches in Sentinel solutions
        $parsers = @($script:Content.resources | Where-Object {
            $_.type -match 'savedSearches' -and (
                ($_.properties.PSObject.Properties['category'] -and $_.properties.category -match 'Parsers') -or
                ($_.properties.PSObject.Properties['functionAlias'])
            )
        })
        $parsers.Count | Should -Be 0
    }

    It 'data connector advertises 19 dataTypes (18 Defender_<Sub>_CL + 1 XdrConnectorHealth_CL)' {
        $dc = $script:Content.resources | Where-Object { $_.type -match 'dataConnectors' }
        $names = @($dc.properties.connectorUiConfig.dataTypes | ForEach-Object { $_.name })
        $names.Count | Should -Be 19
        $names | Should -Contain 'XdrConnectorHealth_CL'
        # All 18 sub-areas should be present in Defender_<Pascal>_CL form
        foreach ($pascal in @('ActionCenter','AttackSimulator','CloudApps','Configuration','DataLake','EndpointConfiguration','EndpointDevices','EntityPivots','ExposureManagement','Files','Identity','MultiTenant','PortalServices','SecureScore','SentinelPrecision','Streaming','ThreatAnalytics','VulnerabilityManagement')) {
            $names | Should -Contain "Defender_${pascal}_CL"
        }
    }

    It 'connectivityCriteria uses freshness-signal KQL (Decision 12: NOT CardState-dependent)' {
        $dc = $script:Content.resources | Where-Object { $_.type -match 'dataConnectors' }
        $criteria = $dc.properties.connectorUiConfig.connectivityCriteria
        $criteria.Count | Should -BeGreaterThan 0
        $kql = ($criteria[0].value -join ' ')
        # Freshness-signal pattern: existence of recent row = Connected.
        $kql | Should -Match 'XdrConnectorHealth_CL' -Because 'card freshness query must target the heartbeat table'
        $kql | Should -Match 'ago\(15m\)' -Because '15-min freshness window = 3x heartbeat cadence safety margin'
        # CardState lives in Notes JSON (operator diagnostics), NOT a typed column.
        # Filtering on it would always evaluate false → card permanently Disconnected.
        $kql | Should -Not -Match 'CardState\s*==' -Because 'CardState is a Notes JSON field, not a typed col — would never match'
    }

    It 'sampleQueries are syntactically structured (non-empty + has description + has query)' {
        $dc = $script:Content.resources | Where-Object { $_.type -match 'dataConnectors' }
        $samples = $dc.properties.connectorUiConfig.sampleQueries
        $samples.Count | Should -BeGreaterOrEqual 5
        foreach ($s in $samples) {
            $s.description | Should -Not -BeNullOrEmpty
            $s.query       | Should -Not -BeNullOrEmpty
        }
    }

    It 'has NO Claude/AI/V2 references' {
        $raw = Get-Content -Raw $script:Path
        $raw | Should -Not -Match 'Claude'
        $raw | Should -Not -Match 'anthropic'
        $raw | Should -Not -Match 'ClientV2'
        $raw | Should -Not -Match 'AuthV2'
    }
}

Describe 'deploy/solution/manifest.json invariants' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $script:Manifest = Get-Content -Raw (Join-Path $script:RepoRoot 'deploy' 'solution' 'manifest.json') | ConvertFrom-Json -Depth 10
    }

    It 'has Name + Version + DataConnectors entry' {
        $script:Manifest.Name    | Should -Be 'XdrLogRaider'
        $script:Manifest.Version | Should -Be '0.1.0'
        $script:Manifest.DataConnectors | Should -Not -BeNullOrEmpty
    }

    It 'Phase 1 ship-lock: NO Workbooks/AnalyticalRules/HuntingQueries/Parsers entries' {
        $hasWorkbooks    = $script:Manifest.PSObject.Properties['Workbooks']
        $hasAnalytic     = $script:Manifest.PSObject.Properties['AnalyticalRules']
        $hasHunting      = $script:Manifest.PSObject.Properties['HuntingQueries']
        $hasParsers      = $script:Manifest.PSObject.Properties['Parsers']
        # Allowed values: missing key entirely, OR empty array (NO populated list)
        if ($hasWorkbooks)    { @($script:Manifest.Workbooks).Count       | Should -Be 0 -Because 'Phase 1 lock — no workbooks ship' }
        if ($hasAnalytic)     { @($script:Manifest.AnalyticalRules).Count | Should -Be 0 -Because 'Phase 1 lock — no analytic rules ship' }
        if ($hasHunting)      { @($script:Manifest.HuntingQueries).Count  | Should -Be 0 -Because 'Phase 1 lock — no hunting queries ship' }
        if ($hasParsers)      { @($script:Manifest.Parsers).Count         | Should -Be 0 -Because 'Phase 1 lock — no parsers ship' }
    }
}
