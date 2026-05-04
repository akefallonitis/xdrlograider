#Requires -Modules Pester
<#
.SYNOPSIS
    Phase H — Durable Functions consolidation structure gate per directive 16
    in .claude/plans/immutable-splashing-waffle.md.

.DESCRIPTION
    Verifies:
      1. Xdr-PollOrchestrator function exists with orchestrationTrigger binding
      2. Xdr-PollStream function exists with activityTrigger binding
      3. All 5 Defender-*-Refresh timers have BOTH timerTrigger AND durableClient bindings
      4. All 5 starters call Start-NewOrchestration (Durable path) with legacy fallback
      5. Orchestrator is replay-safe (no non-deterministic calls outside Invoke-DurableActivity)
      6. Activity does its own auth + ingest

    Per Microsoft Durable Functions PowerShell pattern documented at
    https://learn.microsoft.com/azure/azure-functions/durable/durable-functions-overview
#>

BeforeAll {
    $script:RepoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:FunctionsDir = Join-Path $script:RepoRoot 'src' 'functions'
}

Describe 'Phase H — Xdr-PollOrchestrator (orchestrationTrigger)' {
    BeforeAll {
        $script:OrchPath = Join-Path $script:FunctionsDir 'Xdr-PollOrchestrator'
    }

    It 'directory exists' {
        Test-Path -LiteralPath $script:OrchPath -PathType Container | Should -BeTrue
    }

    It 'function.json declares orchestrationTrigger binding' {
        $functionJson = Get-Content -Raw -Path (Join-Path $script:OrchPath 'function.json') | ConvertFrom-Json
        $functionJson.bindings.Count | Should -Be 1
        $functionJson.bindings[0].type | Should -Be 'orchestrationTrigger'
        $functionJson.bindings[0].direction | Should -Be 'in'
        $functionJson.bindings[0].name | Should -Be 'Context'
    }

    It 'run.ps1 receives $Context input + reads Portal/Tier' {
        $runPs1 = Get-Content -Raw -Path (Join-Path $script:OrchPath 'run.ps1')
        $runPs1 | Should -Match 'param\(\$Context\)'
        $runPs1 | Should -Match '\$Context\.Input'
        $runPs1 | Should -Match '\$portal\s*=\s*\$input\.Portal'
        $runPs1 | Should -Match '\$tier\s*=\s*\$input\.Tier'
    }

    It 'run.ps1 uses Invoke-DurableActivity to fan out per stream' {
        $runPs1 = Get-Content -Raw -Path (Join-Path $script:OrchPath 'run.ps1')
        $runPs1 | Should -Match 'Invoke-DurableActivity\s+-FunctionName\s+''Xdr-PollStream'''
        $runPs1 | Should -Match '-NoWait' -Because 'fan-out pattern requires -NoWait then Wait-DurableTask -Any:$false'
    }

    It 'run.ps1 uses Wait-DurableTask -Any:$false for fan-in' {
        $runPs1 = Get-Content -Raw -Path (Join-Path $script:OrchPath 'run.ps1')
        $runPs1 | Should -Match 'Wait-DurableTask' -Because 'orchestrator must wait for all activities before aggregating'
    }
}

Describe 'Phase H — Xdr-PollStream (activityTrigger)' {
    BeforeAll {
        $script:ActivityPath = Join-Path $script:FunctionsDir 'Xdr-PollStream'
    }

    It 'directory exists' {
        Test-Path -LiteralPath $script:ActivityPath -PathType Container | Should -BeTrue
    }

    It 'function.json declares activityTrigger binding' {
        $functionJson = Get-Content -Raw -Path (Join-Path $script:ActivityPath 'function.json') | ConvertFrom-Json
        $functionJson.bindings.Count | Should -Be 1
        $functionJson.bindings[0].type | Should -Be 'activityTrigger'
        $functionJson.bindings[0].direction | Should -Be 'in'
        $functionJson.bindings[0].name | Should -Be 'Input'
    }

    It 'run.ps1 receives $Input + does auth + Invoke-MDEEndpoint + ingest' {
        $runPs1 = Get-Content -Raw -Path (Join-Path $script:ActivityPath 'run.ps1')
        $runPs1 | Should -Match 'param\(\$Input\)'
        $runPs1 | Should -Match 'Get-XdrAuthFromKeyVault'
        $runPs1 | Should -Match 'Connect-DefenderPortal'
        $runPs1 | Should -Match 'Invoke-MDEEndpoint'
    }

    It 'run.ps1 returns metrics object with Success/RowsIngested/LatencyMs/Error' {
        $runPs1 = Get-Content -Raw -Path (Join-Path $script:ActivityPath 'run.ps1')
        $runPs1 | Should -Match 'Success\s+='
        $runPs1 | Should -Match 'RowsIngested\s+='
        $runPs1 | Should -Match 'LatencyMs\s+='
        $runPs1 | Should -Match 'Error\s+='
    }

    It 'run.ps1 has try/catch + emits AppInsights exception on failure' {
        $runPs1 = Get-Content -Raw -Path (Join-Path $script:ActivityPath 'run.ps1')
        $runPs1 | Should -Match 'try\s*\{'
        $runPs1 | Should -Match '\}\s*catch\s*\{'
        $runPs1 | Should -Match 'Send-XdrAppInsightsException'
    }
}

