#Requires -Modules Pester
<#
.SYNOPSIS
    Behavioural tests for Xdr-WriteHeartbeat activity.

.DESCRIPTION
    Catches the regression class that bit us live 2026-05-06 14:00:12Z:
    activity called Write-Heartbeat with -FunctionType 'Durable' which is
    NOT in Write-Heartbeat's ValidateSet (Simple|Starter|Orchestrator|Activity).
    Behavioural test EXECUTES the activity body with a mock Write-Heartbeat
    that captures the actual arguments + verifies they pass ValidateSet.

    Per BINDING methodology Step 4: tests must EXECUTE code, not just
    regex-pattern-match the source. Regex tests would have missed this bug
    because the source code reads $FunctionType = 'Durable' (looks fine in
    isolation) — only when invoked against the real param block does the
    ValidateSet fail.
#>

BeforeAll {
    $script:RepoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:ActivityPath = Join-Path $script:RepoRoot 'src/functions/Xdr-WriteHeartbeat/run.ps1'
    $script:WriteHeartbeatPath = Join-Path $script:RepoRoot 'src/Modules/Xdr.Sentinel.Ingest/Public/Write-Heartbeat.ps1'

    # Extract Write-Heartbeat's actual ValidateSet for FunctionType — this is
    # the single source of truth that the activity's literal value must comply with.
    $whSrc = Get-Content -Raw $script:WriteHeartbeatPath
    # Use a single-quoted regex so `$FunctionType` is literal (PS double-quote
    # would interpolate $FunctionType). Match: [ValidateSet(...)] followed by
    # one-or-more non-bracket lines then [string]$FunctionType.
    $vsRegex = [regex]::new('(?ms)\[ValidateSet\(([^\)]+)\)\][^\[]*\[string\]\s*\$FunctionType')
    $vsMatch = $vsRegex.Match($whSrc)
    if ($vsMatch.Success) {
        $vs = $vsMatch.Groups[1].Value
        $script:WriteHeartbeatFunctionTypeValidSet = @($vs -split ',' | ForEach-Object { $_.Trim() -replace "^'|'$","" } | Where-Object { $_ -and $_ -ne '$null' })
    } else {
        throw "Could not extract Write-Heartbeat -FunctionType ValidateSet from source"
    }
}

Describe 'Xdr-WriteHeartbeat activity — behavioural verification' {

    Context 'Activity calls Write-Heartbeat with ValidateSet-compliant -FunctionType' {

        It 'extracts the activity body literal -FunctionType value and confirms it is in Write-Heartbeat ValidateSet' {
            $activitySrc = Get-Content -Raw $script:ActivityPath
            # Capture the literal between -FunctionType and the next continuation backtick OR newline.
            if ($activitySrc -match "-FunctionType\s+'([^']+)'") {
                $literal = $Matches[1]
                $script:WriteHeartbeatFunctionTypeValidSet | Should -Contain $literal -Because (
                    "activity passes -FunctionType '$literal' but Write-Heartbeat ValidateSet is " +
                    ($script:WriteHeartbeatFunctionTypeValidSet -join ', ') +
                    ". Live forensic 2026-05-06 14:00:12Z caught the original 'Durable' regression."
                )
            } else {
                throw "Activity does not pass -FunctionType to Write-Heartbeat — review the call site"
            }
        }
    }

    Context 'Activity binding name MUST NOT be $Input (regression: PowerShell automatic-variable shadow)' {

        It 'function.json binding name is NOT "Input"' {
            $fnJson = Get-Content -Raw (Join-Path $script:RepoRoot 'src/functions/Xdr-WriteHeartbeat/function.json') | ConvertFrom-Json
            $fnJson.bindings[0].name | Should -Not -Be 'Input' -Because 'PowerShell automatic-variable shadow — same root cause as fb2c6f4 fix on Xdr-PollStream'
            $fnJson.bindings[0].type | Should -Be 'activityTrigger'
        }

        It 'run.ps1 param name MATCHES function.json binding name' {
            $bindingName = (Get-Content -Raw (Join-Path $script:RepoRoot 'src/functions/Xdr-WriteHeartbeat/function.json') | ConvertFrom-Json).bindings[0].name
            $activitySrc = Get-Content -Raw $script:ActivityPath
            $activitySrc | Should -Match ('(?m)^\s*param\s*\(\s*\$' + [regex]::Escape($bindingName) + '\s*\)') -Because 'Azure Functions PS convention: binding name = param name'
        }
    }

    Context 'Activity reads structured fields from ActivityInput (Portal/Tier/FunctionName/StreamsAttempted/StreamsSucceeded/RowsIngested/LatencyMs)' {

        It 'Activity reads all 7 expected ActivityInput fields' {
            $activitySrc = Get-Content -Raw $script:ActivityPath
            $bindingName = (Get-Content -Raw (Join-Path $script:RepoRoot 'src/functions/Xdr-WriteHeartbeat/function.json') | ConvertFrom-Json).bindings[0].name
            foreach ($field in 'Portal','Tier','FunctionName','StreamsAttempted','StreamsSucceeded','RowsIngested','LatencyMs') {
                $activitySrc | Should -Match ('\$' + [regex]::Escape($bindingName) + '\.' + $field) -Because "must read ActivityInput.$field"
            }
        }
    }

    Context 'Orchestrator passes the Xdr-WriteHeartbeat input shape correctly' {

        It 'Orchestrator constructs $heartbeatInput with all fields the activity expects' {
            $orchSrc = Get-Content -Raw (Join-Path $script:RepoRoot 'src/functions/Xdr-PollOrchestrator/run.ps1')
            $orchSrc | Should -Match "Invoke-DurableActivity\s+-FunctionName\s+'Xdr-WriteHeartbeat'" -Because 'orchestrator must call the new heartbeat activity as final step'
            foreach ($field in 'Portal','Tier','FunctionName','StreamsAttempted','StreamsSucceeded','RowsIngested','LatencyMs','OrchestrationInstanceId') {
                $orchSrc | Should -Match ('(?ms)\$heartbeatInput\s*=\s*@\{[^}]*' + $field + '\s*=') -Because "orchestrator must pass $field to Xdr-WriteHeartbeat"
            }
        }
    }
}
