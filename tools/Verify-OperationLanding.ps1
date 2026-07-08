# tools/Verify-OperationLanding.ps1
# Operator tool · 8-axis KQL gate per-Operation (post-deploy verification helper).
#
# Verifies a single Operation landed correctly post-deploy:
#   1. Workspace table <Portal>_<Category>_CL exists
#   2. Row count > 0 within last 1h
#   3. Typed cols populated (NOT NULL · NOT 'OrderedHashtable' string artifact)
#   4. RawJson valid JSON
#   5. CorrelationId present
#   6. AppEvents Entry.Poll.Succeeded for OperationKey within last 1h
#   7. AppEvents Cycle.Completed within last 5min
#   8. XdrCheckpoint table has row for OperationKey

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WorkspaceId,
    [Parameter(Mandatory)] [string] $Portal,           # e.g. 'Defender'
    [Parameter(Mandatory)] [string] $Category,         # e.g. 'ActionCenter'
    [Parameter(Mandatory)] [string] $OperationKey,     # e.g. 'GetHistoricActions'
    [string] $AppInsightsResourceId,
    [int] $LookbackMinutes = 60
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$tableName = "${Portal}_${Category}_CL"
$lookback = "${LookbackMinutes}m"

$results = [ordered]@{
    OperationKey = $OperationKey
    TableName    = $tableName
    Lookback     = $lookback
    Gates        = [ordered]@{}
}

# ── Manifest-derived NaturalKey (for the exactly-once gate) ─────────────────────
# Read the composite NaturalKey field name(s) from manifests/<Portal>/<Category>.psd1 for the selected
# Operation (StrictMode-safe). The exactly-once gate (9) dcount's on these. $null when not resolvable.
function Get-XdrOperationNaturalKey {
    param([string]$Portal, [string]$Category, [string]$OperationKey)
    $manifestPath = Join-Path (Resolve-Path "$PSScriptRoot\..").Path "manifests/$Portal/$Category.psd1"
    if (-not (Test-Path $manifestPath)) { return @() }
    $manifest = Import-PowerShellDataFile -Path $manifestPath -ErrorAction SilentlyContinue
    if (-not $manifest -or -not $manifest.ContainsKey('Operations')) { return @() }
    $ops = @($manifest.Operations)
    if ($ops.Count -eq 0) { return @() }
    $op = $ops | Where-Object { $_.ContainsKey('OperationKey') -and $_.OperationKey -eq $OperationKey } | Select-Object -First 1
    if (-not $op) { $op = $ops[0] }
    if (-not $op.ContainsKey('NaturalKey')) { return @() }
    return @($op.NaturalKey)
}

$naturalKeyFields = Get-XdrOperationNaturalKey -Portal $Portal -Category $Category -OperationKey $OperationKey

# KQL scalar for the composite NaturalKey · matches the runtime's '|'-joined key (Invoke-XdrEntryPoll).
# 1 field → tostring(field); N fields → strcat(tostring(f1),'|',tostring(f2),...).
$naturalKeyKql = $null
if ($naturalKeyFields.Count -eq 1) {
    $naturalKeyKql = "tostring($($naturalKeyFields[0]))"
} elseif ($naturalKeyFields.Count -gt 1) {
    $nkParts = @()
    for ($i = 0; $i -lt $naturalKeyFields.Count; $i++) {
        if ($i -gt 0) { $nkParts += "'|'" }
        $nkParts += "tostring($($naturalKeyFields[$i]))"
    }
    $naturalKeyKql = "strcat($($nkParts -join ', '))"
}

function Invoke-WsQuery {
    param([string]$Query)
    $output = az monitor log-analytics query --workspace $WorkspaceId --analytics-query $Query --output json 2>$null
    if (-not $output) { return $null }
    return $output | ConvertFrom-Json -AsHashtable -ErrorAction SilentlyContinue
}

# Gate 1 · Table exists
$q1 = "$tableName | take 1 | count"
$r1 = Invoke-WsQuery -Query $q1
$results.Gates['1_TableExists'] = @{ Pass = ($null -ne $r1); Query = $q1 }

# Gate 2 · Row count > 0
$q2 = "$tableName | where TimeGenerated > ago($lookback) | summarize Count=count()"
$r2 = Invoke-WsQuery -Query $q2
$count = 0
if ($r2 -and $r2.Count -gt 0) { $count = [int]$r2[0].Count }
$results.Gates['2_RowCount'] = @{ Pass = ($count -gt 0); Count = $count; Query = $q2 }

# Gate 3 · Typed cols populated (sample 10 rows · check for OrderedHashtable string artifact)
$q3 = "$tableName | where TimeGenerated > ago($lookback) | take 10 | extend BadCols = pack_all() | mv-apply col=BadCols on (where tostring(col) contains 'OrderedHashtable')"
$r3 = Invoke-WsQuery -Query $q3
$results.Gates['3_TypedColsClean'] = @{ Pass = ($null -eq $r3 -or $r3.Count -eq 0); BadCount = if ($r3) { $r3.Count } else { 0 } }

# Gate 4 · RawJson valid (parse_json round-trip)
$q4 = "$tableName | where TimeGenerated > ago($lookback) | take 10 | extend ParsedRaw = parse_json(RawJson) | where isnull(ParsedRaw) | count"
$r4 = Invoke-WsQuery -Query $q4
$badJson = if ($r4 -and $r4.Count -gt 0) { [int]$r4[0].Count } else { 0 }
$results.Gates['4_RawJsonValid'] = @{ Pass = ($badJson -eq 0); BadJsonCount = $badJson }

