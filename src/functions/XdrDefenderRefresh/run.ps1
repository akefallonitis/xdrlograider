# XdrLogRaider · Defender Refresh (TimerTrigger 1m + DurableClient)
#
# Responsibilities per cycle:
#   1. Generate a CycleId (GUID) that propagates through Orchestrator → Activity → every Track-XdrEvent.
#   2. Enumerate Defender manifest entries from $script:LoadedManifests (loaded at cold-start).
#   3. Filter by R3 capability gate (per-tenant license discovery) — reading via the Capabilities
#      module's HotCache, NOT the profile.ps1 $script: scope (which is per-runspace and not visible here).
#   4. Filter entries whose DcrImmutableId env var is unset (DCR not provisioned yet).
#   5. Schedule a Durable Orchestration with the entry list + CycleId.

param($Timer, $starter, $TriggerMetadata)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# G-D fail-safe: a Telemetry module-load miss must NEVER break the dispatch cycle. Track-XdrEvent is
# called (unguarded) below for cycle observability; if the cmdlet is absent (module failed to load),
# define a no-op shim so CommandNotFound cannot throw under ErrorActionPreference='Stop'. When the real
# module IS loaded the guard skips the shim and the real cmdlet is used (no shadowing).
if (-not (Get-Command Track-XdrEvent -ErrorAction SilentlyContinue)) {
    function Track-XdrEvent { param([string]$Name, [hashtable]$Properties) }
}

$cycleStartUtc = [DateTime]::UtcNow
$cycleId       = [Guid]::NewGuid().ToString()

Write-Host "[XdrDefenderRefresh] Cycle started · $cycleStartUtc · cycleId=$cycleId · isPastDue=$($Timer.IsPastDue)"

# ─── R3 capability resolution ──────────────────────────────────────────────────
# Get the module-cached capabilities (populated at cold-start in profile.ps1; HotCache shared
# across runspaces because $script: in a module is process-scoped, unlike $script: in profile.ps1).
# If the cold-start probe failed transiently, this call will retry (StateStore fallback or live probe).
$tenantCapabilities = $null
if (Get-Command Get-XdrTenantCapabilities -ErrorAction SilentlyContinue) {
    try {
        $tenantCapabilities = Get-XdrTenantCapabilities -Portal 'Defender' -ErrorAction SilentlyContinue
    } catch {
        # Transient failure → R3 gate fail-opens (capability filter Test-XdrRequiresProducts handles null safely).
        # §4.B B11: surface the fail-open as a GATEABLE telemetry event (alongside the warning · not instead of it)
        # so a silent capability-fetch fail-open is visible to gating instead of only Write-Warning host-noise.
        Write-Warning "[XdrDefenderRefresh] Get-XdrTenantCapabilities failed (fail-open): $($_.Exception.Message)"
        Track-XdrEvent -Name 'Entry.FailOpen' -Properties @{ GateName = 'CapabilityFetch'; CorrelationId = $cycleId }
    }
}
$tenantProducts = if ($tenantCapabilities) { $tenantCapabilities.Products } else { $null }

