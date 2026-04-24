#Requires -Version 7.0
<#
.SYNOPSIS
    One-shot Service Principal provisioner for XdrLogRaider local automation.

.DESCRIPTION
    Creates an Entra App Registration + Service Principal, assigns Tier 2 RBAC
    (Contributor on connector RG + Log Analytics Contributor on workspace),
    then writes credentials to tests/.env.local (gitignored).

    After this script: any of the local-test scripts can authenticate
    unattended via Connect-AzAccount -ServicePrincipal.

    REQUIRED operator permissions:
      - Application Administrator (Entra) — to create the App Reg + SP
      - Owner on connector RG xdrlograider — to assign Contributor to the SP
      - Owner on the Sentinel workspace (or its RG) — to assign Log Analytics
        Contributor to the SP

    Microsoft Graph: NONE required. Pure Azure RBAC.

.PARAMETER DisplayName
    App Registration display name. Default: 'XdrLogRaider-Automation'.

.PARAMETER ConnectorResourceGroup
    Connector RG. Default: 'xdrlograider'.

.PARAMETER WorkspaceId
    Full ARM resource ID of the Sentinel workspace
    (/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<ws>).
    REQUIRED.

.PARAMETER GrantKeyVaultOfficer
    OPT-IN. Also assigns Key Vault Secrets Officer (data plane) on the
    deployed KV. Only needed if you want auto-rotation in
    Post-DeploymentVerification.ps1's -AutoFix mode. Default: false.

.PARAMETER KeyVaultName
    Required when -GrantKeyVaultOfficer is set. Output of the deploy.

.PARAMETER EnvFilePath
    Where to write credentials. Default: ./tests/.env.local.

