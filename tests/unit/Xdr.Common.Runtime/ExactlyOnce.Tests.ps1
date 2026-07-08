#Requires -Version 7.4
# Exactly-once cursor + boundary-dedup proof (plan §35.2). Drives the REAL Invoke-XdrEntryPoll with the I/O
# boundaries mocked (auth · HTTP · DCE · checkpoint I/O) so the high-water + boundary-natural-key logic is
# exercised end-to-end. Proves: cold-start ingests all · re-poll of the same data ingests ZERO (no duplicates ·
# NO DCR dedup) · a newer event ingests exactly once · a NEW same-timestamp tie ingests once while an already-seen
# tie does not · the boundary set accumulates across a non-advancing high-water.

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

    # DCE endpoint is set by ARM in production; the local test must provide a non-empty value so Send-ToDce's
    # mandatory -DceEndpoint binds (Pester validates args against the real metadata before the mock body runs).
    $env:XDRLR_DCE_ENDPOINT = 'https://dce-test.local'

    # Inputs fed to the mocks via $global: (mock bodies run in module scope; $global is visible there + here).
    $global:XdrTestHttpRows = @()
    $global:XdrTestCheckpoint = @{ OperationKey = 'GetHistory'; Cursor = $null; BoundaryKeys = $null; WindowStartUtc = $null; WindowEndUtc = $null; LastUpdatedUtc = $null; LastItemCount = 0; ETag = $null }
}

Describe 'R3 exactly-once cursor (plan §35.2)' {
    BeforeEach {
        Mock -ModuleName Xdr.Common.Runtime Connect-XdrPortal { @{ Portal = 'Defender'; Sccauth = 'x'; XsrfToken = 'y' } }
        Mock -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp { @{ StatusCode = 200; Body = @{ Count = @($global:XdrTestHttpRows).Count; Results = $global:XdrTestHttpRows }; RawBody = '' } }
        Mock -ModuleName Xdr.Common.Runtime Get-XdrCheckpoint { $global:XdrTestCheckpoint }
        Mock -ModuleName Xdr.Common.Runtime Save-XdrCheckpointAtomic { $true }
        Mock -ModuleName Xdr.Common.Runtime Send-ToDce { @{ Success = $true; RowsAccepted = @($Rows).Count; BytesIngested = 100 } }
        # G3 · grant the single-flight lease deterministically (the real Blob-lease infra is absent in unit tests; an
        # un-mocked acquire returns $null → Invoke-XdrEntryPoll would skip as 'contended'). Granting it exercises the
        # normal poll path; the dedicated G3 test mocks contention explicitly.
        Mock -ModuleName Xdr.Common.Runtime Lock-XdrSingleFlight { 'lease-granted' }
        Mock -ModuleName Xdr.Common.Runtime Unlock-XdrSingleFlight { $true }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrEvent { }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrException { }
    }

    It 'cold start ingests ALL rows and persists max(EventTime) + its key' {
        $global:XdrTestCheckpoint = @{ OperationKey = 'GetHistory'; Cursor = $null; BoundaryKeys = $null; ETag = $null }
        $global:XdrTestHttpRows = @((New-AcRow 'K1' '2026-05-01T00:00:00Z'), (New-AcRow 'K2' '2026-05-02T00:00:00Z'), (New-AcRow 'K3' '2026-05-03T00:00:00Z'))
        $r = Invoke-XdrEntryPoll -Entry $script:Entry -CorrelationId 'c1'
        $r.Success | Should -BeTrue
        Should -Invoke -ModuleName Xdr.Common.Runtime Send-ToDce -Times 1 -Exactly -ParameterFilter { @($Rows).Count -eq 3 }
        Should -Invoke -ModuleName Xdr.Common.Runtime Save-XdrCheckpointAtomic -Times 1 -Exactly -ParameterFilter { $Cursor -match '2026-05-03' -and $BoundaryKeys -eq 'K3' }
    }

    It 're-poll of the SAME data ingests ZERO (exactly-once · no duplicates · no DCR dedup)' {
        $global:XdrTestCheckpoint = @{ OperationKey = 'GetHistory'; Cursor = '2026-05-03T00:00:00Z'; BoundaryKeys = 'K3'; ETag = 'e1' }
        $global:XdrTestHttpRows = @((New-AcRow 'K1' '2026-05-01T00:00:00Z'), (New-AcRow 'K2' '2026-05-02T00:00:00Z'), (New-AcRow 'K3' '2026-05-03T00:00:00Z'))
        $r = Invoke-XdrEntryPoll -Entry $script:Entry -CorrelationId 'c2'
        $r.Success | Should -BeTrue
        $r.ItemCount | Should -Be 0
        Should -Invoke -ModuleName Xdr.Common.Runtime Send-ToDce -Times 0 -Exactly
    }

    It 'a NEWER event ingests exactly once and advances the high-water' {
        $global:XdrTestCheckpoint = @{ OperationKey = 'GetHistory'; Cursor = '2026-05-03T00:00:00Z'; BoundaryKeys = 'K3'; ETag = 'e1' }
        $global:XdrTestHttpRows = @((New-AcRow 'K1' '2026-05-01T00:00:00Z'), (New-AcRow 'K3' '2026-05-03T00:00:00Z'), (New-AcRow 'K4' '2026-05-04T00:00:00Z'))
        $r = Invoke-XdrEntryPoll -Entry $script:Entry -CorrelationId 'c3'
        Should -Invoke -ModuleName Xdr.Common.Runtime Send-ToDce -Times 1 -Exactly -ParameterFilter { @($Rows).Count -eq 1 -and $Rows[0].ActionId -eq 'K4' }
        Should -Invoke -ModuleName Xdr.Common.Runtime Save-XdrCheckpointAtomic -Times 1 -Exactly -ParameterFilter { $Cursor -match '2026-05-04' -and $BoundaryKeys -eq 'K4' }
    }

    It 'a NEW same-timestamp tie ingests once; the already-seen tie does not; boundary set ACCUMULATES' {
        # high-water is 2026-05-03 with key K3 already ingested. New row K3b at the SAME timestamp must ingest;
        # K3 (already seen) must NOT; the persisted boundary set must become {K3,K3b} so K3 can never re-ingest.
        $global:XdrTestCheckpoint = @{ OperationKey = 'GetHistory'; Cursor = '2026-05-03T00:00:00Z'; BoundaryKeys = 'K3'; ETag = 'e1' }
        $global:XdrTestHttpRows = @((New-AcRow 'K3' '2026-05-03T00:00:00Z'), (New-AcRow 'K3b' '2026-05-03T00:00:00Z'))
        $r = Invoke-XdrEntryPoll -Entry $script:Entry -CorrelationId 'c4'
        Should -Invoke -ModuleName Xdr.Common.Runtime Send-ToDce -Times 1 -Exactly -ParameterFilter { @($Rows).Count -eq 1 -and $Rows[0].ActionId -eq 'K3b' }
        Should -Invoke -ModuleName Xdr.Common.Runtime Save-XdrCheckpointAtomic -Times 1 -Exactly -ParameterFilter { $Cursor -match '2026-05-03' -and $BoundaryKeys -eq 'K3,K3b' }
    }
}

