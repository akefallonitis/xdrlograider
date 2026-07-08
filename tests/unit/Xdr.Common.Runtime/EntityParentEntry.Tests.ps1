#Requires -Version 7.4
# Φ3 (N4 entity feeder) · the entity op must POLL ITS {id} in production. Invoke-XdrEntityFanout's self-sufficient
# fallback (Get-XdrParentEntityIds · ONE bounded parent poll to seed the id cache when empty) ALREADY existed but was
# never reachable: the Activity called the fan-out with NO -ParentEntry. Fix = Get-XdrManifests attaches each entity
# op's PARENT poll-contract as $op['ParentEntry'] (Set-XdrParentEntryLinks · in-memory · committed manifests unchanged),
# and the Activity passes it. This proves both halves: (1) the loader attaches ParentEntry; (2) the fan-out, given an
# EMPTY cache + a ParentEntry, resolves ids via the fallback and polls each {id} (vs graceful-skip without one).

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

Describe 'Get-XdrManifests attaches ParentEntry to each entity op (N4 · Set-XdrParentEntryLinks)' {
    BeforeAll {
        $script:tmpRoot = Join-Path ([IO.Path]::GetTempPath()) "xdrlr-pe-$([guid]::NewGuid().Guid)"
        New-Item -ItemType Directory -Path (Join-Path $script:tmpRoot 'Defender') -Force | Out-Null
        $psd1 = @'
@{
    Portal = 'Defender'
    Category = 'Operations'
    Operations = @(
        # ops carry ONLY Subcategory (the REAL psd1 shape) — Portal/Category live at the manifest root; the loader stamps them.
        @{ OperationKey = 'ListCases'; Method = 'GET'; SubPortal = 'mtp'; Path = '/cases'; ResponseShape = 'wrapper'; ItemsContainer = 'Results'; ProjectionMap = @{ caseId = '$.id' } }
        @{ OperationKey = 'ListCaseActivities'; Method = 'GET'; SubPortal = 'mtp'; Path = '/cases/{CaseId}/activities'; ResponseShape = 'wrapper'; ItemsContainer = 'Results'; ProjectionMap = @{ ActionId = '$.id' }; EntityResolution = 'Resolved'; DependsOn = @{ ParentOperationKey = 'ListCases'; EntityIdField = 'caseId'; ParamName = 'CaseId' } }
    )
}
'@
        Set-Content -Path (Join-Path $script:tmpRoot 'Defender/Operations.psd1') -Value $psd1 -Encoding utf8
        $script:loaded = Get-XdrManifests -Root $script:tmpRoot -Force
        $script:ops = @($script:loaded['Defender']['Operations']['Operations'])
        $script:child  = $script:ops | Where-Object { $_['OperationKey'] -eq 'ListCaseActivities' } | Select-Object -First 1
        $script:parent = $script:ops | Where-Object { $_['OperationKey'] -eq 'ListCases' }          | Select-Object -First 1
    }
    AfterAll { if ($script:tmpRoot -and (Test-Path $script:tmpRoot)) { Remove-Item $script:tmpRoot -Recurse -Force -ErrorAction SilentlyContinue } }

    It 'the ENTITY op gains a ParentEntry carrying the parent poll-contract (RED pre-fix)' {
        $script:child['ParentEntry'] | Should -Not -BeNullOrEmpty
        $script:child['ParentEntry']['OperationKey'] | Should -Be 'ListCases'
        $script:child['ParentEntry']['Path']         | Should -Be '/cases'
        $script:child['ParentEntry']['ProjectionMap']['caseId'] | Should -Be '$.id'
    }
    It 'the ParentEntry excludes DependsOn/ParentEntry (no recursion/bloat)' {
        $script:child['ParentEntry'].ContainsKey('DependsOn')   | Should -BeFalse
        $script:child['ParentEntry'].ContainsKey('ParentEntry') | Should -BeFalse
    }
    It 'a NON-entity op gets NO ParentEntry' {
        $script:parent.ContainsKey('ParentEntry') | Should -BeFalse
    }
    It 'every op SELF-DESCRIBES Portal+Category stamped from the manifest root (load-time · not just dispatched ops)' {
        # REGRESSION (2026-06-18): the psd1 ops carry only Subcategory; Portal/Category live at the root. Get-XdrManifests
        # stamps them onto every op so $entry['Category'] is non-empty for EVERY consumer (normal poll, fan-out child/parent).
        $script:parent['Category'] | Should -Be 'Operations'
        $script:parent['Portal']   | Should -Be 'Defender'
        $script:child['Category']  | Should -Be 'Operations'
        $script:child['Portal']    | Should -Be 'Defender'
    }
    It 'the ParentEntry carries the stamped Category+Portal (regression · the empty-Category parent-poll bind-fail, 2026-06-18)' {
        # WITHOUT the load-time stamp the subset (built from the raw indexed parent op, which had no Category) shipped
        # Category-less → Get-XdrParentEntityIds called ConvertTo-XdrRows -Category '' → bind-fail EVERY cycle → the entity
        # fan-out silently starved (live-caught: ListPostureOversightInitiatives, 2026-06-18).
        $script:child['ParentEntry']['Category'] | Should -Be 'Operations'
        $script:child['ParentEntry']['Portal']   | Should -Be 'Defender'
    }
}

