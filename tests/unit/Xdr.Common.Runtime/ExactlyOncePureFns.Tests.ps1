#Requires -Version 7.4
# DIRECT table-tests for the two PURE exactly-once decision functions lifted out of Invoke-XdrEntryPoll
# (plan §35.2 + §16 U1): Select-XdrExactlyOnceRows (boundary de-dup) and Get-XdrAdvancedFrontier (high-water +
# boundary accumulation · resume-aware), plus the G2 precision helper Get-XdrCursorAtPrecision. These exercise the
# decision logic with DATA only (no auth/HTTP/DCE/checkpoint mocks) so the exactly-once contract is pinned in
# isolation, complementing the end-to-end ExactlyOnce/ResumablePagination proofs.

BeforeAll {
    $script:Repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $psd1s = Get-ChildItem (Join-Path $script:Repo 'src\Modules') -Directory |
        ForEach-Object { Join-Path $_.FullName ($_.Name + '.psd1') } | Where-Object { Test-Path $_ }
    for ($pass = 1; $pass -le 4; $pass++) {
        foreach ($p in $psd1s) { try { Import-Module $p -Force -DisableNameChecking -ErrorAction Stop } catch { } }
    }

    function New-Row([string]$id, [string]$time) { @{ ActionId = $id; EventTime = $time } }
    function New-InsightRow([string]$rid, [string]$created) { @{ RecordId = $rid; createdDate = $created } }   # keyless-CURSOR row (content-hash RecordId · bucketed-date cursor)
    function RIds($list) { @($list | ForEach-Object { $_.RecordId }) }
    function New-KeySet([string[]]$keys) {
        $s = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($k in $keys) { if ($k) { [void]$s.Add($k) } }
        return $s
    }
    # Convenience: the ingested ActionIds, in order.
    function Ids($list) { @($list | ForEach-Object { $_.ActionId }) }
}

