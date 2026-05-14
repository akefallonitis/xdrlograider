#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# CI/CD workflow invariants per Rule 18:
#   - NO SP secrets (AZ_CLIENT_SECRET, ARM_CLIENT_SECRET, azure-credentials)
#   - NO Azure OIDC for deploy (azure/login@vN used only by post-deploy tooling, never CI gates)
#   - NO live online testing in CI (no `Probe-Auth-Local` invocation, no `az deployment` outside operator-local context)
#   - NO Claude / AI / tool-attribution strings
#   - Cosign keyless OIDC for release signing ONLY
#   - All offline gates HARD-FAIL (no continue-on-error: true on critical gates)

Describe '.github/workflows invariants (Rule 18)' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $script:WorkflowFiles = @(Get-ChildItem (Join-Path $script:RepoRoot '.github' 'workflows') -Filter '*.yml')
        $script:AllContent = ($script:WorkflowFiles | ForEach-Object { Get-Content -Raw $_.FullName }) -join "`n`n"
    }

    It 'has the 3 required workflow files (ci, release, validate-solution)' {
        $names = $script:WorkflowFiles.Name | Sort-Object
        $names | Should -Contain 'ci.yml'
        $names | Should -Contain 'release.yml'
        $names | Should -Contain 'validate-solution.yml'
    }

    It 'NO Service Principal secrets referenced (Rule 18)' {
        $forbidden = @(
            'AZ_CLIENT_SECRET'
            'ARM_CLIENT_SECRET'
            'AZURE_CLIENT_SECRET'
            'azure-credentials'
            'azureCredentials'
            'AZURE_CREDENTIALS'
        )
        foreach ($pat in $forbidden) {
            $script:AllContent | Should -Not -Match $pat -Because "Rule 18: NO SP secrets in CI"
        }
    }

    It 'NO Azure OIDC login action (azure/login@) in CI workflows for deploy purposes' {
        # Allow `azure/login@` in operator-local scripts but NOT in workflows.
        # The only OIDC use must be sigstore cosign keyless for RELEASE signing.
        $script:AllContent | Should -Not -Match 'azure/login@'
    }

    It 'NO live online testing in CI (no deployment commands in workflows)' {
        # Strip YAML comments (# ...) and the release-body markdown block (under
        # `body: |`) before checking. References to `az deployment group ...` in
        # comments or release notes are documentation, not actual invocations.
        $stripped = $script:AllContent -replace '(?m)^\s*#.*$', ''
        # Strip the release.yml body: |...files: block where we explain operator
        # commands in markdown. The body ends at the next top-level key (files:).
        $stripped = $stripped -replace '(?s)body:\s*\|.*?files:', 'body: | <stripped>\nfiles:'
        $stripped | Should -Not -Match 'az deployment group (create|what-if)' -Because 'no actual deployment commands should run from CI workflows (Rule 18)'
        $stripped | Should -Not -Match 'Probe-Auth-Local'
        $stripped | Should -Not -Match 'Verify-Deploy'
    }

    It 'NO Claude / AI / tool-attribution strings' {
        $script:AllContent | Should -Not -Match 'Claude'
        $script:AllContent | Should -Not -Match 'anthropic'
        $script:AllContent | Should -Not -Match 'Co-Authored-By: Claude'
        $script:AllContent | Should -Not -Match '🤖'
        $script:AllContent | Should -Not -Match 'Generated with Claude'
    }

    It 'release.yml uses cosign keyless OIDC signing (sigstore/cosign-installer)' {
        $rel = Get-Content -Raw (Join-Path $script:RepoRoot '.github' 'workflows' 'release.yml')
        $rel | Should -Match 'sigstore/cosign-installer'
        $rel | Should -Match 'cosign sign-blob'
        # id-token write permission is mandatory for keyless OIDC.
        $rel | Should -Match 'id-token:\s*write'
    }

    It 'ci.yml hard-fails on PSSA Errors + Pester failures + ARM-TTK + auto-regenerate-gate' {
        $ci = Get-Content -Raw (Join-Path $script:RepoRoot '.github' 'workflows' 'ci.yml')
        $ci | Should -Match 'gitleaks'
        $ci | Should -Match 'PSScriptAnalyzer|psscript'
        $ci | Should -Match 'Pester'
        $ci | Should -Match 'arm-ttk'
        $ci | Should -Match 'auto-regenerate-gate'
    }

    It 'NO continue-on-error: true on critical CI gates (ARM-TTK + coverage)' {
        # Allow continue-on-error on SBOM generation only (anchore/sbom-action sometimes flakes).
        $ci  = Get-Content -Raw (Join-Path $script:RepoRoot '.github' 'workflows' 'ci.yml')
        $ci  | Should -Not -Match 'continue-on-error:\s*true'
        $rel = Get-Content -Raw (Join-Path $script:RepoRoot '.github' 'workflows' 'release.yml')
        # release allows continue-on-error on sbom only
        $coeMatches = [regex]::Matches($rel, 'continue-on-error:\s*true')
        $coeMatches.Count | Should -BeLessOrEqual 1 -Because 'release.yml may only continue-on-error for the SBOM step'
    }

    It 'release.yml bundles pinned Az module versions (RequiredVersion)' {
        $rel = Get-Content -Raw (Join-Path $script:RepoRoot '.github' 'workflows' 'release.yml')
        $rel | Should -Match "Az\.Accounts.*5\.4\.0"
        $rel | Should -Match "Az\.KeyVault.*6\.4\.3"
        $rel | Should -Match "Az\.Storage.*7\.5\.0"
    }

    It 'release.yml auto-refreshes the stable tag on every green main-branch CI (workflow_run trigger)' {
        # Stable-tag contract: every green ci.yml on main triggers release.yml,
        # which retags v0.1.0 at HEAD and re-publishes signed artifacts so
        # releases/latest/download/* always reflects the current main HEAD.
        $rel = Get-Content -Raw (Join-Path $script:RepoRoot '.github' 'workflows' 'release.yml')
        $rel | Should -Match 'workflow_run:'                       -Because 'auto-refresh requires workflow_run trigger'
        $rel | Should -Match 'workflows:\s*\[\s*"ci"\s*\]'         -Because 'workflow_run must reference ci.yml by name'
        $rel | Should -Match "workflow_run\.conclusion\s*==\s*'success'" -Because 'must gate on conclusion=success to avoid firing on CI failure'
    }

    It 'release.yml emits a "Last refreshed" marker in the release body so operators see the rebuild date' {
        # GitHub does NOT update release.published_at when artifacts are
        # re-uploaded under the same tag. Without a body marker, operators
        # cannot tell from the page UI which build of v0.1.0 they are seeing.
        $rel = Get-Content -Raw (Join-Path $script:RepoRoot '.github' 'workflows' 'release.yml')
        $rel | Should -Match 'Last refreshed'
        $rel | Should -Match 'steps\.meta\.outputs\.iso'
        $rel | Should -Match 'steps\.meta\.outputs\.sha'
    }

    It 'NO V2 / ClientV2 / AuthV2 module references in workflows' {
        $script:AllContent | Should -Not -Match 'ClientV2'
        $script:AllContent | Should -Not -Match 'AuthV2'
        $script:AllContent | Should -Not -Match 'Xdr\.\w+V2'
    }
}
