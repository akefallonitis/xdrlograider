# P-ENG · request-builder mechanism completeness (plan §4.G/§7). Proves the clean classifier
# (Get-XdrRequestParams) + New-XdrRequestUrl + New-XdrRequestBody speak every paging/time SHAPE as
# manifest data — query AND body — with the live Operations (pageIndex + ClientSideHighWater) path
# unchanged (no regression). No legacy field-name fallbacks: correctness is the clean contract only.

#Requires -Module Pester

BeforeAll {
    Set-StrictMode -Version Latest
    $modulesRoot = Join-Path $PSScriptRoot '..\..\..\src\Modules' | Resolve-Path
    $env:PSModulePath = $modulesRoot.Path + [IO.Path]::PathSeparator + $env:PSModulePath
    foreach ($m in @('Xdr.Common.Exceptions','Xdr.Common.Telemetry','Xdr.Common.Cache','Xdr.Common.Storage','Xdr.Common.Auth','Xdr.Common.Parser','Xdr.Common.Ingest','Xdr.Common.Runtime')) {
        Import-Module (Join-Path $modulesRoot.Path "$m\$m.psd1") -Force -DisableNameChecking -ErrorAction Stop
    }
    # The live-proven Operations/ActionCenter pagination shape (pageIndex 1-based · ClientSideHighWater).
    function New-OperationsEntry {
        @{
            Portal = 'Defender'; SubPortal = 'mtp'; Path = '/actionCenter/actioncenterui/history-actions'; Method = 'GET'
            TimeFilter = @{ Mode = 'ClientSideHighWater'; FieldName = 'EventTime' }
            Pagination = @{ Mode = 'pageSize'; ParamLocation = 'query'
                PageSizeQuery = 'pageSize'; PageSize = 50
                PageIndexQuery = 'pageIndex'; PageIndexStart = 1
                SortByQuery = 'sortByField'; SortByField = 'EventTime'
                SortOrderQuery = 'sortOrder'; SortOrder = 'Descending' }
        }
    }
}

Describe 'P-ENG · request builder · NO regression on the live Operations shape' {
    It 'builds the exact ActionCenter query (pageSize/pageIndex 1-based/sort · NO server time param)' {
        $e = New-OperationsEntry
        $u1 = New-XdrRequestUrl -Entry $e -Window @{ StartUtc = '2026-06-04T00:00:00Z' } -Page 1
        $u1 | Should -Match 'pageSize=50'
        $u1 | Should -Match 'pageIndex=1'          # 1-based · page 1 → pageIndex 1
        $u1 | Should -Match 'sortByField=EventTime'
        $u1 | Should -Match 'sortOrder=Descending'
        $u1 | Should -Not -Match 'EventTime=2026'   # ClientSideHighWater emits NO server time predicate
        $u1 | Should -BeLike 'https://security.microsoft.com/apiproxy/mtp/actionCenter/*'
    }
    It 'increments pageIndex with the 1-based offset on page 2' {
        $u2 = New-XdrRequestUrl -Entry (New-OperationsEntry) -Window @{} -Page 2
        $u2 | Should -Match 'pageIndex=2'
    }
    It 'returns NO body for a GET/query-only op (identical to the prior static-body path)' {
        (New-XdrRequestBody -Entry (New-OperationsEntry) -Window @{} -Page 1) | Should -BeNullOrEmpty
    }
}

