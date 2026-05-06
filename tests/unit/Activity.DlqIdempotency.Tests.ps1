#Requires -Modules Pester
<#
.SYNOPSIS
    Layer A regression-locker — DLQ replay rows MUST be sent in a SEPARATE batch
    from fresh rows; DLQ row deletion MUST happen AFTER replay confirms success.

.DESCRIPTION
    Audit-Agent-B finding B-3: Xdr-PollStream concatenates `$freshRows + $dlqRows`
    into ONE Send-ToLogAnalytics batch. If the Send succeeds but the orchestrator
    retries the activity (transient timeout / orchestrator replay), the DLQ rows
    ingest TWICE — data integrity violation.

    Correct pattern:
      1. Send fresh rows in batch A → success → checkpoint advances
      2. For each DLQ entry: send its rows in batch B → success → DELETE DLQ row
         If batch B fails, leave DLQ row for next replay cycle (AttemptCount++)
    This guarantees idempotent replay even with orchestrator retries.

    Per Section R Layer A, plan file
    C:\Users\akefa\.claude\plans\immutable-splashing-waffle.md.
#>

BeforeAll {
    $script:RepoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:ActivityPath = Join-Path $script:RepoRoot 'src/functions/Xdr-PollStream/run.ps1'
    $script:ActivitySrc  = Get-Content -Raw $script:ActivityPath
}

Describe 'Activity.DlqIdempotency — DLQ rows must be batch-isolated from fresh rows' {

    It 'activity does NOT concatenate $freshRows + $dlqRows into a single Send-ToLogAnalytics batch' {
        # Detect the anti-pattern: any line that does `@($freshRows) + @($dlqRows)` or similar.
        $antiPattern = '@?\(?\$\w*[fF]reshRows\)?\s*\+\s*@?\(?\$\w*[dD]lqRows\)?'
        $script:ActivitySrc | Should -Not -Match $antiPattern -Because (
            "Audit-Agent-B finding B-3: combining fresh + DLQ rows into one batch breaks " +
            "idempotency on orchestrator replay (rows ingest twice). Send each in a separate batch."
        )
    }

    It 'activity replays each DLQ entry separately (foreach loop over dlq entries with per-entry Send-ToLogAnalytics)' {
        # Look for the pattern: foreach over $dlqEntries OR $dlqRows, with per-iteration ingest.
        # This is harder to detect by regex alone — we settle for the negative assertion above
        # plus a positive: there MUST be a foreach over $dlq* with a Send-ToLogAnalytics inside.
        $hasPerEntryReplay = $script:ActivitySrc -match '(?ms)foreach\s*\(\s*\$\w+\s+in\s+\$dlq\w+\s*\).*?Send-ToLogAnalytics'
        $hasPerEntryReplay | Should -BeTrue -Because (
            "DLQ replay must iterate per-entry (or per-batch) with isolated Send-ToLogAnalytics. " +
            "This enables post-success deletion: only delete the DLQ row AFTER its replay batch " +
            "confirms success. If the activity is killed mid-replay, surviving DLQ rows are retried " +
            "next cycle (idempotent)."
        )
    }
}
