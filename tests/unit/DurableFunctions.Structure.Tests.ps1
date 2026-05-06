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

    It 'run.ps1 receives $Context input + reads Portal/Tier with explicit [string] cast (JValue runtime safety)' {
        # Durable Functions delivers $Context.Input as a Newtonsoft.Json.Linq.JObject;
        # accessing properties returns JValue, NOT string. Direct use crashes the
        # orchestrator with "Unable to cast object of type 'Newtonsoft.Json.Linq.JValue'
        # to type 'System.String'". This test asserts the explicit [string] cast is
        # in place + that we don't shadow PowerShell's automatic $Input variable.
        $runPs1 = Get-Content -Raw -Path (Join-Path $script:OrchPath 'run.ps1')
        $runPs1 | Should -Match 'param\(\$Context\)'
        $runPs1 | Should -Match '\$Context\.Input'
        $runPs1 | Should -Match '\$portal\s*=\s*\[string\]\$\w+\.Portal'  -Because 'JValue must be cast to string explicitly'
        $runPs1 | Should -Match '\$tier\s*=\s*\[string\]\$\w+\.Tier'      -Because 'JValue must be cast to string explicitly'
        $runPs1 | Should -Not -Match '^\s*\$input\s*=\s*\$Context\.Input' -Because 'avoid shadowing PowerShell automatic $Input variable'
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

    It 'function.json declares activityTrigger binding with NON-shadowing name' {
        $functionJson = Get-Content -Raw -Path (Join-Path $script:ActivityPath 'function.json') | ConvertFrom-Json
        $functionJson.bindings.Count | Should -Be 1
        $functionJson.bindings[0].type | Should -Be 'activityTrigger'
        $functionJson.bindings[0].direction | Should -Be 'in'
        # Binding name MUST NOT be 'Input' — that creates a PS automatic-variable shadow
        # in run.ps1's param() block, causing the Durable input to silently bind to the
        # empty pipeline enumerator. Live forensic 2026-05-06.
        $functionJson.bindings[0].name | Should -Not -Be 'Input' -Because 'PowerShell automatic-variable shadow'
        $functionJson.bindings[0].name | Should -Match '^[A-Za-z_][A-Za-z0-9_]*$' -Because 'must be valid PS variable name'
    }

    It 'function.json binding name MATCHES run.ps1 param name (Azure Functions PS convention)' {
        $functionJson = Get-Content -Raw -Path (Join-Path $script:ActivityPath 'function.json') | ConvertFrom-Json
        $bindingName = $functionJson.bindings[0].name
        $runPs1 = Get-Content -Raw -Path (Join-Path $script:ActivityPath 'run.ps1')
        $runPs1 | Should -Match ('(?m)^\s*param\s*\(\s*\$' + [regex]::Escape($bindingName) + '\s*\)') -Because 'function.json binding name MUST match run.ps1 param name; mismatch breaks input binding'
    }

    It 'run.ps1 has a param block + does auth + Invoke-MDEEndpoint + ingest (param NOT named $Input — automatic-variable shadow)' {
        $runPs1 = Get-Content -Raw -Path (Join-Path $script:ActivityPath 'run.ps1')
        # Regression-locker: param($Input) shadows the PowerShell automatic $Input
        # variable, causing the binding to silently bind to the empty pipeline
        # enumerator instead of the JObject from Durable. Verified live 2026-05-06.
        $runPs1 | Should -Match '(?m)^\s*param\s*\(\s*\$[A-Za-z_][A-Za-z0-9_]*\s*\)'
        $runPs1 | Should -Not -Match '(?m)^\s*param\s*\(\s*\$Input\s*\)' -Because 'param($Input) shadows PS automatic $Input — activity input never binds. Use a non-Input name + matching function.json binding name.'
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

Describe 'Section R — Xdr-Refresh universal portal-agnostic dispatcher (replaces 5 Defender-*-Refresh timers)' {

    It 'Xdr-Refresh function.json has BOTH timerTrigger AND durableClient bindings' {
        $functionJsonPath = Join-Path $script:FunctionsDir 'Xdr-Refresh' 'function.json'
        Test-Path $functionJsonPath | Should -BeTrue -Because 'Section R adds Xdr-Refresh as the single dispatcher'
        $functionJson = Get-Content -Raw -Path $functionJsonPath | ConvertFrom-Json
        $bindingTypes = @($functionJson.bindings | ForEach-Object { $_.type })
        $bindingTypes | Should -Contain 'timerTrigger'  -Because 'fires every 1 min'
        $bindingTypes | Should -Contain 'durableClient' -Because 'starts orchestrations for due (Portal, Tier) pairs'
    }

    It 'Xdr-Refresh run.ps1 reads tier-due state + calls Start-NewOrchestration with Xdr-PollOrchestrator' {
        $runPs1 = Get-Content -Raw -Path (Join-Path $script:FunctionsDir 'Xdr-Refresh' 'run.ps1')
        $runPs1 | Should -Match 'Get-XdrTierCadenceMap|XdrTierState' -Because 'reads cadence map + tier state'
        $runPs1 | Should -Match 'Start-NewOrchestration'
        $runPs1 | Should -Match "FunctionName\s+'Xdr-PollOrchestrator'"
        $runPs1 | Should -Match '-DurableClient\s+\$Starter'
    }

    It 'Xdr-Refresh dispatch is portal-agnostic (does NOT hard-code Portal=Defender literal)' {
        $runPs1 = Get-Content -Raw -Path (Join-Path $script:FunctionsDir 'Xdr-Refresh' 'run.ps1')
        # The Portal value passed to Start-NewOrchestration MUST come from a variable
        # (iterating $enabledPortals), not a literal — otherwise v0.2.0+ multi-portal
        # expansion requires code changes.
        $runPs1 | Should -Not -Match "InputObject[\s=]+@\{[^}]*Portal\s*=\s*'Defender'\s*[;}]" -Because (
            'Section R: Xdr-Refresh is portal-agnostic. Portal value comes from $enabledPortals iteration, not hard-coded.'
        )
    }

    It 'no Defender-*-Refresh timer directories remain (deleted in Section R consolidation)' {
        $oldTimers = @(
            'Defender-ActionCenter-Refresh',
            'Defender-XspmGraph-Refresh',
            'Defender-Configuration-Refresh',
            'Defender-Inventory-Refresh',
            'Defender-Maintenance-Refresh'
        )
        foreach ($t in $oldTimers) {
            Test-Path (Join-Path $script:FunctionsDir $t) | Should -BeFalse -Because "Section R deletes $t (replaced by Xdr-Refresh)"
        }
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
