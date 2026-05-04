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
$input = $Context.Input
$portal = $input.Portal
$tier = $input.Tier
$functionName = $input.FunctionName  # passed by timer-starter for heartbeat correlation

# DETERMINISTIC: read manifest (cached at module-load; no I/O)
$manifest = Get-MDEEndpointManifest
$tierStreams = @(
    $manifest.Values |
    Where-Object {
        $_ -is [hashtable] -and
        $_.ContainsKey('Tier') -and $_.Tier -eq $tier -and
        (-not $_.ContainsKey('Portal') -or $_.Portal -eq $portal)
    }
)

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
