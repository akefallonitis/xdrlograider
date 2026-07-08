#Requires -Version 7.4
# T3b (audit 2026-06-12 · operator directive "all time filters generic/always-working across all cases") · WINDOW
# boundary exactly-once. A WINDOW op polls a SERVER time window [StartUtc, now]; the corpus windows are
# INCLUSIVE-INCLUSIVE (endpoint_devices.yml "the inclusive start/end") and StartUtc = last cycle's WindowEndUtc, so a
# row sitting exactly at the boundary StartUtc is re-served EVERY cycle = a GUARANTEED duplicate. Resolve-XdrTimeWindow's
# WINDOW branch always PROMISED "boundary natural-key dedup (as CURSOR)" in its comment but never set HighWaterUtc, so
# Select-XdrExactlyOnceRows (which needs a high-water) never ran for WINDOW ops. This pins the wiring: a WINDOW op with
# a CursorField + NaturalKey now runs the SAME client-side boundary dedup as CURSOR — the boundary tie whose key was
# already ingested is dropped, a genuinely-new same-instant row is kept.

BeforeAll {
    $script:Repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $env:PSModulePath = (Join-Path $script:Repo 'src\Modules') + [IO.Path]::PathSeparator + $env:PSModulePath
    $psd1s = Get-ChildItem (Join-Path $script:Repo 'src\Modules') -Directory |
        ForEach-Object { Join-Path $_.FullName ($_.Name + '.psd1') } | Where-Object { Test-Path $_ }
    for ($pass = 1; $pass -le 4; $pass++) {
        foreach ($p in $psd1s) { try { Import-Module $p -Force -DisableNameChecking -ErrorAction Stop } catch { } }
    }
    $env:XDRLR_DCE_ENDPOINT = 'https://dce-test.local'
}

Describe 'T3b · WINDOW unit · Resolve-XdrTimeWindow sets HighWaterUtc = StartUtc (enables the boundary dedup)' {
    It 'a WINDOW op resuming from a prior WindowEndUtc carries HighWaterUtc == StartUtc' {
        InModuleScope Xdr.Common.Runtime {
            $entry = @{ IngestionMode = 'WINDOW'; LookbackHours = 24 }
            $cp    = @{ WindowEndUtc = '2026-05-06T00:00:00.0000000Z' }
            $w = Resolve-XdrTimeWindow -Entry $entry -Checkpoint $cp
            $w.StartUtc      | Should -Match '2026-05-06T00:00:00'
            $w.HighWaterUtc  | Should -Be $w.StartUtc   # RED on the pre-fix code (HighWaterUtc stayed null for WINDOW)
        }
    }
    It 'a SNAPSHOT op still has HighWaterUtc null (the WINDOW change must NOT leak into SNAPSHOT)' {
        InModuleScope Xdr.Common.Runtime {
            $w = Resolve-XdrTimeWindow -Entry @{ IngestionMode = 'SNAPSHOT' } -Checkpoint @{}
            $w.HighWaterUtc | Should -BeNullOrEmpty
        }
    }
}

Describe 'T3b · WINDOW end-to-end · the inclusive-inclusive boundary row is deduped, not re-ingested' {
    BeforeEach {
        $script:Entry = @{
            OperationKey = 'GetMachineTimelineEvents'; Portal = 'Defender'; Category = 'Operations'; Method = 'GET'; SubPortal = 'mtp'; Path = '/timeline'
            ResponseShape = 'wrapper'; ItemsContainer = 'value'
            IngestionMode = 'WINDOW'; CursorField = 'EventTime'; NaturalKey = @('ActionId'); LookbackHours = 24
            TimeFilter = @{ Mode = 'ServerFromDate'; FieldName = 'EventTime'; FromDateParam = 'fromDate'; ToDateParam = 'toDate' }
            ProjectionMap = @{ EventTime = '$.EventTime'; ActionId = '$.ActionId' }
            DcrImmutableId = 'dcr-test'; DcrStreamName = 'Custom-Defender_Operations_CL'
        }
        $global:XdrWinRows = @()
        # Prior cycle ended at T_b='2026-05-06T00:00:00Z' having ingested the boundary row 'Kb' (persisted in BoundaryKeys).
        Mock -ModuleName Xdr.Common.Runtime Connect-XdrPortal { @{ Portal = 'Defender'; Sccauth = 'x'; XsrfToken = 'y' } }
        Mock -ModuleName Xdr.Common.Runtime Get-XdrCheckpoint { @{ OperationKey = 'GetMachineTimelineEvents'; Cursor = '2026-05-06T00:00:00.0000000Z'; BoundaryKeys = 'Kb'; WindowEndUtc = '2026-05-06T00:00:00.0000000Z'; ETag = 'e1' } }
        # The inclusive-inclusive window [T_b, now] re-serves the boundary row Kb (at exactly T_b) AND a genuinely newer row.
        Mock -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp {
            @{ StatusCode = 200; RawBody = ''; Body = @{ value = @(
                @{ ActionId = 'Kb';   EventTime = '2026-05-06T00:00:00.0000000Z' },
                @{ ActionId = 'Knew'; EventTime = '2026-05-06T06:00:00.0000000Z' }
            ) } }
        }
        Mock -ModuleName Xdr.Common.Runtime Save-XdrCheckpointAtomic { $true }
        Mock -ModuleName Xdr.Common.Runtime Send-ToDce { $global:XdrWinRows = @(@($Rows) | ForEach-Object { $_.ActionId }); @{ Success = $true; RowsAccepted = @($Rows).Count; BytesIngested = 100 } }
        Mock -ModuleName Xdr.Common.Runtime Lock-XdrSingleFlight { 'lease-granted' }
        Mock -ModuleName Xdr.Common.Runtime Unlock-XdrSingleFlight { $true }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrEvent { }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrException { }
    }
    It 'ingests ONLY the genuinely newer row (Knew); the boundary tie (Kb) is dropped — no inclusive-inclusive dup' {
        $r = Invoke-XdrEntryPoll -Entry $script:Entry -CorrelationId 'win-e2e-1'
        $r.Success | Should -BeTrue
        $global:XdrWinRows | Should -Not -Contain 'Kb'    # RED on the pre-fix code: both Kb+Knew ingested (the dup)
        $global:XdrWinRows | Should -Be @('Knew')
    }
}
