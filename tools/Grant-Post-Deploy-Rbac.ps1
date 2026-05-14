<#
.SYNOPSIS
    Grants the 3 RBAC roles the FA SAMI needs when the deploying identity used
    -deployRoleAssignments=false (Contributor-only operator path).

.DESCRIPTION
    The XdrLogRaider ARM template accepts a -deployRoleAssignments boolean. When
    the deploying identity has Contributor but NOT User Access Administrator (or
    Owner), set deployRoleAssignments=false and the template skips the 3 role
    assignments. Operator then runs this script with an identity that DOES have
    role-assignment write permission (typically a human in the directory's
    'Owner' role on the resource group, or via PIM).

    Roles granted to the Function App's System-Assigned Managed Identity:
      1. Key Vault Secrets User             on the connector's Key Vault
      2. Storage Table Data Contributor     on the connector's Storage Account
      3. Monitoring Metrics Publisher       on the connector's resource group
                                             (covers all 19 DCRs in one assignment)

    Idempotent: re-running is safe (az role assignment create no-ops if the same
    role + scope + principal already exists, returning the existing assignment).

.PARAMETER ResourceGroup
    The connector's resource group (where mainTemplate.json was deployed).

.PARAMETER SubscriptionId
    Optional. Defaults to the current az account context.

.PARAMETER FunctionAppName
    Optional. Auto-discovered from the RG if exactly one FA exists.

.PARAMETER KeyVaultName
    Optional. Auto-discovered from the RG.

.PARAMETER StorageAccountName
    Optional. Auto-discovered from the RG.

.PARAMETER WhatIf
    Print the role-assignment commands without executing them.

.EXAMPLE
    pwsh ./tools/Grant-Post-Deploy-Rbac.ps1 -ResourceGroup XDRLOGRAIDER

.EXAMPLE
    # Preview only:
    pwsh ./tools/Grant-Post-Deploy-Rbac.ps1 -ResourceGroup XDRLOGRAIDER -WhatIf

.OUTPUTS
    Markdown summary at tests/results/grant-rbac-<utc>.md.
    Exit 0 on success, 1 on any failure.
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [string] $SubscriptionId,
    [string] $FunctionAppName,
    [string] $KeyVaultName,
    [string] $StorageAccountName,
    [string] $OutputDir = (Join-Path $PSScriptRoot '..' 'tests' 'results'),
    [switch] $WhatIf
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI (az) is required. Install: https://aka.ms/azurecli"
}
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

# --- Resolve subscription ---
if ($SubscriptionId) {
    & az account set --subscription $SubscriptionId | Out-Null
} else {
    $SubscriptionId = & az account show --query id -o tsv
}
if (-not $SubscriptionId) {
    throw "Not logged in to Azure. Run 'az login' first."
}
Write-Host "Subscription: $SubscriptionId" -ForegroundColor Cyan
Write-Host "Resource group: $ResourceGroup" -ForegroundColor Cyan

# --- Resolve resources from the RG ---
function Resolve-Single {
    param([string] $ResourceType, [string] $Name, [string] $Label)
    if ($Name) {
        $exists = & az resource list -g $ResourceGroup --resource-type $ResourceType --query "[?name=='$Name'].name" -o tsv
        if (-not $exists) { throw "$Label '$Name' not found in RG '$ResourceGroup'." }
        return $Name
    }
    $found = @(& az resource list -g $ResourceGroup --resource-type $ResourceType --query "[].name" -o tsv) | Where-Object { $_ }
    if ($found.Count -eq 0) { throw "No $Label found in RG '$ResourceGroup'. Pass -$($Label.Replace(' ',''))Name explicitly." }
    if ($found.Count -gt 1) { throw "Multiple $Label resources found in RG '$ResourceGroup': $($found -join ', '). Pass -$($Label.Replace(' ',''))Name to disambiguate." }
    return $found[0]
}

$fa = Resolve-Single -ResourceType 'Microsoft.Web/sites'         -Name $FunctionAppName     -Label 'Function App'
$kv = Resolve-Single -ResourceType 'Microsoft.KeyVault/vaults'   -Name $KeyVaultName        -Label 'Key Vault'
$st = Resolve-Single -ResourceType 'Microsoft.Storage/storageAccounts' -Name $StorageAccountName -Label 'Storage Account'

Write-Host "Function App:   $fa" -ForegroundColor Green
Write-Host "Key Vault:      $kv" -ForegroundColor Green
Write-Host "Storage:        $st" -ForegroundColor Green

# --- Resolve SAMI principalId ---
$samiPrincipalId = & az functionapp identity show -g $ResourceGroup -n $fa --query principalId -o tsv 2>$null
if (-not $samiPrincipalId) {
    throw "Function App '$fa' has no SystemAssigned identity. Re-deploy with identity.type=SystemAssigned."
}
Write-Host "SAMI principalId: $samiPrincipalId" -ForegroundColor Green

