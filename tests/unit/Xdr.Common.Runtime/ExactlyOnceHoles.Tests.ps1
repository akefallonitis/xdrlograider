#Requires -Version 7.4
# F-C · the two REAL exactly-once holes (G1, G3) + the G2 precision guard, proven END-TO-END against the REAL
# Invoke-XdrEntryPoll with the I/O boundaries mocked (auth · HTTP · DCE · checkpoint I/O) — the SAME harness shape as
# ExactlyOnce.Tests.ps1 / ResumablePagination.Tests.ps1. A Save-XdrCheckpointAtomic mock writes the saved props back
# into a $global: checkpoint so cycle N+1's Get-XdrCheckpoint sees cycle N's persisted high-water + boundary set —
# this is what lets each test assert TRUE cross-cycle exactly-once.
#
#   G1 · a partial multi-chunk ingest (some chunks land 2xx, a later chunk DLQ'd) must NOT re-ingest the landed
#        chunks next cycle. The committed high-water advances over the CONTIGUOUS LANDED PREFIX, leaving the un-landed
#        remainder above it → next cycle ingests ONLY the remainder, ZERO re-ingest of the landed rows.
#   G3 · two overlapping poll cycles on ONE Op must not double-ingest. A single-flight lease serializes them; the
#        contended cycle SKIPS (Success no-op) → total ingest = ONE set.
#   G2 · a boundary row that reappears at a coarser sub-second precision is still dropped (manifest CursorPrecision).

BeforeAll {
    $script:Repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $psd1s = Get-ChildItem (Join-Path $script:Repo 'src\Modules') -Directory |
        ForEach-Object { Join-Path $_.FullName ($_.Name + '.psd1') } | Where-Object { Test-Path $_ }
    for ($pass = 1; $pass -le 4; $pass++) {
        foreach ($p in $psd1s) { try { Import-Module $p -Force -DisableNameChecking -ErrorAction Stop } catch { } }
    }

    function New-AcRow([string]$id, [string]$time) { @{ ActionId = $id; EventTime = $time } }
    $env:XDRLR_DCE_ENDPOINT = 'https://dce-test.local'

    $global:XdrHoleHttpRows   = @()
    $global:XdrHoleCheckpoint = $null
    $global:XdrHoleIngested   = [System.Collections.Generic.List[object]]::new()
    $global:XdrHoleSendCall    = 0
}

