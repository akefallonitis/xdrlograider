# XdrLogRaider · Defender Activity (Durable Activity)
#
# The actual work unit. Receives one Operation manifest entry + cycle correlation id from the
# Orchestrator, delegates to Invoke-XdrEntryPoll (the runtime keystone), returns Result.
#
# Activity contract: NEVER throws — always returns a Result hashtable. Orchestrator collects
# all results; failed Operations show Success=$false + ErrorClass/ErrorMessage.

param($InputData)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'  # capture all errors via try/catch, return Result

$activityStartedUtc = [DateTime]::UtcNow

# ─── Reconstruct { Entry; CycleId } from the Durable activity input. The Orchestrator passes a JSON STRING
# wrapper ({"EntryJson":"<entry-json>","CycleId":"<guid>"}) because the Durable PowerShell serializer mangled
# a live hashtable on the orchestrator→activity hop (keys lost → empty entry → Op=unknown → empty URL → 500 →
# 0 rows; strings round-trip intact — the same fix the Refresh→Orchestrator hop already uses for Entries). The
# reconstruction lives in the TESTABLE ConvertFrom-XdrActivityInput (Xdr.Common.Runtime) which NEVER throws and
# defends against every shape Durable can deliver (String / Hashtable / OrderedHashtable / JObject /
# PSCustomObject / 1-element array). A throw here (before the Result) would fault the task →
# OrchestrationFailureException and the Activity would never even log Started.
#
# Bulletproof RAW line FIRST (zero throwable property access): if a future host hands over a brand-new shape,
# this single AppTraces line pinpoints it WITHOUT a redeploy (§30 A-OBSERVABILITY).
# WS3.3 · high-volume diagnostic (per activity invocation, base64 payload dump) — gated behind XDRLR_DEBUG_DURABLE;
# a future host shape-change is diagnosed by flipping the setting on, not by paying the dump on every poll forever.
if ($env:XDRLR_DEBUG_DURABLE) {
    $rawType = try { if ($null -eq $InputData) { 'null' } else { $InputData.GetType().FullName } } catch { 'type-error' }
    $rawDump = try {
        if ($null -eq $InputData) { 'null' }
        elseif ($InputData -is [string]) { [string]$InputData }
        else { [string]($InputData | ConvertTo-Json -Depth 6 -Compress -WarningAction SilentlyContinue) }
    } catch { "unserializable:$($_.Exception.GetType().Name)" }
    $rawClip = [string]$rawDump; if ($rawClip.Length -gt 500) { $rawClip = $rawClip.Substring(0, 500) }
    Write-Host "[XdrDefenderActivity] RAW-INPUT · type=$rawType · dump=$rawClip"
}

$entry = @{}
$cycleId = ''
if (Get-Command ConvertFrom-XdrActivityInput -ErrorAction SilentlyContinue) {
    $parsed  = ConvertFrom-XdrActivityInput -InputData $InputData
    $entry   = $parsed.Entry
    $cycleId  = [string]$parsed.CycleId
} else {
    Write-Host "[XdrDefenderActivity] ConvertFrom-XdrActivityInput unavailable · profile.ps1 module load failed"
}
if ($entry -isnot [hashtable]) { $entry = @{} }

if ($env:XDRLR_DEBUG_DURABLE) { Write-Host "[XdrDefenderActivity] payload-diag · entryKeys=[$(@($entry.Keys) -join ',')] · cycleIdLen=$($cycleId.Length)" }

$operationKey = if ($entry['OperationKey']) { $entry['OperationKey'] } else { 'unknown' }

$result = @{
    Success       = $false
    OperationKey  = $operationKey
    CorrelationId = $cycleId
    ItemCount     = 0
    BytesIngested = 0
    ErrorClass    = $null
    ErrorMessage  = $null
    DurationMs    = 0
    StartedUtc    = $activityStartedUtc.ToString('o')
}

