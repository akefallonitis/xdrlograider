#Requires -Modules Pester

# AST-based shape tests for the 7 timer-function bodies.
# Asserts each run.ps1 has the canonical skeleton: param($Timer), strict mode,
# auth-gate call, Connect-MDEPortal, Invoke-MDETierPoll with the correct tier,
# Write-Heartbeat on both gated + main paths, and no references to legacy
# functions that were removed in the module consolidation.
#
# Parse-only — no function bodies are executed.

BeforeDiscovery {
    # Pester 5 Discovery phase: plain `$FooVar = ...` is fine here — the -ForEach
    # on Describe/It picks these up at discovery. Don't use `$script:` here.
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
    # Pester 5: BeforeDiscovery `$script:` vars do NOT survive into the Run phase,
    # so re-set anything the It blocks need.
    $script:RemovedFunctions = @(
        'Exchange-SccauthCookie',
        'Get-LaraAuthSelfTestFlag',
        'Invoke-LaraTierPoll',
        'Connect-LaraPortal'
    )

    # Parse a run.ps1 once and return both the AST and all command calls flattened.
    function script:Get-TimerFunctionAst {
        param([string]$RunPs1Path)

        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $RunPs1Path, [ref]$tokens, [ref]$parseErrors
        )
        [pscustomobject]@{
            Ast         = $ast
            ParseErrors = $parseErrors
            Commands    = $ast.FindAll({
                param($n) $n -is [System.Management.Automation.Language.CommandAst]
            }, $true)
        }
    }

    # Helper: does ANY command in the AST invoke a given name (case-insensitive)?
    function script:Test-AstCallsCommand {
        param($Commands, [string]$Name)
        foreach ($c in $Commands) {
            $first = $c.CommandElements[0]
            if ($first -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                $first.Value -ieq $Name) { return $true }
        }
        return $false
    }

    # Helper: find all calls to a command and return the value of a parameter. Returns
    # array of parameter values observed across all calls (useful to assert tier).
    function script:Get-AstCommandParameterValues {
        param($Commands, [string]$CommandName, [string]$ParameterName)

        $values = @()
        foreach ($c in $Commands) {
            $first = $c.CommandElements[0]
            if (-not ($first -is [System.Management.Automation.Language.StringConstantExpressionAst])) { continue }
            if ($first.Value -ine $CommandName) { continue }

            # Walk CommandElements[1..n] pairwise looking for "-Name" + value.
            for ($i = 1; $i -lt $c.CommandElements.Count; $i++) {
                $el = $c.CommandElements[$i]
                if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and
                    $el.ParameterName -ieq $ParameterName) {
                    # Parameter argument can be: (a) on the same element as Argument, or
                    # (b) the NEXT element (classic -Param value separation).
                    if ($el.Argument) {
                        $values += $el.Argument.Extent.Text.Trim("'", '"')
                    } elseif ($i + 1 -lt $c.CommandElements.Count) {
                        $next = $c.CommandElements[$i + 1]
                        if ($next -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                            $values += $next.Value
                        } elseif ($next) {
                            $values += $next.Extent.Text.Trim("'", '"')
                        }
                    }
                }
            }
        }
        ,$values
    }
}

Describe 'Timer function shape: <Folder>' -ForEach $TimerCases {

    BeforeAll {
        $script:FunctionDir  = Join-Path $script:FunctionsRoot $Folder
        $script:RunPath      = Join-Path $script:FunctionDir 'run.ps1'
        $script:FunctionJson = Join-Path $script:FunctionDir 'function.json'

        $script:Parsed = script:Get-TimerFunctionAst -RunPs1Path $script:RunPath
    }

    It 'run.ps1 exists' {
        Test-Path $script:RunPath | Should -BeTrue
    }

    It 'parses without syntax errors' {
        $script:Parsed.ParseErrors | Should -BeNullOrEmpty
    }

    It 'has a top-level param($Timer) block' {
        $paramBlock = $script:Parsed.Ast.ParamBlock
        $paramBlock | Should -Not -BeNullOrEmpty
        $paramNames = $paramBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }
        $paramNames | Should -Contain 'Timer'
    }

    It 'sets $ErrorActionPreference = Stop' {
        $asgmts = $script:Parsed.Ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst]
        }, $true)
        $hit = $asgmts | Where-Object {
            $_.Left.Extent.Text -match '\$ErrorActionPreference' -and
            $_.Right.Extent.Text -match "'Stop'|`"Stop`""
        }
        $hit | Should -Not -BeNullOrEmpty
    }

    It 'enables Set-StrictMode -Version Latest' {
        script:Test-AstCallsCommand -Commands $script:Parsed.Commands -Name 'Set-StrictMode' | Should -BeTrue
    }

    It 'calls Get-XdrAuthSelfTestFlag (auth gate present)' {
        script:Test-AstCallsCommand -Commands $script:Parsed.Commands -Name 'Get-XdrAuthSelfTestFlag' | Should -BeTrue
    }

    It 'calls Connect-MDEPortal' {
        script:Test-AstCallsCommand -Commands $script:Parsed.Commands -Name 'Connect-MDEPortal' | Should -BeTrue
    }

    It 'calls Get-MDEAuthFromKeyVault' {
        script:Test-AstCallsCommand -Commands $script:Parsed.Commands -Name 'Get-MDEAuthFromKeyVault' | Should -BeTrue
    }

    It "calls Invoke-MDETierPoll with -Tier '<Tier>'" {
        $values = script:Get-AstCommandParameterValues `
            -Commands $script:Parsed.Commands `
            -CommandName 'Invoke-MDETierPoll' `
            -ParameterName 'Tier'
        $values | Should -Not -BeNullOrEmpty
        $values | Should -Contain $Tier
    }

    It 'calls Write-Heartbeat on BOTH the gated and main paths (at least 2 calls)' {
        $calls = @($script:Parsed.Commands | Where-Object {
            $_.CommandElements[0] -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $_.CommandElements[0].Value -ieq 'Write-Heartbeat'
        })
        $calls.Count | Should -BeGreaterOrEqual 2
    }

    It 'does not reference any removed / legacy Lara* function' {
        $callsByName = $script:Parsed.Commands |
            ForEach-Object {
                $first = $_.CommandElements[0]
                if ($first -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $first.Value }
            } | Sort-Object -Unique

        $leakage = $callsByName | Where-Object { $_ -in $script:RemovedFunctions }
        $leakage | Should -BeNullOrEmpty -Because "timer body still references legacy helpers: $($leakage -join ', ')"
    }

    It 'has a function.json sibling' {
        Test-Path $script:FunctionJson | Should -BeTrue
    }

    It 'function.json declares a timerTrigger with a non-empty schedule' {
        $fn = Get-Content $script:FunctionJson -Raw | ConvertFrom-Json
        $binding = $fn.bindings | Where-Object { $_.type -eq 'timerTrigger' } | Select-Object -First 1
        $binding | Should -Not -BeNullOrEmpty
        $binding.name | Should -Be 'Timer'
        $binding.schedule | Should -Not -BeNullOrEmpty
        # NCRONTAB used by Azure Functions has 6 space-separated fields.
        ($binding.schedule -split '\s+').Count | Should -Be 6
    }
}
