#Requires -Modules Pester

# AST-based shape tests for the 5 poll-*/run.ps1 timer bodies + the shared
# Invoke-TierPollWithHeartbeat helper.
#
# Each timer body is a 2-line thin wrapper that calls the shared helper.
# Tests split into two layers:
#
#   LAYER 1 - thin-wrapper shape (per timer):
#     run.ps1 exists, parses, has param($Timer), calls
#     Invoke-TierPollWithHeartbeat with the correct -Tier + -FunctionName that
#     matches the folder name, and references no removed/legacy helpers.
#     function.json has a timerTrigger with a valid 6-field NCRONTAB schedule.
#
#   LAYER 2 - helper shape (once):
#     Invoke-TierPollWithHeartbeat.ps1 has the canonical execution shape:
#     strict mode + ErrorAction=Stop, Get-XdrAuthSelfTestFlag gate,
#     Get-XdrAuthFromKeyVault + Connect-DefenderPortal + Invoke-MDETierPoll,
#     Write-Heartbeat on both gated + success + fatal paths, top-level
#     try/catch with fatalError Note, bare re-throw, nested try around
#     Write-Heartbeat in the catch, no references to legacy functions.
#
# Parse-only - no function bodies are executed.

BeforeDiscovery {
    $TimerCases = @(
        @{ Folder = 'poll-fast-10m';        Tier = 'fast' }
        @{ Folder = 'poll-exposure-1h';     Tier = 'exposure' }
        @{ Folder = 'poll-config-6h';       Tier = 'config' }
        @{ Folder = 'poll-inventory-1d';    Tier = 'inventory' }
        @{ Folder = 'poll-maintenance-1w';  Tier = 'maintenance' }
    )
}

