#Requires -Version 7.4
<#
.SYNOPSIS
PURE gate-decision functions for the §4.B postdeploy audit (B9-B11) + the §4.A offline cataloguing sweep core.
Dot-sourceable with NO Azure / no live state so the Pester SelfTests can RED-prove every decision branch
(the Verify-DeployedConnector.ps1 Test-XdrGate_* pattern, extracted to a shared lib so Run-PostDeployAudit.ps1
AND Invoke-Xdr4ASweep.ps1 AND their SelfTests all consume the SAME canonical logic — no fork to drift).

Each Test-XdrB* fn takes already-fetched KQL row-hashtables (or counts) and returns a decision hashtable:
    @{ Pass=<bool>; Inconclusive=<bool>; Detail=<string>; Verdict=<'PASS'|'INCONCLUSIVE'|'FAIL'> }
The driver bodies do only I/O (build single-quoted KQL → run via Invoke-XdrKqlQuery → grab row → call the pure
fn → record). ARTIFACT-DISCRIMINATION is BAKED INTO THE PURE FN (a reset-in-window → INCONCLUSIVE for the
raw-count branch, fall through to the outcome ratio), so the SelfTests prove the operator's core requirement
(a cold-emit baseline is NOT mistaken for real dup-accumulation) without a live tenant.

B5 QUERY-HONESTY: a null/empty/errored query is INCONCLUSIVE, NEVER a silent 0 — every fn that consumes a
query result treats a not-Success / null-row input as Inconclusive, never Pass.
#>

Set-StrictMode -Version Latest

