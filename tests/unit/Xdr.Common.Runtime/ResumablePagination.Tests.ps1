#Requires -Version 7.4
# U1 · RESUMABLE PAGINATION proof (plan §16 U1 · "works at ALL volumes · never time out · never drop · never
# double-ingest"). Drives the REAL Invoke-XdrEntryPoll with the I/O boundaries mocked (auth · HTTP · DCE ·
# checkpoint I/O) EXACTLY like ExactlyOnce.Tests.ps1, but with TWO additions that make a multi-cycle drain
# observable:
#   1. A PAGE-AWARE Invoke-XdrPortalHttp mock that returns ONE distinct row per page (PageSize=1 · so each fetched
#      page == a full page → pageIndexIncrement keeps paging until an empty page), recording which absolute
#      pageIndex each cycle requested.
#   2. A Save-XdrCheckpointAtomic mock that WRITES the saved props back into the $global: checkpoint (the real
#      Table round-trip), so cycle N+1's Get-XdrCheckpoint sees cycle N's persisted Cursor + ResumePage +
#      ResumeHighWater. This is what lets the test assert TRUE cross-cycle exactly-once.
#
# A per-cycle page budget of 2 (env XDRLR_MAX_PAGES_PER_CYCLE) forces a 5-page result set to drain across 3
# cycles. Proven: EVERY row ingests EXACTLY ONCE across the cycles (no drop · no duplicate) · the cross-cycle
# high-water (Cursor) advances ONLY when the drain completes · ResumePage/ResumeHighWater are set MID-drain and
# CLEARED on completion · a re-poll after completion ingests ZERO (the exactly-once boundary still holds).

BeforeAll {
    $script:Repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $psd1s = Get-ChildItem (Join-Path $script:Repo 'src\Modules') -Directory |
        ForEach-Object { Join-Path $_.FullName ($_.Name + '.psd1') } | Where-Object { Test-Path $_ }
    for ($pass = 1; $pass -le 4; $pass++) {
        foreach ($p in $psd1s) { try { Import-Module $p -Force -DisableNameChecking -ErrorAction Stop } catch { } }
    }

    function New-AcRow([string]$id, [string]$time) { @{ ActionId = $id; EventTime = $time } }

    $env:XDRLR_DCE_ENDPOINT = 'https://dce-test.local'

    # ── The 5-page result set (descending EventTime · newest page first · the live Defender sort) ──
    # Page p (1-based) → one row Cp at day (6-p): page1=C5@day5 (newest) … page5=C1@day1 (oldest). Page 6+ = empty.
    # $global: (NOT $script:) so the value is visible INSIDE the module-scoped Invoke-XdrPortalHttp mock body —
    # a $script: var there resolves to the MODULE's scope (null), which would feed empty rows into the parser.
    $global:XdrResumePageRow = @{
        1 = (New-AcRow 'C5' '2026-05-05T00:00:00Z')
        2 = (New-AcRow 'C4' '2026-05-04T00:00:00Z')
        3 = (New-AcRow 'C3' '2026-05-03T00:00:00Z')
        4 = (New-AcRow 'C2' '2026-05-02T00:00:00Z')
        5 = (New-AcRow 'C1' '2026-05-01T00:00:00Z')
    }

    # Records EVERY row handed to Send-ToDce across ALL cycles (the union must be each row exactly once).
    $global:XdrResumeIngested = [System.Collections.Generic.List[object]]::new()
    # Records the pageIndex values requested (proves resume continues, never re-fetches a page).
    $global:XdrResumePagesRequested = [System.Collections.Generic.List[int]]::new()
    # The persisted checkpoint · Save mock writes back here so the next cycle resumes from it.
    $global:XdrResumeCheckpoint = $null

    # Run ONE poll cycle against the page-aware mocks; returns the Invoke-XdrEntryPoll result.
    function Invoke-ResumeCycle { param([string]$Cid) Invoke-XdrEntryPoll -Entry $script:ResumeEntry -CorrelationId $Cid }
}

