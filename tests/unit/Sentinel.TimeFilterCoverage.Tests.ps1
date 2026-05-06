#Requires -Modules Pester
<#
.SYNOPSIS
    Layer A regression-locker — every workspace-table query in sentinel/
    analytic-rules + hunting-queries yaml MUST be time-bounded.

.DESCRIPTION
    Unbounded queries scan the entire workspace table on every Sentinel rule
    evaluation OR every hunting-query operator click — expensive, slow, and
    may breach Sentinel's per-rule evaluation budget on large workspaces.

    LIVE FORENSIC 2026-05-06: 2 hunting queries shipped with unbounded inner
    joins / direct table queries (RbacEscalationEvents.yaml +
    CustomDetectionContentAudit.yaml). Reviews missed it because the queries
    "looked correct" syntactically — but production workspaces with 30d+ of
    rows would scan O(N) per click.

    This test runs tools/Audit-TimeFilterCoverage.ps1 — exit 0 = clean,
    non-zero = unbounded references found (test fails with the listing).
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:AuditScript = Join-Path $script:RepoRoot 'tools/Audit-TimeFilterCoverage.ps1'
}

Describe 'Sentinel.TimeFilterCoverage — every workspace-table query is time-bounded' {

    It 'tools/Audit-TimeFilterCoverage.ps1 exists' {
        Test-Path $script:AuditScript | Should -BeTrue
    }

    It 'every yaml workspace-table reference passes the time-bound + parser-wrapper check' {
        $output = & pwsh -NoProfile -File $script:AuditScript 2>&1
        $exit   = $LASTEXITCODE
        $exit | Should -Be 0 -Because (
            "Audit-TimeFilterCoverage flagged unbounded queries — operator-side queries that scan the entire workspace are expensive + may breach Sentinel rule budgets. Output:`n" + ($output -join "`n")
        )
    }
}
