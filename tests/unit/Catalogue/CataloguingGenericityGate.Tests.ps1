#Requires -Version 7.4
# F1.6 · GENERICITY GATE · the cataloguing engine must catalogue ANY portal's corpus, not just Defender. Before, the
# suite exercised ONLY Defender (regen-diff axes 28/30/32 + axis 7 are all -Portal Defender) — so portal genericity was
# ASSUMED, never PROVEN by the suite, and a re-hardwiring to Defender would pass green. This gate runs Build-Catalogue
# for a representative set of NON-Defender portals and asserts each catalogues without crashing AND emits a
# structurally-valid catalogue with operations (per-portal ship-health). The exhaustive -AllPortals sweep is the P2
# manual-reaudit gate; this is the fast suite-level proof + regression guard.

Describe 'F1.6 · cataloguing genericity gate · non-Defender portals catalogue cleanly' {
    BeforeAll {
        $script:Repo   = (Resolve-Path "$PSScriptRoot\..\..\..").Path
        $script:Script = Join-Path $script:Repo 'dev-tools\Build-Catalogue.ps1'
    }
    # Representative diverse corpora, by nodoc key (unambiguous · no friendly-name mismatch): Purview (cookie · the
    # 2nd-portal proof target) · SecurityCopilot (pod-host grammar) · M365Admin (a distinct expansion corpus).
    It 'catalogues <portal> without crashing + emits a valid catalogue with operations' -ForEach @(
        @{ portal = 'nodoc-purview' }, @{ portal = 'nodoc-security-copilot' }, @{ portal = 'nodoc-m365-admin' }
    ) {
        # stdout → temp file (clean JSON · ConvertTo-CatJson), stderr → null (curation/timeFilter advisory noise).
        $tmp = [IO.Path]::GetTempFileName()
        try {
            & pwsh -NoProfile -File $script:Script -Portal $portal > $tmp 2>$null
            $LASTEXITCODE | Should -Be 0 -Because "Build-Catalogue must not crash on $portal (portal-generic engine)"
            $json = Get-Content $tmp -Raw | ConvertFrom-Json
            $json.PortalKey | Should -Be $portal -Because 'the catalogue must be for the requested portal, not Defender'
            @($json.Operations).Count | Should -BeGreaterThan 0 -Because "$portal corpus must yield catalogued operations (ship-health)"
        } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }
}

# FH-4 · GENERICITY GATE (REAL · not vacuous). F1.6 above proves only Build-Catalogue is portal-generic. The
# regen→diff axes 28/30 drive Generate-Manifest + Build-PerCategorySchema ONLY for Defender — a Defender literal in
# either downstream generator would pass green. This drives the WHOLE chain (committed non-Defender catalogue →
# Generate-Manifest → Build-PerCategorySchema) for a SPACED non-Defender category, proving the shared tokenizer +
# portal resolution + schema/DCR emit are data-driven (the data-only-onboarding premise). -IncludePendingLiveProbe
# widens past Shipped (non-Defender corpora are catalog-only · capability, not active ingestion · ledger A15).
Describe 'FH-4 · genericity gate (REAL) · the FULL gen pipeline is portal-generic (non-Defender end-to-end)' {
    BeforeAll {
        $script:Repo        = (Resolve-Path "$PSScriptRoot\..\..\..").Path
        $script:GenManifest = Join-Path $script:Repo 'dev-tools\Generate-Manifest.ps1'
        $script:BuildSchema = Join-Path $script:Repo 'dev-tools\Build-PerCategorySchema.ps1'
        Import-Module (Join-Path $script:Repo 'src\Modules\Xdr.Common.Parser\Xdr.Common.Parser.psd1') -Force -DisableNameChecking
    }
    It 'drives <portal>/<group> through Generate-Manifest + Build-PerCategorySchema (zero engine edits)' -ForEach @(
        @{ portal = 'Purview'; group = 'Data Security' }
    ) {
        $token = Get-XdrCategoryToken -Category $group
        $tmp   = Join-Path ([IO.Path]::GetTempPath()) ('xdrlr-genericity-' + [Guid]::NewGuid().ToString('N'))
        try {
            $manPath = Join-Path $tmp "manifests/$portal/$token.psd1"
            New-Item -ItemType Directory -Path (Split-Path $manPath) -Force | Out-Null
            # 1 · Generate-Manifest from the COMMITTED non-Defender catalogue (catalog-only widen · no Shipped dependency)
            $genOut = & pwsh -NoProfile -File $script:GenManifest -Portal $portal -Group $group -IncludePendingLiveProbe -OutPath $manPath 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0 -Because "Generate-Manifest must be portal-generic ($portal/$group): $genOut"
            Test-Path $manPath | Should -BeTrue
            $man   = Import-PowerShellDataFile -Path $manPath
            $block = if ($man.ContainsKey($portal)) { $man[$portal] } else { $man }
            @($block.Operations).Count | Should -BeGreaterThan 0 -Because "$portal/$group must yield manifest operations"
            # 2 · Build-PerCategorySchema from that manifest (temp RepoRoot · OutputMode JSON)
            $schemaOut = & pwsh -NoProfile -File $script:BuildSchema -Portal $portal -Category $token -RepoRoot $tmp -OutputMode JSON 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0 -Because "Build-PerCategorySchema must be portal-generic ($portal/$token): $schemaOut"
            $schemaPath = Join-Path $tmp "deploy/per-category-schemas/$portal-$token.json"
            Test-Path $schemaPath | Should -BeTrue
            # 3 · structural validity · envelope present · DCR stream == table columns · portal+token-derived name
            $schema    = Get-Content $schemaPath -Raw | ConvertFrom-Json
            $tableCols = @($schema.TableResource.properties.schema.columns)
            $tableCols.Count | Should -BeGreaterOrEqual 8 -Because 'the 8-col envelope is always emitted'
            @($tableCols.name) | Should -Contain 'TimeGenerated' -Because 'the envelope is always present'
            ([string]$schema.TableResource.name) | Should -Match "${portal}_${token}_CL" -Because 'table name is portal+token derived, NOT Defender-hardcoded'
            $streamProp = @($schema.DcrResource.properties.streamDeclarations.PSObject.Properties)[0]
            @($streamProp.Value.columns).Count | Should -Be $tableCols.Count -Because 'DCR stream == table columns (axis-14 set-equality by construction)'
        } finally { if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue } }
    }
}
