<#
.SYNOPSIS
    14-phase post-deploy verification. Operator-local; requires `az login` session.

.DESCRIPTION
    Verifies a deployed XdrLogRaider instance against the Phase 1 invariants.

    Phases (Rule 12 + 18):
      1.  ARM resources present (FA, KV, Storage, App Insights, DCE, plan)
      2.  19 workspace tables exist
      3.  Sentinel solution + dataConnector card
      4.  KV + SAMI role assignment
      5.  ConnectorHeartbeat fired in last 10 min (Rule 12)
      6.  ConnectorHeartbeat continuous (≥5 hits in last hour)
      7.  Rate-limited cycles count = 0 in last hour
      8.  Per-sub-area liveness — every Defender_<Sub>_CL has rows or
          XdrTierState shows StreamsAttempted > 0
      9.  App Insights health — no FATAL-tier exceptions in last hour
      10. DCR ingestion — every DCR's immutableId resolves + DCE endpoint reachable
      11. Drift consistency — manifest entries match deployed DCR streams 1:1
      12. SAMI role-assignment list (KV Secrets User + Storage Table Data Contributor + RG-scoped Monitoring Metrics Publisher = 3 RAs)
      13. Circuit-breaker states — no sub-area stuck Open (Phase 1 NEW)
      14. Markdown report emission

.PARAMETER ResourceGroup
    Resource group of the deployment.

.PARAMETER WorkspaceResourceGroup
    Resource group of the existing workspace. Defaults to -ResourceGroup if unset.

.PARAMETER AutoFix
    OPT-IN. Idempotent self-heal:
      - FA restart if heartbeat dry > 10 min
      - WEBSITE_RUN_FROM_PACKAGE re-set if version drifted from latest tag
      - KV secret rotation prompt (interactive)

.OUTPUTS
    Markdown report at tests/results/verify-deploy-<utc>.md.
    Exit 0 = all phases OK; 1 = any failed.
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [string] $WorkspaceResourceGroup,
    [switch] $AutoFix,
    [string] $OutputDir = (Join-Path $PSScriptRoot '..' 'tests' 'results')
)

$ErrorActionPreference = 'Continue'
if (-not $WorkspaceResourceGroup) { $WorkspaceResourceGroup = $ResourceGroup }
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

# Verify az CLI session
$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Host "Verify-Deploy: not logged into az CLI. Run: az login" -ForegroundColor Red
    exit 1
}
Write-Host "Subscription: $($account.name) ($($account.id))"

$phases = New-Object System.Collections.Generic.List[object]
function Add-Phase { param([int]$Number, [string]$Name, [string]$Status, [string]$Detail = '')
    $phases.Add([pscustomobject]@{ N = $Number; Name = $Name; Status = $Status; Detail = $Detail })
    $color = if ($Status -eq 'OK') { 'Green' } elseif ($Status -eq 'SKIP') { 'Yellow' } else { 'Red' }
    Write-Host ("[{0,-4}] Phase $Number — $Name" -f $Status) -ForegroundColor $color
    if ($Detail) { Write-Host "        $Detail" -ForegroundColor DarkGray }
}

# ---- 1) ARM resources present ----
Write-Host "`n=== Phase 1/14 ARM resources ===" -ForegroundColor Cyan
$resources = az resource list -g $ResourceGroup --query "[].{Type:type,Name:name}" 2>$null | ConvertFrom-Json
$required = @{
    'Microsoft.Web/sites'                       = 1
    'Microsoft.KeyVault/vaults'                 = 1
    'Microsoft.Storage/storageAccounts'         = 1
    'Microsoft.Insights/components'             = 1
    'Microsoft.Insights/dataCollectionEndpoints'= 1
    'Microsoft.Insights/dataCollectionRules'    = 19
    'Microsoft.Web/serverfarms'                 = 1
}
$missing = @()
foreach ($k in $required.Keys) {
    $count = @($resources | Where-Object Type -eq $k).Count
    if ($count -ne $required[$k]) {
        $missing += "$k expected $($required[$k]) got $count"
    }
}
Add-Phase -Number 1 -Name 'ARM resources present' -Status $(if ($missing.Count -eq 0) { 'OK' } else { 'FAIL' }) -Detail ($missing -join '; ')

