#Requires -Version 7.4
# U3b · ENTITY FAN-OUT proof (plan §16 U3b · §4.H entity edges · G-P · "works for ALL stream types"). Drives the
# REAL Invoke-XdrEntityFanout (which itself drives the REAL Invoke-XdrEntryPoll per entity) with the I/O boundaries
# mocked (auth · HTTP · DCE · checkpoint I/O · telemetry) EXACTLY like ExactlyOnce.Tests.ps1 / ResumablePagination.
# Proves the GENERIC, BOUNDED parent→child mechanism:
#   (a) N parent entity ids → N child polls (each under a COMPOSITE checkpoint key "<OperationKey>|<entityId>").
#   (b) per-entity EXACTLY-ONCE: each child checkpoints independently → a re-run of the SAME data ingests ZERO.
#   (c) Unresolved / empty-parent-cache → GRACEFUL SKIP (no throw · Success=$true no-op · the cycle continues).
#   (d) the entity cap (XDRLR_MAX_ENTITIES_PER_CYCLE) is ENFORCED (most-overdue-first · the rest fire next cycle).
#   (e) a NON-entity op (GetHistory · no {param}) is UNAFFECTED — it never enters the fan-out path.
# The entities are MOCKED (no live data · the per-op parent→child heuristic is validated at onboarding, not here).