.EXAMPLE
    pwsh ./tools/Initialize-XdrLogRaiderSP.ps1 `
        -WorkspaceId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/Sentinel-Workspace/providers/Microsoft.OperationalInsights/workspaces/Sentinel-Workspace'

.NOTES
    Idempotent: safe to re-run. Checks for existing App Reg by display name;
    rotates the secret if found; recreates role assignments if missing.
#>

[CmdletBinding()]
param(
    [string] $DisplayName = 'XdrLogRaider-Automation',

    [string] $ConnectorResourceGroup = 'xdrlograider',

    [Parameter(Mandatory)]
    [ValidatePattern('^/subscriptions/[0-9a-f-]{36}/resourceGroups/[^/]+/providers/Microsoft\.OperationalInsights/workspaces/[^/]+$')]
    [string] $WorkspaceId,

    [switch] $GrantKeyVaultOfficer,

    [string] $KeyVaultName,

    [string] $EnvFilePath = './tests/.env.local'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($GrantKeyVaultOfficer -and -not $KeyVaultName) {
    throw '-GrantKeyVaultOfficer requires -KeyVaultName'
}

$line = '═' * 67
Write-Host ""
Write-Host "  $line" -ForegroundColor Cyan
Write-Host "   XdrLogRaider — Service Principal provisioning" -ForegroundColor Cyan
Write-Host "  $line" -ForegroundColor Cyan
Write-Host ""

# --- 1. Verify az + auth ---

Write-Host "  [1/6] Verifying az CLI session" -ForegroundColor Yellow
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI ('az') not found. Install from https://aka.ms/installazurecli."
}

$accountJson = az account show 2>$null
if (-not $accountJson) {
    Write-Host "        Not signed in. Running 'az login'..." -ForegroundColor Gray
    az login --output none
    $accountJson = az account show
}
$account = $accountJson | ConvertFrom-Json
Write-Host "        Subscription: $($account.name) ($($account.id))"
Write-Host "        Tenant:       $($account.tenantId)"
Write-Host "        Account:      $($account.user.name)"

$subId    = $account.id
$tenantId = $account.tenantId

# --- 2. Parse workspace ID + verify reachable ---

Write-Host ""
Write-Host "  [2/6] Verifying workspace + connector RG accessibility" -ForegroundColor Yellow

$wsParts = $WorkspaceId -split '/'
$wsSub = $wsParts[2]
$wsRg  = $wsParts[4]
$wsName = $wsParts[8]
Write-Host "        Workspace: $wsName (RG=$wsRg, sub=$wsSub)"

$rgCheck = az group show --name $ConnectorResourceGroup --subscription $subId --output none 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Connector RG '$ConnectorResourceGroup' not found in subscription '$subId'. Verify the deploy completed and the RG exists."
}
Write-Host "        Connector RG: $ConnectorResourceGroup (in current subscription)"

# --- 3. Create or rotate App Registration ---

Write-Host ""
Write-Host "  [3/6] Creating / rotating App Registration '$DisplayName'" -ForegroundColor Yellow

$existing = az ad app list --display-name $DisplayName --query "[0].{appId:appId, id:id}" --output json 2>$null | ConvertFrom-Json
if ($existing -and $existing.appId) {
    Write-Host "        Existing App Reg found: $($existing.appId) — rotating secret"
    $appId = $existing.appId
} else {
    Write-Host "        Creating new App Reg..."
    $appId = az ad app create --display-name $DisplayName --query appId --output tsv
    Write-Host "        Created: $appId"
}

# Ensure Service Principal exists
$spId = az ad sp list --filter "appId eq '$appId'" --query "[0].id" --output tsv 2>$null
if (-not $spId) {
    az ad sp create --id $appId --output none
    $spId = az ad sp list --filter "appId eq '$appId'" --query "[0].id" --output tsv
    Write-Host "        SP created: $spId"
} else {
    Write-Host "        SP exists: $spId"
}

# Rotate client secret (fresh on every run — old ones expire on their own; current run gets a known-good one)
$secret = az ad app credential reset --id $appId --years 2 --query password --output tsv
Write-Host "        Client secret: rotated (2-year expiry)"

# --- 4. Grant RBAC ---

Write-Host ""
Write-Host "  [4/6] Granting RBAC" -ForegroundColor Yellow

function Grant-Role {
    param([string]$Role, [string]$Scope, [string]$ScopeLabel)
    $existing = az role assignment list --assignee-object-id $spId --assignee-principal-type ServicePrincipal --scope $Scope --query "[?roleDefinitionName=='$Role'].id" --output tsv 2>$null
    if ($existing) {
        Write-Host "        $Role on $ScopeLabel — already assigned"
    } else {
        az role assignment create --assignee-object-id $spId --assignee-principal-type ServicePrincipal --role $Role --scope $Scope --output none
        Write-Host "        $Role on $ScopeLabel — granted" -ForegroundColor Green
    }
}

$connectorRgScope = "/subscriptions/$subId/resourceGroups/$ConnectorResourceGroup"
Grant-Role -Role 'Contributor'                -Scope $connectorRgScope -ScopeLabel "RG $ConnectorResourceGroup"
Grant-Role -Role 'Log Analytics Contributor'  -Scope $WorkspaceId      -ScopeLabel "workspace $wsName"

if ($GrantKeyVaultOfficer) {
    $kvScope = "$connectorRgScope/providers/Microsoft.KeyVault/vaults/$KeyVaultName"
    Grant-Role -Role 'Key Vault Secrets Officer' -Scope $kvScope -ScopeLabel "KV $KeyVaultName"
}

# --- 5. Write tests/.env.local ---

Write-Host ""
Write-Host "  [5/6] Writing $EnvFilePath" -ForegroundColor Yellow

$envContent = @"
# Auto-generated by tools/Initialize-XdrLogRaiderSP.ps1 — do not commit.
AZURE_TENANT_ID=$tenantId
AZURE_CLIENT_ID=$appId
AZURE_CLIENT_SECRET=$secret
XDRLR_SP_OBJECT_ID=$spId
XDRLR_SUBSCRIPTION_ID=$subId
XDRLR_CONNECTOR_RG=$ConnectorResourceGroup
XDRLR_WORKSPACE_ID=$WorkspaceId
XDRLR_WORKSPACE_NAME=$wsName
XDRLR_WORKSPACE_RG=$wsRg
XDRLR_WORKSPACE_SUB=$wsSub
"@
if ($GrantKeyVaultOfficer -and $KeyVaultName) {
    $envContent += "`nXDRLR_KV_NAME=$KeyVaultName"
}

# Ensure parent dir exists
$envDir = Split-Path $EnvFilePath -Parent
if ($envDir -and -not (Test-Path $envDir)) {
    New-Item -Path $envDir -ItemType Directory -Force | Out-Null
}
Set-Content -Path $EnvFilePath -Value $envContent -NoNewline
Write-Host "        Written: $EnvFilePath"

# --- 6. Verify ---

Write-Host ""
Write-Host "  [6/6] Verifying RBAC assignments" -ForegroundColor Yellow
$expected = if ($GrantKeyVaultOfficer) { 3 } else { 2 }
$assignments = az role assignment list --assignee-object-id $spId --assignee-principal-type ServicePrincipal --output json | ConvertFrom-Json
Write-Host "        Found $($assignments.Count) role assignment(s) (expected $expected):"
foreach ($a in $assignments) {
    Write-Host "          - $($a.roleDefinitionName) on $($a.scope)"
}

if ($assignments.Count -lt $expected) {
    Write-Host "        WARNING: fewer than expected. Re-run if missing." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "  ✓ Done." -ForegroundColor Green
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor Gray
Write-Host "    1. Deploy XdrLogRaider via Deploy-to-Azure (if not already done)" -ForegroundColor Gray
Write-Host "    2. Run ./tools/Post-DeploymentVerification.ps1 to verify the deployment" -ForegroundColor Gray
Write-Host "    3. Or: ./tools/Run-LocalTests.ps1 -Mode All for the full gauntlet" -ForegroundColor Gray
Write-Host ""
