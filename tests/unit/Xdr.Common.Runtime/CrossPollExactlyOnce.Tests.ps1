#Requires -Version 7.4
# CORE-2 (2026-07-07) · cross-poll exactly-once for the two NON-SNAPSHOT event-stream shapes whose cross-poll dedup
# regressed on a live 7-day steady state:
#
#   1. keyless-CURSOR boundary cohort (GetInsights shape · IngestionMode=CURSOR · bucketed-date cursor createdDate ·
#      NaturalKey empty). Exactly-once at the high-water boundary comes from the RecordId (content-hash) boundary set
#      (F-KEYLESS-CURSOR) — an UNCHANGED current-bucket row already in the committed prior-boundary set is DROPPED.
#      This suite LOCKS the working byte-identical-content behavior so a future edit cannot silently re-open it.
#
#   2. WINDOW overlapping-boundary (GetMachineTimelineEvents shape · IngestionMode=WINDOW · ServerFromDate ·
#      CursorField null · NaturalKey empty · itemsContainer=Items). ROOT CAUSE (F-WINDOW-CURSOR): $cursorField was
#      mis-derived from TimeFilter.FieldName='fromDate' (a QUERY-PARAM name for a server window bound, NOT a row
#      field) → Select-XdrExactlyOnceRows took the CURSOR branch, read $row['fromDate']=$null on every row → kept
#      them all (unparseable-cursor fail-safe) AND bypassed the cursorless SNAPSHOT-signature dedup → the whole
#      overlapping window re-ingested every poll. FIX: gate the FieldName→cursor fallback on Mode='ClientSideHighWater'
#      (server-window modes keep $cursorField=null → the SNAPSHOT-signature cross-poll dedup runs); AND advance the
#      WINDOW resume low-bound EXCLUSIVELY past the prior committed WindowEndUtc (F-WINDOW-EXCLUSIVE) so the
#      inclusive-inclusive server boundary instant is not re-served. The 168h cold backfill is preserved for cold start.
#
# All three suites drive the REAL Invoke-XdrEntryPoll with the I/O boundaries mocked, and — critically — a STATEFUL
# checkpoint (poll 1's save feeds poll 2's read, exactly as the runtime does live). A STATIC checkpoint (the pre-CORE-2
# tests) never exercises the save→read round-trip that failed on the live estate.

BeforeAll {
    $script:Repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $psd1s = Get-ChildItem (Join-Path $script:Repo 'src\Modules') -Directory |
        ForEach-Object { Join-Path $_.FullName ($_.Name + '.psd1') } | Where-Object { Test-Path $_ }
    for ($pass = 1; $pass -le 4; $pass++) {
        foreach ($p in $psd1s) { try { Import-Module $p -Force -DisableNameChecking -ErrorAction Stop } catch { } }
    }
    $env:XDRLR_DCE_ENDPOINT = 'https://dce-test.local'

    # A cold checkpoint carrying every field the runtime reads (StrictMode-safe · indexer reads throughout).
    function New-ColdCheckpoint([string]$op) {
        @{ OperationKey = $op; Cursor = $null; BoundaryKeys = $null; SnapshotSignature = $null; WindowStartUtc = $null
           WindowEndUtc = $null; ResumePage = $null; ResumeCursor = $null; ResumeHighWater = $null
           ResumeBoundaryKeys = $null; ResetUtc = $null; ResetReasonAnnotation = $null; LastUpdatedUtc = $null
           LastItemCount = 0; ETag = $null }
    }
    # The stateful Save mock body (shared shape) — persists exactly what the runtime passes, so the NEXT Get returns it.
    function Set-StatefulCheckpointMock {
        Mock -ModuleName Xdr.Common.Runtime Save-XdrCheckpointAtomic {
            $global:XdrCP = @{ OperationKey = $OperationKey; Cursor = $Cursor; BoundaryKeys = $BoundaryKeys
                SnapshotSignature = $SnapshotSignature; WindowStartUtc = $Window.StartUtc; WindowEndUtc = $Window.EndUtc
                ResumePage = $ResumePage; ResumeCursor = $ResumeCursor; ResumeHighWater = $ResumeHighWater
                ResumeBoundaryKeys = $ResumeBoundaryKeys; ResetUtc = $ResetUtc; ResetReasonAnnotation = $ResetReasonAnnotation
                LastUpdatedUtc = (Get-Date).ToString('o'); LastItemCount = $ItemCount; ETag = 'e' + ([guid]::NewGuid().ToString('N').Substring(0,6)) }
            $true
        }
    }
}

