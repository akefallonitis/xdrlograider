#Requires -Version 7.0
[CmdletBinding()]
param([string] $EnvFilePath = './tests/.env.local', [int] $LookbackHours = 4)
$ErrorActionPreference = 'Stop'
$env_ = @{}
foreach ($l in Get-Content $EnvFilePath) { if ($l -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.+)\s*$') { $env_[$Matches[1]] = $Matches[2].Trim() } }
foreach ($mod in 'Az.Accounts','Az.OperationalInsights') { Import-Module $mod -ErrorAction SilentlyContinue }
$secure = ConvertTo-SecureString $env_['AZURE_CLIENT_SECRET'] -AsPlainText -Force
$cred   = [pscredential]::new($env_['AZURE_CLIENT_ID'], $secure)
Connect-AzAccount -ServicePrincipal -TenantId $env_['AZURE_TENANT_ID'] -Credential $cred -SubscriptionId $env_['XDRLR_SUBSCRIPTION_ID'] -WarningAction SilentlyContinue | Out-Null
$wsId = if ($env_.ContainsKey('XDRLR_WORKSPACE_CUSTOMER_ID')) { $env_['XDRLR_WORKSPACE_CUSTOMER_ID'] } else { (Get-AzOperationalInsightsWorkspace -ResourceGroupName $env_['XDRLR_WORKSPACE_RG'] -Name $env_['XDRLR_WORKSPACE_NAME']).CustomerId }
$ts = [TimeSpan]::FromHours($LookbackHours)

function Q($Title, $Q, [switch]$Raw) {
    Write-Host ""; Write-Host "=== $Title ===" -ForegroundColor Cyan
    try {
        $r = Invoke-AzOperationalInsightsQuery -WorkspaceId $wsId -Query $Q -Timespan $ts -ErrorAction Stop
        if ($r.Results) { if ($Raw) { $r.Results | ForEach-Object { $_ | ConvertTo-Json -Compress | Write-Host } } else { $r.Results | Format-Table -AutoSize -Wrap | Out-String | Write-Host } }
        else { Write-Host "  (no rows)" -ForegroundColor Yellow }
    } catch { Write-Host "  ERROR: $_" -ForegroundColor Red }
}

# Which OPERATION is producing the Stream-empty exception?
Q 'AppExceptions: which OperationName?' @"
AppExceptions
| where OuterMessage has "Unknown Stream"
| summarize n=count() by OperationName, AppRoleInstance, AssemblyName=OuterAssembly
| order by n desc
"@

# Correlate: when the empty-stream exception fires, what was the AppRequest or Operation?
Q 'AppExceptions: full detail with InnerMessage' @"
AppExceptions
| where OuterMessage has "Unknown Stream"
| project TimeGenerated, OperationName, OperationId, ParentId, OuterMethod, InnermostMethod, AppRoleInstance,
          OuterMessage=substring(OuterMessage, 0, 200), Details=tostring(Details)
| order by TimeGenerated desc
| take 5
"@ -Raw

# AppRequests joined with exceptions via OperationId
Q 'AppExceptions joined with AppRequests' @"
AppExceptions
| where OuterMessage has "Unknown Stream"
| project XTime=TimeGenerated, OperationId, ProblemId
| join kind=leftouter (
    AppRequests
    | project RTime=TimeGenerated, OperationId, RequestName=Name, Url
) on OperationId
| project XTime, OperationId, RequestName, Url
| take 10
"@

# Let's see ALL function executions in the last hour
Q 'AppRequests last hour by Name' @"
AppRequests
| summarize n=count(), succ=countif(Success), fail=countif(not(Success)), latest=max(TimeGenerated) by Name
| order by latest desc
"@

# Look for orchestration completion events
Q 'Durable orchestration events' @"
AppEvents
| where Name contains 'Orchestration' or Name contains 'Activity' or Name contains 'Durable'
| summarize n=count() by Name
| order by n desc
"@

# Stream.Polled events - did per-stream polls happen?
Q 'Stream.* events (legacy poll)' @"
AppEvents
| where Name startswith 'Stream'
| summarize n=count(), latest=max(TimeGenerated) by Name
| order by latest desc
"@

# Heartbeat full row to confirm the table schema
Q 'XdrConnectorHealth_CL last row' @"
XdrConnectorHealth_CL
| top 1 by TimeGenerated
"@ -Raw

# What environment vars are actually set on the FA? Get them indirectly via AppEvents that record env-validation
Q 'profile.ps1 env-var validation events' @"
AppTraces
| where Message contains 'XDR_INGEST_DLQ' or Message contains 'DCR_IMMUTABLE_IDS_JSON' or Message contains 'KEY_VAULT_URI' or Message contains 'DCE_ENDPOINT'
| project TimeGenerated, Message=substring(Message, 0, 300)
| order by TimeGenerated desc
| take 10
"@ -Raw
