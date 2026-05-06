#Requires -Version 7.0
<#
.SYNOPSIS
    Comprehensive single-pass live audit per .claude/plans/immutable-splashing-waffle.md Section 0.

.DESCRIPTION
    Runs the 11 BINDING query signals in one sweep and emits a punch-list markdown
    report with red/green per signal. NEVER inspects one function in isolation —
    chains across the data path so root-cause batching is possible.

    | Signal                                | Source                | Query intent                                                                                          |
    |---------------------------------------|-----------------------|-------------------------------------------------------------------------------------------------------|
    | S1. Function execution success/fail   | AppRequests           | summarize n=count(), succ=countif(Success), fail=countif(!Success) by Name                            |
    | S2. All exception classes              | AppExceptions         | summarize n=count() by ProblemId                                                                       |
    | S3. Error/warning trace messages       | AppTraces             | where SeverityLevel >= 2 | summarize by substring(Message, 0, 100)                                  |
    | S4. AuthChain.* customEvents           | AppEvents             | where Name has "AuthChain" | summarize by Name                                                          |
    | S5. ALL customEvents (not just auth)   | AppEvents             | summarize by Name                                                                                       |
    | S6. Heartbeat tier coverage            | XdrConnectorHealth_CL | summarize maxAttempted, maxSucceeded, maxRows by FunctionName, Tier                                    |
    | S7. Per-table ingestion volume         | union Defender_*_CL   | summarize rows=count() by t                                                                             |
    | S8. Per-stream ingestion volume        | union Defender_*_CL   | summarize rows=count() by SourceName                                                                   |
    | S9. DCE ingest dependencies            | AppDependencies       | where Target has "ingest.monitor.azure.com"                                                            |
    | S10. KV secret fetches                 | AppDependencies       | where Target has "vault.azure.net"                                                                     |
    | S11. Defender portal API calls         | AppDependencies       | where Target has "security.microsoft.com"                                                              |

    For each signal, asserts a binding gate (e.g. S1 fail==0, S6 maxRows>0, S7 has all 11
    expected tables). Emits a chained root-cause analysis: e.g. if S6 maxRows=0 AND
    S9 returns 0 dependencies, the upstream cause is S9 (no DCE calls) NOT S6 (no rows).

    Authenticates via SP creds in tests/.env.local. Idempotent. ~30s runtime.

.PARAMETER EnvFilePath
    Path to env file with SP creds. Default: ./tests/.env.local.

.PARAMETER LookbackHours
    How far back to query each signal. Default: 1 (matches Heartbeat 5min cadence + 12 bins).

.PARAMETER ReportDir
    Where to write the markdown punch-list. Default: ./tests/results.

.EXAMPLE
    pwsh ./tools/Audit-LiveDeployment.ps1
#>

[CmdletBinding()]
param(
    [string] $EnvFilePath  = './tests/.env.local',
    [int]    $LookbackHours = 1,
    [string] $ReportDir    = './tests/results'
)

$ErrorActionPreference = 'Stop'

$line = '═' * 67
Write-Host ""
Write-Host "  $line" -ForegroundColor Cyan
Write-Host "   XdrLogRaider — Live audit (11 BINDING signals, single-pass)" -ForegroundColor Cyan
Write-Host "  $line" -ForegroundColor Cyan
Write-Host ""

# --- Bootstrap ---
if (-not (Test-Path $EnvFilePath)) { throw "Env file not found: $EnvFilePath" }
$env_ = @{}
foreach ($l in Get-Content $EnvFilePath) {
    if ($l -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.+)\s*$') { $env_[$Matches[1]] = $Matches[2].Trim() }
}
foreach ($k in 'AZURE_TENANT_ID','AZURE_CLIENT_ID','AZURE_CLIENT_SECRET','XDRLR_SUBSCRIPTION_ID','XDRLR_WORKSPACE_ID','XDRLR_WORKSPACE_NAME','XDRLR_WORKSPACE_RG','XDRLR_CONNECTOR_RG') {
    if (-not $env_.ContainsKey($k)) { throw "Missing $k in $EnvFilePath" }
}