Describe 'Φ-F · {TenantId} path-token SEEDED from session (param-resolution · MultiTenant ops)' {
    It 'Invoke-XdrEntryPoll seeds Entry[TenantId] from the connected session → substitutes it into the live URL' {
        # ROOT CAUSE (Φ-F #1): New-XdrRequestUrl substitutes {TenantId} ONLY when Entry['TenantId'] is set, but
        # nothing seeded it (runtime only READ it; the "dispatcher seeds it" comment was aspirational) → the literal
        # {TenantId} shipped → 400/404 on MultiTenant ops (GetWorkloadStatus, ListAutomationRules). The runtime now
        # seeds Entry['TenantId'] from the connected session (Decision-16) right after Connect-XdrPortal. This pins it.
        Mock -ModuleName Xdr.Common.Runtime Connect-XdrPortal { @{ Portal = 'Defender'; Sccauth = 'x'; XsrfToken = 'y'; TenantId = 'tid-xyz' } }
        Mock -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp { @{ StatusCode = 200; Body = @{ status = 'ok' }; RawBody = '' } }
        Mock -ModuleName Xdr.Common.Runtime Get-XdrCheckpoint { @{ OperationKey = 'GetWorkloadStatus'; Cursor = $null; BoundaryKeys = $null; ETag = $null } }
        Mock -ModuleName Xdr.Common.Runtime Save-XdrCheckpointAtomic { $true }
        Mock -ModuleName Xdr.Common.Runtime Send-ToDce { @{ Success = $true; RowsAccepted = 0; BytesIngested = 0 } }
        Mock -ModuleName Xdr.Common.Runtime Lock-XdrSingleFlight { 'lease-granted' }
        Mock -ModuleName Xdr.Common.Runtime Unlock-XdrSingleFlight { $true }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrEvent { }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrException { }

        $mtEntry = @{
            OperationKey = 'GetWorkloadStatus'; Portal = 'Defender'; Category = 'Operations'; Method = 'GET'
            SubPortal = 'mtoapi'; Path = '/tenants/{TenantId}/workloadStatus'
            ResponseShape = 'singleObject'; IngestionMode = 'SNAPSHOT'; NaturalKey = @()
            ProjectionMap = @{ status = '$.status' }
            DcrImmutableId = 'dcr-test'; DcrStreamName = 'Custom-Defender_Operations_CL'
        }
        $null = Invoke-XdrEntryPoll -Entry $mtEntry -CorrelationId 'tid-seed-1'
        Should -Invoke -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp -Times 1 -Exactly -ParameterFilter {
            $Url -match '/tenants/tid-xyz/workloadStatus' -and $Url -notmatch '\{TenantId\}'
        }
    }
}