Describe 'Select-XdrExactlyOnceRows · boundary de-dup (pure · plan §35.2)' {
    It 'cold start (no high-water) keeps ALL rows' {
        $rows = @((New-Row 'K1' '2026-05-01T00:00:00Z'), (New-Row 'K2' '2026-05-02T00:00:00Z'), (New-Row 'K3' '2026-05-03T00:00:00Z'))
        $out = Select-XdrExactlyOnceRows -Rows $rows -HighWaterUtc $null -CursorField 'EventTime' -NaturalKey @('ActionId') -PriorKeys (New-KeySet @())
        @($out).Count | Should -Be 3
        (Ids $out) | Should -Be @('K1','K2','K3')
    }

    It 'no CursorField keeps ALL rows (nothing to compare)' {
        $rows = @((New-Row 'K1' '2026-05-01T00:00:00Z'), (New-Row 'K2' '2026-05-02T00:00:00Z'))
        $hw = [DateTime]::Parse('2026-05-10T00:00:00Z').ToUniversalTime()
        $out = Select-XdrExactlyOnceRows -Rows $rows -HighWaterUtc $hw -CursorField '' -NaturalKey @('ActionId') -PriorKeys (New-KeySet @())
        @($out).Count | Should -Be 2
    }

    It 'drops rows OLDER than the high-water; keeps NEWER' {
        $rows = @((New-Row 'OLD' '2026-05-01T00:00:00Z'), (New-Row 'NEW' '2026-05-09T00:00:00Z'))
        $hw = [DateTime]::Parse('2026-05-05T00:00:00Z').ToUniversalTime()
        $out = Select-XdrExactlyOnceRows -Rows $rows -HighWaterUtc $hw -CursorField 'EventTime' -NaturalKey @('ActionId') -PriorKeys (New-KeySet @())
        (Ids $out) | Should -Be @('NEW')
    }

    It 'a boundary tie whose key was already ingested is DROPPED; an unseen tie is KEPT' {
        $hw = [DateTime]::Parse('2026-05-03T00:00:00Z').ToUniversalTime()
        $rows = @((New-Row 'K3' '2026-05-03T00:00:00Z'), (New-Row 'K3b' '2026-05-03T00:00:00Z'))
        $out = Select-XdrExactlyOnceRows -Rows $rows -HighWaterUtc $hw -CursorField 'EventTime' -NaturalKey @('ActionId') -PriorKeys (New-KeySet @('K3'))
        (Ids $out) | Should -Be @('K3b')   # K3 already seen → dropped; K3b new → kept
    }

    It 're-poll of the SAME data (all <= hw, all keys seen) ingests ZERO' {
        $hw = [DateTime]::Parse('2026-05-03T00:00:00Z').ToUniversalTime()
        $rows = @((New-Row 'K1' '2026-05-01T00:00:00Z'), (New-Row 'K2' '2026-05-02T00:00:00Z'), (New-Row 'K3' '2026-05-03T00:00:00Z'))
        $out = Select-XdrExactlyOnceRows -Rows $rows -HighWaterUtc $hw -CursorField 'EventTime' -NaturalKey @('ActionId') -PriorKeys (New-KeySet @('K3'))
        @($out).Count | Should -Be 0
    }

    # F-BOUNDARY (live-proven 2026-06-12 · GetHistory boundary ActionId re-ingested once per degraded cycle).
    # The boundary-tie default must be DROP (already-ingested), rescuing ONLY a provably-new same-timestamp row.
    It 'F-BOUNDARY · a keyed boundary tie with an EMPTY boundary-key set is DROPPED (degraded · was the live dup)' {
        $hw = [DateTime]::Parse('2026-05-06T01:51:53.7605698Z').ToUniversalTime()
        $rows = @((New-Row 'f9e95be6' '2026-05-06T01:51:53.7605698Z'))   # the exact live boundary action
        $out = Select-XdrExactlyOnceRows -Rows $rows -HighWaterUtc $hw -CursorField 'EventTime' -NaturalKey @('ActionId') -PriorKeys (New-KeySet @())
        @($out).Count | Should -Be 0   # PRE-FIX this returned 1 (the re-emitted duplicate)
    }
    It 'F-BOUNDARY · a keyed boundary tie with a NULL boundary-key set is DROPPED (no method-on-null throw)' {
        $hw = [DateTime]::Parse('2026-05-06T01:51:53.7605698Z').ToUniversalTime()
        $rows = @((New-Row 'f9e95be6' '2026-05-06T01:51:53.7605698Z'))
        $out = Select-XdrExactlyOnceRows -Rows $rows -HighWaterUtc $hw -CursorField 'EventTime' -NaturalKey @('ActionId') -PriorKeys $null
        @($out).Count | Should -Be 0
    }
    It 'F-BOUNDARY · a provably-NEW same-timestamp row (populated set lacking its key) is still RESCUED (no loss)' {
        $hw = [DateTime]::Parse('2026-05-06T01:51:53.7605698Z').ToUniversalTime()
        $rows = @((New-Row 'NEW_SAME_TS' '2026-05-06T01:51:53.7605698Z'))
        $out = Select-XdrExactlyOnceRows -Rows $rows -HighWaterUtc $hw -CursorField 'EventTime' -NaturalKey @('ActionId') -PriorKeys (New-KeySet @('SOME_OTHER_KEY'))
        (Ids $out) | Should -Be @('NEW_SAME_TS')
    }

    It 'an unparseable/absent cursor field on a row is KEPT (fail-safe)' {
        $hw = [DateTime]::Parse('2026-05-05T00:00:00Z').ToUniversalTime()
        $rows = @((New-Row 'GOOD' '2026-05-09T00:00:00Z'), @{ ActionId = 'NODATE' }, (New-Row 'BADDATE' 'not-a-date'))
        $out = Select-XdrExactlyOnceRows -Rows $rows -HighWaterUtc $hw -CursorField 'EventTime' -NaturalKey @('ActionId') -PriorKeys (New-KeySet @())
        (Ids $out | Sort-Object) | Should -Be @('BADDATE','GOOD','NODATE')
    }

    It 'no NaturalKey → boundary ties are ALWAYS kept (empty composite key)' {
        $hw = [DateTime]::Parse('2026-05-03T00:00:00Z').ToUniversalTime()
        $rows = @((New-Row 'A' '2026-05-03T00:00:00Z'), (New-Row 'B' '2026-05-03T00:00:00Z'))
        $out = Select-XdrExactlyOnceRows -Rows $rows -HighWaterUtc $hw -CursorField 'EventTime' -NaturalKey @() -PriorKeys (New-KeySet @())
        @($out).Count | Should -Be 2
    }

    It 'returns a List even for an empty result (not $null · StrictMode .Count safe)' {
        $hw = [DateTime]::Parse('2026-05-03T00:00:00Z').ToUniversalTime()
        $rows = @((New-Row 'K3' '2026-05-03T00:00:00Z'))
        $out = Select-XdrExactlyOnceRows -Rows $rows -HighWaterUtc $hw -CursorField 'EventTime' -NaturalKey @('ActionId') -PriorKeys (New-KeySet @('K3'))
        # Comma-protect so the assertion sees the List object itself (a bare empty List unrolls to nothing in the
        # pipeline). The real contract the caller relies on: it is the concrete List type and .Count is callable.
        (, $out) | Should -BeOfType ([System.Collections.Generic.List[hashtable]])
        $out.Count | Should -Be 0   # would THROW under StrictMode if $null was returned
    }

    It 'empty input rows → empty List' {
        $out = Select-XdrExactlyOnceRows -Rows @() -HighWaterUtc $null -CursorField 'EventTime' -NaturalKey @('ActionId') -PriorKeys (New-KeySet @())
        $out.Count | Should -Be 0
    }
}

