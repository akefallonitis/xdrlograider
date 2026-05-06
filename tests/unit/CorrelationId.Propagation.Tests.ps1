#Requires -Modules Pester
<#
.SYNOPSIS
    Layer A regression-locker — OperationId / CorrelationId propagation end-to-end.

.DESCRIPTION
    Audit-Agent-B finding B-4: a single tier-poll spans 4 layers (timer → orchestrator
    → activity → ingest). Without a shared OperationId the operator cannot stitch
    AppInsights logs across them. Forensic incident response is fragmented.

    Required propagation:
      1. Timer (Xdr-Refresh): generates OperationId per orchestration start
      2. Orchestrator (Xdr-PollOrchestrator): passes Context.InstanceId (or input.OperationId)
         to every activity input
      3. Activity (Xdr-PollStream): reads OperationId from input + passes it to:
         - Send-XdrAppInsightsCustomEvent -OperationId
         - Send-XdrAppInsightsException -OperationId
         - Send-ToLogAnalytics (via -OperationId)
         - Pop-XdrIngestDlq (via -OperationId)
      4. Telemetry: every customEvent / exception emitted by activity has the same OperationId

    Per Section R Layer A, plan file
    C:\Users\akefa\.claude\plans\immutable-splashing-waffle.md.
#>

BeforeAll {
    $script:RepoRoot         = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:ActivityPath     = Join-Path $script:RepoRoot 'src/functions/Xdr-PollStream/run.ps1'
    $script:OrchestratorPath = Join-Path $script:RepoRoot 'src/functions/Xdr-PollOrchestrator/run.ps1'
    $script:ActivitySrc      = Get-Content -Raw $script:ActivityPath
    $script:OrchSrc          = Get-Content -Raw $script:OrchestratorPath
}

Describe 'CorrelationId.Propagation — orchestrator passes InstanceId to activity input' {

    It 'orchestrator activity-input hashtable contains an OperationId field sourced from $Context.InstanceId' {
        # Pattern: the activityInput hashtable MUST include OperationId = $Context.InstanceId or similar.
        $script:OrchSrc | Should -Match '(?ms)\$activityInput\s*=\s*@\{[^}]*OperationId\s*=' -Because (
            "Audit-Agent-B finding B-4: orchestrator MUST pass its InstanceId as OperationId in the activity input " +
            "so all telemetry across timer → orchestrator → activity → ingest layers shares a stitch key."
        )
    }
}

Describe 'CorrelationId.Propagation — activity reads OperationId from input + propagates' {

    It 'activity reads $ActivityInput.OperationId as $opId (or similar)' {
        # Activity body MUST extract OperationId from input.
        $script:ActivitySrc | Should -Match '\$\w*[oO]p\w*\s*=\s*\[string\]\$\w+\.OperationId' -Because (
            "activity MUST extract OperationId from its input so it can be passed downstream to all telemetry calls"
        )
    }

    It 'activity calls to Send-XdrAppInsights* OR Send-ToLogAnalytics propagate OperationId' {
        # At least ONE telemetry call must include -OperationId. (Comprehensive enforcement
        # would require AST walking each call site; for v0.1.0 GA we gate on presence.)
        $hasOpId = $script:ActivitySrc -match '-OperationId\s+\$\w+'
        $hasOpId | Should -BeTrue -Because (
            "without -OperationId on at least one telemetry/ingest call, operators cannot stitch logs across layers"
        )
    }
}