# ─── Manifest entry enumeration (ALL portals with a shipped manifest · registry-driven · Defender-only today) ──────────
# Runspace-independent load (plan §23 · fixes count=0). profile.ps1 populates $script:LoadedManifests
# in ITS runspace only; the pooled runspaces that run this TimerTrigger don't see it (observed live:
# count=1 on the cold-start cycle in profile's runspace, count=0 on every cycle after → 0 dispatch →
# 0 rows). Get-XdrManifests lazy-loads + caches per-runspace — the same pattern profile.ps1 already
# uses for the capability HotCache; the manifests were simply never migrated to it.
$entries = @()
$loadedManifests = if (Get-Command Get-XdrManifests -ErrorAction SilentlyContinue) {
    Get-XdrManifests
} elseif (Test-Path Variable:script:LoadedManifests) {
    $script:LoadedManifests
} else {
    @{}
}
if ($loadedManifests -and $loadedManifests.Count -gt 0) {
    # F1.4c · enumerate EVERY portal with a shipped manifest (registry-driven · de-Defender-ized). Defender is BYTE-
    # IDENTICAL: it is the only key today, the outer loop runs once, and PartitionPrefix resolves to 'Defender'.
    foreach ($portalKey in $loadedManifests.Keys) {
        $portalManifest = $loadedManifests[$portalKey]
        if (-not $portalManifest) { continue }
        $partitionPrefix = try { [string](Get-XdrPortalConfig -Portal ([string]$portalKey))['PartitionPrefix'] } catch { [string]$portalKey }
        foreach ($catKey in $portalManifest.Keys) {
            $catData = $portalManifest[$catKey]
            if (-not $catData) { continue }
            # Each .psd1 returns @{ Defender = @{ Category=..; Operations=@() } } · unwrap defensively.
            $catBlock = if ($catData.ContainsKey($portalKey)) { $catData[$portalKey] } else { $catData }
            if (-not $catBlock.ContainsKey('Operations')) { continue }
            # F7 · batch-read this category's checkpoint partition ONCE (kills the cadence gate's O(N) per-op
            # cold-start point-reads + the timeout risk). FAIL-OPEN: @{} on any error/absence → every op treated as
            # due (the SAME fail-open the per-op gate's catch used). The poll itself still does its own EO1-strict
            # Get-XdrCheckpoint (with the ETag for atomic write-back) — this map is for the cadence/overdue gate only.
            $catPartitionKey = "${partitionPrefix}_$($catBlock.Category)"
            $catCheckpoints = if (Get-Command Get-XdrCheckpointsForPartition -ErrorAction SilentlyContinue) { Get-XdrCheckpointsForPartition -PartitionKey $catPartitionKey } else { @{} }
            foreach ($op in @($catBlock['Operations'])) {
                # V1 (§21.1): per-Op fail-safe. A malformed/incomplete manifest entry (a missing OPTIONAL key — which
                # under Set-StrictMode -Version Latest THROWS PropertyNotFoundException on dot-access, verified — or a
                # bad cadence string) must NEVER abort the whole enumeration: that zeroes the cycle for ALL ops (the
                # crash-loop class once the category grows past 1 op). Catch per-Op, log loud, drop just this Op,
                # continue. Optional-key reads below are also indexer-not-dot so a missing key yields $null, not a throw.
                try {
                # 4-gate dispatch per plan §4.18 · NO `IsActive` flag · all gates evaluated dynamically per tenant per cycle.
                # G-Validation is implicit (Validate-Manifests excludes Stub/Inactive at build · only Validated entries
                # reach $script:LoadedManifests in production builds).

                # G-Capability: skip Operations whose RequiresProducts has no intersection with R3-discovered tenant products.
                if (Get-Command Test-XdrRequiresProducts -ErrorAction SilentlyContinue) {
                    $allowed = Test-XdrRequiresProducts -RequiresProducts $op['RequiresProducts'] -TenantProducts $tenantProducts
                    if (-not $allowed) {
                        Track-XdrEvent -Name 'Entry.RequiresProducts.Skipped' -Properties @{
                            OperationKey     = $op['OperationKey']
                            RequiresProducts = ($op['RequiresProducts'] -join ',')
                            TenantProducts   = ($tenantProducts -join ',')
                            CorrelationId    = $cycleId
                        }
                        continue
                    }
                }

                # G-Cadence: skip Operations whose last-poll + cadence has not elapsed (per-Op poll-rate isolation).
                # Reads StateStore XdrCheckpoint PartitionKey=Portal_Category RowKey=OperationKey · `LastUpdatedUtc` column
                # (canonical column written by Save-XdrCheckpointAtomic at Runtime.psm1 · NOT `LastFiredUtc`).
                # If checkpoint absent (first cycle ever for this Op) · proceed (treat as due).
                # Side-effect: records how-overdue each surviving Op is, for the most-overdue-first per-cycle cap below.
                $opOverdueSeconds = [double]::MaxValue   # no checkpoint (first cycle ever) → maximally overdue → cap-priority
                if ($op['Cadence']) {
                    try {
                        # F7 · look up the pre-batched partition map (one read/category above) instead of a per-op point-read.
                        $checkpoint = $catCheckpoints[[string]$op['OperationKey']]
                        if ($checkpoint -and $checkpoint.LastUpdatedUtc) {
                            # WS-A · culture-safe parse: ConvertTo-XdrUtc (invariant · assume-UTC for naive · lossless
                            # for an -AsHashtable-promoted [DateTime]) instead of the bare [DateTime]::Parse (current
                            # culture → dd/MM swap) + invariant TimeSpan.Parse for the cadence span. A null/unparseable
                            # LastUpdatedUtc → skip the gate (leave $opOverdueSeconds maximally overdue = treat as due).
                            $lastUpdated = (ConvertTo-XdrUtc $checkpoint.LastUpdatedUtc)
                            if ($lastUpdated) {
                                $cadenceSpan = [TimeSpan]::Parse($op['Cadence'], [System.Globalization.CultureInfo]::InvariantCulture)
                                $nextDueUtc = $lastUpdated + $cadenceSpan
                                if ($cycleStartUtc -lt $nextDueUtc) {
                                    Track-XdrEvent -Name 'Entry.CadenceNotDue.Skipped' -Properties @{
                                        OperationKey   = $op['OperationKey']
                                        LastUpdatedUtc = $lastUpdated.ToString('o')
                                        NextDueUtc     = $nextDueUtc.ToString('o')
                                        Cadence        = $op['Cadence']
                                        CorrelationId  = $cycleId
                                    }
                                    continue
                                }
                                $opOverdueSeconds = ($cycleStartUtc - $nextDueUtc).TotalSeconds   # passed the gate → overdue by this much
                            }
                        }
                    } catch {
                        # INTENTIONAL-FAIL-SAFE: cadence gate failure must not block cycle. Treat as due.
                        Write-Warning "[XdrDefenderRefresh] G-Cadence read failed for $($op['OperationKey']) (fail-open): $($_.Exception.Message)"
                    }
                }

                # G-Provisioned: resolved below at $readyEntries filter (skip entries with no DcrImmutableId env var).
                # Build a flattened entry hashtable for the Activity payload.
                # Operator architectural binding 2026-06-02: DCR co-located with FA in connector RG → enables ARM-time
                # reference() to immutableId directly (same-scope reference works · cross-scope reference to nested
                # deployment outputs does not). Env var XDRLR_DCR_DEFENDER_<CATEGORY> holds the immutable ID itself
                # (resolved at deploy time · no runtime Az REST GET · no Reader-on-DCR role assignment needed).
                $entry = @{}
                foreach ($k in $op.Keys) { $entry[$k] = $op[$k] }
                # Seed Portal/Category from the catalog ROOT (they are NOT per-Op keys) so the Activity's
                # partition key + row envelope Portal/Category columns are correct (plan §24 G1).
                $entry['Portal']   = if ($catBlock.ContainsKey('Portal'))   { $catBlock['Portal'] }   else { $portalKey }
                $entry['Category'] = if ($catBlock.ContainsKey('Category')) { $catBlock['Category'] } else { $catKey }
                $entry['DcrImmutableId'] = if ($op['DcrImmutableIdEnvVar']) {
                    [Environment]::GetEnvironmentVariable($op['DcrImmutableIdEnvVar'])
                } else { $null }
                # Internal bookkeeping for the per-cycle activity cap (Select-XdrCycleEntries · most-overdue-first).
                # '_'-prefixed → stripped before the Activity payload (never reaches the Orchestrator/Activity/row).
                $entry['_OverdueSeconds'] = $opOverdueSeconds
                $entries += $entry
                } catch {
                    Write-Warning "[XdrDefenderRefresh] Op enumeration failed for '$($op['OperationKey'])' (skipped · per-Op fail-safe): $($_.Exception.Message)"
                    if (Get-Command Track-XdrEvent -ErrorAction SilentlyContinue) {
                        Track-XdrEvent -Name 'Entry.Enumeration.Failed' -Properties @{ OperationKey = [string]$op['OperationKey']; Error = $_.Exception.Message; CorrelationId = $cycleId }
                    }
                    continue
                }
            }
        }
    }
}