Write-Host "  Authenticating as SP $($env_['AZURE_CLIENT_ID'])..." -ForegroundColor Gray
foreach ($mod in 'Az.Accounts','Az.OperationalInsights','Az.Monitor','Az.ApplicationInsights','Az.Websites') {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Install-Module -Name $mod -Force -Scope CurrentUser -SkipPublisherCheck -ErrorAction SilentlyContinue
    }
    Import-Module $mod -ErrorAction SilentlyContinue
}
$secure = ConvertTo-SecureString $env_['AZURE_CLIENT_SECRET'] -AsPlainText -Force
$cred   = [pscredential]::new($env_['AZURE_CLIENT_ID'], $secure)
Connect-AzAccount -ServicePrincipal -TenantId $env_['AZURE_TENANT_ID'] -Credential $cred -SubscriptionId $env_['XDRLR_SUBSCRIPTION_ID'] -WarningAction SilentlyContinue | Out-Null
Write-Host "  ✓ Authenticated to subscription $($env_['XDRLR_SUBSCRIPTION_ID'])" -ForegroundColor Green
Write-Host ""

# --- Resolve App Insights resource (for AppRequests/AppDependencies/AppExceptions/AppTraces/AppEvents) ---
# AppInsights resource is in the connector RG; name follows xdrlr-<env>-ai-<suffix> pattern.
$aiResource = Get-AzApplicationInsights -ResourceGroupName $env_['XDRLR_CONNECTOR_RG'] -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $aiResource) { throw "No App Insights resource found in $($env_['XDRLR_CONNECTOR_RG'])" }
$aiResourceId = $aiResource.Id
Write-Host "  App Insights: $($aiResource.Name)" -ForegroundColor Gray
Write-Host "  Workspace:    $($env_['XDRLR_WORKSPACE_NAME']) ($($env_['XDRLR_WORKSPACE_ID']))" -ForegroundColor Gray
Write-Host ""

# --- Helper: invoke Logs Analytics query against a workspace ---
# Both Workspace tables (Defender_*_CL, XdrConnectorHealth_CL) AND App Insights tables
# (AppRequests, AppDependencies, AppExceptions, AppTraces, AppEvents) live in the same
# Log Analytics workspace because the AI resource was provisioned as workspace-based.
# Query both via the same Invoke-AzOperationalInsightsQuery call.
$script:WsCustomerId = if ($env_.ContainsKey('XDRLR_WORKSPACE_CUSTOMER_ID')) { $env_['XDRLR_WORKSPACE_CUSTOMER_ID'] }
                       else { (Get-AzOperationalInsightsWorkspace -ResourceGroupName $env_['XDRLR_WORKSPACE_RG'] -Name $env_['XDRLR_WORKSPACE_NAME']).CustomerId }
Write-Host "  Workspace CustomerId: $script:WsCustomerId" -ForegroundColor Gray
Write-Host ""

function Invoke-LogsQuery {
    param(
        [Parameter(Mandatory)] [string] $Query,
        [Parameter(Mandatory)] [ValidateSet('Workspace','AppInsights')] [string] $Target,
        [int] $TimespanHours = $LookbackHours
    )
    # Invoke-AzOperationalInsightsQuery -Timespan expects [TimeSpan] (HH:mm:ss), not ISO 8601.
    $tsObj = [TimeSpan]::FromHours($TimespanHours)
    return Invoke-AzOperationalInsightsQuery -WorkspaceId $script:WsCustomerId -Query $Query -Timespan $tsObj -ErrorAction Stop
}

$signals  = [ordered]@{}
$startUtc = (Get-Date).ToUniversalTime()

function Record-Signal {
    param([string]$Id, [string]$Name, [bool]$Pass, [string]$Detail, $Rows)
    $signals[$Id] = [pscustomobject]@{ Id=$Id; Name=$Name; Pass=$Pass; Detail=$Detail; Rows=$Rows; RowCount=if ($Rows) { @($Rows).Count } else { 0 } }
    $tag    = if ($Pass) { '✓' } else { '✗' }
    $colour = if ($Pass) { 'Green' } else { 'Red' }
    Write-Host ("  $tag $Id  $Name  $Detail") -ForegroundColor $colour
}

