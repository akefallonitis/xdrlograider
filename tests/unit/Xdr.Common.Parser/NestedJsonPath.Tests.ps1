#Requires -Module Pester

# U3 · NESTED / WILDCARD JSONPath in the ProjectionMap resolver (plan §16.2 U3 · §16.3 nested-JSONPath gate).
#
# Proves the parser's JSONPath resolver (Apply-XdrProjectionMap → script:Resolve-XdrJsonPath) now types ops
# whose useful data lives in a NESTED array:
#   - `$.a.b[*]`     → serialize the whole nested array into a typed (string) column.
#   - `$.a.b[*].c`   → fan a scalar list out of each element.
#   - arbitrary nesting depth + nested wildcards.
# And that FLAT-path behavior is BYTE-IDENTICAL (single index, deep dot-walk, misses) so the GetHistory replay
# stays green and the RawJson floor is never affected (a miss → column omitted, data still in RawJson).
#
# The resolver is script-scoped (not exported); it is exercised through the PUBLIC Apply-XdrProjectionMap, which
# is exactly how the runtime reaches it (per-Op typed columns). Bodies are built via ConvertFrom-Json (-AsHashtable
# for the runtime's IDictionary shape AND PSCustomObject) so BOTH node shapes are covered.

BeforeAll {
    $modulesRoot = Join-Path $PSScriptRoot '..\..\..\src\Modules' | Resolve-Path
    $env:PSModulePath = $modulesRoot.Path + [IO.Path]::PathSeparator + $env:PSModulePath
    Import-Module (Join-Path $modulesRoot.Path 'Xdr.Common.Parser\Xdr.Common.Parser.psd1') -Force -DisableNameChecking

    # A response whose useful data is in a nested array (the shape U3 unlocks): a.b is an array of objects,
    # each with scalar `c` and a deeper `d.e`. Plus a top-level array and a deep scalar for nesting checks.
    $script:NestedJson = @{
        a = @{
            b = @(
                @{ c = 'c1'; d = @{ e = 'e1' } }
                @{ c = 'c2'; d = @{ e = 'e2' } }
                @{ c = 'c3'; d = @{ e = 'e3' } }
            )
        }
        groups = @(
            @{ members = @(@{ id = 'm1' }, @{ id = 'm2' }) }
            @{ members = @(@{ id = 'm3' }) }
        )
        deep = @{ level1 = @{ level2 = @{ level3 = 'buried' } } }
        scalarList = @('x','y','z')
    }
}

Describe 'U3 · Wildcard `[*]` over a nested array' {

    It 'terminal wildcard `$.a.b[*]` serializes the WHOLE nested array into a string column' {
        $item = $script:NestedJson | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable -Depth 10
        $row = Apply-XdrProjectionMap -Item $item -ProjectionMap @{ Bees = '$.a.b[*]' }
        $row.ContainsKey('Bees') | Should -BeTrue
        $row.Bees | Should -BeOfType [string]                       # non-scalar → JSON-serialized
        $parsed = $row.Bees | ConvertFrom-Json
        @($parsed).Count | Should -Be 3
        $parsed[0].c | Should -Be 'c1'
        $parsed[2].d.e | Should -Be 'e3'
    }

    It 'mid-path wildcard `$.a.b[*].c` fans a scalar list out of each element' {
        $item = $script:NestedJson | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable -Depth 10
        $row = Apply-XdrProjectionMap -Item $item -ProjectionMap @{ Cees = '$.a.b[*].c' }
        $row.ContainsKey('Cees') | Should -BeTrue
        $vals = @($row.Cees | ConvertFrom-Json)                     # list → serialized array
        $vals | Should -Be @('c1','c2','c3')
    }

    It 'wildcard reaches a DEEPER field `$.a.b[*].d.e` across each element' {
        $item = $script:NestedJson | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable -Depth 10
        $row = Apply-XdrProjectionMap -Item $item -ProjectionMap @{ Ees = '$.a.b[*].d.e' }
        @($row.Ees | ConvertFrom-Json) | Should -Be @('e1','e2','e3')
    }

    It 'NESTED wildcards `$.groups[*].members[*].id` flatten one level per wildcard' {
        $item = $script:NestedJson | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable -Depth 10
        $row = Apply-XdrProjectionMap -Item $item -ProjectionMap @{ MemberIds = '$.groups[*].members[*].id' }
        @($row.MemberIds | ConvertFrom-Json) | Should -Be @('m1','m2','m3')
    }

    It 'works on a PSCustomObject body too (not only -AsHashtable)' {
        $item = $script:NestedJson | ConvertTo-Json -Depth 10 | ConvertFrom-Json     # PSCustomObject
        $row = Apply-XdrProjectionMap -Item $item -ProjectionMap @{ Cees = '$.a.b[*].c' }
        @($row.Cees | ConvertFrom-Json) | Should -Be @('c1','c2','c3')
    }

    It 'a single Results-style wrapper item with a nested detail array types via wildcard' {
        # Realistic: an op whose row carries a nested "RelatedEntities[*].EntityId" worth typing.
        $detail = @{ ActionId = 'a-1'; RelatedEntities = @(@{ EntityId = 'e-1' }, @{ EntityId = 'e-2' }) } |
            ConvertTo-Json -Depth 6 | ConvertFrom-Json -AsHashtable -Depth 6
        $row = Apply-XdrProjectionMap -Item $detail -ProjectionMap @{ ActionId = '$.ActionId'; EntityIds = '$.RelatedEntities[*].EntityId' }
        $row.ActionId  | Should -Be 'a-1'
        @($row.EntityIds | ConvertFrom-Json) | Should -Be @('e-1','e-2')
    }
}

