#Requires -Version 7.4
# SB2 / IN1 RED pin (audit 2026-06-12) · Log Analytics SILENTLY truncates a string column past its ~256KB cap
# MID-TOKEN → invalid JSON, no marker (live-confirmed: GetTenantContext RawJson stored at exactly 262144 B, cut
# mid-object, parse_json broke). The 1MB RawJson clamp (the locked "floor") is PHYSICALLY IMPOSSIBLE — LA caps the
# column at 256KB regardless — so it must clamp at an LA-safe threshold and PRESERVE A HEAD inside a VALID-JSON
# observable envelope (the old marker-only path discarded ALL content). Plus an ingest per-column backstop for any
# string column (large projection *Json cols too).

BeforeAll {
    $repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $env:PSModulePath = (Join-Path $repo 'src\Modules') + [IO.Path]::PathSeparator + $env:PSModulePath
    Import-Module (Join-Path $repo 'src\Modules\Xdr.Common.Parser\Xdr.Common.Parser.psd1') -Force -DisableNameChecking
    Import-Module (Join-Path $repo 'src\Modules\Xdr.Common.Ingest\Xdr.Common.Ingest.psd1') -Force -DisableNameChecking
    $script:LaCap = 256 * 1024
}

Describe 'SB2 · Compress-XdrRawJson is LA-256KB-safe AND head-preserving' {
    It 'a >256KB item clamps to a VALID-JSON envelope UNDER the LA cap (never invalid silent truncation)' {
        $big = @{ blob = ('x' * 300000); k = 'v' }
        $cmp = Compress-XdrRawJson -Item $big
        [System.Text.Encoding]::UTF8.GetByteCount($cmp) | Should -BeLessOrEqual $script:LaCap
        { $cmp | ConvertFrom-Json -ErrorAction Stop } | Should -Not -Throw    # MUST be valid JSON
    }
    It 'the clamp PRESERVES A HEAD (not marker-only) + keeps the observable markers' {
        $big = @{ blob = ('y' * 300000) }
        $cmp = Compress-XdrRawJson -Item $big
        $cmp | Should -Match '__xdrlr_truncated'
        $cmp | Should -Match '__xdrlr_original_bytes'
        $obj = $cmp | ConvertFrom-Json
        ([string]$obj.__xdrlr_head).Length | Should -BeGreaterThan 1000   # real content head, not empty
    }
    It 'a small item is returned UNCHANGED (no clamp, no envelope)' {
        $small = @{ ActionId = 'A1'; EventTime = '2026-06-11T05:00:00Z' }
        $cmp = Compress-XdrRawJson -Item $small
        $cmp | Should -Not -Match '__xdrlr_truncated'
        ($cmp | ConvertFrom-Json).ActionId | Should -Be 'A1'
    }
}

Describe 'F3 · over-cap RawJson STUBS projected non-scalar fields (clamp = dormant never-hit floor)' {
    It 'a jumbo PROJECTED non-scalar field is stubbed → RawJson UNDER the cap, NOT head-truncated · no data loss (data is in its <key>Json column)' {
        $item = @{ name = 'op'; status = 'on'; bigArray = @(@{ blob = ('x' * 300000) }) }
        $cmp = Compress-XdrRawJson -Item $item -MaxBytes (240 * 1024) -StubFields @('bigArray')
        [System.Text.Encoding]::UTF8.GetByteCount($cmp) | Should -BeLessOrEqual (240 * 1024)
        { $cmp | ConvertFrom-Json -ErrorAction Stop } | Should -Not -Throw
        $cmp | Should -Not -Match '__xdrlr_truncated'        # stubbing kept it small — NOT head-truncated
        $obj = $cmp | ConvertFrom-Json
        $obj.bigArray.__xdrlr_in_column | Should -BeTrue     # stubbed (the full content is in bigArrayJson)
        $obj.name | Should -Be 'op'; $obj.status | Should -Be 'on'   # scalars stay inline + intact
    }
    It 'WITHOUT stub-fields the SAME jumbo item head-truncates (proves the stub path is what makes the clamp dormant)' {
        $item = @{ name = 'op'; bigArray = @(@{ blob = ('y' * 300000) }) }
        (Compress-XdrRawJson -Item $item -MaxBytes (240 * 1024)) | Should -Match '__xdrlr_truncated'
    }
    It 'a small item with a stub-field is UNCHANGED (under cap → no stubbing · array stays inline)' {
        $cmp = Compress-XdrRawJson -Item @{ name = 'op'; arr = @(1, 2, 3) } -MaxBytes (240 * 1024) -StubFields @('arr')
        $cmp | Should -Not -Match '__xdrlr_in_column'
        @(($cmp | ConvertFrom-Json).arr) | Should -Be @(1, 2, 3)
    }
    It 'end-to-end · ConvertTo-XdrRows on a jumbo item → RawJson stubbed (dormant clamp) + full data in its <key>Json column' {
        $body = @{ value = @(@{ name = 'op'; bigArray = @(@{ blob = ('x' * 300000) }) }) }
        $rows = ConvertTo-XdrRows -ResponseBody $body -OperationKey 'T' -Category 'Test' -ResponseShape wrapper -ItemsContainer 'value' -ProjectionMap @{ name = '$.name'; bigArrayJson = '$.bigArray' }
        $r = $rows[0]
        [System.Text.Encoding]::UTF8.GetByteCount([string]$r['RawJson']) | Should -BeLessOrEqual (240 * 1024)
        [string]$r['RawJson'] | Should -Match '__xdrlr_in_column'
        [System.Text.Encoding]::UTF8.GetByteCount([string]$r['bigArrayJson']) | Should -BeGreaterThan 250000   # full data preserved in the column
    }
    It 'Get-XdrProjectedNonScalarFields returns top-level non-scalar PROJECTED fields only (scalars + unprojected excluded · gate not vacuous)' {
        InModuleScope 'Xdr.Common.Parser' {
            $item = @{ bigArray = @(1, 2); obj = @{ a = 1 }; scalarF = 'x'; unprojected = @(9, 9) }
            $pm = @{ bigArrayJson = '$.bigArray'; objJson = '$.obj'; scalarF = '$.scalarF' }   # 'unprojected' not mapped
            @((Get-XdrProjectedNonScalarFields -Item $item -ProjectionMap $pm) | Sort-Object) | Should -Be @('bigArray', 'obj')
        }
    }
}

Describe 'IN1 · Limit-XdrColumnBytes per-column backstop (any string column)' {
    It 'clamps a >256KB typed/projection column to under the LA cap with a visible marker' {
        InModuleScope 'Xdr.Common.Ingest' {
            $row = @{ OperationKey = 'X'; RawJson = 'small'; RelatedEntitiesJson = ('z' * 300000) }
            $out = Limit-XdrColumnBytes -Row $row -MaxBytes (240 * 1024) -OperationKey 'X'
            [System.Text.Encoding]::UTF8.GetByteCount($out['RelatedEntitiesJson']) | Should -BeLessOrEqual (256 * 1024)
            $out['RelatedEntitiesJson'] | Should -Match 'XDRLR-COL-TRUNCATED'
        }
    }
    It 'leaves normal-sized columns untouched' {
        InModuleScope 'Xdr.Common.Ingest' {
            $row = @{ OperationKey = 'X'; RawJson = 'small'; A = 'ok' }
            $out = Limit-XdrColumnBytes -Row $row -MaxBytes (240 * 1024) -OperationKey 'X'
            $out['A'] | Should -Be 'ok'
            $out['RawJson'] | Should -Be 'small'
        }
    }
}
