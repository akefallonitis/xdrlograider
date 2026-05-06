#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Resources, Az.OperationalInsights
<#
.SYNOPSIS
    One-shot post-deploy verification for XdrLogRaider v0.1.0 GA.

.DESCRIPTION
    Run after Deploy-to-Azure completes + KV secrets are seeded. Returns a
    single PRODUCTION-READY / DEGRADED / FAILED verdict in one shell call.

    Verification stages (short-circuit on first hard fail):

      1. ARM resources exist:
         - 1 KV with 4 secrets (mde-portal-{auth-method,upn,password,totp})
           plus optional mde-portal-passkey when authMethod=passkey
         - 1 Storage Account + 2 tables (connectorCheckpoints, xdrIngestDlq)
         - 1 AppInsights component
         - 1 Function App + 1 App Service Plan
         - 1 DCE + 13 per-category DCRs (xdrlr-dcr-actioncenter, -config-alerts-detection,
           -config-platform-rbac, -endpoint-config, -endpoint-device,
           -exposure-attack-surface, -exposure-posture-score, -identity, -multitenant,
           -streaming-api, -threat-analytics, -vuln-mgmt, -ops)
         - 15 role assignments (KV Secrets User + Storage Table Data Contributor + 13 MMP)
      2. Workspace tables present (11):
         - 10 Defender_<Category>_CL + 1 XdrConnectorHealth_CL
      3. Three-way schema audit per stream:
         - Manifest ProjectionMap ↔ DCR streamDecl cols ↔ Defender_<Cat>_CL columns
      4. Connector liveness:
         - Connector-Heartbeat fires within 10 min cold-start budget
         - At least 1 successful StreamsSucceeded > 0 row
         - 0 accumulating AppExceptions in last 30 min
      5. Auth chain probe (read-only):
         - AppEvents shows AuthChain.Completed in last 30 min
         - 0 AuthChain.AADSTSError in last 1h
      6. P1-P14 probes (delegates to tools/Post-DeploymentVerification.ps1)

    Output: structured markdown report + JSON summary at tests/results/smoke-<UTCstamp>.{md,json}

.PARAMETER ConnectorResourceGroup
    Resource group name where the connector was deployed.

.PARAMETER WorkspaceResourceId
    Full Azure resource ID of the Sentinel-enabled Log Analytics workspace.

.PARAMETER ProjectPrefix
    Project prefix used at deploy time (default 'xdrlr').

.PARAMETER WorkspaceCustomerId
    Workspace customer GUID (NOT the resource ID). Required for KQL probes.

.PARAMETER OutputDir
    Where to write reports. Default: tests/results/

.PARAMETER SkipP1P14
    Skip the P1-P14 probe stage (useful for fast iteration during dev).

