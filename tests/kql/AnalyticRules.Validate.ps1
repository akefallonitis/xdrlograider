#Requires -Modules Pester

BeforeAll {
    $script:RulesDir     = Join-Path $PSScriptRoot '..' '..' 'sentinel' 'analytic-rules'
    $script:HuntingDir   = Join-Path $PSScriptRoot '..' '..' 'sentinel' 'hunting-queries'
}

Describe 'Analytic rules — file presence' {
    It 'ships at least 15 analytic rule YAML files' {
        $files = Get-ChildItem -Path $script:RulesDir -Filter '*.yaml'
        $files.Count | Should -BeGreaterOrEqual 15
    }

    It 'includes core drift-detection rules' {
        foreach ($name in @(
            'AsrRuleDowngrade.yaml', 'LrUnsignedScriptsOn.yaml',
            'DataExportNewDestination.yaml', 'PuaDisabled.yaml',
            'TamperProtectionOff.yaml', 'TenantAllowListNewEntry.yaml'
        )) {
            Test-Path (Join-Path $script:RulesDir $name) | Should -BeTrue
        }
    }
}

Describe 'Analytic rules — YAML schema (Sentinel Solutions compatible)' {
    BeforeAll {
        $script:Rules = Get-ChildItem -Path $script:RulesDir -Filter '*.yaml' | ForEach-Object {
            @{ Name = $_.Name; Content = Get-Content $_.FullName -Raw }
        }
    }

    It 'each rule has required top-level keys' -ForEach $script:Rules {
        param($Name, $Content)
        foreach ($key in 'id:', 'name:', 'description:', 'severity:', 'query:', 'queryFrequency:', 'queryPeriod:', 'triggerOperator:', 'triggerThreshold:', 'tactics:', 'relevantTechniques:') {
            $Content | Should -Match "(?m)^$key"
        }
    }

    It 'each rule has a GUID id' -ForEach $script:Rules {
        param($Name, $Content)
        $Content | Should -Match '(?m)^id:\s+[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    }

    It 'each rule has a valid severity' -ForEach $script:Rules {
        param($Name, $Content)
        $Content | Should -Match '(?m)^severity:\s+(Informational|Low|Medium|High)'
    }

    It 'each rule declares XdrLogRaiderInternal connector' -ForEach $script:Rules {
        param($Name, $Content)
        $Content | Should -Match 'connectorId:\s+XdrLogRaiderInternal'
    }
}

Describe 'Hunting queries — file presence' {
    It 'ships at least 10 hunting query YAML files' {
        $files = Get-ChildItem -Path $script:HuntingDir -Filter '*.yaml'
        $files.Count | Should -BeGreaterOrEqual 10
    }
}

Describe 'Hunting queries — YAML schema' {
    BeforeAll {
        $script:Queries = Get-ChildItem -Path $script:HuntingDir -Filter '*.yaml' | ForEach-Object {
            @{ Name = $_.Name; Content = Get-Content $_.FullName -Raw }
        }
    }

    It 'each hunting query has required keys' -ForEach $script:Queries {
        param($Name, $Content)
        foreach ($key in 'id:', 'name:', 'description:', 'query:', 'tactics:', 'relevantTechniques:') {
            $Content | Should -Match "(?m)^$key"
        }
    }

    It 'each hunting query has a GUID id' -ForEach $script:Queries {
        param($Name, $Content)
        $Content | Should -Match '(?m)^id:\s+[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    }
}
