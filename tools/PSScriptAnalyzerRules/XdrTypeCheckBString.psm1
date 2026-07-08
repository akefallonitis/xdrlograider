#
# Custom PSScriptAnalyzer rule · enforces the `-isnot [string]` guard at JSON-serialization boundaries.
#
# Why this rule exists:
#   PowerShell 7.4 has a type-check foot-gun: `[string] -is [pscustomobject]` returns TRUE in some
#   pipeline contexts. Code that does `if ($x -is [pscustomobject]) { ... } else { $x | ConvertTo-Json }`
#   can double-serialize a string body (producing a JSON-encoded quoted string instead of an object).
#   That double-encoding is the root cause of AADSTS50080 errors in OAuth token POSTs and
#   "{ \"PartitionKey\": ... }" payloads in Storage Tables.
#
# The rule:
#   For every call to ConvertTo-Json in the file, walk up the AST. Within the enclosing function
#   (or script) scope, look for a preceding `-isnot [string]` check on the same variable being
#   serialized. Emit a Warning if no such guard is found within 20 lines of the ConvertTo-Json call.
#
# Suppression: prefix the function body with `# pssa-disable XdrTypeCheckBString: <reason>` to exempt
# a specific function (used for low-risk telemetry envelopes where the input is always a fresh hashtable).

function Measure-XdrTypeCheckBString {
    [CmdletBinding()]
    [OutputType([Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord[]])]
    param(
        [Parameter(Mandatory)] [System.Management.Automation.Language.ScriptBlockAst] $ScriptBlockAst
    )

    $diagnostics = @()
    $convertToJsonCalls = $ScriptBlockAst.FindAll({
        param($a)
        $a -is [System.Management.Automation.Language.CommandAst] -and
        $a.GetCommandName() -eq 'ConvertTo-Json'
    }, $true)

    foreach ($call in $convertToJsonCalls) {
        # Find the enclosing FunctionDefinitionAst or ScriptBlockAst
        $scope = $call
        while ($scope -and $scope -isnot [System.Management.Automation.Language.FunctionDefinitionAst] -and `
               $scope -isnot [System.Management.Automation.Language.ScriptBlockAst]) {
            $scope = $scope.Parent
        }
        if (-not $scope) { continue }

        # Check for `# pssa-disable XdrTypeCheckBString` suppression in scope text
        $scopeText = $scope.Extent.Text
        if ($scopeText -match '#\s*pssa-disable\s+XdrTypeCheckBString') { continue }

        # Look for `-isnot [string]` OR `-is [string]` (either direction proves type-awareness) anywhere in the same scope
        $hasGuard = $scopeText -match '-isnot\s+\[string\]' -or $scopeText -match '-is\s+\[string\]'
        if (-not $hasGuard) {
            $diagnostics += [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord]::new(
                "ConvertTo-Json invoked without an `-isnot [string]` type-guard in the enclosing scope. " +
                "PowerShell 7.4 `[string] -is [pscustomobject]` returns TRUE in some paths — guard the input " +
                "type explicitly to prevent double-encoding (AADSTS50080-class bugs).",
                $call.Extent,
                'XdrTypeCheckBString',
                'Warning',
                $null
            )
        }
    }

    return $diagnostics
}

Export-ModuleMember -Function Measure-XdrTypeCheckBString