BeforeAll {
    $script:Repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $psd1s = Get-ChildItem (Join-Path $script:Repo 'src\Modules') -Directory |
        ForEach-Object { Join-Path $_.FullName ($_.Name + '.psd1') } | Where-Object { Test-Path $_ }
    for ($pass = 1; $pass -le 4; $pass++) {
        foreach ($p in $psd1s) { try { Import-Module $p -Force -DisableNameChecking -ErrorAction Stop } catch { } }
    }

    function New-AcRow([string]$id, [string]$time) { @{ ActionId = $id; EventTime = $time } }

    $env:XDRLR_DCE_ENDPOINT = 'https://dce-test.local'

    # The CHILD entity manifest entry · a CURSOR op whose path carries an entity {CaseId} resolved by the DependsOn edge.
    # Identical data-plane to the GetHistory baseline so the child poll exercises the SAME exactly-once path per entity.
    $script:EntityEntry = @{
        OperationKey = 'ListCaseActivities'; Portal = 'Defender'; Category = 'Operations'; Subcategory = 'Action Center'
        Method = 'GET'; SubPortal = 'mtp'; Path = '/CaseManagement/be/cases/{CaseId}/activities'
        ResponseShape = 'wrapper'; ItemsContainer = 'Results'
        IngestionMode = 'CURSOR'; CursorField = 'EventTime'; NaturalKey = @('ActionId')
        TimeFilter = @{ FieldName = 'EventTime'; Mode = 'ClientSideHighWater' }
        Pagination = @{ Mode = 'pageSize'; PageSizeQuery = 'pageSize'; PageSize = 500; PageIndexQuery = 'pageIndex'; CursorMode = 'pageIndexIncrement'; LoopGuard = 1000; SortByQuery = 'sortByField'; SortByField = 'EventTime'; SortOrderQuery = 'sortOrder'; SortOrder = 'Descending'; StopWhenCursorPassed = $true }
        ProjectionMap = @{ EventTime = '$.EventTime'; ActionId = '$.ActionId' }
        DcrImmutableId = 'dcr-test'; DcrStreamName = 'Custom-Defender_Operations_CL'
        ParamSource = 'ParentOp'; EntityResolution = 'Resolved'
        DependsOn = @{ ParentOperationKey = 'ListCases'; ParentOperationId = 'ActionCenter.ListCases'; EntityIdField = 'caseId'; ParamName = 'CaseId'; MatchKind = 'ExactName' }
    }

    # ── Shared mock state (per-composite-key checkpoints · per-URL rows) · $global so module-scoped mock bodies see it ──
    # Composite-key checkpoint store · keyed by the child OperationKey "<op>|<id>". Save mock writes back here (the real
    # Table round-trip) so a re-run sees the prior cursor → per-entity exactly-once is genuinely exercised.
    $global:XdrFanCheckpoints = @{}
    # The rows each entity's child poll returns · keyed by entityId. The HTTP mock parses the {CaseId} out of the URL.
    $global:XdrFanRowsByEntity = @{}
    # Every (OperationKey,Rows) handed to Send-ToDce · proves which composite keys ingested + how many rows.
    $global:XdrFanIngested = [System.Collections.Generic.List[object]]::new()
    # Every child OperationKey whose poll requested HTTP (proves the fan-out count + the cap).
    $global:XdrFanPolledKeys = [System.Collections.Generic.List[string]]::new()

    function Reset-FanState {
        $global:XdrFanCheckpoints = @{}
        $global:XdrFanRowsByEntity = @{}
        $global:XdrFanIngested.Clear()
        $global:XdrFanPolledKeys.Clear()
        # Clear the module's bounded entity cache so each test feeds a FRESH id set (no cross-test id leakage · the cache
        # is module-scoped + persists across calls). Clear-XdrEntityCache (no args) wipes ALL parent keys.
        Clear-XdrEntityCache
    }

    # Standard mock set used by every fan-out test. Connect/HTTP/DCE/checkpoint/telemetry — same boundaries as ExactlyOnce.
    function Set-FanMocks {
        Mock -ModuleName Xdr.Common.Runtime Connect-XdrPortal { @{ Portal = 'Defender'; Sccauth = 'x'; XsrfToken = 'y' } }
        # HTTP mock · parse the entity id out of the path ('/cases/<id>/activities'), return that entity's rows (or none).
        Mock -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp {
            $eid = ''
            if ($Url -match '/cases/([^/]+)/activities') { $eid = [uri]::UnescapeDataString($Matches[1]) }
            $arr = [System.Collections.Generic.List[object]]::new()
            if ($eid -and $global:XdrFanRowsByEntity.ContainsKey($eid)) { foreach ($r in @($global:XdrFanRowsByEntity[$eid])) { [void]$arr.Add($r) } }
            @{ StatusCode = 200; Body = @{ Count = $arr.Count; Results = $arr.ToArray() }; RawBody = '' }
        }
        # Per-composite-key checkpoint read (default empty row when unseen).
        Mock -ModuleName Xdr.Common.Runtime Get-XdrCheckpoint {
            if ($global:XdrFanCheckpoints.ContainsKey($OperationKey)) { return $global:XdrFanCheckpoints[$OperationKey] }
            @{ OperationKey = $OperationKey; Cursor = $null; BoundaryKeys = $null; ResumePage = $null; ResumeCursor = $null; ResumeHighWater = $null; ResumeBoundaryKeys = $null; LastUpdatedUtc = $null; ETag = $null }
        }
        # Persist the saved state back into the per-key store (the real Table round-trip · so a re-run dedups).
        Mock -ModuleName Xdr.Common.Runtime Save-XdrCheckpointAtomic {
            $global:XdrFanCheckpoints[$OperationKey] = @{
                OperationKey = $OperationKey; Cursor = $Cursor; BoundaryKeys = $BoundaryKeys
                ResumePage = $ResumePage; ResumeCursor = $ResumeCursor; ResumeHighWater = $ResumeHighWater; ResumeBoundaryKeys = $ResumeBoundaryKeys
                LastUpdatedUtc = ([DateTime]::UtcNow.ToString('o')); ETag = 'etag-next'
            }
            $true
        }
        Mock -ModuleName Xdr.Common.Runtime Send-ToDce {
            $global:XdrFanIngested.Add(@{ Op = $StreamName; Rows = @($Rows) })
            @{ Success = $true; RowsAccepted = @($Rows).Count; BytesIngested = 50 * @($Rows).Count }
        }
        # Record which child key polled (the HTTP mock can't see the composite key · capture it via the breaker read,
        # which Invoke-XdrEntryPoll calls FIRST with the composite OperationKey). Return Closed so the poll proceeds.
        Mock -ModuleName Xdr.Common.Runtime Get-XdrCircuitState { $global:XdrFanPolledKeys.Add($OperationKey); @{ State = 'Closed'; FailureCount = 0; OpenedUtc = $null; ETag = $null } }
        Mock -ModuleName Xdr.Common.Runtime Test-XdrCircuitClosed { $true }
        Mock -ModuleName Xdr.Common.Runtime Update-XdrCircuitState { }
        # G3 · grant the single-flight lease for every child poll (real Blob-lease infra absent in unit tests · an
        # un-mocked acquire → $null → Invoke-XdrEntryPoll would skip each child as 'contended').
        Mock -ModuleName Xdr.Common.Runtime Lock-XdrSingleFlight { 'lease-granted' }
        Mock -ModuleName Xdr.Common.Runtime Unlock-XdrSingleFlight { $true }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrEvent { }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrException { }
    }
}