Describe 'Get-XdrCursorAtPrecision · G2 precision normalization (pure)' {
    It 'default (empty precision) returns the value UNCHANGED (exact · back-compat)' {
        $v = [DateTime]::Parse('2026-05-03T01:02:03.1234567Z').ToUniversalTime()
        (Get-XdrCursorAtPrecision -Value $v) | Should -Be $v
        (Get-XdrCursorAtPrecision -Value $v -Precision '') | Should -Be $v
        (Get-XdrCursorAtPrecision -Value $v -Precision 'Ticks') | Should -Be $v
    }
    It "'Second' collapses sub-second jitter to the same instant" {
        $a = [DateTime]::Parse('2026-05-03T01:02:03.100Z').ToUniversalTime()
        $b = [DateTime]::Parse('2026-05-03T01:02:03.900Z').ToUniversalTime()
        (Get-XdrCursorAtPrecision -Value $a -Precision 'Second') | Should -Be (Get-XdrCursorAtPrecision -Value $b -Precision 'Second')
    }
    It "'Millisecond' truncates ticks below 1ms" {
        $v = [DateTime]::Parse('2026-05-03T01:02:03.1239999Z').ToUniversalTime()
        $r = Get-XdrCursorAtPrecision -Value $v -Precision 'Millisecond'
        $r.Millisecond | Should -Be 123
        ($r.Ticks % [TimeSpan]::TicksPerMillisecond) | Should -Be 0
    }
    It 'an unknown precision token falls back to exact (never widens unexpectedly)' {
        $v = [DateTime]::Parse('2026-05-03T01:02:03.1234567Z').ToUniversalTime()
        (Get-XdrCursorAtPrecision -Value $v -Precision 'fortnight') | Should -Be $v
    }
}

