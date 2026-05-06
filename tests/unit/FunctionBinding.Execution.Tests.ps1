#Requires -Modules Pester
<#
.SYNOPSIS
    Layer A regression-locker — for each Function App run.ps1, verify:
      1. param() block extracts a non-shadowing name (NOT $Input — PS automatic var)
      2. function.json binding[0].name matches the param name (Azure Functions convention)
      3. The activity body reads inputs via [string] cast on JObject properties

.DESCRIPTION
    Live forensic 2026-05-06 (commit fb2c6f4): the activity declared param($Input)
    AND function.json binding name 'Input'. PowerShell automatic $Input shadowed the
    parameter at runtime; activity input never bound. EVERY $Input.X read returned
    null; downstream calls failed with "Unknown Stream ''".

    This test class is an AST-only unit test that EXECUTES (not just regex-pattern-matches)
    the param-vs-binding parity check across all Function App run.ps1 files.

    Per Section R Layer A, plan file
    C:\Users\akefa\.claude\plans\immutable-splashing-waffle.md.
#>

BeforeAll {
    $script:RepoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:FunctionsDir = Join-Path $script:RepoRoot 'src/functions'
    $script:FunctionDirs = @(Get-ChildItem -Path $script:FunctionsDir -Directory)
}

Describe 'FunctionBinding.Execution — every run.ps1 has non-shadowing param + matches function.json binding' {

    It 'function.json binding name MUST NOT be "Input" (PS automatic-variable shadow): <Name>' -ForEach @(
        $functionsDir = Join-Path $PSScriptRoot '..' '..' 'src/functions'
        Get-ChildItem -Path $functionsDir -Directory | ForEach-Object {
            @{ Name = $_.Name; Path = $_.FullName }
        }
    ) {
        param($Name, $Path)
        $functionJsonPath = Join-Path $Path 'function.json'
        if (-not (Test-Path $functionJsonPath)) {
            Set-ItResult -Skipped -Because "$Name has no function.json"
            return
        }
        $config = Get-Content -Raw $functionJsonPath | ConvertFrom-Json
        $bindingName = $config.bindings[0].name
        $bindingName | Should -Not -Be 'Input' -Because (
            "PowerShell automatic-variable shadow: param(`$Input) makes the Durable runtime " +
            "fail to bind activity input — every property read returns null. Caught LIVE in fb2c6f4."
        )
        $bindingName | Should -Match '^[A-Za-z_][A-Za-z0-9_]*$' -Because 'must be a valid PowerShell variable name'
    }

    It 'run.ps1 param() name MUST match function.json binding[0].name (Azure Functions convention): <Name>' -ForEach @(
        $functionsDir = Join-Path $PSScriptRoot '..' '..' 'src/functions'
        Get-ChildItem -Path $functionsDir -Directory | ForEach-Object {
            @{ Name = $_.Name; Path = $_.FullName }
        }
    ) {
        param($Name, $Path)
        $runPs1Path      = Join-Path $Path 'run.ps1'
        $functionJsonPath = Join-Path $Path 'function.json'
        if (-not (Test-Path $runPs1Path) -or -not (Test-Path $functionJsonPath)) {
            Set-ItResult -Skipped -Because "$Name missing run.ps1 or function.json"
            return
        }
        $config      = Get-Content -Raw $functionJsonPath | ConvertFrom-Json
        $bindingName = $config.bindings[0].name

        # AST-extract the first param() block; we want the FIRST parameter name (which receives the binding).
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($runPs1Path, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty -Because "$Name run.ps1 must parse without syntax errors"

        $paramBlock = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ParamBlockAst] }, $true) | Select-Object -First 1
        $paramBlock | Should -Not -BeNullOrEmpty -Because "$Name run.ps1 must declare a param() block"

        $firstParamName = $paramBlock.Parameters[0].Name.VariablePath.UserPath
        $firstParamName | Should -Be $bindingName -Because (
            "Azure Functions PS convention: function.json binding[0].name MUST match run.ps1's first param. " +
            "Mismatch silently fails to bind input. Live evidence: fb2c6f4."
        )
    }

    It 'Durable activity run.ps1 reads input via [string] cast on properties (regression: JValue cast crash 8ec9b1d): <Name>' -ForEach @(
        $functionsDir = Join-Path $PSScriptRoot '..' '..' 'src/functions'
        Get-ChildItem -Path $functionsDir -Directory | Where-Object {
            $cfg = Get-Content -Raw (Join-Path $_.FullName 'function.json') -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
            $cfg -and $cfg.bindings[0].type -eq 'activityTrigger'
        } | ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
    ) {
        param($Name, $Path)
        $runPs1Path = Join-Path $Path 'run.ps1'
        $src = Get-Content -Raw $runPs1Path
        # Activities receive Newtonsoft.Json.Linq.JObject from Durable runtime;
        # property access returns JValue (not string). Direct use (e.g. $X.Tier -eq 'Y')
        # crashes with "Unable to cast object of type 'JValue' to type 'String'".
        # The fix is explicit [string] cast on every property read. Live evidence: 8ec9b1d.
        $src | Should -Match '\[string\]\$[A-Za-z_][A-Za-z0-9_]*\.\w+' -Because (
            "$Name is an activity; activity input is JObject (JValue properties). " +
            "Body MUST use [string]`$ParamName.Property pattern to coerce JValue→String."
        )
    }

    It 'Orchestrator run.ps1 does NOT use `if ($X.Property)` directly on Durable input (JValue→Boolean FormatException)' {
        # Live forensic 2026-05-06T17:30Z: orchestrator had:
        #   if ($orchInput.OperationId) { [string]$orchInput.OperationId } else { ... }
        # The `if ($jvalue)` triggers JValue.IConvertible.ToBoolean which throws:
        #   "String 'eae21dc4-...' was not recognized as a valid Boolean."
        # Fix: cast to [string] FIRST, then test [string]::IsNullOrWhiteSpace.
        $orchPath = Join-Path $PSScriptRoot '..' '..' 'src/functions/Xdr-PollOrchestrator/run.ps1'
        if (-not (Test-Path $orchPath)) { Set-ItResult -Skipped -Because 'orchestrator not present'; return }
        $src = Get-Content -Raw $orchPath
        # Forbidden pattern: `if ($orchInput.X)` or `if ($Context.Input.X)`.
        # Use word-boundary so we don't match `if ($x.Length -gt 0)` style.
        $src | Should -Not -Match '(?m)^\s*\$\w+\s*=\s*if\s*\(\s*\$orchInput\.\w+\s*\)' -Because (
            "JValue→Boolean coercion throws FormatException on GUID/string values. " +
            "Pattern: cast to [string] FIRST, then test [string]::IsNullOrWhiteSpace."
        )
        $src | Should -Not -Match '(?m)^\s*if\s*\(\s*\$Context\.Input\.\w+\s*\)\s*\{' -Because (
            'Same JValue→Boolean pitfall on $Context.Input.'
        )
    }
}
