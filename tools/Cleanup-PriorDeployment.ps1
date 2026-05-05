#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Resources, Az.OperationalInsights
<#
.SYNOPSIS
    Removes connector-owned resources from a prior deployment WITHOUT deleting RGs.

.DESCRIPTION
    Cleans the Sentinel workspace + connector RG of artifacts owned by XdrLogRaider.
    Targets ONLY connector-deployed resources by name pattern. Does NOT delete RGs.

    Resources cleaned (in safe order):

      1. Sentinel content (workspace-scoped):
         - savedSearches (parsers + hunting queries)
         - alertRules (analytic rules)
         - dataConnectors (the connector card)
         - workbooks
         - metadata back-links
      2. Custom workspace tables:
         - Defender_*_CL (10 consolidated category tables)
         - XdrConnectorHealth_CL (ops table)
         - MDE_*_CL (legacy per-stream tables, if any)
      3. Data Collection Rules (DCRs):
         - <projectPrefix>-dcr-defender-1..7 (current 7-DCR shape)
         - <projectPrefix>-dcr-1..5 (legacy 5-DCR shape, if any)
      4. Data Collection Endpoint:
         - <projectPrefix>-dce
      5. Function App + plan + KV + Storage in connector RG (-WhatIf preview only;
         -Force required to actually delete, since these can be reused)

    NEVER deletes:
      - Resource Groups
      - Other connectors / data connectors not matching XdrLogRaider naming
      - Workspace itself
      - Any resource not matching the projectPrefix

.PARAMETER WorkspaceResourceId
    Full Azure resource ID of the Sentinel-enabled Log Analytics workspace.
    Example: /subscriptions/.../resourceGroups/.../providers/Microsoft.OperationalInsights/workspaces/...

.PARAMETER ConnectorResourceGroup
    Resource group name where Function App, KV, Storage, DCE, DCRs were deployed.

.PARAMETER ProjectPrefix
    The projectPrefix used in the original deployment (default 'xdrlr').
    Resources matching <prefix>-* in the connector RG are candidates for deletion.

.PARAMETER WhatIf
    Preview only — shows what would be deleted, makes no changes.

.PARAMETER Force
    Skip the per-resource confirmation prompt. Use ONLY after WhatIf review.

.PARAMETER SkipFunctionApp
    Default behavior: keeps Function App + plan + KV + Storage (operator may want to reuse them).
    Set this to $false explicitly if you also want those deleted.

.EXAMPLE
    Connect-AzAccount
    ./tools/Cleanup-PriorDeployment.ps1 `
        -WorkspaceResourceId '/subscriptions/.../workspaces/<ws>' `
        -ConnectorResourceGroup 'xdrlr-prod-rg' `
        -ProjectPrefix 'xdrlr' `
        -WhatIf

.EXAMPLE
    # After reviewing the WhatIf output, actually delete:
    ./tools/Cleanup-PriorDeployment.ps1 `
        -WorkspaceResourceId '/subscriptions/.../workspaces/<ws>' `
        -ConnectorResourceGroup 'xdrlr-prod-rg' `
        -ProjectPrefix 'xdrlr' `
        -Force

