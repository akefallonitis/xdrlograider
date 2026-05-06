# Xdr-PollOrchestrator — Durable Functions orchestrator (Phase H per directive 16).
#
# Receives input: @{ Portal = 'Defender'; Tier = '<Capability>' }
# Reads manifest streams filtered by Portal + Tier, fans out one
# Xdr-PollStream activity per stream, aggregates results, emits per-tier
# heartbeat with per-stream metrics.
#
# Replay-safety: orchestrator function is REPLAYED on every event. Anything
# non-deterministic (KV lookups, portal sign-in, current time) MUST happen
# in activities — never in the orchestrator body. Per Microsoft Durable
# Functions PowerShell pattern: keep orchestrator deterministic + minimal.
#
# Per .claude/plans/immutable-splashing-waffle.md Section 2.A.

param($Context)

$ErrorActionPreference = 'Stop'

# Durable Functions hands $Context.Input as a Newtonsoft.Json.Linq.JObject.
# Accessing .Portal returns a JValue (not a string) — direct use crashes the
# orchestrator with "Unable to cast object of type 'Newtonsoft.Json.Linq.JValue'
# to type 'System.String'". Explicit [string] cast normalises the type.
# (Also avoid $input — it's PowerShell's automatic enumeration variable.)
$orchInput    = $Context.Input
$portal       = [string]$orchInput.Portal
$tier         = [string]$orchInput.Tier
$functionName = [string]$orchInput.FunctionName  # passed by timer-starter for heartbeat correlation

# DETERMINISTIC: read manifest. Get-XdrEndpointManifest -Portal $portal returns
# entries from that portal's manifest file. The Portal filter below is kept for
# forward-compat with v0.2.0+ multi-tenant FA scenarios (one orchestrator
# instance polling MULTIPLE portals' manifests merged into a single hashtable).
# v0.1.0 GA: Defaults sets Portal='Defender' (logical name) so this filter
# matches; FQDN moved to a separate PortalHost field used only by L2 auth.
$manifest = Get-XdrEndpointManifest -Portal $portal
$manifestCount = if ($manifest -and $manifest.Count) { [int]$manifest.Count } else { 0 }
$tierStreams = @(
    $manifest.Values |
    Where-Object {
        $_ -is [System.Collections.IDictionary] -and
        $_.Contains('Tier') -and ([string]$_.Tier -eq [string]$tier) -and
        (-not $_.Contains('Portal') -or [string]$_.Portal -eq [string]$portal)
    }
)
Write-Information ("Xdr-PollOrchestrator: Portal='{0}' Tier='{1}' manifestCount={2} matchedStreams={3}" -f $portal, $tier, $manifestCount, $tierStreams.Count)

if ($tierStreams.Count -eq 0) {
    # No streams for this Portal+Tier combo; emit empty heartbeat
    return [pscustomobject]@{
        Portal = $portal
        Tier = $tier
        StreamsAttempted = 0
        StreamsSucceeded = 0
        RowsIngested = 0
        Errors = @{}
        FunctionName = $functionName
    }
}

# Fan out: one activity per stream (NoWait pattern then WaitAll)
$activityTasks = @()
foreach ($stream in $tierStreams) {
    $activityInput = @{
        Portal     = $portal
        Tier       = $tier
        StreamName = $stream.Stream
        StreamPath = $stream.Path
    }
    $task = Invoke-DurableActivity -FunctionName 'Xdr-PollStream' -Input $activityInput -NoWait
    $activityTasks += $task
}

# Wait for all activities to complete (fan-in)
$results = Wait-DurableTask -Task $activityTasks -Any:$false

# DETERMINISTIC: aggregate results
$totalAttempted = $tierStreams.Count
$totalSucceeded = 0
$totalRows = 0
$errors = @{}
foreach ($r in $results) {
    if ($r.Success) {
        $totalSucceeded++
        $totalRows += $r.RowsIngested
    } else {
        $errors[$r.StreamName] = $r.Error
    }
}

return [pscustomobject]@{
    Portal = $portal
    Tier = $tier
    StreamsAttempted = $totalAttempted
    StreamsSucceeded = $totalSucceeded
    RowsIngested = $totalRows
    Errors = $errors
    FunctionName = $functionName
}
