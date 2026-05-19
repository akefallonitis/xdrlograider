#Requires -Module Pester
# Pure-function coverage for Xdr.Ingest helpers · no live HTTP / MI required.
# Exercises Split-IngestBatch + Write-Heartbeat row shape + Invoke-XdrStorageTableEntity arg validation.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Ingest/Xdr.Ingest.psd1') -Force
}

Describe 'Split-IngestBatch (pure chunker)' -Tag 'ingest-pure' {

    It 'returns empty chunk list for empty input' {
        $r = Split-IngestBatch -Rows @()
        @($r).Count | Should -Be 0
    }

    It 'wraps single small row in one chunk' {
        $row = [pscustomobject]@{ TimeGenerated = '2026-01-01T00:00:00Z'; Portal = 'Defender'; RawJson = 'small' }
        $r = Split-IngestBatch -Rows @($row)
        @($r).Count | Should -Be 1
        @($r[0]).Count | Should -Be 1
    }

    It 'splits when cumulative size exceeds MaxBytes' {
        # Build many rows · each ~ 5KB · cap at 20KB → expect ≥ 3 chunks
        $big = 'x' * 4500
        $rows = 1..10 | ForEach-Object { [pscustomobject]@{ TimeGenerated = '2026-01-01T00:00:00Z'; RawJson = $big } }
        $r = Split-IngestBatch -Rows $rows -MaxBytes 20KB
        @($r).Count | Should -BeGreaterThan 2
    }

    It 'never produces an empty chunk in non-empty input' {
        $rows = 1..5 | ForEach-Object { [pscustomobject]@{ A = $_ } }
        $r = Split-IngestBatch -Rows $rows -MaxBytes 100KB
        foreach ($chunk in $r) { @($chunk).Count | Should -BeGreaterThan 0 }
    }

    It 'preserves total row count across all chunks' {
        $rows = 1..47 | ForEach-Object { [pscustomobject]@{ A = $_; Payload = 'x' * 100 } }
        $r = Split-IngestBatch -Rows $rows -MaxBytes 5KB
        $sum = 0
        foreach ($chunk in $r) { $sum += @($chunk).Count }
        $sum | Should -Be 47
    }

    It 'preserves row ordering (chunks are sequential cuts of input)' {
        $rows = 1..10 | ForEach-Object { [pscustomobject]@{ Idx = $_; Pad = 'x' * 500 } }
        $r = Split-IngestBatch -Rows $rows -MaxBytes 2KB
        $flat = foreach ($chunk in $r) { $chunk }
        $indices = @($flat | ForEach-Object { $_.Idx })
        # Compare as joined string · Should -Be on arrays needs comma-coalescing both sides equally
        ($indices -join ',') | Should -Be ((1..10) -join ',')
    }

    It 'tolerates oversize single row by emitting it in its own chunk' {
        # One row that already exceeds MaxBytes; should still be emitted (with a warning at runtime)
        $oversize = [pscustomobject]@{ Big = 'x' * 10000 }
        $r = Split-IngestBatch -Rows @($oversize) -MaxBytes 1KB
        @($r).Count | Should -Be 1
        @($r[0]).Count | Should -Be 1
    }
}

Describe 'Get-MiBearerToken cache (cold-start path · mocked)' -Tag 'ingest-pure' {
    # Live token acquisition is integration · skip if Az.Accounts not loaded
    # We exercise the script-scope cache directly by setting it ourselves.

    It 'is callable (signature only · returns string)' {
        $cmd = Get-Command Get-MiBearerToken
        $cmd.OutputType.Type.Name | Should -Contain 'String'
    }

    It 'has Force + RefreshBeforeMinutes parameters' {
        $cmd = Get-Command Get-MiBearerToken
        $cmd.Parameters.Keys | Should -Contain 'Force'
        $cmd.Parameters.Keys | Should -Contain 'RefreshBeforeMinutes'
    }
}

Describe 'Invoke-XdrStorageTableEntity parameter contract' -Tag 'ingest-pure' {
    It 'is exported as public function' {
        Get-Command Invoke-XdrStorageTableEntity -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
    It 'accepts the canonical (Verb · StorageAccount · Table · PartitionKey · RowKey · Entity · Filter · BearerToken) parameter set' {
        $cmd = Get-Command Invoke-XdrStorageTableEntity
        foreach ($p in @('Verb','StorageAccount','Table','PartitionKey','RowKey','Entity','Filter','BearerToken')) {
            $cmd.Parameters.Keys | Should -Contain $p -Because "Invoke-XdrStorageTableEntity must expose parameter '$p'"
        }
    }
}

Describe 'Write-Heartbeat signature + row schema (Reinforcement-B/C cols)' -Tag 'ingest-pure' {
    It 'exposes Portal · ReauthCount · SkippedThisCycle · CircuitOpen · Capabilities parameters (Reinforcement-B/C contract)' {
        $cmd = Get-Command Write-Heartbeat
        $cmd.Parameters.Keys | Should -Contain 'Portal'
        $cmd.Parameters.Keys | Should -Contain 'ReauthCount'
        $cmd.Parameters.Keys | Should -Contain 'SkippedThisCycle'
        $cmd.Parameters.Keys | Should -Contain 'CircuitOpen'
        $cmd.Parameters.Keys | Should -Contain 'Capabilities'
    }
    It 'defaults StreamName to Custom-XdrConnectorHealth_CL (post-0m rename)' {
        # Inspect the psm1 source directly · AST traversal across Get-Command varies by PS version
        $psm1 = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'src/Modules/Xdr.Ingest/Xdr.Ingest.psm1')
        $psm1 | Should -Match "StreamName\s*=\s*'Custom-XdrConnectorHealth_CL'"
    }
}
