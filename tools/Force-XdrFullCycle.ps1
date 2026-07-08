# tools/Force-XdrFullCycle.ps1
#
# Plan §8.4 contract + §4.21 override-sync extension · forces the next FA TimerTrigger cycle to fire eligible
# Operations by making them CADENCE-DUE (one-shot manual burst for verification or post-redeploy validation).
#
# F-FORCE (audit 2026-06-12 · the WORKING mechanism): the G-Cadence gate (XdrDefenderRefresh/run.ps1) reads EXACTLY
# ONE signal — XdrCheckpoint.LastUpdatedUtc (skip while lastUpdated + Cadence > now; absent/blank ⇒ due, maximally
# overdue). The prior version of this tool wrote a 'ForceFullCycle'/'ForceNow:<op>' marker row to XdrTierState that
# NO runtime code ever read — a silent no-op trigger (dead-marker class · removed, never extend). This version
# clears LastUpdatedUtc on the real checkpoint row(s) via an AAD table MERGE:
#   FORCE-WITHOUT-REWIND · the merge touches ONLY LastUpdatedUtc. Cursor / BoundaryKeys / Resume* are NEVER
#   written, so the exactly-once frontier is untouched — the forced cycle polls from the SAME high-water and
#   ingests ZERO duplicates (a no-new-data force is a clean no-op cycle + a fresh LastUpdatedUtc).
#
# Two modes (unchanged contract):
#   1. ALL-OPS mode (default · no -OperationKey) · clears LastUpdatedUtc on EVERY XdrCheckpoint row → every op
#      with a checkpoint is due next cycle (ops with no checkpoint yet are always due anyway).
#   2. PER-OP mode  (-OperationKey <key>)        · clears ONLY that op's row(s) (RowKey == OperationKey across
#      partitions; an entity-fanout child 'Op|entity' row is NOT matched — force the parent op).
#
# Verification: the next TimerTrigger (~1min) emits NO Entry.CadenceNotDue.Skipped for the forced op(s); the cycle
# itself emits the normal Entry.Poll.* telemetry. Audit trail = this az call (AAD principal) + the cycle telemetry.
#
# Discipline: NO destructive ops · NO --no-wait · AAD data-plane ONLY (--auth-mode login; the FA storage account
# has shared-key DISABLED · allowSharedKeyAccess=false · verified 2026-06-09). Prereq: az login (or the .env.local
# SP · Storage Table Data Contributor). Idempotent · safe to call repeatedly.

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [Parameter(Mandatory)] [string] $StorageAccount,

    # Per-Op burst (plan §4.21 ForceNow mode) · e.g. 'GetHistory'. Omitted → ALL-OPS mode (plan §8.4 default).
    [string] $OperationKey = '',

    [string] $TableName = 'XdrCheckpoint'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$mode  = if ([string]::IsNullOrWhiteSpace($OperationKey)) { 'ForceFullCycle' } else { 'ForceNow' }
$scope = if ($mode -eq 'ForceFullCycle') { 'all checkpointed Ops' } else { "Op=$OperationKey only · other Ops continue natural cadence" }
Write-Host "[Force-XdrFullCycle] RG=$ResourceGroup SA=$StorageAccount Table=$TableName · Mode=$mode · Scope=$scope"

# Enumerate the target checkpoint row keys (AAD · paged on the continuation marker · PartitionKey+RowKey only).
# az's nextMarker is a COMPOUND OBJECT ({nextpartitionkey, nextrowkey} · live-proven 2026-06-12), NOT a string — a
# bare [string] cast stringifies the hashtable type name and az then dict()-parses that literal ("dictionary update
# sequence" error). And the container is present-but-null-valued on a complete result, so the loop must guard on
# the INNER VALUES. --marker takes the pair as space-separated key=value arguments.
$filter = if ($mode -eq 'ForceNow') { "RowKey eq '$($OperationKey -replace "'","''")'" } else { '' }
$rows = [System.Collections.Generic.List[object]]::new()
$markerPairs = @()
do {
    $qArgs = @('storage','entity','query','--table-name',$TableName,'--account-name',$StorageAccount,'--auth-mode','login',
               '--select','PartitionKey','RowKey','--output','json')
    if ($filter) { $qArgs += @('--filter', $filter) }
    if ($markerPairs.Count -gt 0) { $qArgs += (@('--marker') + $markerPairs) }
    $raw = az @qArgs 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Error "[Force-XdrFullCycle] checkpoint query FAILED (AAD --auth-mode login): $raw"; exit 1 }
    $page = $raw | ConvertFrom-Json -AsHashtable
    foreach ($it in @($page['items'])) { if ($it) { $rows.Add($it) } }
    $markerPairs = @()
    $mk = if ($page.Contains('nextMarker')) { $page['nextMarker'] } else { $null }
    if ($mk -is [System.Collections.IDictionary]) {
        foreach ($k in $mk.Keys) { if ($mk[$k]) { $markerPairs += "$k=$($mk[$k])" } }
    } elseif ($mk -and ($mk -is [string])) { $markerPairs = @([string]$mk) }
} while ($markerPairs.Count -gt 0)