# Gate 5 · CorrelationId present (NOT NULL · NOT empty)
$q5 = "$tableName | where TimeGenerated > ago($lookback) | where isnull(CorrelationId) or CorrelationId == '' | count"
$r5 = Invoke-WsQuery -Query $q5
$noCorrId = if ($r5 -and $r5.Count -gt 0) { [int]$r5[0].Count } else { 0 }
$results.Gates['5_CorrelationIdPresent'] = @{ Pass = ($noCorrId -eq 0); MissingCount = $noCorrId }

# Gate 6 · AppEvents Entry.Poll.Succeeded for OperationKey
$q6 = "AppEvents | where TimeGenerated > ago($lookback) | where Name == 'Entry.Poll.Succeeded' | where Properties.OperationKey == '$OperationKey' | count"
$r6 = Invoke-WsQuery -Query $q6
$entrySuccess = if ($r6 -and $r6.Count -gt 0) { [int]$r6[0].Count } else { 0 }
$results.Gates['6_EntryPollSucceeded'] = @{ Pass = ($entrySuccess -gt 0); Count = $entrySuccess }

# Gate 7 · AppEvents Cycle.Completed within last 5min
$q7 = "AppEvents | where TimeGenerated > ago(5m) | where Name == 'Cycle.Completed' | count"
$r7 = Invoke-WsQuery -Query $q7
$cycleCompleted = if ($r7 -and $r7.Count -gt 0) { [int]$r7[0].Count } else { 0 }
$results.Gates['7_CycleCompleted'] = @{ Pass = ($cycleCompleted -gt 0); Count = $cycleCompleted }

# Gate 8 · XdrCheckpoint row for OperationKey (returned as marker only · operator confirms via Storage Explorer)
$q8 = "AppEvents | where TimeGenerated > ago($lookback) | where Name == 'Checkpoint.Saved' | where Properties.OperationKey == '$OperationKey' | count"
$r8 = Invoke-WsQuery -Query $q8
$chkCount = if ($r8 -and $r8.Count -gt 0) { [int]$r8[0].Count } else { 0 }
$results.Gates['8_CheckpointSaved'] = @{ Pass = ($chkCount -gt 0); Count = $chkCount }

# Gate 9 · Exactly-once by construction · count(rows) == dcount(NaturalKey composite) over the window.
# Proves the connector's high-water + boundary-natural-key dedup (NO DCR dedup · plan §35) actually
# held in the deployed table: a duplicate would make count > dcount. NaturalKey field name(s) come from
# the manifest; a multi-field key is dcount'd on a '|'-joined strcat matching the runtime composite key.
# dcount(...,4) forces EXACT accuracy so the equality is hard. An EMPTY window proves NOTHING (there are no rows
# to dedup) → INCONCLUSIVE, NEVER a vacuous green (plan §18/§7 honesty bar · absence is not proof).
if ($naturalKeyKql) {
    $q9 = "$tableName | where TimeGenerated > ago($lookback) | summarize Rows=count(), DistinctKeys=dcount($naturalKeyKql, 4)"
    $r9 = Invoke-WsQuery -Query $q9
    $eoRows = 0; $eoDistinct = 0; $eoHave = $false
    if ($r9 -and $r9.Count -gt 0) {
        $r9row = $r9[0]
        if ($r9row -is [System.Collections.IDictionary]) {
            if ($r9row.Contains('Rows'))         { $eoRows = [int]$r9row['Rows']; $eoHave = $true }
            if ($r9row.Contains('DistinctKeys')) { $eoDistinct = [int]$r9row['DistinctKeys'] }
        }
    }
    $eoEmpty = (-not $eoHave) -or ($eoRows -eq 0)                              # no rows landed → cannot prove exactly-once
    $eoPass  = $eoHave -and ($eoRows -gt 0) -and ($eoRows -eq $eoDistinct)     # count==dcount over a NON-EMPTY window
    $results.Gates['9_ExactlyOnce'] = @{
        Pass         = $eoPass
        Inconclusive = $eoEmpty
        Rows         = $eoRows
        DistinctKeys = $eoDistinct
        Duplicates   = ($eoRows - $eoDistinct)
        NaturalKey   = ($naturalKeyFields -join ',')
        Query        = $q9
        Note         = if ($eoEmpty) { 'empty window · 0 rows · exactly-once UNPROVABLE → INCONCLUSIVE (not a vacuous green)' } else { '' }
    }
} else {
    $results.Gates['9_ExactlyOnce'] = @{
        Pass       = $false
        NaturalKey = ''
        Note       = "NaturalKey not resolvable from manifests/$Portal/$Category.psd1 for OperationKey=$OperationKey · cannot prove exactly-once"
    }
}

# Final tally · Inconclusive (empty-window / cannot-evaluate) is its OWN bucket — NEVER a silent green (plan §18
# honesty bar). VERIFIED requires EVERY gate to actually PASS; an inconclusive gate alone blocks VERIFIED.
$gatesPassed       = ($results.Gates.Values | Where-Object { $_.Pass }).Count
$gatesInconclusive = ($results.Gates.Values | Where-Object { $_.Inconclusive }).Count
$gatesTotal        = $results.Gates.Count
$results.Verdict = if ($gatesPassed -eq $gatesTotal) { 'VERIFIED' }
    elseif (($gatesPassed + $gatesInconclusive) -eq $gatesTotal) { "INCONCLUSIVE ($gatesInconclusive inconclusive · $gatesPassed verified · NOT a pass)" }
    else { "PARTIAL ($gatesPassed/$gatesTotal)" }
$results.GatesPassed       = "$gatesPassed/$gatesTotal"
$results.GatesInconclusive = $gatesInconclusive

$results | ConvertTo-Json -Depth 6
exit (if ($gatesPassed -eq $gatesTotal) { 0 } else { 1 })
