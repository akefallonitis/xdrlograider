#Requires -Modules Pester
<#
.SYNOPSIS
    D'.7 v0.1.0 GA Phase 5.4 — Durable Functions fallback-path gate.

.DESCRIPTION
    Asserts every Defender-{Tier}-Refresh timer's run.ps1 has BOTH paths:

      1. Durable Functions starter (preferred): when $Starter binding is
         available, call Start-NewOrchestration -FunctionName Xdr-PollOrchestrator
         to fan out per-stream activities.

      2. Legacy fallback: when $Starter is null/unavailable, call
         Invoke-TierPollWithHeartbeat directly.

    The fallback path is critical for graceful degradation when:
      - Durable Functions extension unavailable (extension load failure on
        cold start)
      - Storage Account unreachable for Durable's task hub state (regional
        outage; DR scenarios)
      - Operator deploys a hotfix that disables Durable Functions

    Without this dual-path, the entire connector goes silent when Durable
    Functions has issues. With it, the heartbeat + per-stream poll continue
    via the legacy path while operators investigate.

    Phase 5.4 v0.1.0 GA: every poll-* timer has both branches; both branches
    correctly take their `param` from $Starter; both call the right helper.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:FunctionsDir = Join-Path $script:RepoRoot 'src/functions'

    # All 5 capability timers that use the Durable starter pattern.
    # (Connector-Heartbeat is a separate 5-minute heartbeat that doesn't fan out.)
    $script:PollTimers = @(
        'Defender-ActionCenter-Refresh',
        'Defender-XspmGraph-Refresh',
        'Defender-Configuration-Refresh',
        'Defender-Inventory-Refresh',
        'Defender-Maintenance-Refresh'
    )
}

Describe 'DurableFunctions.FallbackPath — every poll-* timer has Durable + legacy paths' {

    It 'enumerates exactly 5 capability poll-* timer functions (v0.1.0 GA Phase 2 architecture)' {
        @($script:PollTimers).Count | Should -Be 5 -Because '5 cadence-tier timers + 1 heartbeat = 6 total functions; this gate covers the 5 cadence tiers'
    }

    It 'every poll-* timer has function.json with timerTrigger + durableClient bindings' {
        foreach ($timer in $script:PollTimers) {
            $fnJson = Join-Path $script:FunctionsDir $timer 'function.json'
            Test-Path $fnJson | Should -BeTrue -Because "$timer must have a function.json"
            $j = Get-Content $fnJson -Raw | ConvertFrom-Json
            $bindings = @($j.bindings)
            $types = @($bindings | ForEach-Object { $_.type })
            $types | Should -Contain 'timerTrigger' -Because "$timer must have a timerTrigger binding"
            $types | Should -Contain 'durableClient' -Because "$timer must have a durableClient binding (D'.7 fallback contract requires the binding even if it can't load at runtime)"
        }
    }

    It 'every poll-* run.ps1 declares param($Timer, $Starter)' {
        foreach ($timer in $script:PollTimers) {
            $run = Join-Path $script:FunctionsDir $timer 'run.ps1'
            Test-Path $run | Should -BeTrue -Because "$timer must have a run.ps1"
            $src = Get-Content $run -Raw
            $src | Should -Match 'param\s*\(\s*\$Timer\s*,\s*\$Starter\s*\)' -Because "$timer run.ps1 must declare param(`$Timer, `$Starter)"
        }
    }

    It 'every poll-* run.ps1 has the Durable-starter path (Start-NewOrchestration)' {
        foreach ($timer in $script:PollTimers) {
            $run = Join-Path $script:FunctionsDir $timer 'run.ps1'
            $src = Get-Content $run -Raw
            $src | Should -Match 'Start-NewOrchestration' -Because "$timer run.ps1 must call Start-NewOrchestration to fan out per-stream activities (preferred path)"
            $src | Should -Match "FunctionName\s+'Xdr-PollOrchestrator'" -Because "$timer must orchestrate via Xdr-PollOrchestrator"
        }
    }

    It 'every poll-* run.ps1 has the legacy fallback (Invoke-TierPollWithHeartbeat)' {
        foreach ($timer in $script:PollTimers) {
            $run = Join-Path $script:FunctionsDir $timer 'run.ps1'
            $src = Get-Content $run -Raw
            $src | Should -Match 'Invoke-TierPollWithHeartbeat' -Because "$timer run.ps1 must have a fallback path that calls Invoke-TierPollWithHeartbeat when `$Starter is null"
        }
    }

    It 'every poll-* run.ps1 gates Durable vs legacy via if ($Starter)' {
        # Pattern: `if ($Starter) { ... Start-NewOrchestration ... } else { ... Invoke-TierPollWithHeartbeat ... }`
        foreach ($timer in $script:PollTimers) {
            $run = Join-Path $script:FunctionsDir $timer 'run.ps1'
            $src = Get-Content $run -Raw
            $src | Should -Match 'if\s*\(\s*\$Starter\s*\)' -Because "$timer run.ps1 must conditionally branch on `$Starter (Durable vs legacy)"
        }
    }

    It 'every poll-* timer maps to a unique Tier passed to both Durable + fallback' {
        # Each timer should pass its tier to both Start-NewOrchestration's
        # InputObject AND Invoke-TierPollWithHeartbeat's -Tier param.
        $tierMap = @{
            'Defender-ActionCenter-Refresh'  = 'ActionCenter'
            'Defender-XspmGraph-Refresh'     = 'XspmGraph'
            'Defender-Configuration-Refresh' = 'Configuration'
            'Defender-Inventory-Refresh'     = 'Inventory'
            'Defender-Maintenance-Refresh'   = 'Maintenance'
        }
        foreach ($timer in $script:PollTimers) {
            $run = Join-Path $script:FunctionsDir $timer 'run.ps1'
            $src = Get-Content $run -Raw
            $expectedTier = $tierMap[$timer]
            # Durable path InputObject must declare the right Tier
            $src | Should -Match "Tier\s*=\s*'$expectedTier'" -Because "$timer Durable InputObject must declare Tier='$expectedTier'"
            # Legacy fallback must pass -Tier '<expectedTier>'
            $src | Should -Match "-Tier\s+'$expectedTier'" -Because "$timer legacy fallback must pass -Tier '$expectedTier'"
        }
    }
}

