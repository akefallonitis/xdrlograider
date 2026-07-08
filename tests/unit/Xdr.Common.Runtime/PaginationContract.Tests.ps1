#Requires -Version 7.4
# G-J · dead-contract-field honor. Two manifest Pagination fields that the runtime previously IGNORED are now
# read by Invoke-XdrEntryPoll's page loop:
#   (a) TotalCountPath  · the server's total-row count (e.g. 'Count') · stop paging once accumulated >= total,
#       EVEN when the final page is exactly == PageSize (which would otherwise fetch one empty extra page).
#   (b) Pagination.LoopGuard (per-Op) · bound the page loop by the manifest value, not just $script:LoopGuardMax.
# Proven end-to-end through the REAL Invoke-XdrEntryPoll with I/O mocked (same harness as ExactlyOnce.Tests.ps1),
# plus a direct InModuleScope unit on the Resolve-XdrTotalCount helper.

BeforeAll {
    $script:Repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $psd1s = Get-ChildItem (Join-Path $script:Repo 'src\Modules') -Directory |
        ForEach-Object { Join-Path $_.FullName ($_.Name + '.psd1') } | Where-Object { Test-Path $_ }
    for ($pass = 1; $pass -le 4; $pass++) {
        foreach ($p in $psd1s) { try { Import-Module $p -Force -DisableNameChecking -ErrorAction Stop } catch { } }
    }

    function New-AcRow([string]$id, [string]$time) { @{ ActionId = $id; EventTime = $time } }
    $env:XDRLR_DCE_ENDPOINT = 'https://dce-test.local'
    $global:XdrTestCheckpoint = @{ OperationKey = 'PgOp'; Cursor = $null; BoundaryKeys = $null; WindowStartUtc = $null; WindowEndUtc = $null; LastUpdatedUtc = $null; LastItemCount = 0; ETag = $null }
}

Describe 'Resolve-XdrTotalCount · JSONPath total-count reader (G-J a · unit)' {
    It 'reads a top-level Count from an -AsHashtable body' {
        InModuleScope Xdr.Common.Runtime {
            (Resolve-XdrTotalCount -Response @{ Count = 1870; Results = @() } -Path 'Count') | Should -Be 1870
        }
    }
    It 'reads a $.-prefixed nested path' {
        InModuleScope Xdr.Common.Runtime {
            (Resolve-XdrTotalCount -Response @{ meta = @{ total = 42 } } -Path '$.meta.total') | Should -Be 42
        }
    }
    It 'returns $null for an absent path (fail-safe)' {
        InModuleScope Xdr.Common.Runtime {
            (Resolve-XdrTotalCount -Response @{ Results = @() } -Path 'Count') | Should -BeNullOrEmpty
        }
    }
    It 'returns $null for a non-numeric value (fail-safe)' {
        InModuleScope Xdr.Common.Runtime {
            (Resolve-XdrTotalCount -Response @{ Count = 'lots' } -Path 'Count') | Should -BeNullOrEmpty
        }
    }
}

Describe 'TotalCountPath stops paging once drained (G-J a · end-to-end)' {
    BeforeEach {
        # Page-aware HTTP mock: 2 full pages of 2 rows then the loop should STOP because Count=4 == accumulated 4,
        # even though page 2 is exactly PageSize (pageIndexIncrement would otherwise request page 3).
        $script:PgCallCount = 0
        Mock -ModuleName Xdr.Common.Runtime Connect-XdrPortal { @{ Portal = 'Defender'; Sccauth = 'x'; XsrfToken = 'y' } }
        Mock -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp {
            $script:PgCallCount++
            $rows = if ($script:PgCallCount -eq 1) {
                @((New-AcRow 'A1' '2026-05-01T00:00:00Z'), (New-AcRow 'A2' '2026-05-02T00:00:00Z'))
            } elseif ($script:PgCallCount -eq 2) {
                @((New-AcRow 'A3' '2026-05-03T00:00:00Z'), (New-AcRow 'A4' '2026-05-04T00:00:00Z'))
            } else {
                @()   # a 3rd call would mean TotalCountPath did NOT stop the loop (regression)
            }
            @{ StatusCode = 200; Body = @{ Count = 4; Results = $rows }; RawBody = '' }
        }
        Mock -ModuleName Xdr.Common.Runtime Get-XdrCheckpoint { $global:XdrTestCheckpoint }
        Mock -ModuleName Xdr.Common.Runtime Save-XdrCheckpointAtomic { $true }
        Mock -ModuleName Xdr.Common.Runtime Send-ToDce { @{ Success = $true; RowsAccepted = @($Rows).Count; BytesIngested = 100 } }
        # G3 · grant the single-flight lease (real Blob-lease infra absent in unit tests · un-mocked acquire → $null
        # → would skip as 'contended'). Granting exercises the normal page-loop path under test.
        Mock -ModuleName Xdr.Common.Runtime Lock-XdrSingleFlight { 'lease-granted' }
        Mock -ModuleName Xdr.Common.Runtime Unlock-XdrSingleFlight { $true }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrEvent { }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrException { }

        # SNAPSHOT so no high-water dedup interferes · pageIndexIncrement with PageSize=2 (a full final page would
        # normally keep paging) · TotalCountPath='Count' is the stop signal under test.
        $script:PgEntry = @{
            OperationKey = 'PgOp'; Portal = 'Defender'; Category = 'Operations'; Method = 'GET'; SubPortal = 'mtp'; Path = '/x'
            ResponseShape = 'wrapper'; ItemsContainer = 'Results'
            IngestionMode = 'SNAPSHOT'
            Pagination = @{ Mode = 'pageSize'; PageSizeQuery = 'pageSize'; PageSize = 2; PageIndexQuery = 'pageIndex'; PageIndexStart = 1; CursorMode = 'pageIndexIncrement'; LoopGuard = 1000; TotalCountPath = 'Count' }
            ProjectionMap = @{ EventTime = '$.EventTime'; ActionId = '$.ActionId' }
            DcrImmutableId = 'dcr-test'; DcrStreamName = 'Custom-Defender_Operations_CL'
        }
        $global:XdrTestCheckpoint = @{ OperationKey = 'PgOp'; Cursor = $null; BoundaryKeys = $null; ETag = $null }
    }

    It 'fetches EXACTLY 2 pages then stops (accumulated 4 == Count 4 · no empty 3rd page)' {
        $r = Invoke-XdrEntryPoll -Entry $script:PgEntry -CorrelationId 'pg1'
        $r.Success | Should -BeTrue
        Should -Invoke -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp -Times 2 -Exactly
    }
    It 'ingests all 4 rows (no row lost by the early stop)' {
        $r = Invoke-XdrEntryPoll -Entry $script:PgEntry -CorrelationId 'pg2'
        $r.ItemCount | Should -Be 4
        Should -Invoke -ModuleName Xdr.Common.Runtime Send-ToDce -Times 1 -Exactly -ParameterFilter { @($Rows).Count -eq 4 }
    }
}

