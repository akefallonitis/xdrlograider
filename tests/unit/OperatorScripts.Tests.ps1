#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Operator-script invariants: parse cleanly + correct section/phase counts +
# offline-by-default + no destructive operations without explicit opt-in.

Describe 'tools/Preflight-Local.ps1 invariants' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $script:Path = Join-Path $script:RepoRoot 'tools' 'Preflight-Local.ps1'
        $script:Content = Get-Content -Raw $script:Path
    }

    It 'parses without syntax errors' {
        $tokens = $null; $errs = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($script:Path, [ref]$tokens, [ref]$errs)
        $errs.Count | Should -Be 0
    }

    It 'has 8 numbered sections (matches plan §10)' {
        $headers = [regex]::Matches($script:Content, '===\s*\d+/8\s+[^=]+===')
        $headers.Count | Should -Be 8
    }

    It 'is offline-by-default — -IncludeOnline opt-in for section 8' {
        $script:Content | Should -Match '\[switch\]\s+\$IncludeOnline'
        $script:Content | Should -Match 'if \(\$IncludeOnline\)'
    }

    It 'emits markdown + JSON reports' {
        $script:Content | Should -Match 'preflight-\$utc\.md'
        $script:Content | Should -Match 'preflight-\$utc\.json'
    }

    It 'does NOT invoke az login / az deployment / Connect-AzAccount (no online ops without opt-in)' {
        # Goal: no actual Azure commands invoked in the default offline path.
        # Strip block comments <#...#> and single-line # comments, then check.
        $stripped = $script:Content -replace '(?s)<#.*?#>', '' -replace '(?m)^\s*#.*$', ''
        $stripped | Should -Not -Match '(?<!\w)az login(?!\w)'
        $stripped | Should -Not -Match '(?<!\w)az deployment\s+group'
        $stripped | Should -Not -Match '(?<!\w)Connect-AzAccount(?!\w)'
    }
}

Describe 'tools/Probe-Auth-Local.ps1 invariants' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $script:Path = Join-Path $script:RepoRoot 'tools' 'Probe-Auth-Local.ps1'
        $script:Content = Get-Content -Raw $script:Path
    }

    It 'parses without syntax errors' {
        $tokens = $null; $errs = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($script:Path, [ref]$tokens, [ref]$errs)
        $errs.Count | Should -Be 0
    }

    It 'requires .env.local (gitignored) for credentials — never inline' {
        $script:Content | Should -Match '\$EnvFile'
        $script:Content | Should -Match '\.env\.local'
    }

    It 'validates the 3 NEW Phase 1 probes (TenantContext, Custom Collection, Auth chain)' {
        $script:Content | Should -Match 'Connect-DefenderPortal'
        $script:Content | Should -Match 'Get-DefenderTenantContext'
        $script:Content | Should -Match 'Get-XdrCustomCollectionRule'
    }

    It 'iterates per-sub-area smoke (1 endpoint per sub-area)' {
        $script:Content | Should -Match 'Invoke-MDEEndpoint.*-EntryKey'
    }
}

Describe 'tools/Verify-Deploy.ps1 invariants' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $script:Path = Join-Path $script:RepoRoot 'tools' 'Verify-Deploy.ps1'
        $script:Content = Get-Content -Raw $script:Path
    }

    It 'parses without syntax errors' {
        $tokens = $null; $errs = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($script:Path, [ref]$tokens, [ref]$errs)
        $errs.Count | Should -Be 0
    }

    It 'has 14 numbered phases (Rule 12 + plan §10)' {
        # Match either single-phase `Phase 7/14` or combined `Phase 5-6/14` headers
        $phaseHdrs = [regex]::Matches($script:Content, '===\s+Phase\s+[\d\-]+/14')
        $phaseHdrs.Count | Should -BeGreaterOrEqual 13   # Phase 5+6 may share one header (heartbeat)
    }

    It 'requires az login session (operator-local, never CI)' {
        $script:Content | Should -Match 'az account show'
    }

    It 'AutoFix is OPT-IN switch only' {
        $script:Content | Should -Match '\[switch\]\s+\$AutoFix'
    }

    It 'verifies the 14-phase Phase 1 invariants (ARM resources, tables, heartbeat, circuit-breaker)' {
        $script:Content | Should -Match 'ARM resources present'
        $script:Content | Should -Match 'workspace tables'
        $script:Content | Should -Match 'Heartbeat fired'
        $script:Content | Should -Match 'Circuit-breaker'
        $script:Content | Should -Match 'Rate-limited'
    }
}
