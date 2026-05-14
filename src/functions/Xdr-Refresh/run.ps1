# Xdr-Refresh — Universal portal-agnostic cadence-tier dispatcher (Section R, 2026-05-06).
#
# Replaces the 5 deleted Defender-*-Refresh timer functions AND scales to
# v0.2.0+ multi-portal expansion (Entra/Purview/Intune) WITHOUT adding new
# function-app endpoints — operators just toggle manifest entries.
#
# Cron: every 1 min. Body:
#   1. Read XdrTierState Storage table for ALL enabled (Portal, Tier) pairs.
#      Each row's RowKey='__schedule__' carries `nextRunUtc`.
#   2. For each pair whose nextRunUtc <= now, call Start-NewOrchestration with
#      @{ Portal=<P>; Tier=<T>; FunctionName='Xdr-Refresh' }.
#   3. Update nextRunUtc = now + cadence (Get-XdrTierCadenceMap value for Tier).
#
# Failure modes:
#   - If XdrTierState is empty (first run after deploy), seed all configured
#     (Portal, Tier) pairs with `nextRunUtc = now` so they fire on the next
#     1-min tick.
#   - If a Storage write fails for a single pair, log + continue with others.

param($Timer, $Starter)

$ErrorActionPreference = 'Stop'

# Cadence map: Tier -> TimeSpan
$cadenceMap = Get-XdrTierCadenceMap

# v0.1.0 GA: only Defender is enabled. v0.2.0+ adds 'Entra','Purview','Intune'.
# This list comes from a single source of truth — see Manifest.SemanticContract.
$enabledPortals = @('Defender')

$storageAccount = $env:STORAGE_ACCOUNT_NAME
if (-not $storageAccount) {
    Write-Warning "Xdr-Refresh: STORAGE_ACCOUNT_NAME env var not set — dispatcher cannot read XdrTierState"
    return
}

if (-not $Starter) {
    Write-Warning "Xdr-Refresh: DurableClient binding 'Starter' was null — Durable Functions extension unavailable; cannot dispatch"
    return
}

$nowUtc = [DateTime]::UtcNow

# Rule 15 stagger seed: deterministic per-partition offset modulo cadence.
# Without stagger, all daily-cadence (Portal, Tier) advances align to
# baseTime + cadence — at v0.2.0+ multi-portal, 4 portals × Inventory tier
# would fire within the same 1-min window. SHA1(partitionKey)→uint32→mod
# cadenceSeconds distributes NextRunUtc across the cadence window.
function Get-XdrStaggerSeconds {
    param([string]$PartitionKey, [int]$CadenceSeconds)
    if ($CadenceSeconds -le 60) { return 0 }  # No stagger needed for short cadences
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try {
        $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($PartitionKey))
        $uint = [BitConverter]::ToUInt32($bytes, 0)
        return [int]($uint % [uint32]$CadenceSeconds)
    } finally {
        $sha.Dispose()
    }
}

# Read the schedule rows. Each row's PartitionKey='Portal|Tier', RowKey='__schedule__'.
$scheduleRows = @()
try {
    $scheduleRows = @(Invoke-XdrStorageTableEntity `
        -StorageAccountName $storageAccount `
        -TableName          'XdrTierState' `
        -Operation          'Query' `
        -Filter             "RowKey eq '__schedule__'")
} catch {
    Write-Warning ("Xdr-Refresh: failed to read XdrTierState: {0}" -f $_.Exception.Message)
    $scheduleRows = @()
}

# Seed missing schedules so every (Portal, Tier) eventually fires.
$existingKeys = @{}
foreach ($r in $scheduleRows) { $existingKeys[$r.PartitionKey] = $r }