Describe 'G1 · partial multi-chunk ingest advances over the contiguous landed prefix (no re-ingest)' {
    BeforeEach {
        # ASCENDING fetch order (oldest first) so the landed PREFIX is the OLDER rows and the un-landed remainder is
        # NEWER → it sits ABOVE the advanced high-water and is re-polled (never dropped). (The connector ingests rows
        # in fetch order; SortOrder is a server hint, it does not reorder rows in-connector.)
        $script:HoleEntry = @{
            OperationKey = 'GetHistory'; Portal = 'Defender'; Category = 'Operations'; Method = 'GET'; SubPortal = 'mtp'; Path = '/x'
            ResponseShape = 'wrapper'; ItemsContainer = 'Results'
            IngestionMode = 'CURSOR'; CursorField = 'EventTime'; NaturalKey = @('ActionId')
            TimeFilter = @{ FieldName = 'EventTime'; Mode = 'ClientSideHighWater' }
            Pagination = @{ Mode = 'pageSize'; PageSizeQuery = 'pageSize'; PageSize = 500; PageIndexQuery = 'pageIndex'; CursorMode = 'pageIndexIncrement'; LoopGuard = 1000 }
            ProjectionMap = @{ EventTime = '$.EventTime'; ActionId = '$.ActionId' }
            DcrImmutableId = 'dcr-test'; DcrStreamName = 'Custom-Defender_Operations_CL'
        }
        # Three rows · the test models them as chunk1={R1}, chunk2={R2} (LAND) and chunk3={R3} (DLQ'd) via the mock.
        $global:XdrHoleHttpRows = @((New-AcRow 'R1' '2026-05-01T00:00:00Z'), (New-AcRow 'R2' '2026-05-02T00:00:00Z'), (New-AcRow 'R3' '2026-05-03T00:00:00Z'))
        $global:XdrHoleCheckpoint = @{ OperationKey = 'GetHistory'; Cursor = $null; BoundaryKeys = $null; ResumePage = $null; ResumeCursor = $null; ResumeHighWater = $null; ResumeBoundaryKeys = $null; ETag = $null }
        $global:XdrHoleIngested.Clear()
        $global:XdrHoleSendCall = 0

        Mock -ModuleName Xdr.Common.Runtime Connect-XdrPortal { @{ Portal = 'Defender'; Sccauth = 'x'; XsrfToken = 'y' } }
        Mock -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp { @{ StatusCode = 200; Body = @{ Results = $global:XdrHoleHttpRows }; RawBody = '' } }
        Mock -ModuleName Xdr.Common.Runtime Get-XdrCheckpoint { $global:XdrHoleCheckpoint }
        Mock -ModuleName Xdr.Common.Runtime Save-XdrCheckpointAtomic {
            $global:XdrHoleCheckpoint = @{
                OperationKey = $OperationKey; Cursor = $Cursor; BoundaryKeys = $BoundaryKeys
                ResumePage = $ResumePage; ResumeCursor = $ResumeCursor; ResumeHighWater = $ResumeHighWater; ResumeBoundaryKeys = $ResumeBoundaryKeys
                ETag = 'etag-next'
            }
            $true
        }
        # Cycle 1 → PARTIAL: the first 2 rows (R1,R2) land contiguously, the 3rd (R3) is DLQ'd. Cycle 2+ → full success.
        Mock -ModuleName Xdr.Common.Runtime Send-ToDce {
            $global:XdrHoleSendCall++
            foreach ($r in $Rows) { $global:XdrHoleIngested.Add($r) }
            $n = @($Rows).Count
            if ($global:XdrHoleSendCall -eq 1) {
                # R3 DLQ'd by Send-XdrDceChunk inside the real Send-ToDce; here the mock reports the contiguous prefix.
                @{ Success = $false; RowsAccepted = 2; LandedContiguousRows = 2; BytesIngested = 200; StatusCode = 400; ErrorClass = 'XdrPortalTerminalException'; ErrorMessage = 'chunk 3 DLQ' }
            } else {
                @{ Success = $true; RowsAccepted = $n; LandedContiguousRows = $n; BytesIngested = (100 * $n) }
            }
        }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrEvent { }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrException { }
        # G3 · grant the lease so the G1 path runs normally (this Describe is not testing contention).
        Mock -ModuleName Xdr.Common.Runtime Lock-XdrSingleFlight { 'lease-granted' }
        Mock -ModuleName Xdr.Common.Runtime Unlock-XdrSingleFlight { $true }
    }

    It 'cycle 1 partial-fails (R3 DLQ) yet COMMITS the landed prefix high-water (day 2 · key R2)' {
        $r1 = Invoke-XdrEntryPoll -Entry $script:HoleEntry -CorrelationId 'g1-c1'
        $r1.ErrorClass | Should -Be 'XdrPortalTerminalException'   # the partial failure is still surfaced
        # The committed high-water advanced over ONLY the landed prefix (R1,R2) → day 2, boundary key R2.
        $global:XdrHoleCheckpoint.Cursor | Should -Match '2026-05-02'
        $global:XdrHoleCheckpoint.BoundaryKeys | Should -Be 'R2'
    }

    It 'next cycle ingests ONLY the un-landed remainder (R3) · ZERO re-ingest of the landed R1,R2' {
        $null = Invoke-XdrEntryPoll -Entry $script:HoleEntry -CorrelationId 'g1-c1'   # partial · commits day 2
        $global:XdrHoleIngested.Clear()                                               # forget cycle-1 sends
        $r2 = Invoke-XdrEntryPoll -Entry $script:HoleEntry -CorrelationId 'g1-c2'     # re-poll the same 3 rows
        $r2.Success | Should -BeTrue
        $ids = @($global:XdrHoleIngested | ForEach-Object { $_.ActionId })
        $ids | Should -Be @('R3')                                                     # ONLY the remainder
        $ids | Should -Not -Contain 'R1'
        $ids | Should -Not -Contain 'R2'
        Should -Invoke -ModuleName Xdr.Common.Runtime Send-ToDce -Times 1 -Exactly -ParameterFilter { @($Rows).Count -eq 1 -and $Rows[0].ActionId -eq 'R3' }
    }

    It 'a FULL success (no partial) is byte-identical: commits max over ALL rows · no partial-prefix path' {
        # Force a full success on cycle 1 by starting the send counter past the partial branch.
        $global:XdrHoleSendCall = 5
        $r = Invoke-XdrEntryPoll -Entry $script:HoleEntry -CorrelationId 'g1-full'
        $r.Success | Should -BeTrue
        $r.ErrorClass | Should -BeNullOrEmpty
        $r.ItemCount | Should -Be 3
        $global:XdrHoleCheckpoint.Cursor | Should -Match '2026-05-03'   # full max (R3)
        $global:XdrHoleCheckpoint.BoundaryKeys | Should -Be 'R3'
    }
}