Describe 'Φ-F · capability-absent (403/404) → posture telemetry + cadence back-off (NOT AppException/DLQ/breaker)' {
    It 'a 403 is a CLEAN no-op: Success=$true · emits Capability.OpUnavailable · advances cadence · NO Track-XdrException' {
        # ROOT CAUSE (plan §6 · 3-way error class): every 4xx (except 429) was PortalTerminal → AppException + the
        # error path skips the checkpoint write → LastUpdatedUtc never advances → the op re-polls EVERY cycle = the
        # live 8-op 400/404/403 AppException flood. 403/404 = the tenant cannot serve the op (no product/MTO/data) →
        # record POSTURE + back off to cadence. This pins: Success stays true, posture event fires, cadence touched,
        # NO Track-XdrException (no flood), NO breaker trip.
        Mock -ModuleName Xdr.Common.Runtime Connect-XdrPortal { @{ Portal = 'Defender'; Sccauth = 'x'; XsrfToken = 'y'; TenantId = 'tid-xyz' } }
        Mock -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp { throw (New-XdrException -Type PortalTerminal -Message 'HTTP 403' -Properties @{ StatusCode = 403; OperationKey = ''; Url = 'x'; ResponseBody = 'forbidden' }) }
        Mock -ModuleName Xdr.Common.Runtime Get-XdrCheckpoint { @{ OperationKey = 'GetWorkloadStatus'; Cursor = '2026-05-01T00:00:00Z'; BoundaryKeys = 'K0'; ETag = 'e1' } }
        Mock -ModuleName Xdr.Common.Runtime Save-XdrCheckpointAtomic { $true }
        Mock -ModuleName Xdr.Common.Runtime Send-ToDce { @{ Success = $true; RowsAccepted = 0; BytesIngested = 0 } }
        Mock -ModuleName Xdr.Common.Runtime Lock-XdrSingleFlight { 'lease-granted' }
        Mock -ModuleName Xdr.Common.Runtime Unlock-XdrSingleFlight { $true }
        Mock -ModuleName Xdr.Common.Runtime Update-XdrCircuitState { }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrEvent { }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrException { }

        $e = @{
            OperationKey = 'GetWorkloadStatus'; Portal = 'Defender'; Category = 'Operations'; Method = 'GET'
            SubPortal = 'mtoapi'; Path = '/tenants/{TenantId}/workloadStatus'
            ResponseShape = 'singleObject'; IngestionMode = 'SNAPSHOT'; NaturalKey = @()
            ProjectionMap = @{ status = '$.status' }; DcrImmutableId = 'dcr-test'; DcrStreamName = 'Custom-Defender_Operations_CL'
        }
        $r = Invoke-XdrEntryPoll -Entry $e -CorrelationId 'cap-1'
        $r.Success    | Should -BeTrue            # capability-absent is a CLEAN no-op, not a failure
        $r.ItemCount  | Should -Be 0
        $r.ErrorClass | Should -BeNullOrEmpty     # NOT an error → no DLQ / no breaker trip
        Should -Invoke -ModuleName Xdr.Common.Runtime Track-XdrEvent -ParameterFilter { $Name -eq 'Capability.OpUnavailable' } -Times 1
        Should -Invoke -ModuleName Xdr.Common.Runtime Save-XdrCheckpointAtomic -Times 1 -Exactly   # cadence advanced
        Should -Invoke -ModuleName Xdr.Common.Runtime Track-XdrException -Times 0 -Exactly          # NO AppException flood
    }
}

