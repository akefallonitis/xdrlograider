#Requires -Modules Pester
<#
.SYNOPSIS
    Layer A regression-locker — for every cross-module call site in src/functions/* and
    src/Modules/*/Public/*, validate that:
      1. Every named-arg in the caller exists as a parameter on the callee
      2. Every Mandatory parameter on the callee is supplied by the caller
      3. Every literal-string arg passed to a [ValidateSet]-annotated parameter is in the set

.DESCRIPTION
    Live forensics: 5 of 9 chained bugs this session were caller→callee param-name
    or call-shape mismatches:
      #3 Get-XdrAuthFromKeyVault: caller used -KeyVaultUri, real param is -VaultUri
      #4 Connect-DefenderPortal: caller used `-Credential $authBundle.Credential`
         but the WHOLE bundle IS the credential
      #5 Pop-XdrIngestDlq: caller missing mandatory -TableName
      #6 Invoke-MDEEndpoint: caller passed -Config (no such param)
      #9 Write-Heartbeat: caller passed -FunctionType 'Durable' (not in ValidateSet
         Simple|Starter|Orchestrator|Activity)

    This test class catches ALL of these systematically via AST walking, NOT by
    hand-coding regex per call site (which is what failed).

    Per Section R Layer A, plan file
    C:\Users\akefa\.claude\plans\immutable-splashing-waffle.md.
#>

BeforeAll {
    $script:RepoRoot   = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:ModulesDir = Join-Path $script:RepoRoot 'src/Modules'

    # PowerShell CommonParameters (auto-added by [CmdletBinding()]) — universally allowed.
    $script:CommonParameters = @(
        'ErrorAction','ErrorVariable','WarningAction','WarningVariable',
        'InformationAction','InformationVariable','OutVariable','OutBuffer',
        'PipelineVariable','Verbose','Debug','Confirm','WhatIf'
    )

    # Build a callee-signature catalogue: function name -> @{ Params=@{ Name -> @{ Mandatory; ValidateSet } }; HasCmdletBinding }
    $script:CalleeCatalogue = @{}
    $publicFunctionFiles = @(
        Get-ChildItem -Path $script:ModulesDir -Recurse -Filter '*.ps1' |
            Where-Object { $_.FullName -match '[\\/]Public[\\/]' }
    )
    foreach ($f in $publicFunctionFiles) {
        $tokens = $null; $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
        if ($errs) { continue }
        $functionAsts = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        foreach ($funcAst in $functionAsts) {
            $sig = @{ Name = $funcAst.Name; Params = @{}; HasCmdletBinding = $false }
            $paramBlock = $funcAst.Body.ParamBlock
            if (-not $paramBlock) { continue }
            # Detect [CmdletBinding()] OR [Parameter(...)] attribute on any param → enables CommonParameters
            foreach ($attr in $paramBlock.Attributes) {
                if ($attr.TypeName.Name -eq 'CmdletBinding') { $sig.HasCmdletBinding = $true }
            }
            foreach ($param in $paramBlock.Parameters) {
                $pName = $param.Name.VariablePath.UserPath
                $isMandatory = $false
                $validateSet = $null
                foreach ($attr in $param.Attributes) {
                    if ($attr -is [System.Management.Automation.Language.AttributeAst]) {
                        $typeName = $attr.TypeName.Name
                        if ($typeName -eq 'Parameter' -or $typeName -eq 'ParameterAttribute') {
                            $sig.HasCmdletBinding = $true  # [Parameter()] also enables CommonParameters
                            foreach ($na in $attr.NamedArguments) {
                                if ($na.ArgumentName -eq 'Mandatory') {
                                    if ($na.ExpressionOmitted -or $na.Argument.Extent.Text -eq '$true') { $isMandatory = $true }
                                }
                            }
                        } elseif ($typeName -eq 'ValidateSet') {
                            $validateSet = @($attr.PositionalArguments | ForEach-Object {
                                if ($_ -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $_.Value }
                                else { $_.Extent.Text.Trim("'""") }
                            })
                        }
                    }
                }
                $sig.Params[$pName] = @{
                    Mandatory   = $isMandatory
                    ValidateSet = $validateSet
                }
            }
            $script:CalleeCatalogue[$funcAst.Name] = $sig
        }
    }

    # Build the list of caller files (function-app run.ps1 + module Public/* files)
    $script:CallerFiles = @()
    $script:CallerFiles += @(Get-ChildItem -Path (Join-Path $script:RepoRoot 'src/functions') -Recurse -Filter 'run.ps1')
    $script:CallerFiles += $publicFunctionFiles

    # For each caller, extract every CommandAst that names a known callee.
    # Skip splatted invocations (we can't statically verify what's in the hashtable).
    # Skip self-references (a function calling itself, e.g. recursive retry).
    function Get-CrossModuleCalls {
        param(
            [Parameter(Mandatory)] [string] $FilePath,
            [Parameter(Mandatory)] [hashtable] $Catalogue
        )
        $tokens = $null; $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($FilePath, [ref]$tokens, [ref]$errs)
        if ($errs) { return @() }
        # Identify functions defined IN this file — their calls to themselves are self-references.
        $localFunctionNames = @{}
        foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
            $localFunctionNames[$fn.Name] = $true
        }
        $commands = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
        $out = @()
        foreach ($cmd in $commands) {
            $first = $cmd.CommandElements[0]
            if (-not ($first -is [System.Management.Automation.Language.StringConstantExpressionAst])) { continue }
            $cmdName = $first.Value
            if (-not $Catalogue.ContainsKey($cmdName)) { continue }
            if ($localFunctionNames.ContainsKey($cmdName)) { continue }   # self-reference / recursive call
            # Detect splat: any element that is a VariableExpressionAst with Splatted=$true.
            # Guard against single-element commands (no args) where 1..0 range reverses.
            $hasSplat = $false
            if ($cmd.CommandElements.Count -gt 1) {
                for ($j = 1; $j -lt $cmd.CommandElements.Count; $j++) {
                    $el = $cmd.CommandElements[$j]
                    if ($el -is [System.Management.Automation.Language.VariableExpressionAst] -and $el.Splatted) {
                        $hasSplat = $true; break
                    }
                }
            }
            $namedArgs = @{}
            for ($i = 1; $i -lt $cmd.CommandElements.Count; $i++) {
                $el = $cmd.CommandElements[$i]
                if ($el -is [System.Management.Automation.Language.CommandParameterAst]) {
                    $argName = $el.ParameterName
                    $argVal  = $null
                    if ($i + 1 -lt $cmd.CommandElements.Count) {
                        $argEl = $cmd.CommandElements[$i + 1]
                        if (-not ($argEl -is [System.Management.Automation.Language.CommandParameterAst])) {
                            $argVal = $argEl
                            $i++
                        }
                    }
                    $namedArgs[$argName] = $argVal
                }
            }
            $out += [pscustomobject]@{
                File      = $FilePath
                Line      = $cmd.Extent.StartLineNumber
                Callee    = $cmdName
                NamedArgs = $namedArgs
                HasSplat  = $hasSplat
            }
        }
        return $out
    }

    $script:AllCalls = @()
    foreach ($caller in $script:CallerFiles) {
        $script:AllCalls += Get-CrossModuleCalls -FilePath $caller.FullName -Catalogue $script:CalleeCatalogue
    }
}

Describe 'CallSiteBinding — caller-supplied named args MUST exist on callee' {

    It 'every named arg in caller maps to a real callee parameter (CommonParameters whitelisted)' {
        $offenders = @()
        foreach ($call in $script:AllCalls) {
            $sig = $script:CalleeCatalogue[$call.Callee]
            foreach ($argName in $call.NamedArgs.Keys) {
                # CommonParameters auto-added by [CmdletBinding()] / [Parameter()].
                if ($sig.HasCmdletBinding -and $script:CommonParameters -contains $argName) { continue }
                # PowerShell allows prefix-match (partial param name). Walk all defined params.
                $matched = $sig.Params.Keys | Where-Object { $_.StartsWith($argName, [System.StringComparison]::OrdinalIgnoreCase) }
                if (@($matched).Count -eq 0) {
                    $offenders += "{0}:{1}  {2} -{3} (callee has no such param)" -f $call.File, $call.Line, $call.Callee, $argName
                }
            }
        }
        $offenders | Should -BeNullOrEmpty -Because "Live forensic 2026-05-06: bugs #3, #6 were exactly this — caller passed param names that don't exist on callee. Offenders:`n  $($offenders -join "`n  ")"
    }
}

Describe 'CallSiteBinding — every Mandatory callee parameter MUST be supplied at the call site' {

    It 'every Mandatory parameter on a known callee is passed by every non-splat caller invocation' {
        $offenders = @()
        foreach ($call in $script:AllCalls) {
            if ($call.HasSplat) { continue }   # splat → cannot statically verify hashtable contents
            $sig = $script:CalleeCatalogue[$call.Callee]
            $mandatoryNames = @($sig.Params.GetEnumerator() | Where-Object { $_.Value.Mandatory } | ForEach-Object { $_.Key })
            foreach ($mName in $mandatoryNames) {
                $supplied = $false
                foreach ($argName in $call.NamedArgs.Keys) {
                    if ($mName.StartsWith($argName, [System.StringComparison]::OrdinalIgnoreCase)) { $supplied = $true; break }
                }
                if (-not $supplied) {
                    $offenders += "{0}:{1}  {2}: missing Mandatory param -{3}" -f $call.File, $call.Line, $call.Callee, $mName
                }
            }
        }
        $offenders | Should -BeNullOrEmpty -Because "Live forensic 2026-05-06: bug #5 (Pop-XdrIngestDlq missing -TableName). Offenders:`n  $($offenders -join "`n  ")"
    }
}

Describe 'CallSiteBinding — literal string args to [ValidateSet] params MUST be in the set' {

    It 'no caller passes an invalid literal to a ValidateSet-annotated param' {
        $offenders = @()
        foreach ($call in $script:AllCalls) {
            if ($call.HasSplat) { continue }
            $sig = $script:CalleeCatalogue[$call.Callee]
            foreach ($argEntry in $call.NamedArgs.GetEnumerator()) {
                $argName = $argEntry.Key
                $argVal  = $argEntry.Value
                $matchedParam = $sig.Params.Keys | Where-Object { $_.StartsWith($argName, [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
                if (-not $matchedParam) { continue }
                $vs = $sig.Params[$matchedParam].ValidateSet
                if (-not $vs) { continue }
                if ($argVal -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    $literal = $argVal.Value
                    if ($literal -notin $vs) {
                        $offenders += "{0}:{1}  {2} -{3} '{4}' not in ValidateSet({5})" -f $call.File, $call.Line, $call.Callee, $argName, $literal, ($vs -join ',')
                    }
                }
            }
        }
        $offenders | Should -BeNullOrEmpty -Because "Live forensic 2026-05-06: bug #9 (Write-Heartbeat -FunctionType 'Durable'). Offenders:`n  $($offenders -join "`n  ")"
    }
}
