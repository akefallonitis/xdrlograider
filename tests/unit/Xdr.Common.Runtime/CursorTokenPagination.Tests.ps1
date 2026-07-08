#Requires -Version 7.4
# T3a (audit 2026-06-12 · operator directive "all pagination generic/always-working across all cases") · TOKEN /
# nextLink pagination drained end-to-end through the REAL Invoke-XdrEntryPoll loop. The runtime token path was
# REACHABLE but had 2 LIVE-PROVEN gaps that made it silently single-page (data loss) on the dominant Microsoft
# idiom: (G-a) Get-XdrNextCursor split CursorPath on '.', so a literal response key named `odata.nextLink` (the
# Defender Attack-Simulator live shape · references/live/.../ListSimulations/response.json) split into odata->nextLink
# and resolved to $null; (G-b) only an ABSOLUTE https:// cursor was treated as a URL, so a RELATIVE nextLink
# (`?$skiptoken=...`, the same live shape) was never composed against the base. Both fixed via a generic JSONPath
# tokenizer (bracket + dotted segments) + a relative-nextLink compose. The opaque-token mode (XSPM `$.skipToken` ->
# re-sent as a query param) already worked at the helper level; this pins it end-to-end too.

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

Describe 'T3a · Split-XdrJsonPath · generic JSONPath tokenizer (bracket + dotted segments)' {
    It 'tokenizes a literal dotted KEY in bracket notation as ONE segment (the odata.nextLink foot-gun)' {
        InModuleScope Xdr.Common.Runtime {
            ((Split-XdrJsonPath "`$['odata.nextLink']") -join '|') | Should -Be 'odata.nextLink'   # literal dotted key = ONE segment
            ((Split-XdrJsonPath '$.@odata.nextLink')    -join '|') | Should -Be '@odata|nextLink'  # dotted form still splits
            ((Split-XdrJsonPath '$.skipToken')          -join '|') | Should -Be 'skipToken'
            ((Split-XdrJsonPath '$.a.b')                -join '|') | Should -Be 'a|b'
            ((Split-XdrJsonPath "`$['a']['b']")          -join '|') | Should -Be 'a|b'
            ((Split-XdrJsonPath '$.data["next.page"]')  -join '|') | Should -Be 'data|next.page'
        }
    }
}

Describe 'T3c · empty-token TERMINATION · a URL-shaped cursor with only EMPTY query values is end-of-data' {
    # LIVE-PROVEN shape: the Attack-Simulator last/empty page returns odata.nextLink = "?$skiptoken=" — a relative
    # URL whose token VALUE is empty. Following it re-fetches the SAME page forever (bounded only by the cycle
    # budget · and a SNAPSHOT op would MULTIPLY rows — intra-cycle dedup is CURSOR-only). Must terminate.
    It 'an empty-valued relative token ("?$skiptoken=") terminates; a real token ("?$skiptoken=AAA") continues' {
        InModuleScope Xdr.Common.Runtime {
            $e = @{ Pagination = @{ Mode = 'cursor'; CursorMode = 'nextLink'; CursorPath = "`$['odata.nextLink']" } }
            Get-XdrNextCursor -Response @{ 'odata.nextLink' = '?$skiptoken=' }    -Entry $e | Should -BeNullOrEmpty
            Get-XdrNextCursor -Response @{ 'odata.nextLink' = '?$skiptoken=AAA' } -Entry $e | Should -Be '?$skiptoken=AAA'
            Get-XdrNextCursor -Response @{ 'odata.nextLink' = $null }             -Entry $e | Should -BeNullOrEmpty
        }
    }
    It 'an empty-valued ABSOLUTE nextLink terminates too (same rule across URL shapes)' {
        InModuleScope Xdr.Common.Runtime {
            $e = @{ Pagination = @{ Mode = 'cursor'; CursorMode = 'nextLink'; CursorPath = '$.nextLink' } }
            Get-XdrNextCursor -Response @{ nextLink = 'https://security.microsoft.com/x?$skiptoken=' }     -Entry $e | Should -BeNullOrEmpty
            Get-XdrNextCursor -Response @{ nextLink = 'https://security.microsoft.com/x?$skiptoken=BBB' } -Entry $e | Should -Be 'https://security.microsoft.com/x?$skiptoken=BBB'
        }
    }
}