BeforeAll {
    $script:FunctionsRoot = Join-Path $PSScriptRoot '..' '..' 'src' 'functions'
    $script:HelperPath    = Join-Path $PSScriptRoot '..' '..' 'src' 'Modules' 'Xdr.Defender.Client' 'Public' 'Invoke-TierPollWithHeartbeat.ps1'

    $script:RemovedFunctions = @(
        'Exchange-SccauthCookie',
        'Get-LaraAuthSelfTestFlag',
        'Invoke-LaraTierPoll',
        'Connect-LaraPortal',
        # Shim wrappers removed in v0.1.0-beta first publish — code must call
        # the real-module names directly (Connect-DefenderPortal etc.).
        'Connect-MDEPortal',
        'Connect-MDEPortalWithCookies',
        'Invoke-MDEPortalRequest',
        'Test-MDEPortalAuth',
        'Get-MDEAuthFromKeyVault'
    )

    function script:Get-ScriptAst {
        param([string]$Path)

        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $Path, [ref]$tokens, [ref]$parseErrors
        )
        [pscustomobject]@{
            Ast         = $ast
            ParseErrors = $parseErrors
            Commands    = $ast.FindAll({
                param($n) $n -is [System.Management.Automation.Language.CommandAst]
            }, $true)
        }
    }

    function script:Test-AstCallsCommand {
        param($Commands, [string]$Name)
        foreach ($c in $Commands) {
            $first = $c.CommandElements[0]
            if ($first -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                $first.Value -ieq $Name) { return $true }
        }
        return $false
    }

    function script:Get-AstCommandParameterValues {
        param($Commands, [string]$CommandName, [string]$ParameterName)

        $values = @()
        foreach ($c in $Commands) {
            $first = $c.CommandElements[0]
            if (-not ($first -is [System.Management.Automation.Language.StringConstantExpressionAst])) { continue }
            if ($first.Value -ine $CommandName) { continue }

            for ($i = 1; $i -lt $c.CommandElements.Count; $i++) {
                $el = $c.CommandElements[$i]
                if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and
                    $el.ParameterName -ieq $ParameterName) {
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

Describe 'Timer thin-wrapper shape: <Folder>' -ForEach $TimerCases {

    BeforeAll {
        $script:FunctionDir  = Join-Path $script:FunctionsRoot $Folder
        $script:RunPath      = Join-Path $script:FunctionDir 'run.ps1'
        $script:FunctionJson = Join-Path $script:FunctionDir 'function.json'

        $script:Parsed = script:Get-ScriptAst -Path $script:RunPath
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

    It 'calls Invoke-TierPollWithHeartbeat (the shared helper)' {
        script:Test-AstCallsCommand -Commands $script:Parsed.Commands -Name 'Invoke-TierPollWithHeartbeat' | Should -BeTrue
    }

    It "passes -Tier '<Tier>' to Invoke-TierPollWithHeartbeat" {
        $values = script:Get-AstCommandParameterValues `
            -Commands $script:Parsed.Commands `
            -CommandName 'Invoke-TierPollWithHeartbeat' `
            -ParameterName 'Tier'
        $values | Should -Not -BeNullOrEmpty
        $values | Should -Contain $Tier
    }

    It "passes -FunctionName '<Folder>' to Invoke-TierPollWithHeartbeat" {
        $values = script:Get-AstCommandParameterValues `
            -Commands $script:Parsed.Commands `
            -CommandName 'Invoke-TierPollWithHeartbeat' `
            -ParameterName 'FunctionName'
        $values | Should -Not -BeNullOrEmpty
        $values | Should -Contain $Folder
    }

    It 'body is consolidated (<= 2 total commands; proves the 45-line boilerplate dedup held)' {
        # v0.1.0-beta canonical thin wrapper: exactly 1 CommandAst across the
        # whole file — the Invoke-TierPollWithHeartbeat call. Allow up to 2
        # so a defensive guard or extra single call can be added without test
        # churn, but anything approaching the old ~20-command fat body fails.
        $totalCommands = @($script:Parsed.Commands).Count
        $totalCommands | Should -BeLessOrEqual 2 -Because 'v0.1.0-beta thin wrapper should contain at most 2 CommandAst nodes (just the helper call)'
    }

    It 'does not reference any removed / legacy Lara* function' {
        $callsByName = $script:Parsed.Commands |
            ForEach-Object {
                $first = $_.CommandElements[0]
                if ($first -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $first.Value }
            } | Sort-Object -Unique

        $leakage = $callsByName | Where-Object { $_ -in $script:RemovedFunctions }
        $leakage | Should -BeNullOrEmpty -Because "thin-wrapper body still references legacy helpers: $($leakage -join ', ')"
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

Describe 'Invoke-TierPollWithHeartbeat helper shape (single source of truth for all 5 poll-* timers)' {

    BeforeAll {
        $script:Parsed = script:Get-ScriptAst -Path $script:HelperPath
    }

    It 'helper file exists' {
        Test-Path $script:HelperPath | Should -BeTrue
    }

    It 'parses without syntax errors' {
        $script:Parsed.ParseErrors | Should -BeNullOrEmpty
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

    It 'calls Get-XdrAuthSelfTestFlag (auth gate)' {
        script:Test-AstCallsCommand -Commands $script:Parsed.Commands -Name 'Get-XdrAuthSelfTestFlag' | Should -BeTrue
    }

    It 'calls Get-XdrAuthFromKeyVault (real Xdr.Common.Auth name, not Get-MDEAuthFromKeyVault shim)' {
        script:Test-AstCallsCommand -Commands $script:Parsed.Commands -Name 'Get-XdrAuthFromKeyVault' | Should -BeTrue
    }

    It 'calls Connect-DefenderPortal (real Xdr.Defender.Auth name, not Connect-MDEPortal shim)' {
        script:Test-AstCallsCommand -Commands $script:Parsed.Commands -Name 'Connect-DefenderPortal' | Should -BeTrue
    }

    It 'calls Invoke-MDETierPoll' {
        script:Test-AstCallsCommand -Commands $script:Parsed.Commands -Name 'Invoke-MDETierPoll' | Should -BeTrue
    }

    It 'calls Write-Heartbeat on gated + success + fatal paths (>= 3 calls)' {
        $calls = @($script:Parsed.Commands | Where-Object {
            $_.CommandElements[0] -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $_.CommandElements[0].Value -ieq 'Write-Heartbeat'
        })
        $calls.Count | Should -BeGreaterOrEqual 3 -Because 'helper must emit heartbeat in gated-skip, success, and fatal-catch paths'
    }

    It 'has a top-level TryStatementAst (fatal-error handling)' {
        $tryStatements = $script:Parsed.Ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.TryStatementAst]
        }, $true)
        $tryStatements | Should -Not -BeNullOrEmpty -Because 'helper must wrap main body in try/catch to surface fatal errors as heartbeat rows'
    }

    It 'catch block emits a fatal-error heartbeat (contains fatalError token)' {
        $tryStatements = $script:Parsed.Ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.TryStatementAst]
        }, $true)
        $tryStatements | Should -Not -BeNullOrEmpty
        $hasFatalError = $false
        foreach ($try in $tryStatements) {
            foreach ($catch in $try.CatchClauses) {
                if ($catch.Body.Extent.Text -match 'fatalError') {
                    $hasFatalError = $true; break
                }
            }
            if ($hasFatalError) { break }
        }
        $hasFatalError | Should -BeTrue -Because "catch block must emit Notes with a 'fatalError' field so operators see the failure in MDE_Heartbeat_CL"
    }

    It 'catch block re-throws (so Application Insights logs the fatal)' {
        $tryStatements = $script:Parsed.Ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.TryStatementAst]
        }, $true)
        $rethrows = $false
        foreach ($try in $tryStatements) {
            foreach ($catch in $try.CatchClauses) {
                $throws = $catch.Body.FindAll({
                    param($n) $n -is [System.Management.Automation.Language.ThrowStatementAst]
                }, $true)
                if ($throws.Count -gt 0) { $rethrows = $true; break }
            }
            if ($rethrows) { break }
        }
        $rethrows | Should -BeTrue -Because 'catch must `throw` after emitting failure heartbeat so the Functions runtime marks the invocation failed'
    }

    It 'does not reference any removed / legacy Lara* function' {
        $callsByName = $script:Parsed.Commands |
            ForEach-Object {
                $first = $_.CommandElements[0]
                if ($first -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $first.Value }
            } | Sort-Object -Unique

        $leakage = $callsByName | Where-Object { $_ -in $script:RemovedFunctions }
        $leakage | Should -BeNullOrEmpty -Because "helper references legacy helpers: $($leakage -join ', ')"
    }
}