# --- Resolve scope IDs ---
$kvId = & az keyvault show -g $ResourceGroup -n $kv --query id -o tsv
$stId = & az storage account show -g $ResourceGroup -n $st --query id -o tsv
$rgId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"

# --- Role grants ---
$grants = @(
    [pscustomobject]@{ Role = 'Key Vault Secrets User';           Scope = $kvId; Reason = 'Read defender-* secrets at FA runtime (Az.KeyVault SDK, 60-min TTL cache)' }
    [pscustomobject]@{ Role = 'Storage Table Data Contributor';   Scope = $stId; Reason = 'Read/write XdrTierState + connectorCheckpoints + xdrIngestDlq + XdrTenantState tables (MI-backed REST)' }
    [pscustomobject]@{ Role = 'Monitoring Metrics Publisher';     Scope = $rgId; Reason = 'Send rows to DCE (Logs Ingestion API); RG-scoped covers all 19 DCRs' }
)

Write-Host ""
Write-Host "=== Granting 3 RBAC assignments to SAMI ===" -ForegroundColor Cyan
$results = New-Object System.Collections.Generic.List[object]
foreach ($g in $grants) {
    $cmd = "az role assignment create --assignee-object-id $samiPrincipalId --assignee-principal-type ServicePrincipal --role `"$($g.Role)`" --scope `"$($g.Scope)`""
    if ($WhatIf) {
        Write-Host "[WHATIF] $cmd" -ForegroundColor Yellow
        $results.Add([pscustomobject]@{ Role = $g.Role; Scope = $g.Scope; Status = 'WHATIF' })
        continue
    }
    try {
        # --assignee-object-id + --assignee-principal-type avoids the AAD lookup
        # that fails when the caller doesn't have directory-read permission on the SP.
        $out = & az role assignment create `
            --assignee-object-id $samiPrincipalId `
            --assignee-principal-type ServicePrincipal `
            --role $g.Role `
            --scope $g.Scope 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host ("  [OK] {0,-35} on {1}" -f $g.Role, $g.Scope) -ForegroundColor Green
            $results.Add([pscustomobject]@{ Role = $g.Role; Scope = $g.Scope; Status = 'OK' })
        } else {
            # Already-exists is idempotent success
            if ("$out" -match 'already exists|RoleAssignmentExists') {
                Write-Host ("  [OK] {0,-35} already exists" -f $g.Role) -ForegroundColor DarkGreen
                $results.Add([pscustomobject]@{ Role = $g.Role; Scope = $g.Scope; Status = 'EXISTS' })
            } else {
                Write-Host ("  [FAIL] {0,-35} {1}" -f $g.Role, $out) -ForegroundColor Red
                $results.Add([pscustomobject]@{ Role = $g.Role; Scope = $g.Scope; Status = 'FAIL'; Error = "$out" })
            }
        }
    } catch {
        Write-Host ("  [FAIL] {0,-35} {1}" -f $g.Role, $_.Exception.Message) -ForegroundColor Red
        $results.Add([pscustomobject]@{ Role = $g.Role; Scope = $g.Scope; Status = 'FAIL'; Error = $_.Exception.Message })
    }
}

# --- Markdown report ---
$utc = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$mdPath = Join-Path $OutputDir "grant-rbac-$utc.md"
$md = New-Object System.Text.StringBuilder
$null = $md.AppendLine("# Post-deploy RBAC grant — $utc")
$null = $md.AppendLine("")
$null = $md.AppendLine("- Subscription: ``$SubscriptionId``")
$null = $md.AppendLine("- Resource group: ``$ResourceGroup``")
$null = $md.AppendLine("- Function App: ``$fa``")
$null = $md.AppendLine("- SAMI principalId: ``$samiPrincipalId``")
$null = $md.AppendLine("- Key Vault: ``$kv``")
$null = $md.AppendLine("- Storage Account: ``$st``")
$null = $md.AppendLine("")
$null = $md.AppendLine("## Role assignments")
$null = $md.AppendLine("")
$null = $md.AppendLine("| Role | Scope | Status |")
$null = $md.AppendLine("|---|---|---|")
foreach ($r in $results) {
    $null = $md.AppendLine("| $($r.Role) | $($r.Scope) | $($r.Status) |")
}
$null = $md.AppendLine("")
$null = $md.AppendLine("## Next step")
$null = $md.AppendLine("")
$null = $md.AppendLine('Run `pwsh ./tools/Verify-Deploy.ps1 -ResourceGroup ' + $ResourceGroup + '` to confirm SAMI can read/write KV + Storage + DCE.')
Set-Content -Path $mdPath -Value $md.ToString() -Encoding UTF8
Write-Host ""
Write-Host "Report: $mdPath" -ForegroundColor Cyan

# --- Exit code ---
$failCount = ($results | Where-Object { $_.Status -eq 'FAIL' }).Count
if ($failCount -gt 0) {
    Write-Host "$failCount role assignment(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host "All role assignments OK." -ForegroundColor Green
exit 0
