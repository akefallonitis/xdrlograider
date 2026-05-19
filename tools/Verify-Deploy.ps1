#Requires -Version 7.4
<#
.SYNOPSIS
    Post-deploy verification harness · drives the 7-check acceptance suite against
    a deployed XdrLogRaider Function App.

.DESCRIPTION
    Run AFTER `pwsh tools/Deploy-Local.ps1` completes. Asserts:
      1. Function App exists + is running
      2. SAMI is enabled
      3. KV secrets populated · 5 defender-* secrets (upn/password/totp/auth-method/passkey-pem · Π1 fix · G-V1)
      4. DCE endpoint reachable from the FA's outbound IP
      5. DCR routing · 1 health + 19 per-sub-area Custom-Defender_<SubArea>_CL streams (Π1 fix · G-V2)
      5b. DCR_IMMUTABLE_ID_MAP app setting populated with 19 entries (runtime stream router input)
      6. Workspace tables `Defender_*_CL` (union) ingesting · active KQL probe (Π1 fix · G-V3)
      7. Heartbeat row freshness ≤20 min via active KQL probe (Π1 fix · G-V3)

    Complements Smoke-E2E.ps1 (which exercises the runtime end-to-end). This tool
    runs LIGHTWEIGHT control-plane checks via az CLI — no TOTP burn required.

.PARAMETER ResourceGroup
    The RG where Deploy-Local.ps1 placed the connector.

.PARAMETER FunctionAppName
    Explicit FA name (defaults to '<projectPrefix>fa<random>' if omitted).

.OUTPUTS
    Exit 0 on full green · 1 on any check failure.
    Writes tests/results/iter-<utc>/verify-deploy.json with per-check status.

.EXAMPLE
    pwsh tools/Verify-Deploy.ps1 -ResourceGroup my-rg
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [string]$FunctionAppName,
    [string]$ResultsDir = (Join-Path $PSScriptRoot '..\tests\results')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$iterStamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$iterDir = Join-Path $ResultsDir ("iter-verify-{0}" -f $iterStamp)
$null = New-Item -ItemType Directory -Path $iterDir -Force

$checks = [System.Collections.Generic.List[hashtable]]::new()
function Record-Check {
    param([string]$Name, [bool]$Passed, [string]$Detail)
    $checks.Add(@{ Name=$Name; Passed=$Passed; Detail=$Detail }) | Out-Null
    $color = if ($Passed) { 'Green' } else { 'Red' }
    $mark  = if ($Passed) { '✓' } else { '✗' }
    Write-Host ("  [{0}] {1,-46} {2}" -f $mark, $Name, $Detail) -ForegroundColor $color
}

Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Verify-Deploy · post-deploy control-plane checks · RG=$ResourceGroup" -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan

# Resolve FA name if not provided
if (-not $FunctionAppName) {
    $fas = az functionapp list --resource-group $ResourceGroup --query "[?starts_with(name, 'xdrlr')].name" -o tsv 2>$null
    if (-not $fas) {
        Record-Check 'Function App discovery' $false "No 'xdrlr*' FA found in RG '$ResourceGroup'"
        $summary = [ordered]@{ Generated = (Get-Date).ToUniversalTime().ToString('o'); Passed = $false; Checks = $checks.ToArray() }
        $summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $iterDir 'verify-deploy.json') -Encoding UTF8
        exit 1
    }
    $FunctionAppName = @($fas)[0]
}

# Check 1 · FA exists + running
$faShow = az functionapp show --name $FunctionAppName --resource-group $ResourceGroup --query '{name:name, state:state, identity:identity.type, kind:kind}' -o json 2>$null | ConvertFrom-Json
$ok = ($null -ne $faShow -and $faShow.state -eq 'Running')
Record-Check '1. FA exists + Running' $ok "name=$($faShow.name) state=$($faShow.state)"

