# XdrLogRaider · Defender Orchestrator (Durable Orchestrator)
#
# Per Durable Functions PowerShell binding: $Context is the orchestration context.
# Orchestrator constraints:
#   - MUST be deterministic across replays · NO Get-Date, NO Invoke-RestMethod, NO file I/O.
#   - Only side effect allowed: Invoke-DurableActivity (and Wait-DurableTask).
#   - Do NOT Set-StrictMode (some Durable internals trigger strict-mode noise during replay).
#
# Responsibilities:
#   1. Receive cycle input { CycleId, CycleStartUtc, Entries, Portal } from XdrDefenderRefresh.
#   2. Fan out one Activity per entry, threading CycleId into each Activity payload so the
#      Activity → Invoke-XdrEntryPoll → Track-XdrEvent chain carries the correlation id.
#   3. Wait for all activities · set custom status with summary · return cycle outcome.

param($Context)

# ─── ORCHESTRATOR DIAGNOSTIC (the previously-uninstrumented black box) ───
# Live RAW-INPUT showed the activity wrapper arriving as {"CycleId":[],"EntryJson":[]} (string leaves became
# empty arrays) across BOTH a hashtable AND a JSON-string Refresh input — so $Context.Input HERE is already
# delivering empty values, and the orchestrator is failing hard (OrchestrationFailureException). Dump the EXACT
# $Context.Input shape so the root cause is visible from AppTraces. Write-Host is logging (NOT a Durable API)
# so it is replay-safe; it may log multiple times across replays — fine for diagnostics.
# WS3.3 · the CTX dump re-logs on EVERY replay (Durable re-executes orchestrator code) — a major share of the
# 1.57M-traces/48h flood. Gated behind XDRLR_DEBUG_DURABLE: flip it on only while diagnosing a serializer issue.
if ($env:XDRLR_DEBUG_DURABLE) {
    $ctxType = try { if ($null -eq $Context.Input) { 'null' } else { $Context.Input.GetType().FullName } } catch { 'type-error' }
    $ctxDump = try {
        if ($null -eq $Context.Input) { 'null' }
        elseif ($Context.Input -is [string]) { [string]$Context.Input }
        else { [string]($Context.Input | ConvertTo-Json -Depth 8 -Compress) }
    } catch { "unserializable:$($_.Exception.GetType().Name)" }
    $ctxClip = [string]$ctxDump; if ($ctxClip.Length -gt 800) { $ctxClip = $ctxClip.Substring(0, 800) }
    Write-Host "[XdrDefenderOrchestrator] CTX-INPUT · type=$ctxType · dump=$ctxClip"
}

$cycleData = $Context.Input
# Refresh base64-encodes the cycle JSON because Durable parses+empties a raw JSON/object orchestration input
# (proven: Refresh jsonLen=2336 but $Context.Input arrives as {"CycleId":[],...}). A base64 string is opaque to
# Durable so it survives; decode it here. (Type check is on the INPUT VALUE, reads stay dot-access — materially
# different from the iter4 `-is [IDictionary]`+indexer change on $Context that broke replay.)
if ($cycleData -is [string]) {
    try {
        $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$cycleData))
        $cycleData = $json | ConvertFrom-Json -AsHashtable -Depth 30
    } catch {
        Write-Host "[XdrDefenderOrchestrator] ctx-decode-FAILED · $($_.Exception.Message)"
    }
}
$cycleId = $cycleData.CycleId
if ($env:XDRLR_DEBUG_DURABLE) { Write-Host "[XdrDefenderOrchestrator] read · cycleIdLen=$(([string]$cycleId).Length) · entriesCount=$(@($cycleData.Entries).Count)" }

# Fan out — wrap each entry with CycleId and base64-encode it for the SAME reason as the orchestration input
# (Durable parses+empties a raw JSON activity input). The Activity base64-decodes via ConvertFrom-XdrActivityInput.
$activityTasks = @()
foreach ($entryJson in $cycleData.Entries) {
    $activityWrapperJson = @{ EntryJson = $entryJson; CycleId = $cycleId } | ConvertTo-Json -Compress
    $activityInput = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($activityWrapperJson))
    $task = Invoke-DurableActivity -FunctionName 'XdrDefenderActivity' -Input $activityInput -NoWait
    $activityTasks += $task
}

# Wait for ALL activities. WRAPPED so a missing/incompatible wait cmdlet (the live recurring
# CommandNotFoundException candidate) is NAMED in AppTraces and the orchestration completes gracefully,
# instead of faulting the whole orchestration (the 26 OrchestrationFailureException/cycle). The activities were
# already scheduled above, so catching here does not lose them; the return count is non-essential.
$completedCount = 0
try {
    if ($activityTasks.Count -gt 0) {
        $results = Wait-DurableTask -Task $activityTasks
        $completedCount = @($results).Count
    }
} catch {
    Write-Host "[XdrDefenderOrchestrator] wait-FAILED · $($_.Exception.GetType().Name) · $($_.Exception.Message)"
}

# F1.4c · the cycle can span portals (each entry carries its own Portal · the dispatch is registry-driven now). Derive
# the honest distinct portal set for the cycle label. PURE computation · replay-safe · no I/O · FULLY fail-safe →
# 'Defender' (byte-identical while Defender is the only shipping portal).
$cyclePortals = 'Defender'
try {
    $pset = @($cycleData.Entries) | ForEach-Object {
        if ($_ -is [hashtable]) { $_['Portal'] }
        elseif ($_ -is [string]) { try { ($_ | ConvertFrom-Json -AsHashtable -Depth 30).Portal } catch { $null } }
    } | Where-Object { $_ } | Select-Object -Unique
    if ($pset) { $cyclePortals = ($pset -join ',') }
} catch { $cyclePortals = 'Defender' }

# ─── Cycle.Completed liveness (§21.4 F-FIX-RT · the previously-never-emitted signal) ───
# Orchestrator code is replay-driven and must do NO network I/O, so this is a host-mirror Write-Host (→ AppTraces,
# the workspace-reliable channel the F-OBS exception/heartbeat mirrors use; /v2/track is unreliable in workspace
# mode), emitted ONLY on the non-replay pass so the count is honest. This is the signal that distinguishes "a cycle
# ran to completion" from the auth crash-loop (0 Cycle.Completed observed live). IsReplaying access is guarded so a
# Durable build lacking the property degrades to emit (a duplicate host line on replay is acceptable, like the CTX dump).
$emitCompletion = $true
try { if ($Context.IsReplaying) { $emitCompletion = $false } } catch { <# INTENTIONAL-FAIL-SAFE LOCK 9 · a Durable build lacking IsReplaying degrades to emit (duplicate host line on replay is acceptable) #> }
if ($emitCompletion) {
    Write-Host "[cycle] Cycle.Completed CycleId=$cycleId Portals=$cyclePortals DispatchedActivities=$($activityTasks.Count) CompletedActivities=$completedCount"
}

return @{
    CycleId             = $cycleId
    Portal              = $cyclePortals
    Completed           = $true
    CompletedActivities = $completedCount
}
