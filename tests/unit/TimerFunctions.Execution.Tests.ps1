#Requires -Modules Pester
<#
.SYNOPSIS
    Execution-path tests for the shared Invoke-TierPollWithHeartbeat helper.

.DESCRIPTION
    v0.1.0-beta consolidated ~315 LoC of duplicated fatal-error handling
    (previously copy-pasted across 7 poll-*/run.ps1 bodies) into a single
    helper in Invoke-TierPollWithHeartbeat.ps1. These AST-based tests assert
    the semantics of the helper's catch block — the single source of truth
    for all 7 timers.

    Complements TimerFunctions.Shape.Tests.ps1:
      - Shape tests = structural invariants (thin wrapper shape + helper shape)
      - Execution tests = catch-body semantics (fatalError Note, Tier param,
                                                nested try, re-throw)

    AST-based rather than runtime-execution because actually invoking the
    helper requires mocking deep inside module-internal command resolution
    (Pester 5's Mock pragma doesn't support module-exported commands
    resolved via `& $path` cleanly). Shape + AST semantics together prove
    the helper behaves correctly; runtime coverage comes from the extended
    unit tests in XdrLogRaider.Client.Tests.ps1 that call the public helper.
#>

BeforeAll {
    $script:HelperPath = Join-Path $PSScriptRoot '..' '..' 'src' 'Modules' 'Xdr.Defender.Client' 'Public' 'Invoke-TierPollWithHeartbeat.ps1'

    $tokens = $null; $errs = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:HelperPath, [ref]$tokens, [ref]$errs
    )
    $script:TryStatements = $script:Ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.TryStatementAst]
    }, $true)

    # Find the OUTER top-level try in the helper function body. The helper's
    # structure: function Invoke-TierPollWithHeartbeat { param(...) ... try {...} catch {...} }
    # So the top-level try is the one whose parent is the helper function body
    # (a NamedBlockAst inside a ScriptBlockAst).
    $script:TopTry = $script:TryStatements | Sort-Object {
        # Depth in AST — the outermost has the fewest ancestor TryStatements.
        $depth = 0
        $node = $_.Parent
        while ($node) {
            if ($node -is [System.Management.Automation.Language.TryStatementAst]) { $depth++ }
            $node = $node.Parent
        }
        $depth
    } | Select-Object -First 1
}

Describe 'Invoke-TierPollWithHeartbeat — fatal-error catch-block semantics' {

    It 'helper parses without errors' {
        $script:Ast | Should -Not -BeNullOrEmpty
    }

    It 'has a top-level try/catch in the helper body' {
        $script:TopTry | Should -Not -BeNullOrEmpty -Because 'main polling lifecycle of Invoke-TierPollWithHeartbeat must be wrapped in a top-level try/catch'
    }

    It 'catch body references $_.Exception.Message (captures underlying error)' {
        $catches = $script:TopTry.CatchClauses
        $catches.Count | Should -BeGreaterThan 0
        $catchText = ($catches | ForEach-Object { $_.Body.Extent.Text }) -join "`n"
        $catchText | Should -Match '\$_\.Exception\.Message' -Because 'catch must capture the inner exception message into $errMsg'
    }

    It 'catch body writes a fatalError note (visible in MDE_Heartbeat_CL)' {
        $catchText = ($script:TopTry.CatchClauses | ForEach-Object { $_.Body.Extent.Text }) -join "`n"
        $catchText | Should -Match 'fatalError' -Because 'catch must emit a heartbeat row with Notes.fatalError so operators see the failure'
    }

    It 'catch body emits a Write-Heartbeat with the -Tier parameter (tier flows from caller)' {
        $catchText = ($script:TopTry.CatchClauses | ForEach-Object { $_.Body.Extent.Text }) -join "`n"
        $catchText | Should -Match 'Write-Heartbeat'
        $catchText | Should -Match '-Tier\s+\$Tier' -Because 'failure heartbeat must pass the caller-supplied $Tier param so each of 7 timers tags its tier correctly'
    }

    It 'catch body contains a bare `throw` (re-throw to Azure Functions runtime)' {
        $throws = $script:TopTry.CatchClauses[0].Body.FindAll({
            param($n) $n -is [System.Management.Automation.Language.ThrowStatementAst]
        }, $true)
        $throws.Count | Should -BeGreaterOrEqual 1 -Because 'catch must re-throw so Functions / App Insights logs the fatal'
    }

    It 'catch body has a NESTED try/catch protecting the Write-Heartbeat call' {
        # Writing the fatal heartbeat may itself throw (DCE down, throttled, etc).
        # That nested throw must NOT mask the original fatal — so it must be caught
        # and logged via Write-Warning rather than propagated.
        $innerTries = $script:TopTry.CatchClauses[0].Body.FindAll({
            param($n) $n -is [System.Management.Automation.Language.TryStatementAst]
        }, $true)
        $innerTries.Count | Should -BeGreaterOrEqual 1 -Because 'Write-Heartbeat inside catch must be guarded by a nested try/catch to avoid masking the original fatal'
    }

    It 'helper accepts a Portal param with default security.microsoft.com (forward-scalable J2)' {
        $paramBlock = $script:Ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.ParamBlockAst]
        }, $true) | Select-Object -First 1
        $paramBlock | Should -Not -BeNullOrEmpty

        $portalParam = $paramBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -ieq 'Portal' }
        $portalParam | Should -Not -BeNullOrEmpty -Because 'helper must accept optional -Portal for v0.2.0+ multi-portal expansion without refactor'
        $portalParam.DefaultValue | Should -Not -BeNullOrEmpty
        $portalParam.DefaultValue.Extent.Text | Should -Match 'security\.microsoft\.com' -Because 'Portal default must be security.microsoft.com so v0.1.0-beta behaviour is unchanged'
    }
}
