#Requires -Version 7.4
# Φ4.G3a · Verify-OperationLanding gate-9 (exactly-once) honesty — an EMPTY window must NOT score a vacuous PASS
# ("rows==0 → 0==0 → exactly-once"). That masked a completeness failure (0 rows landed reads as "proven"). A 0-row
# window now resolves to INCONCLUSIVE (its own bucket · never folded into VERIFIED). RED pre-fix.

BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot/../../..").Path
    $script:tool = Join-Path $script:repo 'tools/Verify-OperationLanding.ps1'
    $script:src = Get-Content $script:tool -Raw
}

Describe 'Φ4.G3a · exactly-once gate is honest on an empty window (no vacuous PASS)' {
    It 'parses with no errors' {
        $e = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:tool, [ref]$null, [ref]$e) | Out-Null
        @($e).Count | Should -Be 0
    }
    It 'detects the empty window (0 rows) and flags gate-9 as Inconclusive' {
        $script:src | Should -Match '\$eoEmpty\s*='
        $script:src | Should -Match '\$eoRows -eq 0'
        $script:src | Should -Match 'Inconclusive\s*=\s*\$eoEmpty'
    }
    It 'requires a NON-EMPTY window for the exactly-once PASS (count==dcount alone is not enough)' {
        $script:src | Should -Match '\$eoPass\s*=.*\$eoRows -gt 0'
    }
    It 'tallies Inconclusive as its own bucket — never folded into VERIFIED' {
        $script:src | Should -Match '\$gatesInconclusive\s*='
        $script:src | Should -Match 'INCONCLUSIVE'
    }
    It 'no longer claims a 0-row window is vacuously exactly-once' {
        $script:src | Should -Not -Match 'exactly-once vacuously'
    }
}
