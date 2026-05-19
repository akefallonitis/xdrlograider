# XdrCustomRules.psm1
#
# PSScriptAnalyzer custom rule for the one universal PowerShell foot-gun this
# project must guard against statically. Everything else is enforced via Pester
# contract tests on real artefacts (manifests, sentinelContent, ARM templates),
# not via defensive AST scans for bug classes from prior forks.
#
# B-25 (pscustomobject/string trap) stays static because it is the one universal
# PowerShell foot-gun: any project that does `$x -is [pscustomobject]` before
# ConvertTo-Json will double-encode strings (AADSTS50080 root cause for this
# connector's auth chain).
#
# Invoke via:
#   Invoke-ScriptAnalyzer -Path <file> -CustomRulePath tests/analyzer/XdrCustomRules.psm1

using namespace Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic
Set-StrictMode -Version Latest

function New-XdrDiagnostic {
    param(
        [Parameter(Mandatory)][string]$RuleName,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Extent,
        [string]$Severity = 'Error'
    )
    [PSCustomObject]@{
        Message  = $Message
        Extent   = $Extent.Extent
        RuleName = "XdrCustomRules\$RuleName"
        Severity = $Severity
    }
}

# -----------------------------------------------------------------------------
# B-25 trap: `... -is [pscustomobject]` without preceding `-isnot [string]`
#
# PowerShell auto-wraps every string in a PSObject; the naive `$x -is [pscustomobject]`
# returns TRUE for strings, so the naive caller invokes ConvertTo-Json on something
# already JSON, double-encoding the body and producing AADSTS50080 from ESTS.
#
# Detection: walks BinaryExpressionAst nodes with operator Is whose RHS names
# PSCustomObject. For each hit, looks back ~120 chars for a preceding
# `-isnot [string]` guard. If absent, emits an Error. Exempts this analyzer
# file + its own tests (where the pattern appears in regex/documentation).
# -----------------------------------------------------------------------------
function Measure-XdrNoPsCustomObjectStringTrap {
    [CmdletBinding()][OutputType([Object[]])]
    param([Parameter(Mandatory)][System.Management.Automation.Language.ScriptBlockAst]$ScriptBlockAst)

    $path = $ScriptBlockAst.Extent.File
    if ($path -and $path -match 'XdrCustomRules\.psm1$|XdrCustomRules\..*\.Tests\.ps1$') { return @() }
    if ($ScriptBlockAst.Parent) { return @() }

    $isExprs = $ScriptBlockAst.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.BinaryExpressionAst] -and
        $n.Operator -eq 'Is' -and
        $n.Right -is [System.Management.Automation.Language.TypeExpressionAst] -and
        $n.Right.TypeName.Name -match '^(System\.Management\.Automation\.)?PSCustomObject$'
    }, $true)

    $src = $ScriptBlockAst.Extent.Text
    $results = @()
    foreach ($expr in $isExprs) {
        $offset = $expr.Extent.StartOffset - $ScriptBlockAst.Extent.StartOffset
        $start  = [math]::Max(0, $offset - 120)
        $window = $src.Substring($start, $offset - $start)
        if ($window -notmatch '-isnot\s*\[string\]') {
            $results += New-XdrDiagnostic -RuleName 'XdrNoPsCustomObjectStringTrap' `
                -Message 'B-25: -is [pscustomobject] requires a preceding -isnot [string] guard (or strict CLR check via .GetType().FullName). Strings are PSObject-wrapped and will match this trap, causing JSON bodies to double-encode (root cause of AADSTS50080).' `
                -Extent $expr
        }
    }
    $results
}

Export-ModuleMember -Function Measure-XdrNoPsCustomObjectStringTrap