Describe 'U3b · entity fan-out · N entities → N child polls under composite keys (mechanism + bounds)' {
    BeforeEach {
        Reset-FanState
        Set-FanMocks
        # Three parent entity ids, each with its OWN child rows (distinct ActionIds so we can prove per-entity ingest).
        $global:XdrFanRowsByEntity = @{
            'case-A' = @((New-AcRow 'A1' '2026-05-01T00:00:00Z'), (New-AcRow 'A2' '2026-05-02T00:00:00Z'))
            'case-B' = @((New-AcRow 'B1' '2026-05-01T00:00:00Z'))
            'case-C' = @((New-AcRow 'C1' '2026-05-03T00:00:00Z'), (New-AcRow 'C2' '2026-05-04T00:00:00Z'), (New-AcRow 'C3' '2026-05-05T00:00:00Z'))
        }
        # Seed the bounded entity cache with the three parent ids (the parent op would feed these from its ingested rows).
        Add-XdrEntityIds -Portal 'Defender' -Category 'Operations' -ParentOperationKey 'ListCases' -Ids @('case-A','case-B','case-C')
    }

    It 'fans out to all 3 entities · polls each child under "<OperationKey>|<id>" · NEVER throws' {
        $r = $null
        { $script:r = Invoke-XdrEntityFanout -Entry $script:EntityEntry -CorrelationId 'fc1' } | Should -Not -Throw
        $r = $script:r
        $r.Skipped | Should -BeFalse
        $r.Success | Should -BeTrue
        $r.EntitiesAvailable | Should -Be 3
        $r.EntitiesPolled    | Should -Be 3
        # Each entity polled under its COMPOSITE key.
        $global:XdrFanPolledKeys | Should -Contain 'ListCaseActivities|case-A'
        $global:XdrFanPolledKeys | Should -Contain 'ListCaseActivities|case-B'
        $global:XdrFanPolledKeys | Should -Contain 'ListCaseActivities|case-C'
    }

    It 'each entity ingests its OWN rows exactly once (6 total: 2 + 1 + 3) · aggregate ItemCount' {
        $r = Invoke-XdrEntityFanout -Entry $script:EntityEntry -CorrelationId 'fc2'
        $r.ItemCount | Should -Be 6
        ($global:XdrFanIngested | ForEach-Object { @($_.Rows).Count } | Measure-Object -Sum).Sum | Should -Be 6
    }

    It 'each entity checkpoints UNDER ITS OWN composite key with its own high-water' {
        $null = Invoke-XdrEntityFanout -Entry $script:EntityEntry -CorrelationId 'fc3'
        $global:XdrFanCheckpoints.ContainsKey('ListCaseActivities|case-A') | Should -BeTrue
        $global:XdrFanCheckpoints.ContainsKey('ListCaseActivities|case-C') | Should -BeTrue
        # case-A high-water = max EventTime of A1/A2 (day 2 · key A2); case-C = day 5 (key C3) — INDEPENDENT.
        $global:XdrFanCheckpoints['ListCaseActivities|case-A'].Cursor | Should -Match '2026-05-02'
        $global:XdrFanCheckpoints['ListCaseActivities|case-A'].BoundaryKeys | Should -Be 'A2'
        $global:XdrFanCheckpoints['ListCaseActivities|case-C'].Cursor | Should -Match '2026-05-05'
        $global:XdrFanCheckpoints['ListCaseActivities|case-C'].BoundaryKeys | Should -Be 'C3'
    }
}

