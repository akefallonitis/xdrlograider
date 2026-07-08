#Requires -Version 7.4
# G4 · PUBLIC-ALLOWLIST gate (single-repo deny-by-default) · unit-proves the matcher BOTH ways (RED-able):
#   (1) allowed paths pass · (2) a path outside the allowlist (e.g. a re-tracked references/live file, a stray
#       root file) is a VIOLATION · (3) the LIVE tracked tree has zero violations (the axis-35 invariant).
# The matcher is tools/Test-PublicAllowlist.ps1; gauntlet axis 35 is the enforcing caller.

BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $script:tool = Join-Path $script:repo 'tools\Test-PublicAllowlist.ps1'
}

Describe 'G4 · public-allowlist matcher (tools/Test-PublicAllowlist.ps1)' {
    It 'matcher + allowlist exist' {
        Test-Path $script:tool | Should -BeTrue
        Test-Path (Join-Path $script:repo 'tools\public-allowlist.txt') | Should -BeTrue
    }
    It 'allows representative public paths (dir-prefix + exact-file entries)' {
        $out = & $script:tool -RepoRoot $script:repo -Paths @(
            'src/Modules/Xdr.Common.Parser/Xdr.Common.Parser.psm1',
            'tools/Run-PrePushGauntlet.ps1',
            'references/inventory/nodoc-defender-xdr/catalogue.json',
            'tests/fixtures/live/MDE_ActionCenter_CL-raw.json',
            'README.md')
        $LASTEXITCODE | Should -Be 0
        @($out | Where-Object { $_ }) | Should -BeNullOrEmpty
    }
    It 'REJECTS a re-tracked internal-layer path (references/live) — the G4 invariant' {
        $out = @(& $script:tool -RepoRoot $script:repo -Paths @('references/live/source-xdrlograider-raw/MDE_TenantContext_CL-raw.json'))
        $LASTEXITCODE | Should -Be 1
        $out | Should -Contain 'references/live/source-xdrlograider-raw/MDE_TenantContext_CL-raw.json'
    }
    It 'REJECTS a stray root file outside the allowlist (deny-by-default)' {
        $out = @(& $script:tool -RepoRoot $script:repo -Paths @('probe-allops.log', '.env.local', 'scratch.ps1'))
        $LASTEXITCODE | Should -Be 1
        @($out).Count | Should -Be 3
    }
    It 'LIVE tracked tree has ZERO violations (axis-35 invariant on the real repo)' {
        $out = @(& $script:tool -RepoRoot $script:repo)
        $LASTEXITCODE | Should -Be 0
        @($out | Where-Object { $_ }) | Should -BeNullOrEmpty
    }
}