# ── shared scalar coercions (az --output json renders numeric/bool cols as STRINGS "0"/"True") ──────
# Mirror Verify-DeployedConnector.ps1's ConvertTo-XdrInt/Bool/Get-XdrRowValue so a row read here matches the
# connector exactly. Re-declared (not imported) so this lib is self-contained for the offline SelfTest.
function Get-XdrAuditRowValue {
    param($Row, [string]$Name)
    if ($null -eq $Row) { return $null }
    if ($Row -is [System.Collections.IDictionary]) {
        if ($Row.Contains($Name)) { return $Row[$Name] }
        return $null
    }
    # PSCustomObject fallback (ConvertFrom-Json without -AsHashtable)
    $p = $Row.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function ConvertTo-XdrAuditInt {
    param($Value, [int]$Default = 0)
    if ($null -eq $Value) { return $Default }
    if ($Value -is [int])    { return $Value }
    if ($Value -is [long])   { return [int]$Value }
    if ($Value -is [double]) { return [int]$Value }
    $n = 0
    if ([int]::TryParse(("$Value").Trim(), [ref]$n)) { return $n }
    return $Default
}

function ConvertTo-XdrAuditDouble {
    param($Value, [double]$Default = 0.0)
    if ($null -eq $Value) { return $Default }
    if ($Value -is [double] -or $Value -is [int] -or $Value -is [long]) { return [double]$Value }
    $d = 0.0
    if ([double]::TryParse(("$Value").Trim(), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
    return $Default
}

# Read an integer 'n'-column (or a named column) from the FIRST row of a KQL result, honoring B5 (a failed query
# yields the Default here, but the CALLER passes -QueryOk:$false so the pure fn marks the axis INCONCLUSIVE, never a
# silent 0). Lives in the lib (not the driver) so it is defined the instant the lib is dot-sourced — a script-level
# function must precede its first use, and the driver's B5 known-good probe calls this before the driver body.
function Get-XdrAuditCount {
    param($Result, [string]$Column = 'n', [int]$Default = 0)
    if (-not $Result -or -not $Result.Success) { return $Default }
    $row = @($Result.Data) | Select-Object -First 1
    if (-not $row) { return $Default }
    return (ConvertTo-XdrAuditInt (Get-XdrAuditRowValue $row $Column))
}

# ════════════════════════════════════════════════════════════════════════════════════════════════
# ── B9 · AppTraces error/warning-RATE over a steady-state window ──────────────────────────────────
# ════════════════════════════════════════════════════════════════════════════════════════════════
function Test-XdrB9_ErrorRate {
    <#
    .SYNOPSIS
    PURE · B9 genuine-error RATE per category, normalized per Entry.Poll.Succeeded over a steady-state window.
    .DESCRIPTION
    Inputs (all already-summarized counts from the driver's single-quote KQL):
      -Failed      Entry.Poll.Failed + Entry.Poll.Exception events carrying a HARD ErrorClass (cosmetic classes EXCLUDED by the query)
      -Succeeded   Entry.Poll.Succeeded events
      -UnrecoveredBreakers  count of Breaker.Opened OperationKeys with NO later Breaker.Closed in the window (the hard-class proxy)
      -AppExceptions  count of AppExceptions in the window (genuine .NET exceptions)
      -ResetsInWindow count of Save-XdrCheckpointReset markers (resetAt) inside the window
      -QueryOk     whether the underlying KQL executed (B5: a failed query is INCONCLUSIVE, never 0)
    Threshold: Failed/(Failed+Succeeded) <= 0.02 AND UnrecoveredBreakers == 0 AND AppExceptions == 0.
    ARTIFACT-DISCRIMINATION: a reset in the window inflates Failed/0-row churn → the COUNT-based ratio is
    operator-inflated → INCONCLUSIVE (classify by ErrorClass+recovery, not raw count over a dirty window).
    A zero-Succeeded window with zero errors is INCONCLUSIVE (no steady-state evidence), never a silent green.
    #>
    [CmdletBinding()]
    param(
        [int]    $Failed,
        [int]    $Succeeded,
        [int]    $UnrecoveredBreakers = 0,
        [int]    $AppExceptions = 0,
        [int]    $ResetsInWindow = 0,
        [bool]   $QueryOk = $true,
        [double] $Threshold = 0.02
    )
    if (-not $QueryOk) {
        return @{ Pass = $false; Inconclusive = $true; Verdict = 'INCONCLUSIVE'; Detail = 'B9 KQL did not execute (transient/throttle survived retry) — un-evaluable, NOT 0 (B5 query-honesty)' }
    }
    if ($ResetsInWindow -gt 0) {
        # A reset re-baselines: SNAPSHOT cold-emit + first-cycle churn inflate raw error/0-row counts → the count
        # ratio is operator-inflated. Classify-by-ErrorClass still demands a CLEAN window; mark INCONCLUSIVE so a
        # dirty-window count never blocks (and never silently passes).
        return @{ Pass = $false; Inconclusive = $true; Verdict = 'INCONCLUSIVE'; Detail = "B9 window contains $ResetsInWindow checkpoint reset(s) (resetAt present) → raw error-rate is operator-inflated · re-run over a reset-free steady-state window (artifact-discrimination)" }
    }
    $denom = $Failed + $Succeeded
    if ($denom -eq 0) {
        return @{ Pass = $false; Inconclusive = $true; Verdict = 'INCONCLUSIVE'; Detail = 'B9 no Entry.Poll.Succeeded|Failed in window (FA not polling this cat / window too short) — no steady-state evidence, INCONCLUSIVE' }
    }
    $rate = [double]$Failed / [double]$denom
    $rateStr = $rate.ToString('P2', [System.Globalization.CultureInfo]::InvariantCulture)
    $hardClassOk = ($UnrecoveredBreakers -eq 0) -and ($AppExceptions -eq 0)
    $rateOk = ($rate -le $Threshold)
    $detail = "failed=$Failed succeeded=$Succeeded rate=$rateStr (<= $($Threshold.ToString('P0',[System.Globalization.CultureInfo]::InvariantCulture))) unrecoveredBreakers=$UnrecoveredBreakers appExceptions=$AppExceptions"
    if ($rateOk -and $hardClassOk) {
        return @{ Pass = $true; Inconclusive = $false; Verdict = 'PASS'; Detail = $detail }
    }
    $why = @()
    if (-not $rateOk)      { $why += "error-rate $rateStr exceeds $($Threshold.ToString('P0',[System.Globalization.CultureInfo]::InvariantCulture))" }
    if ($UnrecoveredBreakers -gt 0) { $why += "$UnrecoveredBreakers un-recovered hard class(es) (Breaker.Opened with no Breaker.Closed)" }
    if ($AppExceptions -gt 0)       { $why += "$AppExceptions AppExceptions" }
    return @{ Pass = $false; Inconclusive = $false; Verdict = 'FAIL'; Detail = "$detail · FAIL: $($why -join '; ')" }
}

# ════════════════════════════════════════════════════════════════════════════════════════════════
# ── B10 · steady-state dup-accumulation (the operator's CORE requirement) ─────────────────────────
# ════════════════════════════════════════════════════════════════════════════════════════════════
function Test-XdrB10_DupAccumulation {
    <#
    .SYNOPSIS
    PURE · B10 SNAPSHOT dup-accumulation over a 24h window, with the operator-mandated artifact-discrimination.
    .DESCRIPTION
    ARTIFACT-DISCRIMINATION (CRITICAL): first read the op's checkpoint resetAt; if ANY reset falls in the window
    the raw rows/distinct-RecordId ratio is operator-INFLATED (a forced cold-emit re-emits the full snapshot) →
    INCONCLUSIVE for the RAW-COUNT branch → FALL THROUGH to the OUTCOME RATIO:
        skipFraction = (CadenceNotDue.Skipped + BoundaryDeduped) / (CadenceNotDue.Skipped + BoundaryDeduped + Succeeded)
    A HIGH skipFraction PROVES the signature-skip is firing → the rows present are the cold-emit baseline, NOT
    real accumulation (artifact → PASS with the explicit ratio reason). A LOW skipFraction WITH rising rows
    (ratio > threshold) = REAL dup-accumulation (FAIL). On a CLEAN window (no reset) the RAW ratio applies:
    rows/distinctRecordId <= 1.5 → PASS, else FAIL (genuine accumulation, no reset to explain it).
    Inputs: -Rows / -DistinctRecordId (over the window) · -Succeeded / -Skipped / -BoundaryDeduped (poll outcomes) ·
            -ResetsInWindow · -QueryOk.
    #>
    [CmdletBinding()]
    param(
        [int]    $Rows,
        [int]    $DistinctRecordId,
        [int]    $Succeeded = 0,
        [int]    $Skipped = 0,
        [int]    $BoundaryDeduped = 0,
        [int]    $ResetsInWindow = 0,
        [bool]   $QueryOk = $true,
        [double] $RawRatioThreshold = 1.5,
        [double] $HighSkipFraction = 0.5
    )
    if (-not $QueryOk) {
        return @{ Pass = $false; Inconclusive = $true; Verdict = 'INCONCLUSIVE'; Detail = 'B10 KQL did not execute — un-evaluable, NOT 0 (B5 query-honesty)' }
    }
    $skipDenom = $Skipped + $BoundaryDeduped + $Succeeded
    $skipFraction = if ($skipDenom -gt 0) { [double]($Skipped + $BoundaryDeduped) / [double]$skipDenom } else { 0.0 }
    $skipStr = $skipFraction.ToString('P1', [System.Globalization.CultureInfo]::InvariantCulture)

    if ($ResetsInWindow -gt 0) {
        # RAW ratio is operator-inflated by the reset's full re-emit → fall through to the OUTCOME RATIO.
        if ($skipDenom -eq 0) {
            return @{ Pass = $false; Inconclusive = $true; Verdict = 'INCONCLUSIVE'; Detail = "B10 reset in window AND no poll outcomes (Succeeded/Skipped/BoundaryDeduped all 0) — cannot read the skip fraction, INCONCLUSIVE (re-run over a reset-free window or wait for >=2 cycles)" }
        }
        if ($skipFraction -ge $HighSkipFraction) {
            return @{ Pass = $true; Inconclusive = $false; Verdict = 'PASS'; Detail = "B10 reset in window → raw rows/RecordId is the COLD-EMIT baseline (NOT accumulation); outcome-ratio PROVES the signature-skip fires: skipFraction=$skipStr (>= $($HighSkipFraction.ToString('P0',[System.Globalization.CultureInfo]::InvariantCulture)) · skipped=$Skipped boundaryDeduped=$BoundaryDeduped succeeded=$Succeeded) · artifact, not real dup-accumulation" }
        }
        return @{ Pass = $false; Inconclusive = $false; Verdict = 'FAIL'; Detail = "B10 reset in window BUT skipFraction=$skipStr is LOW (< $($HighSkipFraction.ToString('P0',[System.Globalization.CultureInfo]::InvariantCulture))) with rows=$Rows/distinct=$DistinctRecordId — the signature-skip is NOT firing post-cold-emit → REAL dup-accumulation (skipped=$Skipped boundaryDeduped=$BoundaryDeduped succeeded=$Succeeded)" }
    }

    # CLEAN window (no reset): the RAW rows/distinct-RecordId ratio is the honest accumulation signal.
    if ($DistinctRecordId -eq 0) {
        if ($Rows -eq 0) {
            return @{ Pass = $false; Inconclusive = $true; Verdict = 'INCONCLUSIVE'; Detail = 'B10 0 rows / 0 distinct RecordId in a reset-free window — no SNAPSHOT data to evaluate (legit-empty op or window too short), INCONCLUSIVE' }
        }
        return @{ Pass = $false; Inconclusive = $false; Verdict = 'FAIL'; Detail = "B10 rows=$Rows but distinct RecordId=0 (RecordId not landing / composite-key collapse) — cannot establish exactly-once" }
    }
    $ratio = [double]$Rows / [double]$DistinctRecordId
    $ratioStr = $ratio.ToString('F2', [System.Globalization.CultureInfo]::InvariantCulture)
    if ($ratio -le $RawRatioThreshold) {
        return @{ Pass = $true; Inconclusive = $false; Verdict = 'PASS'; Detail = "B10 clean window · rows=$Rows / distinctRecordId=$DistinctRecordId = ratio $ratioStr (<= $RawRatioThreshold) · no dup-accumulation (skipFraction=$skipStr)" }
    }
    return @{ Pass = $false; Inconclusive = $false; Verdict = 'FAIL'; Detail = "B10 clean window (NO reset) · rows=$Rows / distinctRecordId=$DistinctRecordId = ratio $ratioStr (> $RawRatioThreshold) with skipFraction=$skipStr — REAL dup-accumulation (the snapshot signature-skip is not deduping)" }
}

# ════════════════════════════════════════════════════════════════════════════════════════════════
# ── B11 · fail-open detection (Entry.FailOpen + un-recovered breaker) ─────────────────────────────
# ════════════════════════════════════════════════════════════════════════════════════════════════
function Test-XdrB11_FailOpen {
    <#
    .SYNOPSIS
    PURE · B11 silent fail-open detection over the window.
    .DESCRIPTION
    The operator is promoting the silent Write-Warning fail-open sites (capability-fetch run.ps1, cadence-gate
    Runtime.psm1, breaker-read) to Track-XdrEvent 'Entry.FailOpen' with a GateName property.
    Inputs:
      -EventPresent      whether ANY Entry.FailOpen event exists in the WHOLE telemetry (proves the event is wired)
      -SustainedCount    number of OperationKeys whose Entry.FailOpen recurs across >=2 DISTINCT CorrelationIds in the window (SUSTAINED)
      -TransientCount    number of single/transient Entry.FailOpen (advisory · e.g. one bracketing a reset)
      -UnrecoveredBreakers Breaker.Opened with no matching Breaker.Closed in the window (also a fail-open class)
      -QueryOk           whether the KQL executed.
    Threshold: zero SUSTAINED/recurring fail-open AND zero un-recovered breakers. A single transient is advisory.
    If the Entry.FailOpen event is NOT present yet, report INCONCLUSIVE 'event not yet emitted' (NOT a false pass) —
    BUT an un-recovered breaker (already-wired telemetry) still FAILS regardless.
    #>
    [CmdletBinding()]
    param(
        [bool] $EventPresent = $false,
        [int]  $SustainedCount = 0,
        [int]  $TransientCount = 0,
        [int]  $UnrecoveredBreakers = 0,
        [bool] $QueryOk = $true
    )
    if (-not $QueryOk) {
        return @{ Pass = $false; Inconclusive = $true; Verdict = 'INCONCLUSIVE'; Detail = 'B11 KQL did not execute — un-evaluable, NOT 0 (B5 query-honesty)' }
    }
    # An un-recovered breaker is a hard fail-open regardless of the Entry.FailOpen wiring state (the breaker
    # telemetry is already emitted today), so it BLOCKS even when Entry.FailOpen is not yet present.
    if ($UnrecoveredBreakers -gt 0) {
        return @{ Pass = $false; Inconclusive = $false; Verdict = 'FAIL'; Detail = "B11 $UnrecoveredBreakers Breaker.Opened with no matching Breaker.Closed in window — the breaker stayed OPEN (fail-open / un-recovered)$(if($EventPresent){''}else{' · note: Entry.FailOpen event not yet emitted'})" }
    }
    if (-not $EventPresent) {
        return @{ Pass = $false; Inconclusive = $true; Verdict = 'INCONCLUSIVE'; Detail = 'B11 Entry.FailOpen event not present in telemetry yet (the silent Write-Warning fail-open sites are not yet promoted to Track-XdrEvent ''Entry.FailOpen'' with GateName) — INCONCLUSIVE, NOT a false pass; breaker-recovery checked and clean' }
    }
    if ($SustainedCount -gt 0) {
        return @{ Pass = $false; Inconclusive = $false; Verdict = 'FAIL'; Detail = "B11 $SustainedCount SUSTAINED fail-open (same OperationKey across >=2 distinct CorrelationIds) — a recurring gate fail-open is a real defect (transient=$TransientCount advisory)" }
    }
    $detail = "B11 no sustained fail-open (transient=$TransientCount advisory · single events bracketing a reset are tolerated) · no un-recovered breaker"
    return @{ Pass = $true; Inconclusive = $false; Verdict = 'PASS'; Detail = $detail }
}

# ════════════════════════════════════════════════════════════════════════════════════════════════
# ── §4.A OFFLINE SWEEP CORE (A1-A10) — pure per-op flagging over catalogue ∪ curation ─────────────
# ════════════════════════════════════════════════════════════════════════════════════════════════
# Each flag is a structural cataloguing-audit miss the sweep catches BEFORE prepush so the live re-prove
# CONFIRMS not DISCOVERS. The driver loads catalogue.json (the Shipped op records) + curation.json (overlapVerdict)
# + the manifests (ColumnTypes for the A3 case-sensitive subset check) and calls Get-XdrShippedOpFlags per op.

function Get-XdrCatalogValueList {
    # Normalize a catalogue field that may be a scalar, $null, an array, or a PSCustomObject-wrapped array
    # into a clean string[] (NaturalKey is [], a single string, or an array depending on the serializer).
    param($Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [string]) { return @($Value) }
    if ($Value -is [System.Collections.IEnumerable]) {
        return @($Value | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrEmpty($_) })
    }
    return @([string]$Value)
}

function Get-XdrShippedOpFlags {
    <#
    .SYNOPSIS
    PURE · run the §4.A A1-A10 structural axes over ONE shipped op record (a catalogue Operation object/hashtable)
    and return the list of FLAG strings (empty = clean). The driver aggregates; ANY flag → exit 2.
    .PARAMETER Op
        The catalogue Operation (PSCustomObject from ConvertFrom-Json, or a hashtable). Read tolerantly.
    .PARAMETER OverlapVerdict
        The curation overlapVerdict decision for this op's OperationId ('ship'|'hold'|'' if none). The A9/P11 HARD GATE.
    .PARAMETER ManifestProjectionColumns
        The MANIFEST projection column names (canonical-cased, post Generate-Manifest) for the A3 case-sensitive
        columnTypes-subset check. Empty array when the manifest isn't loaded (A3 then skipped for this op).
    .PARAMETER ManifestColumnTypeKeys
        The manifest ColumnTypes keys for this op (A3: each MUST be a CASE-SENSITIVE member of the projection columns).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Op,
        [string]   $OverlapVerdict = '',
        [string[]] $ManifestProjectionColumns = @(),
        [string[]] $ManifestColumnTypeKeys = @(),
        # An op already PRESENT in a manifest has passed the onboard gate (the ROUND-6 pre-ship LIVE-PATH PROBE is a
        # STANDARD onboard gate · live-verified at 200/cap-absent through the connector), so the A8 "needs a live
        # probe" debt is SATISFIED for it — suppress A8 + the A1/A3-low-value ADVISORY for deployed ops (the operator
        # shipped them knowingly · the §4.B live re-prove is their gate). The HARD structural axes (A3 dead columnType,
        # A4 no-key, A6 fan-out parent, A9/P11 overlap) STILL apply to a deployed op (a correctness defect at any tier).
        [bool]     $IsDeployed = $false
    )
    $flags = @()
    $opId  = [string](Get-XdrAuditRowValue $Op 'OperationId')
    if ([string]::IsNullOrEmpty($opId)) { $opId = [string](Get-XdrAuditRowValue $Op 'Operation') }
    $tag = "[$opId]"

    $ingestionMode   = [string](Get-XdrAuditRowValue $Op 'IngestionMode')
    $entityRes       = [string](Get-XdrAuditRowValue $Op 'EntityResolution')
    $dependsOn       = [string](Get-XdrAuditRowValue $Op 'DependsOn')
    $officialOverlap = [string](Get-XdrAuditRowValue $Op 'OfficialApiOverlap')
    $evidenceTier    = [string](Get-XdrAuditRowValue $Op 'EvidenceTier')
    $effValueClass   = [string](Get-XdrAuditRowValue $Op 'EffectiveValueClass')
    $cursorField     = [string](Get-XdrAuditRowValue $Op 'CursorField')
    # @() at the call site: a single-element @() RETURNED from a function is unwrapped to a scalar string on assign,
    # so .Count would throw under StrictMode — force array context here.
    $naturalKey      = @(Get-XdrCatalogValueList (Get-XdrAuditRowValue $Op 'NaturalKey'))
    $projMapRaw      = Get-XdrAuditRowValue $Op 'ProjectionMap'
    $timeFilterRaw   = Get-XdrAuditRowValue $Op 'TimeFilter'

    # A WINDOW op's exactly-once comes from the From/To window BOUNDARY, not a NaturalKey (A5: a WINDOW op carries
    # the complete contract — Mode != None + From/To params). Detect a COMPLETE window contract so A4 does not
    # over-flag a correctly-bounded keyless WINDOW op (e.g. GetMachineTimelineEvents · ServerFromDate fromDate/toDate).
    $tfMode = ''
    $tfFrom = ''
    $tfTo   = ''
    if ($timeFilterRaw -is [System.Collections.IDictionary]) {
        $tfMode = [string]$timeFilterRaw['Mode']; $tfFrom = [string]$timeFilterRaw['FromDateParam']; $tfTo = [string]$timeFilterRaw['ToDateParam']
    } elseif ($timeFilterRaw -is [pscustomobject]) {
        $tfMode = [string](Get-XdrAuditRowValue $timeFilterRaw 'Mode'); $tfFrom = [string](Get-XdrAuditRowValue $timeFilterRaw 'FromDateParam'); $tfTo = [string](Get-XdrAuditRowValue $timeFilterRaw 'ToDateParam')
    }
    $hasWindowContract = (-not [string]::IsNullOrEmpty($tfMode)) -and ($tfMode -ne 'None') -and (-not [string]::IsNullOrEmpty($tfFrom)) -and (-not [string]::IsNullOrEmpty($tfTo))

    # ── A1/A3 (structural) · ProjectionMap columns ──────────────────────────────────────────────────
    # StrictMode-safe: an EMPTY PSCustomObject ({} in JSON) has a 0-item .PSObject.Properties, and `.Name` on the
    # empty collection THROWS under StrictMode — enumerate the property objects instead (a 0-item enumerate = @()).
    $projCols = @()
    if ($projMapRaw -is [System.Collections.IDictionary]) {
        $projCols = @($projMapRaw.Keys | ForEach-Object { [string]$_ })
    } elseif ($projMapRaw -is [pscustomobject]) {
        $projCols = @(@($projMapRaw.PSObject.Properties) | ForEach-Object { [string]$_.Name })
    }

    # ── A1 · ZERO-PROJ · a data op (CoreTelemetry/ConfigState) MUST project at least one field, else every typed
    #    col is NULL (the EndpointDevices.List camelCase-vs-PascalCase class). A Reference/UiHelper op may be
    #    RawJson-only (no projection) legitimately, so only flag a VALUE op with an empty ProjectionMap. PRE-DEPLOY
    #    debt (a deployed RawJson-only ConfigState op was shipped knowingly · §4.B is its gate) → suppress when deployed.
    $isDataClass = $effValueClass -in @('CoreTelemetry', 'ConfigState')
    if ((-not $IsDeployed) -and $isDataClass -and $projCols.Count -eq 0) {
        $flags += "$tag A1 ZERO-PROJ · EffectiveValueClass=$effValueClass (data-grade) but ProjectionMap is EMPTY → every typed col would be NULL (re-derive the projection from the LIVE body · projectionAlias)"
    }

    # ── A4 · NO-KEY on a non-SNAPSHOT mode · a WINDOW/CURSOR op with NO NaturalKey AND no CursorField + rows =
    #    dup-accumulation. SNAPSHOT is keyless-by-design (content-hash skip). CURSOR is exactly-once via the
    #    content-hash boundary so a keyless CURSOR is VALID iff it has a CursorField; a CURSOR/WINDOW with NEITHER
    #    a key NOR a cursor is the real defect.
    if ($ingestionMode -eq 'CURSOR') {
        # A keyless CURSOR is VALID iff it has a CursorField (exactly-once via the content-hash boundary on the
        # bucketed cursor · the GetInsights class); a CURSOR with NEITHER a key NOR a CursorField dup-accumulates.
        if ($naturalKey.Count -eq 0 -and [string]::IsNullOrEmpty($cursorField)) {
            $flags += "$tag A4 NO-KEY · IngestionMode=CURSOR with NO NaturalKey AND no CursorField → rows would dup-accumulate (a CURSOR needs a CursorField)"
        }
    } elseif ($ingestionMode -eq 'WINDOW') {
        # A WINDOW op is exactly-once via the From/To window BOUNDARY (A5), so a keyless WINDOW with a COMPLETE
        # window contract is VALID; only a WINDOW lacking BOTH a key AND the From/To contract dup-accumulates.
        if ($naturalKey.Count -eq 0 -and -not $hasWindowContract) {
            $flags += "$tag A4 NO-KEY · IngestionMode=WINDOW with NO NaturalKey AND no complete From/To window contract (Mode='$tfMode' From='$tfFrom' To='$tfTo') → rows would dup-accumulate (a WINDOW needs the complete ServerFromDate/From-To contract OR a key)"
        }
    }

    # ── A3 · EffectiveValueClass low (Noise/UiHelper/Reference) on a SHIPPED op = a likely mis-ship (chrome /
    #    pick-list / bare-string). Flag for the MANDATORY body-read (advisory-grade structural flag · the manual
    #    body-read is the real adjudicator, but the sweep must SURFACE it so it is never silently shipped).
    if ((-not $IsDeployed) -and $effValueClass -in @('Noise', 'UiHelper', 'Reference', 'StaticCatalog')) {
        $flags += "$tag A3 LOW-VALUE-CLASS · EffectiveValueClass=$effValueClass on a SHIPPED op → body-READ to confirm genuine telemetry vs chrome/pick-list/bare-string (curation valueClass / shipHold)"
    }

    # ── A6 · fan-out (entity-DAG) · a Resolved (fan-out) op MUST bind a DependsOn parent (the id-cache seed),
    #    else the {param} never resolves → 0 children. The parent-PROJECTS-the-id check is the prepush
    #    EntityDependsOn guard's job (it needs the full catalogue); here we flag the MISSING binding.
    if ($entityRes -eq 'Resolved' -and [string]::IsNullOrEmpty($dependsOn)) {
        $flags += "$tag A6 FANOUT-NO-PARENT · EntityResolution=Resolved but DependsOn is empty → the {param} id-cache never seeds = 0 children (bind entityIdSource/entityParent to a SHIPPED parent that projects the id field)"
    }

    # ── A9 + P11 HARD GATE · OfficialApiOverlap in {Likely,Exact} on a SHIPPED op REQUIRES an overlapVerdict
    #    (a sweep that skips this DISCOVERS it at prepush — the 2026-06-23 Configuration lesson). decision=hold
    #    must NOT be shipped.
    if ($officialOverlap -in @('Likely', 'Exact')) {
        if ([string]::IsNullOrEmpty($OverlapVerdict)) {
            $flags += "$tag A9/P11 OVERLAP-NO-VERDICT · OfficialApiOverlap=$officialOverlap but NO overlapVerdict in curation.json → the manual value-vs-official-API adjudication is missing (P11 HARD GATE · add {decision:ship|hold,source,why})"
        } elseif ($OverlapVerdict -eq 'hold') {
            $flags += "$tag A9/P11 OVERLAP-HOLD-SHIPPED · OfficialApiOverlap=$officialOverlap with overlapVerdict=hold but the op is SHIPPED (contradiction · also add a shipHold so it does not ship)"
        }
    }

    # ── A8 · capability vs stale-path · a postman/openapi-EvidenceTier op needs a LIVE-PATH PROBE before commit
    #    (404=de-ship stale · 403=cap-absent ship-gated · 200=ship). A live-captured/live-evidence op is already
    #    probed. Flag a non-live EvidenceTier as needing the pre-ship probe (the ROUND-6 lesson).
    if ((-not $IsDeployed) -and $evidenceTier -in @('postman-example', 'openapi-derived', 'conservative', 'structural')) {
        $flags += "$tag A8 NEEDS-LIVE-PROBE · EvidenceTier=$evidenceTier (never live-captured) → run the pre-ship LIVE-PATH PROBE (Probe-PostDiscovery-Local): 404=de-ship(stale) · 403=cap-absent(ship-gated) · 200=ship+derive"
    }

    # ── A3 · columnTypes CASE-SENSITIVE projection subset (the cat-6 2-prepush-round lesson) · a manifest
    #    ColumnTypes key that is NOT a CASE-SENSITIVE member of the manifest projection columns is a DEAD
    #    declaration that BLOCKS Validate-Manifests (PowerShell -contains is case-INSENSITIVE so a self-check
    #    misses it). Only evaluated when the manifest projection columns are supplied (driver loaded the manifest).
    # @() at use: a [string[]] param can still arrive as a scalar/$null under StrictMode (single-element unwrap on
    # the caller's hashtable read), so re-wrap before .Count.
    $projColsM = @($ManifestProjectionColumns)
    # Filter out null/empty keys defensively: an empty '' key is never a real projection member, and a phantom ''
    # (from a [string[]] @($null) binding) must never produce a flag — the sweep asserts REAL columnType keys only.
    $ctKeysM   = @(@($ManifestColumnTypeKeys) | Where-Object { -not [string]::IsNullOrEmpty($_) })
    if ($projColsM.Count -gt 0 -and $ctKeysM.Count -gt 0) {
        foreach ($ctKey in $ctKeysM) {
            # CASE-SENSITIVE containment (-ceq): PowerShell -contains is case-INSENSITIVE so a self-check misses a
            # casing drift; LA + Validate-Manifests are case-SENSITIVE, so the dead-declaration check must be too.
            $hit = $false
            foreach ($pc in $projColsM) { if ($pc -ceq $ctKey) { $hit = $true; break } }
            if (-not $hit) {
                $flags += "$tag A3 COLUMNTYPE-NOT-PROJECTED · ColumnTypes key '$ctKey' is NOT a CASE-SENSITIVE member of the manifest projection ($($projColsM.Count) cols) → a DEAD type declaration that BLOCKS Validate-Manifests (re-key columnTypes to the canonical projection casing)"
            }
        }
    }

    return $flags
}

# Aggregator: run the sweep over a list of shipped op records + the curation/manifest lookups, return
# @{ Flags=<string[]>; OpsSwept=<int>; ShippedCount=<int> }. PURE (the driver does the file I/O + exit).
function Invoke-XdrShipSetSweep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [array] $ShippedOps,            # catalogue Operation records with Shipped=true
        [hashtable] $OverlapVerdicts = @{},                     # OperationId -> 'ship'|'hold'
        [hashtable] $ManifestProjectionByOpId = @{},            # OperationId -> string[] canonical projection columns
        [hashtable] $ManifestColumnTypeKeysByOpId = @{},        # OperationId -> string[] ColumnTypes keys
        [hashtable] $DeployedOpIds = @{}                        # OperationId -> $true for ops already in a manifest (passed the onboard gate)
    )
    $allFlags = @()
    foreach ($op in $ShippedOps) {
        $opId = [string](Get-XdrAuditRowValue $op 'OperationId')
        if ([string]::IsNullOrEmpty($opId)) { $opId = [string](Get-XdrAuditRowValue $op 'Operation') }
        $verdict = if ($OverlapVerdicts.ContainsKey($opId)) { [string]$OverlapVerdicts[$opId] } else { '' }
        # Build the array lookups with the @() OPERATOR and a default-then-assign — NEVER `if(..){@(..)}else{@()}`:
        # an `else { @() }` if-EXPRESSION collapses the empty array to $null (the PS if/else @()→$null trap), which
        # binds at the [string[]] param as @($null) → a phantom '' columnType key → a FALSE A3 flag (caught live).
        $projCols = @(); if ($ManifestProjectionByOpId.ContainsKey($opId))    { $projCols = @($ManifestProjectionByOpId[$opId]) }
        $ctKeys   = @(); if ($ManifestColumnTypeKeysByOpId.ContainsKey($opId)) { $ctKeys   = @($ManifestColumnTypeKeysByOpId[$opId]) }
        $isDeployed = $DeployedOpIds.ContainsKey($opId)
        $allFlags += Get-XdrShippedOpFlags -Op $op -OverlapVerdict $verdict -ManifestProjectionColumns $projCols -ManifestColumnTypeKeys $ctKeys -IsDeployed $isDeployed
    }
    return @{ Flags = @($allFlags); OpsSwept = $ShippedOps.Count; ShippedCount = $ShippedOps.Count }
}
