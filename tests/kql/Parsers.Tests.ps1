#Requires -Modules Pester

BeforeDiscovery {
    # -ForEach in `It` is evaluated during discovery, so the parser set must be
    # materialised here (BeforeAll runs too late and leaves $script:Parsers null).
    $script:ParsersDir = Join-Path $PSScriptRoot '..' '..' 'sentinel' 'parsers'
    $script:Parsers = @(
        Get-ChildItem -Path $script:ParsersDir -Filter '*.kql' -ErrorAction SilentlyContinue | ForEach-Object {
            @{ Name = $_.BaseName; Content = (Get-Content $_.FullName -Raw) }
        }
    )
}

BeforeAll {
    $script:ParsersDir = Join-Path $PSScriptRoot '..' '..' 'sentinel' 'parsers'
}

Describe 'KQL parsers — file presence' {
    It 'ships exactly 4 parser .kql files (one per cadence tier with snapshot semantics; fast tier has no parser)' {
        $files = Get-ChildItem -Path $script:ParsersDir -Filter '*.kql'
        $files.Count | Should -Be 4
    }

    It 'includes all cadence-tier parsers' {
        $expected = @(
            'MDE_Drift_Exposure.kql',
            'MDE_Drift_Configuration.kql',
            'MDE_Drift_Inventory.kql',
            'MDE_Drift_Maintenance.kql'
        )
        foreach ($name in $expected) {
            Test-Path (Join-Path $script:ParsersDir $name) | Should -BeTrue
        }
    }
}

Describe 'KQL parsers — content validation' {
    It 'each parser has a SYNOPSIS comment' -ForEach $script:Parsers {
        param($Name, $Content)
        $Content | Should -Match '(?m)^//\s*SYNOPSIS'
    }

    It 'each parser declares lookback and window as function parameters' -ForEach $script:Parsers {
        param($Name, $Content)
        # iter-14.0 Phase 5: parsers are now KQL functions with typed parameters,
        # not raw KQL with `let lookback = ...; let window = ...;`. Workbooks/rules
        # can override the defaults by passing args (e.g. {TimeRange:value} from
        # the workbook time-picker in Phase 7).
        $Content | Should -Match 'lookback\s*:\s*timespan'
        $Content | Should -Match 'window\s*:\s*timespan'
    }

    It 'each parser uses union withsource=_Table' -ForEach $script:Parsers {
        param($Name, $Content)
        $Content | Should -Match 'union\s+withsource=_Table'
    }

    It 'each parser references only MDE_*_CL tables' -ForEach $script:Parsers {
        param($Name, $Content)
        $tableRefs = [regex]::Matches($Content, '\bMDE_\w+_CL\b') | ForEach-Object { $_.Value } | Sort-Object -Unique
        $tableRefs | ForEach-Object {
            $_ | Should -Match '^MDE_[\w]+_CL$'
        }
    }

    It 'each parser projects standard output columns' -ForEach $script:Parsers {
        param($Name, $Content)
        foreach ($col in @('TimeGenerated', 'StreamName', 'EntityId', 'ChangeType')) {
            $Content | Should -Match $col
        }
    }

    It 'Exposure parser uses set-diff pattern (leftanti) because XSPM streams are graph-structured' {
        $exposure = Get-Content (Join-Path $script:ParsersDir 'MDE_Drift_Exposure.kql') -Raw
        $exposure | Should -Match 'leftanti'
    }

    It 'Configuration / Inventory / Maintenance parsers use field-level diff (mv-apply)' {
        foreach ($name in @('MDE_Drift_Configuration', 'MDE_Drift_Inventory', 'MDE_Drift_Maintenance')) {
            $content = Get-Content (Join-Path $script:ParsersDir "$name.kql") -Raw
            $content | Should -Match 'mv-apply'
        }
    }
}

Describe 'KQL parsers — syntax smoke' {
    # Basic parens/braces balance check, no full KQL parse
    It 'each parser has balanced parentheses' {
        foreach ($file in Get-ChildItem -Path $script:ParsersDir -Filter '*.kql') {
            $content = Get-Content $file.FullName -Raw
            $open  = ([regex]::Matches($content, '\(')).Count
            $close = ([regex]::Matches($content, '\)')).Count
            $open | Should -Be $close -Because "parens in $($file.Name) must balance"
        }
    }
}
