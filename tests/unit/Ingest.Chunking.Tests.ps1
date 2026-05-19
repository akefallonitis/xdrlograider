#Requires -Module Pester
# Locks: Split-IngestBatch respects the ~900 KB safe ceiling.
# Prevents the recurring "1.4 MB row silently dropped" class from prior forks.

BeforeAll {
    $ModulePath = Join-Path $PSScriptRoot '..\..\src\Modules\Xdr.Ingest\Xdr.Ingest.psd1'
    Import-Module $ModulePath -Force
}

Describe 'Split-IngestBatch' {

    It 'returns one chunk for small input' {
        $rows = 1..5 | ForEach-Object { [pscustomobject]@{ id=$_; payload='tiny' } }
        $chunks = Split-IngestBatch -Rows $rows
        @($chunks).Count | Should -Be 1
        @($chunks[0]).Count | Should -Be 5
    }

    It 'returns multiple chunks when rows exceed MaxBytes' {
        $bigStr = 'x' * 50000   # ~50 KB string per row → 50 rows ≈ 2.5 MB total
        $rows = 1..50 | ForEach-Object { [pscustomobject]@{ id=$_; payload=$bigStr } }
        $chunks = Split-IngestBatch -Rows $rows -MaxBytes 500KB
        @($chunks).Count | Should -BeGreaterThan 1
        # Total rows preserved
        ($chunks | ForEach-Object { @($_).Count } | Measure-Object -Sum).Sum | Should -Be 50
    }

    It 'returns empty array for empty input' {
        $chunks = Split-IngestBatch -Rows @()
        @($chunks).Count | Should -Be 0
    }

    It 'never produces a chunk whose JSON exceeds MaxBytes (under the 1 MB API hard cap)' {
        $bigStr = 'x' * 20000
        $rows = 1..100 | ForEach-Object { [pscustomobject]@{ id=$_; payload=$bigStr } }
        $maxBytes = 100KB
        $chunks = Split-IngestBatch -Rows $rows -MaxBytes $maxBytes
        foreach ($chunk in $chunks) {
            $json = $chunk | ConvertTo-Json -Depth 100 -Compress
            $bytes = [System.Text.Encoding]::UTF8.GetByteCount($json)
            # Allow some slack — a single row may exceed MaxBytes alone and end up in its
            # own chunk; the rule is that we never combine rows when doing so would breach.
            if (@($chunk).Count -gt 1) {
                $bytes | Should -BeLessOrEqual $maxBytes
            }
        }
    }
}