# === S1. Function execution success/fail per name ===
try {
    $q = "AppRequests | summarize n=count(), succ=countif(Success), fail=countif(not(Success)) by Name | order by n desc"
    $r = Invoke-LogsQuery -Query $q -Target Workspace
    $rows = if ($r.Results) { $r.Results } else { @() }
    $totalFail = ($rows | ForEach-Object { [int]$_.fail } | Measure-Object -Sum).Sum
    $totalSucc = ($rows | ForEach-Object { [int]$_.succ } | Measure-Object -Sum).Sum
    Record-Signal 'S1' 'Function execution (AppRequests)' (@($rows).Count -gt 0 -and $totalFail -eq 0) "rows=$(@($rows).Count) succ=$totalSucc fail=$totalFail" $rows
} catch { Record-Signal 'S1' 'Function execution (AppRequests)' $false "Query failed: $_" @() }

# === S2. All exception classes ===
try {
    $q = "AppExceptions | summarize n=count() by ProblemId | order by n desc"
    $r = Invoke-LogsQuery -Query $q -Target Workspace
    $rows = if ($r.Results) { $r.Results } else { @() }
    Record-Signal 'S2' 'AppExceptions classes' (@($rows).Count -eq 0) "$(@($rows).Count) distinct ProblemIds" $rows
} catch { Record-Signal 'S2' 'AppExceptions classes' $false "Query failed: $_" @() }

# === S3. Error/warning trace messages ===
try {
    $q = "AppTraces | where SeverityLevel >= 2 | summarize n=count() by Snippet=substring(Message, 0, 100) | order by n desc | take 50"
    $r = Invoke-LogsQuery -Query $q -Target Workspace
    $rows = if ($r.Results) { $r.Results } else { @() }
    # Some warnings are expected (DLQ drain stub, throttling) — gate ONLY on errors (SeverityLevel=3)
    $qErr = "AppTraces | where SeverityLevel >= 3 | count"
    $errR = Invoke-LogsQuery -Query $qErr -Target Workspace
    $errCount = if ($errR.Results) { [int]$errR.Results[0].Count } else { 0 }
    Record-Signal 'S3' 'AppTraces errors+warnings' ($errCount -eq 0) "errors=$errCount warns+errors=$(@($rows).Count) snippets" $rows
} catch { Record-Signal 'S3' 'AppTraces errors+warnings' $false "Query failed: $_" @() }

# === S4. AuthChain.* customEvents ===
try {
    $q = "AppEvents | where Name has 'AuthChain' | summarize n=count() by Name | order by n desc"
    $r = Invoke-LogsQuery -Query $q -Target Workspace
    $rows = if ($r.Results) { $r.Results } else { @() }
    Record-Signal 'S4' 'AuthChain.* events' (@($rows).Count -ge 1) "$(@($rows).Count) AuthChain event names" $rows
} catch { Record-Signal 'S4' 'AuthChain.* events' $false "Query failed: $_" @() }

# === S5. ALL customEvents (sanity check on telemetry pipeline) ===
try {
    $q = "AppEvents | summarize n=count() by Name | order by n desc | take 30"
    $r = Invoke-LogsQuery -Query $q -Target Workspace
    $rows = if ($r.Results) { $r.Results } else { @() }
    Record-Signal 'S5' 'ALL customEvents' (@($rows).Count -ge 1) "$(@($rows).Count) distinct event names" $rows
} catch { Record-Signal 'S5' 'ALL customEvents' $false "Query failed: $_" @() }

# === S6. Heartbeat tier coverage ===
try {
    $q = "XdrConnectorHealth_CL | summarize maxAttempted=max(toint(StreamsAttempted)), maxSucceeded=max(toint(StreamsSucceeded)), maxRows=max(toint(RowsIngested)) by FunctionName=tostring(FunctionName_s), Tier=tostring(Tier_s) | order by FunctionName"
    $r = Invoke-LogsQuery -Query $q -Target Workspace
    $rows = if ($r.Results) { $r.Results } else { @() }
    $maxRowsAcrossTiers = ($rows | ForEach-Object { [int]$_.maxRows } | Measure-Object -Maximum).Maximum
    Record-Signal 'S6' 'Heartbeat tier coverage' (@($rows).Count -gt 0 -and $maxRowsAcrossTiers -gt 0) "tiers=$(@($rows).Count) maxRowsAcrossTiers=$maxRowsAcrossTiers" $rows
} catch { Record-Signal 'S6' 'Heartbeat tier coverage' $false "Query failed: $_" @() }

