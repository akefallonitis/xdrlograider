#Requires -Version 7.0
<#
.SYNOPSIS
    Single-command health verdict for the XdrLogRaider connector.

.DESCRIPTION
    Runs the operator's "is this thing working right now" check in one
    shell call. Combines three signals:

      1. Heartbeat — has a successful poll occurred in the last 5 minutes?
      2. Auth diagnostics (App Insights customEvents) — any AADSTSError
         events in the last hour?
      3. Per-tier stream coverage — at least one row per active tier in
         the last 24h?

    Returns a structured object with overall verdict (HEALTHY / DEGRADED
    / FAILED) and per-signal detail. Can be piped into automation; runs
    against any tenant via Workspace ID + a Sentinel-Reader-or-better
    auth context (interactive Az login, SP, or MI).

.PARAMETER WorkspaceId
    Log Analytics workspace customer ID (GUID, NOT the resource ID).
    Required. Find via:
      Get-AzOperationalInsightsWorkspace -ResourceGroupName <rg> -Name <ws> | Select-Object -ExpandProperty CustomerId

.PARAMETER LookbackMinutes
    Time window for the heartbeat + auth-error checks. Default: 5
    minutes for heartbeat (matches the heartbeat-5m timer cadence) and
    60 minutes for auth errors.

.PARAMETER OutputFormat
    'Object' (default — pscustomobject) or 'Json' or 'Markdown'.

.EXAMPLE
    Connect-AzAccount
    ./tools/Test-ConnectorHealth.ps1 -WorkspaceId 'aaaa-bbbb-cccc-dddd'

.EXAMPLE
    # In CI / automation pipeline:
    $health = ./tools/Test-ConnectorHealth.ps1 -WorkspaceId $env:WORKSPACE_ID -OutputFormat Json
    if (($health | ConvertFrom-Json).Verdict -ne 'HEALTHY') {
        throw "Connector unhealthy: see Reasons"
    }

.NOTES
    Requires the Az.OperationalInsights module:
      Install-Module Az.OperationalInsights -Scope CurrentUser

    Read-only. Does not modify any resource.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $WorkspaceId,

    [int] $HeartbeatLookbackMinutes = 5,

    [int] $AuthErrorLookbackMinutes = 60,

    [ValidateSet('Object', 'Json', 'Markdown')]
    [string] $OutputFormat = 'Object'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Ensure Az context is available.
$ctx = Get-AzContext -ErrorAction SilentlyContinue
if (-not $ctx) {
    throw "No Az context. Run 'Connect-AzAccount' or set up a Service Principal first."
}

function Invoke-WorkspaceQuery {
    param([string] $Query)
    $resp = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $Query -ErrorAction Stop
    return $resp.Results
}

# ----- Signal 1: Heartbeat in last N minutes -----
$heartbeatLookback = "${HeartbeatLookbackMinutes}m"
$heartbeatQuery = @"
MDE_Heartbeat_CL
| where TimeGenerated > ago($heartbeatLookback)
| where StreamsSucceeded > 0
| summarize Latest = max(TimeGenerated), Count = count(), Tiers = make_set(Tier)
"@
$hbRows = Invoke-WorkspaceQuery -Query $heartbeatQuery
$hbResult = if ($hbRows -and ($hbRows | Select-Object -First 1).Count -gt 0) {
    $row = $hbRows | Select-Object -First 1
    [pscustomobject]@{
        Status     = 'PASS'
        LatestUtc  = $row.Latest
        PollCount  = $row.Count
        TiersSeen  = $row.Tiers
    }
} else {
    [pscustomobject]@{
        Status    = 'FAIL'
        LatestUtc = $null
        PollCount = 0
        TiersSeen = @()
    }
}

# ----- Signal 2: Auth-chain errors in last N minutes -----
$authLookback = "${AuthErrorLookbackMinutes}m"
$authQuery = @"
customEvents
| where timestamp > ago($authLookback)
| where name == 'AuthChain.AADSTSError'
| summarize ErrorCount = count(),
            DistinctCodes = make_set(tostring(customDimensions.AADSTSCode)),
            LatestUtc = max(timestamp)