Write-Host "[XdrDefenderRefresh] Manifest entries enumerated · count=$($entries.Count)"

if ($entries.Count -eq 0) {
    Write-Host "[XdrDefenderRefresh] No active entries · cycle no-op"
    # F-OBS-1: heartbeat on EVERY cycle incl. idle — so 'alive but idle' is distinguishable from a dead worker.
    if (Get-Command Send-XdrHeartbeat -ErrorAction SilentlyContinue) { Send-XdrHeartbeat -CycleId $cycleId -OpsDispatched 0 -OpenCircuits 0 -DurationMs ([int]((([DateTime]::UtcNow) - $cycleStartUtc).TotalMilliseconds)) }
    return
}

# Skip entries with no provisioned DCR (the env var is set by ARM after DCR deployment).
$readyEntries  = @($entries | Where-Object { $_.DcrImmutableId })
$skippedNoDcr  = $entries.Count - $readyEntries.Count
if ($skippedNoDcr -gt 0) {
    Write-Host "[XdrDefenderRefresh] Skipped $skippedNoDcr entries with no DcrImmutableId env var set"
}

if ($readyEntries.Count -eq 0) {
    Write-Host "[XdrDefenderRefresh] No entries with provisioned DCRs · cycle no-op"
    # F-OBS-1: heartbeat on EVERY cycle incl. idle (no provisioned DCRs) — liveness must not depend on dispatch.
    if (Get-Command Send-XdrHeartbeat -ErrorAction SilentlyContinue) { Send-XdrHeartbeat -CycleId $cycleId -OpsDispatched 0 -OpenCircuits 0 -DurationMs ([int]((([DateTime]::UtcNow) - $cycleStartUtc).TotalMilliseconds)) }
    return
}

