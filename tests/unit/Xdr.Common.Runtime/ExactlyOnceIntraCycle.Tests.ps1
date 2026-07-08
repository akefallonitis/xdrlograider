#Requires -Version 7.4
# EO2 RED pin (audit 2026-06-12) · Select-XdrExactlyOnceRows must dedup WITHIN the fetched set by NaturalKey.
# GetHistory is Descending + pageIndexIncrement: an arrival between the page-N and page-N+1 HTTP calls re-serves
# page N's last row at page N+1's top → without intra-cycle dedup it lands TWICE in one DCE batch (count!=dcount
# on a busy tenant, no crash needed). Keep the FIRST occurrence; rows with an INCOMPLETE key ('') are never
# collapsed (EO5 — distinct null-key rows must survive).

BeforeAll {
    $repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $env:PSModulePath = (Join-Path $repo 'src\Modules') + [IO.Path]::PathSeparator + $env:PSModulePath
    Import-Module Xdr.Common.Runtime -Force -DisableNameChecking
}

Describe 'EO2 · intra-cycle NaturalKey dedup (page-shift / duplicate-page re-serve)' {
    It 'cold start (no high-water): a NaturalKey appearing twice in the fetch is kept ONCE (first wins)' {
        $rows = @(
            @{ ActionId = 'A1'; EventTime = '2026-06-11T05:00:00Z' },
            @{ ActionId = 'A2'; EventTime = '2026-06-11T04:59:00Z' },
            @{ ActionId = 'A1'; EventTime = '2026-06-11T05:00:00Z' }   # page-shift re-serve of A1
        )
        $out = Select-XdrExactlyOnceRows -Rows $rows -HighWaterUtc $null -CursorField 'EventTime' `
            -NaturalKey @('ActionId') -PriorKeys ([System.Collections.Generic.HashSet[string]]::new())
        @($out).Count | Should -Be 2
        @($out | ForEach-Object { $_.ActionId }) | Should -Be @('A1', 'A2')
    }
    It 'cursor branch (>high-water): two rows above the hw with the same key kept ONCE' {
        $hw = [datetime]::Parse('2026-06-11T04:00:00Z').ToUniversalTime()
        $rows = @(
            @{ ActionId = 'B1'; EventTime = '2026-06-11T05:00:00Z' },
            @{ ActionId = 'B1'; EventTime = '2026-06-11T05:00:00Z' }
        )
        $out = Select-XdrExactlyOnceRows -Rows $rows -HighWaterUtc $hw -CursorField 'EventTime' `
            -NaturalKey @('ActionId') -PriorKeys ([System.Collections.Generic.HashSet[string]]::new())
        @($out).Count | Should -Be 1
    }
    It 'rows with an INCOMPLETE NaturalKey are NEVER collapsed (EO5 — distinct null-key rows survive)' {
        $rows = @(
            @{ ActionId = $null; EventTime = '2026-06-11T05:00:00Z' },
            @{ ActionId = $null; EventTime = '2026-06-11T05:00:01Z' }
        )
        $out = Select-XdrExactlyOnceRows -Rows $rows -HighWaterUtc $null -CursorField 'EventTime' `
            -NaturalKey @('ActionId') -PriorKeys ([System.Collections.Generic.HashSet[string]]::new())
        @($out).Count | Should -Be 2
    }
    It 'no NaturalKey → keep all (SNAPSHOT-style; intra-response identical rows are legitimate)' {
        $rows = @(@{ X = '1' }, @{ X = '1' })
        $out = Select-XdrExactlyOnceRows -Rows $rows -HighWaterUtc $null -CursorField $null -NaturalKey @() -PriorKeys $null
        @($out).Count | Should -Be 2
    }
    It 'SNAPSHOT (no CursorField) WITH a NaturalKey does NOT intra-dedup — full re-emit is preserved (the boundary)' {
        $rows = @(@{ Id = 'S1' }, @{ Id = 'S1' })
        $out = Select-XdrExactlyOnceRows -Rows $rows -HighWaterUtc $null -CursorField $null `
            -NaturalKey @('Id') -PriorKeys ([System.Collections.Generic.HashSet[string]]::new())
        @($out).Count | Should -Be 2
    }
}