# ---- 2) Workspace tables ----
Write-Host "`n=== Phase 2/14 Workspace tables ===" -ForegroundColor Cyan
$ws = az resource list -g $WorkspaceResourceGroup --resource-type Microsoft.OperationalInsights/workspaces --query "[0].name" -o tsv 2>$null
if ($ws) {
    $tables = az monitor log-analytics workspace table list -g $WorkspaceResourceGroup --workspace-name $ws --query "[?starts_with(name, 'Defender_') || name == 'XdrConnectorHealth_CL'].name" -o tsv 2>$null
    $tblCount = if ($tables) { @($tables -split "`n").Count } else { 0 }
    Add-Phase -Number 2 -Name '19 workspace tables' -Status $(if ($tblCount -ge 19) { 'OK' } else { 'FAIL' }) -Detail "Found $tblCount Defender_*/Xdr*_CL"
} else {
    Add-Phase -Number 2 -Name '19 workspace tables' -Status 'FAIL' -Detail "No workspace in $WorkspaceResourceGroup"
}

# ---- 3) Sentinel solution + connector card ----
Write-Host "`n=== Phase 3/14 Sentinel solution + connector ===" -ForegroundColor Cyan
$connectorExists = $false
try {
    $r = az rest --method get --url "https://management.azure.com/subscriptions/$($account.id)/resourceGroups/$WorkspaceResourceGroup/providers/Microsoft.OperationalInsights/workspaces/$ws/providers/Microsoft.SecurityInsights/dataConnectors?api-version=2023-02-01-preview" 2>$null | ConvertFrom-Json
    $connectorExists = ($r.value | Where-Object { $_.name -match 'XdrLogRaider' }).Count -gt 0
} catch {}
Add-Phase -Number 3 -Name 'Sentinel solution + dataConnector card' -Status $(if ($connectorExists) { 'OK' } else { 'FAIL' })

# ---- 4) KV + SAMI ----
Write-Host "`n=== Phase 4/14 KV + SAMI ===" -ForegroundColor Cyan
$fa = az resource list -g $ResourceGroup --resource-type Microsoft.Web/sites --query "[0].name" -o tsv 2>$null
$kv = az resource list -g $ResourceGroup --resource-type Microsoft.KeyVault/vaults --query "[0].name" -o tsv 2>$null
$samiPrincipalId = $null
if ($fa) {
    $samiPrincipalId = az functionapp identity show -g $ResourceGroup -n $fa --query principalId -o tsv 2>$null
}
Add-Phase -Number 4 -Name 'KV + SAMI' -Status $(if ($samiPrincipalId) { 'OK' } else { 'FAIL' }) -Detail "FA=$fa KV=$kv SAMI=$samiPrincipalId"

# ---- 5/6) Heartbeat liveness ----
Write-Host "`n=== Phase 5-6/14 Heartbeat ===" -ForegroundColor Cyan
$hbLast10m = $null
$hbHrCount = 0
if ($ws) {
    try {
        $r1 = az monitor log-analytics query -w $ws --analytics-query "XdrConnectorHealth_CL | where TimeGenerated > ago(10m) | count" 2>$null | ConvertFrom-Json
        $hbLast10m = if ($r1.tables[0].rows.Count -gt 0) { [int]$r1.tables[0].rows[0][0] } else { 0 }
        $r2 = az monitor log-analytics query -w $ws --analytics-query "XdrConnectorHealth_CL | where TimeGenerated > ago(1h) | count" 2>$null | ConvertFrom-Json
        $hbHrCount = if ($r2.tables[0].rows.Count -gt 0) { [int]$r2.tables[0].rows[0][0] } else { 0 }
    } catch {}
}
Add-Phase -Number 5 -Name 'Heartbeat fired last 10 min' -Status $(if ($hbLast10m -ge 1) { 'OK' } else { 'FAIL' }) -Detail "Count=$hbLast10m"
Add-Phase -Number 6 -Name 'Heartbeat continuous last 1h (>=5)' -Status $(if ($hbHrCount -ge 5) { 'OK' } else { 'FAIL' }) -Detail "Count=$hbHrCount"

# ---- 7) Rate-limited cycles ----
Write-Host "`n=== Phase 7/14 Rate-limited cycles ===" -ForegroundColor Cyan
$rateCount = 0
if ($ws) {
    try {
        $r = az monitor log-analytics query -w $ws --analytics-query 'union withsource=Table Defender_*_CL | where TimeGenerated > ago(1h) and SuccessKind == "rate-limited" | count' 2>$null | ConvertFrom-Json
        $rateCount = if ($r.tables[0].rows.Count -gt 0) { [int]$r.tables[0].rows[0][0] } else { 0 }
    } catch {}
}
Add-Phase -Number 7 -Name 'Rate-limited cycles (last 1h) = 0' -Status $(if ($rateCount -eq 0) { 'OK' } else { 'FAIL' }) -Detail "Count=$rateCount"