# ─── Per-cycle activity cap + most-overdue-first staggering (plan §4.5/§4.9 · iter32 519-op timeout guard) ───
# The G-Cadence gate above already isolates per-Op poll-rate; this caps how many *due* Ops dispatch in ONE cycle
# so a cold-start "everything due at once" burst cannot exceed the Y1 Linux-Consumption 10-min function timeout.
# Generic + no-op at v0.1.0 (1 Op << cap); correct at Defender's 594-op scale. Default 50, override via appsetting.
# Capped Ops fire on later cycles; same-cadence Ops naturally desync as the cap rotates through the due-set.
$maxPerCycle = 50
$envCap = [Environment]::GetEnvironmentVariable('XDRLR_MAX_ACTIVITIES_PER_CYCLE')
if ($envCap) {
    $parsedCap = 0
    if ([int]::TryParse($envCap, [ref]$parsedCap) -and $parsedCap -ge 1) { $maxPerCycle = $parsedCap }
}
$eligibleCount = $readyEntries.Count
if (Get-Command Select-XdrCycleEntries -ErrorAction SilentlyContinue) {
    $readyEntries = @(Select-XdrCycleEntries -Entries $readyEntries -MaxPerCycle $maxPerCycle)
} elseif ($readyEntries.Count -gt $maxPerCycle) {
    $readyEntries = @($readyEntries | Select-Object -First $maxPerCycle)
}
if ($eligibleCount -gt $readyEntries.Count) {
    $deferred = $eligibleCount - $readyEntries.Count
    Write-Host "[XdrDefenderRefresh] Activity cap: dispatching $($readyEntries.Count) of $eligibleCount eligible · $deferred deferred to next cycle (most-overdue-first)"
    Track-XdrEvent -Name 'Cycle.ActivityCapped' -Properties @{
        Eligible      = $eligibleCount
        Dispatched    = $readyEntries.Count
        Deferred      = $deferred
        MaxPerCycle   = $maxPerCycle
        CorrelationId = $cycleId
    }
}