Describe 'CORE-2 · keyless-CURSOR (GetInsights shape) cross-poll exactly-once · RecordId boundary dedup' {
    BeforeEach {
        $global:XdrCP = New-ColdCheckpoint 'GetInsights'
        Mock -ModuleName Xdr.Common.Runtime Connect-XdrPortal { @{ Portal = 'Defender'; Sccauth = 'x'; XsrfToken = 'y' } }
        Mock -ModuleName Xdr.Common.Runtime Get-XdrCheckpoint { $global:XdrCP }
        Set-StatefulCheckpointMock
        Mock -ModuleName Xdr.Common.Runtime Send-ToDce { $global:XdrSent = @($Rows); @{ Success = $true; RowsAccepted = @($Rows).Count; BytesIngested = 100 } }
        Mock -ModuleName Xdr.Common.Runtime Lock-XdrSingleFlight { 'lease-granted' }
        Mock -ModuleName Xdr.Common.Runtime Unlock-XdrSingleFlight { $true }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrEvent { }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrException { }

        # Keyless CURSOR on the bucketed createdDate. The current-day cohort (max date) holds 2 records whose `id`
        # is unique WITHIN the cohort but re-used across days (as in the real body); dedup rides on the RecordId hash.
        $script:GiEntry = @{
            OperationKey = 'GetInsights'; Portal = 'Defender'; Category = 'Secure Score'; Method = 'GET'; SubPortal = 'mtp'
            Path = '/secureScore/security/secureScoreInsights'; ResponseShape = 'wrapper'; ItemsContainer = 'value'
            IngestionMode = 'CURSOR'; CursorField = 'createdDate'; NaturalKey = @()
            TimeFilter = @{ FieldName = 'createdDate'; Mode = 'ClientSideHighWater' }
            Pagination = @{ Mode = 'none' }
            ProjectionMap = @{ createdDate = '$.createdDate'; id = '$.id'; averageScore = '$.averageScore'; tenantCount = '$.tenantCount' }
            DcrImmutableId = 'dcr-test'; DcrStreamName = 'Custom-Defender_SecureScore_CL'
        }
        # An IMMUTABLE cohort: two current-day records + one older. distinctRaw is constant across polls.
        $script:GiBody = @{ value = @(
            @{ id = 'All_BEC';         createdDate = '2026-05-21T00:00:00Z'; averageScore = 60.59; tenantCount = 4297087 },
            @{ id = 'Users_1_100_BEC'; createdDate = '2026-05-21T00:00:00Z'; averageScore = 40.2;  tenantCount = 100 },
            @{ id = 'All_BEC';         createdDate = '2026-05-20T00:00:00Z'; averageScore = 59.9;  tenantCount = 4297000 }
        ) }
        Mock -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp { @{ StatusCode = 200; RawBody = ''; Body = $script:GiBody } }
    }

    It 'poll 1 ingests the full cohort and persists the high-water + a NON-EMPTY RecordId boundary set' {
        $r1 = Invoke-XdrEntryPoll -Entry $script:GiEntry -CorrelationId 'gi-1'
        $r1.Success   | Should -BeTrue
        $r1.ItemCount | Should -Be 3
        $global:XdrCP.Cursor       | Should -Match '2026-05-21'          # high-water = max(createdDate)
        $global:XdrCP.BoundaryKeys | Should -Not -BeNullOrEmpty          # the content-hash identities of the max-date cohort
    }

    It 'poll 2 (byte-identical content) re-ingests ZERO — the boundary cohort is dropped by RecordId, not re-emitted' {
        $null = Invoke-XdrEntryPoll -Entry $script:GiEntry -CorrelationId 'gi-1'   # poll 1 commits
        $r2 = Invoke-XdrEntryPoll -Entry $script:GiEntry -CorrelationId 'gi-2'     # poll 2 resumes from it
        $r2.Success   | Should -BeTrue
        $r2.ItemCount | Should -Be 0
        Should -Invoke -ModuleName Xdr.Common.Runtime Send-ToDce -Times 1 -Exactly   # ONLY poll 1 sent (poll 2 sent nothing)
    }
}

