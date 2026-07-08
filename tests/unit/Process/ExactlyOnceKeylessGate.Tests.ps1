#Requires -Version 7.4
# 2026-06-18 · keyless-fix wiring regression guard. A SNAPSHOT op with NO proven NaturalKey lands a content-hash
# RecordId (runtime $XdrContentHash · Xdr.Common.Runtime), and the deployed-connector ExactlyOnce gate must use that
# landed RecordId as the dedup key so it RUNS and BLOCKS per-cycle dup-accumulation — instead of advisory-SKIPPING a
# keyless op (the skip is how the live SecureScore GetInsights 24,300-row / empty-RecordId dup slipped through).
# The verifier is a SCRIPT (not behaviorally unit-testable like a module — sourcing it runs the gates), so — matching
# tests/unit/Process/ExactlyOnceHonesty — this guards the wiring by source-pattern + parse so it cannot silently
# regress. The BEHAVIORAL proof of the content-hash itself is the SnapshotReEmit suite
# ('keyless SNAPSHOT op gets a content-hash RecordId — never empty, distinct content -> distinct, deterministic').

BeforeAll {
    $script:repo     = (Resolve-Path "$PSScriptRoot/../../..").Path
    $script:verifier = Join-Path $script:repo 'tools/Verify-DeployedConnector.ps1'
    $script:runtime  = Join-Path $script:repo 'src/Modules/Xdr.Common.Runtime/Xdr.Common.Runtime.psm1'
    $script:vsrc     = Get-Content $script:verifier -Raw
    $script:rsrc     = Get-Content $script:runtime  -Raw
}

Describe 'keyless-fix · a keyless op gets a content-hash RecordId identity that the exactly-once gate blocks on' {
    It 'the verifier and the runtime both parse with no errors' {
        $e = $null; [System.Management.Automation.Language.Parser]::ParseFile($script:verifier, [ref]$null, [ref]$e) | Out-Null; @($e).Count | Should -Be 0
        $e = $null; [System.Management.Automation.Language.Parser]::ParseFile($script:runtime,  [ref]$null, [ref]$e) | Out-Null; @($e).Count | Should -Be 0
    }
    It 'the runtime defines a content-hash helper for the keyless RecordId fallback' {
        $script:rsrc | Should -Match '\$script:XdrContentHash'
        $script:rsrc | Should -Match 'SHA256'
    }
    It 'the deployed-connector ExactlyOnce gate falls back to the landed RecordId column for a keyless op (runs + blocks, never advisory-skips)' {
        $script:vsrc | Should -Match "nkKql = 'RecordId'"
    }
    It 'the ExactlyOnce gate asserts count==dcount on the resolved key (per-cycle for SNAPSHOT)' {
        $script:vsrc | Should -Match 'DistinctKeys=dcount'
        $script:vsrc | Should -Match 'BadCycles=countif'
    }
}
