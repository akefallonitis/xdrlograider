#Requires -Version 7.4
# F1.4c · the XdrDefenderRefresh dispatch must enumerate ALL portals with a shipped manifest (registry-driven), not the
# hardcoded Defender literal (the 3rd multi-portal seam · the reaudit's Defender-literal dispatch). BEFORE:
# $loadedManifests['Defender'] (single-portal load) + "Defender_<cat>" partition + portal default 'Defender'. AFTER: an
# outer loop over $loadedManifests.Keys + Get-XdrPortalConfig PartitionPrefix for the partition. Defender is BYTE-
# IDENTICAL (it is the only key today, the outer loop runs once, the prefix resolves to 'Defender'). This AST-parses the
# REAL run.ps1 (NOT a string-grep · the DispatchSafety pattern) so reverting the de-literalization turns it RED.

Describe 'F1.4c · XdrDefenderRefresh · registry-driven multi-portal dispatch' {
    BeforeAll {
        $script:Repo   = (Resolve-Path "$PSScriptRoot\..\..\..").Path
        $script:RunPs1 = Join-Path $script:Repo 'src\functions\XdrDefenderRefresh\run.ps1'
        $errs = $null
        $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:RunPs1, [ref]$null, [ref]$errs)
        $script:ParseErrors = $errs
    }

    It 'run.ps1 parses with zero errors' {
        $script:ParseErrors | Should -BeNullOrEmpty
    }

    It 'enumerates portals via $loadedManifests.Keys (the outer portal loop · not a single hardcoded portal)' {
        $foreaches = $script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)
        $hasPortalLoop = $false
        foreach ($f in $foreaches) {
            $cond = $f.Condition.Extent.Text
            if ($cond -match 'loadedManifests' -and $cond -match '\.Keys') { $hasPortalLoop = $true; break }
        }
        $hasPortalLoop | Should -BeTrue -Because 'the dispatch must loop over EVERY portal with a shipped manifest'
    }

    It 'has NO hardcoded $loadedManifests[''Defender''] literal index (the de-Defender-ized load)' {
        $idx = $script:Ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.IndexExpressionAst] -and
                $n.Target -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $n.Target.VariablePath.UserPath -eq 'loadedManifests' -and
                $n.Index -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                $n.Index.Value -eq 'Defender'
            }, $true)
        @($idx).Count | Should -Be 0
    }

    It 'resolves the partition prefix through the Portal Registry (Get-XdrPortalConfig · not a literal "Defender_")' {
        $calls = $script:Ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.GetCommandName() -eq 'Get-XdrPortalConfig'
            }, $true)
        @($calls).Count | Should -BeGreaterThan 0 -Because 'the partition prefix + portal context must come from the registry, not a Defender literal'
    }
}