Describe 'Select-XdrExactlyOnceRows · G2 CursorPrecision boundary (pure)' {
    It 'a boundary row that reappears at COARSER sub-second precision is still DROPPED (not duplicated, not lost)' {
        # Committed high-water = 2026-05-03T00:00:00.500Z, key K3 already ingested. The row reappears with a slightly
        # different sub-second component (…​.499) — at exact precision it would be < hw (older) and KEPT (re-ingest =
        # duplicate) OR at a finer reading mismatch. At Second precision it collapses to the SAME instant as the
        # high-water → treated as a boundary tie → its already-seen key K3 drops it. EXACTLY-ONCE preserved.
        $hw = [DateTime]::Parse('2026-05-03T00:00:00.500Z').ToUniversalTime()
        $rows = @((New-Row 'K3' '2026-05-03T00:00:00.499Z'))
        $out = Select-XdrExactlyOnceRows -Rows $rows -HighWaterUtc $hw -CursorField 'EventTime' -NaturalKey @('ActionId') -PriorKeys (New-KeySet @('K3')) -CursorPrecision 'Second'
        @($out).Count | Should -Be 0
    }
    It 'at Second precision a NEW key at the same second still ingests once (tie kept · not over-dropped)' {
        $hw = [DateTime]::Parse('2026-05-03T00:00:00.500Z').ToUniversalTime()
        $rows = @((New-Row 'K3' '2026-05-03T00:00:00.499Z'), (New-Row 'K9' '2026-05-03T00:00:00.999Z'))
        $out = Select-XdrExactlyOnceRows -Rows $rows -HighWaterUtc $hw -CursorField 'EventTime' -NaturalKey @('ActionId') -PriorKeys (New-KeySet @('K3')) -CursorPrecision 'Second'
        (Ids $out) | Should -Be @('K9')
    }
    It 'WITHOUT precision (exact · default) the same reappearing coarser row is treated as older → dropped too (older < hw)' {
        # Sanity: at exact precision ….499 < ….500 so it is OLDER → dropped as already-ingested. (The precision guard
        # matters for the case where jitter pushes the value ABOVE the stored hw; here we just confirm exact still drops.)
        $hw = [DateTime]::Parse('2026-05-03T00:00:00.500Z').ToUniversalTime()
        $rows = @((New-Row 'K3' '2026-05-03T00:00:00.499Z'))
        $out = Select-XdrExactlyOnceRows -Rows $rows -HighWaterUtc $hw -CursorField 'EventTime' -NaturalKey @('ActionId') -PriorKeys (New-KeySet @('K3'))
        @($out).Count | Should -Be 0
    }
    It 'precision guard catches an UPWARD-jittered boundary tie that exact precision would re-ingest' {
        # hw stored at …​.500; the same logical event reappears at …​.501 (clock jitter / coarser server rounding). At
        # EXACT precision …​.501 > …​.500 → it is NEWER → KEPT → DUPLICATE. At Second precision both collapse to the same
        # second → boundary tie → already-seen key K3 → DROPPED. This is the real exactly-once hole G2 closes.
        $hw = [DateTime]::Parse('2026-05-03T00:00:00.500Z').ToUniversalTime()
        $rows = @((New-Row 'K3' '2026-05-03T00:00:00.501Z'))
        $exact = Select-XdrExactlyOnceRows -Rows $rows -HighWaterUtc $hw -CursorField 'EventTime' -NaturalKey @('ActionId') -PriorKeys (New-KeySet @('K3'))
        @($exact).Count | Should -Be 1   # exact precision RE-INGESTS (the hole)
        $guarded = Select-XdrExactlyOnceRows -Rows $rows -HighWaterUtc $hw -CursorField 'EventTime' -NaturalKey @('ActionId') -PriorKeys (New-KeySet @('K3')) -CursorPrecision 'Second'
        @($guarded).Count | Should -Be 0   # Second precision DROPS it (exactly-once preserved)
    }
}

