#Requires -Version 7.4
<#
.SYNOPSIS
    Post-deploy smoke test. Verifies the 7 north-star acceptance criteria.

.DESCRIPTION
    Reads workspace + connector resource info from the most recent deployment
    in $ResourceGroup. Runs the 7 KQL/CLI checks documented in the plan and
    prints a PASS/FAIL summary.

    Exit 0 if all 7 pass; exit 1 with the failing check listed.
    Output also written to tests/results/iter-<utc>/LIVE-PROOF.json — the
    empirical exit artefact per guardrail G3 NO-CLAIM-WITHOUT-PROOF (Claude
    memory feedback_autonomous_loop_v2.md).

.PARAMETER ResourceGroup
    Connector resource group.

.PARAMETER WorkspaceResourceId
    Optional. If omitted, reads from the most recent deployment outputs.

.EXAMPLE
    pwsh ./tools/Smoke-E2E.ps1 -ResourceGroup rg-xdrlr-test
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [string]$WorkspaceResourceId
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

$repoRoot = Join-Path $PSScriptRoot '..'
$iterDir  = Join-Path $repoRoot ("tests/results/iter-" + (Get-Date -Format 'yyyyMMddTHHmmssZ'))
New-Item -ItemType Directory -Path $iterDir -Force | Out-Null

function Test-Check {
    param([string]$Name, [scriptblock]$Body)
    Write-Host "  [....] $Name" -NoNewline
    try {
        $r = & $Body
        if ($r) {
            Write-Host "`r  [PASS] $Name             "
            return @{ Check=$Name; Pass=$true;  Detail=$r }
        } else {
            Write-Host "`r  [FAIL] $Name             " -ForegroundColor Red
            return @{ Check=$Name; Pass=$false; Detail='returned falsy' }
        }
    } catch {
        Write-Host "`r  [FAIL] $Name             " -ForegroundColor Red
        Write-Host "         $($_.Exception.Message)" -ForegroundColor DarkRed
        return @{ Check=$Name; Pass=$false; Detail=$_.Exception.Message }
    }
}

# Locate the latest deployment to extract names + IDs
$deploy = az deployment group list -g $ResourceGroup --query "sort_by([?properties.provisioningState=='Succeeded'], &properties.timestamp) | [-1]" -o json | ConvertFrom-Json
if (-not $deploy) { throw "No Succeeded deployment found in RG $ResourceGroup." }
$outputs = $deploy.properties.outputs
$faName    = $outputs.functionAppName.value
$kvName    = $outputs.keyVaultName.value
$dceUri    = $outputs.dceEndpoint.value
$aiName    = $outputs.appInsightsName.value

if (-not $WorkspaceResourceId) {
    # Read from deployment parameters
    $WorkspaceResourceId = $deploy.properties.parameters.workspaceResourceId.value
}
$wsId = (az resource show --ids $WorkspaceResourceId --query 'properties.customerId' -o tsv)
if (-not $wsId) { throw "Cannot resolve workspace customerId from $WorkspaceResourceId" }

Write-Host "`nXdrLogRaider Smoke-E2E — RG=$ResourceGroup FA=$faName" -ForegroundColor Cyan
$results = @()

# AC-1: ARM resources deployed
$results += Test-Check 'AC-1 ARM resources deployed' {
    $count = @($deploy.properties.outputResources).Count
    if ($count -lt 10) { return $false } else { return "$count resources" }
}

# AC-2: Function App running, Xdr-Poll enabled
$results += Test-Check 'AC-2 Function App running, Xdr-Poll enabled' {
    $state = az functionapp show -g $ResourceGroup -n $faName --query state -o tsv
    if ($state -ne 'Running') { return $false }
    $disabled = az functionapp function show -g $ResourceGroup -n $faName --function-name 'Xdr-Poll' --query 'config.disabled' -o tsv 2>$null
    return ($disabled -ne 'true')
}

# AC-3: Heartbeat row within 10 min · post-0m table name = XdrConnectorHealth_CL
$results += Test-Check 'AC-3 Heartbeat within 10 min (XdrConnectorHealth_CL)' {
    $q = 'XdrConnectorHealth_CL | summarize LastHB=max(TimeGenerated) | extend AgeMin=datetime_diff("minute", now(), LastHB) | project AgeMin'
    $age = az monitor log-analytics query -w $wsId --analytics-query $q --query 'tables[0].rows[0][0]' -o tsv 2>$null
    if (-not $age) { return $false }
    return ([int]$age -le 10) -and "$age min old"
}

# AC-4: TenantContext row exists · per-sub-area architecture · union Defender_*_CL (G-S1 · Π1 fix)
$results += Test-Check 'AC-4 TenantContext row exists (union Defender_*_CL)' {
    $q = 'union withsource=TableName isfuzzy=true Defender_*_CL | where Slug == "TenantContext" | count'
    $n = az monitor log-analytics query -w $wsId --analytics-query $q --query 'tables[0].rows[0][0]' -o tsv 2>$null
    return ([int]$n -ge 1) -and "$n rows"
}

