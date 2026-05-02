#Requires -Modules Pester
<#
.SYNOPSIS
    Locks the invariant: every Az.* cmdlet our code calls has its source module
    bundled in function-app.zip.

.DESCRIPTION
    Iter 13.1 had bundled Az.Accounts/KeyVault/Storage but called Get-AzTableRow
    (in AzTable module — not bundled). Result: every poll silently no-op'd
    because auth-gate cmdlet threw CommandNotFoundException.

    Iter 13.15: AzTable + Az.Resources removed — Storage Table ops now use the
    unified Invoke-XdrStorageTableEntity helper (System.Net.Http.HttpClient +
    Get-AzAccessToken) which honors MI auth natively. Provider map shrunk
    accordingly. Comment-stripping added to the static scan so historical
    references in docstrings (e.g. "Replaces AzTable's Add-AzTableRow") do
    not falsely trigger the unmapped-cmdlet assertion.

    This gate enumerates every PowerShell cmdlet our code actually calls (via
    static analysis — grep for Verb-Noun patterns AFTER stripping comments),
    maps each cmdlet to its source module, and asserts that source module is
    in release.yml's bundled list.
#>

BeforeAll {
    $script:RepoRoot       = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:SrcDir         = Join-Path $script:RepoRoot 'src'
    $script:ReleaseYmlPath = Join-Path $script:RepoRoot '.github' 'workflows' 'release.yml'
    $script:ReleaseYmlContent = Get-Content $script:ReleaseYmlPath -Raw

    # Map of cmdlet → source module. Authoritative for what we expect to be
    # bundled. New cmdlet calls get added here.
    # Iter 13.15: AzTable + Az.Resources cmdlets removed since src/ no longer
    # calls them (replaced by Invoke-XdrStorageTableEntity HttpClient helper).
    $script:CmdletProviderMap = @{
        # Az.Accounts
        'Connect-AzAccount'           = 'Az.Accounts'
        'Disconnect-AzAccount'        = 'Az.Accounts'
        'Disable-AzContextAutosave'   = 'Az.Accounts'
        'Get-AzAccessToken'           = 'Az.Accounts'
        'Get-AzContext'               = 'Az.Accounts'
        'Set-AzContext'               = 'Az.Accounts'
        # Az.KeyVault
        'Get-AzKeyVaultSecret'        = 'Az.KeyVault'
        'Set-AzKeyVaultSecret'        = 'Az.KeyVault'
        'Get-AzKeyVault'              = 'Az.KeyVault'
    }

    # Discover all .ps1 + .psm1 files in src/
    $script:SrcFiles = Get-ChildItem -Path $script:SrcDir -Recurse -Include '*.ps1','*.psm1' -File -ErrorAction SilentlyContinue

    # Helper: strip PowerShell comments from a script body so static analysis
    # only sees real cmdlet invocations (not docstring references like
    # "Replaces AzTable's Add-AzTableRow"). Handles:
    #   - block comments  <# ... #>
    #   - line comments    # to end-of-line
    # Heuristic — does not perfectly handle '#' inside string literals, but
    # cmdlet patterns inside strings are vanishingly rare in our codebase.
    function script:Remove-PowerShellComments {
        param([string] $Source)
        # Strip block comments first (non-greedy)
        $stripped = [regex]::Replace($Source, '<#[\s\S]*?#>', '')
        # Strip single-line comments (# to end-of-line)
        $stripped = [regex]::Replace($stripped, '(?m)#.*$', '')
        return $stripped
    }
}