Describe 'U3b · per-entity EXACTLY-ONCE · a re-run of the SAME data ingests ZERO' {
    BeforeEach {
        Reset-FanState
        Set-FanMocks
        $global:XdrFanRowsByEntity = @{
            'case-A' = @((New-AcRow 'A1' '2026-05-01T00:00:00Z'), (New-AcRow 'A2' '2026-05-02T00:00:00Z'))
            'case-B' = @((New-AcRow 'B1' '2026-05-03T00:00:00Z'))
        }
        Add-XdrEntityIds -Portal 'Defender' -Category 'Operations' -ParentOperationKey 'ListCases' -Ids @('case-A','case-B')
    }

    It 'cycle 1 ingests all · cycle 2 (same data) ingests ZERO per entity (composite-key exactly-once · NO DCR dedup)' {
        $r1 = Invoke-XdrEntityFanout -Entry $script:EntityEntry -CorrelationId 'ee1'
        $r1.ItemCount | Should -Be 3                                          # A1,A2 + B1
        # Re-feed the cache (TTL/clearing aside · the parent would re-feed each cycle) and re-run with IDENTICAL rows.
        Add-XdrEntityIds -Portal 'Defender' -Category 'Operations' -ParentOperationKey 'ListCases' -Ids @('case-A','case-B')
        $global:XdrFanIngested.Clear()
        $r2 = Invoke-XdrEntityFanout -Entry $script:EntityEntry -CorrelationId 'ee2'
        $r2.Skipped | Should -BeFalse
        $r2.ItemCount | Should -Be 0                                          # every row <= each entity's committed high-water → dropped
        @($global:XdrFanIngested).Count | Should -Be 0
    }

    It 'a NEW row at one entity (newer EventTime) ingests EXACTLY ONCE while the others stay at zero' {
        $null = Invoke-XdrEntityFanout -Entry $script:EntityEntry -CorrelationId 'ee3'   # commit case-A@day2, case-B@day3
        # case-A gains a newer A3@day4; case-B unchanged.
        $global:XdrFanRowsByEntity['case-A'] = @((New-AcRow 'A1' '2026-05-01T00:00:00Z'), (New-AcRow 'A2' '2026-05-02T00:00:00Z'), (New-AcRow 'A3' '2026-05-04T00:00:00Z'))
        Add-XdrEntityIds -Portal 'Defender' -Category 'Operations' -ParentOperationKey 'ListCases' -Ids @('case-A','case-B')
        $global:XdrFanIngested.Clear()
        $r = Invoke-XdrEntityFanout -Entry $script:EntityEntry -CorrelationId 'ee4'
        $r.ItemCount | Should -Be 1                                           # only A3 (case-A); case-B re-ingests nothing
        $all = $global:XdrFanIngested | ForEach-Object { $_.Rows } | ForEach-Object { $_.ActionId }
        @($all) | Should -Be @('A3')
        $global:XdrFanCheckpoints['ListCaseActivities|case-A'].Cursor | Should -Match '2026-05-04'
    }
}

Describe 'U3b · NEVER-REFUSE · graceful skip on unresolved / empty parent (cycle continues · no throw)' {
    BeforeEach { Reset-FanState; Set-FanMocks }

    It 'an UNRESOLVED entity op (no DependsOn) is SKIPPED · Success=$true no-op · NEVER throws' {
        $unresolved = @{}
        foreach ($k in $script:EntityEntry.Keys) { $unresolved[$k] = $script:EntityEntry[$k] }
        $unresolved.Remove('DependsOn'); $unresolved['EntityResolution'] = 'Unresolved'
        $r = $null
        { $script:r = Invoke-XdrEntityFanout -Entry $unresolved -CorrelationId 'un1' } | Should -Not -Throw
        $r = $script:r
        $r.Skipped | Should -BeTrue
        $r.Success | Should -BeTrue                                           # an intentional skip is a successful no-op
        $r.SkipReason | Should -Match 'Unresolved|no DependsOn'
        $r.EntitiesPolled | Should -Be 0
        Should -Invoke -ModuleName Xdr.Common.Runtime Send-ToDce -Times 0 -Exactly
    }

    It 'EntityResolution!=Resolved is skipped even WITH a DependsOn block (honest gating)' {
        $pending = @{}
        foreach ($k in $script:EntityEntry.Keys) { $pending[$k] = $script:EntityEntry[$k] }
        $pending['EntityResolution'] = 'Pending'
        $r = Invoke-XdrEntityFanout -Entry $pending -CorrelationId 'un2'
        $r.Skipped | Should -BeTrue
        $r.Success | Should -BeTrue
        $r.SkipReason | Should -Match "Resolved"
    }

    It 'an EMPTY parent cache (resolved edge · no seeded ids · no ParentEntry) SKIPS gracefully · cycle continues' {
        # Use a parent key that was never fed → cache miss → skip.
        $entry = @{}
        foreach ($k in $script:EntityEntry.Keys) { $entry[$k] = $script:EntityEntry[$k] }
        $entry['DependsOn'] = @{ ParentOperationKey = 'NeverFedParent'; ParentOperationId = 'X.NeverFed'; EntityIdField = 'caseId'; ParamName = 'CaseId'; MatchKind = 'ExactName' }
        $r = $null
        { $script:r = Invoke-XdrEntityFanout -Entry $entry -CorrelationId 'un3' } | Should -Not -Throw
        $r = $script:r
        $r.Skipped | Should -BeTrue
        $r.Success | Should -BeTrue
        $r.SkipReason | Should -Match 'cache empty'
        $r.EntitiesPolled | Should -Be 0
    }

    It 'a child poll FAILURE for one entity does NOT abort the others (per-entity isolation · never throws)' {
        # case-OK returns rows; case-BAD's HTTP throws — Invoke-XdrEntryPoll catches it (Success=$false) and the fan-out
        # continues. The fan-out itself must NEVER throw and must still report Success.
        Mock -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp {
            $eid = ''
            if ($Url -match '/cases/([^/]+)/activities') { $eid = [uri]::UnescapeDataString($Matches[1]) }
            if ($eid -eq 'case-BAD') { throw 'simulated portal 500 for case-BAD' }
            $arr = [System.Collections.Generic.List[object]]::new()
            if ($eid -and $global:XdrFanRowsByEntity.ContainsKey($eid)) { foreach ($r in @($global:XdrFanRowsByEntity[$eid])) { [void]$arr.Add($r) } }
            @{ StatusCode = 200; Body = @{ Count = $arr.Count; Results = $arr.ToArray() }; RawBody = '' }
        }
        $global:XdrFanRowsByEntity = @{ 'case-OK' = @((New-AcRow 'OK1' '2026-05-01T00:00:00Z')) }
        Add-XdrEntityIds -Portal 'Defender' -Category 'Operations' -ParentOperationKey 'ListCases' -Ids @('case-OK','case-BAD')
        $r = $null
        { $script:r = Invoke-XdrEntityFanout -Entry $script:EntityEntry -CorrelationId 'un4' } | Should -Not -Throw
        $r = $script:r
        $r.Success | Should -BeTrue                                           # the cycle survives a per-entity failure
        $r.EntitiesPolled | Should -Be 2
        $r.ItemCount | Should -Be 1                                           # only case-OK ingested
    }
}

