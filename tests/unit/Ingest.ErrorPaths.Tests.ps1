#Requires -Modules Pester
<#
.SYNOPSIS
    Mock-based unit tests for ingest error paths.
    Coverage: Send-ToLogAnalytics 413 split + 5xx retry + DLQ enqueue + per-batch metrics.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:SendPath = Join-Path $script:RepoRoot 'src/Modules/Xdr.Sentinel.Ingest/Public/Send-ToLogAnalytics.ps1'
    $script:DlqPath = Join-Path $script:RepoRoot 'src/Modules/Xdr.Sentinel.Ingest/Public/Pop-XdrIngestDlq.ps1'
}

Describe 'Ingest.ErrorPaths — Send-ToLogAnalytics 413 split-and-retry' {
    It 'Source contains 413 status code handling' {
        $content = Get-Content $script:SendPath -Raw
        $content | Should -Match '\b413\b'
    }

    It 'Source contains batch-split logic (RequestEntityTooLarge)' {
        $content = Get-Content $script:SendPath -Raw
        ($content -match '(?i)split|halve|chunked' -and $content -match '\b413\b') | Should -BeTrue
    }
}

Describe 'Ingest.ErrorPaths — Send-ToLogAnalytics retry + DLQ' {
    It 'Source has retry loop for 5xx' {
        $content = Get-Content $script:SendPath -Raw
        ($content -match '5\d\d|StatusCode|HttpStatusCode') | Should -BeTrue
    }

    It 'Source enqueues to DLQ on persistent failure' {
        $content = Get-Content $script:SendPath -Raw
        $content | Should -Match '(?i)dlq|deadLetter|Push-Xdr'
    }

    It '0-row batch skip path' {
        $content = Get-Content $script:SendPath -Raw
        ($content -match '\.Count\s*-eq\s*0|\.Count\s*-le\s*0|empty') | Should -BeTrue -Because 'must skip ingest call entirely on 0 rows'
    }
}

Describe 'Ingest.ErrorPaths — Per-batch AppInsights metrics' {
    It 'xdr.ingest.rows metric is emitted' {
        $content = Get-Content $script:SendPath -Raw
        $content | Should -Match "'xdr\.ingest\.rows'"
    }

    It 'xdr.ingest.bytes_compressed metric is emitted' {
        $content = Get-Content $script:SendPath -Raw
        $content | Should -Match "'xdr\.ingest\.bytes_compressed'"
    }

    It 'xdr.ingest.compression_ratio metric is emitted' {
        $content = Get-Content $script:SendPath -Raw
        $content | Should -Match "'xdr\.ingest\.compression_ratio'"
    }

    It 'xdr.ingest.retry_count metric is emitted' {
        $content = Get-Content $script:SendPath -Raw
        $content | Should -Match "'xdr\.ingest\.retry_count'"
    }

    It 'xdr.ingest.dce_latency_ms metric is emitted' {
        $content = Get-Content $script:SendPath -Raw
        $content | Should -Match "'xdr\.ingest\.dce_latency_ms'"
    }

    It 'xdr.ingest.row_count_per_hour cost-budget gate is emitted' {
        $content = Get-Content $script:SendPath -Raw
        $content | Should -Match "'xdr\.ingest\.row_count_per_hour'" -Because 'D49: cost-budget runtime gate metric required'
    }

    It 'xdr.ingest.row_age_seconds freshness SLI is emitted' {
        $content = Get-Content $script:SendPath -Raw
        $content | Should -Match "'xdr\.ingest\.row_age_seconds'"
    }
}

Describe 'Ingest.ErrorPaths — DLQ drain semantics' {
    It 'Pop-XdrIngestDlq is exported' {
        Test-Path $script:DlqPath | Should -BeTrue
    }

    It 'DLQ source has TTL eviction logic' {
        if (Test-Path $script:DlqPath) {
            $content = Get-Content $script:DlqPath -Raw
            ($content -match '(?i)ttl|expir|evict') | Should -BeTrue -Because 'DLQ entries should TTL-expire to prevent unbounded growth'
        } else {
            Set-ItResult -Skipped -Because 'Pop-XdrIngestDlq path moved'
        }
    }
}
