#Requires -Version 7.4
# Regression proofs for the GENERICITY fixes (2026-06-18) · each fix at SOURCE, generic, B4-clean. Drives the REAL
# Invoke-XdrEntryPoll / Invoke-XdrEntityFanout / Resolve-XdrTimeWindow with the I/O boundaries mocked (auth · HTTP ·
# DCE · checkpoint · telemetry · lease) — the SAME harness as ExactlyOnce.Tests.ps1 / EntityFanout.Tests.ps1.
#   E-BLK2 · a fanned child row lands Operation == the BASE op key (NOT the composite "<op>|<id>"), while the
#            checkpoint RowKey stays composite + the keyless RecordId stays the content-hash (per-entity exactly-once).
#   E-MAJ1 · Resolve-XdrTimeWindow default (unknown IngestionMode) sets HighWaterUtc=StartUtc + emits IngestionMode.Degraded.
#   E-MAJ2 · a THROWN parent SEED poll ≠ a benign empty parent → distinct non-success (ErrorClass · breaker-actionable).
#   E-MAJ3 · a SPARSE page (raw items == PageSize · some dropped by the empty-gate) STILL paginates (no early stop).

BeforeAll {
    $script:Repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $psd1s = Get-ChildItem (Join-Path $script:Repo 'src\Modules') -Directory |
        ForEach-Object { Join-Path $_.FullName ($_.Name + '.psd1') } | Where-Object { Test-Path $_ }
    for ($pass = 1; $pass -le 4; $pass++) {
        foreach ($p in $psd1s) { try { Import-Module $p -Force -DisableNameChecking -ErrorAction Stop } catch { } }
    }
    function New-AcRow([string]$id, [string]$time) { @{ ActionId = $id; EventTime = $time } }
    $env:XDRLR_DCE_ENDPOINT = 'https://dce-test.local'
}

