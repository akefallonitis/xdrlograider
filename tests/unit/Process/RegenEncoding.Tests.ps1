#Requires -Version 7.4
# Φ4.C · the regen→diff gauntlet axes (28 manifest · 30 schema · 32 catalogue/evidence-index) capture child-pwsh stdout
# via `& pwsh -File <tool> | Out-String`, which round-trips through [Console]::OutputEncoding. Under git's `sh` pre-push
# hook the console defaults to the OEM codepage → non-ASCII (the `·` middot in catalogue descriptions) mangled to `?` →
# spurious "catalogue DRIFT" that BLOCKED the push while a direct run was 34/34. The gauntlet (parent decode) + every
# SoT regen tool (child emit) MUST pin UTF-8 output so the round-trip is lossless in ANY launching shell. RED pre-fix.

BeforeDiscovery {
    $script:RegenEncTools = @(
        'tools/Run-PrePushGauntlet.ps1'
        'dev-tools/Build-Catalogue.ps1'
        'dev-tools/Build-EvidenceIndex.ps1'
        'dev-tools/Generate-Manifest.ps1'
    )
}

Describe 'Φ4.C · regen tools pin UTF-8 output encoding (shell-independent regen→diff)' {
    It '<_> pins UTF-8 OutputEncoding (no BOM)' -ForEach $RegenEncTools {
        $repo = (Resolve-Path "$PSScriptRoot/../../..").Path
        $src = Get-Content (Join-Path $repo $_) -Raw
        $src | Should -Match 'OutputEncoding = \[System\.Text\.UTF8Encoding\]::new\(\$false\)'
    }
    It 'the pinned encoding constructs without error (UTF8 no-BOM)' {
        { [System.Text.UTF8Encoding]::new($false) } | Should -Not -Throw
    }
}