try {
    Write-Host "[XdrDefenderActivity] Started · OperationKey=$operationKey · CycleId=$cycleId"

    # ── 4-gate dispatch routing (plan §16 U3b) · ENTITY op → fan-out · NON-entity op → normal poll ──
    # An ENTITY op (catalogue DependsOn edge · path {param} like {CaseId}/{DeviceId}/{MachineId} · ParamSource='ParentOp')
    # CANNOT be polled directly — its URL needs a concrete id. Route it to Invoke-XdrEntityFanout (bounded · per-entity
    # exactly-once · NEVER throws). EVERYTHING ELSE — incl. ActionCenter.GetHistory (no entity {param}) — takes the
    # UNCHANGED Invoke-XdrEntryPoll path (byte-identical). The routing is structural: DependsOn present OR
    # ParamSource='ParentOp' ⇒ entity. {TenantId}-only ops are NOT entity (ParamSource='TenantContext' · R3 auto-fills).
    $isEntityOp = ($entry['DependsOn'] -is [System.Collections.IDictionary]) -or ([string]$entry['ParamSource'] -eq 'ParentOp')

    if ($isEntityOp -and (Get-Command Invoke-XdrEntityFanout -ErrorAction SilentlyContinue)) {
        # The fan-out resolves child {id}s from the BOUNDED entity-id cache; when EMPTY it self-seeds via ONE bounded
        # parent poll (Get-XdrParentEntityIds) IF a ParentEntry is supplied. Get-XdrManifests attached the parent op's
        # poll-contract as $entry['ParentEntry'] (N4 · Set-XdrParentEntryLinks) so the entity op resolves + polls its
        # {id} in production WITHOUT depending on a same-cycle/same-runspace parent feed. Empty cache + no ParentEntry
        # → graceful skip (Success=$true no-op · the cycle continues). NEVER throws.
        $parentEntry = $null
        if ($entry['ParentEntry'] -and (Get-Command ConvertTo-XdrDeepHashtable -ErrorAction SilentlyContinue)) {
            try { $parentEntry = ConvertTo-XdrDeepHashtable -InputObject $entry['ParentEntry'] } catch { $parentEntry = $null }
        }
        $fanResult = Invoke-XdrEntityFanout -Entry $entry -CorrelationId $cycleId -ParentEntry $parentEntry
        $result.Success    = [bool]$fanResult['Success']
        $result.ItemCount  = [int]($fanResult['ItemCount'] ?? 0)
        # Aggregate BytesIngested + surface the first child error (if any) for observability. A skip carries SkipReason.
        $bytes = 0; $childErrClass = $null; $childErrMsg = $null
        foreach ($cr in @($fanResult['ChildResults'])) {
            if ($cr -is [System.Collections.IDictionary]) {
                if ($cr['BytesIngested']) { $bytes += [int]$cr['BytesIngested'] }
                if (-not $childErrClass -and $cr['ErrorClass']) { $childErrClass = [string]$cr['ErrorClass']; $childErrMsg = [string]$cr['ErrorMessage'] }
            }
        }
        $result.BytesIngested = $bytes
        # E-MAJ2 · the fan-out may carry a TOP-LEVEL ErrorClass (a REAL parent-feed failure · seed poll threw → no child
        # ran, so $childErrClass is null) — surface it so the Activity records the ErrorClass and the breaker classifies
        # the cycle as failed (vs a benign empty-parent skip, which carries no ErrorClass). Prefer the top-level fan-out
        # ErrorClass; fall back to the first child error.
        $result.ErrorClass    = if ($fanResult['ErrorClass']) { [string]$fanResult['ErrorClass'] } else { $childErrClass }
        $result.ErrorMessage  = if ($fanResult['Skipped']) { [string]$fanResult['SkipReason'] } else { $childErrMsg }
        Write-Host "[XdrDefenderActivity] ENTITY fan-out · op=$operationKey · skipped=$($fanResult['Skipped']) · entitiesPolled=$($fanResult['EntitiesPolled']) · entitiesAvailable=$($fanResult['EntitiesAvailable']) · items=$($result.ItemCount)"
    } elseif (Get-Command Invoke-XdrEntryPoll -ErrorAction SilentlyContinue) {
        $pollResult = Invoke-XdrEntryPoll -Entry $entry -CorrelationId $cycleId
        $result.Success       = $pollResult.Success
        $result.ItemCount     = $pollResult.ItemCount
        $result.BytesIngested = $pollResult.BytesIngested
        $result.ErrorClass    = $pollResult.ErrorClass
        $result.ErrorMessage  = $pollResult.ErrorMessage
    } else {
        $result.ErrorClass   = 'ModuleNotLoaded'
        $result.ErrorMessage = 'Xdr.Common.Runtime.Invoke-XdrEntryPoll not available · profile.ps1 module load failed'
        Write-Warning $result.ErrorMessage
    }
} catch {
    $result.Success      = $false
    $result.ErrorClass   = $_.Exception.GetType().Name
    $result.ErrorMessage = $_.Exception.Message
}

$result.DurationMs = [int]((([DateTime]::UtcNow) - $activityStartedUtc).TotalMilliseconds)
$errSuffix = if (-not $result.Success) { " · ErrorClass=$($result.ErrorClass) · ErrorMessage=$($result.ErrorMessage)" } else { '' }
Write-Host "[XdrDefenderActivity] Completed · OperationKey=$operationKey · Success=$($result.Success) · Items=$($result.ItemCount) · $($result.DurationMs)ms$errSuffix"
return $result
