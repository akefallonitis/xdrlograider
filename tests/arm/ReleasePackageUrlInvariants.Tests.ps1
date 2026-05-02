#Requires -Modules Pester
<#
.SYNOPSIS
    Lock the two coupled invariants that make /releases/latest/download/function-app.zip
    actually serve the function-app package on cold start:

      INVARIANT 1: mainTemplate.json variables.packageUrl tracks /releases/latest
      INVARIANT 2: .github/workflows/release.yml sets `prerelease: false`

    Both must hold simultaneously. Either alone is harmless; the combination
    of `prerelease: true` (default for tags containing '-') + `packageUrl=
    /releases/latest` produces a 404 on cold start → silent FA failure
    (Function App shows Running but no timer ever fires, no telemetry ever
    emits). Bug class hit live in v0.1.0-beta first deploy.

.NOTES
    The two invariants are deliberately decoupled:
      - The packageUrl simplification (drop functionAppZipVersion parameter,
        track /latest) lives in the ARM template — operator UX win.
      - The prerelease=false enforcement lives in the release workflow —
        platform-publishing concern.
    Without both gates, a future contributor who restores `prerelease: ${{
    contains(github.ref_name, '-') }}` (the seemingly-correct default for
    semver-style pre-release tags) would silently break every -beta / -rc /
    -alpha deploy without any test catching it.
#>

BeforeAll {
    $script:RepoRoot       = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ArmPath        = Join-Path $script:RepoRoot 'deploy' 'compiled' 'mainTemplate.json'
    $script:ReleaseYmlPath = Join-Path $script:RepoRoot '.github' 'workflows' 'release.yml'

    if (-not (Test-Path -LiteralPath $script:ArmPath)) {
        throw "Compiled ARM template not found at $($script:ArmPath)."
    }
    if (-not (Test-Path -LiteralPath $script:ReleaseYmlPath)) {
        throw "release.yml not found at $($script:ReleaseYmlPath)."
    }
    $script:Arm = Get-Content -LiteralPath $script:ArmPath -Raw | ConvertFrom-Json -Depth 50
    $script:ReleaseYml = Get-Content -LiteralPath $script:ReleaseYmlPath -Raw
}

Describe 'ReleasePackageUrl.Invariant1 — mainTemplate packageUrl tracks /releases/latest' {

    It 'mainTemplate.json variables.packageUrl points at /releases/latest/download/function-app.zip' {
        # The variable is an ARM concat expression like
        # [concat('https://github.com/', parameters('githubRepo'),
        #         '/releases/latest/download/function-app.zip')]
        # so we look for the path-suffix substring anywhere inside.
        $pkgUrl = [string]$script:Arm.variables.packageUrl
        $pkgUrl | Should -Match "/releases/latest/download/function-app\.zip" -Because (
            'Marketplace best practice for community connectors is /releases/latest. ' +
            'Operators should not have to edit the wizard for routine upgrades.'
        )
    }

    It 'mainTemplate.json does NOT define a functionAppZipVersion parameter' {
        $params = @($script:Arm.parameters.PSObject.Properties.Name)
        $params | Should -Not -Contain 'functionAppZipVersion' -Because (
            'Parameter dropped in v0.1.0-beta first publish; the /latest URL pattern ' +
            'replaces the operator-edited version pin.'
        )
    }
}

Describe 'ReleasePackageUrl.Invariant2 — release.yml sets prerelease=false' {

    It 'release.yml sets prerelease: false (NOT a contains() expression)' {
        # The exact line should be:  prerelease: false
        # The buggy default we want to BAN is:  prerelease: ${{ contains(github.ref_name, '-') }}
        # which auto-marks every "-beta" / "-rc" / "-alpha" tag as prerelease →
        # /releases/latest skips it → packageUrl 404 on cold start.
        $script:ReleaseYml | Should -Match '(?m)^\s*prerelease:\s*false\s*$' -Because (
            'release.yml MUST hardcode prerelease: false. The /releases/latest endpoint ' +
            'on GitHub SKIPS pre-releases (returns 404), which conflicts with the ' +
            'mainTemplate.json packageUrl simplification (Invariant 1). The "-beta" suffix ' +
            'in the tag name is sufficient operator signal; we do NOT need the GitHub ' +
            'prerelease=true flag, which silently breaks every cold start.'
        )
    }

    It 'release.yml does NOT use contains(github.ref_name, ...) for prerelease (the seemingly-correct trap)' {
        # Catch the specific anti-pattern even if someone "improves" it.
        $script:ReleaseYml | Should -Not -Match "prerelease:\s*\`$\{\{\s*contains\(github\.ref_name" -Because (
            'The contains(github.ref_name, ''-'') pattern is the bug. It treats every ' +
            'semver pre-release tag as GitHub-prerelease which breaks /releases/latest.'
        )
    }
}

Describe 'ReleasePackageUrl.Invariant3 — both invariants documented at the call sites' {

    It 'release.yml prerelease: false has an inline comment explaining the coupling to packageUrl' {
        # Defensive: ensure a future contributor reading the release.yml line
        # understands WHY it must stay false. Match any of the three keywords
        # we know we wrote in the explanation block.
        $script:ReleaseYml | Should -Match 'packageUrl|/releases/latest|cold start' -Because (
            'release.yml prerelease: false MUST carry an inline comment referencing ' +
            'the packageUrl coupling, so a future contributor doesn''t reinstate the bug.'
        )
    }
}
