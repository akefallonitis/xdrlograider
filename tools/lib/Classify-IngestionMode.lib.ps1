# Classify-IngestionMode helpers · dot-sourceable from main script + Pester tests.
# Pure decision function · no I/O · easy to unit-test.
#
# Phase 0 Step 7 contract:
#   - LIVESTREAM  · event-style · time-filter-capable · needs pagination cursors
#                   XdrCheckpoint tracks LastTimeFilterUtc + PaginationCursor + LastCompletedPage
#                   KQL dedup by EntryKey + _OriginalRowId
#   - SNAPSHOT    · full-state · cadence-driven re-ingest · idempotent
#                   XdrCheckpoint tracks LastPolledUtc + LastSuccessUtc only
#                   KQL drift detection at query time via arg_max() / prev()
#   - EXCLUDED    · covered by Microsoft Graph / Defender REST etc. · NEVER in v0.1.0 manifest
#                   Memory Rule 2 should have caught these at Step 5 · sanity-check
#                   Phase 0 Step 7 outputs ONLY for sanity-check entries · 0 expected in production manifest

# ─── Time-filter param signal · path query string ────────────────────────────
$script:TimeFilterParamPatterns = @(
    'since','from','startDate','endDate','startTime','endTime',
    'afterDate','beforeDate','timestamp','lastModified','modifiedAfter','modifiedSince',
    'fromTime','toTime','minDate','maxDate','start','end','before','after'
)

# ─── Memory-Rule-2 forbidden sub-areas (sanity scan only) ─────────────────────
$script:ForbiddenSubAreas = @('AdvancedHunting','AlertsIncidents','LiveResponse')

# ─── LIVESTREAM-suggesting summary keywords ───────────────────────────────────
# Operations whose nodoc summary mentions these are typically event/log streams.
$script:LiveStreamKeywords = @(
    'event','events','alert','alerts','log','logs','audit','telemetry',
    'history','activity','activities','timeline','feed','stream'
)

# ─── SNAPSHOT-suggesting summary keywords ─────────────────────────────────────
$script:SnapshotKeywords = @(
    'configuration','settings','policy','policies','rule','rules',
    'inventory','state','profile','schema','catalog','manifest','metadata',
    'definition','definitions'
)

# ─── LIVESTREAM-suggesting operationId prefixes/suffixes ──────────────────────
$script:LiveStreamOpPatterns = @(
    '\.List$','\.Query$','\.Get.*History$','\.Get.*Events$','\.Get.*Activities$',
    '\.Get.*Logs?$','\.Get.*Timeline$','\.Get.*Feed$','\.Stream$'
)

function Test-PathHasTimeFilter {
    param([string] $Path)
    if (-not $Path) { return $false }
    foreach ($p in $script:TimeFilterParamPatterns) {
        if ($Path -match "[?&]${p}=") { return $true }
    }
    return $false
}

function Test-PathHasPlaceholder {
    # e.g. /api/cases/{caseId} · needs ID substitution before usable in cursor scheme
    param([string] $Path)
    if (-not $Path) { return $false }
    return ($Path -match '\{[A-Za-z][A-Za-z0-9_]*\}')
}

function Test-SummaryMatchesKeywords {
    param([string] $Summary, [string[]] $Keywords)
    if (-not $Summary) { return $false }
    $low = $Summary.ToLowerInvariant()
    foreach ($k in $Keywords) {
        # word-boundary match · avoids "configurations" being a SNAPSHOT hit on "config"
        if ($low -match "\b$([regex]::Escape($k.ToLowerInvariant()))s?\b") { return $true }
    }
    return $false
}

function Test-OperationIdMatchesPattern {
    param([string] $OperationId, [string[]] $Patterns)
    if (-not $OperationId) { return $false }
    foreach ($pat in $Patterns) {
        if ($OperationId -match $pat) { return $true }
    }
    return $false
}