Describe 'U3b · entity CAP enforcement (XDRLR_MAX_ENTITIES_PER_CYCLE · most-overdue-first · rest next cycle)' {
    BeforeEach {
        Reset-FanState; Set-FanMocks
        # 5 entities, each with one row · cap at 2 → only 2 polled this cycle.
        $global:XdrFanRowsByEntity = @{
            'e1' = @((New-AcRow 'r1' '2026-05-01T00:00:00Z'))
            'e2' = @((New-AcRow 'r2' '2026-05-01T00:00:00Z'))
            'e3' = @((New-AcRow 'r3' '2026-05-01T00:00:00Z'))
            'e4' = @((New-AcRow 'r4' '2026-05-01T00:00:00Z'))
            'e5' = @((New-AcRow 'r5' '2026-05-01T00:00:00Z'))
        }
        Add-XdrEntityIds -Portal 'Defender' -Category 'Operations' -ParentOperationKey 'ListCases' -Ids @('e1','e2','e3','e4','e5')
    }
    AfterEach { Remove-Item Env:\XDRLR_MAX_ENTITIES_PER_CYCLE -ErrorAction SilentlyContinue }

    It 'caps the fan-out at the budget (2 of 5) · the other 3 are deferred · 5 remain available' {
        $env:XDRLR_MAX_ENTITIES_PER_CYCLE = '2'
        $r = Invoke-XdrEntityFanout -Entry $script:EntityEntry -CorrelationId 'cap1'
        $r.EntitiesAvailable | Should -Be 5
        $r.EntitiesPolled    | Should -Be 2                                  # bounded · NOT 5 (no fan-out explosion)
        @($global:XdrFanPolledKeys).Count | Should -Be 2
    }

    It 'most-overdue-first · entities with the OLDEST checkpoint run before recently-polled ones' {
        $env:XDRLR_MAX_ENTITIES_PER_CYCLE = '2'
        # Pre-seed checkpoints: e3/e4/e5 polled "now" (recent · low priority); e1/e2 have NO checkpoint (most overdue).
        $recent = ([DateTime]::UtcNow.ToString('o'))
        foreach ($k in @('e3','e4','e5')) { $global:XdrFanCheckpoints["ListCaseActivities|$k"] = @{ OperationKey = "ListCaseActivities|$k"; Cursor = '2026-05-01T00:00:00Z'; BoundaryKeys = "r"; LastUpdatedUtc = $recent; ETag = 'e' } }
        $null = Invoke-XdrEntityFanout -Entry $script:EntityEntry -CorrelationId 'cap2'
        # The 2 polled must be e1 + e2 (the never-checkpointed = most overdue), NOT the recently-polled e3/e4/e5.
        $global:XdrFanPolledKeys | Should -Contain 'ListCaseActivities|e1'
        $global:XdrFanPolledKeys | Should -Contain 'ListCaseActivities|e2'
        $global:XdrFanPolledKeys | Should -Not -Contain 'ListCaseActivities|e3'
    }

    It 'default cap (no env var) polls all 5 (5 << default 50 · no artificial throttle)' {
        $r = Invoke-XdrEntityFanout -Entry $script:EntityEntry -CorrelationId 'cap3'
        $r.EntitiesPolled | Should -Be 5
    }
}

