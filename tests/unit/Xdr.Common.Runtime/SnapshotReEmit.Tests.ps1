#Requires -Version 7.4
# SNAPSHOT re-emit proof (G-L · plan §35). The MIRROR-OPPOSITE of ExactlyOnce.Tests.ps1 (which proves CURSOR
# de-duplicates at the boundary): a SNAPSHOT op is a CURRENT-STATE poll with NO time cursor, so it MUST re-emit
# ALL rows EVERY cycle with NO dedup / NO boundary drop. Two layers of proof:
#   (1) UNIT · Resolve-XdrTimeWindow SNAPSHOT → HighWaterUtc null (+ StartUtc/EndUtc null · one cycle drains all).
#   (2) END-TO-END · drive the REAL Invoke-XdrEntryPoll (I/O mocked like ExactlyOnce) across 2 simulated cycles
#       with the SAME rows; assert BOTH cycles ingest the full set (no row dropped on cycle 2 · the CURSOR test's
#       cycle-2 ingests ZERO · this is the deliberate opposite).

BeforeAll {
    $script:Repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $psd1s = Get-ChildItem (Join-Path $script:Repo 'src\Modules') -Directory |
        ForEach-Object { Join-Path $_.FullName ($_.Name + '.psd1') } | Where-Object { Test-Path $_ }
    for ($pass = 1; $pass -le 4; $pass++) {
        foreach ($p in $psd1s) { try { Import-Module $p -Force -DisableNameChecking -ErrorAction Stop } catch { } }
    }

    function New-AcRow([string]$id, [string]$time) { @{ ActionId = $id; EventTime = $time } }

    # A genuine SNAPSHOT op: IngestionMode=SNAPSHOT · NO CursorField · NO NaturalKey · no StopWhenCursorPassed.
    # (A current-state poll has no high-water field — the whole result set is the current state each cycle.)
    $script:SnapEntry = @{
        OperationKey = 'SnapshotOp'; Portal = 'Defender'; Category = 'Operations'; Method = 'GET'; SubPortal = 'mtp'; Path = '/x'
        ResponseShape = 'wrapper'; ItemsContainer = 'Results'
        IngestionMode = 'SNAPSHOT'
        Pagination = @{ Mode = 'pageSize'; PageSizeQuery = 'pageSize'; PageSize = 500; PageIndexQuery = 'pageIndex'; CursorMode = 'pageIndexIncrement'; LoopGuard = 1000 }
        ProjectionMap = @{ EventTime = '$.EventTime'; ActionId = '$.ActionId' }
        DcrImmutableId = 'dcr-test'; DcrStreamName = 'Custom-Defender_Operations_CL'
    }

    $env:XDRLR_DCE_ENDPOINT = 'https://dce-test.local'

    $global:XdrTestHttpRows = @()
    $global:XdrTestCheckpoint = @{ OperationKey = 'SnapshotOp'; Cursor = $null; BoundaryKeys = $null; WindowStartUtc = $null; WindowEndUtc = $null; LastUpdatedUtc = $null; LastItemCount = 0; ETag = $null }
}

Describe 'SNAPSHOT time-window · no high-water (plan §35)' {
    It 'Resolve-XdrTimeWindow SNAPSHOT returns HighWaterUtc null + StartUtc/EndUtc null (cold checkpoint)' {
        InModuleScope Xdr.Common.Runtime {
            $entry = @{ OperationKey = 'SnapshotOp'; IngestionMode = 'SNAPSHOT' }
            $cp = @{ Cursor = $null; WindowEndUtc = $null }
            $w = Resolve-XdrTimeWindow -Entry $entry -Checkpoint $cp
            $w.HighWaterUtc | Should -BeNullOrEmpty
            $w.StartUtc     | Should -BeNullOrEmpty
            $w.EndUtc       | Should -BeNullOrEmpty
            $w.Exhausted    | Should -BeFalse
        }
    }
    It 'SNAPSHOT IGNORES a populated checkpoint cursor (still no high-water · re-emits all)' {
        # Even if a prior cycle left a cursor on the row, SNAPSHOT must NOT derive a high-water from it (that would
        # start dropping rows · turning a current-state poll into an incremental one). HighWaterUtc stays null.
        InModuleScope Xdr.Common.Runtime {
            $entry = @{ OperationKey = 'SnapshotOp'; IngestionMode = 'SNAPSHOT' }
            $cp = @{ Cursor = '2026-05-03T00:00:00Z'; WindowEndUtc = '2026-05-03T00:00:00Z' }
            $w = Resolve-XdrTimeWindow -Entry $entry -Checkpoint $cp
            $w.HighWaterUtc | Should -BeNullOrEmpty
            $w.StartUtc     | Should -BeNullOrEmpty
        }
    }
}