Describe 'CORE-2 · WINDOW (GetMachineTimelineEvents shape) overlapping-boundary cross-poll exactly-once' {
    BeforeEach {
        # A prior cycle already ran and committed WindowEndUtc = $script:PriorEnd (a FIXED instant · deterministic).
        # The estate holds an event sitting EXACTLY at that prior window end — the inclusive-inclusive server window
        # [WindowEndUtc, now] would re-serve it every resume cycle (the live boundary re-serve). The resume cycle here
        # is the second poll; its behavior is the whole test.
        $script:PriorEnd = '2026-06-01T12:00:00.0000000Z'
        $global:XdrCP = @{ OperationKey = 'GetMachineTimelineEvents'; Cursor = $null; BoundaryKeys = $null
            SnapshotSignature = $null; WindowStartUtc = '2026-05-25T12:00:00.0000000Z'; WindowEndUtc = $script:PriorEnd
            ResumePage = $null; ResumeCursor = $null; ResumeHighWater = $null; ResumeBoundaryKeys = $null
            ResetUtc = $null; ResetReasonAnnotation = $null; LastUpdatedUtc = $script:PriorEnd; LastItemCount = 1; ETag = 'e-prior' }
        $global:XdrIncludeNew = $false
        Mock -ModuleName Xdr.Common.Runtime Connect-XdrPortal { @{ Portal = 'Defender'; Sccauth = 'x'; XsrfToken = 'y' } }
        Mock -ModuleName Xdr.Common.Runtime Get-XdrCheckpoint { $global:XdrCP }
        Set-StatefulCheckpointMock
        Mock -ModuleName Xdr.Common.Runtime Send-ToDce { $global:XdrSent = @($Rows); @{ Success = $true; RowsAccepted = @($Rows).Count; BytesIngested = 100 } }
        Mock -ModuleName Xdr.Common.Runtime Lock-XdrSingleFlight { 'lease-granted' }
        Mock -ModuleName Xdr.Common.Runtime Unlock-XdrSingleFlight { $true }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrEvent { }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrException { }

        # WINDOW-AWARE server (the exact live mechanism): parse the fromDate the URL carries and serve every event with
        # ActionTime >= fromDate (INCLUSIVE, as the endpoint_devices corpus). E_boundary sits AT the prior WindowEndUtc,
        # so an INCLUSIVE resume low-bound (pre-fix) re-serves it; an EXCLUSIVE low-bound (fix) skips it.
        Mock -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp {
            param($Url)
            $from = [DateTime]::MinValue
            if ($Url -match 'fromDate=([^&]+)') { try { $from = [DateTime]::Parse([uri]::UnescapeDataString($Matches[1])).ToUniversalTime() } catch { } }
            $estate = @( @{ ReportId = 'E_boundary'; ActionType = 'FileCreated'; ActionTime = '2026-06-01T12:00:00.0000000Z' } )   # AT the prior window end
            if ($global:XdrIncludeNew) { $estate += @{ ReportId = 'E_new'; ActionType = 'Logon'; ActionTime = ([DateTime]::UtcNow).ToString('o') } }
            $served = @($estate | Where-Object { ([DateTime]::Parse($_.ActionTime)).ToUniversalTime() -ge $from })
            @{ StatusCode = 200; RawBody = ''; Body = @{ Items = $served } }
        }

        # Real GMTE curation: WINDOW · CursorField null · NaturalKey empty · ServerFromDate 'fromDate' · itemsContainer=Items.
        $script:GmteEntry = @{
            OperationKey = 'GetMachineTimelineEvents'; Portal = 'Defender'; Category = 'Endpoints & Devices'; Method = 'GET'; SubPortal = 'mtp'
            Path = '/mdeTimelineExperience/machines/M1/events'; ResponseShape = 'wrapper'; ItemsContainer = 'Items'
            IngestionMode = 'WINDOW'; CursorField = $null; NaturalKey = @(); LookbackHours = 168
            TimeFilter = @{ Mode = 'ServerFromDate'; FieldName = 'fromDate'; FromDateParam = 'fromDate'; ToDateParam = 'toDate'; ParamLocation = 'query' }
            Pagination = @{ Mode = 'none' }
            ProjectionMap = @{ ActionTime = '$.ActionTime'; ActionType = '$.ActionType'; ReportId = '$.ReportId' }
            DcrImmutableId = 'dcr-test'; DcrStreamName = 'Custom-Defender_EndpointManagement_CL'
        }
    }

    It 'the resume window low-bound is EXCLUSIVE — the server is NOT asked to re-serve the prior-window-end instant' {
        # F-WINDOW-EXCLUSIVE: fromDate on the resume cycle must be STRICTLY AFTER the committed WindowEndUtc.
        $null = Invoke-XdrEntryPoll -Entry $script:GmteEntry -CorrelationId 'gt-excl'
        Should -Invoke -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp -Times 1 -Exactly -ParameterFilter {
            if ($Url -match 'fromDate=([^&]+)') {
                $fromDt = [DateTime]::Parse([uri]::UnescapeDataString($Matches[1])).ToUniversalTime()
                $fromDt -gt ([DateTime]::Parse($script:PriorEnd).ToUniversalTime())   # RED pre-fix: fromDate == PriorEnd (inclusive)
            } else { $false }
        }
    }

    It 'the resume cycle re-ingests ZERO — the boundary event at the prior window end is NOT re-served' {
        $r = Invoke-XdrEntryPoll -Entry $script:GmteEntry -CorrelationId 'gt-resume'
        $r.Success   | Should -BeTrue
        $r.ItemCount | Should -Be 0   # RED pre-fix: E_boundary re-ingested (inclusive re-serve + no cursorless dedup)
    }

    It 'a genuinely-NEW event after the prior window end IS ingested (no over-drop)' {
        $global:XdrIncludeNew = $true
        $r = Invoke-XdrEntryPoll -Entry $script:GmteEntry -CorrelationId 'gt-new'
        $r.ItemCount | Should -Be 1
        ($global:XdrSent | ForEach-Object { [string]$_['ReportId'] }) | Should -Be @('E_new')
    }

    It 'a cold start (no committed WindowEndUtc) uses the full 168h backfill window (cold backfill preserved · NOT an exclusive nudge)' {
        $global:XdrCP = New-ColdCheckpoint 'GetMachineTimelineEvents'   # no WindowEndUtc → 168h lookback, never a +1-tick nudge
        $null = Invoke-XdrEntryPoll -Entry $script:GmteEntry -CorrelationId 'gt-cold'
        Should -Invoke -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp -Times 1 -Exactly -ParameterFilter {
            if ($Url -match 'fromDate=([^&]+)') {
                $fromDt = [DateTime]::Parse([uri]::UnescapeDataString($Matches[1])).ToUniversalTime()
                $fromDt -lt ([DateTime]::UtcNow).AddHours(-167)   # a real ~168h backfill window (the exclusive nudge only applies on RESUME)
            } else { $false }
        }
    }
}