Describe 'E-MAJ3 · per-entity CADENCE GATE · poll an entity only when its composite checkpoint is DUE (op Cadence)' {
    # The fanout op writes ONLY composite <opKey>|<id> checkpoints, so the dispatch G-Cadence gate (which point-reads
    # the BASE opKey) never finds one → the op is "first-cycle-ever" → DUE every 1-min cycle. Ungated that re-polled
    # EVERY entity EVERY cycle (live: 1078 child-polls/2h for 9 entities on a 6h tier). The gate filters each entity by
    # ITS OWN composite checkpoint vs the op's Cadence: eligible only if never-polled OR (now − itsLastUtc) >= cadence.
    BeforeEach {
        Reset-FanState; Set-FanMocks
        # The child op now carries a 6h Cadence (TimeSpan · same format the dispatch G-Cadence parses).
        $script:CadencedEntry = @{}
        foreach ($k in $script:EntityEntry.Keys) { $script:CadencedEntry[$k] = $script:EntityEntry[$k] }
        $script:CadencedEntry['Cadence'] = '06:00:00'
        $global:XdrFanRowsByEntity = @{
            'due-never' = @((New-AcRow 'n1' '2026-05-01T00:00:00Z'))
            'due-old'   = @((New-AcRow 'o1' '2026-05-01T00:00:00Z'))
            'notdue-1'  = @((New-AcRow 'x1' '2026-05-01T00:00:00Z'))
            'notdue-2'  = @((New-AcRow 'x2' '2026-05-01T00:00:00Z'))
        }
        Add-XdrEntityIds -Portal 'Defender' -Category 'Operations' -ParentOperationKey 'ListCases' -Ids @('due-never','due-old','notdue-1','notdue-2')
    }

    It 'polls ONLY the due entities (never-polled + checkpoint older than cadence) · skips the recently-polled' {
        $recent = ([DateTime]::UtcNow.AddMinutes(-30).ToString('o'))           # 30m ago · < 6h → NOT due
        $old    = ([DateTime]::UtcNow.AddHours(-8).ToString('o'))              # 8h ago · >= 6h → due
        $global:XdrFanCheckpoints['ListCaseActivities|due-old']  = @{ OperationKey='ListCaseActivities|due-old';  Cursor='2026-05-01T00:00:00Z'; BoundaryKeys='o'; LastUpdatedUtc=$old;    ETag='e' }
        $global:XdrFanCheckpoints['ListCaseActivities|notdue-1'] = @{ OperationKey='ListCaseActivities|notdue-1'; Cursor='2026-05-01T00:00:00Z'; BoundaryKeys='x'; LastUpdatedUtc=$recent; ETag='e' }
        $global:XdrFanCheckpoints['ListCaseActivities|notdue-2'] = @{ OperationKey='ListCaseActivities|notdue-2'; Cursor='2026-05-01T00:00:00Z'; BoundaryKeys='x'; LastUpdatedUtc=$recent; ETag='e' }
        # 'due-never' has NO checkpoint → MinValue → due.
        $r = Invoke-XdrEntityFanout -Entry $script:CadencedEntry -CorrelationId 'cad1'
        $r.EntitiesAvailable | Should -Be 4
        $r.EntitiesPolled    | Should -Be 2                                    # only due-never + due-old
        $global:XdrFanPolledKeys | Should -Contain 'ListCaseActivities|due-never'
        $global:XdrFanPolledKeys | Should -Contain 'ListCaseActivities|due-old'
        $global:XdrFanPolledKeys | Should -Not -Contain 'ListCaseActivities|notdue-1'
        $global:XdrFanPolledKeys | Should -Not -Contain 'ListCaseActivities|notdue-2'
    }

    It 'when ALL entities are within cadence → polls ZERO (the op fires + completes but selects nothing · the storm fix)' {
        $recent = ([DateTime]::UtcNow.AddMinutes(-5).ToString('o'))
        foreach ($k in @('due-never','due-old','notdue-1','notdue-2')) {
            $global:XdrFanCheckpoints["ListCaseActivities|$k"] = @{ OperationKey="ListCaseActivities|$k"; Cursor='2026-05-01T00:00:00Z'; BoundaryKeys='r'; LastUpdatedUtc=$recent; ETag='e' }
        }
        $r = Invoke-XdrEntityFanout -Entry $script:CadencedEntry -CorrelationId 'cad2'
        $r.EntitiesAvailable | Should -Be 4
        $r.EntitiesPolled    | Should -Be 0                                    # NONE due → no child polls
        @($global:XdrFanPolledKeys).Count | Should -Be 0
        $r.Success | Should -BeTrue                                            # fires + completes cleanly · just polls nothing
    }

    It 'NO Cadence on the entry → fail-open → polls ALL (backward-compatible · a gate slip never blocks the cycle)' {
        $r = Invoke-XdrEntityFanout -Entry $script:EntityEntry -CorrelationId 'cad3'   # EntityEntry has NO Cadence
        $r.EntitiesPolled | Should -Be 4
    }
}