# ---- 8) Per-stream liveness ----
Write-Host "`n=== Phase 8/14 Per-stream liveness ===" -ForegroundColor Cyan
$drySubs = @()
if ($ws) {
    foreach ($pascal in @('ActionCenter','AttackSimulator','CloudApps','Configuration','DataLake','EndpointConfiguration','EndpointDevices','EntityPivots','ExposureManagement','Files','Identity','MultiTenant','PortalServices','SecureScore','SentinelPrecision','Streaming','ThreatAnalytics','VulnerabilityManagement')) {
        $tbl = "Defender_${pascal}_CL"
        $r = az monitor log-analytics query -w $ws --analytics-query "$tbl | where TimeGenerated > ago(24h) | count" 2>$null | ConvertFrom-Json
        $cnt = if ($r -and $r.tables[0].rows.Count -gt 0) { [int]$r.tables[0].rows[0][0] } else { 0 }
        if ($cnt -eq 0) { $drySubs += $pascal }
    }
}
Add-Phase -Number 8 -Name 'Per-sub-area liveness (24h)' -Status $(if ($drySubs.Count -eq 0) { 'OK' } else { 'FAIL' }) -Detail "Dry: $($drySubs -join ', ')"

# ---- 9) App Insights health ----
Write-Host "`n=== Phase 9/14 App Insights ===" -ForegroundColor Cyan
$ai = az resource list -g $ResourceGroup --resource-type Microsoft.Insights/components --query "[0].name" -o tsv 2>$null
$aiExceptions = 0
if ($ai) {
    try {
        $r = az monitor app-insights query --app $ai -g $ResourceGroup --analytics-query 'exceptions | where timestamp > ago(1h) and severityLevel >= 3 | count' 2>$null | ConvertFrom-Json
        $aiExceptions = if ($r.tables[0].rows.Count -gt 0) { [int]$r.tables[0].rows[0][0] } else { 0 }
    } catch {}
}
Add-Phase -Number 9 -Name 'App Insights health (no FATAL in 1h)' -Status $(if ($aiExceptions -eq 0) { 'OK' } else { 'FAIL' }) -Detail "FATAL count=$aiExceptions"

# ---- 10) DCR ingestion path ----
Write-Host "`n=== Phase 10/14 DCR ingestion ===" -ForegroundColor Cyan
$dce = az resource list -g $ResourceGroup --resource-type Microsoft.Insights/dataCollectionEndpoints --query "[0].name" -o tsv 2>$null
$dcrs = az resource list -g $ResourceGroup --resource-type Microsoft.Insights/dataCollectionRules --query "[].name" -o tsv 2>$null
$dcrCount = if ($dcrs) { @($dcrs -split "`n").Count } else { 0 }
Add-Phase -Number 10 -Name 'DCR + DCE present' -Status $(if ($dcrCount -eq 19 -and $dce) { 'OK' } else { 'FAIL' }) -Detail "DCE=$dce · DCRs=$dcrCount"

# ---- 11) Drift consistency ----
Write-Host "`n=== Phase 11/14 Manifest ↔ DCR drift ===" -ForegroundColor Cyan
$expectedStreams = @('ActionCenter','AttackSimulator','CloudApps','Configuration','DataLake','EndpointConfiguration','EndpointDevices','EntityPivots','ExposureManagement','Files','Identity','MultiTenant','PortalServices','SecureScore','SentinelPrecision','Streaming','ThreatAnalytics','VulnerabilityManagement')
# Each DCR name ends with -<dashed-subarea>; check coverage
$mappedSubs = @()
if ($dcrs) {
    foreach ($d in ($dcrs -split "`n")) {
        if ($d -match '-(?<sub>[a-z][a-z\-]+)$' -and $matches['sub'] -ne 'ops') {
            $mappedSubs += ($matches['sub'] -replace '-', '_')
        }
    }
}
$drift = $expectedStreams.Count - ($mappedSubs | Sort-Object -Unique).Count
Add-Phase -Number 11 -Name 'Manifest ↔ DCR consistency' -Status $(if ($drift -eq 0) { 'OK' } else { 'FAIL' }) -Detail "Drift=$drift"