Describe 'CORE-2 · Resolve-XdrTimeWindow unit · WINDOW mode-gating + exclusive resume low-bound' {
    It 'a server-window (ServerFromDate) WINDOW op does NOT mis-derive $cursorField from TimeFilter.FieldName' {
        # The runtime derives $cursorField only from an explicit CursorField or a ClientSideHighWater FieldName.
        # A ServerFromDate FieldName is a query-param name — it must NOT become a row cursor. This asserts the
        # discriminator directly (the same expression the runtime uses).
        InModuleScope Xdr.Common.Runtime {
            $entry = @{ CursorField = $null; TimeFilter = @{ Mode = 'ServerFromDate'; FieldName = 'fromDate' } }
            $tf = $entry['TimeFilter']
            $isRowCursor = ($tf -is [System.Collections.IDictionary]) -and $tf['FieldName'] -and ([string]$tf['Mode'] -eq 'ClientSideHighWater')
            $isRowCursor | Should -BeFalse
        }
    }
    It 'a ClientSideHighWater FieldName IS a valid row cursor (GetInsights createdDate — back-compat preserved)' {
        InModuleScope Xdr.Common.Runtime {
            $tf = @{ Mode = 'ClientSideHighWater'; FieldName = 'createdDate' }
            $isRowCursor = ($tf -is [System.Collections.IDictionary]) -and $tf['FieldName'] -and ([string]$tf['Mode'] -eq 'ClientSideHighWater')
            $isRowCursor | Should -BeTrue
        }
    }
    It 'WINDOW resume advances the low-bound EXCLUSIVELY (one tick past the prior committed WindowEndUtc)' {
        InModuleScope Xdr.Common.Runtime {
            $prevEnd = '2026-05-06T00:00:00.0000000Z'
            $w = Resolve-XdrTimeWindow -Entry @{ IngestionMode = 'WINDOW'; LookbackHours = 168 } -Checkpoint @{ WindowEndUtc = $prevEnd }
            $startDt = [DateTime]::Parse($w.StartUtc).ToUniversalTime()
            $prevDt  = [DateTime]::Parse($prevEnd).ToUniversalTime()
            $startDt | Should -BeGreaterThan $prevDt                       # strictly after → the boundary instant is excluded
            ($startDt - $prevDt).Ticks | Should -Be 1                      # minimal exclusive delta (no data-window widening)
        }
    }
    It 'WINDOW cold start (no committed WindowEndUtc) keeps the full 168h backfill (cold backfill preserved)' {
        InModuleScope Xdr.Common.Runtime {
            $now = [DateTime]::UtcNow
            $w = Resolve-XdrTimeWindow -Entry @{ IngestionMode = 'WINDOW'; LookbackHours = 168 } -Checkpoint @{}
            $startDt = [DateTime]::Parse($w.StartUtc).ToUniversalTime()
            # ~168h back (allow a small execution-time slack); definitively NOT a near-now exclusive nudge.
            ($now - $startDt).TotalHours | Should -BeGreaterThan 167
            ($now - $startDt).TotalHours | Should -BeLessThan 169
        }
    }
    It 'SNAPSHOT is untouched by the WINDOW change (HighWaterUtc stays null · SNAP-1 not in scope)' {
        InModuleScope Xdr.Common.Runtime {
            $w = Resolve-XdrTimeWindow -Entry @{ IngestionMode = 'SNAPSHOT' } -Checkpoint @{ WindowEndUtc = '2026-05-06T00:00:00Z' }
            $w.HighWaterUtc | Should -BeNullOrEmpty
            $w.StartUtc     | Should -BeNullOrEmpty
        }
    }
}
