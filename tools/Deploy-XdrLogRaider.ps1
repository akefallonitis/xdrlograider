#Requires -Modules Az.Accounts, Az.Resources
<#
.SYNOPSIS
    XdrLogRaider v0.1.0 GA — operator-facing one-shot ARM deployment.

.DESCRIPTION
    Equivalent to clicking the Deploy-to-Azure button in README.md, but from
    the command line. Pulls deployment parameters from the last successful
    deployment in the target RG (if any), so operators don't have to re-type
    Workspace ID / UPN / etc. Pass any explicit parameter to override.

    Operator must be Owner OR User Access Administrator on the target RG
    (the template includes 9 RBAC role-assignments — KV Secrets User, Storage
    Table Data Contributor, 7×Monitoring Metrics Publisher per DCR).

    AFTER deployment lands:
      pwsh tools/Initialize-XdrLogRaiderAuth.ps1 -KeyVaultName <kv-name>
      pwsh tools/Smoke-Deploy.ps1 -ConnectorResourceGroup XDRLOGRAIDER -WorkspaceCustomerId <ws-guid>

.PARAMETER ConnectorResourceGroup
    The RG that will hold the connector resources (FA, KV, Storage, AI, DCRs, DCE).
    Default: 'XDRLOGRAIDER'.

.PARAMETER WorkspaceResourceId
    Sentinel workspace ARM resource ID. Auto-discovered from prior deployment if absent.

.PARAMETER ServiceAccountUpn
    UPN of the service account that will authenticate to security.microsoft.com.
    Auto-discovered from prior deployment if absent.

.PARAMETER AuthMethod
    'credentials_totp' (default) or 'passkey' or 'direct_cookies' (test only).

.PARAMETER ProjectPrefix
    Lowercase resource-name prefix. Default 'xdrlr'.

.PARAMETER Env
    Environment marker. Default 'prod'.

.PARAMETER DeploymentName
    Custom deployment name. Default 'xdrlr-v0.1.0-ga-<timestamp>'.

.PARAMETER WhatIfPreview
    If set, runs ARM what-if instead of deploying.

.EXAMPLE
    pwsh tools/Deploy-XdrLogRaider.ps1
    # Re-uses parameters from the last successful deployment in 'XDRLOGRAIDER'.

