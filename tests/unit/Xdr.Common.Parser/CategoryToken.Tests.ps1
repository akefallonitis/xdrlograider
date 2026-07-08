#Requires -Version 7.4
# WS2.2 · THE single category tokenizer (Get-XdrCategoryToken) + the end-to-end naming-chain contract.
# The seam this pins: 8 of 10 Defender categories carry spaces/'&'; the catalogue tokenized table names while the
# manifest/schema generators used the RAW category → "Defender_Cloud Apps_CL" ≠ "Defender_CloudApps_CL" at
# category #2 onboarding. One function now feeds all three tools; this test makes a divergence RED.

BeforeAll {
    $repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    Import-Module (Join-Path $repo 'src\Modules\Xdr.Common.Parser\Xdr.Common.Parser.psd1') -Force -DisableNameChecking
    $script:cat = Get-Content (Join-Path $repo 'references\inventory\nodoc-defender-xdr\catalogue.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 40
}

Describe 'WS2.2 · Get-XdrCategoryToken (single source)' {
    It 'is exported by Xdr.Common.Parser' {
        (Get-Command Get-XdrCategoryToken -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }
    It 'strips spaces' { Get-XdrCategoryToken -Category 'Cloud Apps' | Should -Be 'CloudApps' }
    It "strips '&' and spaces" { Get-XdrCategoryToken -Category 'Analytics & Data' | Should -Be 'AnalyticsData' }
    It 'is identity for clean names (Operations byte-stability)' { Get-XdrCategoryToken -Category 'Operations' | Should -Be 'Operations' }
    It 'is idempotent' { Get-XdrCategoryToken -Category (Get-XdrCategoryToken -Category 'Vulnerability Management') | Should -Be 'VulnerabilityManagement' }
}

Describe 'WS2.2 · naming-chain contract (catalogue ↔ tokenizer)' {
    It 'every Shipped op WorkspaceTable == Portal_<token>_CL and DcrStreamName == Custom-<table>' {
        $shipped = @($script:cat['Operations'] | Where-Object { $_['Shipped'] })
        $shipped.Count | Should -BeGreaterThan 0
        foreach ($op in $shipped) {
            $tok = Get-XdrCategoryToken -Category ([string]$op['Category'])
            [string]$op['WorkspaceTable'] | Should -Be ("$($op['Portal'])_${tok}_CL") -Because $op['OperationId']
            [string]$op['DcrStreamName']  | Should -Be ("Custom-$($op['Portal'])_${tok}_CL") -Because $op['OperationId']
        }
    }
}

Describe 'Blocker-fix · the DEPLOY assemblers also use the canonical tokenizer (no raw-category ARM names · cat#2)' {
    # Audit BLOCKER: the spaced-category seam was wired into catalogue->manifest->schema but NOT the deploy assemblers
    # (Build-MainTemplate / Onboard-CategorySurgical used raw $Category.ToLowerInvariant()), so a spaced category #2
    # ("Cloud Apps") would emit ARM-invalid '-dcr-cloud apps-' names (silent 0-rows) AND make the Check #11 role-gate
    # vacuous (its regex excludes spaces). This pins the at-source fix: both assemblers tokenize via the ONE function.
    BeforeAll {
        $r = (Resolve-Path "$PSScriptRoot\..\..\..").Path
        $script:DeploySrc = @{
            'dev-tools/Build-MainTemplate.ps1'   = (Get-Content (Join-Path $r 'dev-tools/Build-MainTemplate.ps1') -Raw)
            'tools/Onboard-CategorySurgical.ps1' = (Get-Content (Join-Path $r 'tools/Onboard-CategorySurgical.ps1') -Raw)
        }
    }
    It '<tool> imports the canonical tokenizer + uses it + never raw-lowercases $Category for resource names' -ForEach @(
        @{ tool = 'dev-tools/Build-MainTemplate.ps1' }
        @{ tool = 'tools/Onboard-CategorySurgical.ps1' }
    ) {
        $src = $script:DeploySrc[$tool]
        $src | Should -Match 'Import-Module[^\r\n]*Xdr\.Common\.Parser' -Because "$tool must use the SINGLE canonical tokenizer, not a re-implementation"
        $src | Should -Match 'Get-XdrCategoryToken'                    -Because "$tool must tokenize category names for ARM resources"
        $src | Should -Not -Match '\$Category\.ToLowerInvariant\(\)'   -Because 'raw $Category.ToLowerInvariant() keeps spaces -> ARM-invalid DCR/table/role names (the cat#2 blocker)'
        $src | Should -Not -Match '\$Category -replace'                -Because 'an inline -replace is a tokenizer re-implementation that drifts from the canonical one'
    }
}
