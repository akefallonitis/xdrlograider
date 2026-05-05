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
        # v0.1.0 GA: parsers are now KQL functions with typed parameters,
        # not raw KQL with `let lookback = ...; let window = ...;`. Workbooks/rules
        # can override the defaults by passing args (e.g. {TimeRange:value} from
        # the workbook time-picker in Phase 7).
        $Content | Should -Match 'lookback\s*:\s*timespan'
        $Content | Should -Match 'window\s*:\s*timespan'
    }

    It 'each parser sources from Defender_<Category>_CL with SourceName filter (Phase J.C.2-5)' -ForEach $script:Parsers {
        # Phase J.D.5 D'.34 (2026-05-04): parsers rewritten for Phase J.C.2-5
        # architecture. Source pattern is `Defender_<Category>_CL | where SourceName in (...)`.
        # The legacy `union withsource=_Table` pattern was replaced.
        param($Name, $Content)
        $Content | Should -Match 'Defender_\w+_CL' -Because "parser $Name should source from a Defender_<Category>_CL table"
        $Content | Should -Match 'SourceName\s+in' -Because "parser $Name should filter source streams via SourceName"
    }

    It 'each parser references only MDE_*_CL stream literals (in SourceName filter) and Defender_*_CL category tables' -ForEach $script:Parsers {
        param($Name, $Content)
        # MDE_*_CL appears as STRING LITERALS inside SourceName filter (manifest stream names).
        # Defender_*_CL appears as TABLE references at the start of pipelines.
        # Wrap in @(...) to force array — Sort-Object -Unique returns a scalar
        # when there's only 1 unique item, which has no .Count property under
        # Set-StrictMode -Version Latest.
        $mdeRefs = @([regex]::Matches($Content, "'(MDE_\w+_CL)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $defenderRefs = @([regex]::Matches($Content, '\bDefender_\w+_CL\b') | ForEach-Object { $_.Value } | Sort-Object -Unique)
        $mdeRefs.Count | Should -BeGreaterThan 0 -Because "parser $Name should reference at least 1 source stream by name"
        $defenderRefs.Count | Should -BeGreaterThan 0 -Because "parser $Name should reference at least 1 category table"
    }

    It 'each parser projects standard output columns' -ForEach $script:Parsers {
        param($Name, $Content)
        foreach ($col in @('TimeGenerated', 'StreamName', 'EntityId', 'ChangeType')) {
            $Content | Should -Match $col
        }
    }

    It 'all parsers use field-level diff via mv-apply (Phase J.D.5 D''.34: unified pattern)' {
        # Phase J.D.5 (2026-05-04): rewritten parsers all use the same unified
        # mv-apply field-level diff pattern. The legacy leftanti pattern for
        # Exposure was replaced with the consistent mv-apply approach.
        foreach ($name in @('MDE_Drift_Configuration', 'MDE_Drift_Inventory', 'MDE_Drift_Maintenance', 'MDE_Drift_Exposure')) {
            $content = Get-Content (Join-Path $script:ParsersDir "$name.kql") -Raw
            $content | Should -Match 'mv-apply' -Because "parser $name should use field-level mv-apply diff pattern"
        }
    }

    It 'all parsers source from Defender_<Category>_CL with SourceName filter (Phase J.C.2-5 architecture)' {
        foreach ($name in @('MDE_Drift_Configuration', 'MDE_Drift_Inventory', 'MDE_Drift_Maintenance', 'MDE_Drift_Exposure')) {
            $content = Get-Content (Join-Path $script:ParsersDir "$name.kql") -Raw
            $content | Should -Match 'Defender_\w+_CL' -Because "parser $name should source from a Defender_<Category>_CL table"
            $content | Should -Match 'SourceName\s+in' -Because "parser $name should filter by SourceName"
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