"@
$authRows = Invoke-WorkspaceQuery -Query $authQuery
$authResult = if ($authRows -and ($authRows | Select-Object -First 1).ErrorCount -gt 0) {
    $row = $authRows | Select-Object -First 1
    [pscustomobject]@{
        Status        = 'FAIL'
        ErrorCount    = $row.ErrorCount
        DistinctCodes = $row.DistinctCodes
        LatestUtc     = $row.LatestUtc
    }
} else {
    [pscustomobject]@{
        Status        = 'PASS'
        ErrorCount    = 0
        DistinctCodes = @()
        LatestUtc     = $null
    }
}

# ----- Signal 3: Per-tier stream coverage in last 24h -----
$coverageQuery = @"
MDE_Heartbeat_CL
| where TimeGenerated > ago(24h)
| where Tier in ('fast', 'exposure', 'config', 'inventory', 'maintenance')
| summarize TierLastSeen = max(TimeGenerated), TierStreamsSucceeded = max(StreamsSucceeded) by Tier
"@
$coverageRows = Invoke-WorkspaceQuery -Query $coverageQuery
$expectedTiers = @('fast', 'exposure', 'config', 'inventory', 'maintenance')
$tierStatus = @{}
foreach ($t in $expectedTiers) {
    $row = $coverageRows | Where-Object { $_.Tier -eq $t } | Select-Object -First 1
    $tierStatus[$t] = if ($row -and $row.TierStreamsSucceeded -gt 0) { 'PASS' } else { 'FAIL' }
}
$failingTiers = $tierStatus.GetEnumerator() | Where-Object Value -eq 'FAIL' | ForEach-Object { $_.Key }
$coverageResult = [pscustomobject]@{
    Status        = if ($failingTiers.Count -eq 0) { 'PASS' } else { 'PARTIAL' }
    FailingTiers  = $failingTiers
    PerTierStatus = $tierStatus
}

# ----- Overall verdict -----
$verdict = if (
    $hbResult.Status -eq 'PASS' -and
    $authResult.Status -eq 'PASS' -and
    $coverageResult.Status -eq 'PASS'
) {
    'HEALTHY'
} elseif (
    $authResult.Status -eq 'FAIL'
) {
    'FAILED'
} else {
    'DEGRADED'
}

$reasons = @()
if ($hbResult.Status -ne 'PASS') {
    $reasons += "No successful poll heartbeat in last $HeartbeatLookbackMinutes minutes"
}
if ($authResult.Status -ne 'PASS') {
    $reasons += "Auth chain errors in last $AuthErrorLookbackMinutes minutes: $($authResult.ErrorCount) (codes: $($authResult.DistinctCodes -join ', '))"
}
if ($coverageResult.Status -ne 'PASS') {
    $reasons += "Tiers with no successful poll in last 24h: $($coverageResult.FailingTiers -join ', ')"
}

$result = [pscustomobject]@{
    Verdict          = $verdict
    Reasons          = $reasons
    HeartbeatSignal  = $hbResult
    AuthChainSignal  = $authResult
    CoverageSignal   = $coverageResult
    CheckedUtc       = [datetime]::UtcNow.ToString('o')
    WorkspaceId      = $WorkspaceId
}

switch ($OutputFormat) {
    'Object'   { $result }
    'Json'     { $result | ConvertTo-Json -Depth 6 }
    'Markdown' {
        $md = @"
# XdrLogRaider connector health — $($result.CheckedUtc)

**Verdict**: **$($result.Verdict)**

$(if ($result.Reasons.Count -gt 0) { "## Reasons`n$($result.Reasons | ForEach-Object { "- $_" } | Out-String)" })

## Heartbeat (last $HeartbeatLookbackMinutes minutes)
- Status: $($result.HeartbeatSignal.Status)
- Polls: $($result.HeartbeatSignal.PollCount)
- Tiers seen: $($result.HeartbeatSignal.TiersSeen -join ', ')
- Latest UTC: $($result.HeartbeatSignal.LatestUtc)

## Auth chain (last $AuthErrorLookbackMinutes minutes)
- Status: $($result.AuthChainSignal.Status)
- AADSTS errors: $($result.AuthChainSignal.ErrorCount)
- Codes: $($result.AuthChainSignal.DistinctCodes -join ', ')

## Per-tier coverage (last 24h)
- Status: $($result.CoverageSignal.Status)
- Failing tiers: $($result.CoverageSignal.FailingTiers -join ', ')
- Per-tier:
$(($result.CoverageSignal.PerTierStatus.GetEnumerator() | Sort-Object Key | ForEach-Object { "  - $($_.Key): $($_.Value)" }) -join "`n")
"@
        $md
    }
}
