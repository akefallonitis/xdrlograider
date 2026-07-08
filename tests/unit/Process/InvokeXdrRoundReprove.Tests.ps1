#Requires -Version 7.4
# P1 · the per-round RE-PROVE orchestrator's PURE phase plan (no Azure). Pins the operator-LOCKED 2-leg sequence
# (reset[rewind] → cadence-reset[force] → cold-wait → postdeploy-Cold → force[leg-2] → cold-wait → postdeploy-Sustain → no-regression
# roll-up) and that the live driver COMPOSES existing tools only (B4: no new gate/assertion). The cold-emit re-prove
# is data-driven over the deployed categories.

BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    . (Join-Path $script:repo 'tools\Invoke-XdrRoundReprove.ps1')   # InvocationName '.' skips the live driver
}

Describe 'P1 · Get-XdrRoundReprovePlan (pure · the locked 2-leg re-prove)' {
    It 'is the fixed 8-phase 2-leg sequence in order' {
        $p = Get-XdrRoundReprovePlan -Category @('ExposureManagement','Operations')
        @($p).Count | Should -Be 8
        ($p.Name -join '>') | Should -Be 'reset-all>cadence-reset>cold-emit-wait-1>verify-cold>force-leg2>cold-emit-wait-2>verify-sustain>no-regression'
    }
    It 'leg ordering: reset(rewind) → verify-cold → force(leg-2) → verify-sustain; roll-up is last' {
        $p = Get-XdrRoundReprovePlan -Category @('x')
        $idx = @{}; for ($i = 0; $i -lt $p.Count; $i++) { $idx[$p[$i].Name] = $i }
        $idx['reset-all']   | Should -BeLessThan $idx['verify-cold']
        $idx['verify-cold'] | Should -BeLessThan $idx['force-leg2']
        $idx['force-leg2']  | Should -BeLessThan $idx['verify-sustain']
        $p[-1].Name | Should -Be 'no-regression'
        $p[-1].Kind | Should -Be 'rollup'
    }
    It 'the reset phase reflects the Category set (data-driven, not hardcoded)' {
        $pp = Get-XdrRoundReprovePlan -Category @('Alpha','Beta')
        $pp[0].Kind   | Should -Be 'reset'        # leg-1 reset is always first
        $pp[0].Detail | Should -Match 'Alpha,Beta'
    }
    It 'the cold-emit ingest wait builds the _CL union from the DEPLOYED Category set (data-driven · not the 3 hardcoded pilot tables)' {
        $src = Get-Content (Join-Path $script:repo 'tools\Invoke-XdrRoundReprove.ps1') -Raw
        # REGRESSION: the ingest-readiness union was hardcoded to the 3 pilot tables, so a 4th onboarded cat's rows were
        # never observed (dcount(Category) capped at 3 < ExpectCats=4 → the wait starved to its cap, then raced verify-cold).
        $src | Should -Not -Match 'union Defender_ExposureManagement_CL, Defender_Operations_CL, Defender_SecureScore_CL'
        # the table list is built per deployed cat, mirroring the connector's canonical "${Portal}_${Category}_CL" derivation
        $src | Should -Match '\$Category \| ForEach-Object \{ ''\{0\}_\{1\}_CL'' -f \$Portal, \$_ \}'
    }
    It 'composes ONLY existing tools (B4: no new gate) — the live driver references the known tool files' {
        $src = Get-Content (Join-Path $script:repo 'tools\Invoke-XdrRoundReprove.ps1') -Raw
        $src | Should -Match 'Save-XdrCheckpointReset\.ps1'
        $src | Should -Match 'Run-PostDeployVerify\.ps1'
        $src | Should -Match 'Force-XdrFullCycle\.ps1'
        $src | Should -Match 'lib/Get-XdrDeployedCategories\.ps1'
    }
    It 'pipes directly to 8 phases — no comma-wrap footgun (Get-...|ForEach yields each phase, not one array)' {
        # the live driver iterates the plan; this pins that the function emits 8 phases whether assigned or piped,
        # and each Kind is a scalar string (the comma-wrap bug surfaced as $_.Kind == System.Object[] in the plan print)
        $kinds = Get-XdrRoundReprovePlan -Category @('A','B') | ForEach-Object { $_.Kind }
        @($kinds).Count | Should -Be 8
        $kinds | ForEach-Object { $_ | Should -BeOfType [string] }
    }
    It 'live-driver arg-passing invariants (the pwsh -File / automatic-$Args / stdout-capture traps the first live run hit)' {
        $src = Get-Content (Join-Path $script:repo 'tools\Invoke-XdrRoundReprove.ps1') -Raw
        # multi-value [string[]] over `pwsh -File` binds ONLY the first token unless comma-joined into one
        $src | Should -Match 'Category -join'
        # child-arg param must NOT be named $Args (shadows the automatic $Args → @Args splats EMPTY → children run defaults)
        $src | Should -Match '\$ChildArgs'
        $src | Should -Not -Match '\[string\[\]\]\s*\$Args\b'
        # child stdout via Out-Host so the function return ($rc) is the clean exit int, not stdout+code (honest roll-up)
        $src | Should -Match 'Out-Host'
    }
    It 'verify phases RETRY on a non-zero exit (the GENERIC cure for slow AppEvents/AppTraces ingest — observe the gate, do not guess a pre-wait)' {
        $src = Get-Content (Join-Path $script:repo 'tools\Invoke-XdrRoundReprove.ps1') -Raw
        # both verify legs go through the retry wrapper (not a single-shot Invoke-XdrChild that races the slow table)
        $src | Should -Match "Invoke-XdrVerifyWithRetry -File 'Run-PostDeployVerify\.ps1' -Phase 'verify-cold'"
        $src | Should -Match "Invoke-XdrVerifyWithRetry -File 'Run-PostDeployVerify\.ps1' -Phase 'verify-sustain'"
        # the wrapper returns 0 on the first green try and only the last rc at the cap (real failure · the M1 cure holds)
        $src | Should -Match 'if \(\$rc -eq 0\) \{ return 0 \}'
        $src | Should -Match 'still exit \$rc after \$MaxTries tries'
    }
}
