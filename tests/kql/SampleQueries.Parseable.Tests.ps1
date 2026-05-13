#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# KQL sample-query + transformKql syntactic checks.
# We don't run real KQL parsers (no offline Kusto client) — we do structural
# sanity checks (balanced brackets, no obvious typos, valid pipeline form).

Describe 'sentinelContent.json sampleQueries KQL sanity' {
    BeforeAll {
        function Test-KqlBracketsBalanced {
            param([string] $Query)
            $depth = 0; $bracketDepth = 0
            foreach ($ch in $Query.ToCharArray()) {
                switch ($ch) {
                    '(' { $depth++ }
                    ')' { $depth-- }
                    '[' { $bracketDepth++ }
                    ']' { $bracketDepth-- }
                }
                if ($depth -lt 0 -or $bracketDepth -lt 0) { return $false }
            }
            return ($depth -eq 0 -and $bracketDepth -eq 0)
        }
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $script:Content = Get-Content -Raw (Join-Path $script:RepoRoot 'deploy' 'sentinelContent.json') | ConvertFrom-Json -Depth 30
        $script:Samples = @(
            ($script:Content.resources |
                Where-Object { $_.type -match 'dataConnectors' })[0].properties.connectorUiConfig.sampleQueries
        )
    }

    It 'has sample queries' {
        $script:Samples.Count | Should -BeGreaterOrEqual 5
    }

    It 'every sample query has balanced ()/[]' {
        foreach ($s in $script:Samples) {
            (Test-KqlBracketsBalanced -Query $s.query) | Should -BeTrue -Because "query: $($s.description)"
        }
    }

    It 'every sample query references a Defender_*_CL or XdrConnectorHealth_CL table' {
        foreach ($s in $script:Samples) {
            ($s.query -match 'Defender_\w+_CL|XdrConnectorHealth_CL|Defender_\*_CL') | Should -BeTrue -Because "query: $($s.description)"
        }
    }

    It 'every sample query starts with a table name or union' {
        foreach ($s in $script:Samples) {
            $first = ($s.query -split '\s*\|\s*')[0].Trim()
            ($first -match '^(union|Defender_\w*|XdrConnectorHealth_CL|[A-Z]\w*_CL)') | Should -BeTrue -Because "query: $($s.description) — first segment: $first"
        }
    }

    It 'no sample query has trailing pipe or empty segment' {
        foreach ($s in $script:Samples) {
            $s.query.TrimEnd() | Should -Not -Match '\|\s*$' -Because "query: $($s.description)"
        }
    }
}

Describe 'DCR transformKql expressions parseable' {
    BeforeAll {
        function Test-KqlBracketsBalanced {
            param([string] $Query)
            $depth = 0; $bracketDepth = 0
            foreach ($ch in $Query.ToCharArray()) {
                switch ($ch) {
                    '(' { $depth++ }
                    ')' { $depth-- }
                    '[' { $bracketDepth++ }
                    ']' { $bracketDepth-- }
                }
                if ($depth -lt 0 -or $bracketDepth -lt 0) { return $false }
            }
            return ($depth -eq 0 -and $bracketDepth -eq 0)
        }
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $script:Dcrs = @()
        foreach ($f in Get-ChildItem (Join-Path $script:RepoRoot 'deploy' 'dcrs') -Filter '*_dcr.json') {
            $script:Dcrs += Get-Content -Raw $f.FullName | ConvertFrom-Json -Depth 30
        }
    }

    It 'every DCR dataFlow has a transformKql expression' {
        foreach ($d in $script:Dcrs) {
            foreach ($flow in $d.properties.dataFlows) {
                $flow.transformKql | Should -Not -BeNullOrEmpty
            }
        }
    }

    It 'every transformKql starts with source |' {
        foreach ($d in $script:Dcrs) {
            foreach ($flow in $d.properties.dataFlows) {
                $flow.transformKql | Should -Match '^source\s*\|'
            }
        }
    }

    It 'every transformKql has balanced ()' {
        foreach ($d in $script:Dcrs) {
            foreach ($flow in $d.properties.dataFlows) {
                (Test-KqlBracketsBalanced -Query $flow.transformKql) | Should -BeTrue -Because $d.name
            }
        }
    }
}
