#Requires -Version 7.0
[CmdletBinding()]
param(
    [string] $EnvFilePath  = './tests/.env.local',
    [int]    $LookbackHours = 2
)
$ErrorActionPreference = 'Stop'
$env_ = @{}
foreach ($l in Get-Content $EnvFilePath) {
    if ($l -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.+)\s*$') { $env_[$Matches[1]] = $Matches[2].Trim() }
}
foreach ($mod in 'Az.Accounts','Az.OperationalInsights','Az.Resources') { Import-Module $mod -ErrorAction SilentlyContinue }
$secure = ConvertTo-SecureString $env_['AZURE_CLIENT_SECRET'] -AsPlainText -Force
$cred   = [pscredential]::new($env_['AZURE_CLIENT_ID'], $secure)
Connect-AzAccount -ServicePrincipal -TenantId $env_['AZURE_TENANT_ID'] -Credential $cred -SubscriptionId $env_['XDRLR_SUBSCRIPTION_ID'] -WarningAction SilentlyContinue | Out-Null

$wsId = if ($env_.ContainsKey('XDRLR_WORKSPACE_CUSTOMER_ID')) { $env_['XDRLR_WORKSPACE_CUSTOMER_ID'] }
        else { (Get-AzOperationalInsightsWorkspace -ResourceGroupName $env_['XDRLR_WORKSPACE_RG'] -Name $env_['XDRLR_WORKSPACE_NAME']).CustomerId }
$ts = [TimeSpan]::FromHours($LookbackHours)

function Q([string]$Title, [string]$Query, [switch]$Raw) {
    Write-Host ""; Write-Host "=== $Title ===" -ForegroundColor Cyan
    try {
        $r = Invoke-AzOperationalInsightsQuery -WorkspaceId $wsId -Query $Query -Timespan $ts -ErrorAction Stop
        if ($r.Results) {
            if ($Raw) {
                $r.Results | ForEach-Object { $_ | ConvertTo-Json -Compress | Write-Host }
            } else {
                $r.Results | Format-Table -AutoSize -Wrap | Out-String | Write-Host
            }
        } else { Write-Host "  (no rows)" -ForegroundColor Yellow }
    } catch {
        Write-Host "  ERROR: $_" -ForegroundColor Red
    }
}

# ── 1. Full AppExceptions detail (NOT truncated)
Q 'AppExceptions FULL detail (last 5)' @"
AppExceptions
| project TimeGenerated, OperationName, ProblemId, OuterMessage, OuterAssembly, AppRoleName=Properties.AppRoleName
| order by TimeGenerated desc
| take 5
"@ -Raw

# ── 2. What FA is producing telemetry? (CloudRoleName)
Q 'Distinct CloudRoleName + counts' @"
union AppRequests, AppDependencies, AppExceptions, AppTraces, AppEvents
| summarize n=count() by AppRoleName
| order by n desc
"@

# ── 3. Direct check: do Defender_*_CL tables exist?
Q 'Existing _CL tables in workspace (any data ever)' @"
union *
| where TimeGenerated > ago(7d)
| where Type endswith '_CL'
| summarize rows=count() by Type
| order by rows desc
"@

# ── 4. XdrConnectorHealth_CL detailed: which functions / tiers?
Q 'XdrConnectorHealth_CL by FunctionName/Tier' @"
XdrConnectorHealth_CL
| summarize n=count(), maxAtt=max(StreamsAttempted), maxSucc=max(StreamsSucceeded), maxRows=max(RowsIngested), latest=max(TimeGenerated) by FunctionName, Tier
| order by latest desc
"@

# ── 5. AppRequests: which functions ran?
Q 'AppRequests function names + counts' @"
AppRequests
| summarize n=count(), succ=countif(Success), fail=countif(not(Success)), latest=max(TimeGenerated) by Name
| order by latest desc
| take 50
"@

# ── 6. AppEvents distinct names
Q 'AppEvents distinct names' @"
AppEvents
| summarize n=count(), latest=max(TimeGenerated) by Name
| order by latest desc
| take 50
"@

# ── 7. Last 10 traces (any severity) showing exception text
Q 'AppTraces last 10 (severity 3) FULL message' @"
AppTraces
| where SeverityLevel >= 3
| project TimeGenerated, SeverityLevel, Message=substring(Message, 0, 500)
| order by TimeGenerated desc
| take 10
"@ -Raw

# ── 8. List FA resources (production vs dev)
Write-Host ""; Write-Host "=== Function Apps in connector RG ===" -ForegroundColor Cyan
Get-AzWebApp -ResourceGroupName $env_['XDRLR_CONNECTOR_RG'] | Select-Object Name, Kind, State, DefaultHostName | Format-Table -AutoSize
