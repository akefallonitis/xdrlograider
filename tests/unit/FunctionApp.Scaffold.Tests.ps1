#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Phase A1 4-Durable Functions topology invariants (Decision 1 plan §2).
# Replaces the earlier 19-per-sub-area-timer expectations from a deprecated topology.

Describe 'Function App scaffolding — 4 Durable Functions invariants (Decision 1)' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $script:FnRoot   = Join-Path $script:RepoRoot 'src' 'functions'
        $script:Expected = @{
            'Xdr-Refresh'          = @{ Trigger = 'timerTrigger';         Schedule = '0 * * * * *'  }
            'Xdr-PollOrchestrator' = @{ Trigger = 'orchestrationTrigger' }
            'Xdr-PollStream'       = @{ Trigger = 'activityTrigger'; BindingName = 'ActivityInput' }
            'Connector-Heartbeat'  = @{ Trigger = 'timerTrigger';         Schedule = '0 */5 * * * *' }
        }
    }

    It 'has exactly 4 function dirs (Xdr-Refresh + Xdr-PollOrchestrator + Xdr-PollStream + Connector-Heartbeat)' {
        $dirs = @(Get-ChildItem $script:FnRoot -Directory)
        $dirs.Count | Should -Be 4
        foreach ($expected in $script:Expected.Keys) {
            $dirs.Name | Should -Contain $expected
        }
    }

    It 'every function dir has function.json + run.ps1' {
        $dirs = Get-ChildItem $script:FnRoot -Directory
        foreach ($d in $dirs) {
            Test-Path (Join-Path $d.FullName 'function.json') | Should -BeTrue -Because $d.Name
            Test-Path (Join-Path $d.FullName 'run.ps1')       | Should -BeTrue -Because $d.Name
        }
    }

    It 'Xdr-Refresh: timerTrigger 1-min + durableClient Starter binding' {
        $j = Get-Content -Raw (Join-Path $script:FnRoot 'Xdr-Refresh' 'function.json') | ConvertFrom-Json
        @($j.bindings | Where-Object { $_.type -eq 'timerTrigger' }).Count   | Should -Be 1
        @($j.bindings | Where-Object { $_.type -eq 'durableClient' }).Count  | Should -Be 1
        ($j.bindings | Where-Object { $_.type -eq 'timerTrigger' }).schedule | Should -Be '0 * * * * *'
    }

    It 'Xdr-PollOrchestrator: orchestrationTrigger Context binding' {
        $j = Get-Content -Raw (Join-Path $script:FnRoot 'Xdr-PollOrchestrator' 'function.json') | ConvertFrom-Json
        @($j.bindings | Where-Object { $_.type -eq 'orchestrationTrigger' }).Count | Should -Be 1
    }

    It 'Xdr-PollStream: activityTrigger with binding name "ActivityInput" (avoid $Input shadow)' {
        $j = Get-Content -Raw (Join-Path $script:FnRoot 'Xdr-PollStream' 'function.json') | ConvertFrom-Json
        $a = $j.bindings | Where-Object { $_.type -eq 'activityTrigger' }
        $a | Should -Not -BeNullOrEmpty
        $a.name | Should -Be 'ActivityInput' -Because 'binding name "Input" would shadow PowerShell `$Input automatic var; pilot live-forensic 2026-05-06 rename'
    }

    It 'Connector-Heartbeat: timerTrigger on 5-min cron + INDEPENDENT (not Durable)' {
        $j = Get-Content -Raw (Join-Path $script:FnRoot 'Connector-Heartbeat' 'function.json') | ConvertFrom-Json
        $t = $j.bindings | Where-Object { $_.type -eq 'timerTrigger' }
        $t | Should -Not -BeNullOrEmpty
        $t.schedule | Should -Be '0 */5 * * * *'
        # Heartbeat MUST NOT be Durable — its isolation is its purpose (Decision 25)
        @($j.bindings | Where-Object { $_.type -in 'orchestrationTrigger','activityTrigger','durableClient' }).Count | Should -Be 0
    }

    It 'Xdr-Refresh run.ps1 dispatches via Start-NewOrchestration + reads __schedule__ rows + applies Rule 15 stagger' {
        $content = Get-Content -Raw (Join-Path $script:FnRoot 'Xdr-Refresh' 'run.ps1')
        $content | Should -Match 'Start-NewOrchestration'
        $content | Should -Match "RowKey eq '__schedule__'"
        $content | Should -Match 'Get-XdrStaggerSeconds' -Because 'Rule 15 stagger seed (Phase A0.2)'
    }

    It 'Xdr-PollOrchestrator: explicit [string] casts on Context.Input + EntryKey fan-out + circuit-breaker pre-flight' {
        $content = Get-Content -Raw (Join-Path $script:FnRoot 'Xdr-PollOrchestrator' 'run.ps1')
        $content | Should -Match '\[string\]\$orchInput\.Portal' -Because 'JValue→String cast (replay-determinism)'
        $content | Should -Match '\[string\]\$orchInput\.Tier'
        $content | Should -Match 'Invoke-DurableActivity'
        $content | Should -Match 'EntryKey'
        $content | Should -Match 'circuit' -Because 'pre-flight circuit-breaker check (Phase A2)'
    }

    It 'Xdr-PollStream: reads ActivityInput.EntryKey + dispatches Invoke-MDEEndpoint -EntryKey + writes Set-XdrTierStateRow ByProperties' {
        $content = Get-Content -Raw (Join-Path $script:FnRoot 'Xdr-PollStream' 'run.ps1')
        $content | Should -Match '\[string\]\$ActivityInput\.EntryKey' -Because 'EntryKey routing (Phase A1)'
        $content | Should -Match '\$invokeArgs.*EntryKey' -Because 'Invoke-MDEEndpoint dispatched by EntryKey'
        # Use multiline-friendly match: cmdlet and -PartitionKey may sit on separate lines.
        ($content -match '(?s)Set-XdrTierStateRow[^{}]*?-PartitionKey') | Should -BeTrue -Because 'ByProperties form (Phase A1)'
        $content | Should -Match 'Get-CheckpointState' -Because 'multi-cycle pagination resume (Phase A0.3)'
    }

    It 'Connector-Heartbeat run.ps1 calls Get-XdrTierStateAggregate + Write-Heartbeat + emits 3 customMetrics + lean Notes' {
        $content = Get-Content -Raw (Join-Path $script:FnRoot 'Connector-Heartbeat' 'run.ps1')
        $content | Should -Match 'Get-XdrTierStateAggregate'
        $content | Should -Match 'Write-Heartbeat'
        $content | Should -Match "xdr\.heartbeat\.cardState"     -Because 'H12 — required customMetric'
        $content | Should -Match "xdr\.dlq\.pending_count"        -Because 'H12 — required customMetric'
        $content | Should -Match "xdr\.subarea\.circuit_state"    -Because 'H12 — required customMetric'
        $content | Should -Match '\$leanNotes'                    -Because 'H14 — lean Notes JSON (Decision 15)'
        $content | Should -Match 'ConnectorVersion'               -Because 'H13 — operator-facing build pin'
        $content | Should -Match 'ConnectorBuildId'               -Because 'H13'
    }
}