# ─── Schedule Durable Orchestration ────────────────────────────────────────────
# Standard Durable Functions PowerShell cmdlet signature:
#   Start-NewOrchestration -FunctionName <name> -InputObject <data> -InstanceId <id>
# DurableClient ($starter) is auto-injected via the function.json binding · NOT a parameter.
#
# The orchestration input is passed as ONE JSON STRING, NOT a live hashtable. Passing $body as a live
# hashtable made the Durable PowerShell serializer corrupt every STRING leaf into an EMPTY ARRAY on the
# refresh->orchestrator hop — live RAW-INPUT on 0a25e68 showed the activity wrapper arriving as
# {"CycleId":[],"EntryJson":[]} (keys intact, values []), so CycleId (a GUID) and each Entries element (a
# JSON string) reached the orchestrator empty → Op=unknown → empty URL → 500 → 0 rows. A JSON string is
# serialized verbatim; Durable then parses it back into an OrderedHashtable with the real values preserved
# (proven by the activity hop, where the orchestrator's JSON string arrives as a populated OrderedHashtable).
# Each Entries element is itself a per-entry JSON string (so nested ProjectionMap/TimeFilter/Pagination
# survive); the Activity double-parses via ConvertFrom-XdrActivityInput. ConvertTo-Json is deterministic.
$body = @{
    CycleId       = $cycleId
    CycleStartUtc = $cycleStartUtc.ToString('o')
    # Strip '_'-prefixed internal bookkeeping keys (e.g. _OverdueSeconds) so the Activity payload carries ONLY
    # the manifest data-plane fields — the per-entry JSON is byte-identical to pre-cap behavior at 1 Op.
    Entries       = @($readyEntries | ForEach-Object {
        $clean = @{}
        foreach ($k in $_.Keys) { if ($k -notlike '_*') { $clean[$k] = $_[$k] } }
        $clean | ConvertTo-Json -Depth 20 -Compress
    })
    Portal        = 'Defender'
}
$bodyJson = $body | ConvertTo-Json -Depth 25 -Compress
# Base64-encode the orchestration input. PROVEN (live 5151fed): Refresh builds a real JSON string
# (inputLen=2336) but the Durable PS layer parses a JSON/object orchestration input and EMPTIES every string
# leaf to [] before the orchestrator reads it ($Context.Input arrives as {"CycleId":[],...}). A base64 string
# is NOT valid JSON, so Durable cannot parse+empty it — it survives verbatim; the orchestrator base64-decodes.
$bodyB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($bodyJson))

$null = Start-NewOrchestration -FunctionName 'XdrDefenderOrchestrator' -InputObject $bodyB64 -InstanceId $cycleId
Write-Host "[XdrDefenderRefresh] Scheduled orchestration · instanceId=$cycleId · entries=$($readyEntries.Count) · jsonLen=$($bodyJson.Length) · b64Len=$($bodyB64.Length)"

# ─── G-G · per-cycle liveness heartbeat (plan §3.3/§4.I) ───────────────────────
# Emit ONE liveness signal at the end of a productive cycle, carrying ONLY real measured values:
#   OpsDispatched = the count we actually scheduled · DurationMs = wall-clock for this dispatch ·
#   OpenCircuits  = honest tally of the dispatched ops whose breaker is currently Open (degradation signal).
# Guarded with Get-Command exactly like the G-D Track-XdrEvent shim so a Telemetry module load-miss can NEVER
# break the cycle (the heartbeat is ALSO internally try/catch fail-safe). No fabricated behavioral fields.
if (Get-Command Send-XdrHeartbeat -ErrorAction SilentlyContinue) {
    # OpenCircuits: count dispatched ops with an Open breaker using the existing (guarded) breaker API. Bounded by
    # the per-cycle cap. Any read failure is swallowed (best-effort liveness · never block the cycle).
    $openCircuits = 0
    if ((Get-Command Get-XdrCircuitState -ErrorAction SilentlyContinue) -and (Get-Command Test-XdrCircuitClosed -ErrorAction SilentlyContinue)) {
        foreach ($re in $readyEntries) {
            try {
                $rePartition = "$(try { [string](Get-XdrPortalConfig -Portal ([string]$re['Portal']))['PartitionPrefix'] } catch { [string]$re['Portal'] })_$($re['Category'])"
                $reCircuit = Get-XdrCircuitState -PartitionKey $rePartition -OperationKey $re['OperationKey'] -ErrorAction SilentlyContinue
                if ($reCircuit -and -not (Test-XdrCircuitClosed -CircuitState $reCircuit)) { $openCircuits++ }
            } catch {
                # INTENTIONAL-FAIL-SAFE: a breaker read blip must not abort the heartbeat tally.
            }
        }
    }
    $cycleDurationMs = [int]((([DateTime]::UtcNow) - $cycleStartUtc).TotalMilliseconds)
    Send-XdrHeartbeat -CycleId $cycleId -OpsDispatched $readyEntries.Count -OpenCircuits $openCircuits -DurationMs $cycleDurationMs
}
