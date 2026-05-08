#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
.SYNOPSIS
    B2 regression-locker (Plan R+++++++++.2): Invoke-DefenderPortalRequest MUST
    implement an auth circuit-breaker on 401-reauth-loop. After 2 reauth
    failures within 5 minutes for a given cacheKey, the circuit OPENS:
    cache is evicted, AuthChain.FailureCircuit event fires, fail-fast throw.

.DESCRIPTION
    Tests the AST shape of Invoke-DefenderPortalRequest.ps1 — verifies the
    circuit-breaker block exists with a 5min sliding window, fires AppInsights
    CustomEvent 'AuthChain.FailureCircuit' on circuit open, and increments
    window on reauth failure / clears on success.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:ModulePath = Join-Path $script:RepoRoot 'src/Modules/Xdr.Defender.Auth/Public/Invoke-DefenderPortalRequest.ps1'
    $script:ModuleContent = Get-Content $script:ModulePath -Raw
}

Describe 'Invoke-DefenderPortalRequest auth circuit-breaker (B2 regression-locker)' {

    It 'source file exists' {
        Test-Path $script:ModulePath | Should -BeTrue
    }

    It 'circuit-breaker block exists with Plan R+++++++++.2 reference' {
        $script:ModuleContent | Should -Match '(?ms)B2 \(Plan R\+\+\+\+\+\+\+\+\+\.2\):.*?circuit-breaker' -Because 'B2 fix must be documented inline'
    }

    It 'uses module-scope $script:AuthFailureWindow hashtable' {
        $script:ModuleContent | Should -Match '\$script:AuthFailureWindow' -Because 'sliding-window state must be module-scope to persist across invocations'
    }

    It 'prunes entries older than 5 minutes' {
        $script:ModuleContent | Should -Match 'AddMinutes\(-5\)' -Because 'sliding window is 5min wide'
    }

    It 'circuit OPENS at >= 2 failures' {
        $script:ModuleContent | Should -Match '\$window\.Count\s*-ge\s*2' -Because 'threshold is 2 failures within 5min'
    }

    It 'evicts cache on circuit open' {
        $script:ModuleContent | Should -Match '(?ms)circuit OPEN.*?\$script:SessionCache\.Remove\(\$cacheKey\)' -Because 'cache must be evicted to force fresh auth on next call'
    }

    It 'fires AuthChain.FailureCircuit AppInsights event' {
        $script:ModuleContent | Should -Match "Send-XdrAppInsightsCustomEvent.*EventName\s+'AuthChain\.FailureCircuit'" -Because 'operator KQL alerts must trigger on circuit open'
    }

    It 'throws fail-fast with operator-actionable message' {
        $script:ModuleContent | Should -Match 'AuthChain\.FailureCircuit OPEN' -Because 'throw message must reference the circuit name for KQL/log search'
        $script:ModuleContent | Should -Match 'Initialize-XdrLogRaiderAuth\.ps1' -Because 'message must point operator at remediation script'
    }

    It 'increments failure window on reauth failure' {
        $script:ModuleContent | Should -Match '\$script:AuthFailureWindow\[\$cacheKey\]\.Add\(\$now\)' -Because 'failure increment must be in the post-reauth catch block'
    }

    It 'clears failure window on reauth success' {
        $script:ModuleContent | Should -Match '\$script:AuthFailureWindow\[\$cacheKey\]\.Clear\(\)' -Because 'success must zero the failure counter'
    }
}