Describe 'E-BLK2 · entity fan-out child row carries the BASE Operation · composite checkpoint key preserved' {
    BeforeAll {
        # A child entity op (CURSOR · path with {CaseId}) · identical data-plane to the GetHistory baseline. KEYLESS so
        # the content-hash RecordId path is exercised too (the eb5c76d fan-out child is keyless).
        $script:EntityEntry = @{
            OperationKey = 'GetPostureOversightInitiative'; Portal = 'Defender'; Category = 'ExposureManagement'; Subcategory = 'Initiatives'
            Method = 'GET'; SubPortal = 'mtp'; Path = '/posture/be/initiatives/{InitiativeId}/oversight'
            ResponseShape = 'wrapper'; ItemsContainer = 'Results'
            IngestionMode = 'SNAPSHOT'   # keyless snapshot · RecordId = content-hash
            Pagination = @{ Mode = 'pageSize'; PageSizeQuery = 'pageSize'; PageSize = 500; PageIndexQuery = 'pageIndex'; CursorMode = 'pageIndexIncrement'; LoopGuard = 1000 }
            ProjectionMap = @{ ControlState = '$.controlState' }
            DcrImmutableId = 'dcr-test'; DcrStreamName = 'Custom-Defender_ExposureManagement_CL'
            ParamSource = 'ParentOp'; EntityResolution = 'Resolved'
            DependsOn = @{ ParentOperationKey = 'ListPostureOversightInitiatives'; EntityIdField = 'initiativeId'; ParamName = 'InitiativeId'; MatchKind = 'ExactName' }
        }
    }
    BeforeEach {
        Clear-XdrEntityCache
        $global:GbIngested = [System.Collections.Generic.List[object]]::new()
        $global:GbCheckpointKeys = [System.Collections.Generic.List[string]]::new()
        $global:GbSucceededOpKeys = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Xdr.Common.Runtime Connect-XdrPortal { @{ Portal = 'Defender'; Sccauth = 'x'; XsrfToken = 'y' } }
        # Each entity returns ONE row carrying a controlState (so it's not empty-gated).
        Mock -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp {
            $eid = ''
            if ($Url -match '/initiatives/([^/]+)/oversight') { $eid = [uri]::UnescapeDataString($Matches[1]) }
            @{ StatusCode = 200; Body = @{ Results = @(@{ controlState = "state-$eid" }) }; RawBody = '' }
        }
        Mock -ModuleName Xdr.Common.Runtime Get-XdrCheckpoint { @{ OperationKey = $OperationKey; Cursor = $null; BoundaryKeys = $null; ResumePage = $null; ResumeCursor = $null; ResumeHighWater = $null; ResumeBoundaryKeys = $null; LastUpdatedUtc = $null; ETag = $null } }
        # Capture EVERY checkpoint RowKey written (proves composite-key checkpointing survives).
        Mock -ModuleName Xdr.Common.Runtime Save-XdrCheckpointAtomic { $global:GbCheckpointKeys.Add($OperationKey); $true }
        # Capture EVERY ingested row (proves the Operation envelope column on a fanned child).
        Mock -ModuleName Xdr.Common.Runtime Send-ToDce { $global:GbIngested.Add(@{ Op = $StreamName; Rows = @($Rows) }); @{ Success = $true; RowsAccepted = @($Rows).Count; BytesIngested = 10 } }
        Mock -ModuleName Xdr.Common.Runtime Get-XdrCircuitState { @{ State = 'Closed'; FailureCount = 0; OpenedUtc = $null; ETag = $null } }
        Mock -ModuleName Xdr.Common.Runtime Test-XdrCircuitClosed { $true }
        Mock -ModuleName Xdr.Common.Runtime Update-XdrCircuitState { }
        Mock -ModuleName Xdr.Common.Runtime Lock-XdrSingleFlight { 'lease-granted' }
        Mock -ModuleName Xdr.Common.Runtime Unlock-XdrSingleFlight { $true }
        # Capture the OperationKey on every Entry.Poll.Succeeded (must be BASE, never composite).
        Mock -ModuleName Xdr.Common.Runtime Track-XdrEvent {
            if ($Name -eq 'Entry.Poll.Succeeded') { $global:GbSucceededOpKeys.Add([string]$Properties['OperationKey']) }
        }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrException { }
        Add-XdrEntityIds -Portal 'Defender' -Category 'ExposureManagement' -ParentOperationKey 'ListPostureOversightInitiatives' -Ids @('init-1','init-2')
    }

    It 'a fanned child row lands Operation == the BASE op key (NOT "<op>|<id>") · entity id is in ParentRecordId' {
        $r = Invoke-XdrEntityFanout -Entry $script:EntityEntry -CorrelationId 'gb1'
        $r.Skipped | Should -BeFalse
        $r.EntitiesPolled | Should -Be 2
        $allRows = $global:GbIngested | ForEach-Object { $_.Rows }
        @($allRows).Count | Should -Be 2
        foreach ($row in $allRows) {
            $row['Operation']      | Should -Be 'GetPostureOversightInitiative'   # BASE · NOT composite
            $row['Operation']      | Should -Not -Match '\|'                       # no composite suffix leaked
            # the entity id (the fan-out parent) is carried on ParentRecordId · NOT in Operation
            $row['ParentRecordId'] | Should -Match '^init-[12]$'
        }
    }

    It 'the checkpoint RowKey stays COMPOSITE "<op>|<id>" (per-entity exactly-once preserved)' {
        $null = Invoke-XdrEntityFanout -Entry $script:EntityEntry -CorrelationId 'gb2'
        @($global:GbCheckpointKeys) | Should -Contain 'GetPostureOversightInitiative|init-1'
        @($global:GbCheckpointKeys) | Should -Contain 'GetPostureOversightInitiative|init-2'
        # and NONE of them is the bare base key (the per-entity isolation must not collapse to one row)
        @($global:GbCheckpointKeys) | Should -Not -Contain 'GetPostureOversightInitiative'
    }

    It 'the Entry.Poll.Succeeded telemetry OperationKey is the BASE key (verifier op-scope match)' {
        $null = Invoke-XdrEntityFanout -Entry $script:EntityEntry -CorrelationId 'gb3'
        @($global:GbSucceededOpKeys).Count | Should -Be 2
        foreach ($k in $global:GbSucceededOpKeys) {
            $k | Should -Be 'GetPostureOversightInitiative'   # BASE · never composite
        }
    }

    It 'the keyless child RecordId is the content-hash of RawJson (NOT empty · NOT the composite key)' {
        $null = Invoke-XdrEntityFanout -Entry $script:EntityEntry -CorrelationId 'gb4'
        $allRows = $global:GbIngested | ForEach-Object { $_.Rows }
        foreach ($row in $allRows) {
            $row['RecordId'] | Should -Match '^[0-9a-f]{64}$'   # SHA256 hex · the keyless content-hash identity
        }
    }

    It 'a NON-fan-out (top-level) poll is byte-identical · Operation == op key (no composite logic engaged)' {
        $top = @{
            OperationKey = 'GetHistory'; Portal = 'Defender'; Category = 'Operations'; Subcategory = 'Action Center'
            Method = 'GET'; SubPortal = 'mtp'; Path = '/actionCenter/actioncenterui/history-actions'
            ResponseShape = 'wrapper'; ItemsContainer = 'Results'
            IngestionMode = 'CURSOR'; CursorField = 'EventTime'; NaturalKey = @('ActionId')
            Pagination = @{ Mode = 'pageSize'; PageSizeQuery = 'pageSize'; PageSize = 500; PageIndexQuery = 'pageIndex'; CursorMode = 'pageIndexIncrement'; LoopGuard = 1000 }
            ProjectionMap = @{ EventTime = '$.EventTime'; ActionId = '$.ActionId' }
            DcrImmutableId = 'dcr-test'; DcrStreamName = 'Custom-Defender_Operations_CL'
        }
        Mock -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp { @{ StatusCode = 200; Body = @{ Results = @((New-AcRow 'H1' '2026-05-01T00:00:00Z')) }; RawBody = '' } }
        $r = Invoke-XdrEntryPoll -Entry $top -CorrelationId 'gb5'
        $r.Success | Should -BeTrue
        $r.OperationKey | Should -Be 'GetHistory'
        $allRows = $global:GbIngested | ForEach-Object { $_.Rows }
        @($allRows)[0]['Operation'] | Should -Be 'GetHistory'
        @($allRows)[0]['ParentRecordId'] | Should -Be ''   # top-level poll · no fan-out parent
    }
}