Describe 'DurableFunctions.FallbackPath — Xdr-PollOrchestrator + Xdr-PollStream contract' {

    It 'Xdr-PollOrchestrator function exists with orchestrationTrigger binding' {
        $orchPath = Join-Path $script:FunctionsDir 'Xdr-PollOrchestrator/function.json'
        Test-Path $orchPath | Should -BeTrue
        $j = Get-Content $orchPath -Raw | ConvertFrom-Json
        $types = @($j.bindings | ForEach-Object { $_.type })
        $types | Should -Contain 'orchestrationTrigger' -Because 'Xdr-PollOrchestrator must use orchestrationTrigger (Durable Functions orchestrator pattern)'
    }

    It 'Xdr-PollStream activity exists with activityTrigger binding' {
        $actPath = Join-Path $script:FunctionsDir 'Xdr-PollStream/function.json'
        Test-Path $actPath | Should -BeTrue
        $j = Get-Content $actPath -Raw | ConvertFrom-Json
        $types = @($j.bindings | ForEach-Object { $_.type })
        $types | Should -Contain 'activityTrigger' -Because 'Xdr-PollStream must use activityTrigger (Durable Functions activity pattern)'
    }

    It 'Xdr-PollOrchestrator run.ps1 fans out via Invoke-DurableActivity per stream' {
        $run = Join-Path $script:FunctionsDir 'Xdr-PollOrchestrator/run.ps1'
        Test-Path $run | Should -BeTrue
        $src = Get-Content $run -Raw
        $src | Should -Match 'Invoke-DurableActivity' -Because 'orchestrator must fan out via Invoke-DurableActivity to Xdr-PollStream'
    }

    It 'Xdr-PollStream run.ps1 calls Invoke-MDEEndpoint per stream' {
        $run = Join-Path $script:FunctionsDir 'Xdr-PollStream/run.ps1'
        Test-Path $run | Should -BeTrue
        $src = Get-Content $run -Raw
        $src | Should -Match 'Invoke-MDEEndpoint' -Because 'activity must dispatch via Invoke-MDEEndpoint (manifest-driven dispatch)'
    }
}
