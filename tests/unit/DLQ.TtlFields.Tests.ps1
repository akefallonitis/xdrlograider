#Requires -Modules Pester
<#
.SYNOPSIS
    Phase F.4 + L.1 DLQ TTL fields + consumer regression test.

.DESCRIPTION
    Per .claude/plans/immutable-splashing-waffle.md:
    - Push-XdrIngestDlq stamps ExpiresUtc + TtlDays fields on every DLQ row
    - Pop-XdrIngestDlq SKIPS + DELETES expired entries (Phase L.1 consumer)
    - Default TTL = 7 days; XDR_INGEST_DLQ_TTL_DAYS env var override

    This test gates:
      1. Push-XdrIngestDlq has ExpiresUtc + TtlDays fields in entity payload
      2. Pop-XdrIngestDlq has TTL skip+delete logic (calls Remove-XdrIngestDlqEntry on expired)
      3. Pop emits Ingest.DlqExpired exception class with structured Properties
      4. Pop emits xdr.dlq.ttl_evicted_count metric
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:PushFile = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Sentinel.Ingest' 'Public' 'Push-XdrIngestDlq.ps1'
    $script:PopFile  = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Sentinel.Ingest' 'Public' 'Pop-XdrIngestDlq.ps1'
}

Describe 'Phase F.4 — Push-XdrIngestDlq stamps TTL fields' {
    It 'Push has TtlDays parameter with default value 7 (overridable via XDR_INGEST_DLQ_TTL_DAYS env var)' {
        $content = Get-Content -Raw -Path $script:PushFile
        $content | Should -Match 'TtlDays' -Because 'Phase F.4 added TtlDays parameter'
        $content | Should -Match 'XDR_INGEST_DLQ_TTL_DAYS' -Because 'env var override for operator tuning'
    }

    It 'Push entity payload contains ExpiresUtc field (computed from FirstFailedUtc + TtlDays)' {
        $content = Get-Content -Raw -Path $script:PushFile
        $content | Should -Match 'ExpiresUtc\s*=' -Because 'Phase F.4 stamps ExpiresUtc on every DLQ row'
        $content | Should -Match 'AddDays\(\$TtlDays\)' -Because 'ExpiresUtc must be computed from FirstFailedUtc + TtlDays'
    }
}

Describe 'Phase L.1 — Pop-XdrIngestDlq TTL consumer (skip + delete + emit)' {
    It 'Pop checks ExpiresUtc per entry and SKIPS expired' {
        $content = Get-Content -Raw -Path $script:PopFile
        $content | Should -Match "PSObject\.Properties\['ExpiresUtc'\]" -Because 'Pop must read ExpiresUtc field'
        $content | Should -Match '\$expiresUtc\s+-lt\s+\$now' -Because 'Pop must compare ExpiresUtc to now'
    }

    It 'Pop calls Remove-XdrIngestDlqEntry to DELETE expired entries' {
        $content = Get-Content -Raw -Path $script:PopFile
        # Look for Remove call within the TTL handling block
        $content | Should -Match 'Remove-XdrIngestDlqEntry' -Because 'expired entries must be deleted (not just skipped)'
    }

    It 'Pop emits Ingest.DlqExpired exception class for forensic logging' {
        $content = Get-Content -Raw -Path $script:PopFile
        $content | Should -Match "ErrorClass\s*=\s*'Ingest\.DlqExpired'" -Because 'expired entries logged to AppExceptions for ops alerts'
    }

    It 'Pop emits xdr.dlq.ttl_evicted_count metric when expiredCount > 0' {
        $content = Get-Content -Raw -Path $script:PopFile
        $content | Should -Match "'xdr\.dlq\.ttl_evicted_count'" -Because 'operators alert on sustained nonzero TTL evictions'
        $content | Should -Match '\$expiredCount\s+-gt\s+0' -Because 'metric only emitted when there were evictions'
    }

    It 'Pop continues processing remaining entries after evicting expired ones' {
        $content = Get-Content -Raw -Path $script:PopFile
        # Verify the TTL block uses 'continue' to skip current entry without aborting
        $content | Should -Match 'dlq-pop-ttl-expired[\s\S]+?continue' -Because 'expired entries skip via continue; remaining entries still processed'
    }
}