# Check 2 · SAMI enabled
$ok = ($null -ne $faShow -and $faShow.identity -eq 'SystemAssigned')
Record-Check '2. System-Assigned Managed Identity' $ok "identity=$($faShow.identity)"

# Check 3 · KV secrets populated (G-V1 · Π1 fix · ARM creates defender-* · 5 secrets incl. Passkey)
$kvs = az keyvault list --resource-group $ResourceGroup --query "[?starts_with(name, 'xdrlr')].name" -o tsv 2>$null
$kv = if ($kvs) { @($kvs)[0] } else { $null }
$appSettings = $null
if ($kv) {
    $secrets = az keyvault secret list --vault-name $kv --query "[].name" -o tsv 2>$null
    $expected = @('defender-upn','defender-password','defender-totp','defender-auth-method','defender-passkey-pem')
    $present = @($expected | Where-Object { $_ -in @($secrets) })
    $ok = $present.Count -eq $expected.Count
    Record-Check '3. KV secrets (defender-{upn,password,totp,auth-method,passkey-pem})' $ok "$($present.Count)/$($expected.Count) present"
} else {
    Record-Check '3. Key Vault present' $false 'No xdrlr* KV in RG'
}

# Check 4 · DCE endpoint reachable (DNS-only sanity · not actual ingestion)
$dces = az resource list --resource-group $ResourceGroup --resource-type 'Microsoft.Insights/dataCollectionEndpoints' --query "[].properties.logsIngestion.endpoint" -o tsv 2>$null
if ($dces) {
    $dce = @($dces)[0]
    try {
        $r = Invoke-WebRequest -Uri $dce -Method GET -TimeoutSec 10 -SkipHttpErrorCheck
        $ok = $r.StatusCode -in @(200,401,403)   # any HTTP response = reachable; 401/403 expected without bearer
        Record-Check '4. DCE endpoint reachable (DNS+TCP)' $ok "endpoint=$dce status=$($r.StatusCode)"
    } catch {
        Record-Check '4. DCE endpoint reachable' $false "exception: $($_.Exception.Message)"
    }
} else {
    Record-Check '4. DCE present' $false 'No DCE in RG'
}

# Check 5 · DCR routing for per-sub-area architecture (G-V2 · Π1 fix · 1 health + 19 per-sub-area)
$dcrs = @(az resource list --resource-group $ResourceGroup --resource-type 'Microsoft.Insights/dataCollectionRules' --query "[].name" -o tsv 2>$null)
$dcrCheck = $false
$healthOk = $false
$subAreaStreamCount = 0
if ($dcrs.Count -gt 0) {
    foreach ($dcrName in $dcrs) {
        $dcrJson = az monitor data-collection rule show --resource-group $ResourceGroup --name $dcrName -o json 2>$null | ConvertFrom-Json
        if (-not $dcrJson) { continue }
        $streamNames = @($dcrJson.properties.streamDeclarations.PSObject.Properties.Name)
        if ('Custom-XdrConnectorHealth_CL' -in $streamNames) { $healthOk = $true }
        foreach ($s in $streamNames) {
            if ($s -match '^Custom-Defender_[A-Za-z]+_CL$') { $subAreaStreamCount++ }
        }
    }
    $dcrCheck = $healthOk -and ($subAreaStreamCount -ge 19) -and ($dcrs.Count -ge 20)
    Record-Check '5. DCR routing (1 health + 19 per-sub-area)' $dcrCheck "$($dcrs.Count) DCRs · health=$healthOk · sub-area streams=$subAreaStreamCount/19"
} else {
    Record-Check '5. DCRs present' $false 'No DCRs found in RG'
}