Describe 'P-ENG · request builder · new paging/time shapes (manifest data · no code)' {
    It 'skipTop · computes $skip offset = (page-1)*top' {
        $e = @{ Portal = 'Defender'; Path = '/x'; Pagination = @{ Mode = 'skipTop'; SkipQuery = '$skip'; TopQuery = '$top'; PageSize = 100 } }
        $rp1 = Get-XdrRequestParams -Entry $e -Window @{} -Page 1
        $rp1.Query['$skip'] | Should -Be '0';   $rp1.Query['$top'] | Should -Be '100'
        $rp3 = Get-XdrRequestParams -Entry $e -Window @{} -Page 3
        $rp3.Query['$skip'] | Should -Be '200'
    }
    It 'ServerOData · emits a real $filter predicate (Field Operator iso)' {
        $e = @{ Portal = 'Defender'; Path = '/x'; TimeFilter = @{ Mode = 'ServerOData'; FieldName = 'createdDateTime'; Operator = 'ge' } }
        $rp = Get-XdrRequestParams -Entry $e -Window @{ StartUtc = '2026-06-04T00:00:00Z' } -Page 1
        # T3d · the value is canonicalised by Format-XdrTimeValue (full-fidelity 'o') — the SAME bytes production
        # always sent, since Resolve-XdrTimeWindow emits 'o' on every path; only a hand-shortened test input differs.
        $rp.Query['$filter'] | Should -Be 'createdDateTime ge 2026-06-04T00:00:00.0000000Z'
    }
    It 'ServerFromDate · emits From/To date params' {
        $e = @{ Portal = 'Defender'; Path = '/x'; TimeFilter = @{ Mode = 'ServerFromDate'; FieldName = 'd'; FromDateParam = 'fromDate'; ToDateParam = 'toDate' } }
        $rp = Get-XdrRequestParams -Entry $e -Window @{ StartUtc = '2026-06-04T00:00:00Z'; EndUtc = '2026-06-04T01:00:00Z' } -Page 1
        $rp.Query['fromDate'] | Should -Be '2026-06-04T00:00:00.0000000Z'   # T3d · canonical 'o' (see above)
        $rp.Query['toDate']   | Should -Be '2026-06-04T01:00:00.0000000Z'
    }
    It 'ParamLocation=body · POST-read paging merges into the BODY, NOT the query' {
        $e = @{ Portal = 'Defender'; Path = '/x'; Method = 'POST'; BodyTemplate = @{ filter = 'high' }
                Pagination = @{ Mode = 'pageSize'; ParamLocation = 'body'; PageSizeQuery = 'pageSize'; PageSize = 50; PageIndexQuery = 'pageIndex'; PageIndexStart = 0 } }
        $url  = New-XdrRequestUrl  -Entry $e -Window @{} -Page 2
        $body = New-XdrRequestBody -Entry $e -Window @{} -Page 2
        $url  | Should -Not -Match 'pageSize'        # body-located → NOT in the query string
        $body['filter']    | Should -Be 'high'       # static template preserved
        $body['pageSize']  | Should -Be '50'         # paging merged into the body
        $body['pageIndex'] | Should -Be '1'          # page 2 · 0-based start
    }
    It '{TenantId} · substitutes the path token from R3 tenant context' {
        $e = @{ Portal = 'Defender'; Path = '/api/{TenantId}/data'; TenantId = 'tid-123' }
        $u = New-XdrRequestUrl -Entry $e -Window @{} -Page 1
        $u | Should -Match '/api/tid-123/data'
        $u | Should -Not -Match '\{TenantId\}'
    }
    It 'nextLink-absolute · a full-URL cursor IS the next request, verbatim' {
        $e = @{ Portal = 'Defender'; Path = '/x'; Pagination = @{ Mode = 'cursor'; CursorQuery = 'token' } }
        $u = New-XdrRequestUrl -Entry $e -Window @{} -Cursor 'https://security.microsoft.com/apiproxy/mtp/x?$skiptoken=ABC' -Page 2
        $u | Should -Be 'https://security.microsoft.com/apiproxy/mtp/x?$skiptoken=ABC'
    }
    It 'CursorPath (clean single name) · Get-XdrNextCursor extracts the server token from the body' {
        # Get-XdrNextCursor is module-internal (script:-scoped) → call it inside the module scope.
        InModuleScope 'Xdr.Common.Runtime' {
            (Get-XdrNextCursor -Response @{ nextToken = 'CONT-1' } -Entry @{ CursorPath = '$.nextToken' } -Page 1 -PageRowCount 0) | Should -Be 'CONT-1'
        }
    }
}