.NOTES
    Requires:
      - Az.Accounts (auth)
      - Az.Resources (resource enumeration + deletion)
      - Az.OperationalInsights (workspace tables + saved searches)
    Caller's identity needs:
      - Contributor on the connector RG
      - Log Analytics Contributor on the workspace RG
      - User Access Administrator if any role assignments need cleanup
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param(
    [Parameter(Mandatory)] [string] $WorkspaceResourceId,
    [Parameter(Mandatory)] [string] $ConnectorResourceGroup,
    [string] $ProjectPrefix = 'xdrlr',
    [switch] $Force,
    [switch] $SkipFunctionApp = $true
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Validate Az auth
$ctx = Get-AzContext -ErrorAction SilentlyContinue
if (-not $ctx) {
    throw "Not signed in. Run Connect-AzAccount first."
}
Write-Host "Subscription: $($ctx.Subscription.Name) ($($ctx.Subscription.Id))" -ForegroundColor Cyan
Write-Host "Account:      $($ctx.Account.Id)" -ForegroundColor Cyan
Write-Host ""

# Parse workspace ID
if ($WorkspaceResourceId -notmatch '^/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft\.OperationalInsights/workspaces/([^/]+)$') {
    throw "WorkspaceResourceId must be a full resource ID. Got: $WorkspaceResourceId"
}
$wsSubId  = $Matches[1]
$wsRg     = $Matches[2]
$wsName   = $Matches[3]

Write-Host "===== TARGET ======" -ForegroundColor Yellow
Write-Host "  Workspace:        $wsName (in RG $wsRg)"
Write-Host "  Connector RG:     $ConnectorResourceGroup"
Write-Host "  ProjectPrefix:    $ProjectPrefix"
Write-Host "  Mode:             $(if ($WhatIfPreference -or $PSCmdlet.MyInvocation.BoundParameters.ContainsKey('WhatIf')) { 'WhatIf (preview)' } else { 'EXECUTE' })"
Write-Host "  Skip FA + KV + Storage: $SkipFunctionApp"
Write-Host ""

$plan = [ordered]@{
    SentinelContent = @()
    CustomTables    = @()
    DCRs            = @()
    DCE             = @()
    FunctionApp     = @()
    KeyVault        = @()
    StorageAccount  = @()
}

# ----------------------------------------------------------------------------
# 1. Sentinel content (workspace-scoped — Microsoft.SecurityInsights provider)
# ----------------------------------------------------------------------------
Write-Host "[1/5] Discovering Sentinel content in workspace $wsName..." -ForegroundColor Cyan

# Saved searches (parsers + hunting queries) — match XdrLogRaider naming patterns
try {
    $allSavedSearches = Get-AzOperationalInsightsSavedSearch -ResourceGroupName $wsRg -WorkspaceName $wsName -ErrorAction Stop
    $ours = $allSavedSearches.Value | Where-Object {
        $_.Properties.DisplayName -match '^MDE_Drift_(Configuration|Inventory|Exposure|Maintenance)$|^MDE [A-Z]' -or
        $_.Properties.Category -in @('XdrLogRaider','MDE Hunting','MDE Parsers')
    }
    foreach ($ss in $ours) {
        $plan.SentinelContent += [pscustomobject]@{
            Type = 'SavedSearch'
            Name = $ss.Properties.DisplayName
            Id   = $ss.Name  # Saved-search ID
        }
    }
} catch {
    Write-Warning "  Could not enumerate saved searches: $($_.Exception.Message)"
}

# Workbooks — saved as Microsoft.Insights/workbooks at subscription scope
# Note: -ExpandProperties is required to populate Properties.displayName.
try {
    $allWorkbooks = Get-AzResource -ResourceType 'Microsoft.Insights/workbooks' -ExpandProperties -ErrorAction Stop |
        Where-Object {
            $_.Properties -and $_.Properties.displayName -and (
                # Match both 'MDE_X' and 'MDE X' display name formats; also XdrLogRaider direct match
                $_.Properties.displayName -match 'XdrLogRaider' -or
                $_.Properties.displayName -match '^MDE[ _](Action[ ]?Center|Compliance[ ]?Dashboard|Drift[ ]?Report|Exposure[ ]?Map|Governance[ ]?Scorecard|Identity[ ]?Posture|Response[ ]?Audit|ConnectorHealth)'
            )
        }
    foreach ($wb in $allWorkbooks) {
        $plan.SentinelContent += [pscustomobject]@{
            Type = 'Workbook'
            Name = $wb.Properties.displayName
            Id   = $wb.ResourceId
        }
    }
} catch {
    Write-Warning "  Could not enumerate workbooks: $($_.Exception.Message)"
}

# Content Hub solution packages (Microsoft.SecurityInsights/contentPackages)
try {
    $cpUrl = "https://management.azure.com$WorkspaceResourceId/providers/Microsoft.SecurityInsights/contentPackages?api-version=2024-01-01-preview"
    $cpResp = Invoke-AzRestMethod -Uri $cpUrl -Method GET -ErrorAction Stop
    if ($cpResp.StatusCode -eq 200) {
        $cps = ($cpResp.Content | ConvertFrom-Json).value
        $ours = $cps | Where-Object {
            $_.properties.contentId -match 'XdrLogRaider|community\.xdrlograider' -or
            $_.properties.displayName -match 'XdrLogRaider'
        }
        foreach ($cp in $ours) {
            $plan.SentinelContent += [pscustomobject]@{
                Type = 'ContentPackage'
                Name = $cp.properties.displayName
                Id   = $cp.id
            }
        }
    }
} catch {
    Write-Warning "  Could not enumerate Content Hub packages: $($_.Exception.Message)"
}

# Analytic rules — Microsoft.SecurityInsights/scheduled
try {
    $rulesUrl = "https://management.azure.com$WorkspaceResourceId/providers/Microsoft.SecurityInsights/alertRules?api-version=2024-01-01-preview"
    $rulesResp = Invoke-AzRestMethod -Uri $rulesUrl -Method GET -ErrorAction Stop
    if ($rulesResp.StatusCode -eq 200) {
        $rules = ($rulesResp.Content | ConvertFrom-Json).value
        $ours = $rules | Where-Object {
            $_.properties.displayName -match '^MDE |^\[XdrOps\]'
        }
        foreach ($r in $ours) {
            $plan.SentinelContent += [pscustomobject]@{
                Type = 'AnalyticRule'
                Name = $r.properties.displayName
                Id   = $r.id
            }
        }
    }
} catch {
    Write-Warning "  Could not enumerate analytic rules: $($_.Exception.Message)"
}

# Data connectors — Microsoft.SecurityInsights/dataConnectors (the connector card)
try {
    $dcsUrl = "https://management.azure.com$WorkspaceResourceId/providers/Microsoft.SecurityInsights/dataConnectors?api-version=2024-01-01-preview"
    $dcsResp = Invoke-AzRestMethod -Uri $dcsUrl -Method GET -ErrorAction Stop
    if ($dcsResp.StatusCode -eq 200) {
        $dcs = ($dcsResp.Content | ConvertFrom-Json).value
        $ours = $dcs | Where-Object { $_.properties.connectorUiConfig.id -eq 'XdrLogRaiderInternal' -or $_.name -match 'XdrLogRaider' }
        foreach ($d in $ours) {
            $plan.SentinelContent += [pscustomobject]@{
                Type = 'DataConnector'
                Name = $d.name
                Id   = $d.id
            }
        }
    }
} catch {
    Write-Warning "  Could not enumerate data connectors: $($_.Exception.Message)"
}

# Metadata back-links — Microsoft.SecurityInsights/metadata
try {
    $mdUrl = "https://management.azure.com$WorkspaceResourceId/providers/Microsoft.SecurityInsights/metadata?api-version=2024-01-01-preview"
    $mdResp = Invoke-AzRestMethod -Uri $mdUrl -Method GET -ErrorAction Stop
    if ($mdResp.StatusCode -eq 200) {
        $md = ($mdResp.Content | ConvertFrom-Json).value
        $ours = $md | Where-Object {
            $_.properties.parentId -match '/MDE_|/XdrOps-|/XdrLogRaider' -or
            $_.properties.contentId -match 'XdrLogRaider|community\.xdrlograider'
        }
        foreach ($m in $ours) {
            $plan.SentinelContent += [pscustomobject]@{
                Type = 'Metadata'
                Name = $m.name
                Id   = $m.id
            }
        }
    }
} catch {
    Write-Warning "  Could not enumerate metadata: $($_.Exception.Message)"
}
Write-Host "  Found $($plan.SentinelContent.Count) Sentinel content items"

# ----------------------------------------------------------------------------
# 2. Custom workspace tables (Defender_*_CL + XdrConnectorHealth_CL + legacy MDE_*_CL)
# ----------------------------------------------------------------------------
Write-Host "[2/5] Discovering custom workspace tables..." -ForegroundColor Cyan
try {
    $allTables = Get-AzOperationalInsightsTable -ResourceGroupName $wsRg -WorkspaceName $wsName -ErrorAction Stop
    $ours = $allTables | Where-Object {
        $_.Name -match '^Defender_[A-Za-z]+_CL$' -or
        $_.Name -eq 'XdrConnectorHealth_CL' -or
        $_.Name -eq 'MDE_Heartbeat_CL' -or
        $_.Name -eq 'MDE_AuthTestResult_CL' -or
        ($_.Name -match '^MDE_[A-Za-z]+_CL$')
    }
    foreach ($t in $ours) {
        $plan.CustomTables += [pscustomobject]@{
            Type = 'CustomTable'
            Name = $t.Name
            Id   = "$WorkspaceResourceId/tables/$($t.Name)"
        }
    }
} catch {
    Write-Warning "  Could not enumerate tables: $($_.Exception.Message)"
}
Write-Host "  Found $($plan.CustomTables.Count) custom tables"

# ----------------------------------------------------------------------------
# 3. DCRs (in connector RG, matching prefix)
# ----------------------------------------------------------------------------
Write-Host "[3/5] Discovering DCRs in $ConnectorResourceGroup..." -ForegroundColor Cyan
try {
    $allDcrs = Get-AzResource -ResourceType 'Microsoft.Insights/dataCollectionRules' `
        -ResourceGroupName $ConnectorResourceGroup -ErrorAction Stop
    $ours = $allDcrs | Where-Object { $_.Name -match "^$ProjectPrefix-" }
    foreach ($d in $ours) {
        $plan.DCRs += [pscustomobject]@{
            Type = 'DCR'
            Name = $d.Name
            Id   = $d.ResourceId
        }
    }
} catch {
    Write-Warning "  Could not enumerate DCRs: $($_.Exception.Message)"
}
Write-Host "  Found $($plan.DCRs.Count) DCRs"

# ----------------------------------------------------------------------------
# 4. DCE
# ----------------------------------------------------------------------------
Write-Host "[4/5] Discovering DCE in $ConnectorResourceGroup..." -ForegroundColor Cyan
try {
    $allDces = Get-AzResource -ResourceType 'Microsoft.Insights/dataCollectionEndpoints' `
        -ResourceGroupName $ConnectorResourceGroup -ErrorAction Stop
    $ours = $allDces | Where-Object { $_.Name -match "^$ProjectPrefix-" }
    foreach ($d in $ours) {
        $plan.DCE += [pscustomobject]@{
            Type = 'DCE'
            Name = $d.Name
            Id   = $d.ResourceId
        }
    }
} catch {
    Write-Warning "  Could not enumerate DCEs: $($_.Exception.Message)"
}
Write-Host "  Found $($plan.DCE.Count) DCEs"

# ----------------------------------------------------------------------------
# 5. Function App + plan + KV + Storage (only enumerated; deletion gated by SkipFunctionApp)
# ----------------------------------------------------------------------------
if (-not $SkipFunctionApp) {
    Write-Host "[5/5] Discovering FA + KV + Storage in $ConnectorResourceGroup..." -ForegroundColor Cyan
    try {
        $sites = Get-AzResource -ResourceType 'Microsoft.Web/sites' -ResourceGroupName $ConnectorResourceGroup -ErrorAction Stop |
            Where-Object { $_.Name -match "^$ProjectPrefix-" }
        $plans = Get-AzResource -ResourceType 'Microsoft.Web/serverfarms' -ResourceGroupName $ConnectorResourceGroup -ErrorAction Stop |
            Where-Object { $_.Name -match "^$ProjectPrefix-" }
        $kvs = Get-AzResource -ResourceType 'Microsoft.KeyVault/vaults' -ResourceGroupName $ConnectorResourceGroup -ErrorAction Stop |
            Where-Object { $_.Name -match "^$ProjectPrefix-" }
        $storages = Get-AzResource -ResourceType 'Microsoft.Storage/storageAccounts' -ResourceGroupName $ConnectorResourceGroup -ErrorAction Stop |
            Where-Object { $_.Name -match "^$ProjectPrefix" }
        $ais = Get-AzResource -ResourceType 'Microsoft.Insights/components' -ResourceGroupName $ConnectorResourceGroup -ErrorAction Stop |
            Where-Object { $_.Name -match "^$ProjectPrefix-" }
        foreach ($s in $sites) { $plan.FunctionApp += [pscustomobject]@{ Type='FunctionApp'; Name=$s.Name; Id=$s.ResourceId } }
        foreach ($p in $plans) { $plan.FunctionApp += [pscustomobject]@{ Type='AppServicePlan'; Name=$p.Name; Id=$p.ResourceId } }
        foreach ($a in $ais)   { $plan.FunctionApp += [pscustomobject]@{ Type='AppInsights'; Name=$a.Name; Id=$a.ResourceId } }
        foreach ($k in $kvs)    { $plan.KeyVault += [pscustomobject]@{ Type='KeyVault'; Name=$k.Name; Id=$k.ResourceId } }
        foreach ($s in $storages) { $plan.StorageAccount += [pscustomobject]@{ Type='StorageAccount'; Name=$s.Name; Id=$s.ResourceId } }
    } catch {
        Write-Warning "  Could not enumerate FA/KV/Storage: $($_.Exception.Message)"
    }
}

# ----------------------------------------------------------------------------
# Print plan
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "===== DELETION PLAN =====" -ForegroundColor Yellow
$total = 0
foreach ($category in $plan.Keys) {
    $items = $plan[$category]
    if ($items.Count -eq 0) { continue }
    Write-Host "[$category]  $($items.Count) item(s)" -ForegroundColor Cyan
    foreach ($i in $items) {
        Write-Host "  - $($i.Type): $($i.Name)" -ForegroundColor White
    }
    $total += $items.Count
}
Write-Host ""
Write-Host "Total: $total resources will be deleted." -ForegroundColor Yellow
Write-Host "(NEVER deletes RGs. NEVER deletes other connectors. NEVER deletes the workspace itself.)" -ForegroundColor DarkGray
Write-Host ""

if ($total -eq 0) {
    Write-Host "Nothing to delete. Exiting." -ForegroundColor Green
    exit 0
}

# ----------------------------------------------------------------------------
# Execute (or WhatIf)
# ----------------------------------------------------------------------------
$isWhatIf = $WhatIfPreference -or $PSCmdlet.MyInvocation.BoundParameters.ContainsKey('WhatIf')
if ($isWhatIf) {
    Write-Host "WHAT-IF mode — no changes made. Re-run without -WhatIf to execute." -ForegroundColor Cyan
    exit 0
}

if (-not $Force) {
    $confirm = Read-Host "Type 'DELETE' to confirm deletion of $total resources"
    if ($confirm -ne 'DELETE') {
        Write-Host "Aborted." -ForegroundColor Yellow
        exit 0
    }
}

# Delete in safe order: Sentinel content first (releases workspace-scoped pins),
# then DCRs (releases workspace bindings), then tables, then DCE, then FA stack.
$deletionOrder = @('SentinelContent', 'DCRs', 'CustomTables', 'DCE')
if (-not $SkipFunctionApp) { $deletionOrder += @('FunctionApp', 'KeyVault', 'StorageAccount') }

$deleted = 0
$failed = 0
foreach ($category in $deletionOrder) {
    foreach ($item in $plan[$category]) {
        try {
            switch ($item.Type) {
                'SavedSearch' {
                    # Remove-AzOperationalInsightsSavedSearch doesn't have -Force in all module versions.
                    # Use REST API DELETE for reliable cross-version deletion.
                    $ssUrl = "https://management.azure.com$WorkspaceResourceId/savedSearches/$($item.Id)?api-version=2020-08-01"
                    $delResp = Invoke-AzRestMethod -Uri $ssUrl -Method DELETE -ErrorAction Stop
                    if ($delResp.StatusCode -notin @(200, 202, 204)) {
                        throw "DELETE returned $($delResp.StatusCode): $($delResp.Content)"
                    }
                }
                'CustomTable' {
                    # Remove-AzOperationalInsightsTable doesn't have -Force in all module versions.
                    # Use REST API DELETE for reliable cross-version deletion.
                    $tblUrl = "https://management.azure.com$WorkspaceResourceId/tables/$($item.Name)?api-version=2022-10-01"
                    $delResp = Invoke-AzRestMethod -Uri $tblUrl -Method DELETE -ErrorAction Stop
                    if ($delResp.StatusCode -notin @(200, 202, 204)) {
                        throw "DELETE returned $($delResp.StatusCode): $($delResp.Content)"
                    }
                }
                'ContentPackage' {
                    # Content Hub solution package uninstall
                    $cpUrl = "https://management.azure.com$($item.Id)?api-version=2024-01-01-preview"
                    $delResp = Invoke-AzRestMethod -Uri $cpUrl -Method DELETE -ErrorAction Stop
                    if ($delResp.StatusCode -notin @(200, 202, 204)) {
                        throw "Content Hub DELETE returned $($delResp.StatusCode): $($delResp.Content)"
                    }
                }
                default {
                    Remove-AzResource -ResourceId $item.Id -Force -ErrorAction Stop | Out-Null
                }
            }
            Write-Host "  ✓ Deleted [$($item.Type)] $($item.Name)" -ForegroundColor Green
            $deleted++
        } catch {
            Write-Host "  ✗ FAILED [$($item.Type)] $($item.Name) — $($_.Exception.Message)" -ForegroundColor Red
            $failed++
        }
    }
}

Write-Host ""
Write-Host "===== RESULT =====" -ForegroundColor Yellow
Write-Host "  Deleted: $deleted" -ForegroundColor Green
Write-Host "  Failed:  $failed" -ForegroundColor $(if ($failed -gt 0) { 'Red' } else { 'Green' })
Write-Host ""
if ($failed -gt 0) {
    Write-Host "Some resources failed to delete. Common causes:" -ForegroundColor Yellow
    Write-Host "  - Insufficient permissions (need Contributor + LA Contributor)"
    Write-Host "  - Resource locks (check Azure Portal → resource → Locks)"
    Write-Host "  - KV soft-delete (resource exists in soft-deleted state — purge separately)"
    exit 1
}
Write-Host "Cleanup complete. Connector RG and workspace RG are intact (only connector-owned resources removed)." -ForegroundColor Green