Describe 'U3b · bounded cache hard-cap + parent-poll fallback (self-sufficient · works for all stream types)' {
    BeforeEach { Reset-FanState; Set-FanMocks }
    AfterEach { Remove-Item Env:\XDRLR_ENTITY_CACHE_MAX -ErrorAction SilentlyContinue }

    It 'the entity cache is HARD-CAPPED (10k entities can never blow it · newest retained)' {
        $env:XDRLR_ENTITY_CACHE_MAX = '100'
        $many = 1..500 | ForEach-Object { "id-$_" }
        Add-XdrEntityIds -Portal 'Defender' -Category 'Operations' -ParentOperationKey 'BigParent' -Ids $many
        $cached = @(Get-XdrCachedEntityIds -Portal 'Defender' -Category 'Operations' -ParentOperationKey 'BigParent')
        $cached.Count | Should -Be 100                                       # capped · NOT 500
        $cached | Should -Contain 'id-500'                                   # newest retained
        $cached | Should -Not -Contain 'id-1'                               # oldest evicted
    }

    It 'Get-XdrEntityIdField harvests the id field from parent rows (de-duped · order-preserving · StrictMode-safe)' {
        $rows = @(
            @{ caseId = 'c1'; name = 'x' }, @{ caseId = 'c2' }, @{ caseId = 'c1' },   # dup c1
            @{ name = 'no-id-here' },                                                  # missing field → skipped
            @{ caseId = '' }                                                           # empty → skipped
        )
        $ids = @(Get-XdrEntityIdField -Rows $rows -EntityIdField 'caseId')
        $ids | Should -Be @('c1','c2')
    }

    It 'an EMPTY cache + a ParentEntry → ONE bounded parent poll seeds the ids → fan-out proceeds' {
        # The parent op is a list at /CaseManagement/be/cases returning items with a caseId field.
        Mock -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp {
            if ($Url -match '/cases/([^/]+)/activities') {
                # CHILD poll · return that entity's rows.
                $eid = [uri]::UnescapeDataString($Matches[1])
                $arr = [System.Collections.Generic.List[object]]::new()
                if ($global:XdrFanRowsByEntity.ContainsKey($eid)) { foreach ($r in @($global:XdrFanRowsByEntity[$eid])) { [void]$arr.Add($r) } }
                return @{ StatusCode = 200; Body = @{ Results = $arr.ToArray() }; RawBody = '' }
            }
            # PARENT list poll (/cases) · return two case items.
            @{ StatusCode = 200; Body = @{ Results = @(@{ caseId = 'pc-1' }, @{ caseId = 'pc-2' }) }; RawBody = '' }
        }
        $global:XdrFanRowsByEntity = @{ 'pc-1' = @((New-AcRow 'P1' '2026-05-01T00:00:00Z')); 'pc-2' = @((New-AcRow 'P2' '2026-05-02T00:00:00Z')) }
        $parentEntry = @{ OperationKey = 'ListCases'; Portal = 'Defender'; Category = 'Operations'; Subcategory = 'Action Center'; Method = 'GET'; SubPortal = 'mtp'; Path = '/CaseManagement/be/cases'; ResponseShape = 'wrapper'; ItemsContainer = 'Results'; ProjectionMap = @{ caseId = '$.caseId' } }
        $r = Invoke-XdrEntityFanout -Entry $script:EntityEntry -CorrelationId 'pp1' -ParentEntry $parentEntry
        $r.Skipped | Should -BeFalse
        $r.EntitiesAvailable | Should -Be 2
        $r.EntitiesPolled    | Should -Be 2
        $r.ItemCount         | Should -Be 2
    }

    It 'a FAILING parent poll (empty cache · parent HTTP throws) surfaces a DISTINCT non-success · never throws (E-MAJ2)' {
        # E-MAJ2 · a THROWN seed poll is a REAL parent-feed failure, NOT a benign 0-id parent. It must NOT be masked as a
        # Success=$true graceful skip (which the breaker would never escalate) — it surfaces Success=$false + a distinct
        # ErrorClass so the Activity records it and the breaker can act on REPEATED parent-feed failure. The fan-out STILL
        # never throws and STILL polls no children (the cycle continues; the breaker, not a throw, governs escalation).
        Mock -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp { throw 'parent list 500' }
        $parentEntry = @{ OperationKey = 'ListCases'; Portal = 'Defender'; Category = 'Operations'; Method = 'GET'; SubPortal = 'mtp'; Path = '/CaseManagement/be/cases'; ResponseShape = 'wrapper'; ItemsContainer = 'Results' }
        $r = $null
        { $script:r = Invoke-XdrEntityFanout -Entry $script:EntityEntry -CorrelationId 'pp2' -ParentEntry $parentEntry } | Should -Not -Throw
        $r = $script:r
        $r.Skipped | Should -BeTrue
        $r.Success | Should -BeFalse                                          # E-MAJ2 · real parent-feed failure ≠ benign skip
        $r.ErrorClass | Should -Be 'XdrEntityParentFeedFailed'                # breaker-actionable · distinct from empty-parent
        $r.SkipReason | Should -Match 'SEED poll FAILED'
        $r.EntitiesPolled | Should -Be 0
    }
}