.EXAMPLE
    pwsh tools/Deploy-XdrLogRaider.ps1 -ConnectorResourceGroup 'connector-rg' `
        -WorkspaceResourceId '/subscriptions/.../workspaces/<ws>' `
        -ServiceAccountUpn 'svc@contoso.com' `
        -AuthMethod 'credentials_totp'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]   $ConnectorResourceGroup = 'XDRLOGRAIDER',
    [string]   $WorkspaceResourceId,
    [string]   $ServiceAccountUpn,
    [ValidateSet('credentials_totp', 'passkey', 'direct_cookies')]
    [string]   $AuthMethod    = 'credentials_totp',
    [string]   $ProjectPrefix = 'xdrlr',
    [string]   $Env           = 'prod',
    [string]   $DeploymentName,
    [switch]   $WhatIfPreview,
    # CRITICAL: Re-deploy mode that does NOT touch KV secrets.
    # The ARM template's KV secret resources are conditional on
    # `length(parameters('servicePassword')) > 0` etc — empty SecureStrings
    # cause those resources to be skipped, preserving any existing secrets
    # already seeded via Initialize-XdrLogRaiderAuth.ps1.
    # USE THIS for any redeploy where secrets are already populated.
    [switch]   $SkipSecretSeeding,
    # Manual override only. NEVER pass non-empty SecureStrings unless
    # you intend to overwrite KV secrets.
    [securestring] $ServicePassword,
    [securestring] $TotpSeed,
    [securestring] $PasskeyJson
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$tplPath  = Join-Path $repoRoot 'deploy/compiled/mainTemplate.json'

if (-not (Test-Path $tplPath)) {
    throw "ARM template not found: $tplPath"
}

# Confirm Az context
$ctx = Get-AzContext -ErrorAction Stop
if (-not $ctx.Account) { throw "Not logged in. Run: Connect-AzAccount" }

Write-Host "===== XdrLogRaider v0.1.0 GA Deploy =====" -ForegroundColor Cyan
Write-Host "  Subscription : $($ctx.Subscription.Name) ($($ctx.Subscription.Id))"
Write-Host "  Tenant       : $($ctx.Tenant.Id)"
Write-Host "  Account      : $($ctx.Account.Id)"
Write-Host ""

# Confirm RG exists
$rg = Get-AzResourceGroup -Name $ConnectorResourceGroup -ErrorAction SilentlyContinue
if (-not $rg) {
    throw "Resource group '$ConnectorResourceGroup' not found. Create it first or pass -ConnectorResourceGroup <existing>."
}

# Pull last successful deployment to fill any unspecified params
if (-not $WorkspaceResourceId -or -not $ServiceAccountUpn) {
    $allDeploys = @(Get-AzResourceGroupDeployment -ResourceGroupName $ConnectorResourceGroup -ErrorAction SilentlyContinue)
    $lastDeploy = $allDeploys |
        Where-Object {
            $_.ProvisioningState -eq 'Succeeded' -and
            $null -ne $_.Parameters -and
            $_.Parameters.ContainsKey('existingWorkspaceId')
        } |
        Sort-Object Timestamp -Descending |
        Select-Object -First 1

    if ($lastDeploy) {
        Write-Host "Reusing parameters from last deployment: $($lastDeploy.DeploymentName) ($($lastDeploy.Timestamp))" -ForegroundColor Yellow
        if (-not $WorkspaceResourceId) { $WorkspaceResourceId = $lastDeploy.Parameters['existingWorkspaceId'].Value }
        if (-not $ServiceAccountUpn)   { $ServiceAccountUpn   = $lastDeploy.Parameters['serviceAccountUpn'].Value }
    }
}

if (-not $WorkspaceResourceId) {
    throw "WorkspaceResourceId not provided and not discoverable from prior deployments. Pass -WorkspaceResourceId."
}
if (-not $ServiceAccountUpn) {
    throw "ServiceAccountUpn not provided and not discoverable. Pass -ServiceAccountUpn."
}

# Resolve workspace location from the workspace itself
$wsName = ($WorkspaceResourceId -split '/')[-1]
$wsRG   = ($WorkspaceResourceId -split '/')[4]
$ws     = Get-AzOperationalInsightsWorkspace -ResourceGroupName $wsRG -Name $wsName -ErrorAction Stop
$wsLoc  = $ws.Location

$params = @{
    projectPrefix             = $ProjectPrefix
    env                       = $Env
    connectorLocation         = $rg.Location
    existingWorkspaceId       = $WorkspaceResourceId
    workspaceLocation         = $wsLoc
    serviceAccountUpn         = $ServiceAccountUpn
    authMethod                = $AuthMethod
    restrictPublicNetwork     = $false
    enableKeyVaultDiagnostics = $false
    githubRepo                = 'akefallonitis/xdrlograider'
}

# CRITICAL ARCHITECTURE (post-incident 2026-05-07T17:05Z): the ARM template's
# KV secret resources are conditional on `length(parameters('servicePassword')) > 0`.
# By default, this script passes EMPTY SecureStrings so those resources are
# SKIPPED on redeploy — preserving any existing real credentials seeded via
# Initialize-XdrLogRaiderAuth.ps1. This prevents the "ARM redeploy wiped my
# auth secrets" failure mode that caused 65 stream auth failures during
# Phase 1 live override.
#
# To deliberately seed/rotate secrets, pass them explicitly:
#   pwsh tools/Deploy-XdrLogRaider.ps1 -ServicePassword (Read-Host -AsSecureString)
# OR run Initialize-XdrLogRaiderAuth.ps1 separately AFTER the template lands.
# Empty SecureString does NOT serialize over Azure REST API (.NET serializer rejects 0-length).
# Use sentinel string 'dummy-not-used-existing-kv-overrides' which mainTemplate.json's belt-and-
# suspenders condition explicitly rejects (see CHANGELOG L21 BINDING) — KV secret resources
# remain skipped, preserving operator-seeded values.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Sentinel string explicitly rejected by ARM template condition; not a real secret.')]
$emptySecure = ConvertTo-SecureString 'dummy-not-used-existing-kv-overrides' -AsPlainText -Force

if ($SkipSecretSeeding -or $null -eq $ServicePassword) {
    $params['servicePassword'] = $emptySecure
} else {
    $params['servicePassword'] = $ServicePassword
}
if ($SkipSecretSeeding -or $null -eq $TotpSeed) {
    $params['totpSeed'] = $emptySecure
} else {
    $params['totpSeed'] = $TotpSeed
}
if ($SkipSecretSeeding -or $null -eq $PasskeyJson) {
    $params['passkeyJson'] = $emptySecure
} else {
    $params['passkeyJson'] = $PasskeyJson
}

Write-Host "Deployment parameters:" -ForegroundColor Cyan
$params.GetEnumerator() | Sort-Object Name | ForEach-Object {
    Write-Host ("  {0,-26} = {1}" -f $_.Key, $_.Value)
}
Write-Host ""

if (-not $DeploymentName) {
    $DeploymentName = "xdrlr-v0.1.0-ga-$(Get-Date -Format 'yyyyMMdd-HHmm')"
}

if ($WhatIfPreview) {
    Write-Host "Running what-if (no resources will be modified)..." -ForegroundColor Yellow
    Get-AzResourceGroupDeploymentWhatIfResult `
        -ResourceGroupName $ConnectorResourceGroup `
        -TemplateFile $tplPath `
        -TemplateParameterObject $params `
        -ErrorAction Stop
    Write-Host "What-if complete." -ForegroundColor Green
    return
}

if (-not $PSCmdlet.ShouldProcess($ConnectorResourceGroup, "Deploy XdrLogRaider v0.1.0 GA ($DeploymentName)")) {
    return
}

Write-Host "Starting deployment '$DeploymentName' (this takes 5-10 min)..." -ForegroundColor Cyan
$start = Get-Date
$result = New-AzResourceGroupDeployment `
    -ResourceGroupName $ConnectorResourceGroup `
    -Name $DeploymentName `
    -TemplateFile $tplPath `
    -TemplateParameterObject $params `
    -ErrorAction Stop