Describe 'U1 · resumable CURSOR drain · exactly-once across cycles + high-water advances ONLY on completion' {
    BeforeEach {
        $env:XDRLR_MAX_PAGES_PER_CYCLE = '2'   # force a 5-page set to take 3 cycles

        $script:ResumeEntry = @{
            OperationKey = 'ResumeOp'; Portal = 'Defender'; Category = 'Operations'; Method = 'GET'; SubPortal = 'mtp'; Path = '/x'
            ResponseShape = 'wrapper'; ItemsContainer = 'Results'
            IngestionMode = 'CURSOR'; CursorField = 'EventTime'; NaturalKey = @('ActionId')
            TimeFilter = @{ FieldName = 'EventTime'; Mode = 'ClientSideHighWater' }
            # PageSize=1 → every data page is a FULL page → pageIndexIncrement keeps paging until an empty page.
            # StopWhenCursorPassed=$true matches live Defender (descending sort · stop once a row <= the high-water is
            # seen). During the COLD backlog drain there is no high-water yet, so this never early-stops mid-drain;
            # it only kicks in on the re-poll AFTER the high-water is committed (proving the boundary still holds).
            Pagination = @{ Mode = 'pageSize'; PageSizeQuery = 'pageSize'; PageSize = 1; PageIndexQuery = 'pageIndex'; PageIndexStart = 1; CursorMode = 'pageIndexIncrement'; LoopGuard = 1000; SortByQuery = 'sortByField'; SortByField = 'EventTime'; SortOrderQuery = 'sortOrder'; SortOrder = 'Descending'; StopWhenCursorPassed = $true }
            ProjectionMap = @{ EventTime = '$.EventTime'; ActionId = '$.ActionId' }
            DcrImmutableId = 'dcr-test'; DcrStreamName = 'Custom-Defender_Operations_CL'
        }

        $global:XdrResumeIngested.Clear()
        $global:XdrResumePagesRequested.Clear()
        # Cold start · no cursor · no resume.
        $global:XdrResumeCheckpoint = @{ OperationKey = 'ResumeOp'; Cursor = $null; BoundaryKeys = $null; ResumePage = $null; ResumeCursor = $null; ResumeHighWater = $null; ResumeBoundaryKeys = $null; ETag = $null }

        Mock -ModuleName Xdr.Common.Runtime Connect-XdrPortal { @{ Portal = 'Defender'; Sccauth = 'x'; XsrfToken = 'y' } }
        # Page-aware HTTP mock · parse the pageIndex out of the URL, return that page's single row (or empty).
        Mock -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp {
            $pi = 0
            if ($Url -match 'pageIndex=(\d+)') { $pi = [int]$Matches[1] }
            $global:XdrResumePagesRequested.Add($pi)
            # Build Results via a List<object>.ToArray() so it is ALWAYS a real object[] of the right length (0 or 1) —
            # the shape ConvertFrom-Json -AsHashtable yields in the real Invoke-XdrPortalHttp. A bare 1-element array
            # literal collapses to a scalar through the mock pipeline (the parser would then project the WRAPPER, not
            # the row → null typed cols) and an empty literal becomes $null (an empty page would parse as 1 row →
            # pagination never terminates). ToArray() sidesteps both.
            $arr = [System.Collections.Generic.List[object]]::new()
            if ($global:XdrResumePageRow.ContainsKey($pi)) { [void]$arr.Add($global:XdrResumePageRow[$pi]) }
            @{ StatusCode = 200; Body = @{ Results = $arr.ToArray() }; RawBody = '' }
        }
        Mock -ModuleName Xdr.Common.Runtime Get-XdrCheckpoint { $global:XdrResumeCheckpoint }
        # Persist the saved state back into the global so the next cycle resumes from it (the real Table round-trip).
        Mock -ModuleName Xdr.Common.Runtime Save-XdrCheckpointAtomic {
            $global:XdrResumeCheckpoint = @{
                OperationKey = $OperationKey; Cursor = $Cursor; BoundaryKeys = $BoundaryKeys
                ResumePage = $ResumePage; ResumeCursor = $ResumeCursor; ResumeHighWater = $ResumeHighWater; ResumeBoundaryKeys = $ResumeBoundaryKeys
                ETag = 'etag-next'
            }
            $true
        }
        Mock -ModuleName Xdr.Common.Runtime Send-ToDce {
            foreach ($r in $Rows) { $global:XdrResumeIngested.Add($r) }
            @{ Success = $true; RowsAccepted = @($Rows).Count; BytesIngested = 100 }
        }
        # G3 · grant the single-flight lease (real Blob-lease infra absent in unit tests · un-mocked acquire → $null →
        # would skip as 'contended'). Granting exercises the normal multi-cycle drain path.
        Mock -ModuleName Xdr.Common.Runtime Lock-XdrSingleFlight { 'lease-granted' }
        Mock -ModuleName Xdr.Common.Runtime Unlock-XdrSingleFlight { $true }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrEvent { }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrException { }
    }
    AfterEach { Remove-Item Env:\XDRLR_MAX_PAGES_PER_CYCLE -ErrorAction SilentlyContinue }

    It 'cycle 1 ingests the first budget of pages, marks the drain INCOMPLETE, and does NOT advance the high-water' {
        $r1 = Invoke-ResumeCycle -Cid 'rc1'
        $r1.Success | Should -BeTrue
        $r1.ItemCount | Should -Be 2                                   # pages 1+2 → {C5, C4}
        # V3 normalizes the per-cycle SEND order to ascending-by-cursor, so assert the SET ingested (the contract) —
        # not the incidental order — matching the order-insensitive pattern this file uses for the full-drain checks.
        (@($global:XdrResumeIngested | ForEach-Object { $_.ActionId }) | Sort-Object) | Should -Be @('C4','C5')
        # Cross-cycle high-water (Cursor) stays EMPTY — older rows C1..C3 are not yet fetched, so it must NOT jump.
        $global:XdrResumeCheckpoint.Cursor | Should -BeNullOrEmpty
        # Resume state is set mid-drain: next page = 3, and the PENDING high-water holds the running max (day 5).
        [int]$global:XdrResumeCheckpoint.ResumePage | Should -Be 3
        $global:XdrResumeCheckpoint.ResumeHighWater | Should -Match '2026-05-05'
    }

    It 'drains the WHOLE 5-row set across 3 cycles · EVERY row EXACTLY ONCE (no drop · no duplicate)' {
        $null = Invoke-ResumeCycle -Cid 'rc1'   # C5, C4   (incomplete)
        $null = Invoke-ResumeCycle -Cid 'rc2'   # C3, C2   (incomplete)
        $r3   = Invoke-ResumeCycle -Cid 'rc3'   # C1       (+ empty page → complete)
        $r3.Success | Should -BeTrue

        $ids = $global:XdrResumeIngested | ForEach-Object { $_.ActionId }
        # EXACTLY-ONCE: all five rows, no duplicate, no drop (order = the descending page order across cycles).
        @($ids).Count | Should -Be 5
        ($ids | Sort-Object) | Should -Be @('C1','C2','C3','C4','C5')
        ($ids | Select-Object -Unique).Count | Should -Be 5

        # Pages were requested CONTIGUOUSLY and NEVER re-fetched (resume continued · did not restart at page 1).
        # 6 requests total: pages 1,2 (c1) · 3,4 (c2) · 5 + the empty 6 (c3 · the natural terminator).
        @($global:XdrResumePagesRequested) | Should -Be @(1,2,3,4,5,6)
    }

    It 'the high-water (Cursor) advances to max(EventTime) ONLY when the drain completes · resume state CLEARED' {
        $null = Invoke-ResumeCycle -Cid 'rc1'
        $global:XdrResumeCheckpoint.Cursor | Should -BeNullOrEmpty       # still incomplete
        $null = Invoke-ResumeCycle -Cid 'rc2'
        $global:XdrResumeCheckpoint.Cursor | Should -BeNullOrEmpty       # still incomplete
        $r3 = Invoke-ResumeCycle -Cid 'rc3'                              # completes here

        # On completion the committed high-water = the pending running max (day 5 · the NEWEST row, from cycle 1).
        $global:XdrResumeCheckpoint.Cursor | Should -Match '2026-05-05'
        $global:XdrResumeCheckpoint.BoundaryKeys | Should -Be 'C5'
        # All resume state is cleared (empty), so the next CADENCE starts a fresh incremental from the high-water.
        [int]$global:XdrResumeCheckpoint.ResumePage | Should -Be 0
        $global:XdrResumeCheckpoint.ResumeCursor | Should -BeNullOrEmpty
        $global:XdrResumeCheckpoint.ResumeHighWater | Should -BeNullOrEmpty
        $global:XdrResumeCheckpoint.ResumeBoundaryKeys | Should -BeNullOrEmpty
    }

    It 'after a completed drain, re-polling the SAME data ingests ZERO (the exactly-once boundary still holds)' {
        $null = Invoke-ResumeCycle -Cid 'rc1'
        $null = Invoke-ResumeCycle -Cid 'rc2'
        $null = Invoke-ResumeCycle -Cid 'rc3'   # drain complete · Cursor = day 5 · resume cleared
        $global:XdrResumeIngested.Clear()
        $global:XdrResumePagesRequested.Clear()

        # Next cadence · fresh incremental from page 1 · the same 5 rows are all <= the day-5 high-water.
        # C5 is the boundary tie (its key C5 is in BoundaryKeys) → dropped; C1..C4 are older → dropped. ZERO ingest.
        $r = Invoke-ResumeCycle -Cid 'rc4'
        $r.Success | Should -BeTrue
        $r.ItemCount | Should -Be 0
        @($global:XdrResumeIngested).Count | Should -Be 0
    }

    It 'a per-cycle budget overrun NEVER throws (graceful resume · not loopGuard DLQ)' {
        # The whole point of U1: a result set bigger than one cycle can hold must DEGRADE to resume, never fault.
        $r1 = Invoke-ResumeCycle -Cid 'rc1'
        $r1.Success | Should -BeTrue
        $r1.ErrorClass | Should -BeNullOrEmpty
        $r1.ErrorMessage | Should -BeNullOrEmpty
    }
}

