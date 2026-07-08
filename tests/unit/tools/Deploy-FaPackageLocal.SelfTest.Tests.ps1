#requires -Version 7.0
# Contract test (plan §23.2 · LOCK 28) for tools/Deploy-FaPackageLocal.ps1 — the path-1 LOOP code deploy.
# It pins the tool's SAFETY ENVELOPE: release/ARM-independent, 0-KeyVault, 0-ARM, no RBAC self-escalation,
# dry-run by default, revert-safe. These are static-source assertions (no live Azure) so they run in CI.

Describe 'Deploy-FaPackageLocal · safety contract (plan §23.2)' {
    BeforeAll {
        $script:tool = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' 'tools' 'Deploy-FaPackageLocal.ps1')).Path
        $script:raw  = Get-Content -LiteralPath $script:tool -Raw
    }

    It 'exists and parses with zero errors' {
        Test-Path $script:tool | Should -BeTrue
        $errs = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:tool, [ref]$null, [ref]$errs) | Out-Null
        @($errs).Count | Should -Be 0
    }

    It 'is DRY-RUN by default · all mutation gated behind -Execute' {
        $script:raw | Should -Match '\[switch\]\s*\$Execute'
    }

    It 'requires GitSha (Mandatory · stamps the build by content)' {
        $script:raw | Should -Match '(?s)\[Parameter\(Mandatory\)\].*?\$GitSha'
    }

    It 'NEVER runs an ARM deployment (path-1 is release/ARM-independent)' {
        # actual call sites would read "az deployment ..." (literal spaces); the self-guard regex uses \s+ so
        # this does not false-trip on the guard pattern itself.
        $script:raw | Should -Not -Match 'az deployment'
    }

    It 'NEVER touches KeyVault (read-only connector · 0-KeyVault)' {
        $script:raw | Should -Not -Match 'az keyvault'
    }

    It 'does NOT self-escalate RBAC (least-privilege · requires pre-granted blob-write)' {
        # the only role op the tool EXECUTES is a READ (az role assignment list); it must not CREATE a grant
        # via the Invoke-Az helper. (The operator-instruction string in the throw message is guidance, not a call.)
        $script:raw | Should -Not -Match "Invoke-Az\s+@\('role'"
    }

    It 'has a self-guard that aborts on ARM-deploy / KeyVault-write source patterns' {
        $script:raw | Should -Match "throw 'GUARD:"
        $script:raw | Should -Match "selfText -match 'deployment"
        $script:raw | Should -Match "keyvault"
    }

    It 'deploys via run-from-package (built locally · cache-busts the FA)' {
        $script:raw | Should -Match 'WEBSITE_RUN_FROM_PACKAGE'
        $script:raw | Should -Match 'Build-FunctionAppZip'
        $script:raw | Should -Match 'XDRLR_GIT_COMMIT_SHA'
    }

    It 'captures the current package value + emits a revert command BEFORE mutating' {
        $script:raw | Should -Match 'REVERT'
        $script:raw | Should -Match 'oldPkg'
    }

    It 'restarts synchronously via az functionapp restart (no --no-wait arg in the call · §12)' {
        $script:raw | Should -Match "functionapp','restart'"
        # the restart Invoke-Az arg-array must not carry --no-wait (the label text "NO --no-wait" is fine)
        $script:raw | Should -Not -Match "functionapp','restart'[^\r\n]*--no-wait"
    }
}
