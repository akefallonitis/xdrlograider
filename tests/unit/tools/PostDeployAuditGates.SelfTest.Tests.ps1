#Requires -Version 7.4
# SelfTest for the §4.B B9-B11 PURE gate functions (tools/lib/Xdr.PostDeployAudit.ps1) — RED-prove EVERY decision
# branch with NO live az (the Verify-DeployedConnector Test-XdrGate_* honesty-bar pattern). The pure fns are the
# heart of Run-PostDeployAudit; the SelfTest proves the operator's CORE requirement (B10 artifact-discrimination:
# a cold-emit baseline is NOT mistaken for real dup-accumulation) without a tenant. B5 query-honesty: a !QueryOk
# input is INCONCLUSIVE on EVERY gate, never a silent 0/PASS.

BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot/../../..").Path
    $script:lib  = Join-Path $script:repo 'tools/lib/Xdr.PostDeployAudit.ps1'
    . $script:lib
}

Describe 'B9-B11 lib · parse + load' {
    It 'the lib parses with no errors' {
        $e = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:lib, [ref]$null, [ref]$e) | Out-Null
        @($e).Count | Should -Be 0
    }
    It 'exports the three NEW gate functions + the sweep core' {
        Get-Command Test-XdrB9_ErrorRate      -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Test-XdrB10_DupAccumulation -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Test-XdrB11_FailOpen       -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Get-XdrShippedOpFlags      -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'B9 · AppTraces error/warning-RATE (per Entry.Poll.Succeeded · classify-by-ErrorClass+recovery)' {
    It 'PASS · low error-rate (<=2%) with no hard class on a CLEAN window' {
        $d = Test-XdrB9_ErrorRate -Failed 1 -Succeeded 99 -QueryOk $true
        $d.Verdict | Should -Be 'PASS'
        $d.Pass    | Should -BeTrue
    }
    It 'FAIL · error-rate above 2%' {
        $d = Test-XdrB9_ErrorRate -Failed 5 -Succeeded 95 -QueryOk $true
        $d.Verdict | Should -Be 'FAIL'
    }
    It 'PASS · exactly at the 2% threshold (boundary inclusive)' {
        # 2 / (2+98) = 0.02 == threshold → PASS (<=)
        (Test-XdrB9_ErrorRate -Failed 2 -Succeeded 98 -QueryOk $true).Verdict | Should -Be 'PASS'
    }
    It 'FAIL · an un-recovered hard class (Breaker.Opened with no Breaker.Closed) even at 0% rate' {
        $d = Test-XdrB9_ErrorRate -Failed 0 -Succeeded 200 -UnrecoveredBreakers 1 -QueryOk $true
        $d.Verdict | Should -Be 'FAIL'
        $d.Detail  | Should -Match 'un-recovered hard class'
    }
    It 'FAIL · AppExceptions present even at low rate' {
        (Test-XdrB9_ErrorRate -Failed 0 -Succeeded 200 -AppExceptions 3 -QueryOk $true).Verdict | Should -Be 'FAIL'
    }
    It 'ARTIFACT-DISCRIMINATION · a reset in the window → INCONCLUSIVE (raw count operator-inflated · classify-by-ErrorClass needs a clean window)' {
        $d = Test-XdrB9_ErrorRate -Failed 0 -Succeeded 100 -ResetsInWindow 1 -QueryOk $true
        $d.Verdict | Should -Be 'INCONCLUSIVE'
        $d.Detail  | Should -Match 'reset'
    }
    It 'INCONCLUSIVE · zero Succeeded+Failed (no steady-state evidence · never a silent PASS)' {
        (Test-XdrB9_ErrorRate -Failed 0 -Succeeded 0 -QueryOk $true).Verdict | Should -Be 'INCONCLUSIVE'
    }
    It 'B5 QUERY-HONESTY · a failed query is INCONCLUSIVE, never 0/PASS' {
        $d = Test-XdrB9_ErrorRate -Failed 0 -Succeeded 0 -QueryOk $false
        $d.Verdict       | Should -Be 'INCONCLUSIVE'
        $d.Inconclusive  | Should -BeTrue
        $d.Pass          | Should -BeFalse
    }
}

Describe 'B10 · steady-state dup-accumulation (the operator CORE requirement · artifact-discriminated)' {
    It 'PASS · clean window · rows/distinct ratio <= 1.5' {
        $d = Test-XdrB10_DupAccumulation -Rows 100 -DistinctRecordId 90 -QueryOk $true
        $d.Verdict | Should -Be 'PASS'
    }
    It 'FAIL · clean window (NO reset) · ratio > 1.5 = REAL dup-accumulation' {
        $d = Test-XdrB10_DupAccumulation -Rows 300 -DistinctRecordId 100 -QueryOk $true
        $d.Verdict | Should -Be 'FAIL'
        $d.Detail  | Should -Match 'REAL dup-accumulation'
    }
    It 'PASS at the 1.5 boundary (inclusive)' {
        (Test-XdrB10_DupAccumulation -Rows 150 -DistinctRecordId 100 -QueryOk $true).Verdict | Should -Be 'PASS'
    }
    It 'ARTIFACT · reset-in-window + HIGH skip fraction → PASS (cold-emit baseline · signature-skip PROVEN firing · NOT accumulation)' {
        # 2700 rows / 100 distinct on a freshly-reset op LOOKS like accumulation, but a high skip fraction proves
        # the rows are the cold-emit baseline + the signature-skip fires → artifact, not real dup.
        $d = Test-XdrB10_DupAccumulation -Rows 2700 -DistinctRecordId 100 -ResetsInWindow 1 -Succeeded 1 -Skipped 20 -BoundaryDeduped 5 -QueryOk $true
        $d.Verdict | Should -Be 'PASS'
        $d.Detail  | Should -Match 'COLD-EMIT baseline'
    }
    It 'REAL · reset-in-window + LOW skip fraction + rising rows → FAIL (signature-skip NOT firing post-cold-emit)' {
        $d = Test-XdrB10_DupAccumulation -Rows 2700 -DistinctRecordId 100 -ResetsInWindow 1 -Succeeded 20 -Skipped 1 -BoundaryDeduped 0 -QueryOk $true
        $d.Verdict | Should -Be 'FAIL'
        $d.Detail  | Should -Match 'REAL dup-accumulation'
    }
    It 'INCONCLUSIVE · reset-in-window with NO poll outcomes (cannot read the skip fraction)' {
        (Test-XdrB10_DupAccumulation -Rows 2700 -DistinctRecordId 100 -ResetsInWindow 1 -Succeeded 0 -Skipped 0 -BoundaryDeduped 0 -QueryOk $true).Verdict | Should -Be 'INCONCLUSIVE'
    }
    It 'INCONCLUSIVE · clean window with 0 rows / 0 distinct (legit-empty op · no SNAPSHOT data to evaluate)' {
        (Test-XdrB10_DupAccumulation -Rows 0 -DistinctRecordId 0 -QueryOk $true).Verdict | Should -Be 'INCONCLUSIVE'
    }
    It 'FAIL · rows present but distinct RecordId == 0 (RecordId not landing · cannot establish exactly-once)' {
        (Test-XdrB10_DupAccumulation -Rows 50 -DistinctRecordId 0 -QueryOk $true).Verdict | Should -Be 'FAIL'
    }
    It 'B5 QUERY-HONESTY · a failed query is INCONCLUSIVE, never 0/PASS' {
        (Test-XdrB10_DupAccumulation -Rows 0 -DistinctRecordId 0 -QueryOk $false).Verdict | Should -Be 'INCONCLUSIVE'
    }
}

Describe 'B11 · fail-open detection (Entry.FailOpen sustained + un-recovered breaker)' {
    It 'INCONCLUSIVE · Entry.FailOpen event NOT present yet (not a false pass · the operator has not wired it)' {
        $d = Test-XdrB11_FailOpen -EventPresent $false -QueryOk $true
        $d.Verdict      | Should -Be 'INCONCLUSIVE'
        $d.Inconclusive | Should -BeTrue
        $d.Detail       | Should -Match 'not present in telemetry yet'
    }
    It 'PASS · event present + a single transient (advisory · bracketing a reset)' {
        $d = Test-XdrB11_FailOpen -EventPresent $true -SustainedCount 0 -TransientCount 1 -QueryOk $true
        $d.Verdict | Should -Be 'PASS'
    }
    It 'FAIL · a SUSTAINED fail-open (same OperationKey across >=2 distinct CorrelationIds)' {
        $d = Test-XdrB11_FailOpen -EventPresent $true -SustainedCount 1 -QueryOk $true
        $d.Verdict | Should -Be 'FAIL'
        $d.Detail  | Should -Match 'SUSTAINED'
    }
    It 'FAIL · an un-recovered Breaker.Opened blocks even when Entry.FailOpen is NOT yet emitted' {
        $d = Test-XdrB11_FailOpen -EventPresent $false -UnrecoveredBreakers 1 -QueryOk $true
        $d.Verdict | Should -Be 'FAIL'
        $d.Detail  | Should -Match 'Breaker.Opened with no matching Breaker.Closed'
    }
    It 'B5 QUERY-HONESTY · a failed query is INCONCLUSIVE, never PASS' {
        (Test-XdrB11_FailOpen -EventPresent $false -QueryOk $false).Verdict | Should -Be 'INCONCLUSIVE'
    }
}
