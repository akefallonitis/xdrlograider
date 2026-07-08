#Requires -Version 7.4
# N3 · single-flight poll-lease RENEWAL mid-drain (the dup-ingest exactly-once hole). The 55s Azure Blob Lease
# cannot cover a long multi-page drain (page budget · slow portal · backoff); without renewal it lapses and a
# concurrently-fired next cycle for the SAME Op acquires it and double-ingests. These pin:
#   (a) the HELD lease IS renewed during the drain (threshold forced to 0 so it fires on the first page);
#   (b) a LOST lease (renew + its one retry both fail) FAILS LOUD — the poll aborts, NOTHING is ingested, and the
#       checkpoint does NOT advance, so the next cycle resumes cleanly with no duplicate.
# Mirrors the ExactlyOnce harness: drives the REAL Invoke-XdrEntryPoll with the I/O boundaries mocked.

BeforeAll {
    $script:Repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $psd1s = Get-ChildItem (Join-Path $script:Repo 'src\Modules') -Directory |
        ForEach-Object { Join-Path $_.FullName ($_.Name + '.psd1') } | Where-Object { Test-Path $_ }
    for ($pass = 1; $pass -le 4; $pass++) {
        foreach ($p in $psd1s) { try { Import-Module $p -Force -DisableNameChecking -ErrorAction Stop } catch { } }
    }
    function New-AcRow([string]$id, [string]$time) { @{ ActionId = $id; EventTime = $time } }
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
    $global:XdrTestHttpRows = @()
    $global:XdrTestCheckpoint = @{ OperationKey = 'GetHistory'; Cursor = $null; BoundaryKeys = $null; ETag = $null }
}

Describe 'N3 · poll-lease renewal mid-drain (dup-ingest hole)' {
    BeforeEach {
        Mock -ModuleName Xdr.Common.Runtime Connect-XdrPortal { @{ Portal = 'Defender'; Sccauth = 'x'; XsrfToken = 'y' } }
        Mock -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp { @{ StatusCode = 200; Body = @{ Count = @($global:XdrTestHttpRows).Count; Results = $global:XdrTestHttpRows }; RawBody = '' } }
        Mock -ModuleName Xdr.Common.Runtime Get-XdrCheckpoint { $global:XdrTestCheckpoint }
        Mock -ModuleName Xdr.Common.Runtime Save-XdrCheckpointAtomic { $true }
        Mock -ModuleName Xdr.Common.Runtime Send-ToDce { @{ Success = $true; RowsAccepted = @($Rows).Count; BytesIngested = 100 } }
        Mock -ModuleName Xdr.Common.Runtime Lock-XdrSingleFlight { 'lease-granted' }
        Mock -ModuleName Xdr.Common.Runtime Unlock-XdrSingleFlight { $true }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrEvent { }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrException { }
        $env:XDRLR_LEASE_RENEW_SECONDS = '0'   # force the renewal every page (production default is 40s)
        $global:XdrTestCheckpoint = @{ OperationKey = 'GetHistory'; Cursor = $null; BoundaryKeys = $null; ETag = $null }
        $global:XdrTestHttpRows = @((New-AcRow 'K1' '2026-05-01T00:00:00Z'))
    }
    AfterEach { Remove-Item Env:XDRLR_LEASE_RENEW_SECONDS -ErrorAction SilentlyContinue }

    It 'renews the HELD poll lease during the drain (threshold 0 → fires) · ingest still proceeds' {
        Mock -ModuleName Xdr.Common.Runtime Renew-XdrSingleFlight { $true }
        $r = Invoke-XdrEntryPoll -Entry $script:Entry -CorrelationId 'n3-ok'
        $r.Success | Should -BeTrue
        Should -Invoke -ModuleName Xdr.Common.Runtime Renew-XdrSingleFlight -Times 1 -Exactly -ParameterFilter { $ResourceKey -eq 'poll::Defender_Operations::GetHistory' -and $LeaseToken -eq 'lease-granted' }
        Should -Invoke -ModuleName Xdr.Common.Runtime Send-ToDce -Times 1 -Exactly
    }

    It 'lease LOST mid-drain (renew + retry both fail) → FAIL LOUD · NO ingest · NO checkpoint advance (no dup)' {
        Mock -ModuleName Xdr.Common.Runtime Renew-XdrSingleFlight { $false }
        $r = Invoke-XdrEntryPoll -Entry $script:Entry -CorrelationId 'n3-lost'
        $r.Success | Should -BeFalse
        Should -Invoke -ModuleName Xdr.Common.Runtime Renew-XdrSingleFlight -Times 2 -Exactly   # initial call + one retry, then give up
        Should -Invoke -ModuleName Xdr.Common.Runtime Send-ToDce -Times 0 -Exactly
        Should -Invoke -ModuleName Xdr.Common.Runtime Save-XdrCheckpointAtomic -Times 0 -Exactly
    }
}