if ($rows.Count -eq 0) {
    if ($mode -eq 'ForceNow') { Write-Error "[Force-XdrFullCycle] no XdrCheckpoint row found for OperationKey='$OperationKey' (an op with no checkpoint is ALWAYS due — nothing to force)"; exit 1 }
    Write-Host "[Force-XdrFullCycle] no checkpoint rows exist — every op is already due (cold estate) · nothing to do"
    exit 0
}

# FORCE-WITHOUT-REWIND merge: blank LastUpdatedUtc ONLY (merge semantics preserve every other column — the
# exactly-once frontier Cursor/BoundaryKeys/Resume* are never written). Blank ⇒ the cadence gate treats the op as
# due (ConvertTo-XdrUtc('') → $null → gate skipped · maximally-overdue cap priority).
#
# WHY Invoke-RestMethod, NOT `az storage entity merge` (live-fixed 2026-06-18): a fan-out CHILD checkpoint RowKey is
# composite 'Op|entity' (a PIPE) and the Table entity-addressing URL has PARENS — both are cmd metacharacters, and
# `az` on Windows is az.cmd (a batch wrapper) that mangles them ("'<entity>' is not recognized" / "--resource was
# unexpected"). Native Invoke-RestMethod takes the URL verbatim (pipe → %7C via EscapeDataString) with NO cmd reparse.
# Still AAD data-plane: the bearer token is the SAME principal `az --auth-mode login` would use (the SP has Storage
# Table Data Contributor). The row LISTING above (az storage entity query) is unaffected — it never passes a composite
# key as an arg; only the per-row merge did.
$tok = az account get-access-token --resource 'https://storage.azure.com/' --query accessToken -o tsv 2>$null
if ([string]::IsNullOrWhiteSpace($tok)) { Write-Error '[Force-XdrFullCycle] failed to acquire an AAD storage-data-plane token (az account get-access-token)'; exit 1 }
$mergeHdr  = @{ Authorization = "Bearer $tok"; 'x-ms-version' = '2019-02-02'; Accept = 'application/json'; 'If-Match' = '*' }
$tableBase = "https://$StorageAccount.table.core.windows.net/$TableName"
$forced = 0
foreach ($r in $rows) {
    $pk = [string]$r['PartitionKey']; $rk = [string]$r['RowKey']
    # OData entity address · EscapeDataString percent-encodes the pipe (%7C) + any URL-unsafe char. Defender op/entity
    # keys are quote-free identifiers (a literal ' would need OData ''-doubling — not present in this domain).
    $entUrl = "$tableBase(PartitionKey='$([uri]::EscapeDataString($pk))',RowKey='$([uri]::EscapeDataString($rk))')"
    try {
        Invoke-RestMethod -Method Patch -Uri $entUrl -Headers $mergeHdr -ContentType 'application/json' -Body '{"LastUpdatedUtc":""}' -TimeoutSec 60 -ErrorAction Stop | Out-Null
    } catch {
        Write-Error "[Force-XdrFullCycle] merge FAILED for $pk/$rk (Table REST): $($_.Exception.Message) :: $($_.ErrorDetails.Message)"; exit 1
    }
    $forced++
    Write-Host "[Force-XdrFullCycle]   due: $pk / $rk"
}

Write-Host "[Force-XdrFullCycle] $forced checkpoint row(s) made cadence-due (LastUpdatedUtc cleared · frontier untouched)"
Write-Host "[Force-XdrFullCycle] Next TimerTrigger (within ~1min) will fire $scope"
Write-Host "[Force-XdrFullCycle] Verify: AppEvents | where Name == 'Entry.CadenceNotDue.Skipped' shows NO forced op; Entry.Poll.* fires for it"
exit 0
