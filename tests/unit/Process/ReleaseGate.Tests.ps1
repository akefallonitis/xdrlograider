#Requires -Version 7.4
# Φ4.A · release.yml must run the pre-push gauntlet BEFORE building/signing/publishing a release (defense-in-depth).
# ci.yml gates the normal push->retag flow, but a tag push OR workflow_dispatch can point at un-gated code (the residual
# hole). RED pre-fix: release.yml went straight from Install-Pester to Build-FunctionAppZip with no gauntlet.

BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $script:rel  = Get-Content "$script:repo\.github\workflows\release.yml" -Raw
}

# Discovery-time (top-level · runs in Pester's discovery phase) enumeration of every workflow that invokes the gauntlet,
# so the data-driven guard below can assert each one provisions the tools the gauntlet axes need. $script:-scoped + set
# at top level so it is visible in BOTH the -ForEach (discovery) and the It bodies (run).
$script:repoRoot   = (Resolve-Path "$PSScriptRoot\..\..\..").Path
$script:gauntletWf = Get-ChildItem "$script:repoRoot\.github\workflows" -Filter '*.yml' |
    Where-Object { (Get-Content $_.FullName -Raw) -match 'Run-PrePushGauntlet\.ps1' } |
    ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }

Describe 'Φ4.A · release.yml gauntlet gate (defense-in-depth)' {
    It 'invokes Run-PrePushGauntlet.ps1' {
        $script:rel | Should -Match 'Run-PrePushGauntlet\.ps1'
    }
    It 'runs the gauntlet BEFORE Build-FunctionAppZip (the gate precedes the build)' {
        $gIdx = $script:rel.IndexOf('Run-PrePushGauntlet.ps1')
        $bIdx = $script:rel.IndexOf('Build-FunctionAppZip')
        $gIdx | Should -BeGreaterThan -1
        $bIdx | Should -BeGreaterThan -1
        $gIdx | Should -BeLessThan $bIdx
    }
    It 'aborts the release on a non-zero gauntlet exit (refuses to build un-gated code)' {
        $script:rel | Should -Match 'gauntlet FAIL|refusing to build'
    }
    It 'release.yml is still valid YAML' {
        Import-Module powershell-yaml -ErrorAction SilentlyContinue
        { ConvertFrom-Yaml $script:rel } | Should -Not -Throw
    }
}

Describe 'Φ4.B · gauntlet workflows provision the tools their axes need (axis 15 / ARM-TTK cannot self-pass)' {
    # Audit FH (2026-06-15): release.yml invoked Run-PrePushGauntlet WITHOUT installing PSScriptAnalyzer, so axis 15
    # (PSSA errors==0 + the custom B-25 type-check rule) gracefully SKIPPED -> self-passed. On a tag-push / workflow_dispatch
    # that bypassed ci.yml, a PSSA-Error regression would ship in a SIGNED, PUBLISHED release while the gate read green.
    # Generic guard (fix-at-source, not just release.yml): ANY workflow that runs the gauntlet MUST install the tools its
    # axes depend on (PSScriptAnalyzer for axis 15; arm-ttk for the ARM-TTK axes) so no axis graceful-skips to a self-pass.

    It 'discovers the known gauntlet workflows (ci.yml + release.yml)' {
        # Recompute from disk here (run phase) rather than reading $script:gauntletWf, which is discovery-scoped and
        # not carried into run-phase It bodies in Pester 5 (the -ForEach tests below bake their data in at discovery).
        $names = @(Get-ChildItem "$script:repo\.github\workflows" -Filter '*.yml' |
            Where-Object { (Get-Content $_.FullName -Raw) -match 'Run-PrePushGauntlet\.ps1' } |
            ForEach-Object { $_.Name })
        $names | Should -Contain 'ci.yml'      -Because 'ci.yml runs the gauntlet on every push to main'
        $names | Should -Contain 'release.yml' -Because 'release.yml runs the gauntlet before building/signing a release'
    }

    It '<Name> installs PSScriptAnalyzer (else gauntlet axis 15 self-passes)' -ForEach $script:gauntletWf {
        (Get-Content $Path -Raw) | Should -Match 'Install-Module\s+PSScriptAnalyzer' `
            -Because "$Name runs the gauntlet, so axis 15 must actually run PSScriptAnalyzer rather than graceful-skip to a self-pass"
    }

    It '<Name> provisions arm-ttk (else the ARM-TTK-backed axes self-pass)' -ForEach $script:gauntletWf {
        (Get-Content $Path -Raw) | Should -Match 'arm-ttk' `
            -Because "$Name runs the gauntlet, so the ARM-TTK-backed axes must have arm-ttk cloned/available"
    }
}

