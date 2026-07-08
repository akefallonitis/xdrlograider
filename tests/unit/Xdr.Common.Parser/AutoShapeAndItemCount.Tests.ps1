#Requires -Version 7.4
# Parser regression proofs for the GENERICITY fixes (2026-06-18):
#   E-MAJ4 · ConvertTo-XdrRows with ResponseShape='auto' (no manifest ItemsContainer) falls back to singleObject —
#            it does NOT magic-name-guess a container ('value'/'data'/...), so it can never fan out the WRONG array.
#            A manifest-declared ItemsContainer is still honored under 'auto' (DATA, not a guess). An explicit
#            'wrapper' shape KEEPS the magic-name fallback (back-compat for a declared-shape op without a container).
#   E-MAJ3 · Get-XdrResponseItemCount returns the RAW (pre-empty-gate) item count via the SAME ResponseShape +
#            ItemsContainer resolution ConvertTo-XdrRows uses (single-source · the pagination page-fullness count).

BeforeAll {
    $modulesRoot = Join-Path $PSScriptRoot '..\..\..\src\Modules' | Resolve-Path
    $env:PSModulePath = $modulesRoot.Path + [IO.Path]::PathSeparator + $env:PSModulePath
    Import-Module (Join-Path $modulesRoot.Path 'Xdr.Common.Parser\Xdr.Common.Parser.psd1') -Force -DisableNameChecking
}

Describe 'E-MAJ4 · ResponseShape=auto falls back to singleObject (no magic-name container guess)' {
    It 'auto + a body whose only array is a NON-record metadata key (value) → ONE row (the body), NOT the array fanned' {
        # A response where `value` is metadata (e.g. a settings array), NOT the record list. The old magic-name list
        # would grab `value` and fan it to N rows = the WRONG array. auto→singleObject yields exactly ONE row (safe).
        $body = @{ id = 'cfg-1'; value = @('a','b','c'); name = 'someConfig' } | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
        $rows = ConvertTo-XdrRows -ResponseBody $body -OperationKey 'AutoOp' -Category 'Operations' -ResponseShape 'auto'
        @($rows).Count | Should -Be 1                                       # singleObject · NOT 3 (the wrong fan-out)
    }
    It 'auto + a manifest ItemsContainer IS honored (DATA-driven · not a guess) → fans the declared array' {
        $body = @{ Results = @(@{ id = 1 }, @{ id = 2 }) } | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
        $rows = ConvertTo-XdrRows -ResponseBody $body -OperationKey 'AutoOp' -Category 'Operations' -ResponseShape 'auto' -ItemsContainer 'Results' -ProjectionMap @{ Id = '$.id' }
        @($rows).Count | Should -Be 2                                       # the DECLARED container fans · not a guess
    }
    It 'auto + a body with NO array (pure object) → ONE row (singleObject · unchanged for the common case)' {
        $body = @{ IsActive = $true; mode = 'prod' } | ConvertTo-Json | ConvertFrom-Json -AsHashtable
        $rows = ConvertTo-XdrRows -ResponseBody $body -OperationKey 'AutoOp' -Category 'Operations' -ResponseShape 'auto' -ProjectionMap @{ Mode = '$.mode' }
        @($rows).Count | Should -Be 1
        @($rows)[0]['Mode'] | Should -Be 'prod'
    }
    It 'explicit wrapper KEEPS the magic-name fallback (declared shape · no container) → still resolves Results' {
        # E-MAJ4 narrows ONLY the `auto` path; an explicit `wrapper` with no ItemsContainer still resolves a canonical
        # list key (back-compat · a declared-wrapper op is asserting "there IS a list here").
        $body = @{ Results = @(@{ id = 'r1' }, @{ id = 'r2' }, @{ id = 'r3' }) } | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
        $rows = ConvertTo-XdrRows -ResponseBody $body -OperationKey 'WrapOp' -Category 'Operations' -ResponseShape 'wrapper' -ProjectionMap @{ Id = '$.id' }
        @($rows).Count | Should -Be 3
    }
    It 'bareArray / singleObject explicit shapes are unchanged' {
        # ConvertTo-XdrRows returns `,$list` (comma-protected) · assign THEN @() to enumerate (a single `@(call)` would
        # capture the 1-element comma-wrapper · the documented trap in GetHistory.Tests.ps1).
        $arr = @(@{ id = 1 }, @{ id = 2 }) | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        $arrRows = ConvertTo-XdrRows -ResponseBody $arr -OperationKey 'B' -Category 'Operations' -ResponseShape 'bareArray' -ProjectionMap @{ Id = '$.id' }
        @($arrRows).Count | Should -Be 2
        $obj = @{ id = 1 } | ConvertTo-Json | ConvertFrom-Json
        $objRows = ConvertTo-XdrRows -ResponseBody $obj -OperationKey 'S' -Category 'Operations' -ResponseShape 'singleObject' -ProjectionMap @{ Id = '$.id' }
        @($objRows).Count | Should -Be 1
    }
}

Describe 'E-MAJ3 · Get-XdrResponseItemCount returns the RAW (pre-empty-gate) item count (single-source with the parser)' {
    It 'counts RAW wrapper items INCLUDING ones the empty-gate would drop (the pagination page-fullness count)' {
        # 2 raw items · one is an empty hashtable (the empty-gate drops it from ROWS, but NOT from the page count).
        $body = @{ Results = @(@{ V = 'x' }, @{}) } | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
        # The parser (post-gate) yields 1 row; the RAW item count is 2 — they MUST differ here (that's the whole bug).
        @(ConvertTo-XdrRows -ResponseBody $body -OperationKey 'C' -Category 'Operations' -ResponseShape 'wrapper' -ItemsContainer 'Results' -ProjectionMap @{ V = '$.V' }).Count | Should -Be 1
        (Get-XdrResponseItemCount -ResponseBody $body -ResponseShape 'wrapper' -ItemsContainer 'Results') | Should -Be 2
    }
    It 'bareArray raw count == array length' {
        $body = @(@{ id = 1 }, @{ id = 2 }, @{ id = 3 }) | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        (Get-XdrResponseItemCount -ResponseBody $body -ResponseShape 'bareArray') | Should -Be 3
    }
    It 'singleObject raw count == 1' {
        $body = @{ a = 1 } | ConvertTo-Json | ConvertFrom-Json
        (Get-XdrResponseItemCount -ResponseBody $body -ResponseShape 'singleObject') | Should -Be 1
    }
    It 'auto (no container) raw count == 1 (singleObject · E-MAJ4 · never the magic-guessed array length)' {
        $body = @{ id = 'x'; value = @('a','b','c','d') } | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
        (Get-XdrResponseItemCount -ResponseBody $body -ResponseShape 'auto') | Should -Be 1   # NOT 4
    }
    It 'null body → 0 (fail-safe)' {
        (Get-XdrResponseItemCount -ResponseBody $null -ResponseShape 'wrapper' -ItemsContainer 'Results') | Should -Be 0
    }
}