# Check 5b · DCR_IMMUTABLE_ID_MAP app setting populated (G-V2 · runtime stream router input)
$appSettings = az functionapp config appsettings list --name $FunctionAppName --resource-group $ResourceGroup -o json 2>$null | ConvertFrom-Json
$dcrMapSetting = @($appSettings | Where-Object { $_.name -eq 'DCR_IMMUTABLE_ID_MAP' })
if ($dcrMapSetting.Count -gt 0 -and $dcrMapSetting[0].value) {
    try {
        $dcrMapJson = $dcrMapSetting[0].value | ConvertFrom-Json
        $mapCount = @($dcrMapJson).Count
        Record-Check '5b. DCR_IMMUTABLE_ID_MAP app setting (19 sub-area entries)' ($mapCount -ge 19) "$mapCount entries in map"
    } catch {
        Record-Check '5b. DCR_IMMUTABLE_ID_MAP parseable JSON' $false "parse failed: $($_.Exception.Message)"
    }
} else {
    Record-Check '5b. DCR_IMMUTABLE_ID_MAP app setting present' $false 'app setting not found · stream router will fail at runtime'
}

# Check 6 + 7 · active KQL probes against workspace (G-V3 · Π1 fix · removes soft-skip)
$wsId = $null
$deploy = az deployment group list -g $ResourceGroup --query "sort_by([?properties.provisioningState=='Succeeded'], &properties.timestamp) | [-1]" -o json 2>$null | ConvertFrom-Json
if ($deploy -and $deploy.properties -and $deploy.properties.parameters.PSObject.Properties['workspaceResourceId']) {
    $wsArmId = $deploy.properties.parameters.workspaceResourceId.value
    $wsId = az resource show --ids $wsArmId --query 'properties.customerId' -o tsv 2>$null
}

if ($wsId) {
    # Check 6 · Workspace tables Defender_*_CL ingesting (table-creation gate · ~10min lag post-deploy)
    $q6 = "union withsource=TableName isfuzzy=true Defender_*_CL | where TimeGenerated > ago(2h) | summarize n=count()"
    $rows6 = az monitor log-analytics query -w $wsId --analytics-query $q6 --query 'tables[0].rows[0][0]' -o tsv 2>$null
    $ok6 = ($null -ne $rows6 -and [int]$rows6 -ge 1)
    Record-Check '6. Workspace tables Defender_*_CL ingesting (last 2h)' $ok6 "rows: $rows6 (≥1 expected ~10min post-deploy + first-cycle)"

    # Check 7 · Heartbeat freshness (≤20min · accounts for 5min timer + 15min table-creation lag)
    $q7 = "XdrConnectorHealth_CL | summarize LastHB=max(TimeGenerated) | extend AgeMin=datetime_diff('minute', now(), LastHB) | project AgeMin"
    $age = az monitor log-analytics query -w $wsId --analytics-query $q7 --query 'tables[0].rows[0][0]' -o tsv 2>$null
    $ok7 = ($null -ne $age -and [int]$age -le 20)
    Record-Check '7. Heartbeat fresh (≤20 min)' $ok7 "AgeMin: $age"
} else {
    Record-Check '6. Workspace resolution' $false 'cannot resolve workspaceResourceId from deployment outputs'
    Record-Check '7. Workspace resolution' $false 'cannot resolve workspaceResourceId from deployment outputs'
}

Write-Host ""
$passed = ($checks | Where-Object { $_.Passed }).Count
$total = $checks.Count
$color = if ($passed -eq $total) { 'Green' } else { 'Yellow' }
Write-Host ("  Result: {0}/{1} checks passed" -f $passed, $total) -ForegroundColor $color

$summary = [ordered]@{
    Generated      = (Get-Date).ToUniversalTime().ToString('o')
    ResourceGroup  = $ResourceGroup
    FunctionAppName = $FunctionAppName
    Passed         = ($passed -eq $total)
    PassedCount    = $passed
    TotalCount     = $total
    Checks         = $checks.ToArray()
}
$jsonPath = Join-Path $iterDir 'verify-deploy.json'
$summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
Write-Host "  Report: $jsonPath" -ForegroundColor DarkGray

if ($passed -lt $total) { exit 1 } else { exit 0 }