Describe 'U1 · resumable SNAPSHOT drain · full re-emit across cycles (SnapshotReEmit preserved at volume)' {
    # A SNAPSHOT op has NO high-water — it re-emits the whole current-state set each CADENCE. When that set is
    # bigger than one cycle's budget it must still drain FULLY across cycles (position-only resume), then re-start
    # the whole snapshot on the next cadence. No boundary dedup is involved (the SnapshotReEmit invariant holds).
    BeforeEach {
        $env:XDRLR_MAX_PAGES_PER_CYCLE = '2'

        $script:SnapResumeEntry = @{
            OperationKey = 'SnapResumeOp'; Portal = 'Defender'; Category = 'Operations'; Method = 'GET'; SubPortal = 'mtp'; Path = '/x'
            ResponseShape = 'wrapper'; ItemsContainer = 'Results'
            IngestionMode = 'SNAPSHOT'
            Pagination = @{ Mode = 'pageSize'; PageSizeQuery = 'pageSize'; PageSize = 1; PageIndexQuery = 'pageIndex'; PageIndexStart = 1; CursorMode = 'pageIndexIncrement'; LoopGuard = 1000 }
            ProjectionMap = @{ EventTime = '$.EventTime'; ActionId = '$.ActionId' }
            DcrImmutableId = 'dcr-test'; DcrStreamName = 'Custom-Defender_Operations_CL'
        }

        $global:XdrResumeIngested.Clear()
        $global:XdrResumePagesRequested.Clear()
        $global:XdrResumeCheckpoint = @{ OperationKey = 'SnapResumeOp'; Cursor = $null; BoundaryKeys = $null; ResumePage = $null; ResumeCursor = $null; ResumeHighWater = $null; ResumeBoundaryKeys = $null; ETag = $null }

        Mock -ModuleName Xdr.Common.Runtime Connect-XdrPortal { @{ Portal = 'Defender'; Sccauth = 'x'; XsrfToken = 'y' } }
        Mock -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp {
            $pi = 0
            if ($Url -match 'pageIndex=(\d+)') { $pi = [int]$Matches[1] }
            $global:XdrResumePagesRequested.Add($pi)
            # Build Results via a List<object>.ToArray() so it is ALWAYS a real object[] of the right length (0 or 1) —
            # the shape ConvertFrom-Json -AsHashtable yields in the real Invoke-XdrPortalHttp. A bare 1-element array
            # literal collapses to a scalar through the mock pipeline (the parser would then project the WRAPPER, not
            # the row → null typed cols) and an empty literal becomes $null (an empty page would parse as 1 row →
            # pagination never terminates). ToArray() sidesteps both.
            $arr = [System.Collections.Generic.List[object]]::new()
            if ($global:XdrResumePageRow.ContainsKey($pi)) { [void]$arr.Add($global:XdrResumePageRow[$pi]) }
            @{ StatusCode = 200; Body = @{ Results = $arr.ToArray() }; RawBody = '' }
        }
        Mock -ModuleName Xdr.Common.Runtime Get-XdrCheckpoint { $global:XdrResumeCheckpoint }
        Mock -ModuleName Xdr.Common.Runtime Save-XdrCheckpointAtomic {
            $global:XdrResumeCheckpoint = @{
                OperationKey = $OperationKey; Cursor = $Cursor; BoundaryKeys = $BoundaryKeys
                ResumePage = $ResumePage; ResumeCursor = $ResumeCursor; ResumeHighWater = $ResumeHighWater; ResumeBoundaryKeys = $ResumeBoundaryKeys
                ETag = 'etag-next'
            }
            $true
        }
        Mock -ModuleName Xdr.Common.Runtime Send-ToDce {
            foreach ($r in $Rows) { $global:XdrResumeIngested.Add($r) }
            @{ Success = $true; RowsAccepted = @($Rows).Count; BytesIngested = 100 }
        }
        # G3 · grant the single-flight lease (real Blob-lease infra absent in unit tests · un-mocked acquire → $null →
        # would skip as 'contended'). Granting exercises the normal multi-cycle drain path.
        Mock -ModuleName Xdr.Common.Runtime Lock-XdrSingleFlight { 'lease-granted' }
        Mock -ModuleName Xdr.Common.Runtime Unlock-XdrSingleFlight { $true }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrEvent { }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrException { }
    }
    AfterEach { Remove-Item Env:\XDRLR_MAX_PAGES_PER_CYCLE -ErrorAction SilentlyContinue }

    It 'cycle 1 stops at the budget with ResumePage set · NO high-water (SNAPSHOT has none)' {
        $r1 = Invoke-XdrEntryPoll -Entry $script:SnapResumeEntry -CorrelationId 'sr1'
        $r1.ItemCount | Should -Be 2
        [int]$global:XdrResumeCheckpoint.ResumePage | Should -Be 3
        $global:XdrResumeCheckpoint.Cursor | Should -BeNullOrEmpty           # SNAPSHOT never derives a high-water
        $global:XdrResumeCheckpoint.ResumeHighWater | Should -BeNullOrEmpty   # no CursorField → no pending high-water
    }

    It 'drains the FULL snapshot across cycles (all 5 rows · each once) then CLEARS resume on completion' {
        $null = Invoke-XdrEntryPoll -Entry $script:SnapResumeEntry -CorrelationId 'sr1'
        $null = Invoke-XdrEntryPoll -Entry $script:SnapResumeEntry -CorrelationId 'sr2'
        $null = Invoke-XdrEntryPoll -Entry $script:SnapResumeEntry -CorrelationId 'sr3'
        $ids = $global:XdrResumeIngested | ForEach-Object { $_.ActionId }
        ($ids | Sort-Object) | Should -Be @('C1','C2','C3','C4','C5')
        [int]$global:XdrResumeCheckpoint.ResumePage | Should -Be 0   # cleared → next cadence re-emits the whole set
    }
}