Describe 'Get-XdrAdvancedFrontier · high-water + boundary accumulation (pure · plan §35.2 + §16 U1)' {
    It 'COMPLETE drain promotes max(CursorField) to NextCursor + its key as NextBoundaryKeys; resume cleared' {
        $ingest = @((New-Row 'K1' '2026-05-01T00:00:00Z'), (New-Row 'K2' '2026-05-02T00:00:00Z'), (New-Row 'K3' '2026-05-03T00:00:00Z'))
        $f = Get-XdrAdvancedFrontier -Baseline '' -IngestRows $ingest -DrainComplete $true -CursorField 'EventTime' -NaturalKey @('ActionId') -AccumKeys @() -HasCheckpoint $false
        $f['NextCursor'] | Should -Match '2026-05-03'
        $f['NextBoundaryKeys'] | Should -Be 'K3'
        $f['ResumeHighWater'] | Should -Be ''
        $f['ResumeBoundaryKeys'] | Should -Be ''
    }

    It 'a NEW same-timestamp tie ACCUMULATES the boundary set against the baseline (K3 + K3b)' {
        # Baseline hw = 2026-05-03 with prior key K3. Newly ingested K3b at the SAME timestamp → the set becomes {K3,K3b}
        # so K3 can never re-ingest. (The running max does NOT advance past the baseline → baseline keys accumulate.)
        $ingest = @((New-Row 'K3b' '2026-05-03T00:00:00Z'))
        $f = Get-XdrAdvancedFrontier -Baseline '2026-05-03T00:00:00Z' -IngestRows $ingest -DrainComplete $true -CursorField 'EventTime' -NaturalKey @('ActionId') -AccumKeys @('K3') -HasCheckpoint $true -CommittedCursor '2026-05-03T00:00:00Z' -CommittedBoundaryKeys 'K3'
        $f['NextCursor'] | Should -Match '2026-05-03'
        $f['NextBoundaryKeys'] | Should -Be 'K3,K3b'
    }

    It 'when the max ADVANCES past the baseline the boundary set is FRESH (only the new max key)' {
        $ingest = @((New-Row 'K4' '2026-05-04T00:00:00Z'))
        $f = Get-XdrAdvancedFrontier -Baseline '2026-05-03T00:00:00Z' -IngestRows $ingest -DrainComplete $true -CursorField 'EventTime' -NaturalKey @('ActionId') -AccumKeys @('K3') -HasCheckpoint $true -CommittedCursor '2026-05-03T00:00:00Z' -CommittedBoundaryKeys 'K3'
        $f['NextCursor'] | Should -Match '2026-05-04'
        $f['NextBoundaryKeys'] | Should -Be 'K4'   # NOT K3,K4 — the max moved, the set is fresh
    }

    It 'NOTHING ingested → preserves the baseline high-water + baseline keys (no advance)' {
        $f = Get-XdrAdvancedFrontier -Baseline '2026-05-03T00:00:00Z' -IngestRows @() -DrainComplete $true -CursorField 'EventTime' -NaturalKey @('ActionId') -AccumKeys @('K3') -HasCheckpoint $true -CommittedCursor '2026-05-03T00:00:00Z' -CommittedBoundaryKeys 'K3'
        $f['NextCursor'] | Should -Be '2026-05-03T00:00:00Z'
        $f['NextBoundaryKeys'] | Should -Be 'K3'
    }

    It 'INCOMPLETE drain does NOT advance the committed Cursor; stashes the running max in Resume*' {
        $ingest = @((New-Row 'C5' '2026-05-05T00:00:00Z'), (New-Row 'C4' '2026-05-04T00:00:00Z'))
        $f = Get-XdrAdvancedFrontier -Baseline '' -IngestRows $ingest -DrainComplete $false -CursorField 'EventTime' -NaturalKey @('ActionId') -AccumKeys @() -HasCheckpoint $true -CommittedCursor $null -CommittedBoundaryKeys ''
        $f['NextCursor'] | Should -Be ''            # committed high-water UNTOUCHED (was empty)
        $f['NextBoundaryKeys'] | Should -Be ''
        $f['ResumeHighWater'] | Should -Match '2026-05-05'   # pending running max stashed
        $f['ResumeBoundaryKeys'] | Should -Be 'C5'
    }

    It 'INCOMPLETE drain keeps a pre-existing committed Cursor exactly (no regression)' {
        $ingest = @((New-Row 'X' '2026-06-01T00:00:00Z'))
        $f = Get-XdrAdvancedFrontier -Baseline '2026-05-20T00:00:00Z' -IngestRows $ingest -DrainComplete $false -CursorField 'EventTime' -NaturalKey @('ActionId') -AccumKeys @('Kprev') -HasCheckpoint $true -CommittedCursor '2026-05-20T00:00:00Z' -CommittedBoundaryKeys 'Kprev'
        $f['NextCursor'] | Should -Be '2026-05-20T00:00:00Z'
        $f['NextBoundaryKeys'] | Should -Be 'Kprev'
        $f['ResumeHighWater'] | Should -Match '2026-06-01'
        $f['ResumeBoundaryKeys'] | Should -Be 'X'
    }

    It 'the running max NEVER regresses below the baseline (descending drain · later cycle older rows)' {
        # Baseline already at day 5 (cycle 1 saw the newest page); this cycle ingests only OLDER rows (days 3,2).
        # The pending high-water must STAY at day 5, not regress to day 3.
        $ingest = @((New-Row 'C3' '2026-05-03T00:00:00Z'), (New-Row 'C2' '2026-05-02T00:00:00Z'))
        $f = Get-XdrAdvancedFrontier -Baseline '2026-05-05T00:00:00Z' -IngestRows $ingest -DrainComplete $false -CursorField 'EventTime' -NaturalKey @('ActionId') -AccumKeys @('C5') -HasCheckpoint $true -CommittedCursor $null -CommittedBoundaryKeys ''
        $f['ResumeHighWater'] | Should -Match '2026-05-05'   # held at day 5 (the running max from the baseline)
        $f['ResumeBoundaryKeys'] | Should -Be 'C5'
    }

    It 'no CursorField · COMPLETE · uses the committed Cursor fallback (SNAPSHOT-style preserved)' {
        $f = Get-XdrAdvancedFrontier -Baseline '' -IngestRows @((New-Row 'A' '')) -DrainComplete $true -CursorField '' -NaturalKey @() -AccumKeys @() -HasCheckpoint $true -CommittedCursor 'prior-cursor' -CommittedBoundaryKeys 'prior-bk'
        $f['NextCursor'] | Should -Be 'prior-cursor'
        $f['NextBoundaryKeys'] | Should -Be 'prior-bk'
    }

    It 'no CursorField · COMPLETE · no checkpoint → page-cursor fallback for NextCursor' {
        $f = Get-XdrAdvancedFrontier -Baseline '' -IngestRows @((New-Row 'A' '')) -DrainComplete $true -CursorField '' -NaturalKey @() -AccumKeys @() -HasCheckpoint $false -CommittedCursor $null -CommittedBoundaryKeys '' -PageCursor 'page-tok'
        $f['NextCursor'] | Should -Be 'page-tok'
        $f['NextBoundaryKeys'] | Should -Be ''
    }
}