Describe 'Phase H — 5 Defender-*-Refresh timers refactored to Durable starters' {
    BeforeAll {
        $script:Timers = @(
            'Defender-ActionCenter-Refresh',
            'Defender-XspmGraph-Refresh',
            'Defender-Configuration-Refresh',
            'Defender-Inventory-Refresh',
            'Defender-Maintenance-Refresh'
        )
    }

    It '<Timer>: function.json has BOTH timerTrigger AND durableClient bindings' -ForEach @(
        @{ Timer = 'Defender-ActionCenter-Refresh' }
        @{ Timer = 'Defender-XspmGraph-Refresh' }
        @{ Timer = 'Defender-Configuration-Refresh' }
        @{ Timer = 'Defender-Inventory-Refresh' }
        @{ Timer = 'Defender-Maintenance-Refresh' }
    ) {
        $functionJsonPath = Join-Path $script:FunctionsDir $Timer 'function.json'
        $functionJson = Get-Content -Raw -Path $functionJsonPath | ConvertFrom-Json
        $bindingTypes = @($functionJson.bindings | ForEach-Object { $_.type })
        $bindingTypes | Should -Contain 'timerTrigger' -Because "$Timer must keep timer trigger"
        $bindingTypes | Should -Contain 'durableClient' -Because "$Timer must add durableClient binding for Phase H"
    }

    It '<Timer>: run.ps1 calls Start-NewOrchestration with Xdr-PollOrchestrator (Durable path)' -ForEach @(
        @{ Timer = 'Defender-ActionCenter-Refresh' }
        @{ Timer = 'Defender-XspmGraph-Refresh' }
        @{ Timer = 'Defender-Configuration-Refresh' }
        @{ Timer = 'Defender-Inventory-Refresh' }
        @{ Timer = 'Defender-Maintenance-Refresh' }
    ) {
        $runPs1 = Get-Content -Raw -Path (Join-Path $script:FunctionsDir $Timer 'run.ps1')
        $runPs1 | Should -Match 'Start-NewOrchestration'
        $runPs1 | Should -Match "FunctionName\s+'Xdr-PollOrchestrator'"
        $runPs1 | Should -Match '-DurableClient\s+\$Starter'
    }

    It '<Timer>: run.ps1 has legacy fallback to Invoke-TierPollWithHeartbeat' -ForEach @(
        @{ Timer = 'Defender-ActionCenter-Refresh' }
        @{ Timer = 'Defender-XspmGraph-Refresh' }
        @{ Timer = 'Defender-Configuration-Refresh' }
        @{ Timer = 'Defender-Inventory-Refresh' }
        @{ Timer = 'Defender-Maintenance-Refresh' }
    ) {
        $runPs1 = Get-Content -Raw -Path (Join-Path $script:FunctionsDir $Timer 'run.ps1')
        $runPs1 | Should -Match 'Invoke-TierPollWithHeartbeat' -Because 'graceful degradation if DurableClient unavailable'
    }
}

Describe 'Phase H — Connector-Heartbeat is NOT Durable (overhead-only timer)' {
    It 'Connector-Heartbeat function.json has only timerTrigger (no durableClient)' {
        $functionJson = Get-Content -Raw -Path (Join-Path $script:FunctionsDir 'Connector-Heartbeat' 'function.json') | ConvertFrom-Json
        $bindingTypes = @($functionJson.bindings | ForEach-Object { $_.type })
        $bindingTypes | Should -Contain 'timerTrigger'
        $bindingTypes | Should -Not -Contain 'durableClient' -Because 'heartbeat is overhead-only; no orchestration needed'
    }
}