Describe 'E-MAJ1 · Resolve-XdrTimeWindow default branch (unknown IngestionMode) · client dedup + gate-observable event' {
    It 'sets HighWaterUtc = StartUtc (mirror WINDOW) so client boundary dedup RUNS (not unbounded full re-emit)' {
        InModuleScope Xdr.Common.Runtime {
            Mock Track-XdrEvent { }
            $entry = @{ OperationKey = 'TypoOp'; Portal = 'Defender'; Category = 'Operations'; IngestionMode = 'SNAPSHO'; LookbackHours = 6 }   # typo'd mode
            $w = Resolve-XdrTimeWindow -Entry $entry -Checkpoint @{}
            $w['StartUtc']     | Should -Not -BeNullOrEmpty
            $w['HighWaterUtc'] | Should -Not -BeNullOrEmpty                 # was $null pre-fix → dedup skipped
            $w['HighWaterUtc'] | Should -Be $w['StartUtc']                  # mirrors the WINDOW branch
        }
    }
    It 'emits a gate-observable IngestionMode.Degraded event (not only Write-Warning)' {
        InModuleScope Xdr.Common.Runtime {
            $script:degradedSeen = $null
            Mock Track-XdrEvent { if ($Name -eq 'IngestionMode.Degraded') { $script:degradedSeen = $Properties } }
            $entry = @{ OperationKey = 'TypoOp2'; Portal = 'Defender'; Category = 'Operations'; IngestionMode = 'bogus'; LookbackHours = 12 }
            $null = Resolve-XdrTimeWindow -Entry $entry -Checkpoint @{}
            Should -Invoke Track-XdrEvent -ParameterFilter { $Name -eq 'IngestionMode.Degraded' } -Times 1
            $script:degradedSeen['OperationKey']  | Should -Be 'TypoOp2'
            $script:degradedSeen['IngestionMode'] | Should -Be 'bogus'
        }
    }
    It 'a KNOWN mode (SNAPSHOT) does NOT emit IngestionMode.Degraded (no false positive)' {
        InModuleScope Xdr.Common.Runtime {
            Mock Track-XdrEvent { }
            $entry = @{ OperationKey = 'GoodOp'; Portal = 'Defender'; Category = 'Operations'; IngestionMode = 'SNAPSHOT' }
            $null = Resolve-XdrTimeWindow -Entry $entry -Checkpoint @{}
            Should -Invoke Track-XdrEvent -ParameterFilter { $Name -eq 'IngestionMode.Degraded' } -Times 0
        }
    }
}

