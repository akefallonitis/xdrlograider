#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Rule 6: 4-value SuccessKind set is live | live-empty | rate-limited | error.
# 'tenant-gated' is RETIRED. License gaps surface as error + LicenseHint (Rule 23).

Describe 'SuccessKind tenant-gated retirement (Rule 6 + 23)' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $script:ModulesRoot = Join-Path $script:RepoRoot 'src' 'Modules'
    }

    It 'has ZERO tenant-gated string literals in module source' {
        $files = Get-ChildItem -Path $script:ModulesRoot -Recurse -Include '*.ps1', '*.psm1', '*.psd1'
        $hits  = foreach ($f in $files) {
            $matches = Select-String -Path $f.FullName -Pattern "'tenant-gated'" -SimpleMatch
            foreach ($m in $matches) { "$($f.FullName):$($m.LineNumber): $($m.Line.Trim())" }
        }
        $hits.Count | Should -Be 0 -Because "Rule 6 retired tenant-gated. Findings: $($hits -join '; ')"
    }

    It 'Set-MDEEndpointLastResult ValidateSet has 4 values (no tenant-gated)' {
        $path = Join-Path $script:ModulesRoot 'Xdr.Defender.Client' 'Public' 'Get-MDEEndpointLastResult.ps1'
        $content = Get-Content -Raw $path
        $content | Should -Match "ValidateSet\('live',\s*'live-empty',\s*'rate-limited',\s*'error'\)"
        $content | Should -Not -Match 'tenant-gated'
    }

    It 'Set-XdrTierStateRow ValidateSet for -Reason has 4 values (no tenant-gated)' {
        $path = Join-Path $script:ModulesRoot 'Xdr.Sentinel.Ingest' 'Public' 'Set-XdrTierStateRow.ps1'
        $content = Get-Content -Raw $path
        # Allow '' as the empty default since ByProperties param-set may not set Reason
        $content | Should -Match "ValidateSet\('live',\s*'live-empty',\s*'rate-limited',\s*'error',\s*''\)"
        $content | Should -Not -Match "'tenant-gated'"
    }

    It 'Get-MDEEndpointLastResult exposes LicenseHint column (Rule 23)' {
        $path = Join-Path $script:ModulesRoot 'Xdr.Defender.Client' 'Public' 'Get-MDEEndpointLastResult.ps1'
        $content = Get-Content -Raw $path
        $content | Should -Match 'LicenseHint'
    }
}