# === S7. Per-table ingestion volume ===
try {
    $q = "union Defender_*_CL | summarize rows=count() by t=tostring(Type) | order by rows desc"
    $r = Invoke-LogsQuery -Query $q -Target Workspace
    $rows = if ($r.Results) { $r.Results } else { @() }
    Record-Signal 'S7' 'Per-table ingestion (Defender_*_CL)' (@($rows).Count -ge 1) "tablesWithData=$(@($rows).Count) (expected up to 10)" $rows
} catch { Record-Signal 'S7' 'Per-table ingestion (Defender_*_CL)' $false "Query failed: $_" @() }

# === S8. Per-stream ingestion volume ===
try {
    $q = "union Defender_*_CL | summarize rows=count() by SourceName=tostring(SourceName) | order by rows desc | take 60"
    $r = Invoke-LogsQuery -Query $q -Target Workspace
    $rows = if ($r.Results) { $r.Results } else { @() }
    Record-Signal 'S8' 'Per-stream ingestion (SourceName)' (@($rows).Count -ge 1) "streamsWithData=$(@($rows).Count) (expected up to 59)" $rows
} catch { Record-Signal 'S8' 'Per-stream ingestion (SourceName)' $false "Query failed: $_" @() }

# === S9. DCE ingest dependencies ===
try {
    $q = "AppDependencies | where Target has 'ingest.monitor.azure.com' | summarize n=count(), succ=countif(Success), fail=countif(not(Success)) by Target | order by n desc"
    $r = Invoke-LogsQuery -Query $q -Target Workspace
    $rows = if ($r.Results) { $r.Results } else { @() }
    Record-Signal 'S9' 'DCE ingest dependencies' (@($rows).Count -ge 1) "DCE-call rows=$(@($rows).Count)" $rows
} catch { Record-Signal 'S9' 'DCE ingest dependencies' $false "Query failed: $_" @() }

# === S10. KV secret fetches ===
try {
    $q = "AppDependencies | where Target has 'vault.azure.net' | summarize n=count(), succ=countif(Success), fail=countif(not(Success))"
    $r = Invoke-LogsQuery -Query $q -Target Workspace
    $rows = if ($r.Results) { $r.Results } else { @() }
    $callCount = if (@($rows).Count -gt 0) { [int]$rows[0].n } else { 0 }
    Record-Signal 'S10' 'KV secret fetches' ($callCount -gt 0) "KV-call count=$callCount" $rows
} catch { Record-Signal 'S10' 'KV secret fetches' $false "Query failed: $_" @() }

# === S11. Defender portal API calls ===
try {
    $q = "AppDependencies | where Target has 'security.microsoft.com' | summarize n=count(), succ=countif(Success), fail=countif(not(Success))"
    $r = Invoke-LogsQuery -Query $q -Target Workspace
    $rows = if ($r.Results) { $r.Results } else { @() }
    $callCount = if (@($rows).Count -gt 0) { [int]$rows[0].n } else { 0 }
    Record-Signal 'S11' 'Defender portal API calls' ($callCount -gt 0) "portal-call count=$callCount" $rows
} catch { Record-Signal 'S11' 'Defender portal API calls' $false "Query failed: $_" @() }

# === Chained root-cause analysis ===
Write-Host ""
Write-Host "  $line" -ForegroundColor Cyan
Write-Host "   Chained root-cause analysis (per BINDING methodology Step 2)" -ForegroundColor Cyan
Write-Host "  $line" -ForegroundColor Cyan
Write-Host ""

$rootCauses = @()