Describe 'Invoke-XdrEntityFanout resolves + polls via the ParentEntry fallback when the cache is EMPTY' {
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
        $global:PeChildKeys = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Xdr.Common.Runtime Connect-XdrPortal { @{ Portal = 'Defender'; Sccauth = 'x'; XsrfToken = 'y' } }
        Mock -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp { @{ StatusCode = 200; Body = @{ Results = @() }; RawBody = '' } }
        Mock -ModuleName Xdr.Common.Runtime Get-XdrCheckpoint { @{ OperationKey = $OperationKey; Cursor = $null; BoundaryKeys = $null; ETag = $null } }
        Mock -ModuleName Xdr.Common.Runtime Save-XdrCheckpointAtomic { $true }
        Mock -ModuleName Xdr.Common.Runtime Send-ToDce { @{ Success = $true; RowsAccepted = 0; BytesIngested = 0 } }
        Mock -ModuleName Xdr.Common.Runtime Get-XdrCircuitState { $global:PeChildKeys.Add($OperationKey); @{ State = 'Closed'; FailureCount = 0; OpenedUtc = $null; ETag = $null } }
        Mock -ModuleName Xdr.Common.Runtime Test-XdrCircuitClosed { $true }
        Mock -ModuleName Xdr.Common.Runtime Update-XdrCircuitState { }
        Mock -ModuleName Xdr.Common.Runtime Lock-XdrSingleFlight { 'lease-granted' }
        Mock -ModuleName Xdr.Common.Runtime Unlock-XdrSingleFlight { $true }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrEvent { }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrException { }
        # The parent poll (Get-XdrParentEntityIds) is the seam under test: with a ParentEntry it returns the parent ids.
        Mock -ModuleName Xdr.Common.Runtime Get-XdrParentEntityIds { @('case-A', 'case-B') }
    }

    It 'WITH ParentEntry + empty cache → resolves 2 ids via the fallback + polls each {id} (NOT a skip)' {
        $r = Invoke-XdrEntityFanout -Entry $script:EntityEntry -CorrelationId 'pe1' -ParentEntry $script:EntityEntry['ParentEntry']
        $r.Skipped | Should -BeFalse
        $r.EntitiesAvailable | Should -Be 2
        $r.EntitiesPolled    | Should -Be 2
        Should -Invoke -ModuleName Xdr.Common.Runtime Get-XdrParentEntityIds -Times 1 -Exactly
        @($global:PeChildKeys) | Should -Contain 'ListCaseActivities|case-A'
        @($global:PeChildKeys) | Should -Contain 'ListCaseActivities|case-B'
    }
    It 'WITHOUT ParentEntry + empty cache → graceful skip (the prior production behavior · proves the fallback is the fix)' {
        $r = Invoke-XdrEntityFanout -Entry $script:EntityEntry -CorrelationId 'pe2'
        $r.Skipped | Should -BeTrue
        $r.EntitiesAvailable | Should -Be 0
        Should -Invoke -ModuleName Xdr.Common.Runtime Get-XdrParentEntityIds -Times 0 -Exactly
    }
}