Describe 'Φ4.C · postdeploy enforcement gate (FH-6 · release refuses a SHA without a green postdeploy/verified record)' {
    # The full postdeploy verify is LOCAL-ONLY (the service account must never authenticate in CI · security lock).
    # tools/Confirm-PostDeploy.ps1 runs it locally and POSTS a commit status (postdeploy/verified=success) for the
    # deployed SHA; release.yml + post-deploy-gate.yml only READ that status (CI-safe). The producer's context string
    # and the consumers' check string MUST agree, and the gate MUST precede the build — these tests pin both.
    BeforeAll {
        $script:repo2   = (Resolve-Path "$PSScriptRoot\..\..\..").Path
        $script:relC    = Get-Content "$script:repo2\.github\workflows\release.yml" -Raw
        $script:pdg     = Get-Content "$script:repo2\.github\workflows\post-deploy-gate.yml" -Raw
        $script:confirm = Get-Content "$script:repo2\tools\Confirm-PostDeploy.ps1" -Raw
    }
    It 'release.yml gates on the postdeploy/verified commit status (reads the combined status API)' {
        $script:relC | Should -Match 'postdeploy/verified'
        $script:relC | Should -Match 'commits/.*/status'
    }
    It 'release.yml runs the postdeploy gate BEFORE Build-FunctionAppZip (no build without the record)' {
        $gIdx = $script:relC.IndexOf('postdeploy/verified')
        $bIdx = $script:relC.IndexOf('Build-FunctionAppZip')
        $gIdx | Should -BeGreaterThan -1
        $bIdx | Should -BeGreaterThan -1
        $gIdx | Should -BeLessThan $bIdx
    }
    It 'the postdeploy gate is GA-ONLY (a prerelease/hyphenated tag is the deploy-for-verify vehicle, not gated)' {
        # Bootstrap correctness: the gate MUST skip prerelease tags — else the verification prerelease build (which
        # produces the very code to deploy + verify) would be blocked before any postdeploy/verified record can exist.
        $script:relC | Should -Match 'GA-ONLY'
        $script:relC | Should -Match '\$TAG.*==.*\*-\*'   # the hyphen == prerelease check that short-circuits the gate
    }
    It 'release.yml grants statuses: read (so the gate can read the status)' {
        $script:relC | Should -Match 'statuses:\s*read'
    }
    It 'the postdeploy status CONTEXT agrees across the producer + both gates (else the gate can never pass)' {
        # Confirm-PostDeploy POSTS the context; release.yml + post-deploy-gate.yml READ it. Same literal string required.
        $script:confirm | Should -Match "postdeploy/verified"
        $script:relC    | Should -Match 'postdeploy/verified'
        $script:pdg     | Should -Match 'postdeploy/verified'
    }
    It 'post-deploy-gate.yml reads the status + NEVER INVOKES the service-account verify in CI (security lock)' {
        $script:pdg | Should -Match 'postdeploy/verified'
        $script:pdg | Should -Match 'workflow_dispatch'
        $script:pdg | Should -Match 'commits/.*/status'   # it READS the status (gh api), the CI-safe half
        # It must not EXECUTE any local-only verify tool (an invocation = `pwsh ... <tool>`; comment/error MENTIONS are fine).
        $script:pdg | Should -Not -Match 'pwsh.{0,80}(Verify-XdrLiveContent|Run-PostDeployVerify|Confirm-PostDeploy)'
    }
    It 'post-deploy-gate.yml is valid YAML' {
        Import-Module powershell-yaml -ErrorAction SilentlyContinue
        { ConvertFrom-Yaml $script:pdg } | Should -Not -Throw
    }
}
