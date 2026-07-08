#Requires -Version 7.4
# WS-A / WS-B (audit 2026-06-12) · THE round-trip coverage that was MISSING — the methodology gap that let the
# live cross-cycle duplicate ship AND made the fix iterate 3×. Every prior exactly-once test mocked the checkpoint
# READ with a PLAIN-STRING hashtable (e.g. CheckpointReadFailLoud.Tests / ExactlyOnce.Tests `Cursor = '...'`), so
# the LOSSY boundary was invisible: production reads the table via `ConvertFrom-Json -AsHashtable`, which PROMOTES
# the stored ISO string to a [DateTime]; the old code returned that promoted value raw and every downstream
# `[string]` cast truncated it to whole seconds (06/05/2026 01:51:53 — the .7605698 GONE). Next no-ingest cycle the
# boundary row's EventTime (.7605698) tested `> ` the truncated high-water (.000) → re-ingested = the live dup.
# These tests mock the EXACT promoted shape (ConvertTo-Json | ConvertFrom-Json -AsHashtable) so the fidelity loss is
# caught at the boundary, generically, for every datetime-typed checkpoint field.

BeforeAll {
    $script:Repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $env:PSModulePath = (Join-Path $script:Repo 'src\Modules') + [IO.Path]::PathSeparator + $env:PSModulePath
    $psd1s = Get-ChildItem (Join-Path $script:Repo 'src\Modules') -Directory |
        ForEach-Object { Join-Path $_.FullName ($_.Name + '.psd1') } | Where-Object { Test-Path $_ }
    for ($pass = 1; $pass -le 4; $pass++) {
        foreach ($p in $psd1s) { try { Import-Module $p -Force -DisableNameChecking -ErrorAction Stop } catch { } }
    }
    function New-AcRow([string]$id, [string]$time) { @{ ActionId = $id; EventTime = $time } }
    # The production table-read shape: a hashtable serialized to JSON and read back with -AsHashtable promotes any
    # ISO-8601 string value to a [DateTime] — exactly what Get-XdrTableEntity returns.
    function ConvertTo-PromotedEntity([hashtable]$row) { $row | ConvertTo-Json -Compress | ConvertFrom-Json -AsHashtable }
}

Describe 'G-RT · Get-XdrCheckpoint preserves cursor sub-second fidelity across the -AsHashtable promotion' {
    It 'the promoted [DateTime] cursor is returned at FULL fidelity (not truncated by a [string] cast)' {
        $stored = @{ Cursor = '2026-05-06T01:51:53.7605698Z'; BoundaryKeys = 'K1'; ResumeHighWater = '2026-05-06T01:51:53.7605698Z' }
        $promoted = ConvertTo-PromotedEntity $stored
        # sanity: the read shape really is a promoted [DateTime] (the production reality the old tests never modelled)
        ($promoted['Cursor'] -is [datetime]) | Should -BeTrue
        Mock -ModuleName Xdr.Common.Runtime Get-XdrTableEntity { @{ Found = $true; ETag = 'e1'; Entity = $promoted } }
        $cp = Get-XdrCheckpoint -PartitionKey 'Defender_Operations' -OperationKey 'GetHistory'
        ([string]$cp.Cursor)          | Should -Match '\.7605698'   # sub-seconds survive (RED on the bare-[string] code)
        ([string]$cp.ResumeHighWater) | Should -Match '\.7605698'
    }
}

Describe 'G-RT · a boundary-only re-poll re-persists the high-water WITHOUT truncation (no cross-cycle dup)' {
    BeforeEach {
        $script:Entry = @{
            OperationKey = 'GetHistory'; Portal = 'Defender'; Category = 'Operations'; Method = 'GET'; SubPortal = 'mtp'; Path = '/x'
            ResponseShape = 'wrapper'; ItemsContainer = 'Results'
            IngestionMode = 'CURSOR'; CursorField = 'EventTime'; NaturalKey = @('ActionId')
            TimeFilter = @{ FieldName = 'EventTime'; Mode = 'ClientSideHighWater' }
            Pagination = @{ Mode = 'pageSize'; PageSizeQuery = 'pageSize'; PageSize = 500; PageIndexQuery = 'pageIndex'; CursorMode = 'pageIndexIncrement'; LoopGuard = 1000; SortByQuery = 'sortByField'; SortByField = 'EventTime'; SortOrderQuery = 'sortOrder'; SortOrder = 'Descending'; StopWhenCursorPassed = $true }
            ProjectionMap = @{ EventTime = '$.EventTime'; ActionId = '$.ActionId' }
            DcrImmutableId = 'dcr-test'; DcrStreamName = 'Custom-Defender_Operations_CL'
        }
        $env:XDRLR_DCE_ENDPOINT = 'https://dce-test.local'
        # the committed checkpoint, in the PRODUCTION promoted shape (Cursor at full fidelity = the boundary row's time)
        $promoted = ConvertTo-PromotedEntity @{ Cursor = '2026-05-06T01:51:53.7605698Z'; BoundaryKeys = 'K1' }
        Mock -ModuleName Xdr.Common.Runtime Connect-XdrPortal { @{ Portal = 'Defender'; Sccauth = 'x'; XsrfToken = 'y' } }
        Mock -ModuleName Xdr.Common.Runtime Get-XdrTableEntity { @{ Found = $true; ETag = 'e1'; Entity = $promoted } }
        # ONLY the boundary row comes back (nothing newer) — it is the already-ingested high-water tie.
        Mock -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp { @{ StatusCode = 200; Body = @{ Count = 1; Results = @((New-AcRow 'K1' '2026-05-06T01:51:53.7605698Z')) }; RawBody = '' } }
        Mock -ModuleName Xdr.Common.Runtime Save-XdrCheckpointAtomic { $global:XdrRtSaved = @{ Cursor = $Cursor; BoundaryKeys = $BoundaryKeys }; $true }
        Mock -ModuleName Xdr.Common.Runtime Send-ToDce { @{ Success = $true; RowsAccepted = @($Rows).Count; BytesIngested = 100 } }
        Mock -ModuleName Xdr.Common.Runtime Lock-XdrSingleFlight { 'lease-granted' }
        Mock -ModuleName Xdr.Common.Runtime Unlock-XdrSingleFlight { $true }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrEvent { }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrException { }
        $global:XdrRtSaved = $null
    }
    It 'ingests ZERO (the boundary tie is already seen) AND the re-persisted cursor keeps its sub-seconds' {
        $r = Invoke-XdrEntryPoll -Entry $script:Entry -CorrelationId 'rt-1'
        $r.Success | Should -BeTrue
        Should -Invoke -ModuleName Xdr.Common.Runtime Send-ToDce -Times 0 -Exactly   # no dup ingest this cycle
        $global:XdrRtSaved | Should -Not -BeNullOrEmpty
        # THE fix: the saved high-water must NOT be truncated to whole seconds. On the old bare-[string] code the
        # no-ingest path read the promoted [DateTime] and cast it to '06/05/2026 01:51:53' (no .7605698) → next
        # cycle the boundary row tested > the truncated high-water → the live duplicate. Full fidelity = no dup.
        ([string]$global:XdrRtSaved.Cursor) | Should -Match '\.7605698'
    }
}