Describe '400 classification (license-independence §3 + zero-masking §4.2 · response-driven discriminator · operator-locked 2026-06-10)' {
    # REVISED RULING (supersedes the prior "InvalidProxyPrefix = contract bug" premise — FALSIFIED by evidence):
    # references/openapi multi_tenant.yml documents /mtoapi/* as THE Multi-Tenant-Org route and the mtoapi cataloguing is
    # verified correct; a 400 {"Error":"InvalidProxyPrefix"} is the apiproxy router refusing a DOCUMENTED prefix the
    # tenant cannot route (no MTO product) = a per-tenant LICENSE GATE → capability-absent → POSTURE (the connector must
    # always work across tenants/products: visible Capability.OpUnavailable telemetry · no AppException flood · no DLQ ·
    # cadence back-off · auto-activates on an MTO tenant). ZERO-MASKING HOLDS via the response-driven discriminator:
    # ANY OTHER 400 body (a REAL contract error) stays a LOUD breaker-bounded failure — that tooth is pinned below.
    BeforeEach {
        Mock -ModuleName Xdr.Common.Runtime Connect-XdrPortal { @{ Portal = 'Defender'; Sccauth = 'x'; XsrfToken = 'y'; TenantId = 'tid-xyz' } }
        Mock -ModuleName Xdr.Common.Runtime Get-XdrCheckpoint { @{ OperationKey = 'ListTenantGroups'; Cursor = '2026-05-01T00:00:00Z'; BoundaryKeys = 'K0'; ETag = 'e1' } }
        Mock -ModuleName Xdr.Common.Runtime Save-XdrCheckpointAtomic { $true }
        Mock -ModuleName Xdr.Common.Runtime Send-ToDce { @{ Success = $true; RowsAccepted = 0; BytesIngested = 0 } }
        Mock -ModuleName Xdr.Common.Runtime Lock-XdrSingleFlight { 'lease-granted' }
        Mock -ModuleName Xdr.Common.Runtime Unlock-XdrSingleFlight { $true }
        Mock -ModuleName Xdr.Common.Runtime Update-XdrCircuitState { }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrEvent { }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrException { }
        $script:e = @{
            OperationKey = 'ListTenantGroups'; Portal = 'Defender'; Category = 'Operations'; Method = 'GET'
            SubPortal = 'mtoapi'; Path = '/tenantGroups'
            ResponseShape = 'singleObject'; IngestionMode = 'SNAPSHOT'; NaturalKey = @()
            ProjectionMap = @{ id = '$.id' }; DcrImmutableId = 'dcr-test'; DcrStreamName = 'Custom-Defender_Operations_CL'
        }
    }
    It 'a 400 InvalidProxyPrefix (mtoapi on a non-MTO tenant) is CAPABILITY-ABSENT → posture · NO flood · cadence back-off' {
        Mock -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp { throw (New-XdrException -Type PortalTerminal -Message 'HTTP 400' -Properties @{ StatusCode = 400; OperationKey = ''; Url = 'x'; ResponseBody = '{"Error":"Failed with error: InvalidProxyPrefix"}' }) }
        $r = Invoke-XdrEntryPoll -Entry $script:e -CorrelationId 'lic-1'
        $r.Success    | Should -BeTrue            # license-gate is a CLEAN no-op (the tenant lacks the product), not a failure
        $r.ItemCount  | Should -Be 0
        $r.ErrorClass | Should -BeNullOrEmpty     # NOT an error → no DLQ / no breaker trip
        Should -Invoke -ModuleName Xdr.Common.Runtime Track-XdrEvent -ParameterFilter { $Name -eq 'Capability.OpUnavailable' } -Times 1  # posture is VISIBLE telemetry, never silent
        Should -Invoke -ModuleName Xdr.Common.Runtime Save-XdrCheckpointAtomic -Times 1 -Exactly   # cadence advanced (no every-cycle re-poll)
        Should -Invoke -ModuleName Xdr.Common.Runtime Track-XdrException -Times 0 -Exactly          # NO AppException flood
    }
    It 'a 400 with a REAL contract error stays a LOUD FAILURE · breaker-bounded · NEVER masked as posture (zero-masking tooth)' {
        Mock -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp { throw (New-XdrException -Type PortalTerminal -Message 'HTTP 400' -Properties @{ StatusCode = 400; OperationKey = ''; Url = 'x'; ResponseBody = '{"Error":"InvalidParameter: pageIndex"}' }) }
        $r = Invoke-XdrEntryPoll -Entry $script:e -CorrelationId 'term-1'
        $r.Success    | Should -BeFalse                          # a terminal contract error IS a failure (not a clean no-op)
        $r.ErrorClass | Should -Be 'XdrPortalTerminalException'
        Should -Invoke -ModuleName Xdr.Common.Runtime Track-XdrException -Times 1 -Exactly         # LOUD · stays visible
        Should -Invoke -ModuleName Xdr.Common.Runtime Save-XdrCheckpointAtomic -Times 0 -Exactly   # NO cadence-touch (cursor never advanced)
        Should -Invoke -ModuleName Xdr.Common.Runtime Update-XdrCircuitState -ParameterFilter { $Success -eq $false } -Times 1 -Exactly  # breaker COUNTS it → opens after threshold (the loud bound)
        Should -Invoke -ModuleName Xdr.Common.Runtime Track-XdrEvent -ParameterFilter { $Name -eq 'Entry.Poll.Failed' } -Times 1
        Should -Invoke -ModuleName Xdr.Common.Runtime Track-XdrEvent -ParameterFilter { $Name -eq 'Capability.OpUnavailable' } -Times 0 -Exactly  # NOT masked as posture
    }
}