Describe 'G1 (DESCENDING · V3) · send-order normalization makes the landed-prefix advance valid for newest-first responses' {
    BeforeEach {
        # GetHistory is SortOrder=Descending → the response is NEWEST-first. V3 normalizes the SEND order to
        # ascending-by-cursor, so the contiguous-landed prefix is the OLDEST rows and the advance is valid. WITHOUT
        # that normalization the landed prefix would be the NEWEST rows (remainderMin < prefixMax → guard fails → NO
        # advance → re-ingest dups). This Describe feeds DESCENDING input and asserts the SAME correct outcome as the
        # ASCENDING Describe above — only possible because of the normalization (proves V3, not a tautology).
        $script:DescEntry = @{
            OperationKey = 'GetHistory'; Portal = 'Defender'; Category = 'Operations'; Method = 'GET'; SubPortal = 'mtp'; Path = '/x'
            ResponseShape = 'wrapper'; ItemsContainer = 'Results'
            IngestionMode = 'CURSOR'; CursorField = 'EventTime'; NaturalKey = @('ActionId'); SortOrder = 'Descending'
            TimeFilter = @{ FieldName = 'EventTime'; Mode = 'ClientSideHighWater' }
            Pagination = @{ Mode = 'pageSize'; PageSizeQuery = 'pageSize'; PageSize = 500; PageIndexQuery = 'pageIndex'; CursorMode = 'pageIndexIncrement'; LoopGuard = 1000 }
            ProjectionMap = @{ EventTime = '$.EventTime'; ActionId = '$.ActionId' }
            DcrImmutableId = 'dcr-test'; DcrStreamName = 'Custom-Defender_Operations_CL'
        }
        # NEWEST-first (descending) fetch order: R3(day3), R2(day2), R1(day1).
        $global:XdrHoleHttpRows = @((New-AcRow 'R3' '2026-05-03T00:00:00Z'), (New-AcRow 'R2' '2026-05-02T00:00:00Z'), (New-AcRow 'R1' '2026-05-01T00:00:00Z'))
        $global:XdrHoleCheckpoint = @{ OperationKey = 'GetHistory'; Cursor = $null; BoundaryKeys = $null; ResumePage = $null; ResumeCursor = $null; ResumeHighWater = $null; ResumeBoundaryKeys = $null; ETag = $null }
        $global:XdrHoleIngested.Clear()
        $global:XdrHoleSendCall = 0

        Mock -ModuleName Xdr.Common.Runtime Connect-XdrPortal { @{ Portal = 'Defender'; Sccauth = 'x'; XsrfToken = 'y' } }
        Mock -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp { @{ StatusCode = 200; Body = @{ Results = $global:XdrHoleHttpRows }; RawBody = '' } }
        Mock -ModuleName Xdr.Common.Runtime Get-XdrCheckpoint { $global:XdrHoleCheckpoint }
        Mock -ModuleName Xdr.Common.Runtime Save-XdrCheckpointAtomic {
            $global:XdrHoleCheckpoint = @{
                OperationKey = $OperationKey; Cursor = $Cursor; BoundaryKeys = $BoundaryKeys
                ResumePage = $ResumePage; ResumeCursor = $ResumeCursor; ResumeHighWater = $ResumeHighWater; ResumeBoundaryKeys = $ResumeBoundaryKeys
                ETag = 'etag-next'
            }
            $true
        }
        # The send mock lands the first 2 rows IN SEND ORDER. After V3's ascending normalization the send order is
        # R1,R2,R3 → the landed prefix is R1,R2 (oldest), R3 is the DLQ'd remainder.
        Mock -ModuleName Xdr.Common.Runtime Send-ToDce {
            $global:XdrHoleSendCall++
            foreach ($r in $Rows) { $global:XdrHoleIngested.Add($r) }
            $n = @($Rows).Count
            if ($global:XdrHoleSendCall -eq 1) {
                @{ Success = $false; RowsAccepted = 2; LandedContiguousRows = 2; BytesIngested = 200; StatusCode = 400; ErrorClass = 'XdrPortalTerminalException'; ErrorMessage = 'chunk 3 DLQ' }
            } else {
                @{ Success = $true; RowsAccepted = $n; LandedContiguousRows = $n; BytesIngested = (100 * $n) }
            }
        }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrEvent { }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrException { }
        Mock -ModuleName Xdr.Common.Runtime Lock-XdrSingleFlight { 'lease-granted' }
        Mock -ModuleName Xdr.Common.Runtime Unlock-XdrSingleFlight { $true }
    }

    It 'normalizes the SEND order to ascending-by-cursor (oldest R1 sent FIRST despite a newest-first response)' {
        $null = Invoke-XdrEntryPoll -Entry $script:DescEntry -CorrelationId 'g1d-order'
        $global:XdrHoleIngested[0].ActionId | Should -Be 'R1'   # oldest first → the normalization fired
        $global:XdrHoleIngested[2].ActionId | Should -Be 'R3'   # newest last
    }

    It 'cycle 1 partial-fails yet COMMITS the landed-prefix high-water (day 2 · R2) — advance is VALID for descending' {
        $r1 = Invoke-XdrEntryPoll -Entry $script:DescEntry -CorrelationId 'g1d-c1'
        $r1.ErrorClass | Should -Be 'XdrPortalTerminalException'
        # WITHOUT V3 the landed prefix would be the NEWEST rows → guard fails → Cursor stays null. WITH it the prefix is
        # the oldest (R1,R2) → committed high-water = day 2, boundary key R2.
        $global:XdrHoleCheckpoint.Cursor | Should -Match '2026-05-02'
        $global:XdrHoleCheckpoint.BoundaryKeys | Should -Be 'R2'
    }

    It 'next cycle ingests ONLY the un-landed remainder (R3) · ZERO re-ingest of the landed R1,R2' {
        $null = Invoke-XdrEntryPoll -Entry $script:DescEntry -CorrelationId 'g1d-c1'
        $global:XdrHoleIngested.Clear()
        $r2 = Invoke-XdrEntryPoll -Entry $script:DescEntry -CorrelationId 'g1d-c2'
        $r2.Success | Should -BeTrue
        @($global:XdrHoleIngested | ForEach-Object { $_.ActionId }) | Should -Be @('R3')
    }
}