Describe 'E-MAJ2 · a thrown parent SEED poll ≠ a benign empty parent (distinct non-success · breaker-actionable)' {
    BeforeAll {
        $script:EntityEntry = @{
            OperationKey = 'ListCaseActivities'; Portal = 'Defender'; Category = 'Operations'; Subcategory = 'Action Center'
            Method = 'GET'; SubPortal = 'mtp'; Path = '/CaseManagement/be/cases/{CaseId}/activities'
            ResponseShape = 'wrapper'; ItemsContainer = 'Results'
            IngestionMode = 'CURSOR'; CursorField = 'EventTime'; NaturalKey = @('ActionId')
            Pagination = @{ Mode = 'pageSize'; PageSizeQuery = 'pageSize'; PageSize = 500; PageIndexQuery = 'pageIndex'; CursorMode = 'pageIndexIncrement'; LoopGuard = 1000 }
            ProjectionMap = @{ EventTime = '$.EventTime'; ActionId = '$.ActionId' }
            DcrImmutableId = 'dcr-test'; DcrStreamName = 'Custom-Defender_Operations_CL'
            ParamSource = 'ParentOp'; EntityResolution = 'Resolved'
            DependsOn = @{ ParentOperationKey = 'ListCases'; EntityIdField = 'caseId'; ParamName = 'CaseId'; MatchKind = 'ExactName' }
            ParentEntry = @{ OperationKey = 'ListCases'; Portal = 'Defender'; Category = 'Operations'; Method = 'GET'; SubPortal = 'mtp'; Path = '/CaseManagement/be/cases'; ResponseShape = 'wrapper'; ItemsContainer = 'Results'; ProjectionMap = @{ caseId = '$.id' } }
        }
    }
    BeforeEach {
        Clear-XdrEntityCache
        Mock -ModuleName Xdr.Common.Runtime Connect-XdrPortal { @{ Portal = 'Defender'; Sccauth = 'x'; XsrfToken = 'y' } }
        Mock -ModuleName Xdr.Common.Runtime Get-XdrCheckpoint { @{ OperationKey = $OperationKey; Cursor = $null; BoundaryKeys = $null; ETag = $null } }
        Mock -ModuleName Xdr.Common.Runtime Save-XdrCheckpointAtomic { $true }
        Mock -ModuleName Xdr.Common.Runtime Send-ToDce { @{ Success = $true; RowsAccepted = 0; BytesIngested = 0 } }
        Mock -ModuleName Xdr.Common.Runtime Get-XdrCircuitState { @{ State = 'Closed'; FailureCount = 0; OpenedUtc = $null; ETag = $null } }
        Mock -ModuleName Xdr.Common.Runtime Test-XdrCircuitClosed { $true }
        Mock -ModuleName Xdr.Common.Runtime Update-XdrCircuitState { }
        Mock -ModuleName Xdr.Common.Runtime Lock-XdrSingleFlight { 'lease-granted' }
        Mock -ModuleName Xdr.Common.Runtime Unlock-XdrSingleFlight { $true }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrEvent { }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrException { }
    }

    It 'a THROWN seed poll → Success=$false + distinct ErrorClass (XdrEntityParentFeedFailed) · still NEVER throws' {
        Mock -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp { throw 'parent list 500' }
        $r = $null
        { $script:r = Invoke-XdrEntityFanout -Entry $script:EntityEntry -CorrelationId 'm2a' -ParentEntry $script:EntityEntry['ParentEntry'] } | Should -Not -Throw
        $r = $script:r
        $r.Success    | Should -BeFalse
        $r.ErrorClass | Should -Be 'XdrEntityParentFeedFailed'
        $r.SkipReason | Should -Match 'SEED poll FAILED'
        $r.EntitiesPolled | Should -Be 0
    }

    It 'a BENIGN empty parent (seed poll returns 0 ids · no throw) → graceful Success=$true skip · NO ErrorClass' {
        # The parent list legitimately returns ZERO items (no cases yet) → a benign 0-id result, NOT a failure.
        Mock -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp { @{ StatusCode = 200; Body = @{ Results = @() }; RawBody = '' } }
        $r = Invoke-XdrEntityFanout -Entry $script:EntityEntry -CorrelationId 'm2b' -ParentEntry $script:EntityEntry['ParentEntry']
        $r.Success    | Should -BeTrue                                       # benign · the breaker must NOT escalate
        $r.ErrorClass | Should -BeNullOrEmpty
        $r.Skipped    | Should -BeTrue
        $r.SkipReason | Should -Match 'cache empty'                          # the benign empty-parent skip reason
        $r.EntitiesPolled | Should -Be 0
    }
}