Describe 'New-XdrRequestUrl · 1-based pageIndex + descending sort (plan §39.10 · LIVE-PROVEN 2026-06-04)' {
    # ROOT CAUSE of the iter9/iter10 0-rows: Defender Operations history-actions is 1-BASED. pageIndex=0
    # returns a bodyless HTTP 500; pageIndex=1 returns 200 with rows. This pins the fix permanently.
    BeforeAll {
        $script:AcEntry = @{
            Portal = 'Defender'; SubPortal = 'mtp'; Path = '/Operations/Operationsui/history-actions'
            TimeFilter = @{ FieldName = 'EventTime'; Mode = 'ClientSideHighWater' }
            Pagination = @{
                Mode = 'pageSize'; PageSizeQuery = 'pageSize'; PageSize = 50
                PageIndexQuery = 'pageIndex'; PageIndexStart = 1
                SortByQuery = 'sortByField'; SortByField = 'EventTime'
                SortOrderQuery = 'sortOrder'; SortOrder = 'Descending'
            }
        }
    }
    It 'page 1 emits pageIndex=1 (1-based · pageIndex=0 would 500) NOT pageIndex=0' {
        $u = New-XdrRequestUrl -Entry $script:AcEntry -Page 1
        $u | Should -Match 'pageIndex=1(&|$)'
        $u | Should -Not -Match 'pageIndex=0'
    }
    It 'page 2 emits pageIndex=2 (increments from PageIndexStart)' {
        (New-XdrRequestUrl -Entry $script:AcEntry -Page 2) | Should -Match 'pageIndex=2(&|$)'
    }
    It 'emits the descending EventTime sort (live-proven 200 · §35.4 #1 retracted)' {
        $u = New-XdrRequestUrl -Entry $script:AcEntry -Page 1
        $u | Should -Match 'sortByField=EventTime'
        $u | Should -Match 'sortOrder=Descending'
    }
    It 'emits pageSize=50' {
        (New-XdrRequestUrl -Entry $script:AcEntry -Page 1) | Should -Match 'pageSize=50'
    }
    It 'ClientSideHighWater TimeFilter emits NO server time predicate' {
        # the sort value =EventTime is fine; a server predicate would be the query KEY EventTime= (preceded by ? or &)
        (New-XdrRequestUrl -Entry $script:AcEntry -Page 1) | Should -Not -Match '[?&]EventTime='
    }
    It 'PageIndexStart absent → 0-based back-compat preserved (page 1 → pageIndex=0)' {
        $e = @{ Portal = 'Defender'; SubPortal = 'mtp'; Path = '/x'; Pagination = @{ PageIndexQuery = 'pageIndex'; PageSizeQuery = 'pageSize'; PageSize = 100 } }
        (New-XdrRequestUrl -Entry $e -Page 1) | Should -Match 'pageIndex=0'
    }
}