$elapsed = (Get-Date) - $start

Write-Host ""
Write-Host "===== Deployment Complete =====" -ForegroundColor Green
Write-Host "  Name             : $($result.DeploymentName)"
Write-Host "  ProvisioningState: $($result.ProvisioningState)"
Write-Host "  Elapsed          : $('{0:mm}m {0:ss}s' -f $elapsed)"
Write-Host ""
Write-Host "Outputs:" -ForegroundColor Cyan
$result.Outputs.GetEnumerator() | Sort-Object Key | ForEach-Object {
    $val = $_.Value.Value
    if ($val -is [string] -and $val.Length -gt 80) { $val = $val.Substring(0, 77) + '...' }
    Write-Host ("  {0,-30} = {1}" -f $_.Key, $val)
}
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Seed KV secrets:"
Write-Host "     pwsh tools/Initialize-XdrLogRaiderAuth.ps1 -KeyVaultName $($result.Outputs.keyVaultName.Value)"
Write-Host "  2. Wait 5-10 min for FA cold-start"
Write-Host "  3. Smoke verify:"
Write-Host "     pwsh tools/Smoke-Deploy.ps1 -ConnectorResourceGroup $ConnectorResourceGroup -WorkspaceCustomerId $($ws.CustomerId)"
Write-Host "  4. P1-P14 probes:"
Write-Host "     pwsh tools/Post-DeploymentVerification.ps1 -WorkspaceCustomerId $($ws.CustomerId)"