Describe 'E-MAJ3 · a SPARSE page (raw items == PageSize · some empty-gated) STILL paginates (no silent under-fetch)' {
    BeforeEach {
        # PageSize=2. Page 1 returns 2 RAW items but ONE is all-null (empty-gated → 1 ingest row). Pre-fix the page
        # was judged SHORT (post-gate 1 < 2) → pagination STOPPED after page 1 → page-2 rows silently lost. Post-fix the
        # RAW count (2 == PageSize) keeps paging to page 2; page 2 is SHORT (1 raw item < PageSize) → natural stop. (No
        # empty terminal page · an empty array returned THROUGH a Pester mock collapses to $null, an unrelated artifact.)
        $script:CallN = 0
        Mock -ModuleName Xdr.Common.Runtime Connect-XdrPortal { @{ Portal = 'Defender'; Sccauth = 'x'; XsrfToken = 'y' } }
        Mock -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp {
            $script:CallN++
            $rows = if ($script:CallN -eq 1) {
                @( @{ V = 'p1a' }, @{} )                                     # 2 raw items · 1 empty/all-null (gated → 1 row)
            } else {
                @( @{ V = 'p2a' } )                                          # 1 raw item · SHORT page → natural terminator
            }
            @{ StatusCode = 200; Body = @{ Results = $rows }; RawBody = '' }
        }
        Mock -ModuleName Xdr.Common.Runtime Get-XdrCheckpoint { @{ OperationKey = $OperationKey; Cursor = $null; BoundaryKeys = $null; ETag = $null } }
        Mock -ModuleName Xdr.Common.Runtime Save-XdrCheckpointAtomic { $true }
        Mock -ModuleName Xdr.Common.Runtime Send-ToDce { @{ Success = $true; RowsAccepted = @($Rows).Count; BytesIngested = 10 } }
        Mock -ModuleName Xdr.Common.Runtime Get-XdrCircuitState { @{ State = 'Closed'; FailureCount = 0; OpenedUtc = $null; ETag = $null } }
        Mock -ModuleName Xdr.Common.Runtime Test-XdrCircuitClosed { $true }
        Mock -ModuleName Xdr.Common.Runtime Update-XdrCircuitState { }
        Mock -ModuleName Xdr.Common.Runtime Lock-XdrSingleFlight { 'lease-granted' }
        Mock -ModuleName Xdr.Common.Runtime Unlock-XdrSingleFlight { $true }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrEvent { }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrException { }

        $script:SparseEntry = @{
            OperationKey = 'SparseOp'; Portal = 'Defender'; Category = 'Operations'; Method = 'GET'; SubPortal = 'mtp'; Path = '/x'
            ResponseShape = 'wrapper'; ItemsContainer = 'Results'
            IngestionMode = 'SNAPSHOT'
            Pagination = @{ Mode = 'pageSize'; PageSizeQuery = 'pageSize'; PageSize = 2; PageIndexQuery = 'pageIndex'; PageIndexStart = 1; CursorMode = 'pageIndexIncrement'; LoopGuard = 1000 }
            ProjectionMap = @{ V = '$.V' }
            DcrImmutableId = 'dcr-test'; DcrStreamName = 'Custom-Defender_Operations_CL'
        }
    }

    It 'keeps paging past a sparse page · fetches page 2 (pre-fix it stopped after page 1 · silent under-fetch)' {
        $r = Invoke-XdrEntryPoll -Entry $script:SparseEntry -CorrelationId 'm3a'
        $r.Success | Should -BeTrue
        # Page 1 (sparse · RAW==2==PageSize → continue · pre-fix the post-gate 1<2 stopped here), page 2 (RAW 1<2 → stop).
        Should -Invoke -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp -Times 2 -Exactly
    }
    It 'ingests both NON-empty rows (1 from sparse p1 + 1 from p2) · the p2 row is NOT lost to an early stop' {
        $r = Invoke-XdrEntryPoll -Entry $script:SparseEntry -CorrelationId 'm3b'
        $r.ItemCount | Should -Be 2
    }
}
