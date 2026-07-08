#Requires -Version 7.4
# V1 (§21.1) regression pin · the XdrDefenderRefresh dispatch must be StrictMode-safe for OPTIONAL manifest keys.
# Empirically verified: under `Set-StrictMode -Version Latest` (which run.ps1 sets), dot-access of a MISSING
# hashtable key THROWS PropertyNotFoundException — and the op-enumeration foreach was NOT wrapped in a per-op
# try/catch, so a single malformed entry (a missing optional key, once the category grows past one op) aborted the
# WHOLE cycle → 0 dispatch → 0 rows (the crash-loop class). This AST-parses the REAL run.ps1 and asserts:
#   (1) ZERO dot-access of the known-optional keys on $op (they must be indexer $op['Key'] → $null, not a throw),
#   (2) the per-Op dispatch body is inside a try/catch (one bad entry cannot zero the cycle).
# Reverting either fix turns this RED. This pins structure on the actual file (not a string-grep, not a replica).

Describe 'XdrDefenderRefresh · StrictMode-safe optional-key dispatch (V1)' {
    BeforeAll {
        $script:Repo   = (Resolve-Path "$PSScriptRoot\..\..\..").Path
        $script:RunPs1 = Join-Path $script:Repo 'src\functions\XdrDefenderRefresh\run.ps1'
        $errs = $null
        $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:RunPs1, [ref]$null, [ref]$errs)
        $script:ParseErrors = $errs
    }

    It 'run.ps1 exists and parses with zero errors' {
        Test-Path $script:RunPs1 | Should -BeTrue
        $script:ParseErrors | Should -BeNullOrEmpty
    }

    It 'has ZERO dot-access of optional manifest keys on $op (StrictMode would throw on a missing key · must be indexer)' {
        $optional = @('RequiresProducts', 'Cadence', 'DcrImmutableIdEnvVar')
        $dotHits = $script:Ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.MemberExpressionAst] -and
                $n.Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $n.Expression.VariablePath.UserPath -eq 'op' -and
                $n.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                $optional -contains $n.Member.Value
            }, $true)
        @($dotHits).Count | Should -Be 0
    }

    It 'wraps the per-Op dispatch body in a try/catch (a single bad entry cannot abort the whole cycle)' {
        $tryStatements = $script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] }, $true)
        $hasDispatchTry = $false
        foreach ($t in $tryStatements) {
            $bodyText = $t.Body.Extent.Text
            if ($bodyText -match 'Test-XdrRequiresProducts' -and $bodyText -match '\$entries \+= \$entry') { $hasDispatchTry = $true; break }
        }
        $hasDispatchTry | Should -BeTrue
    }
}
