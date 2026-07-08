#Requires -Version 7.4
# P11.1 · -SkipArm = code-only sync. The cutover on an ALREADY-deployed estate must NOT re-run the full
# mainTemplate (its role-assignment nested deployments fail RoleAssignmentExists against pre-existing grants —
# live-hit 2026-06-12, §11a). -SkipArm gates Step 1 (the ARM deploy) so the sync is a pure repoint+restart;
# the full template stays the PUBLIC fresh-install path (idempotent there — no pre-existing assignments).
# Behavioural pin via child process (the tool is a linear orchestration script): -SkipArm + -WhatIfMode is
# az-free (Step 1 skipped, WhatIf exits before the Azure steps), so it runs offline in CI Tier-1.

BeforeAll {
    $script:tool = (Resolve-Path "$PSScriptRoot\..\..\..\tools\Sync-IncrementalCategory.ps1").Path
}

Describe 'P11.1 · Sync-IncrementalCategory -SkipArm (code-only sync)' {
    It '-SkipArm + -WhatIfMode skips the ARM step, stays az-free, and exits 0' {
        $out = & pwsh -NoProfile -NonInteractive -File $script:tool `
            -Category Operations -ResourceGroup rg-test -ReleaseTag v0.0.0-test -SkipArm -WhatIfMode *>&1
        $LASTEXITCODE | Should -Be 0
        ($out -join "`n") | Should -Match 'Step 1.*(SKIP|skip)'
        ($out -join "`n") | Should -Match 'code-only'
    }
    It 'the script declares a -SkipArm switch and gates the ARM sync on it' {
        $text = Get-Content $script:tool -Raw
        $text | Should -Match '\[switch\]\s*\$SkipArm'
        # Step 1 (Sync-ExistingDeployment delegation) must be inside a -not $SkipArm guard
        $text | Should -Match 'if\s*\(\s*-not\s*\$SkipArm'
    }
}