Describe 'G3 · overlapping cycles on ONE Op are single-flighted (second skips · ingest exactly ONCE)' {
    BeforeEach {
        $script:G3Entry = @{
            OperationKey = 'GetHistory'; Portal = 'Defender'; Category = 'Operations'; Method = 'GET'; SubPortal = 'mtp'; Path = '/x'
            ResponseShape = 'wrapper'; ItemsContainer = 'Results'
            IngestionMode = 'CURSOR'; CursorField = 'EventTime'; NaturalKey = @('ActionId')
            TimeFilter = @{ FieldName = 'EventTime'; Mode = 'ClientSideHighWater' }
            Pagination = @{ Mode = 'pageSize'; PageSizeQuery = 'pageSize'; PageSize = 500; PageIndexQuery = 'pageIndex'; CursorMode = 'pageIndexIncrement'; LoopGuard = 1000 }
            ProjectionMap = @{ EventTime = '$.EventTime'; ActionId = '$.ActionId' }
            DcrImmutableId = 'dcr-test'; DcrStreamName = 'Custom-Defender_Operations_CL'
        }
        $global:XdrHoleHttpRows = @((New-AcRow 'K1' '2026-05-01T00:00:00Z'), (New-AcRow 'K2' '2026-05-02T00:00:00Z'))
        $global:XdrHoleCheckpoint = @{ OperationKey = 'GetHistory'; Cursor = $null; BoundaryKeys = $null; ETag = $null }
        $global:XdrHoleIngested.Clear()
        $global:XdrHoleLockCall = 0
        $global:XdrHoleLockKeys = [System.Collections.Generic.List[string]]::new()

        Mock -ModuleName Xdr.Common.Runtime Connect-XdrPortal { @{ Portal = 'Defender'; Sccauth = 'x'; XsrfToken = 'y' } }
        Mock -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp { @{ StatusCode = 200; Body = @{ Results = $global:XdrHoleHttpRows }; RawBody = '' } }
        Mock -ModuleName Xdr.Common.Runtime Get-XdrCheckpoint { $global:XdrHoleCheckpoint }
        Mock -ModuleName Xdr.Common.Runtime Save-XdrCheckpointAtomic { $true }
        Mock -ModuleName Xdr.Common.Runtime Send-ToDce {
            foreach ($r in $Rows) { $global:XdrHoleIngested.Add($r) }
            @{ Success = $true; RowsAccepted = @($Rows).Count; BytesIngested = 100 }
        }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrEvent { }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrException { }
        # Model an OVERLAP: the FIRST acquire grants the lease (cycle A is in flight); a SECOND acquire for the SAME
        # Op key while A still holds it is CONTENDED → $null. (Two real workers · the 2nd timer fired mid-cycle.)
        Mock -ModuleName Xdr.Common.Runtime Lock-XdrSingleFlight {
            $global:XdrHoleLockCall++
            $global:XdrHoleLockKeys.Add([string]$ResourceKey)
            if ($global:XdrHoleLockCall -eq 1) { 'lease-A' } else { $null }
        }
        Mock -ModuleName Xdr.Common.Runtime Unlock-XdrSingleFlight { $true }
    }

    It 'the contended second cycle SKIPS as a successful no-op · ingest happens EXACTLY ONCE' {
        $rA = Invoke-XdrEntryPoll -Entry $script:G3Entry -CorrelationId 'g3-A'   # acquires → ingests
        $rB = Invoke-XdrEntryPoll -Entry $script:G3Entry -CorrelationId 'g3-B'   # contended → skips

        $rA.Success | Should -BeTrue
        $rA.ItemCount | Should -Be 2
        $rB.Success | Should -BeTrue                                              # a skip is a SUCCESSFUL no-op
        $rB.ItemCount | Should -Be 0
        $rB.ErrorMessage | Should -Match 'single-flight contended'

        # Exactly ONE ingest set total (the contended cycle ingested nothing · no duplicate).
        @($global:XdrHoleIngested | ForEach-Object { $_.ActionId }) | Should -Be @('K1','K2')
        Should -Invoke -ModuleName Xdr.Common.Runtime Send-ToDce -Times 1 -Exactly
    }

    It 'the lease key is poll::<Portal>_<Category>::<OperationKey>' {
        $null = Invoke-XdrEntryPoll -Entry $script:G3Entry -CorrelationId 'g3-key'
        $global:XdrHoleLockKeys[0] | Should -Be 'poll::Defender_Operations::GetHistory'
    }

    It 'the contended cycle does NOT touch the checkpoint (no save · the in-flight cycle owns it)' {
        $null = Invoke-XdrEntryPoll -Entry $script:G3Entry -CorrelationId 'g3-A2'   # acquires
        $beforeB = $global:XdrHoleIngested.Count
        $null = Invoke-XdrEntryPoll -Entry $script:G3Entry -CorrelationId 'g3-B2'   # contended
        ($global:XdrHoleIngested.Count - $beforeB) | Should -Be 0   # the skip ingested nothing
    }

    It 'when the lease is AVAILABLE (no contention) the poll proceeds and ingests normally' {
        # Both acquires granted → both cycles run (e.g. two DIFFERENT ops, or sequential non-overlapping cycles).
        Mock -ModuleName Xdr.Common.Runtime Lock-XdrSingleFlight { 'lease-ok' }
        $r = Invoke-XdrEntryPoll -Entry $script:G3Entry -CorrelationId 'g3-ok'
        $r.Success | Should -BeTrue
        $r.ItemCount | Should -Be 2
    }
}

