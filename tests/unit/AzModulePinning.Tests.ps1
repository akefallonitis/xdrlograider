#Requires -Modules Pester
<#
.SYNOPSIS
    Locks the iter-13.15 module bundle: Az.Accounts + Az.KeyVault + Az.Storage
    pinned with RequiredVersion (exact pin). AzTable + Az.Resources REMOVED.

.DESCRIPTION
    History:
    - Iter 13.0: MinimumVersion 7.0.0 for Az.Storage → PSGallery served 9.6.0
      (latest) → Az.Storage 8+ had removed *-AzTableRow → CommandNotFoundException
      → silent no-op of all polls.
    - Iter 13.2: pinned RequiredVersion = 7.5.0; bundled AzTable 2.1.0 as bridge.
    - Iter 13.13: bundled Az.Resources 7.10.0 (AzTable transitive dep).
    - Iter 13.14: AzTable's Microsoft.Azure.Cosmos.Table SDK still didn't
      reliably honor MI auth → switched gate flag write to direct REST.
    - Iter 13.15: replaced ALL AzTable + Az.Storage table cmdlet usage with the
      unified Invoke-XdrStorageTableEntity helper (HttpClient + MI token via
      Get-AzAccessToken). AzTable + Az.Resources no longer needed → REMOVED.

    Locked invariants:
    - Every bundled module uses RequiredVersion (exact pin, no floating).
    - Az.Accounts + Az.KeyVault + Az.Storage are bundled.
    - AzTable + Az.Resources are NOT bundled (iter-13.15 transition gate).
#>

BeforeAll {
    $script:RepoRoot       = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ReleaseYmlPath = Join-Path $script:RepoRoot '.github' 'workflows' 'release.yml'
    $script:ReleaseYmlContent = Get-Content $script:ReleaseYmlPath -Raw

    $script:RequiredModules = @{
        'Az.Accounts'  = '5.3.4'
        'Az.KeyVault'  = '6.4.3'
        'Az.Storage'   = '7.5.0'  # Retained for blob/queue ops; not table
    }
}

Describe 'Az.* module bundling — RequiredVersion enforcement (no floating versions)' {

    It 'release.yml uses RequiredVersion (NOT MinimumVersion) for module bundling' {
        # MinimumVersion lets PSGallery serve whatever-latest. Each release
        # silently picks a different snapshot. Az.Storage 9.x silently broke
        # iter-13's table cmdlet usage. RequiredVersion guarantees reproducible
        # builds + tested-version pinning.
        $script:ReleaseYmlContent | Should -Match 'RequiredVersion' -Because 'iter-13.2 locked exact-version pinning'
        # Soft check — MinimumVersion may still appear in comments, but not as a
        # parameter to Save-Module
        $minVerInSaveModule = $script:ReleaseYmlContent -match 'Save-Module[^\r\n]*-MinimumVersion'
        $minVerInSaveModule | Should -BeFalse -Because 'iter-13.2 must NOT use Save-Module -MinimumVersion (floating dependency hell)'
    }

    It 'release.yml bundles Az.Accounts at the pinned version' {
        $expected = $script:RequiredModules['Az.Accounts']
        $script:ReleaseYmlContent | Should -Match "Name\s*=\s*'Az\.Accounts';\s*RequiredVersion\s*=\s*'$([regex]::Escape($expected))'" -Because "Az.Accounts must be pinned to $expected for reproducible builds"
    }

    It 'release.yml bundles Az.KeyVault at the pinned version' {
        $expected = $script:RequiredModules['Az.KeyVault']
        $script:ReleaseYmlContent | Should -Match "Name\s*=\s*'Az\.KeyVault';\s*RequiredVersion\s*=\s*'$([regex]::Escape($expected))'" -Because "Az.KeyVault must be pinned to $expected"
    }

    It 'release.yml bundles Az.Storage at the pinned version' {
        # Iter 13.15: Az.Storage no longer used for tables (Invoke-XdrStorageTableEntity
        # helper replaces all table cmdlet calls). Retained for blob/queue ops + future use.
        $expected = $script:RequiredModules['Az.Storage']
        $script:ReleaseYmlContent | Should -Match "Name\s*=\s*'Az\.Storage';\s*RequiredVersion\s*=\s*'$([regex]::Escape($expected))'" -Because "Az.Storage must be pinned to $expected for reproducible builds"
    }
}

Describe 'iter-13.15 transition gate — AzTable + Az.Resources MUST NOT be bundled' {
    # These modules were bundled in iter-13.2 → iter-13.14. iter-13.15 removed
    # them when Storage Table ops moved to System.Net.Http.HttpClient via
    # Invoke-XdrStorageTableEntity. This gate locks the transition: any
    # accidental re-add to release.yml fails CI immediately.

    It 'release.yml does NOT bundle AzTable (replaced by Invoke-XdrStorageTableEntity in iter-13.15)' {
        $script:ReleaseYmlContent | Should -Not -Match "Name\s*=\s*'AzTable';\s*RequiredVersion" -Because 'iter-13.15: AzTable removed; Storage Table ops use Invoke-XdrStorageTableEntity (System.Net.Http.HttpClient + MI token via Get-AzAccessToken).'
    }

    It 'release.yml does NOT bundle Az.Resources (only existed as AzTable transitive dep)' {
        $script:ReleaseYmlContent | Should -Not -Match "Name\s*=\s*'Az\.Resources';\s*RequiredVersion" -Because 'iter-13.15: Az.Resources only existed because AzTable required it. With AzTable gone, no remaining dependency.'
    }
}

Describe 'release.yml post-build gates — bundle integrity assertions' {

    It 'release.yml asserts every bundled Az.* module .psd1 is present in zip (iter-13.15: 3 modules)' {
        # Iter 13.15: 3 bundled modules (Az.Accounts, Az.KeyVault, Az.Storage).
        # Missing any one re-triggers a silent no-op bug.
        $script:ReleaseYmlContent | Should -Match "Az\.Accounts.*Az\.KeyVault.*Az\.Storage" -Because 'release.yml validation loop must check all bundled modules'
    }

    It 'release.yml asserts AzTable + Az.Resources are NOT in the zip (negative-bundle gate)' {
        # iter-13.15: enforce removal stays effective even if Save-Module cache
        # leaks an old version into the staging dir. The actual gate text in
        # release.yml is "AzTable + Az.Resources confirmed NOT bundled (iter-13.15 transition)".
        $script:ReleaseYmlContent | Should -Match 'AzTable.*Az\.Resources.*NOT bundled.*iter-13\.15' -Because 'release.yml must include the negative-bundle assertion to prevent regression'
    }
}
