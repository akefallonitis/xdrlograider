#Requires -Version 7.4
# Φ3 · skipTop ($skip + $top offset/limit) pagination CONTINUATION. The URL builder (New-XdrRequestUrl) already emits
# skip=(Page-1)*top · top=PageSize whenever SkipQuery+TopQuery are set, but Get-XdrNextCursor previously returned $null
# for skipTop → the page loop stopped after page 1 (under-fetch). Mode 3 returns the next page while a FULL page returns,
# keyed on the SAME SkipQuery+TopQuery pair so URL + cursor stay aligned. RED on pre-fix: only 1 HTTP call / 2 rows.
# Proven end-to-end through the REAL Invoke-XdrEntryPoll with I/O mocked (same harness as PaginationContract.Tests.ps1).

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

Describe 'skipTop pagination pages PAST page 1 then stops on a short page (Φ3 · Get-XdrNextCursor Mode 3)' {
    BeforeEach {
        # Page-aware HTTP mock: page 1 = FULL (2 rows == PageSize) → must continue; page 2 = SHORT (1 row < PageSize)
        # → must stop. Pre-fix (no Mode 3) returns $null after the full page 1 → only 1 call, 2 rows (the under-fetch bug).
        $script:StCallCount = 0
        Mock -ModuleName Xdr.Common.Runtime Connect-XdrPortal { @{ Portal = 'Defender'; Sccauth = 'x'; XsrfToken = 'y' } }
        Mock -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp {
            $script:StCallCount++
            $rows = if ($script:StCallCount -eq 1) {
                @((New-AcRow 'A1' '2026-05-01T00:00:00Z'), (New-AcRow 'A2' '2026-05-02T00:00:00Z'))   # FULL page
            } elseif ($script:StCallCount -eq 2) {
                @((New-AcRow 'A3' '2026-05-03T00:00:00Z'))                                              # SHORT page → stop
            } else {
                @()   # a 3rd call would mean Mode 3 did not stop on the short page (regression)
            }
            @{ StatusCode = 200; Body = @{ Results = $rows }; RawBody = '' }
        }
        Mock -ModuleName Xdr.Common.Runtime Get-XdrCheckpoint { @{ OperationKey = 'StOp'; Cursor = $null; BoundaryKeys = $null; ETag = $null } }
        Mock -ModuleName Xdr.Common.Runtime Save-XdrCheckpointAtomic { $true }
        Mock -ModuleName Xdr.Common.Runtime Send-ToDce { @{ Success = $true; RowsAccepted = @($Rows).Count; BytesIngested = 100 } }
        Mock -ModuleName Xdr.Common.Runtime Lock-XdrSingleFlight { 'lease-granted' }
        Mock -ModuleName Xdr.Common.Runtime Unlock-XdrSingleFlight { $true }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrEvent { }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrException { }

        # SNAPSHOT (no high-water dedup) · skipTop pagination: SkipQuery+TopQuery set, PageSize=2, CursorMode='skipTop'.
        $script:StEntry = @{
            OperationKey = 'StOp'; Portal = 'Defender'; Category = 'Operations'; Method = 'GET'; SubPortal = 'mtp'; Path = '/x'
            ResponseShape = 'wrapper'; ItemsContainer = 'Results'
            IngestionMode = 'SNAPSHOT'
            Pagination = @{ Mode = 'pageSize'; ParamLocation = 'query'; PageSize = 2; SkipQuery = '$skip'; TopQuery = '$top'; CursorMode = 'skipTop'; LoopGuard = 1000 }
            ProjectionMap = @{ EventTime = '$.EventTime'; ActionId = '$.ActionId' }
            DcrImmutableId = 'dcr-test'; DcrStreamName = 'Custom-Defender_Operations_CL'
        }
    }

    It 'pages to page 2 (skipTop continuation · NOT page-1-only) — exactly 2 HTTP calls' {
        $r = Invoke-XdrEntryPoll -Entry $script:StEntry -CorrelationId 'st1'
        $r.Success | Should -BeTrue
        Should -Invoke -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp -Times 2 -Exactly
    }
    It 'ingests all 3 rows across the 2 pages (the page-2 row is NOT lost)' {
        $r = Invoke-XdrEntryPoll -Entry $script:StEntry -CorrelationId 'st2'
        $r.ItemCount | Should -Be 3
        Should -Invoke -ModuleName Xdr.Common.Runtime Send-ToDce -Times 1 -Exactly -ParameterFilter { @($Rows).Count -eq 3 }
    }
    It 'stops on the short page (no empty 3rd call · skipTop terminates correctly)' {
        $null = Invoke-XdrEntryPoll -Entry $script:StEntry -CorrelationId 'st3'
        Should -Invoke -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp -Times 2 -Exactly
    }
}
