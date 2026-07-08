#Requires -Version 7.4
# Φ4.G2c-3 · tools/Force-XdrAuthLoss.ps1 — operator-side forced-auth-loss that DRIVES the c83fc18 Reauth gate live
# (invalidate/delete the cached session in XdrTierState PK=<Portal> RK=<UPN> so the FA self-heals next cycle). MUST:
# parse · DryRun-default · AAD (--auth-mode login) NOT shared-key SDK · target XdrTierState with both modes
# (Invalidate=merge sentinel Sccauth · Delete=entity delete) · carry NO RG/KeyVault destructive op. RED pre-creation.

BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot/../../..").Path
    $script:tool = Join-Path $script:repo 'tools/Force-XdrAuthLoss.ps1'
    $script:exists = Test-Path $script:tool
    $script:src = if ($script:exists) { Get-Content $script:tool -Raw } else { '' }
    # comment-stripped view for negative asserts (the rationale docstring legitimately names delete/purge/--no-wait).
    # Strip BOTH the <# .. #> block comment AND full-line # comments (a line-only strip leaves the block-body prose).
    $script:noBlock = [regex]::Replace($script:src, '(?s)<#.*?#>', '')
    $script:codeOnly = (($script:noBlock -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
}

Describe 'Φ4.G2c-3 · Force-XdrAuthLoss forced-auth-loss CLI contract' {
    It 'exists and parses with no errors' {
        $script:exists | Should -BeTrue
        $e = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:tool, [ref]$null, [ref]$e) | Out-Null
        @($e).Count | Should -Be 0
    }
    It 'is DRY-RUN by default (the az mutation is gated behind -Apply)' {
        $script:src | Should -Match '\[switch\]\s*\$Apply'
        $script:src | Should -Match 'if\s*\(\s*-not\s+\$Apply\s*\)'
    }
    It 'mutates via AAD (--auth-mode login), never a shared key / Az.Storage SDK' {
        $script:src | Should -Match '--auth-mode login'
        $script:codeOnly | Should -Not -Match 'Get-AzStorageAccount|Add-AzTableRow|--account-key|--connection-string'
    }
    It 'targets XdrTierState with both modes (Invalidate=merge sentinel Sccauth · Delete=entity delete)' {
        $script:src | Should -Match 'XdrTierState'
        $script:src | Should -Match 'az storage entity merge'
        $script:src | Should -Match 'az storage entity delete'
        $script:src | Should -Match 'Sccauth='
    }
    It 'carries NO RG/KeyVault destructive op (entity delete is the intended Delete mode · not flagged)' {
        $script:codeOnly | Should -Not -Match 'az group delete|keyvault (purge|delete)|--no-wait|table delete'
    }
}