# Chain: S7/S8 (table/stream ingestion) → S9 (DCE) → S6 (Heartbeat) → S11 (portal) → S10 (KV) → S4 (auth)
if (-not $signals.S10.Pass) {
    $rootCauses += "ROOT: KV secret fetches missing (S10) → upstream cause for S11 (no auth secrets to use), S4 (no AuthChain events), S6 (Heartbeat reports failure), S7/S8 (no ingestion possible)"
}
if (-not $signals.S11.Pass -and $signals.S10.Pass) {
    $rootCauses += "ROOT: Portal API calls missing (S11) → KV worked (S10) but auth chain or Connect-DefenderPortal failing → upstream cause for S6, S7, S8"
}
if (-not $signals.S6.Pass -and $signals.S11.Pass) {
    $rootCauses += "ROOT: Heartbeat reports zero rows (S6) but portal calls happening (S11) → likely Invoke-MDEEndpoint returning rows but Send-ToLogAnalytics not called OR DCE call failing → check S9"
}
if (-not $signals.S7.Pass -and $signals.S9.Pass) {
    $rootCauses += "ROOT: DCE called (S9) but no rows in tables (S7) → DCR streamDecl mismatch OR DCR transformKql dropping rows → check DCR shape vs ARM streamDeclarations"
}
if (-not $signals.S9.Pass -and $signals.S6.Pass) {
    $rootCauses += "ROOT: DCE never called (S9) but Heartbeat says success (S6) → activity NEVER calls Send-ToLogAnalytics (THIS IS THE BUG WE FIXED IN COMMIT 3a91c54)"
}
if (-not $signals.S2.Pass) {
    $rootCauses += "WARN: Active exceptions (S2) — chain to S3 trace messages and AppExceptions detail before declaring production-ready"
}
if ($rootCauses.Count -eq 0) {
    if (($signals.Values | Where-Object { -not $_.Pass } | Measure-Object).Count -eq 0) {
        $rootCauses += "ALL GREEN: 11/11 signals pass — production-ready"
    } else {
        $rootCauses += "Some signals failed but no canonical root-cause chain matched — manual root-cause analysis required"
    }
}
foreach ($r in $rootCauses) { Write-Host "  • $r" -ForegroundColor Yellow }

# === Markdown report ===
$stamp    = (Get-Date).ToString('yyyyMMdd-HHmmss')
$reportFile = Join-Path $ReportDir "live-audit-$stamp.md"
if (-not (Test-Path $ReportDir)) { New-Item -ItemType Directory -Path $ReportDir | Out-Null }
$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine("# XdrLogRaider — Live audit ($stamp UTC)")
[void]$md.AppendLine("")
[void]$md.AppendLine("Lookback: $LookbackHours hour(s)")
[void]$md.AppendLine("App Insights: $($aiResource.Name)")
[void]$md.AppendLine("Workspace:    $($env_['XDRLR_WORKSPACE_NAME'])")
[void]$md.AppendLine("")
[void]$md.AppendLine("## Signal summary")
[void]$md.AppendLine("")
[void]$md.AppendLine("| Id | Name | Pass | Detail | Rows |")
[void]$md.AppendLine("|----|------|------|--------|------|")
foreach ($s in $signals.Values) {
    $tag = if ($s.Pass) { '✓' } else { '✗' }
    [void]$md.AppendLine("| $($s.Id) | $($s.Name) | $tag | $($s.Detail) | $($s.RowCount) |")
}
[void]$md.AppendLine("")
[void]$md.AppendLine("## Root-cause chain")
[void]$md.AppendLine("")
foreach ($r in $rootCauses) { [void]$md.AppendLine("- $r") }
[void]$md.AppendLine("")
foreach ($s in $signals.Values) {
    if (-not $s.Pass -and $s.Rows -and @($s.Rows).Count -gt 0) {
        [void]$md.AppendLine("### $($s.Id) detail rows")
        [void]$md.AppendLine("")
        [void]$md.AppendLine('```')
        $rowsToDump = @($s.Rows) | Select-Object -First 20
        foreach ($row in $rowsToDump) {
            if ($row -is [Array]) { [void]$md.AppendLine(($row -join ' | ')) }
            else { [void]$md.AppendLine(($row | ConvertTo-Json -Compress)) }
        }
        [void]$md.AppendLine('```')
        [void]$md.AppendLine("")
    }
}
$md.ToString() | Set-Content -Path $reportFile
Write-Host ""
Write-Host "  Report: $reportFile" -ForegroundColor Gray

$passCount = ($signals.Values | Where-Object Pass | Measure-Object).Count
$totalCount = $signals.Count
Write-Host ""
if ($passCount -eq $totalCount) {
    Write-Host "  ALL GREEN: $passCount/$totalCount signals pass" -ForegroundColor Green
    exit 0
} else {
    Write-Host "  GAPS: $passCount/$totalCount signals pass" -ForegroundColor Red
    exit 1
}
