#Requires -Version 7.0
<#
.SYNOPSIS
    Drill-down companion to Audit-LiveDeployment.ps1 — surfaces row-level detail
    for the gap-class signals so we can root-cause the chained issues.
#>
[CmdletBinding()]
param(
    [string] $EnvFilePath  = './tests/.env.local',
    [int]    $LookbackHours = 2
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $EnvFilePath)) { throw "Env file not found: $EnvFilePath" }
$env_ = @{}
foreach ($l in Get-Content $EnvFilePath) {
    if ($l -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.+)\s*$') { $env_[$Matches[1]] = $Matches[2].Trim() }
}
foreach ($mod in 'Az.Accounts','Az.OperationalInsights') { Import-Module $mod -ErrorAction SilentlyContinue }
# Operator-tool: SP secret read from .env file (already plaintext on disk); convert to SecureString for Connect-AzAccount.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Operator tool: SP secret from .env file required to be SecureString for Connect-AzAccount.')]
$secure = ConvertTo-SecureString $env_['AZURE_CLIENT_SECRET'] -AsPlainText -Force
$cred   = [pscredential]::new($env_['AZURE_CLIENT_ID'], $secure)
Connect-AzAccount -ServicePrincipal -TenantId $env_['AZURE_TENANT_ID'] -Credential $cred -SubscriptionId $env_['XDRLR_SUBSCRIPTION_ID'] -WarningAction SilentlyContinue | Out-Null

$wsId = if ($env_.ContainsKey('XDRLR_WORKSPACE_CUSTOMER_ID')) { $env_['XDRLR_WORKSPACE_CUSTOMER_ID'] }
        else { (Get-AzOperationalInsightsWorkspace -ResourceGroupName $env_['XDRLR_WORKSPACE_RG'] -Name $env_['XDRLR_WORKSPACE_NAME']).CustomerId }
$ts = [TimeSpan]::FromHours($LookbackHours)

function Q([string]$Title, [string]$Query) {
    Write-Host ""
    Write-Host "=== $Title ===" -ForegroundColor Cyan
    try {
        $r = Invoke-AzOperationalInsightsQuery -WorkspaceId $wsId -Query $Query -Timespan $ts -ErrorAction Stop
        if ($r.Results) {
            $r.Results | Format-Table -AutoSize | Out-String | Write-Host
        } else {
            Write-Host "  (no rows)" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  ERROR: $_" -ForegroundColor Red
    }
}

# ── 1. AppExceptions: what ARE the 2 ProblemIds?
Q 'AppExceptions detail' @"
AppExceptions
| project TimeGenerated, ProblemId, OuterMessage, OperationName, Method, Properties
| order by TimeGenerated desc
| take 20
"@

# ── 2. AuthChain event names + payloads
Q 'AuthChain.* events' @"
AppEvents
| where Name has 'AuthChain'
| project TimeGenerated, Name, Properties=tostring(Properties)
| order by TimeGenerated desc
| take 20
"@

# ── 3. ALL custom event names (catch StreamPoll.*, Heartbeat.*, etc.)
Q 'ALL customEvents' @"
AppEvents
| summarize n=count(), latest=max(TimeGenerated) by Name
| order by latest desc
"@

# ── 4. AppRequests detail: what functions ran, what succeeded
Q 'AppRequests by Name+Success' @"
AppRequests
| summarize n=count(), succ=countif(Success), fail=countif(not(Success)), latest=max(TimeGenerated) by Name
| order by latest desc
"@

# ── 5. AppDependencies detail: what was called?
Q 'AppDependencies by Type+Target' @"
AppDependencies
| summarize n=count(), succ=countif(Success), fail=countif(not(Success)), avgDuration=avg(DurationMs) by Type, Target
| order by n desc
"@

# ── 6. Workspace tables: do Defender_*_CL exist?
Q 'Workspace tables ending _CL' @"
union withsource=t Defender_*_CL, XdrConnectorHealth_CL, MDE_*_CL
| summarize rows=count() by t
| order by rows desc
"@

# ── 7. XdrConnectorHealth_CL: what columns exist?
Q 'XdrConnectorHealth_CL schema sample' @"
XdrConnectorHealth_CL
| take 5
"@

# ── 8. Recent traces with severity — what warnings/errors?
Q 'AppTraces severity >=2 (top 30 distinct messages)' @"
AppTraces
| where SeverityLevel >= 2
| summarize n=count(), latest=max(TimeGenerated) by Snippet=substring(Message, 0, 140)
| order by n desc
| take 30
"@

# ── 9. AppDependencies KV+portal+DCE — direct check
Q 'KV/Portal/DCE dependencies' @"
AppDependencies
| where Target has 'vault.azure.net' or Target has 'security.microsoft.com' or Target has 'ingest.monitor.azure.com' or Target has 'login.microsoftonline.com'
| summarize n=count(), succ=countif(Success), fail=countif(not(Success)) by Target
| order by n desc
"@