Describe 'Cmdlet → bundled module coverage (Linux Consumption Legion + Az.Storage 8+ regression lock)' {

    It 'every Az.*/AzTable cmdlet our code calls (excluding comments) has its source module declared in the provider map' {
        # Find all Verb-Noun matches in src/ that look like Az cmdlets, AFTER
        # stripping comments so historical docstring references don't false-positive.
        $allCmdletCalls = @()
        foreach ($file in $script:SrcFiles) {
            $content = Get-Content $file.FullName -Raw
            $codeOnly = Remove-PowerShellComments -Source $content
            # Match Verb-Az* or Verb-AzTable* patterns
            $cmdletMatches = [regex]::Matches($codeOnly, '\b(?:Get|Set|New|Remove|Add|Update|Disable|Enable|Connect|Disconnect|Test|Invoke|Save|Restore)-(?:Az\w+|AzTable\w*)')
            foreach ($m in $cmdletMatches) {
                $allCmdletCalls += $m.Value
            }
        }
        $uniqueCmdlets = $allCmdletCalls | Sort-Object -Unique

        $unmapped = @()
        foreach ($cmd in $uniqueCmdlets) {
            if (-not $script:CmdletProviderMap.ContainsKey($cmd)) {
                $unmapped += $cmd
            }
        }
        $unmapped | Should -BeNullOrEmpty -Because "every Az.* / AzTable cmdlet must be in the provider map (or we don't know which module to bundle):`n$(($unmapped | ForEach-Object { '    ' + $_ }) -join "`n")"
    }

    It 'every cmdlet provider module is bundled in release.yml Save-Module list' {
        # Build set of expected modules (from cmdletProviderMap values)
        $expectedModules = $script:CmdletProviderMap.Values |
            ForEach-Object { $_ -split '\|' } |
            Sort-Object -Unique

        $missing = @()
        foreach ($mod in $expectedModules) {
            # Search release.yml for this module being passed to Save-Module
            $pattern = "Name\s*=\s*'$([regex]::Escape($mod))'"
            if ($script:ReleaseYmlContent -notmatch $pattern) {
                $missing += $mod
            }
        }
        $missing | Should -BeNullOrEmpty -Because "modules referenced by cmdlet calls must be bundled (otherwise CommandNotFoundException at runtime):`n$(($missing | ForEach-Object { '    ' + $_ }) -join "`n")"
    }

    It 'iter-13.15 transition gate: src/ does NOT call any AzTable cmdlets in code (only docstring references allowed)' {
        # Locks the iter-13.15 transition: ad-hoc reintroduction of AzTable
        # cmdlets would be a regression. Comments are allowed (history).
        $azTableCallsInCode = @()
        foreach ($file in $script:SrcFiles) {
            $content = Get-Content $file.FullName -Raw
            $codeOnly = Remove-PowerShellComments -Source $content
            $matches2 = [regex]::Matches($codeOnly, '\b(?:Get|Add|Update|Remove)-AzTableRow\b')
            foreach ($m in $matches2) {
                $azTableCallsInCode += "$($file.FullName): $($m.Value)"
            }
        }
        $azTableCallsInCode | Should -BeNullOrEmpty -Because 'iter-13.15 replaced all AzTable cmdlet calls with Invoke-XdrStorageTableEntity. Any reintroduction is a regression.'
    }

    It 'iter-13.15 transition gate: src/ does NOT call legacy Storage Table context cmdlets in code' {
        # New-AzStorageContext / Get-AzStorageTable / New-AzStorageTable were
        # used pre-iter-13.15 to bridge to AzTable. With Invoke-XdrStorageTableEntity
        # there is no need for any context object — token + URI is sufficient.
        $legacyCallsInCode = @()
        foreach ($file in $script:SrcFiles) {
            $content = Get-Content $file.FullName -Raw
            $codeOnly = Remove-PowerShellComments -Source $content
            $matches2 = [regex]::Matches($codeOnly, '\b(?:New-AzStorageContext|Get-AzStorageTable|New-AzStorageTable)\b')
            foreach ($m in $matches2) {
                $legacyCallsInCode += "$($file.FullName): $($m.Value)"
            }
        }
        $legacyCallsInCode | Should -BeNullOrEmpty -Because 'iter-13.15 removed runtime Storage Table context creation; the table is created at deploy time by Bicep and entity ops use Invoke-XdrStorageTableEntity directly.'
    }
}