Describe 'U3b · NON-entity op is UNAFFECTED (GetHistory takes the normal poll path · byte-identical)' {
    BeforeEach {
        Reset-FanState; Set-FanMocks
        $script:GetHistoryEntry = @{
            OperationKey = 'GetHistory'; Portal = 'Defender'; Category = 'Operations'; Subcategory = 'Action Center'
            Method = 'GET'; SubPortal = 'mtp'; Path = '/actionCenter/actioncenterui/history-actions'
            ResponseShape = 'wrapper'; ItemsContainer = 'Results'
            IngestionMode = 'CURSOR'; CursorField = 'EventTime'; NaturalKey = @('ActionId')
            TimeFilter = @{ FieldName = 'EventTime'; Mode = 'ClientSideHighWater' }
            Pagination = @{ Mode = 'pageSize'; PageSizeQuery = 'pageSize'; PageSize = 500; PageIndexQuery = 'pageIndex'; CursorMode = 'pageIndexIncrement'; LoopGuard = 1000 }
            ProjectionMap = @{ EventTime = '$.EventTime'; ActionId = '$.ActionId' }
            DcrImmutableId = 'dcr-test'; DcrStreamName = 'Custom-Defender_Operations_CL'
            ParamSource = 'None'   # NOT an entity op · no DependsOn
        }
    }

    It 'GetHistory has NO DependsOn and ParamSource=None → it is NOT an entity op (must use the normal path)' {
        $script:GetHistoryEntry.ContainsKey('DependsOn') | Should -BeFalse
        $script:GetHistoryEntry['ParamSource'] | Should -Be 'None'
    }

    It 'Invoke-XdrEntryPoll on GetHistory ingests normally under its PLAIN key (no composite · no fan-out)' {
        $global:XdrFanRowsByEntity = @{}   # not used · GetHistory path-less HTTP mock below
        Mock -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp { @{ StatusCode = 200; Body = @{ Count = 2; Results = @((New-AcRow 'H1' '2026-05-01T00:00:00Z'), (New-AcRow 'H2' '2026-05-02T00:00:00Z')) }; RawBody = '' } }
        $r = Invoke-XdrEntryPoll -Entry $script:GetHistoryEntry -CorrelationId 'gh1'
        $r.Success | Should -BeTrue
        $r.OperationKey | Should -Be 'GetHistory'                            # PLAIN key · no '|<id>' suffix
        $r.ItemCount | Should -Be 2
        Should -Invoke -ModuleName Xdr.Common.Runtime Save-XdrCheckpointAtomic -Times 1 -Exactly -ParameterFilter { $OperationKey -eq 'GetHistory' }
    }

    It 'the dispatcher routing predicate classifies GetHistory as NON-entity and the child as entity' {
        # Mirror the XdrDefenderActivity routing predicate exactly.
        $isEntity = { param($e) ($e['DependsOn'] -is [System.Collections.IDictionary]) -or ([string]$e['ParamSource'] -eq 'ParentOp') }
        (& $isEntity $script:GetHistoryEntry) | Should -BeFalse                # → normal Invoke-XdrEntryPoll
        (& $isEntity $script:EntityEntry)     | Should -BeTrue                 # → Invoke-XdrEntityFanout
    }
}