Describe 'U3 · Deeper nesting (no wildcard)' {

    It 'resolves a 3-level nested scalar `$.deep.level1.level2.level3`' {
        $item = $script:NestedJson | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable -Depth 10
        $row = Apply-XdrProjectionMap -Item $item -ProjectionMap @{ Buried = '$.deep.level1.level2.level3' }
        $row.Buried | Should -Be 'buried'
    }

    It 'single index into a nested array `$.a.b[1].c` still works' {
        $item = $script:NestedJson | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable -Depth 10
        $row = Apply-XdrProjectionMap -Item $item -ProjectionMap @{ SecondC = '$.a.b[1].c' }
        $row.SecondC | Should -Be 'c2'
    }

    It 'index then deeper walk `$.a.b[0].d.e`' {
        $item = $script:NestedJson | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable -Depth 10
        $row = Apply-XdrProjectionMap -Item $item -ProjectionMap @{ FirstE = '$.a.b[0].d.e' }
        $row.FirstE | Should -Be 'e1'
    }
}

Describe 'U3 · Misses degrade (RawJson floor · never throw · column omitted)' {

    It 'wildcard over an ABSENT path → column omitted (no throw)' {
        $item = $script:NestedJson | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable -Depth 10
        $row = $null
        { $script:probe = Apply-XdrProjectionMap -Item $item -ProjectionMap @{ Nope = '$.nonexistent[*].x' } } | Should -Not -Throw
        $script:probe.ContainsKey('Nope') | Should -BeFalse
    }

    It 'wildcard whose tail field is absent on every element → column omitted' {
        $item = $script:NestedJson | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable -Depth 10
        $row = Apply-XdrProjectionMap -Item $item -ProjectionMap @{ Missing = '$.a.b[*].nope' }
        $row.ContainsKey('Missing') | Should -BeFalse
    }

    It 'out-of-range single index → column omitted (no throw)' {
        $item = $script:NestedJson | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable -Depth 10
        { $script:probe2 = Apply-XdrProjectionMap -Item $item -ProjectionMap @{ X = '$.a.b[99].c' } } | Should -Not -Throw
        $script:probe2.ContainsKey('X') | Should -BeFalse
    }
}

Describe 'U3 · FLAT-path behavior is BYTE-IDENTICAL (GetHistory replay guard)' {
    # These mirror the existing flat-path expectations (Xdr.Common.Parser.ProdRequirements.Tests.ps1) so a
    # regression in the unchanged fast-path would surface here too.

    It 'simple `$.a` projects a scalar' {
        $raw = @{ a = 1; b = 'two' } | ConvertTo-Json | ConvertFrom-Json
        $row = Apply-XdrProjectionMap -Item $raw -ProjectionMap @{ A = '$.a'; B = '$.b' }
        $row.A | Should -Be 1
        $row.B | Should -Be 'two'
    }

    It 'flat nested `$.user.id` (single dotted object · the GetHistory-style path)' {
        $raw = @{ user = @{ id = 'u-42'; name = 'alice' } } | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        $row = Apply-XdrProjectionMap -Item $raw -ProjectionMap @{ UserId = '$.user.id' }
        $row.UserId | Should -Be 'u-42'
    }

    It 'missing flat path does NOT throw and omits the column' {
        $raw = @{ a = 1 } | ConvertTo-Json | ConvertFrom-Json
        { $script:p = Apply-XdrProjectionMap -Item $raw -ProjectionMap @{ A = '$.a'; C = '$.nonexistent.deep.path' } } | Should -Not -Throw
        $script:p.ContainsKey('A') | Should -BeTrue
        $script:p.ContainsKey('C') | Should -BeFalse
    }

    It 'replays the real GetHistory fixture row[0] flat ProjectionMap UNCHANGED (byte-identical typing)' {
        $repoRoot = (Resolve-Path "$PSScriptRoot\..\..\..").Path
        $manifest = Import-PowerShellDataFile (Join-Path $repoRoot 'manifests\Defender\Operations.psd1')
        # Select GetHistory BY KEY · the 9-op Shipped manifest is catalogue-ordered (GetHistory is index 2, not 0).
        $op = $manifest.Operations | Where-Object { $_.OperationKey -eq 'GetHistory' } | Select-Object -First 1
        $cap = Get-Content (Join-Path $repoRoot 'tests\fixtures\live\MDE_ActionCenter_CL-raw.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 25
        $sample = @($cap['Results'])[0]
        $row = Apply-XdrProjectionMap -Item $sample -ProjectionMap $op.ProjectionMap -OperationKey 'GetHistory'
        # Every flat scalar PM key that exists on the sample must project to the sample's value (no wildcard here).
        $row.ActionId    | Should -Be $sample['ActionId']
        $row.ActionType  | Should -Be $sample['ActionType']
        $row.EventTime   | Should -Be $sample['EventTime']
        $row.EndTime     | Should -Be $sample['EndTime']
    }
}
