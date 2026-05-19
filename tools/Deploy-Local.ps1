#Requires -Version 7.4
<#
.SYNOPSIS
    az deployment group create wrapper. Validates ARM offline first, then deploys.

.DESCRIPTION
    Reads SP credentials from tests/.env.local (or interactive az login).
    Prompts for SA secrets (UPN/password/TOTP) at runtime if not provided.
    Validates ARM with az deployment group validate BEFORE deploying.

.PARAMETER ResourceGroup
    Connector resource group (will be created if it does not exist).

.PARAMETER WorkspaceResourceId
    Full ARM resource ID of the Sentinel-enabled workspace.

.PARAMETER ProjectPrefix
    Default xdrlr.

.PARAMETER ReleaseTag
    GitHub release tag for WEBSITE_RUN_FROM_PACKAGE. Default 'latest'.

.PARAMETER WhatIf
    Run `az deployment group what-if` only — no deploy.

.EXAMPLE
    pwsh ./tools/Deploy-Local.ps1 -ResourceGroup rg-xdrlr-test -WorkspaceResourceId /subscriptions/.../workspaces/law-xdrlr-test
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$WorkspaceResourceId,
    [string]$ProjectPrefix = 'xdrlr',
    [string]$ReleaseTag    = 'latest',
    [string]$PlanSku       = 'Y1',
    [string]$EnvFile       = (Join-Path $PSScriptRoot '..\tests\.env.local'),
    [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Load env.local
if (Test-Path $EnvFile) {
    Get-Content $EnvFile | Where-Object { $_ -match '^\s*[^#].+=' } | ForEach-Object {
        $k, $v = $_ -split '=', 2
        Set-Item -Path "env:$($k.Trim())" -Value $v.Trim()
    }
}

# Verify az is logged in
$account = az account show -o json 2>$null | ConvertFrom-Json
if (-not $account) {
    throw "az not logged in. Run 'az login --use-device-code' first."
}
Write-Host "az subscription: $($account.id) ($($account.name))" -ForegroundColor DarkGray
Write-Host "az identity:     $($account.user.name) ($($account.user.type))" -ForegroundColor DarkGray

# Derive workspace location from the workspace resource
$ws = az resource show --ids $WorkspaceResourceId --query '{name:name, location:location, rg:resourceGroup}' -o json | ConvertFrom-Json
if (-not $ws) { throw "Workspace not found: $WorkspaceResourceId" }
Write-Host "Workspace: $($ws.name) ($($ws.location))" -ForegroundColor Cyan

# Ensure RG exists
$rg = az group show -n $ResourceGroup -o json 2>$null | ConvertFrom-Json
if (-not $rg) {
    Write-Host "Creating RG $ResourceGroup in $($ws.location)..." -ForegroundColor Yellow
    az group create -n $ResourceGroup -l $ws.location -o none
}

# SA secrets — from env.local or interactive prompt
$upn = $env:XDRLR_TEST_UPN
if (-not $upn) { $upn = Read-Host "Service account UPN" }
$pwd = $env:XDRLR_TEST_PASSWORD
if (-not $pwd) { $pwd = Read-Host "Service account password" -AsSecureString | ConvertFrom-SecureString -AsPlainText }
$totp = $env:XDRLR_TEST_TOTP_SECRET
if (-not $totp) { $totp = Read-Host "TOTP base32 seed" -AsSecureString | ConvertFrom-SecureString -AsPlainText }

$template      = Join-Path $PSScriptRoot '..\deploy\mainTemplate.json'
$deploymentName = "xdrlr-mvp-" + (Get-Date -Format 'yyyyMMddHHmmss')

$parameters = @{
    projectPrefix            = @{ value = $ProjectPrefix }
    workspaceResourceId      = @{ value = $WorkspaceResourceId }
    workspaceLocation        = @{ value = $ws.location }
    serviceAccountUpn        = @{ value = $upn }
    serviceAccountPassword   = @{ value = $pwd }
    serviceAccountTotpSecret = @{ value = $totp }
    releaseTag               = @{ value = $ReleaseTag }
    planSku                  = @{ value = $PlanSku }
}
$paramFile = New-TemporaryFile
@{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = $parameters } |
    ConvertTo-Json -Depth 10 | Set-Content -Path $paramFile -Encoding UTF8

try {
    Write-Host "`n=== ARM validate ===" -ForegroundColor Cyan
    az deployment group validate -g $ResourceGroup --template-file $template --parameters "@$paramFile" -o none
    if ($LASTEXITCODE -ne 0) { throw "az deployment group validate failed (exit $LASTEXITCODE)" }
    Write-Host "Validate: OK" -ForegroundColor Green

    if ($WhatIfOnly) {
        Write-Host "`n=== ARM what-if (no deploy) ===" -ForegroundColor Cyan
        az deployment group what-if -g $ResourceGroup --template-file $template --parameters "@$paramFile"
        return
    }

    if ($PSCmdlet.ShouldProcess($ResourceGroup, "Deploy XdrLogRaider MVP")) {
        Write-Host "`n=== Deploying (~8-12 min) ===" -ForegroundColor Cyan
        az deployment group create -g $ResourceGroup -n $deploymentName `
            --template-file $template --parameters "@$paramFile" -o json | ConvertFrom-Json | ForEach-Object {
                Write-Host "Outputs:" -ForegroundColor Green
                $_.properties.outputs | ConvertTo-Json -Depth 5
            }
    }
} finally {
    Remove-Item $paramFile -Force -ErrorAction SilentlyContinue
    Remove-Variable pwd, totp -ErrorAction SilentlyContinue
}
