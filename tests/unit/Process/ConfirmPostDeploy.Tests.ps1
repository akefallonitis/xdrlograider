#Requires -Version 7.4
# FH-6 · Confirm-PostDeploy postdeploy ENFORCEMENT. The PURE planners (the verify-chain plan + the commit-status record)
# are dot-sourceable and offline-testable; the live driver is LOCAL-ONLY — it refuses CI (the chain runs the service-
# account content verify · creds never in CI · exit 2). These tests pin the planners + the CI-refusal security-lock
# contract. The LIVE chain run + the actual gh status POST are exercised at the EXIT GATE (pilot re-prove · not offline).

BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $script:tool = Join-Path $script:repo 'tools\Confirm-PostDeploy.ps1'
    . $script:tool   # dot-source · the live driver is guarded by ($MyInvocation.InvocationName -ne '.'), so only the pure functions load
}

Describe 'FH-6 · Confirm-PostDeploy · pure planners' {
    It 'Get-XdrConfirmChainPlan chains Run-PostDeployVerify then Test-GaReadiness (fail-fast order)' {
        $plan = Get-XdrConfirmChainPlan -ResourceGroup rg -WorkspaceId ws -WorkspaceResourceId /sub/x -Window Sustain
        @($plan).Count | Should -Be 2
        $plan[0].Name | Should -Be 'postdeploy-verify'
        $plan[0].File | Should -Be 'Run-PostDeployVerify.ps1'
        $plan[1].Name | Should -Be 'ga-readiness'
        $plan[1].File | Should -Be 'Test-GaReadiness.ps1'
    }
    It 'the chain forwards -AllOps to BOTH stages when requested' {
        $plan = Get-XdrConfirmChainPlan -ResourceGroup rg -WorkspaceId ws -WorkspaceResourceId /sub/x -AllOps $true
        ($plan[0].Args -contains '-AllOps') | Should -BeTrue
        ($plan[1].Args -contains '-AllOps') | Should -BeTrue
    }
    It 'the chain forwards the core workspace coordinates to the verify stage' {
        $plan = Get-XdrConfirmChainPlan -ResourceGroup myrg -WorkspaceId mycid -WorkspaceResourceId /subs/abc/ws -Window Hour
        $a = $plan[0].Args
        $a | Should -Contain 'myrg'
        $a | Should -Contain 'mycid'
        $a | Should -Contain '/subs/abc/ws'
        $a | Should -Contain 'Hour'
    }
    It 'Get-XdrPostDeployStatusRecord · success record carries context + state + a <=140-char ASCII description' {
        $r = Get-XdrPostDeployStatusRecord -Sha 'abc123' -State success -WorkspaceId '3f75ec26-aaaa-bbbb' -Window Sustain -Utc '2026-06-15T00:00:00Z'
        $r.sha     | Should -Be 'abc123'
        $r.context | Should -Be 'postdeploy/verified'
        $r.state   | Should -Be 'success'
        $r.description.Length | Should -BeLessOrEqual 140
        $r.description | Should -Match 'ws=3f75ec26'
        $r.description | Should -Match 'window=Sustain'
        [bool]($r.description -cmatch '^[\x20-\x7E]+$') | Should -BeTrue -Because 'the status description must be ASCII-safe over the gh api transport'
    }
    It 'the status context is overridable (release.yml + this test must agree on the required-status name)' {
        (Get-XdrPostDeployStatusRecord -Sha s -State success -WorkspaceId w -Context 'postdeploy/ci').context | Should -Be 'postdeploy/ci'
    }
}

Describe 'FH-6 · Confirm-PostDeploy · LOCAL-ONLY security lock' {
    It 'refuses to run under CI (exit 2 · the service account must never authenticate in CI)' {
        $out = pwsh -NoProfile -Command "`$env:GITHUB_ACTIONS='true'; & '$script:tool' -ResourceGroup rg -WorkspaceId ws -WorkspaceResourceId /sub/x; exit `$LASTEXITCODE" 2>&1
        $LASTEXITCODE | Should -Be 2 -Because 'the CI-refusal is the security lock (creds never in CI), mirroring Verify-XdrLiveContent'
        ($out -join "`n") | Should -Match 'LOCAL-ONLY'
    }
}
