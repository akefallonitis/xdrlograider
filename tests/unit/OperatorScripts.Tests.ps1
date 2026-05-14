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

    It 'has 9 numbered sections (8 sections + 7b az validate)' {
        # Sections are headered "=== N/9 ..." or "=== Nb/9 ..." (7b is the
        # operator-local ARM-expression-eval gate added to catch substring/
        # dependsOn bugs the offline JSON-shape Pester cannot).
        $headers = [regex]::Matches($script:Content, '===\s*[\dab]+/9\s+[^=]+===')
        $headers.Count | Should -Be 9
    }

    It 'is offline-by-default — -IncludeOnline opt-in for section 8' {
        $script:Content | Should -Match '\[switch\]\s+\$IncludeOnline'
        $script:Content | Should -Match 'if \(\$IncludeOnline\)'
    }

    It 'emits markdown + JSON reports' {
        $script:Content | Should -Match 'preflight-\$utc\.md'
        $script:Content | Should -Match 'preflight-\$utc\.json'
    }

    It 'does NOT invoke Connect-AzAccount in the default offline path (no online ops without opt-in)' {
        # Connect-AzAccount is the v0.1.0-banned online op. `az login` and
        # `az deployment group` ARE allowed in section 7b — that section is
        # the operator-local ARM-expression-eval gate, and az-CLI is
        # explicitly checked + skipped when missing/logged-out. Strip block +
        # line comments first so the boundary checks don't trip on docs.
        $stripped = $script:Content -replace '(?s)<#.*?#>', '' -replace '(?m)^\s*#.*$', ''
        $stripped | Should -Not -Match '(?<!\w)Connect-AzAccount(?!\w)'
    }

    It 'section 7b is gated on env vars (XDRLR_PREFLIGHT_RG + WORKSPACE_ID) so default run stays offline' {
        $script:Content | Should -Match 'XDRLR_PREFLIGHT_RG'
        $script:Content | Should -Match 'XDRLR_PREFLIGHT_WORKSPACE_ID'
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

    It 'has 15 numbered phases (14 + cold-start budget probe; Plan §8.6 H8)' {
        # Match either single-phase `Phase 7/15` or combined `Phase 5-6/15` headers
        $phaseHdrs = [regex]::Matches($script:Content, '===\s+Phase\s+[\d\-]+/15')
        $phaseHdrs.Count | Should -BeGreaterOrEqual 14   # Phase 5+6 may share one header (heartbeat)
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
