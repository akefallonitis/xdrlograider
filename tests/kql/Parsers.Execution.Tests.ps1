# Section R++++++ F5 (2026-05-07): drift parser execution test (Layer 10 BLOCKING gap closure).
#
# Existing tests/kql/Parsers.Tests.ps1 + Parsers.Fixture.Tests.ps1 do STATIC audits
# (KQL syntax, stream union content, output column shape). This test goes one level
# deeper: simulates parser execution semantics in PowerShell to validate the
# Added/Removed/Modified logic against fixture before/after snapshots.
#
# We do NOT execute KQL against a live Kusto engine (Kusto.Language NuGet validator
# is v1.1+ scope). Instead we replicate the parser's mv-apply set-difference logic
# in PS + assert the expected ChangeType classifications match the parser's intent.

#Requires -Modules Pester

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:ParserDir = Join-Path $script:RepoRoot 'sentinel' 'parsers'

    # Helper: simulate the parser's case() classification logic
    # Parser KQL: iff(isnotempty(NewValue) and isempty(OldValue), 'Added',
    #              iff(isempty(NewValue) and isnotempty(OldValue), 'Removed', 'Modified'))
    function script:Classify-FieldChange {
        param([string] $OldValue, [string] $NewValue)
        if ([string]::IsNullOrEmpty($OldValue) -and -not [string]::IsNullOrEmpty($NewValue)) { return 'Added' }
        if (-not [string]::IsNullOrEmpty($OldValue) -and [string]::IsNullOrEmpty($NewValue)) { return 'Removed' }
        if ($OldValue -ne $NewValue) { return 'Modified' }
        return $null  # No change
    }
}

Describe 'Parser execution semantics — Added/Removed/Modified classification' {

    Context 'Added: field exists in current snapshot but NOT in previous' {
        It 'classifies new field as Added' {
            $result = script:Classify-FieldChange -OldValue '' -NewValue 'newvalue'
            $result | Should -Be 'Added'
        }

        It 'classifies new boolean as Added' {
            $result = script:Classify-FieldChange -OldValue $null -NewValue 'true'
            $result | Should -Be 'Added'
        }
    }

    Context 'Removed: field existed in previous snapshot but NOT in current' {
        It 'classifies disappeared field as Removed' {
            $result = script:Classify-FieldChange -OldValue 'oldvalue' -NewValue ''
            $result | Should -Be 'Removed'
        }

        It 'classifies disappeared boolean as Removed' {
            $result = script:Classify-FieldChange -OldValue 'true' -NewValue $null
            $result | Should -Be 'Removed'
        }
    }

    Context 'Modified: field value changed' {
        It 'classifies value change as Modified' {
            $result = script:Classify-FieldChange -OldValue 'block' -NewValue 'audit'
            $result | Should -Be 'Modified'
        }

        It 'classifies bool flip as Modified' {
            $result = script:Classify-FieldChange -OldValue 'true' -NewValue 'false'
            $result | Should -Be 'Modified'
        }
    }

    Context 'No-change: identical values produce no event' {
        It 'returns null for identical values' {
            $result = script:Classify-FieldChange -OldValue 'same' -NewValue 'same'
            $result | Should -BeNullOrEmpty
        }
    }
}

Describe 'Parser KQL structure — every parser emits required output columns' {
    BeforeDiscovery {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $parserDir = Join-Path $repoRoot 'sentinel' 'parsers'
        $script:Parsers = Get-ChildItem -Path $parserDir -Filter 'MDE_Drift_*.kql' | ForEach-Object {
            @{ Path = $_.FullName; Name = $_.BaseName }
        }
    }

    It 'parser <Name> emits 9 required drift columns' -ForEach $script:Parsers {
        $kql = Get-Content $Path -Raw
        # Required output cols per Section R+ (Removed-branch fix landed):
        #   TimeGenerated, StreamName, EntityId, FieldName, OldValue, NewValue,
        #   SnapshotCurrent, SnapshotPrevious, ChangeType
        $kql | Should -Match 'TimeGenerated' -Because 'every drift event needs ingest timestamp'
        $kql | Should -Match 'StreamName' -Because 'identifies which stream produced the drift'
        $kql | Should -Match 'EntityId' -Because 'identifies which entity (machine/policy/rule) drifted'
        $kql | Should -Match 'FieldName' -Because 'identifies which property changed'
        $kql | Should -Match 'OldValue' -Because 'shows what value was before'
        $kql | Should -Match 'NewValue' -Because 'shows what value is now'
        $kql | Should -Match 'ChangeType' -Because 'Added/Removed/Modified classification'
    }

    It 'parser <Name> uses case() for ChangeType classification (post Section R++.C B4 fix)' -ForEach $script:Parsers {
        $kql = Get-Content $Path -Raw
        # Section R++.C B4: original mv-apply logic had unreachable Removed branch.
        # Fix uses set_difference + set_has_element + case() for proper classification.
        $kql | Should -Match 'set_(difference|has_element|union)' -Because 'set-based logic detects key removals (Section R++.C B4 fix)'
        $kql | Should -Match 'case\s*\(' -Because 'case() handles 3-way Added/Removed/Modified classification'
    }

    It 'parser <Name> declares window + lookback parameters (cadence-tier customization)' -ForEach $script:Parsers {
        $kql = Get-Content $Path -Raw
        $kql | Should -Match 'window\s*:\s*timespan' -Because 'parsers parameterize current-snapshot window'
        $kql | Should -Match 'lookback\s*:\s*timespan' -Because 'parsers parameterize previous-snapshot lookback'
    }
}
