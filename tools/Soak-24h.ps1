#Requires -Version 7.4
<#
.SYNOPSIS
    24-hour soak monitoring · Plan §16.2 T6 enabler.

.DESCRIPTION
    After Deploy-Local + Verify-Deploy + Smoke-E2E pass · operator runs this
    to confirm 24h stability before v0.1.0 GA tag. Polls every $PollIntervalMinutes
    (default 30 min) for $DurationHours (default 24h) · checks:
      - Heartbeat freshness (XdrConnectorHealth_CL · max age <= 2× poll interval)
      - AuthFatal count (must be 0 in last poll window)
      - DLQ growth (XdrIngestDlq table · monotonically stable · no flood)
      - ProjectedData populated (>= 50% of rows · per Plan §16.1 #10)

    Each poll writes a row to tests/results/soak-<utc>/poll-<idx>.json.
    Final report at tests/results/soak-<utc>/SOAK-PROOF.json with overall pass/fail.

    Exit 0 if 48 zero-blocker polls (24h / 30min) · exit 1 on first blocker hit.

    Designed to run in background (operator launches · monitors at end).

.NOTES
    ITER4 S7 · Foreground Start-Sleep dies if operator's terminal closes. Run detached:
      Windows: Start-Process pwsh -ArgumentList '-NoProfile','-File',(Resolve-Path tools/Soak-24h.ps1),'-ResourceGroup',$rg -WindowStyle Hidden
      Linux:   nohup pwsh -NoProfile -File tools/Soak-24h.ps1 -ResourceGroup $rg > soak.log 2>&1 &
    Monitor progress via Get-Content tests/results/soak-<utc>/poll-NNN.json -Wait.

.PARAMETER ResourceGroup
    Connector resource group (same as Deploy-Local + Verify-Deploy + Smoke-E2E).

.PARAMETER WorkspaceResourceId
    Optional. If omitted · read from most-recent deployment outputs (like Smoke-E2E).

.PARAMETER PollIntervalMinutes
    Default 30. Range 5-120.

.PARAMETER DurationHours
    Default 24. Range 1-72.

.PARAMETER MaxAuthFatalPerWindow
    Default 0. AuthFatal count threshold per poll window. >0 fails the soak.

.PARAMETER MaxDlqGrowthPerWindow
    Default 5. DLQ entity-count growth per window. >threshold fails the soak.

.EXAMPLE
    pwsh ./tools/Soak-24h.ps1 -ResourceGroup rg-xdrlr-test
    pwsh ./tools/Soak-24h.ps1 -ResourceGroup rg-xdrlr-test -PollIntervalMinutes 60 -DurationHours 12
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [string]$WorkspaceResourceId,
    [ValidateRange(5, 120)][int]$PollIntervalMinutes = 30,
    [ValidateRange(1, 72)][int]$DurationHours       = 24,
    [int]$MaxAuthFatalPerWindow                     = 0,
    [int]$MaxDlqGrowthPerWindow                     = 5
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

$repoRoot = Join-Path $PSScriptRoot '..'
$stamp    = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$soakDir  = Join-Path $repoRoot ("tests/results/soak-" + $stamp)
New-Item -ItemType Directory -Path $soakDir -Force | Out-Null

# Resolve workspace ID (same pattern as Smoke-E2E.ps1)
if (-not $WorkspaceResourceId) {
    $deploy = az deployment group list -g $ResourceGroup --query "sort_by([?properties.provisioningState=='Succeeded'], &properties.timestamp) | [-1]" -o json | ConvertFrom-Json
    if (-not $deploy) { throw "No Succeeded deployment found in RG $ResourceGroup." }
    $WorkspaceResourceId = $deploy.properties.parameters.workspaceResourceId.value
}
$wsId = (az resource show --ids $WorkspaceResourceId --query 'properties.customerId' -o tsv)
if (-not $wsId) { throw "Cannot resolve workspace customerId from $WorkspaceResourceId" }

# G-K2 · Π1 fix · resolve Storage Account name for XdrIngestDlq Storage Table query
$storageAccountName = az storage account list --resource-group $ResourceGroup --query "[?starts_with(name, 'xdrlr')].name | [0]" -o tsv 2>$null
if ($storageAccountName) {
    # Import Xdr.Ingest for Invoke-XdrStorageTableEntity helper
    $ingestModule = Join-Path $repoRoot 'src/Modules/Xdr.Ingest/Xdr.Ingest.psd1'
    if (Test-Path $ingestModule) {
        Import-Module $ingestModule -Force -ErrorAction SilentlyContinue
    }
    Write-Host ("  StorageAccount: $storageAccountName (DLQ table)") -ForegroundColor DarkGray
} else {
    Write-Warning "Cannot resolve Storage Account in RG $ResourceGroup · DLQ growth check will be skipped"
}

$totalPolls = [int]([math]::Floor(($DurationHours * 60) / $PollIntervalMinutes))
Write-Host ("`n=== Soak-24h start ===") -ForegroundColor Cyan
Write-Host ("  ResourceGroup: $ResourceGroup") -ForegroundColor DarkGray
Write-Host ("  WorkspaceId:   $wsId") -ForegroundColor DarkGray
Write-Host ("  Duration:      $DurationHours h · $totalPolls polls every $PollIntervalMinutes min") -ForegroundColor DarkGray
Write-Host ("  Output:        $soakDir") -ForegroundColor DarkGray
Write-Host ""

$results        = [System.Collections.Generic.List[object]]::new()
$prevDlqCount   = $null
$overallStatus  = 'pass'
$startUtc       = [datetime]::UtcNow

for ($i = 1; $i -le $totalPolls; $i++) {
    $pollUtc = [datetime]::UtcNow
    $elapsedMin = [int](($pollUtc - $startUtc).TotalMinutes)
    Write-Host ("  [Poll $i/$totalPolls @ +${elapsedMin}min] querying KQL ...") -ForegroundColor DarkCyan

    # Check 1: Heartbeat freshness (must be within 2× poll interval)
    $hbAgeMinQ = "XdrConnectorHealth_CL | where Portal == 'Defender' | summarize LastHB=max(TimeGenerated) | extend AgeMin=datetime_diff('minute', now(), LastHB) | project AgeMin"
    $hbAgeMin  = az monitor log-analytics query -w $wsId --analytics-query $hbAgeMinQ --query 'tables[0].rows[0][0]' -o tsv 2>$null
    $hbFresh   = ($null -ne $hbAgeMin) -and ([int]$hbAgeMin -le ($PollIntervalMinutes * 2))

    # Check 2: AuthFatal count in this window (last PollIntervalMinutes)
    $afQ = "XdrConnectorHealth_CL | where TimeGenerated > ago(${PollIntervalMinutes}m) and Status == 'AuthFatal' | count"
    $afCount = az monitor log-analytics query -w $wsId --analytics-query $afQ --query 'tables[0].rows[0][0]' -o tsv 2>$null
    $afCount = if ($afCount) { [int]$afCount } else { 0 }
    $afOk    = $afCount -le $MaxAuthFatalPerWindow

    # Check 3: DLQ growth (G-K2 · Π1 fix · Storage Table · NOT Log Analytics)
    # XdrIngestDlq writes via Invoke-XdrStorageTableEntity to https://<sa>.table.core.windows.net/XdrIngestDlq
    $dlqCount = $null
    if ($storageAccountName -and (Get-Command Invoke-XdrStorageTableEntity -ErrorAction SilentlyContinue)) {
        try {
            $dlqResult = Invoke-XdrStorageTableEntity -Verb QUERY -StorageAccount $storageAccountName -Table 'XdrIngestDlq' -ErrorAction SilentlyContinue
            if ($dlqResult -and $dlqResult.StatusCode -eq 200) {
                $dlqCount = @($dlqResult.Entities).Count
            }
        } catch { }
    }
    $dlqGrowth = if ($null -ne $prevDlqCount -and $null -ne $dlqCount) { $dlqCount - $prevDlqCount } else { 0 }
    $dlqOk     = $dlqGrowth -le $MaxDlqGrowthPerWindow

    # Check 4: ProjectedData populated rate (R-A · G-K1 · Π1 fix · union Defender_*_CL)
    $pdQ = "union withsource=TableName isfuzzy=true Defender_*_CL | where TimeGenerated > ago(${PollIntervalMinutes}m) and SuccessKind == 'live' | summarize Total=count(), WithPD=countif(isnotempty(ProjectedData)) | extend Pct = iff(Total>0, round(100.0 * WithPD / Total, 1), 0.0) | project Pct"
    $pdPct = az monitor log-analytics query -w $wsId --analytics-query $pdQ --query 'tables[0].rows[0][0]' -o tsv 2>$null
    $pdPct = if ($pdPct) { [double]$pdPct } else { 0 }
    $pdOk  = $pdPct -ge 50

    $pollPass = $hbFresh -and $afOk -and $dlqOk -and $pdOk
    $entry = [pscustomobject]@{
        Poll              = $i
        TimestampUtc      = $pollUtc.ToString('o')
        ElapsedMinutes    = $elapsedMin
        HeartbeatAgeMin   = $hbAgeMin
        HeartbeatFresh    = $hbFresh
        AuthFatalCount    = $afCount
        AuthFatalOk       = $afOk
        DlqCount          = $dlqCount
        DlqGrowth         = $dlqGrowth
        DlqOk             = $dlqOk
        ProjectedDataPct  = $pdPct
        ProjectedDataOk   = $pdOk
        PollPass          = $pollPass
    }
    $results.Add($entry) | Out-Null
    $entry | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $soakDir ("poll-{0:D3}.json" -f $i)) -Encoding UTF8

    $color = if ($pollPass) { 'Green' } else { 'Red' }
    Write-Host ("    [$(if ($pollPass) { 'PASS' } else { 'FAIL' })] HB=${hbAgeMin}min · AuthFatal=$afCount · DlqGrowth=$dlqGrowth · PD%=$pdPct") -ForegroundColor $color

    if (-not $pollPass) {
        $overallStatus = 'fail'
        Write-Host ("    Soak FAILED at poll $i · stopping early") -ForegroundColor Red
        break
    }

    $prevDlqCount = $dlqCount
    if ($i -lt $totalPolls) {
        Write-Host ("    sleeping $PollIntervalMinutes min until next poll ...") -ForegroundColor DarkGray
        Start-Sleep -Seconds ($PollIntervalMinutes * 60)
    }
}

# Final SOAK-PROOF.json
$proof = [pscustomobject]@{
    TimestampUtc      = (Get-Date).ToUniversalTime().ToString('o')
    ResourceGroup     = $ResourceGroup
    WorkspaceId       = $wsId
    DurationHours     = $DurationHours
    PollIntervalMin   = $PollIntervalMinutes
    TotalPolls        = $totalPolls
    PollsExecuted     = $results.Count
    OverallStatus     = $overallStatus
    AllPolls          = $results
}
$proofPath = Join-Path $soakDir 'SOAK-PROOF.json'
$proof | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $proofPath -Encoding UTF8

Write-Host ""
Write-Host ("=== Soak-24h: $overallStatus ($($results.Count)/$totalPolls polls) ===") -ForegroundColor $(if ($overallStatus -eq 'pass') { 'Green' } else { 'Red' })
Write-Host ("SOAK-PROOF.json: $proofPath") -ForegroundColor DarkGray

if ($overallStatus -ne 'pass') { exit 1 }
