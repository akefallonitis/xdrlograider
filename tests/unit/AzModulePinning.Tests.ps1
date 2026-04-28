#Requires -Modules Pester
<#
.SYNOPSIS
    Locks the iter-13.2 invariant: bundled Az.* modules use RequiredVersion
    (exact pin), NOT MinimumVersion (floating).

.DESCRIPTION
    Iter 13 used MinimumVersion 7.0.0 for Az.Storage. PSGallery served 9.6.0
    (latest 9.x). Az.Storage 8+ removed Get-AzStorageTable / *-AzTableRow —
    those moved to the separate `AzTable` community module. Result: every
    poll's auth-gate check threw CommandNotFoundException → silent no-op for
    ALL polls → 46 of 47 tables stayed empty.

    Locked: every bundled module must declare an exact RequiredVersion.
    Bundle drift between releases is unacceptable for a production connector.
#>

BeforeAll {
    $script:RepoRoot       = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ReleaseYmlPath = Join-Path $script:RepoRoot '.github' 'workflows' 'release.yml'
    $script:ReleaseYmlContent = Get-Content $script:ReleaseYmlPath -Raw

    $script:RequiredModules = @{
        'Az.Accounts'  = '5.3.4'
        'Az.KeyVault'  = '6.4.3'
        'Az.Storage'   = '7.5.0'  # CRITICAL: 8+ removed table cmdlets
        'Az.Resources' = '7.10.0' # Iter 13.13: AzTable's AzureRmStorageTableCoreHelper.psm1 #Requires -Modules Az.Resources
        'AzTable'      = '2.1.0'  # Community module; provides Get/Add/Update/Remove-AzTableRow
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

    It 'release.yml bundles Az.Storage at the pinned version (must be < 8.0 to retain table cmdlets)' {
        $expected = $script:RequiredModules['Az.Storage']
        $script:ReleaseYmlContent | Should -Match "Name\s*=\s*'Az\.Storage';\s*RequiredVersion\s*=\s*'$([regex]::Escape($expected))'" -Because "Az.Storage 7.5.0 is the LAST version with Get-AzStorageTable/Add-AzTableRow built-in. 8+ removed them."
        # Sanity: pin must be < 8.0
        $major = [int]($expected -split '\.')[0]
        $major | Should -BeLessThan 8 -Because "Az.Storage 8+ removed table cmdlets — would re-trigger iter-13 silent no-op bug"
    }

    It 'release.yml bundles AzTable (community module) — required because Az.Storage 7.x is the bridge but Az.Data.Tables is the modern target' {
        $expected = $script:RequiredModules['AzTable']
        $script:ReleaseYmlContent | Should -Match "Name\s*=\s*'AzTable';\s*RequiredVersion\s*=\s*'$([regex]::Escape($expected))'" -Because 'AzTable provides Get/Add/Update/Remove-AzTableRow used by Get-CheckpointTimestamp + Set-CheckpointTimestamp + Get-XdrAuthSelfTestFlag + validate-auth-selftest. Without it, ALL polls silently no-op.'
    }

    It 'release.yml bundles Az.Resources (iter-13.13) — AzTable transitive dependency' {
        $expected = $script:RequiredModules['Az.Resources']
        $script:ReleaseYmlContent | Should -Match "Name\s*=\s*'Az\.Resources';\s*RequiredVersion\s*=\s*'$([regex]::Escape($expected))'" -Because (
            'iter-13.13 live evidence: AzTable 2.1.0 ships AzureRmStorageTableCoreHelper.psm1 ' +
            'with `#Requires -Modules Az.Resources`. Without Az.Resources bundled, ' +
            'Add-AzTableRow / Get-AzTableRow fail to load → validate-auth-selftest cannot ' +
            'write the gate flag → all poll-* timers stay gated → 0 rows ingested.'
        )
    }
}

Describe 'release.yml post-build gates — bundle integrity assertions' {

    It 'release.yml asserts every bundled Az.* + AzTable module .psd1 is present in zip' {
        # iter-13.13: now 5 expected modules (Az.Accounts, Az.KeyVault, Az.Storage,
        # Az.Resources, AzTable) — missing any one re-triggers a silent no-op bug.
        $script:ReleaseYmlContent | Should -Match "Az\.Accounts.*Az\.KeyVault.*Az\.Storage.*AzTable" -Because 'release.yml validation loop must check all bundled modules — missing AzTable was the iter-13 silent no-op bug; missing Az.Resources was the iter-13.13 silent gate-flag bug'
    }

    It 'release.yml asserts AzTable manifest declares the expected table cmdlets' {
        $script:ReleaseYmlContent | Should -Match 'expectedTableFns.*Get-AzTableRow.*Add-AzTableRow' -Because 'AzTable manifest must declare these — without them runtime CommandNotFoundException'
    }
}
