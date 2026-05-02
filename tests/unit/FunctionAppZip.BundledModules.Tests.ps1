#Requires -Modules Pester
<#
.SYNOPSIS
    Validates that the iter-13 Linux Consumption "Legion" managed-dependencies
    fix is correctly wired across requirements.psd1, host.json, and the
    release.yml Save-Module step.

.DESCRIPTION
    Linux Consumption "Legion" runtime (Microsoft's current compute platform
    for Y1 PowerShell function apps) does NOT support Managed Dependencies.
    Every function load throws "Failed to install function app dependencies"
    if requirements.psd1 lists Az modules.

    Microsoft's official guidance (https://aka.ms/functions-powershell-include-modules):
    bundle modules into Modules/ inside the function-app.zip via Save-Module
    at release time. Same approach is also required by Flex Consumption
    (v0.2.0 migration target).

    This Pester gate offline-locks the invariant set:
      1. requirements.psd1 must remain empty (no Az/* references)
      2. host.json managedDependency.Enabled must be false
      3. release.yml must Save-Module Az.Accounts/Az.KeyVault/Az.Storage
         into the staged Modules/ directory
      4. release.yml must enforce a size budget gate (10-100 MB)
      5. release.yml must validate bundled modules are present in the final zip

    Iter-12 had ONE dependency-management bug (zip flatten) that caused FA
    Runtime: Error. Iter-13 reveals the SECOND dependency bug (Legion managed
    deps). This gate prevents either from regressing.
#>

BeforeAll {
    $script:RepoRoot       = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ReqPsd1Path    = Join-Path $script:RepoRoot 'src' 'requirements.psd1'
    $script:HostJsonPath   = Join-Path $script:RepoRoot 'src' 'host.json'
    $script:ReleaseYmlPath = Join-Path $script:RepoRoot '.github' 'workflows' 'release.yml'
}

Describe 'Linux Consumption Legion fix — requirements.psd1 must be empty' {

    It 'requirements.psd1 file exists' {
        Test-Path $script:ReqPsd1Path | Should -BeTrue
    }

    It 'requirements.psd1 has NO Az.* module references (Legion incompatibility)' {
        $content = Get-Content $script:ReqPsd1Path -Raw
        # Strip comments (lines starting with #)
        $codeOnly = ($content -split "`n") | Where-Object { $_ -notmatch '^\s*#' } | Out-String
        $codeOnly | Should -Not -Match "(?m)^\s*'Az\." -Because 'Az module references in requirements.psd1 trigger Linux Consumption Legion managed-dependencies failure (every function fails to load with "Failed to install function app dependencies")'
        $codeOnly | Should -Not -Match "(?m)^\s*Az\."  -Because 'Same: Az.* without quotes also triggers the bug'
    }

    It 'requirements.psd1 has @{ ... } empty hashtable structure' {
        $content = Get-Content $script:ReqPsd1Path -Raw
        $content | Should -Match '@\{\s*\}' -Because 'PowerShell Functions runtime requires the file to parse as a valid hashtable manifest, even if empty'
    }
}

Describe 'host.json managedDependency disabled' {

    It 'host.json exists and parses as valid JSON' {
        Test-Path $script:HostJsonPath | Should -BeTrue
        { Get-Content $script:HostJsonPath -Raw | ConvertFrom-Json } | Should -Not -Throw
    }

    It 'host.json managedDependency.Enabled = false (must coexist with bundled-modules approach)' {
        $hostJson = Get-Content $script:HostJsonPath -Raw | ConvertFrom-Json
        $hostJson.managedDependency.Enabled | Should -BeFalse -Because 'managedDependency=true triggers Legion runtime to attempt PSGallery download which fails. Bundled modules under Modules/ require this to be false.'
    }
}

Describe 'release.yml Save-Module step + bundled-modules invariant gates' {

    BeforeAll {
        $script:ReleaseYmlContent = Get-Content $script:ReleaseYmlPath -Raw
    }

    It 'release.yml Save-Module command for Az.Accounts present' {
        $script:ReleaseYmlContent | Should -Match 'Save-Module' -Because 'iter-13 requires Az modules bundled at release time'
        $script:ReleaseYmlContent | Should -Match "Name\s*=\s*'Az\.Accounts'" -Because 'Az.Accounts needed for Connect-AzAccount -Identity (SAMI auth)'
    }

    It 'release.yml Save-Module command for Az.KeyVault present' {
        $script:ReleaseYmlContent | Should -Match "Name\s*=\s*'Az\.KeyVault'" -Because 'Az.KeyVault needed for Get-AzKeyVaultSecret (auth secrets read)'
    }

    It 'release.yml Save-Module command for Az.Storage present' {
        $script:ReleaseYmlContent | Should -Match "Name\s*=\s*'Az\.Storage'" -Because 'Az.Storage needed for checkpoint table operations'
    }

    It 'release.yml has zip size budget gate (catches missing-modules + runaway-bloat regressions)' {
        $script:ReleaseYmlContent | Should -Match 'function-app\.zip is only \$zipMB MB' -Because 'lower bound catches Save-Module failure (zip would be ~67 KB without modules)'
        $script:ReleaseYmlContent | Should -Match 'exceeds 100 MB budget|exceeds 150 MB budget' -Because 'upper bound catches unintended trees leaking into zip'
    }

    It 'release.yml asserts bundled Az.* modules are present in the produced zip' {
        # The release.yml uses a foreach loop over $azMod variable to assert
        # each Modules/<name>/<version>/<name>.psd1 path is in the zip.
        $script:ReleaseYmlContent | Should -Match 'is missing bundled' -Because 'release-time gate catches Save-Module silent failure'
        $script:ReleaseYmlContent | Should -Match "Az\.Accounts.*Az\.KeyVault.*Az\.Storage" -Because 'release.yml validation loop must enumerate all 3 expected Az modules'
    }

    It 'release.yml asserts requirements.psd1 stays module-free (no regression)' {
        $script:ReleaseYmlContent | Should -Match 'requirements\.psd1 still has Az module references' -Because 'developer accidentally re-adding Az to requirements.psd1 must be caught at release time'
    }

    It 'release.yml prunes docs/help to reduce zip size' {
        $script:ReleaseYmlContent | Should -Match 'prunePatterns' -Because 'pruning saves ~30% size — required to stay within 100 MB budget'
    }
}

Describe 'Microsoft official guidance alignment' {

    It 'requirements.psd1 references Microsoft official URL for the Legion fix' {
        $content = Get-Content $script:ReqPsd1Path -Raw
        $content | Should -Match 'aka\.ms/functions-powershell-include-modules' -Because 'document the canonical Microsoft pattern for future maintainers'
    }
}