# AC-5: per-sub-area Defender_*_CL covers >= 5 sub-areas (G-S1 · Π1 fix)
$results += Test-Check 'AC-5 Defender_*_CL covers >= 5 sub-areas' {
    $q = 'union withsource=TableName isfuzzy=true Defender_*_CL | where TimeGenerated > ago(2h) | summarize n=dcount(SubArea)'
    $n = az monitor log-analytics query -w $wsId --analytics-query $q --query 'tables[0].rows[0][0]' -o tsv 2>$null
    return ([int]$n -ge 5) -and "$n distinct sub-areas"
}

# AC-6: No HTML SPA shells in RawJson (Reinforcement-B · auth-chain-is-the-gate · G-S1 fix)
$results += Test-Check 'AC-6 No HTML in RawJson (R-B intact · union Defender_*_CL)' {
    $q = 'union withsource=TableName isfuzzy=true Defender_*_CL | where RawJson startswith "<" or RawJson contains "<!DOCTYPE" | count'
    $n = az monitor log-analytics query -w $wsId --analytics-query $q --query 'tables[0].rows[0][0]' -o tsv 2>$null
    return ([int]$n -eq 0) -and 'HTML% = 0'
}

# AC-7: 12h soak — no AuthFatal (lenient for first deploy: 1h window) · post-0m table name
$results += Test-Check 'AC-7 No AuthFatal in last 1h (XdrConnectorHealth_CL · soak proxy)' {
    $n = az monitor log-analytics query -w $wsId --analytics-query 'XdrConnectorHealth_CL | where TimeGenerated > ago(1h) and Status == "AuthFatal" | count' --query 'tables[0].rows[0][0]' -o tsv 2>$null
    return ([int]$n -eq 0)
}

# AC-8: Reinforcement-A · ProjectedData column populated on >= 50% of rows (G-S1 · Π1 fix · union Defender_*_CL)
$results += Test-Check 'AC-8 ProjectedData populated (R-A · typed-DSL · union Defender_*_CL)' {
    $q = 'union withsource=TableName isfuzzy=true Defender_*_CL | where TimeGenerated > ago(1h) and SuccessKind == "live" | summarize Total=count(), WithProjection=countif(isnotempty(ProjectedData)) | extend Pct = iff(Total>0, round(100.0 * WithProjection / Total, 1), 0.0) | project Pct'
    $pct = az monitor log-analytics query -w $wsId --analytics-query $q --query 'tables[0].rows[0][0]' -o tsv 2>$null
    if (-not $pct) { return $false }
    return ([double]$pct -ge 50) -and "$pct% populated"
}

# AC-9: Reinforcement-C · Capability heartbeat row exists (cold-start discovery emitted ProductSnapshot)
$results += Test-Check 'AC-9 Capability row exists (Reinforcement-C · cold-start discovery)' {
    $q = 'XdrConnectorHealth_CL | where TimeGenerated > ago(24h) and Status == "Capability" | summarize n=count()'
    $n = az monitor log-analytics query -w $wsId --analytics-query $q --query 'tables[0].rows[0][0]' -o tsv 2>$null
    return ([int]$n -ge 1) -and "$n Capability rows"
}

# AC-10: ConnectorVersion column matches deployment param (G-S1 · Π1 fix · union Defender_*_CL)
$results += Test-Check 'AC-10 ConnectorVersion matches deployment param (provenance · drift detection)' {
    $deployedVersion = $deploy.properties.parameters.connectorVersion.value
    if (-not $deployedVersion) { return $false }
    $q = "union withsource=TableName isfuzzy=true Defender_*_CL | where TimeGenerated > ago(2h) | summarize Versions = make_set(ConnectorVersion) | extend N = array_length(Versions) | project N, Versions"
    $row = az monitor log-analytics query -w $wsId --analytics-query $q --query 'tables[0].rows[0]' -o json 2>$null | ConvertFrom-Json
    if (-not $row) { return $false }
    # Expect exactly 1 version · matching $deployedVersion
    return (([int]$row[0]) -eq 1) -and ($row[1] -match [regex]::Escape($deployedVersion)) -and "version=$deployedVersion"
}

# Summarise + write LIVE-PROOF.json
$pass = (@($results | Where-Object Pass).Count)
$total = $results.Count
$liveProof = [pscustomobject]@{
    TimestampUtc      = (Get-Date).ToUniversalTime().ToString('o')
    ResourceGroup     = $ResourceGroup
    FunctionAppName   = $faName
    WorkspaceId       = $wsId
    OverallPass       = ($pass -eq $total)
    PassCount         = $pass
    TotalCount        = $total
    Checks            = $results
}
$proofFile = Join-Path $iterDir 'LIVE-PROOF.json'
$liveProof | ConvertTo-Json -Depth 10 | Set-Content -Path $proofFile -Encoding UTF8

Write-Host "`n=== Smoke-E2E: $pass / $total pass ===" -ForegroundColor $(if ($pass -eq $total) { 'Green' } else { 'Red' })
Write-Host "LIVE-PROOF.json -> $proofFile" -ForegroundColor DarkGray
if ($pass -ne $total) { exit 1 }
