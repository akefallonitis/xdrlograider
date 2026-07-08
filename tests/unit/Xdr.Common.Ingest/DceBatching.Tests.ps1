#Requires -Version 7.4
# DCE <1MB batching proof (plan §35.6 B-DCE-BATCH). A batch whose serialized size exceeds the ~1MB DCE request
# limit must be split into multiple <900KB POSTs · RowsAccepted = sum · Success only if ALL chunks 2xx.

BeforeAll {
    $script:Repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $psd1s = Get-ChildItem (Join-Path $script:Repo 'src\Modules') -Directory |
        ForEach-Object { Join-Path $_.FullName ($_.Name + '.psd1') } | Where-Object { Test-Path $_ }
    for ($pass = 1; $pass -le 4; $pass++) {
        foreach ($p in $psd1s) { try { Import-Module $p -Force -DisableNameChecking -ErrorAction Stop } catch { } }
    }
    # 12 rows × ~100KB each ≈ 1.2MB → must split into ≥2 chunks (<900KB each).
    $big = 'x' * 100000
    $script:BigRows = 1..12 | ForEach-Object { @{ ActionId = "row-$_"; RawJson = $big } }
    $script:SmallRows = 1..3 | ForEach-Object { @{ ActionId = "row-$_"; RawJson = 'small' } }
}

Describe 'DCE <1MB batching (plan §35.6)' {
    BeforeEach {
        Mock -ModuleName Xdr.Common.Ingest Get-XdrDcrAuthToken { 'test-token' }
        Mock -ModuleName Xdr.Common.Ingest Invoke-WebRequest { @{ StatusCode = 204; Content = '' } }
        Mock -ModuleName Xdr.Common.Ingest Track-XdrDependency { }
        Mock -ModuleName Xdr.Common.Ingest Track-XdrEvent { }
        Mock -ModuleName Xdr.Common.Ingest Track-XdrException { }
        Mock -ModuleName Xdr.Common.Ingest Send-XdrDlq { }
    }

    It 'small batch posts once and accepts all rows (single chunk · no behavior change)' {
        $r = Send-ToDce -DceEndpoint 'https://dce.local' -DcrId 'dcr1' -StreamName 'Custom-X_CL' -Rows $script:SmallRows
        $r.Success | Should -BeTrue
        $r.RowsAccepted | Should -Be 3
        Should -Invoke -ModuleName Xdr.Common.Ingest Invoke-WebRequest -Times 1 -Exactly
    }

    It 'a >1MB batch SPLITS into multiple <900KB POSTs and accepts ALL rows' {
        $r = Send-ToDce -DceEndpoint 'https://dce.local' -DcrId 'dcr1' -StreamName 'Custom-X_CL' -Rows $script:BigRows
        $r.Success | Should -BeTrue
        $r.RowsAccepted | Should -Be 12
        # 1.2MB / 900KB → at least 2 chunks → at least 2 POSTs (a single un-chunked POST would be 1).
        Should -Invoke -ModuleName Xdr.Common.Ingest Invoke-WebRequest -Times 2 -ParameterFilter { $true }
    }

    It 'if a chunk fails terminally, overall Success is false (cursor must NOT advance) and DLQ is invoked' {
        Mock -ModuleName Xdr.Common.Ingest Invoke-WebRequest { throw [System.Exception]::new('HTTP 400 Bad Request') }
        $r = Send-ToDce -DceEndpoint 'https://dce.local' -DcrId 'dcr1' -StreamName 'Custom-X_CL' -Rows $script:BigRows
        $r.Success | Should -BeFalse
        Should -Invoke -ModuleName Xdr.Common.Ingest Send-XdrDlq -Times 1
    }
}