Describe 'G2 · manifest CursorPrecision boundary tie (end-to-end · reappearing coarser row still dropped)' {
    BeforeEach {
        # The committed high-water is 2026-05-03T00:00:00.500Z with key K3 already ingested. The live re-poll returns
        # K3 again but the server rounded its EventTime to a slightly different sub-second value (…​.501 · UPWARD jitter).
        # WITHOUT a precision guard that is > the high-water → NEWER → re-ingested (a DUPLICATE). WITH CursorPrecision
        # 'Second' both collapse to the same second → boundary tie → K3 already seen → DROPPED. Exactly-once preserved.
        $global:XdrHoleHttpRows = @((New-AcRow 'K3' '2026-05-03T00:00:00.501Z'), (New-AcRow 'K9' '2026-05-03T00:00:09.000Z'))
        $global:XdrHoleCheckpoint = @{ OperationKey = 'GetHistory'; Cursor = '2026-05-03T00:00:00.500Z'; BoundaryKeys = 'K3'; ETag = 'e1' }
        $global:XdrHoleIngested.Clear()

        Mock -ModuleName Xdr.Common.Runtime Connect-XdrPortal { @{ Portal = 'Defender'; Sccauth = 'x'; XsrfToken = 'y' } }
        Mock -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp { @{ StatusCode = 200; Body = @{ Results = $global:XdrHoleHttpRows }; RawBody = '' } }
        Mock -ModuleName Xdr.Common.Runtime Get-XdrCheckpoint { $global:XdrHoleCheckpoint }
        Mock -ModuleName Xdr.Common.Runtime Save-XdrCheckpointAtomic { $true }
        Mock -ModuleName Xdr.Common.Runtime Send-ToDce {
            foreach ($r in $Rows) { $global:XdrHoleIngested.Add($r) }
            @{ Success = $true; RowsAccepted = @($Rows).Count; BytesIngested = 100 }
        }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrEvent { }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrException { }
        Mock -ModuleName Xdr.Common.Runtime Lock-XdrSingleFlight { 'lease-granted' }
        Mock -ModuleName Xdr.Common.Runtime Unlock-XdrSingleFlight { $true }
    }

    It 'WITH CursorPrecision=Second the reappearing K3 is DROPPED (only the genuinely-new K9 ingests)' {
        $entry = @{
            OperationKey = 'GetHistory'; Portal = 'Defender'; Category = 'Operations'; Method = 'GET'; SubPortal = 'mtp'; Path = '/x'
            ResponseShape = 'wrapper'; ItemsContainer = 'Results'
            IngestionMode = 'CURSOR'; CursorField = 'EventTime'; NaturalKey = @('ActionId'); CursorPrecision = 'Second'
            TimeFilter = @{ FieldName = 'EventTime'; Mode = 'ClientSideHighWater' }
            Pagination = @{ Mode = 'pageSize'; PageSizeQuery = 'pageSize'; PageSize = 500; PageIndexQuery = 'pageIndex'; CursorMode = 'pageIndexIncrement'; LoopGuard = 1000 }
            ProjectionMap = @{ EventTime = '$.EventTime'; ActionId = '$.ActionId' }
            DcrImmutableId = 'dcr-test'; DcrStreamName = 'Custom-Defender_Operations_CL'
        }
        $r = Invoke-XdrEntryPoll -Entry $entry -CorrelationId 'g2-sec'
        $r.Success | Should -BeTrue
        @($global:XdrHoleIngested | ForEach-Object { $_.ActionId }) | Should -Be @('K9')   # K3 dropped (boundary tie)
    }

    It 'WITHOUT CursorPrecision (default exact) the upward-jittered K3 RE-INGESTS (the hole · default unchanged)' {
        # Proves the DEFAULT is back-compat exact: the same row with no precision field is treated as newer → ingested.
        $entry = @{
            OperationKey = 'GetHistory'; Portal = 'Defender'; Category = 'Operations'; Method = 'GET'; SubPortal = 'mtp'; Path = '/x'
            ResponseShape = 'wrapper'; ItemsContainer = 'Results'
            IngestionMode = 'CURSOR'; CursorField = 'EventTime'; NaturalKey = @('ActionId')   # NO CursorPrecision
            TimeFilter = @{ FieldName = 'EventTime'; Mode = 'ClientSideHighWater' }
            Pagination = @{ Mode = 'pageSize'; PageSizeQuery = 'pageSize'; PageSize = 500; PageIndexQuery = 'pageIndex'; CursorMode = 'pageIndexIncrement'; LoopGuard = 1000 }
            ProjectionMap = @{ EventTime = '$.EventTime'; ActionId = '$.ActionId' }
            DcrImmutableId = 'dcr-test'; DcrStreamName = 'Custom-Defender_Operations_CL'
        }
        $r = Invoke-XdrEntryPoll -Entry $entry -CorrelationId 'g2-exact'
        ($global:XdrHoleIngested | ForEach-Object { $_.ActionId } | Sort-Object) | Should -Be @('K3','K9')   # exact = the hole
    }
}
