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
# OperationId propagation (Section R B-4): passed by Xdr-Refresh; falls back to
# Context.InstanceId so legacy invocations still get a correlation key.
# CRITICAL: cast to [string] FIRST. `if ($orchInput.OperationId)` would invoke
# JValue.IConvertible.ToBoolean() which throws FormatException on non-bool values
# like a GUID string ("String 'guid' was not recognized as a valid Boolean").
$opIdRaw      = [string]$orchInput.OperationId
$operationId  = if ([string]::IsNullOrWhiteSpace($opIdRaw)) { [string]$Context.InstanceId } else { $opIdRaw }

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
        (-not $_.Contains('Portal') -or [string]$_.Portal -eq [string]$portal) -and
        # Section R++.A W2: skip Availability='deprecated' streams. They return
        # 4xx by design (e.g. MDE_StreamingApiConfig_CL Returns 404 on modern
        # tenants per manifest comment). Polling them wastes auth-call budget
        # and adds noise to AppExceptions.
        (-not $_.Contains('Availability') -or [string]$_.Availability -ne 'deprecated')
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

# Phase A2 circuit-breaker pre-flight: read XdrTierState for this Portal,
# count streams currently in CircuitState='open' with unexpired CooldownUntilUtc.
# If ALL streams in this Tier are open, skip the entire fan-out (no point
# burning auth/orchestration cost on a sub-area whose every endpoint is
# in cooldown). Per-stream circuit-breaker check happens inside each activity
# (Phase A1) so partial-open tiers still progress.
#
# Replay-safe: this is a DETERMINISTIC read of state at orchestration start.
# Same input produces same decision on replay (state is not mutated here).
$skippedCount = 0
try {
    $tierStateMap = Get-XdrTierStateAggregate `
        -StorageAccountName $env:STORAGE_ACCOUNT_NAME `
        -PartitionKey       $portal
    if ($tierStateMap -is [System.Collections.IDictionary]) {
        $openInTier = 0
        $consideredInTier = 0
        $now = [DateTime]::UtcNow
        foreach ($stream in $tierStreams) {
            $ek = if ($stream.Contains('EntryKey') -and $stream.EntryKey) { [string]$stream.EntryKey } else { [string]$stream.Stream }
            if ($tierStateMap.ContainsKey($ek)) {
                $consideredInTier++
                $r = $tierStateMap[$ek]
                $cs = if ($r.PSObject.Properties['CircuitState']) { [string]$r.CircuitState } else { 'closed' }
                if ($cs -eq 'open') {
                    $cooldownExpired = $true
                    if ($r.PSObject.Properties['CooldownUntilUtc']) {
                        try {
                            $cu = [DateTime]::Parse($r.CooldownUntilUtc)
                            $cooldownExpired = ($cu -le $now)
                        } catch { $cooldownExpired = $true }
                    }
                    if (-not $cooldownExpired) { $openInTier++ }
                }
            }
        }
        if ($consideredInTier -gt 0 -and $openInTier -eq $consideredInTier) {
            Write-Information ("Xdr-PollOrchestrator: ALL {0} streams in {1}|{2} circuit-open; skipping fan-out" -f $consideredInTier, $portal, $tier)
            $skippedCount = $consideredInTier
        }
    }
} catch {
    Write-Warning ("Xdr-PollOrchestrator: pre-flight circuit-breaker check failed; proceeding anyway: {0}" -f $_.Exception.Message)
}

if ($skippedCount -gt 0) {
    return [pscustomobject]@{
        Portal = $portal
        Tier = $tier
        StreamsAttempted = 0
        StreamsSucceeded = 0
        RowsIngested = 0
        StreamsSkippedCircuitOpen = $skippedCount
        Errors = @{}
        FunctionName = $functionName
    }
}

# Fan out: one activity per stream (NoWait pattern then WaitAll).
# Phase A1: pass EntryKey for activity-side dispatch — manifest is EntryKey-keyed
# (`<sub_area>::<slug>`, unique per endpoint). StreamName (workspace table name,
# e.g. Defender_ActionCenter_CL) is shared by multiple endpoints within a
# sub-area; activity uses EntryKey to look up the right manifest entry.
$activityTasks = @()
foreach ($stream in $tierStreams) {
    $entryKeyValue = if ($stream.Contains('EntryKey') -and $stream.EntryKey) { [string]$stream.EntryKey } else { [string]$stream.Stream }
    $activityInput = @{
        Portal      = $portal
        Tier        = $tier
        EntryKey    = $entryKeyValue
        StreamName  = $stream.Stream
        StreamPath  = $stream.Path
        OperationId = $operationId   # Section R B-4: propagate correlation ID to activity → telemetry → ingest
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

# NOTE (2026-05-06): Heartbeat-persist via Xdr-WriteHeartbeat activity is
# REMOVED here pending local end-to-end test coverage. Live evidence: adding
# the call left the FA host in a stalled state (no telemetry post-14:11Z, no
# function executions resumed across multiple restart+stop+start cycles).
# Activity files (Xdr-WriteHeartbeat/{function.json,run.ps1}) remain in the
# zip for future re-integration once we have a Durable runtime mock that
# proves the orchestrator → activity → Write-Heartbeat call chain locally
# without deploying. Connector card 'Connected' status remains gated on
# Connector-Heartbeat liveness rows for v0.1.0 GA.
return [pscustomobject]@{
    Portal = $portal
    Tier = $tier
    StreamsAttempted = $totalAttempted
    StreamsSucceeded = $totalSucceeded
    RowsIngested = $totalRows
    Errors = $errors
    FunctionName = $functionName
}
