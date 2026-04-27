#Requires -Modules Pester
<#
.SYNOPSIS
    Locks the invariant: every Az.* / AzTable cmdlet our code calls has its
    source module bundled in function-app.zip.

.DESCRIPTION
    Iter 13.1 had bundled Az.Accounts/KeyVault/Storage but called Get-AzTableRow
    (in AzTable module — not bundled). Result: every poll silently no-op'd
    because auth-gate cmdlet threw CommandNotFoundException.

    This gate enumerates every PowerShell cmdlet our code calls (via static
    analysis — grep for Verb-Noun patterns), maps each cmdlet to its source
    module, and asserts that source module is in release.yml's bundled list.

    Catches any future "I added a new cmdlet but forgot to bundle the module"
    regression at PR time.
#>

BeforeAll {
    $script:RepoRoot       = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:SrcDir         = Join-Path $script:RepoRoot 'src'
    $script:ReleaseYmlPath = Join-Path $script:RepoRoot '.github' 'workflows' 'release.yml'
    $script:ReleaseYmlContent = Get-Content $script:ReleaseYmlPath -Raw

    # Map of cmdlet → source module. Authoritative for what we expect to be
    # bundled. New cmdlet calls get added here.
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
        # Az.Storage (table cmdlets in 7.x; in 8+ they are in AzTable)
        'New-AzStorageContext'        = 'Az.Storage'
        'Get-AzStorageTable'          = 'Az.Storage|AzTable'
        'New-AzStorageTable'          = 'Az.Storage|AzTable'
        # AzTable
        'Get-AzTableRow'              = 'AzTable'
        'Add-AzTableRow'              = 'AzTable'
        'Update-AzTableRow'           = 'AzTable'
        'Remove-AzTableRow'           = 'AzTable'
    }

    # Discover all .ps1 + .psm1 files in src/
    $script:SrcFiles = Get-ChildItem -Path $script:SrcDir -Recurse -Include '*.ps1','*.psm1' -File -ErrorAction SilentlyContinue
}

Describe 'Cmdlet → bundled module coverage (Linux Consumption Legion + Az.Storage 8+ regression lock)' {

    It 'every Az.*/AzTable cmdlet our code calls has its source module declared in the provider map' {
        # Find all Verb-Noun matches in src/ that look like Az cmdlets
        $allCmdletCalls = @()
        foreach ($file in $script:SrcFiles) {
            $content = Get-Content $file.FullName -Raw
            # Match Verb-Az* or Verb-AzTable* patterns
            $cmdletMatches = [regex]::Matches($content, '\b(?:Get|Set|New|Remove|Add|Update|Disable|Enable|Connect|Disconnect|Test|Invoke|Save|Restore)-(?:Az\w+|AzTable\w*)')
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
}