Describe 'SNAPSHOT re-emit · ALL rows every cycle · NO boundary dedup (mirror-opposite of CURSOR)' {
    BeforeEach {
        Mock -ModuleName Xdr.Common.Runtime Connect-XdrPortal { @{ Portal = 'Defender'; Sccauth = 'x'; XsrfToken = 'y' } }
        Mock -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp { @{ StatusCode = 200; Body = @{ Count = @($global:XdrTestHttpRows).Count; Results = $global:XdrTestHttpRows }; RawBody = '' } }
        Mock -ModuleName Xdr.Common.Runtime Get-XdrCheckpoint { $global:XdrTestCheckpoint }
        Mock -ModuleName Xdr.Common.Runtime Save-XdrCheckpointAtomic { $true }
        Mock -ModuleName Xdr.Common.Runtime Send-ToDce { @{ Success = $true; RowsAccepted = @($Rows).Count; BytesIngested = 100 } }
        # G3 · grant the single-flight lease (real Blob-lease infra absent in unit tests · un-mocked acquire → $null
        # → would skip as 'contended'). Granting exercises the normal SNAPSHOT re-emit path.
        Mock -ModuleName Xdr.Common.Runtime Lock-XdrSingleFlight { 'lease-granted' }
        Mock -ModuleName Xdr.Common.Runtime Unlock-XdrSingleFlight { $true }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrEvent { }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrException { }
    }

    It 'cycle 1 (cold) ingests ALL rows' {
        $global:XdrTestCheckpoint = @{ OperationKey = 'SnapshotOp'; Cursor = $null; BoundaryKeys = $null; ETag = $null }
        $global:XdrTestHttpRows = @((New-AcRow 'K1' '2026-05-01T00:00:00Z'), (New-AcRow 'K2' '2026-05-02T00:00:00Z'), (New-AcRow 'K3' '2026-05-03T00:00:00Z'))
        $r = Invoke-XdrEntryPoll -Entry $script:SnapEntry -CorrelationId 's1'
        $r.Success   | Should -BeTrue
        $r.ItemCount | Should -Be 3
        Should -Invoke -ModuleName Xdr.Common.Runtime Send-ToDce -Times 1 -Exactly -ParameterFilter { @($Rows).Count -eq 3 }
    }

    It 'cycle 2 (same rows · simulated prior checkpoint) RE-EMITS all 3 rows · ZERO dropped (the CURSOR test drops them)' {
        # Simulate the state a SNAPSHOT op carries into the next cycle. A SNAPSHOT poll persists no high-water (no
        # CursorField), so the cursor stays empty; re-running over the identical current-state set must ingest ALL 3
        # again. This is the deliberate inverse of CURSOR (ExactlyOnce.Tests.ps1 cycle-2 ingests 0).
        $global:XdrTestCheckpoint = @{ OperationKey = 'SnapshotOp'; Cursor = $null; BoundaryKeys = $null; ETag = 'e1'; LastUpdatedUtc = '2026-05-03T00:00:01Z'; LastItemCount = 3 }
        $global:XdrTestHttpRows = @((New-AcRow 'K1' '2026-05-01T00:00:00Z'), (New-AcRow 'K2' '2026-05-02T00:00:00Z'), (New-AcRow 'K3' '2026-05-03T00:00:00Z'))
        $r = Invoke-XdrEntryPoll -Entry $script:SnapEntry -CorrelationId 's2'
        $r.Success   | Should -BeTrue
        $r.ItemCount | Should -Be 3
        Should -Invoke -ModuleName Xdr.Common.Runtime Send-ToDce -Times 1 -Exactly -ParameterFilter { @($Rows).Count -eq 3 }
    }

    It 'a SNAPSHOT cycle NEVER emits the boundary-dedup telemetry (no rows dropped at any boundary)' {
        $global:XdrTestCheckpoint = @{ OperationKey = 'SnapshotOp'; Cursor = $null; BoundaryKeys = $null; ETag = 'e1' }
        $global:XdrTestHttpRows = @((New-AcRow 'K1' '2026-05-01T00:00:00Z'), (New-AcRow 'K2' '2026-05-02T00:00:00Z'))
        $null = Invoke-XdrEntryPoll -Entry $script:SnapEntry -CorrelationId 's3'
        Should -Invoke -ModuleName Xdr.Common.Runtime Track-XdrEvent -Times 0 -Exactly -ParameterFilter { $Name -eq 'Entry.Poll.BoundaryDeduped' }
    }

    It 'keyless SNAPSHOT op gets a content-hash RecordId — never empty, distinct content -> distinct, deterministic across cycles (2026-06-18 keyless-fix)' {
        # A SNAPSHOT op with NO NaturalKey would otherwise get an EMPTY RecordId -> un-dedupable dup-accumulation
        # (live-caught: SecureScore GetInsights 24,300 rows / empty RecordId / 1 distinct). The runtime now derives
        # RecordId from a content-hash of RawJson, so every keyless row has a STABLE, dedupable identity. The
        # cross-cycle-determinism assertion is the load-bearing one: it is WHY the dedup works (same content every
        # cycle -> same RecordId -> query latest-per-RecordId collapses the re-emits).
        $global:XdrTestCheckpoint = @{ OperationKey = 'SnapshotOp'; Cursor = $null; BoundaryKeys = $null; ETag = $null }
        $global:XdrTestHttpRows = @((New-AcRow 'K1' '2026-05-01T00:00:00Z'), (New-AcRow 'K2' '2026-05-02T00:00:00Z'))
        Mock -ModuleName Xdr.Common.Runtime Send-ToDce { $global:XdrCapturedRows = @($Rows); @{ Success = $true; RowsAccepted = @($Rows).Count; BytesIngested = 100 } }
        $null = Invoke-XdrEntryPoll -Entry $script:SnapEntry -CorrelationId 'sk1'
        $cycle1 = @($global:XdrCapturedRows)
        $cycle1.Count | Should -Be 2
        foreach ($row in $cycle1) { ([string]$row['RecordId']) | Should -Not -BeNullOrEmpty }
        $cycle1[0]['RecordId'] | Should -Not -Be $cycle1[1]['RecordId']
        $null = Invoke-XdrEntryPoll -Entry $script:SnapEntry -CorrelationId 'sk2'
        $cycle2 = @($global:XdrCapturedRows)
        $c1 = (($cycle1 | ForEach-Object { [string]$_['RecordId'] }) | Sort-Object) -join ','
        $c2 = (($cycle2 | ForEach-Object { [string]$_['RecordId'] }) | Sort-Object) -join ','
        $c2 | Should -Be $c1
    }
}