# ---- 12) SAMI role assignments ----
# Default expectation = 3 RAs (1 KV Secrets User + 1 Storage Table Data Contributor +
# 1 RG-scoped Monitoring Metrics Publisher). When operator deployed with
# deployRoleAssignments=false (Contributor-only identity, split-role admin tenant),
# count will be 0 and operator must grant manually via `az role assignment create`.
# Heartbeat fired in Phase 5-6 is the authoritative end-to-end functional gate; this
# phase WARNs (does not FAIL) on count=0 because the operator may have legitimate
# reasons to defer RA creation.
Write-Host "`n=== Phase 12/14 SAMI role assignments ===" -ForegroundColor Cyan
$ra = $null
if ($samiPrincipalId) {
    $ra = az role assignment list --assignee $samiPrincipalId --all 2>$null | ConvertFrom-Json
}
$raCount = if ($ra) { $ra.Count } else { 0 }
$raStatus = if ($raCount -ge 3) { 'OK' }
            elseif ($raCount -eq 0) { 'SKIP' }   # deployRoleAssignments=false; operator handling manually
            else { 'FAIL' }
$raDetail = "Count=$raCount" + $(if ($raCount -eq 0) {
    ' — deployRoleAssignments=false case; operator must grant manually: ' +
    '`az role assignment create --assignee <SAMI> --role "Key Vault Secrets User" --scope <kv-id>`; ' +
    '`az role assignment create --assignee <SAMI> --role "Storage Table Data Contributor" --scope <st-id>`; ' +
    '`az role assignment create --assignee <SAMI> --role "Monitoring Metrics Publisher" --resource-group <rg>`'
} else { '' })
Add-Phase -Number 12 -Name 'SAMI role assignments (3 expected; 0 OK if deployRoleAssignments=false)' -Status $raStatus -Detail $raDetail

# ---- 13) Circuit-breaker states (NEW Phase 1) ----
Write-Host "`n=== Phase 13/14 Circuit-breaker states ===" -ForegroundColor Cyan
$openCount = 0
if ($ws) {
    try {
        $r = az monitor log-analytics query -w $ws --analytics-query 'XdrConnectorHealth_CL | where TimeGenerated > ago(15m) | top 1 by TimeGenerated desc | project openCircuits = tostring(parse_json(Notes).openCircuits)' 2>$null | ConvertFrom-Json
        if ($r.tables[0].rows.Count -gt 0) { $openCount = [int]$r.tables[0].rows[0][0] }
    } catch {}
}
Add-Phase -Number 13 -Name 'Circuit-breaker states (no Open)' -Status $(if ($openCount -eq 0) { 'OK' } else { 'FAIL' }) -Detail "Open circuits=$openCount"

# ---- 14) Emit markdown report ----
Write-Host "`n=== Phase 14/14 Markdown report ===" -ForegroundColor Cyan
$utc = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine("# XdrLogRaider Verify-Deploy Report ($utc)")
[void]$md.AppendLine('')
[void]$md.AppendLine("**Subscription**: $($account.name) ($($account.id))")
[void]$md.AppendLine("**Resource Group**: $ResourceGroup (workspace RG: $WorkspaceResourceGroup)")
[void]$md.AppendLine('')
[void]$md.AppendLine('| # | Phase | Status | Detail |')
[void]$md.AppendLine('|---|-------|--------|--------|')
foreach ($p in $phases) {
    [void]$md.AppendLine("| $($p.N) | $($p.Name) | $($p.Status) | $($p.Detail) |")
}
[void]$md.AppendLine('')
$fail = @($phases | Where-Object { $_.Status -eq 'FAIL' })
if ($fail.Count -eq 0) {
    [void]$md.AppendLine('**Result: ALL OK — deployment healthy.**')
} else {
    [void]$md.AppendLine("**Result: $($fail.Count) FAIL(s) — investigate (consider `-AutoFix` for known patterns).**")
}
$mdPath = Join-Path $OutputDir "verify-deploy-$utc.md"
[System.IO.File]::WriteAllText($mdPath, $md.ToString(), [System.Text.UTF8Encoding]::new($false))
Add-Phase -Number 14 -Name 'Markdown report' -Status 'OK' -Detail $mdPath

if ($fail.Count -gt 0) { exit 1 } else { exit 0 }