function Resolve-IngestionMode {
    <#
    .SYNOPSIS
        Classify an endpoint entry into LIVESTREAM | SNAPSHOT | EXCLUDED.

    .DESCRIPTION
        Inputs are derived from the candidate manifest entry + (optional) Step 6 live.json
        TimeFilterHints. The decision tree:

          1. If SubArea ∈ {AdvancedHunting, AlertsIncidents, LiveResponse} → EXCLUDED (defensive · Memory Rule 2 should have caught this at Step 5)
          2. If live TimeFilterHints non-empty → LIVESTREAM (observed evidence wins)
          3. If path has time-filter query param → LIVESTREAM
          4. If operationId matches LiveStream op patterns → LIVESTREAM (List · Query · Get*History · Get*Events · Get*Logs · Get*Timeline · Get*Feed · Stream)
          5. If summary keywords match LiveStream set (event/alert/log/activity/...) → LIVESTREAM
          6. Otherwise → SNAPSHOT (safe default · cadence-driven re-ingest)

    .PARAMETER Entry
        Manifest entry hashtable (must have Path, Method, SubArea, NodocRoute, NodocSummary).

    .PARAMETER LiveTimeFilterHints
        Optional array of time-filter param names observed in Step 6 live.json (TimeFilterHints).

    .OUTPUTS
        [pscustomobject] @{ Mode; Reason; Signals }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Entry,
        [string[]] $LiveTimeFilterHints = @()
    )

    $signals = [System.Collections.Generic.List[string]]::new()
    $subArea = if ($Entry.PSObject.Properties['SubArea'] -or ($Entry -is [hashtable] -and $Entry.ContainsKey('SubArea'))) { [string]$Entry.SubArea } else { '' }
    $path    = if ($Entry.PSObject.Properties['Path']    -or ($Entry -is [hashtable] -and $Entry.ContainsKey('Path')))    { [string]$Entry.Path }    else { '' }
    $opId    = if ($Entry.PSObject.Properties['NodocRoute'] -or ($Entry -is [hashtable] -and $Entry.ContainsKey('NodocRoute'))) { [string]$Entry.NodocRoute } else { '' }
    $summary = if ($Entry.PSObject.Properties['NodocSummary'] -or ($Entry -is [hashtable] -and $Entry.ContainsKey('NodocSummary'))) { [string]$Entry.NodocSummary } else { '' }

    # Rule 1 · Memory-Rule-2 defensive · EXCLUDED
    if ($script:ForbiddenSubAreas -contains $subArea) {
        $signals.Add('sub-area-in-memory-rule-2') | Out-Null
        return [pscustomobject]@{ Mode='EXCLUDED'; Reason='Memory Rule 2 wholesale-excluded'; Signals=$signals.ToArray() }
    }

    # Rule 2 · live time-filter hints
    if ($LiveTimeFilterHints -and $LiveTimeFilterHints.Count -gt 0) {
        $signals.Add("live-time-filter-hints=$($LiveTimeFilterHints -join ',')") | Out-Null
        return [pscustomobject]@{ Mode='LIVESTREAM'; Reason='Observed time-filter hint in live.json'; Signals=$signals.ToArray() }
    }

    # Rule 3 · path query string has time-filter param
    if (Test-PathHasTimeFilter -Path $path) {
        $signals.Add('path-time-filter') | Out-Null
        return [pscustomobject]@{ Mode='LIVESTREAM'; Reason='Path query string carries time-filter parameter'; Signals=$signals.ToArray() }
    }

    # Rule 4 · operationId pattern · list/query/history/event/log/timeline/feed/stream
    if (Test-OperationIdMatchesPattern -OperationId $opId -Patterns $script:LiveStreamOpPatterns) {
        $signals.Add("opid-pattern=$opId") | Out-Null
        return [pscustomobject]@{ Mode='LIVESTREAM'; Reason="OperationId '$opId' matches list/query/history pattern"; Signals=$signals.ToArray() }
    }

    # Rule 5 · summary keyword
    if (Test-SummaryMatchesKeywords -Summary $summary -Keywords $script:LiveStreamKeywords) {
        $signals.Add('summary-livestream-keyword') | Out-Null
        return [pscustomobject]@{ Mode='LIVESTREAM'; Reason='Summary mentions event/alert/log/activity/...'; Signals=$signals.ToArray() }
    }

    # Default · SNAPSHOT (cadence-driven full-state · safer than wrong cursor)
    if (Test-SummaryMatchesKeywords -Summary $summary -Keywords $script:SnapshotKeywords) {
        $signals.Add('summary-snapshot-keyword') | Out-Null
    }
    if (Test-PathHasPlaceholder -Path $path) {
        $signals.Add('path-has-placeholder') | Out-Null
    }
    return [pscustomobject]@{ Mode='SNAPSHOT'; Reason='No time-filter evidence · default cadence-driven snapshot'; Signals=$signals.ToArray() }
}
