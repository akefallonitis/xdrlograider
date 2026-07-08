# Parser 8 production requirements (B1/B1b/B3 keystones)
# Per the canonical plan PART 7 §7.2 STEP 2.H · the 8 binding production requirements.
# This file covers parser-side keystones (Req #1, #2, #5, #6, #7).

#Requires -Module Pester

BeforeAll {
    $modulesRoot = Join-Path $PSScriptRoot '..\..\..\src\Modules' | Resolve-Path
    $env:PSModulePath = $modulesRoot.Path + [IO.Path]::PathSeparator + $env:PSModulePath
    Import-Module (Join-Path $modulesRoot.Path 'Xdr.Common.Parser\Xdr.Common.Parser.psd1') -Force -DisableNameChecking
}

Describe 'Req #1 · Fan-out · 1 event per row (B1)' {

    It 'wrapper response with 3 Results → 3 rows' {
        # Production data path: HTTP response → ConvertFrom-Json → PSCustomObject (matches real runtime)
        $body = @{ Results = @(@{ id = 1 }, @{ id = 2 }, @{ id = 3 }) } | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        $rows = ConvertTo-XdrRows -ResponseBody $body -OperationKey 'TestOp' -Category 'TestCat' -ResponseShape 'wrapper' -ProjectionMap @{ Id = '$.id' }
        @($rows).Count | Should -Be 3
    }

    It 'wrapper response with 1 Results item → 1 row (NOT collapsed)' {
        $body = @{ Results = @(@{ id = 1 }) } | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        $rows = ConvertTo-XdrRows -ResponseBody $body -OperationKey 'TestOp' -Category 'TestCat' -ResponseShape 'wrapper' -ProjectionMap @{ Id = '$.id' }
        @($rows).Count | Should -Be 1
    }

    It 'bareArray of 2 → 2 rows' {
        $body = @(@{ id = 'A' }, @{ id = 'B' }) | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        $rows = ConvertTo-XdrRows -ResponseBody $body -OperationKey 'TestOp' -Category 'TestCat' -ResponseShape 'bareArray' -ProjectionMap @{ Id = '$.id' }
        @($rows).Count | Should -Be 2
    }
}

Describe 'Req #2 · Empty-gate · NO empty rows (B1b)' {

    It 'empty array response → 0 rows (NOT 1 empty row)' {
        $body = @{ Results = @() } | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        $rows = ConvertTo-XdrRows -ResponseBody $body -OperationKey 'TestOp' -Category 'TestCat' -ResponseShape 'wrapper' -ProjectionMap @{ Id = '$.id' }
        @($rows).Count | Should -Be 0
    }

    It 'null response → 0 rows' {
        $rows = ConvertTo-XdrRows -ResponseBody $null -OperationKey 'TestOp' -Category 'TestCat' -ResponseShape 'wrapper' -ProjectionMap @{ Id = '$.id' }
        @($rows).Count | Should -Be 0
    }

    It 'Test-XdrEmptyElement detects null' {
        Test-XdrEmptyElement -Item $null | Should -BeTrue
    }

    It 'Test-XdrEmptyElement detects empty hashtable' {
        Test-XdrEmptyElement -Item @{} | Should -BeTrue
    }

    It 'Test-XdrEmptyElement does NOT flag real event' {
        $real = @{ id = 'evt-123'; name = 'real event' } | ConvertTo-Json | ConvertFrom-Json
        Test-XdrEmptyElement -Item $real | Should -BeFalse
    }
}

Describe 'Req #6 · ProjectionMap · 1:1 mapped per RAW' {

    It 'JSONPath simple · "$.a" projects scalar value' {
        $raw = @{ a = 1; b = 'two' } | ConvertTo-Json | ConvertFrom-Json
        $row = Apply-XdrProjectionMap -Item $raw -ProjectionMap @{ A = '$.a'; B = '$.b' }
        $row.A | Should -Be 1
        $row.B | Should -Be 'two'
    }

    It 'JSONPath nested · "$.user.id"' {
        $raw = @{ user = @{ id = 'u-42'; name = 'alice' } } | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        $row = Apply-XdrProjectionMap -Item $raw -ProjectionMap @{ UserId = '$.user.id'; UserName = '$.user.name' }
        $row.UserId | Should -Be 'u-42'
        $row.UserName | Should -Be 'alice'
    }

    It 'missing path does NOT throw' {
        $raw = @{ a = 1 } | ConvertTo-Json | ConvertFrom-Json
        { Apply-XdrProjectionMap -Item $raw -ProjectionMap @{ A = '$.a'; C = '$.nonexistent.deep.path' } } | Should -Not -Throw
    }
}

Describe 'Req #7 · RawJson always preserved (B3 1MB clamp)' {

    It 'small object · RawJson is the full serialization' {
        $raw = @{ id = 1; tag = 'small' }
        $cmp = Compress-XdrRawJson -Item $raw
        $cmp | Should -Match '"id"'
        $cmp | Should -Match '"tag"'
        $cmp | Should -Match '"small"'
    }

    It 'large object > 1MB clamps to truncation marker · NEVER drops RawJson' {
        $bigStr = 'x' * 2000000
        $raw = @{ id = 1; bigField = $bigStr }
        $cmp = Compress-XdrRawJson -Item $raw
        $cmp | Should -Not -BeNullOrEmpty
        $cmp.Length | Should -BeGreaterThan 0
        $cmp.Length | Should -BeLessOrEqual 1100000
        # Verify truncation marker present
        $cmp | Should -Match '__xdrlr_truncated'
    }

    It 'tiny MaxBytes forces truncation marker' {
        $raw = @{ id = 1; data = ('abcdef' * 100) }
        $cmp = Compress-XdrRawJson -Item $raw -MaxBytes 50
        $cmp | Should -Match '__xdrlr_truncated'
        $cmp | Should -Match '__xdrlr_original_bytes'
    }
}

Describe 'Req #5 · Pagination boundary respect' {

    It 'ConvertTo-XdrRows of N items returns exactly N rows' {
        $items = 0..9 | ForEach-Object { @{ id = $_ } }
        $body = @{ Results = $items } | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        $rows = ConvertTo-XdrRows -ResponseBody $body -OperationKey 'TestOp' -Category 'TestCat' -ResponseShape 'wrapper' -ProjectionMap @{ Id = '$.id' }
        @($rows).Count | Should -Be 10
    }
}
