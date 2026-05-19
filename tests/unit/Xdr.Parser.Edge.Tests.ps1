#Requires -Module Pester
# Edge-case coverage for Xdr.Parser DSL operators · null/empty/typed input handling.
# Complements E2E.Replay.Defender.Tests.ps1 (live-fixture-driven) with controlled inputs.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Parser/Xdr.Parser.psd1') -Force
}

Describe 'Apply-XdrProjectionMap edge cases' -Tag 'parser-edge' {

    It 'returns empty hashtable for empty projection map' {
        $r = Apply-XdrProjectionMap -Response @{ A = 1 } -ProjectionMap @{}
        $r | Should -BeOfType [hashtable]
        $r.Keys.Count | Should -Be 0
    }

    It 'tolerates null response with empty projection' {
        $r = Apply-XdrProjectionMap -Response $null -ProjectionMap @{}
        $r.Keys.Count | Should -Be 0
    }

    It 'returns plain literal when projection value has no DSL prefix' {
        $r = Apply-XdrProjectionMap -Response @{} -ProjectionMap @{ Literal = 'plain-string-not-dsl' }
        $r['Literal'] | Should -Be 'plain-string-not-dsl'
    }

    It '$tostring casts integer to string' {
        $r = Apply-XdrProjectionMap -Response @{ N = 42 } -ProjectionMap @{ Col = '$tostring:$.N' }
        $r['Col'] | Should -Be '42'
    }

    It '$tolong casts string to long' {
        $r = Apply-XdrProjectionMap -Response @{ N = '42' } -ProjectionMap @{ Col = '$tolong:$.N' }
        $r['Col'] | Should -Be 42
    }

    It '$tobool casts truthy string to bool true' {
        $r = Apply-XdrProjectionMap -Response @{ B = 'true' } -ProjectionMap @{ Col = '$tobool:$.B' }
        $r['Col'] | Should -BeTrue
    }

    It '$todatetime parses ISO 8601 to ISO string' {
        $r = Apply-XdrProjectionMap -Response @{ T = '2026-05-17T12:00:00Z' } -ProjectionMap @{ Col = '$todatetime:$.T' }
        $r['Col'] | Should -Not -BeNullOrEmpty
        $r['Col'] | Should -Match '^\d{4}'
    }

    It '$tojson serializes nested object compactly' {
        $r = Apply-XdrProjectionMap -Response @{ Nested = @{ A = 1; B = 2 } } -ProjectionMap @{ Col = '$tojson:$.Nested' }
        $r['Col'] | Should -BeOfType [string]
        $r['Col'] | Should -Match '"A"'
    }

    It 'array-suffix [] iterates inner field across array' {
        $resp = @{ Items = @( @{ Id = 1 }, @{ Id = 2 }, @{ Id = 3 } ) }
        $r = Apply-XdrProjectionMap -Response $resp -ProjectionMap @{ Ids = '$tolong:$.Items[].Id' }
        @($r['Ids']).Count | Should -Be 3
        @($r['Ids']) | Should -Contain 1
        @($r['Ids']) | Should -Contain 3
    }

    It 'returns $null for missing path (graceful · no throw)' {
        { Apply-XdrProjectionMap -Response @{ A = 1 } -ProjectionMap @{ Col = '$tostring:$.NotThere' } } | Should -Not -Throw
        $r = Apply-XdrProjectionMap -Response @{ A = 1 } -ProjectionMap @{ Col = '$tostring:$.NotThere' }
        $r['Col'] | Should -BeNullOrEmpty
    }

    It 'accepts BOTH JSONPath-rooted ($.OrgId) and bare (OrgId) syntaxes' {
        $rooted = Apply-XdrProjectionMap -Response @{ OrgId = 'X' } -ProjectionMap @{ Col = '$tostring:$.OrgId' }
        $bare   = Apply-XdrProjectionMap -Response @{ OrgId = 'X' } -ProjectionMap @{ Col = '$tostring:OrgId' }
        $rooted['Col'] | Should -Be $bare['Col']
        $rooted['Col'] | Should -Be 'X'
    }

    It 'unknown DSL op falls back to tostring' {
        $r = Apply-XdrProjectionMap -Response @{ V = 99 } -ProjectionMap @{ Col = '$nonsense:$.V' }
        $r['Col'] | Should -Be '99'
    }

    It '$tolong on non-numeric returns $null (no crash)' {
        $r = Apply-XdrProjectionMap -Response @{ V = 'not-a-number' } -ProjectionMap @{ Col = '$tolong:$.V' }
        $r['Col'] | Should -BeNullOrEmpty
    }

    It '$todatetime on garbage returns $null (no crash)' {
        $r = Apply-XdrProjectionMap -Response @{ T = 'not-a-date' } -ProjectionMap @{ Col = '$todatetime:$.T' }
        $r['Col'] | Should -BeNullOrEmpty
    }

    It 'handles deeply nested path (Outer.Inner.Leaf)' {
        $resp = @{ Outer = @{ Inner = @{ Leaf = 'deep' } } }
        $r = Apply-XdrProjectionMap -Response $resp -ProjectionMap @{ Col = '$tostring:$.Outer.Inner.Leaf' }
        $r['Col'] | Should -Be 'deep'
    }

    It 'handles PSCustomObject input (not just hashtable)' {
        $resp = [pscustomobject]@{ OrgId = 'pso-123'; IsActive = $true }
        $r = Apply-XdrProjectionMap -Response $resp -ProjectionMap @{
            Col1 = '$tostring:$.OrgId'
            Col2 = '$tobool:$.IsActive'
        }
        $r['Col1'] | Should -Be 'pso-123'
        $r['Col2'] | Should -BeTrue
    }
}
