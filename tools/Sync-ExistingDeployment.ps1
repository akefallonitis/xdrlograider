# tools/Sync-ExistingDeployment.ps1
# Operator tool · Path-2 incremental ARM sync into the operator's EXISTING RG (non-destructive).
#
# Strategy: incrementally add per-Category resources (custom table + DCR + V3 Sentinel content)
# to operator's already-deployed RG WITHOUT bouncing the FA · cache-bust + incremental dependency chain.
#
# Discipline rule 18: NEVER az group delete · NEVER --no-wait on destructive ops.

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [Parameter(Mandatory)] [string] $TemplateFile,             # e.g. deploy/mainTemplate.json
    [Parameter(Mandatory)] [string] $ParametersFile,           # e.g. deploy/parameters.local.json
    [string] $DeploymentNamePrefix = 'xdrlr-sync',
    [switch] $WhatIfMode,
    [switch] $SkipFunctionAppUpdate
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path $TemplateFile)) { throw "Template not found: $TemplateFile" }
if (-not (Test-Path $ParametersFile)) { throw "Parameters not found: $ParametersFile" }

# Cache-bust deployment name (epoch-based · prod FA reuses same RG · unique deployment per call)
$epoch = [int][double]::Parse((Get-Date -UFormat %s))
$deploymentName = "${DeploymentNamePrefix}-${epoch}"

Write-Host "[Sync-ExistingDeployment] RG=$ResourceGroup · Deployment=$deploymentName"
Write-Host "[Sync-ExistingDeployment] Template=$TemplateFile · Params=$ParametersFile"
Write-Host "[Sync-ExistingDeployment] WhatIfMode=$($WhatIfMode.IsPresent)"

if ($WhatIfMode) {
    Write-Host "[Sync-ExistingDeployment] Running az deployment group what-if (no resource changes)"
    az deployment group what-if `
        --resource-group $ResourceGroup `
        --template-file $TemplateFile `
        --parameters "@$ParametersFile" `
        --name $deploymentName
    $code = $LASTEXITCODE
    Write-Host "[Sync-ExistingDeployment] what-if exit=$code"
    exit $code
}

Write-Host "[Sync-ExistingDeployment] Running az deployment group create (incremental mode default)"
az deployment group create `
    --resource-group $ResourceGroup `
    --template-file $TemplateFile `
    --parameters "@$ParametersFile" `
    --name $deploymentName `
    --mode Incremental

$rc = $LASTEXITCODE
if ($rc -ne 0) {
    Write-Error "[Sync-ExistingDeployment] az deployment group create exited $rc"
    exit $rc
}

if (-not $SkipFunctionAppUpdate) {
    Write-Host "[Sync-ExistingDeployment] Triggering FA restart (function-app deployment slot · profile re-runs · new modules/manifests load)"
    $fa = az resource list --resource-group $ResourceGroup --resource-type 'Microsoft.Web/sites' --query '[0].name' -o tsv 2>$null
    if ($fa) {
        Write-Host "[Sync-ExistingDeployment] Restarting FA $fa"
        az functionapp restart --resource-group $ResourceGroup --name $fa
    } else {
        Write-Warning "[Sync-ExistingDeployment] No Function App found in $ResourceGroup · skipping restart"
    }
}

Write-Host "[Sync-ExistingDeployment] DONE · verify via:"
Write-Host "    az deployment group show --resource-group $ResourceGroup --name $deploymentName --query properties.provisioningState"
Write-Host ('    az resource list --resource-group ' + $ResourceGroup + ' --query "[].{name:name, type:type}"')
exit 0
