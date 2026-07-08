#Requires -Version 7.4
# F1.5 · Build-Catalogue must load curation PER-PORTAL (the portal being catalogued), NOT hardwired to
# nodoc-defender-xdr. Before, line 120 loaded nodoc-defender-xdr/curation.json regardless of -Portal — so a
# non-Defender portal got DEFENDER's curation corrections (the line-119 comment even admitted "per-portal-loop loading
# is a future generalization"). After: a Set-XdrCurationForPortal($key) reloads the curation inside the
# foreach ($key in $targetKeys) loop. Defender is BYTE-IDENTICAL (regen-diff axes 28/30/32 are the regression guard;
# Build-Catalogue -Portal Defender loads the same nodoc-defender-xdr curation). AST-parses the REAL script (not grep).

Describe 'F1.5 · Build-Catalogue · per-portal curation load (not hardwired Defender)' {
    BeforeAll {
        $script:Repo   = (Resolve-Path "$PSScriptRoot\..\..\..").Path
        $script:Script = Join-Path $script:Repo 'dev-tools\Build-Catalogue.ps1'
        $errs = $null
        $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$null, [ref]$errs)
        $script:ParseErrors = $errs
    }

    It 'parses with zero errors' { $script:ParseErrors | Should -BeNullOrEmpty }

    It 'the Import-XdrCuration call does NOT hardcode the nodoc-defender-xdr curation path (de-hardwired)' {
        $calls = $script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Import-XdrCuration' }, $true)
        @($calls).Count | Should -BeGreaterThan 0
        foreach ($c in $calls) {
            $c.Extent.Text | Should -Not -Match 'nodoc-defender-xdr' -Because 'curation must load the portal being catalogued, not a hardcoded Defender path'
        }
    }

    It 'loads curation per-portal — a Set-XdrCurationForPortal helper exists AND is invoked inside the $targetKeys loop' {
        $func = $script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Set-XdrCurationForPortal' }, $true)
        @($func).Count | Should -Be 1 -Because 'the per-portal curation load must be a reusable helper'
        $loops = $script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] -and $n.Condition.Extent.Text -match 'targetKeys' }, $true)
        @($loops).Count | Should -BeGreaterThan 0
        ($loops[0].Body.Extent.Text -match 'Set-XdrCurationForPortal') | Should -BeTrue -Because 'the curation must reload for each portal before it is catalogued'
    }
}
