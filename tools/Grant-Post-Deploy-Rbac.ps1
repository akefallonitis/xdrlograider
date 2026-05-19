#requires -Version 7.4
<#
.SYNOPSIS
    Post-deploy RBAC grant for operators who deployed XdrLogRaider with
    parameter `deployRoleAssignments=false` (lacks User Access Administrator).

.DESCRIPTION
    Mirrors the 6 role assignments embedded in `deploy/mainTemplate.json`
    (resources L495-590 · gated by `deployRoleAssignments` ARM parameter).

    Required role assignments for the FA's System-Assigned Managed Identity:
      1. Key Vault Secrets User       on KV scope         (read secrets)
      2. Monitoring Metrics Publisher on Health DCR scope (ingest heartbeats)
      3. Monitoring Metrics Publisher on per-sub-area DCR scope × 19 (ingest rows)
      4. Storage Table Data Contributor on SA scope       (XdrCheckpoint · XdrTierState · XdrIngestDlq · XdrTenantCapabilities)
      5. Storage Blob Data Owner       on SA scope        (identity-based AzureWebJobsStorage · NOD-1)
      6. Storage Queue Data Contributor on SA scope       (identity-based AzureWebJobsStorage · NOD-1)

    Operator authority required: at least Owner OR (Contributor + User Access Administrator)
    on the connector resource group.

    Idempotent · skips role assignments that already exist (Az.Authorization
    Set-AzRoleAssignment auto-handles duplicates).

.PARAMETER ResourceGroup
    Connector resource group name (matches what was passed to mainTemplate.json deploy).

.PARAMETER SubscriptionId
    Optional · auto-detected if Az.Accounts context is set.

.EXAMPLE
    pwsh tools/Grant-Post-Deploy-Rbac.ps1 -ResourceGroup my-xdrlr-rg

.NOTES
    Author: Alex Kefallonitis <al.kefallonitis@gmail.com>
    Created: ITER6 · 2026-05-20 · per audit finding M2.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [string]$SubscriptionId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.Resources -ErrorAction Stop

# Subscription pin
if (-not $SubscriptionId) {
    $ctx = Get-AzContext -ErrorAction Stop
    if (-not $ctx -or -not $ctx.Subscription) {
        throw "Az.Accounts has no current context. Run Connect-AzAccount first OR pass -SubscriptionId."
    }
    $SubscriptionId = $ctx.Subscription.Id
}
Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
Write-Host "Subscription: $SubscriptionId · ResourceGroup: $ResourceGroup" -ForegroundColor Cyan

# Resolve the most-recent successful deployment (ITER4 S1 timestamp-DESC pattern)
$deploy = az deployment group list -g $ResourceGroup `
    --query "sort_by([?properties.provisioningState=='Succeeded'], &properties.timestamp) | [-1]" `
    -o json 2>$null | ConvertFrom-Json
if (-not $deploy) { throw "No Succeeded deployment found in $ResourceGroup. Deploy mainTemplate.json first." }

$outputs = $deploy.properties.outputs
$faName  = $outputs.functionAppName.value
$kvName  = $outputs.keyVaultName.value
$saName  = $outputs.storageAccountName.value
$dcrHealthImmutableId = $outputs.dcrHealthImmutableId.value
$dcrDefenderMap = $outputs.dcrDefenderImmutableIdMap.value

Write-Host "FA: $faName · KV: $kvName · SA: $saName" -ForegroundColor Cyan

# Resolve FA SAMI principal ID
$fa = Get-AzFunctionApp -ResourceGroupName $ResourceGroup -Name $faName -ErrorAction Stop
$samiPrincipalId = $fa.IdentityPrincipalId
if (-not $samiPrincipalId) {
    throw "Function App $faName has no SystemAssigned identity. Re-deploy with identity enabled."
}
Write-Host "SAMI PrincipalId: $samiPrincipalId" -ForegroundColor Cyan

# Resource ARM IDs
$rgArmId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"
$kvArmId = "$rgArmId/providers/Microsoft.KeyVault/vaults/$kvName"
$saArmId = "$rgArmId/providers/Microsoft.Storage/storageAccounts/$saName"

# Role definition IDs (built-in · same as mainTemplate)
$ROLE = @{
    KvSecretsUser            = '4633458b-17de-408a-b874-0445c86b69e6'
    MonitoringMetricsPublisher = '3913510d-42f4-4e42-8a64-420c390055eb'
    StorageTableDataContributor = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
    StorageBlobDataOwner     = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
    StorageQueueDataContributor = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
}

function _GrantRole {
    param([string]$RoleId, [string]$Scope, [string]$Label)
    $existing = Get-AzRoleAssignment -ObjectId $samiPrincipalId -RoleDefinitionId $RoleId -Scope $Scope -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "  [skip] $Label · already granted" -ForegroundColor DarkGray
        return
    }
    if ($PSCmdlet.ShouldProcess($Scope, "Grant role $Label")) {
        $null = New-AzRoleAssignment -ObjectId $samiPrincipalId -RoleDefinitionId $RoleId -Scope $Scope -ErrorAction Stop
        Write-Host "  [+]    $Label · granted" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "Granting 6 role assignments to FA SAMI ($samiPrincipalId)..." -ForegroundColor Yellow
_GrantRole -RoleId $ROLE.KvSecretsUser              -Scope $kvArmId -Label "KV Secrets User on $kvName"
_GrantRole -RoleId $ROLE.StorageTableDataContributor -Scope $saArmId -Label "Storage Table Data Contributor on $saName"
_GrantRole -RoleId $ROLE.StorageBlobDataOwner       -Scope $saArmId -Label "Storage Blob Data Owner on $saName (identity-based AzureWebJobsStorage)"
_GrantRole -RoleId $ROLE.StorageQueueDataContributor -Scope $saArmId -Label "Storage Queue Data Contributor on $saName (identity-based AzureWebJobsStorage)"

# Health DCR
$healthDcrArmId = "$rgArmId/providers/Microsoft.Insights/dataCollectionRules/$($outputs.dcrHealthName.value)"
_GrantRole -RoleId $ROLE.MonitoringMetricsPublisher -Scope $healthDcrArmId -Label "MMP on $($outputs.dcrHealthName.value) (Health DCR)"

# Per-sub-area DCRs (19)
foreach ($entry in @($dcrDefenderMap)) {
    $dcrName = "dcr-xdrlr-defender-$($entry.subArea.ToLower())"
    $dcrArmId = "$rgArmId/providers/Microsoft.Insights/dataCollectionRules/$dcrName"
    _GrantRole -RoleId $ROLE.MonitoringMetricsPublisher -Scope $dcrArmId -Label "MMP on $dcrName"
}

Write-Host ""
Write-Host "✅ Grant-Post-Deploy-Rbac: complete." -ForegroundColor Green
Write-Host "   Next: wait ~5min for AAD role-replication · then 'pwsh tools/Verify-Deploy.ps1 -ResourceGroup $ResourceGroup'" -ForegroundColor Cyan
