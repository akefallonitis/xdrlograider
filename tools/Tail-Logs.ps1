#Requires -Version 7.4
<#
.SYNOPSIS
    Tails the Function App log stream.

.PARAMETER ResourceGroup
.PARAMETER FunctionApp  (optional; auto-resolves from latest deployment)

.EXAMPLE
    pwsh ./tools/Tail-Logs.ps1 -ResourceGroup rg-xdrlr-test
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [string]$FunctionApp
)

$ErrorActionPreference = 'Stop'
if (-not $FunctionApp) {
    # ITER4 S1 · portal Deploy-to-Azure default deployment-names don't contain 'xdrlr' · use FA RBAC pattern
    $FunctionApp = az functionapp list -g $ResourceGroup --query "[?kind=='functionapp,linux'] | [0].name" -o tsv
    if (-not $FunctionApp) { throw "No linux function app found in RG $ResourceGroup" }
}
Write-Host "Tailing $ResourceGroup / $FunctionApp ... (Ctrl-C to stop)" -ForegroundColor Cyan
az webapp log tail -g $ResourceGroup -n $FunctionApp