$dispatchedCount = 0
foreach ($portal in $enabledPortals) {
    foreach ($tier in $cadenceMap.Keys) {
        $partitionKey = "$portal|$tier"
        $row = $existingKeys[$partitionKey]
        $shouldFire = $false
        if (-not $row) {
            # First-run seed: fire immediately so initial cycle starts.
            $shouldFire = $true
        } else {
            try {
                $nextRunUtc = [DateTime]::Parse($row.NextRunUtc)
                if ($nextRunUtc -le $nowUtc) { $shouldFire = $true }
            } catch {
                # Corrupted row; treat as due.
                $shouldFire = $true
            }
        }

        if ($shouldFire) {
            # H4 optimistic concurrency (Plan §8.6): ADVANCE the schedule row
            # FIRST (with If-Match: <etag>), THEN dispatch the orchestration only
            # if the advance succeeded. Without this, two Xdr-Refresh ticks
            # racing on FA scale-out can BOTH see nextRunUtc <= now and BOTH
            # dispatch the orchestration — double-fire. Advance-first ordering
            # means at most one dispatcher per (Portal, Tier) per tick;
            # PollOrchestrator + PollStream are already replay-safe but this
            # eliminates the wasted activity-cost burst.
            #
            # First-run seed (no prior row) skips If-Match — there's no etag to
            # compare against; race is bounded to one extra dispatch on first
            # tick after deploy, harmless.
            $cadenceSec = [int]$cadenceMap[$tier].TotalSeconds
            $staggerSec = Get-XdrStaggerSeconds -PartitionKey $partitionKey -CadenceSeconds $cadenceSec
            $nextNext = $nowUtc + $cadenceMap[$tier] + [TimeSpan]::FromSeconds($staggerSec)
            $newOperationId = ([Guid]::NewGuid().ToString())
            $scheduleEntity = @{
                PartitionKey   = $partitionKey
                RowKey         = '__schedule__'
                Portal         = $portal
                Tier           = $tier
                LastDispatchedUtc = $nowUtc.ToString('o')
                NextRunUtc     = $nextNext.ToString('o')
                LastOperationId = $newOperationId
            }
            $rowEtag = if ($row -and $row.PSObject.Properties['odata.etag']) { [string]$row.'odata.etag' } else { '' }
            $advanceResult = $null
            try {
                $advanceArgs = @{
                    StorageAccountName = $storageAccount
                    TableName          = 'XdrTierState'
                    PartitionKey       = $partitionKey
                    RowKey             = '__schedule__'
                    Operation          = 'Upsert'
                    Entity             = $scheduleEntity
                }
                if ($rowEtag) { $advanceArgs['IfMatch'] = $rowEtag }
                $advanceResult = Invoke-XdrStorageTableEntity @advanceArgs
            } catch {
                Write-Warning ("Xdr-Refresh: schedule-row advance failed for {0}: {1}" -f $partitionKey, $_.Exception.Message)
                continue
            }
            if ($advanceResult -eq 'ETAG_MISMATCH') {
                # Another Xdr-Refresh instance advanced this row in this tick.
                # That instance owns the dispatch; we skip silently. This is
                # expected behavior at FA scale-out, not an error.
                Write-Information "Xdr-Refresh: $partitionKey advance lost the race (concurrent dispatcher won this tick)"
                continue
            }
            # Schedule advanced successfully — we now own the dispatch slot.
            try {
                $instanceId = Start-NewOrchestration -DurableClient $Starter `
                    -FunctionName 'Xdr-PollOrchestrator' `
                    -InputObject @{
                        Portal       = $portal
                        Tier         = $tier
                        FunctionName = 'Xdr-Refresh'
                        OperationId  = $newOperationId
                    }
                Write-Information "Xdr-Refresh: started orchestration $instanceId for $partitionKey"
                $dispatchedCount++
                # Best-effort: stamp the LastInstanceId on the schedule row.
                # If this second Upsert fails (e.g. transient Storage 5xx), the
                # schedule is still advanced and the orchestration is running —
                # operator can correlate via OperationId in AppInsights.
                $scheduleEntity['LastInstanceId'] = $instanceId
                try {
                    Invoke-XdrStorageTableEntity `
                        -StorageAccountName $storageAccount `
                        -TableName          'XdrTierState' `
                        -PartitionKey       $partitionKey `
                        -RowKey             '__schedule__' `
                        -Operation          'Upsert' `
                        -Entity             $scheduleEntity | Out-Null
                } catch {
                    Write-Warning ("Xdr-Refresh: LastInstanceId stamp failed (orchestration $instanceId is running): {0}" -f $_.Exception.Message)
                }
            } catch {
                Write-Warning ("Xdr-Refresh: schedule advanced but orchestration start FAILED for {0}: {1} — next tick will retry" -f $partitionKey, $_.Exception.Message)
            }
        }
    }
}

Write-Information "Xdr-Refresh: tick complete; dispatched $dispatchedCount orchestration(s)"