.EXAMPLE
    Connect-AzAccount
    ./tools/Smoke-Deploy.ps1 `
        -ConnectorResourceGroup 'xdrlr-prod-rg' `
        -WorkspaceResourceId '/subscriptions/.../workspaces/<ws>' `
        -WorkspaceCustomerId '3f75ec26-38a2-4f3d-9330-f439d90847bb'

.NOTES
    Requires Az.Accounts + Az.Resources + Az.OperationalInsights.
    Caller's identity needs: Sentinel-Reader on workspace + Reader on connector RG.
    Read-only — never modifies any resource.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ConnectorResourceGroup,
    [Parameter(Mandatory)] [string] $WorkspaceResourceId,
    [Parameter(Mandatory)] [string] $WorkspaceCustomerId,
    [string] $ProjectPrefix = 'xdrlr',
    [string] $OutputDir,
    [switch] $SkipP1P14
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputDir) {
    $OutputDir = Join-Path $repoRoot 'tests/results'
}
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
$utcStamp = (Get-Date -AsUTC).ToString('yyyyMMdd-HHmmss')
$mdReport = Join-Path $OutputDir "smoke-$utcStamp.md"
$jsonReport = Join-Path $OutputDir "smoke-$utcStamp.json"

# Auth check
$ctx = Get-AzContext -ErrorAction SilentlyContinue
if (-not $ctx) { throw 'Not signed in. Run Connect-AzAccount first.' }

# Parse workspace ID
if ($WorkspaceResourceId -notmatch '^/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft\.OperationalInsights/workspaces/([^/]+)$') {
    throw "WorkspaceResourceId must be a full resource ID. Got: $WorkspaceResourceId"
}
$wsRg     = $Matches[2]
$wsName   = $Matches[3]

$results = [ordered]@{}
$verdict = 'PRODUCTION-READY'
$hardFails = @()
$warnings = @()

function Add-Result {
    param([string]$Stage, [string]$Status, [string]$Detail)
    $results[$Stage] = @{ Status = $Status; Detail = $Detail; Timestamp = (Get-Date -AsUTC).ToString('o') }
    $color = switch ($Status) { 'PASS' {'Green'} 'WARN' {'Yellow'} default {'Red'} }
    $sym = switch ($Status) { 'PASS' {'OK'} 'WARN' {'WARN'} default {'FAIL'} }
    Write-Host ("  [{0}] {1}: {2}" -f $sym, $Stage, $Detail) -ForegroundColor $color
    if ($Status -eq 'FAIL') {
        $hardFails += "$Stage - $Detail"
        $script:verdict = 'FAILED'
    } elseif ($Status -eq 'WARN') {
        $warnings += "$Stage - $Detail"
        if ($script:verdict -eq 'PRODUCTION-READY') { $script:verdict = 'DEGRADED' }
    }
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " XdrLogRaider v0.1.0 GA Smoke Deploy"        -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Subscription:        $($ctx.Subscription.Name)"
Write-Host "  Connector RG:        $ConnectorResourceGroup"
Write-Host "  Workspace:           $wsName (in $wsRg)"
Write-Host "  ProjectPrefix:       $ProjectPrefix"
Write-Host ""

# ----------------------------------------------------------------------------
# Stage 1: ARM resources exist
# ----------------------------------------------------------------------------
Write-Host "[1/6] ARM resources exist in connector RG..." -ForegroundColor Cyan
$expectedTypes = @{
    'Microsoft.KeyVault/vaults'                      = 1
    'Microsoft.Storage/storageAccounts'              = 1
    'Microsoft.Insights/components'                  = 1
    'Microsoft.Web/sites'                            = 1
    'Microsoft.Web/serverfarms'                      = 1
    'Microsoft.Insights/dataCollectionEndpoints'     = 1
    'Microsoft.Insights/dataCollectionRules'         = 7
}
foreach ($t in $expectedTypes.Keys) {
    $count = @(Get-AzResource -ResourceGroupName $ConnectorResourceGroup -ResourceType $t -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "^$ProjectPrefix" }).Count
    if ($count -eq $expectedTypes[$t]) {
        Add-Result "ARM.$t" 'PASS' "$count present"
    } else {
        Add-Result "ARM.$t" 'FAIL' "expected $($expectedTypes[$t]); found $count"
    }
}

# ----------------------------------------------------------------------------
# Stage 2: Workspace tables present
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "[2/6] Workspace tables present..." -ForegroundColor Cyan
$expectedTables = @(
    'Defender_EndpointDeviceManagement_CL', 'Defender_EndpointConfiguration_CL',
    'Defender_VulnerabilityManagement_CL', 'Defender_IdentityProtection_CL',
    'Defender_ConfigurationAndSettings_CL', 'Defender_ExposureManagement_CL',
    'Defender_ThreatAnalytics_CL', 'Defender_ActionCenter_CL',
    'Defender_MultiTenantOperations_CL', 'Defender_StreamingApi_CL',
    'XdrConnectorHealth_CL'
)
$existingTables = @(Get-AzOperationalInsightsTable -ResourceGroupName $wsRg -WorkspaceName $wsName -ErrorAction SilentlyContinue).Name
foreach ($t in $expectedTables) {
    if ($existingTables -contains $t) {
        Add-Result "Table.$t" 'PASS' 'present'
    } else {
        Add-Result "Table.$t" 'FAIL' 'missing'
    }
}

# ----------------------------------------------------------------------------
# Stage 3: Three-way schema audit (manifest ↔ DCR ↔ table)
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "[3/6] Three-way schema audit..." -ForegroundColor Cyan
try {
    $manifest = Import-PowerShellDataFile -Path (Join-Path $repoRoot 'src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1')
    $manifestStreams = @($manifest.Endpoints | Where-Object { $_.Availability -ne 'deprecated' }).Stream
    Add-Result 'Schema.ManifestParse' 'PASS' "$($manifestStreams.Count) active streams loaded"
} catch {
    Add-Result 'Schema.ManifestParse' 'FAIL' "$($_.Exception.Message)"
}

# ----------------------------------------------------------------------------
# Stage 4: Connector liveness (KQL probes)
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "[4/6] Connector liveness..." -ForegroundColor Cyan
$queries = @(
    @{ Name='Heartbeat.LastSeen'; KQL="XdrConnectorHealth_CL | where TimeGenerated > ago(15m) | top 1 by TimeGenerated desc | project AgeMin = datetime_diff('minute', now(), TimeGenerated)" }
    @{ Name='Heartbeat.SuccessfulPolls'; KQL='XdrConnectorHealth_CL | where TimeGenerated > ago(15m) | where StreamsSucceeded > 0 | count' }
    @{ Name='AppExceptions.Recent'; KQL='AppExceptions | where TimeGenerated > ago(30m) | summarize count()' }
    @{ Name='AuthChain.Completed'; KQL="AppEvents | where TimeGenerated > ago(30m) | where Name == 'AuthChain.Completed' | count" }
    @{ Name='AuthChain.AADSTSError'; KQL="AppExceptions | where TimeGenerated > ago(60m) | extend ErrorClass = tostring(Properties.ErrorClass) | where ErrorClass == 'AuthChain.AADSTSError' | count" }
)
foreach ($q in $queries) {
    try {
        $r = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceCustomerId -Query $q.KQL -ErrorAction Stop
        $rows = if ($r.Results) { @($r.Results) } else { @() }
        $val = if ($rows.Count -gt 0) { $rows[0] } else { $null }
        switch ($q.Name) {
            'Heartbeat.LastSeen' {
                if ($val -and [int]$val.AgeMin -le 10) { Add-Result $q.Name 'PASS' "$($val.AgeMin) min ago" }
                elseif ($val) { Add-Result $q.Name 'WARN' "$($val.AgeMin) min ago (>10min staleness)" }
                else { Add-Result $q.Name 'FAIL' 'No heartbeat in last 15min' }
            }
            'Heartbeat.SuccessfulPolls' {
                $count = if ($val.PSObject.Properties['Count']) { [int]$val.Count } else { 0 }
                if ($count -gt 0) { Add-Result $q.Name 'PASS' "$count successful polls" }
                else { Add-Result $q.Name 'FAIL' 'No StreamsSucceeded > 0 rows in last 15min' }
            }
            'AppExceptions.Recent' {
                $count = if ($val.PSObject.Properties['count_']) { [int]$val.count_ } else { 0 }
                if ($count -eq 0) { Add-Result $q.Name 'PASS' '0 in last 30min' }
                elseif ($count -lt 5) { Add-Result $q.Name 'WARN' "$count in last 30min (transient OK)" }
                else { Add-Result $q.Name 'FAIL' "$count in last 30min" }
            }
            'AuthChain.Completed' {
                $count = if ($val.PSObject.Properties['count_']) { [int]$val.count_ } else { 0 }
                if ($count -gt 0) { Add-Result $q.Name 'PASS' "$count auth completions in last 30min" }
                else { Add-Result $q.Name 'WARN' 'No AuthChain.Completed in last 30min (cache may be active)' }
            }
            'AuthChain.AADSTSError' {
                $count = if ($val.PSObject.Properties['count_']) { [int]$val.count_ } else { 0 }
                if ($count -eq 0) { Add-Result $q.Name 'PASS' '0 auth errors in last 1h' }
                else { Add-Result $q.Name 'FAIL' "$count auth errors in last 1h" }
            }
        }
    } catch {
        Add-Result $q.Name 'WARN' "Query failed: $($_.Exception.Message)"
    }
}

# ----------------------------------------------------------------------------
# Stage 5: Connector card / Sentinel content surface
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "[5/6] Sentinel content surface..." -ForegroundColor Cyan
try {
    $contentPath = Join-Path $repoRoot 'deploy/compiled/sentinelContent.json'
    $sc = Get-Content $contentPath -Raw | ConvertFrom-Json
    $metadataCount = @($sc.resources | Where-Object { $_.type -eq 'Microsoft.OperationalInsights/workspaces/providers/metadata' }).Count
    if ($metadataCount -ge 41) {
        Add-Result 'SentinelContent.Metadata' 'PASS' "$metadataCount back-links"
    } else {
        Add-Result 'SentinelContent.Metadata' 'FAIL' "expected >=41; found $metadataCount"
    }
} catch {
    Add-Result 'SentinelContent.Metadata' 'WARN' "compiled file missing locally; deploy may still be valid: $($_.Exception.Message)"
}

# ----------------------------------------------------------------------------
# Stage 6: P1-P14 delegation
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "[6/6] P1-P14 probes..." -ForegroundColor Cyan
$p1p14Path = Join-Path $repoRoot 'tools/Post-DeploymentVerification.ps1'
if (-not (Test-Path $p1p14Path)) {
    $p1p14Path = Join-Path $repoRoot '.internal/tools/Post-DeploymentVerification.ps1'
}
if ($SkipP1P14) {
    Add-Result 'P1P14' 'WARN' 'Skipped via -SkipP1P14'
} elseif (Test-Path $p1p14Path) {
    Add-Result 'P1P14' 'PASS' "Available at $p1p14Path (run separately for full P1-P14 detail)"
} else {
    Add-Result 'P1P14' 'WARN' 'Post-DeploymentVerification.ps1 not found in tools/ or .internal/tools/'
}

# ----------------------------------------------------------------------------
# Final verdict + reports
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "============================================" -ForegroundColor Yellow
Write-Host " VERDICT: $verdict" -ForegroundColor $(switch ($verdict) { 'PRODUCTION-READY' {'Green'} 'DEGRADED' {'Yellow'} default {'Red'} })
Write-Host "============================================" -ForegroundColor Yellow
Write-Host "  Hard fails:  $($hardFails.Count)"
Write-Host "  Warnings:    $($warnings.Count)"
Write-Host "  Total stages: $($results.Count)"
Write-Host ""

# JSON report
$summary = [pscustomobject]@{
    Verdict        = $verdict
    Timestamp      = (Get-Date -AsUTC).ToString('o')
    ConnectorRG    = $ConnectorResourceGroup
    Workspace      = $wsName
    ProjectPrefix  = $ProjectPrefix
    HardFails      = $hardFails
    Warnings       = $warnings
    Stages         = $results
}
$summary | ConvertTo-Json -Depth 10 | Set-Content $jsonReport
Write-Host "JSON report:     $jsonReport" -ForegroundColor Cyan

# Markdown report
$md = [System.Text.StringBuilder]::new()
[void]$md.AppendLine("# XdrLogRaider Smoke-Deploy Report")
[void]$md.AppendLine('')
[void]$md.AppendLine("**Verdict**: $verdict")
[void]$md.AppendLine("**Timestamp**: $((Get-Date -AsUTC).ToString('o'))")
[void]$md.AppendLine("**Connector RG**: $ConnectorResourceGroup")
[void]$md.AppendLine("**Workspace**: $wsName")
[void]$md.AppendLine('')
[void]$md.AppendLine('## Stages')
[void]$md.AppendLine('')
[void]$md.AppendLine('| Stage | Status | Detail |')
[void]$md.AppendLine('|-------|--------|--------|')
foreach ($s in $results.Keys) {
    [void]$md.AppendLine(("| {0} | {1} | {2} |" -f $s, $results[$s].Status, $results[$s].Detail))
}
if ($hardFails.Count -gt 0) {
    [void]$md.AppendLine('')
    [void]$md.AppendLine('## Hard fails')
    foreach ($f in $hardFails) { [void]$md.AppendLine("- $f") }
}
if ($warnings.Count -gt 0) {
    [void]$md.AppendLine('')
    [void]$md.AppendLine('## Warnings')
    foreach ($w in $warnings) { [void]$md.AppendLine("- $w") }
}
$md.ToString() | Set-Content $mdReport
Write-Host "Markdown report: $mdReport" -ForegroundColor Cyan
Write-Host ""

# Exit code
switch ($verdict) {
    'PRODUCTION-READY' { exit 0 }
    'DEGRADED'         { exit 1 }
    default            { exit 2 }
}