Describe 'F-KEYLESS-CURSOR · a keyless CURSOR op dedups its boundary by RecordId (the bucketed-date GetInsights class · 2026-06-20)' {
    # A keyless CURSOR op (NaturalKey empty · e.g. GetInsights keyed on the createdDate DAY-bucket where ~30 insights
    # share one date) must NOT keep-all at the boundary tie — keep-all re-emits the volatile current bucket every cycle
    # (the dup-accumulation class). The tie AND the frontier fall back to the row's RecordId (the content-hash): an
    # unchanged current-bucket row (RecordId in PriorKeys) drops; a changed-content row (new content -> new RecordId)
    # is kept. Exactly-once therefore comes from the RecordId boundary, not cursor uniqueness (createdDate is bucketed).
    It 'a boundary tie whose RecordId was already ingested is DROPPED; a changed-content (new RecordId) tie is KEPT' {
        $hw = [DateTime]::Parse('2026-06-19T00:00:00Z').ToUniversalTime()
        $rows = @((New-InsightRow 'hashA' '2026-06-19T00:00:00Z'), (New-InsightRow 'hashB_changed' '2026-06-19T00:00:00Z'))
        $out = Select-XdrExactlyOnceRows -Rows $rows -HighWaterUtc $hw -CursorField 'createdDate' -NaturalKey @() -PriorKeys (New-KeySet @('hashA'))
        (RIds $out) | Should -Be @('hashB_changed')
    }
    It 're-poll of an UNCHANGED current bucket (all RecordIds seen) ingests ZERO — no cross-cycle dup-accumulation' {
        $hw = [DateTime]::Parse('2026-06-19T00:00:00Z').ToUniversalTime()
        $rows = @((New-InsightRow 'h1' '2026-06-19T00:00:00Z'), (New-InsightRow 'h2' '2026-06-19T00:00:00Z'), (New-InsightRow 'h3' '2026-06-19T00:00:00Z'))
        $out = Select-XdrExactlyOnceRows -Rows $rows -HighWaterUtc $hw -CursorField 'createdDate' -NaturalKey @() -PriorKeys (New-KeySet @('h1','h2','h3'))
        @($out).Count | Should -Be 0
    }
    It 'frozen history (createdDate < high-water) is DROPPED; an unseen current-bucket row is KEPT' {
        $hw = [DateTime]::Parse('2026-06-19T00:00:00Z').ToUniversalTime()
        $rows = @((New-InsightRow 'old1' '2026-06-18T00:00:00Z'), (New-InsightRow 'curNew' '2026-06-19T00:00:00Z'))
        $out = Select-XdrExactlyOnceRows -Rows $rows -HighWaterUtc $hw -CursorField 'createdDate' -NaturalKey @() -PriorKeys (New-KeySet @('curSeen'))
        (RIds $out) | Should -Be @('curNew')
    }
    It 'a keyless boundary tie with an EMPTY PriorKeys (degraded) is DROPPED — no-dup priority (parallels the keyed F-BOUNDARY)' {
        $hw = [DateTime]::Parse('2026-06-19T00:00:00Z').ToUniversalTime()
        $rows = @((New-InsightRow 'hX' '2026-06-19T00:00:00Z'))
        $out = Select-XdrExactlyOnceRows -Rows $rows -HighWaterUtc $hw -CursorField 'createdDate' -NaturalKey @() -PriorKeys (New-KeySet @())
        @($out).Count | Should -Be 0
    }
    It 'a truly id-less keyless row (no RecordId AND no NaturalKey) still KEEPS at the tie (fail-safe · carries RawJson)' {
        $hw = [DateTime]::Parse('2026-06-19T00:00:00Z').ToUniversalTime()
        $rows = @(@{ createdDate = '2026-06-19T00:00:00Z' })
        $out = Select-XdrExactlyOnceRows -Rows $rows -HighWaterUtc $hw -CursorField 'createdDate' -NaturalKey @() -PriorKeys (New-KeySet @('whatever'))
        @($out).Count | Should -Be 1
    }
    It 'Get-XdrAdvancedFrontier builds the boundary set from RecordId when keyless (so next-cycle PriorKeys can dedup)' {
        $rows = @((New-InsightRow 'hA' '2026-06-19T00:00:00Z'), (New-InsightRow 'hB' '2026-06-19T00:00:00Z'))
        $fr = Get-XdrAdvancedFrontier -Baseline '' -IngestRows $rows -DrainComplete $true -CursorField 'createdDate' -NaturalKey @() -AccumKeys @() -HasCheckpoint $false -CommittedCursor $null -CommittedBoundaryKeys '' -PageCursor $null
        ([string]$fr['NextCursor']) | Should -Match '2026-06-19'
        ([string]$fr['NextBoundaryKeys']) | Should -Match 'hA'
        ([string]$fr['NextBoundaryKeys']) | Should -Match 'hB'
    }
    It 'F-NULLKEY · a $null NaturalKey (the value that actually reached the EO live · a keyless op @() collapsed to $null through an if/else block) behaves IDENTICALLY to @() — NO array-index crash' {
        # The live GetInsights CURSOR fault (2026-06-20): line-711 `if(..){..}else{@()}` emitted nothing for the empty
        # else-block → $naturalKey=$null → the [string[]] param coerced it to a one-element @($null) → $keyOf indexed
        # $row[$null] → "array index evaluated to null". The earlier cases all passed a LITERAL @() (which does NOT
        # collapse), so none exercised $null. This asserts $null === keyless (the RecordId boundary), no crash.
        $hw = [DateTime]::Parse('2026-06-19T00:00:00Z').ToUniversalTime()
        $rows = @((New-InsightRow 'hashA' '2026-06-19T00:00:00Z'), (New-InsightRow 'hashB_changed' '2026-06-19T00:00:00Z'))
        $out = Select-XdrExactlyOnceRows -Rows $rows -HighWaterUtc $hw -CursorField 'createdDate' -NaturalKey $null -PriorKeys (New-KeySet @('hashA'))
        (RIds $out) | Should -Be @('hashB_changed')
    }
    It 'F-NULLKEY · Get-XdrAdvancedFrontier with a $null NaturalKey builds the RecordId boundary — no crash (symmetric)' {
        $rows = @((New-InsightRow 'hA' '2026-06-19T00:00:00Z'), (New-InsightRow 'hB' '2026-06-19T00:00:00Z'))
        $fr = Get-XdrAdvancedFrontier -Baseline '' -IngestRows $rows -DrainComplete $true -CursorField 'createdDate' -NaturalKey $null -AccumKeys @() -HasCheckpoint $false -CommittedCursor $null -CommittedBoundaryKeys '' -PageCursor $null
        ([string]$fr['NextBoundaryKeys']) | Should -Match 'hA'
        ([string]$fr['NextBoundaryKeys']) | Should -Match 'hB'
    }
}