Describe 'Checkpoint write · upsert + StrictMode-safe ETag (plan §39.11 · LIVE-PROVEN 2026-06-04)' {
    # LIVE bug: Save-XdrCheckpointAtomic sent If-Match:* on the first write → Azure Tables "Update Entity"
    # 404s on a non-existent entity → Set-XdrTableEntity then read $resp.ETag (dot) on the failure-path
    # hashtable (no ETag key) → PropertyNotFoundException under StrictMode → cursor never persisted →
    # every cycle re-ingested ALL rows (~10x duplication). These pin the upsert + indexer fixes.
    # Set-XdrTableEntity env-guard (real fn · Invoke-XdrStorageRest mocked). WS3.2: SAVE+RESTORE — this var leaked
    # process-wide and later UNMOCKED storage reads issued REAL HTTPS GETs to whoever owns the global account name
    # 'xdrtest' (401-storm mid-suite · network in an offline suite). AfterAll restores the prior state.
    BeforeAll { $script:SavedSa = $env:XDRLR_STORAGE_ACCOUNT; $env:XDRLR_STORAGE_ACCOUNT = 'xdrtest' }
    AfterAll  { if ($null -ne $script:SavedSa) { $env:XDRLR_STORAGE_ACCOUNT = $script:SavedSa } else { Remove-Item Env:XDRLR_STORAGE_ACCOUNT -ErrorAction SilentlyContinue } }
    Context 'Set-XdrTableEntity · failure-path response (no ETag key) must NOT throw' {
        It 'returns Success=$false / StatusCode / ETag=$null without throwing' {
            Mock -ModuleName Xdr.Common.Storage Invoke-XdrStorageRest { @{ Success = $false; StatusCode = 404; Headers = @{}; Content = 'nf'; Error = 'ResourceNotFound' } }
            # Calling directly: a PropertyNotFoundException (the pre-fix bug) would fail this It outright.
            $r = Set-XdrTableEntity -TableName 'XdrCheckpoint' -PartitionKey 'Defender_Operations' -RowKey 'GetHistory' -Properties @{ Cursor = 'x' }
            $r.Success | Should -BeFalse
            $r.StatusCode | Should -Be 404
            $r.ETag | Should -BeNullOrEmpty
        }
        It 'returns the ETag on a success-path response' {
            Mock -ModuleName Xdr.Common.Storage Invoke-XdrStorageRest { @{ Success = $true; StatusCode = 204; Headers = @{}; Content = ''; ETag = 'W/"etag1"'; LeaseId = $null } }
            (Set-XdrTableEntity -TableName 'XdrCheckpoint' -PartitionKey 'p' -RowKey 'r' -Properties @{ Cursor = 'x' }).ETag | Should -Be 'W/"etag1"'
        }
    }
    Context 'Save-XdrCheckpointAtomic · Insert-Or-Replace on first write' {
        It 'first-ever write (empty ExistingETag) sends NO If-Match (upsert · not If-Match:* which 404s)' {
            Mock -ModuleName Xdr.Common.Runtime Set-XdrTableEntity { @{ Success = $true; StatusCode = 204; ETag = 'e1'; Error = $null } }
            Save-XdrCheckpointAtomic -PartitionKey 'Defender_Operations' -OperationKey 'GetHistory' -Cursor '2026-05-03T00:00:00Z' -Window @{ StartUtc = 'x'; EndUtc = 'y' } -ItemCount 1 -ExistingETag '' | Should -BeTrue
            Should -Invoke -ModuleName Xdr.Common.Runtime Set-XdrTableEntity -Times 1 -Exactly -ParameterFilter { $IfMatchETag -eq '' }
        }
        It 'subsequent write with a real ETag sends If-Match:<etag> (conditional)' {
            Mock -ModuleName Xdr.Common.Runtime Set-XdrTableEntity { @{ Success = $true; StatusCode = 204; ETag = 'e2'; Error = $null } }
            Save-XdrCheckpointAtomic -PartitionKey 'p' -OperationKey 'o' -Cursor 'c' -Window @{ StartUtc = 'x'; EndUtc = 'y' } -ItemCount 1 -ExistingETag 'W/"prev"' | Should -BeTrue
            Should -Invoke -ModuleName Xdr.Common.Runtime Set-XdrTableEntity -Times 1 -Exactly -ParameterFilter { $IfMatchETag -eq 'W/"prev"' }
        }
    }
}