Describe 'per-Op Pagination.LoopGuard is honored (G-J b · end-to-end)' {
    BeforeEach {
        # Always returns a FULL page (pageIndexIncrement never self-terminates · no TotalCountPath) so ONLY the
        # loop guard can stop it. A per-Op LoopGuard=3 (<< the module default 1000) must throw after 3 pages.
        Mock -ModuleName Xdr.Common.Runtime Connect-XdrPortal { @{ Portal = 'Defender'; Sccauth = 'x'; XsrfToken = 'y' } }
        Mock -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp {
            @{ StatusCode = 200; Body = @{ Results = @((New-AcRow 'B1' '2026-05-01T00:00:00Z'), (New-AcRow 'B2' '2026-05-02T00:00:00Z')) }; RawBody = '' }
        }
        Mock -ModuleName Xdr.Common.Runtime Get-XdrCheckpoint { $global:XdrTestCheckpoint }
        Mock -ModuleName Xdr.Common.Runtime Save-XdrCheckpointAtomic { $true }
        Mock -ModuleName Xdr.Common.Runtime Send-ToDce { @{ Success = $true; RowsAccepted = @($Rows).Count; BytesIngested = 100 } }
        # G3 · grant the single-flight lease (real Blob-lease infra absent in unit tests · un-mocked acquire → $null
        # → would skip as 'contended'). Granting exercises the normal page-loop path under test.
        Mock -ModuleName Xdr.Common.Runtime Lock-XdrSingleFlight { 'lease-granted' }
        Mock -ModuleName Xdr.Common.Runtime Unlock-XdrSingleFlight { $true }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrEvent { }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrException { }

        $script:GuardEntry = @{
            OperationKey = 'GuardOp'; Portal = 'Defender'; Category = 'Operations'; Method = 'GET'; SubPortal = 'mtp'; Path = '/x'
            ResponseShape = 'wrapper'; ItemsContainer = 'Results'
            IngestionMode = 'SNAPSHOT'
            Pagination = @{ Mode = 'pageSize'; PageSizeQuery = 'pageSize'; PageSize = 2; PageIndexQuery = 'pageIndex'; PageIndexStart = 1; CursorMode = 'pageIndexIncrement'; LoopGuard = 3 }
            ProjectionMap = @{ EventTime = '$.EventTime'; ActionId = '$.ActionId' }
            DcrImmutableId = 'dcr-test'; DcrStreamName = 'Custom-Defender_Operations_CL'
        }
        $global:XdrTestCheckpoint = @{ OperationKey = 'GuardOp'; Cursor = $null; BoundaryKeys = $null; ETag = $null }
    }

    It 'stops at the per-Op LoopGuard (3 pages · NOT the module default 1000) · Invoke-XdrEntryPoll never throws' {
        # The guard throws INSIDE the try → Invoke-XdrEntryPoll catches it (never throws to the caller) and returns
        # a failed Result. The HTTP mock is hit exactly LoopGuard (3) times: pages 1,2,3 fetch; page 4's $page>3
        # guard fires before the 4th HTTP call.
        $r = Invoke-XdrEntryPoll -Entry $script:GuardEntry -CorrelationId 'guard1'
        $r.Success | Should -BeFalse
        $r.ErrorMessage | Should -Match 'loopGuard exceeded 3'
        Should -Invoke -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp -Times 3 -Exactly
    }
}
