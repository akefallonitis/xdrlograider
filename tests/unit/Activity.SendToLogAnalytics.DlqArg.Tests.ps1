#Requires -Modules Pester
<#
.SYNOPSIS
    Layer A regression-locker — activity MUST pass -DlqStorageAccount to Send-ToLogAnalytics.

.DESCRIPTION
    Audit-Agent-B finding B-1 (2026-05-06): Xdr-PollStream calls Send-ToLogAnalytics
    WITHOUT -DlqStorageAccount. On terminal DCE failures (429-storm, 5xx exhaustion),
    Send-ToLogAnalytics throws instead of enqueuing the rows to the DLQ — silent
    data loss; DLQ replay never engages.

    The -DlqStorageAccount parameter is what enables Send-ToLogAnalytics's
    push-to-DLQ-on-terminal-failure pattern. Without it, terminal failures throw.

    Per Section R Layer A, plan file
    C:\Users\akefa\.claude\plans\immutable-splashing-waffle.md.
#>

BeforeAll {
    $script:RepoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:ActivityPath = Join-Path $script:RepoRoot 'src/functions/Xdr-PollStream/run.ps1'
    $script:ActivitySrc  = Get-Content -Raw $script:ActivityPath
}

Describe 'Activity.SendToLogAnalytics.DlqArg — DLQ-on-terminal-failure must engage' {

    It 'Send-ToLogAnalytics call site in Xdr-PollStream MUST include -DlqStorageAccount' {
        # Anchor on '\s+`' to pick the actual call site (skip comment occurrences)
        # then extract the multi-line continuation block.
        if ($script:ActivitySrc -match '(?ms)Send-ToLogAnalytics\s+`\r?\n(?:[^\r\n]*`\r?\n)*[^\r\n]*') {
            $sendBlock = $Matches[0]
        } else {
            # Single-line invocation
            $sendBlock = ($script:ActivitySrc | Select-String -Pattern 'Send-ToLogAnalytics\s+-' -List).Line
        }
        $sendBlock | Should -Not -BeNullOrEmpty -Because 'activity MUST call Send-ToLogAnalytics'
        $sendBlock | Should -Match '-DlqStorageAccount\s+\$config\.StorageAccountName' -Because (
            "Audit-Agent-B finding B-1: terminal DCE failures push to DLQ ONLY when -DlqStorageAccount is supplied. " +
            "Without it, Send-ToLogAnalytics throws and rows are lost. The activity MUST pass " +
            "-DlqStorageAccount `$config.StorageAccountName so the DLQ replay loop engages."
        )
    }
}

Describe 'Activity.SendToLogAnalytics.DlqArg — Send-ToLogAnalytics function signature has -DlqStorageAccount' {

    It 'Send-ToLogAnalytics module function declares -DlqStorageAccount parameter' {
        $sendPath = Join-Path $script:RepoRoot 'src/Modules/Xdr.Sentinel.Ingest/Public/Send-ToLogAnalytics.ps1'
        Test-Path $sendPath | Should -BeTrue
        $sendSrc = Get-Content -Raw $sendPath
        $sendSrc | Should -Match '\[string\]\s*\$DlqStorageAccount' -Because 'function MUST expose -DlqStorageAccount so callers can opt into DLQ-on-terminal-failure'
    }
}