Describe 'T3a · nextLink-relative pagination (Attack-Simulator live shape: odata.nextLink + ?$skiptoken=) drains ALL pages' {
    BeforeEach {
        $script:Entry = @{
            OperationKey = 'ListSimulations'; Portal = 'Defender'; Category = 'Operations'; Method = 'GET'; SubPortal = 'mtp'; Path = '/x'
            ResponseShape = 'wrapper'; ItemsContainer = 'value'
            IngestionMode = 'SNAPSHOT'; NaturalKey = @('Id')
            Pagination = @{ Mode = 'cursor'; CursorMode = 'nextLinkRelative'; CursorPath = "`$['odata.nextLink']"; LoopGuard = 1000 }
            ProjectionMap = @{ Id = '$.Id' }
            DcrImmutableId = 'dcr-test'; DcrStreamName = 'Custom-Defender_Operations_CL'
        }
        $global:XdrTokCall = 0; $global:XdrTokUrls = @(); $global:XdrTokRows = 0
        $global:XdrTokPages = @(
            @{ value = @(@{ Id = 'r1' }, @{ Id = 'r2' }); 'odata.nextLink' = '?$skiptoken=AAA' },
            @{ value = @(@{ Id = 'r3' });                 'odata.nextLink' = $null }
        )
        Mock -ModuleName Xdr.Common.Runtime Connect-XdrPortal { @{ Portal = 'Defender'; Sccauth = 'x'; XsrfToken = 'y' } }
        Mock -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp {
            $global:XdrTokUrls += $Url
            $idx = $global:XdrTokCall; $global:XdrTokCall++
            @{ StatusCode = 200; Body = $global:XdrTokPages[$idx]; RawBody = '' }
        }
        Mock -ModuleName Xdr.Common.Runtime Get-XdrCheckpoint { @{ OperationKey = 'ListSimulations'; Cursor = $null; BoundaryKeys = $null; ETag = $null } }
        Mock -ModuleName Xdr.Common.Runtime Save-XdrCheckpointAtomic { $true }
        Mock -ModuleName Xdr.Common.Runtime Send-ToDce { $global:XdrTokRows += @($Rows).Count; @{ Success = $true; RowsAccepted = @($Rows).Count; BytesIngested = 100 } }
        Mock -ModuleName Xdr.Common.Runtime Lock-XdrSingleFlight { 'lease-granted' }
        Mock -ModuleName Xdr.Common.Runtime Unlock-XdrSingleFlight { $true }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrEvent { }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrException { }
    }
    It 'follows the relative nextLink to page 2 and ingests ALL 3 rows (not just page-1''s 2 — the silent-single-page bug)' {
        $r = Invoke-XdrEntryPoll -Entry $script:Entry -CorrelationId 'tok-rel-1'
        $r.Success | Should -BeTrue
        $global:XdrTokCall | Should -Be 2            # page 2 WAS fetched (token resolved + composed)
        $global:XdrTokRows | Should -Be 3            # r1+r2+r3 (page-1-only = 2 = the data-loss RED)
    }
    It 'composes the relative token against the request base (base-path + ?$skiptoken=AAA)' {
        $null = Invoke-XdrEntryPoll -Entry $script:Entry -CorrelationId 'tok-rel-2'
        $global:XdrTokUrls.Count | Should -Be 2
        $global:XdrTokUrls[1] | Should -Match '/apiproxy/mtp/x\?\$skiptoken=AAA'
        $global:XdrTokUrls[1] | Should -Match '^https://security\.microsoft\.com'
    }
}

Describe 'T3a · cursor-token pagination (XSPM live shape: $.skipToken -> re-sent as a query param) drains ALL pages' {
    BeforeEach {
        $script:Entry = @{
            OperationKey = 'ListXspm'; Portal = 'Defender'; Category = 'Operations'; Method = 'GET'; SubPortal = 'mtp'; Path = '/y'
            ResponseShape = 'wrapper'; ItemsContainer = 'data'
            IngestionMode = 'SNAPSHOT'; NaturalKey = @('Id')
            Pagination = @{ Mode = 'cursor'; CursorMode = 'cursorToken'; CursorPath = '$.skipToken'; CursorQuery = 'skipToken'; LoopGuard = 1000 }
            ProjectionMap = @{ Id = '$.Id' }
            DcrImmutableId = 'dcr-test'; DcrStreamName = 'Custom-Defender_Operations_CL'
        }
        $global:XdrTokCall = 0; $global:XdrTokUrls = @(); $global:XdrTokRows = 0
        $global:XdrTokPages = @(
            @{ data = @(@{ Id = 'r1' }); skipToken = 'TOK1' },
            @{ data = @(@{ Id = 'r2' }); skipToken = $null }
        )
        Mock -ModuleName Xdr.Common.Runtime Connect-XdrPortal { @{ Portal = 'Defender'; Sccauth = 'x'; XsrfToken = 'y' } }
        Mock -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp {
            $global:XdrTokUrls += $Url
            $idx = $global:XdrTokCall; $global:XdrTokCall++
            @{ StatusCode = 200; Body = $global:XdrTokPages[$idx]; RawBody = '' }
        }
        Mock -ModuleName Xdr.Common.Runtime Get-XdrCheckpoint { @{ OperationKey = 'ListXspm'; Cursor = $null; BoundaryKeys = $null; ETag = $null } }
        Mock -ModuleName Xdr.Common.Runtime Save-XdrCheckpointAtomic { $true }
        Mock -ModuleName Xdr.Common.Runtime Send-ToDce { $global:XdrTokRows += @($Rows).Count; @{ Success = $true; RowsAccepted = @($Rows).Count; BytesIngested = 100 } }
        Mock -ModuleName Xdr.Common.Runtime Lock-XdrSingleFlight { 'lease-granted' }
        Mock -ModuleName Xdr.Common.Runtime Unlock-XdrSingleFlight { $true }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrEvent { }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrException { }
    }
    It 'extracts $.skipToken and re-sends it as the skipToken query param on page 2 · ingests both rows' {
        $r = Invoke-XdrEntryPoll -Entry $script:Entry -CorrelationId 'tok-q-1'
        $r.Success | Should -BeTrue
        $global:XdrTokCall | Should -Be 2
        $global:XdrTokRows | Should -Be 2
        $global:XdrTokUrls[1] | Should -Match 'skipToken=TOK1'
    }
}
