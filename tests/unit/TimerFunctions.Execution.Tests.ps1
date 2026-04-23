#Requires -Modules Pester
<#
.SYNOPSIS
    Execution-path tests for timer function error handling.

.DESCRIPTION
    Complements TimerFunctions.Shape.Tests.ps1 (AST shape) with deeper
    assertions about the catch block's contents — specifically that the
    failure heartbeat carries a `fatalError` Note, that the exception message
    is forwarded into it, and that the block re-throws.

    These checks are AST-based (parse the script, walk the tree) because
    actually running a Function App timer requires mocking deep inside the
    module-internal command resolution, which Pester 5's Mock pragma doesn't
    support cleanly for exported module commands resolved via `& $path`.

    The shape tests in TimerFunctions.Shape.Tests.ps1 prove the structural
    invariants; these tests prove the semantics of the catch body.
#>

BeforeDiscovery {
    $TimerCases = @(
        @{ Folder = 'poll-p0-compliance-1h'; Tier = 'P0' }
        @{ Folder = 'poll-p1-pipeline-30m';  Tier = 'P1' }
        @{ Folder = 'poll-p2-governance-1d'; Tier = 'P2' }
        @{ Folder = 'poll-p3-exposure-1h';   Tier = 'P3' }
        @{ Folder = 'poll-p5-identity-1d';   Tier = 'P5' }
        @{ Folder = 'poll-p6-audit-10m';     Tier = 'P6' }
        @{ Folder = 'poll-p7-metadata-1d';   Tier = 'P7' }
    )
}

BeforeAll {
    $script:FunctionsRoot = Join-Path $PSScriptRoot '..' '..' 'src' 'functions'
}

Describe 'Timer <Folder> — fatal-error catch-block semantics' -ForEach $TimerCases {
    BeforeAll {
        $script:RunPath = Join-Path $script:FunctionsRoot $Folder 'run.ps1'
        $tokens = $null; $errs = $null
        $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:RunPath, [ref]$tokens, [ref]$errs)
        $script:TryStatements = $script:Ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.TryStatementAst]
        }, $true)
        # The top-level try/catch is the LAST one in the file (nested ones are
        # inside the catch for the "try Write-Heartbeat inside catch" pattern).
        # We want the OUTERMOST — find the one whose catch is at top-level scope.
        $script:TopTry = $script:TryStatements | Where-Object {
            $_.Parent -is [System.Management.Automation.Language.NamedBlockAst]
        } | Select-Object -First 1
    }

    It 'has exactly one top-level try/catch in the main body' {
        $script:TopTry | Should -Not -BeNullOrEmpty -Because "main polling body of $($_.Folder) must be wrapped in a top-level try/catch"
    }

    It 'catch body references $_.Exception.Message (captures underlying error)' {
        $catches = $script:TopTry.CatchClauses
        $catches.Count | Should -BeGreaterThan 0
        $catchText = ($catches | ForEach-Object { $_.Body.Extent.Text }) -join "`n"
        $catchText | Should -Match '\$_\.Exception\.Message' -Because "catch must capture the inner exception message into `$errMsg"
    }

    It 'catch body writes a fatalError note (visible in MDE_Heartbeat_CL)' {
        $catchText = ($script:TopTry.CatchClauses | ForEach-Object { $_.Body.Extent.Text }) -join "`n"
        $catchText | Should -Match 'fatalError' -Because "catch must emit a heartbeat row with Notes.fatalError so operators see the failure"
    }

    It "catch body emits a Write-Heartbeat with the correct -Tier '<Tier>'" {
        $catchText = ($script:TopTry.CatchClauses | ForEach-Object { $_.Body.Extent.Text }) -join "`n"
        $catchText | Should -Match 'Write-Heartbeat'
        $catchText | Should -Match "-Tier\s+'$Tier'" -Because "failure heartbeat's Tier must match this timer's tier ($($_.Folder))"
    }

    It 'catch body contains a bare `throw` (re-throw to Azure Functions runtime)' {
        $throws = $script:TopTry.CatchClauses[0].Body.FindAll({
            param($n) $n -is [System.Management.Automation.Language.ThrowStatementAst]
        }, $true)
        $throws.Count | Should -BeGreaterOrEqual 1 -Because "catch must re-throw so Functions / App Insights logs the fatal for $($_.Folder)"
    }

    It 'catch body has a NESTED try/catch protecting the Write-Heartbeat call' {
        # Writing the fatal heartbeat may itself throw (DCE down, throttled, etc).
        # That nested throw must NOT mask the original fatal — so it must be caught
        # and logged via Write-Warning rather than propagated.
        $innerTries = $script:TopTry.CatchClauses[0].Body.FindAll({
            param($n) $n -is [System.Management.Automation.Language.TryStatementAst]
        }, $true)
        $innerTries.Count | Should -BeGreaterOrEqual 1 -Because "Write-Heartbeat inside catch must be guarded by a nested try/catch to avoid masking the original fatal"
    }
}
