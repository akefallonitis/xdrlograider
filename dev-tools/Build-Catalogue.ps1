#Requires -Version 7.4
<#
.SYNOPSIS
v13 · portal-GENERIC 6-stage cataloguing engine (plan §6.1). Fresh-derives the catalogue from RAW for ONE
portal+group, ALL groups of a portal, or ALL 20 portals. NO inherited prior-catalogue assumptions.

.DESCRIPTION
Stages: Extract -> Classify -> Dedupe -> Depend -> Decide -> Map, re-derived from RAW each run
(openapi x-tagGroups + inventory operations + live fixtures + live-evidence). Heterogeneity handled (verified):
  - OperationId is NULL for single-file portals → Operation key derived from Method + Path.
  - inventory is per-category (`*.operations.json`) OR single (`openapi.operations.json`).
  - Postman/table-token derived from PortalShort (portals.json).
HONEST gating (NEVER fabricate): stages 1-4 (structural) run for EVERY op; pagination/timefilter derive from the
OpenAPI spec where present; the BEHAVIORAL fields (IngestionMode/Cadence/CursorField/NaturalKey/ProjectionMap)
emit FULL values ONLY where live evidence exists — else null/empty (RawJson is the runtime fallback). Per-op
Status: Validated (live) | OpenApiDerived (spec) | StructuralOnly | Excluded. Locked exclusions: Advanced
Hunting · Alerts · Incidents · Live Response (official/write). Reuses canonical Get-XdrSafeColumnName.
#>
[CmdletBinding()]
param(
    [string] $Portal = 'Defender',     # friendly name ('Defender') · nodoc key · or 'All'
    [string] $Group,                   # one x-tagGroups group · omit for ALL groups of the portal
    [switch] $AllPortals,              # catalogue every nodoc-* portal
    [string] $RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path,
    [switch] $WriteFile
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# UTF-8 stdout (no BOM): the catalogue JSON carries non-ASCII (e.g. the `·` middot in descriptions); when this tool's
# stdout is captured by the gauntlet regen→diff axis via `| Out-String`, the OEM codepage (git's sh hook) would mangle
# it to `?` and spuriously fail the diff. Self-correcting regardless of caller (gauntlet · bash · sh · CI).
$OutputEncoding = [System.Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

Import-Module powershell-yaml -ErrorAction Stop
Import-Module (Join-Path $RepoRoot 'src/Modules/Xdr.Common.Parser/Xdr.Common.Parser.psd1') -Force -DisableNameChecking -ErrorAction Stop
# Shared single-record-vs-wrapper SHAPE ORACLE · the SAME file is dot-sourced by Build-EvidenceIndex.ps1 so the two
# generators classify response bodies identically (no twin-drift). Provides Get-XdrBodyShape (live-body classifier)
# and Get-XdrSchemaArrayPropertyKey (the OpenAPI-schema-side list-property picker used by Get-XdrResponseItemSchema).
. (Join-Path $PSScriptRoot 'lib/Get-XdrBodyShape.ps1')
# Shared SHAPE-ONLY DISCOVERY reader · reconstructs a representative real-valued body from a portal-internal shape-only
# capture (references/live/<portalKey>/discovery/<OperationId>.json) so the discovery shape feeds the SAME shape oracle
# + projection logic as a real capture (no separate code path · no twin-drift). Also dot-sourced by Infer-ColumnTypes
# so the born-correct columnTypes it infers match what the catalogue projects. Returns $null when no shape fixture exists.
. (Join-Path $PSScriptRoot 'lib/Get-XdrDiscoveryShape.ps1')

# ── MANUAL-VERIFIED VALUE OVERRIDES (V6 · operator-directed · plan §21) ──────────────────────────────────────────
# The SHIP gate (at the Decide stage below) is a DYNAMIC value filter — an op ships only if it is telemetry-grade
# (EffectiveValueClass CoreTelemetry/ConfigState) AND includable AND pollable. This table is the "filter VERIFIED
# MANUAL at cataloguing time" layer: human corrections to the auto ValueClass heuristic where it mis-judges an op's
# TELEMETRY value. Keyed by OperationId. The gate logic stays portal-agnostic (generic); only the value call is
# hand-verified here. Expansion: add a row when a category is curated. (Externalizable to a per-portal overrides file.)
# == CURATION (operator-verified, plan Phi2): LOADED from per-portal SoT DATA, not an in-code per-op table =========
# The former in-code XdrValueOverrides/XdrShipHold/XdrPathOverrides hashtables (the banned per-op patch) now live as
# reviewable, community-contributable curation DATA at references/inventory/<portalKey>/curation.json with explicit
# provenance (source + reason). This loader reads that file into the SAME-shaped script tables the Decide/Path stages
# consume (consumers UNCHANGED). The keyword/evidence heuristic stays the PRIMARY derivation; curation carries ONLY
# operator-verified corrections where the heuristic is wrong. NO hardcoded entries here -> the override-empty gauntlet
# axis asserts exactly that (all per-op curation is external data).
function Import-XdrCuration {
    param([Parameter(Mandatory)][string] $CurationPath)
    $val = @{}; $hold = @{}; $path = @{}; $subprod = @{}; $qsup = @{}
    # Cadence tiers (D25 · content-value cadence as curation DATA · decoupled from IngestionMode). The five
    # operator-locked tier values are the built-in defaults (portal-generic — apply even when the curation file
    # carries no cadence section); curation can override/extend tierDefaults and assign tiers per Subcategory /
    # per OperationId. Derivation precedence + the final assignment live in the Stage-5.5 pass (single point).
    $cadDefaults = @{ events = '00:10:00'; frequent = '01:00:00'; config = '06:00:00'; inventory = '1.00:00:00'; maintenance = '7.00:00:00' }
    $cadSub = @{}; $cadOp = @{}
    if (Test-Path $CurationPath) {
        $cur = Get-Content $CurationPath -Raw | ConvertFrom-Json -AsHashtable -Depth 20
        if ($cur.Contains('valueClass'))    { foreach ($k in $cur['valueClass'].Keys)    { $val[$k]  = [string]$cur['valueClass'][$k]['class'] } }
        if ($cur.Contains('shipHold'))      { foreach ($k in $cur['shipHold'].Keys)      { $hold[$k] = [string]$cur['shipHold'][$k]['reason'] } }
        # querySupplied · OperationId -> [required QUERY params the runtime/curation CAN supply] (operator-verified at
        # onboarding · e.g. a fixed indicator/user value). Removes them from the pollability-HOLD set. _doc key skipped.
        if ($cur.Contains('querySupplied')) { foreach ($k in $cur['querySupplied'].Keys)  { if ($k -eq '_doc') { continue }; $qsup[$k] = @($cur['querySupplied'][$k]['params']) } }
        if ($cur.Contains('pathReconcile')) { foreach ($k in $cur['pathReconcile'].Keys) { $path[$k] = @{ SubPortal = [string]$cur['pathReconcile'][$k]['SubPortal']; Path = [string]$cur['pathReconcile'][$k]['Path'] } } }
        # SubPortal -> RequiresProducts (license-independence · DATA-driven, not hardcoded). _doc key skipped.
        if ($cur.Contains('subPortalProducts')) { foreach ($k in $cur['subPortalProducts'].Keys) { if ($k -eq '_doc') { continue }; $subprod[$k] = @($cur['subPortalProducts'][$k]) } }
        # NOTE (operator 2026-06-11): categorization is the nodoc x-tagGroups, ALWAYS. There is NO category-override
        # lever — "Action Center" is a TAG (Subcategory) under the "Operations" GROUP, so the pilot ops live in
        # Defender_Operations_CL, not a fabricated Defender_ActionCenter_CL. We never invent a category outside nodoc.
        if ($cur.Contains('cadence')) {
            $cz = $cur['cadence']
            if (($cz -is [System.Collections.IDictionary]) -and $cz.Contains('tierDefaults'))     { foreach ($k in $cz['tierDefaults'].Keys)     { if ($k -ne '_doc') { $cadDefaults[$k] = [string]$cz['tierDefaults'][$k] } } }
            if (($cz -is [System.Collections.IDictionary]) -and $cz.Contains('subcategoryTiers')) { foreach ($k in $cz['subcategoryTiers'].Keys) { if ($k -ne '_doc') { $cadSub[$k] = [string]$cz['subcategoryTiers'][$k] } } }
            if (($cz -is [System.Collections.IDictionary]) -and $cz.Contains('operationTiers'))   { foreach ($k in $cz['operationTiers'].Keys)   { if ($k -ne '_doc') { $cadOp[$k] = [string]$cz['operationTiers'][$k] } } }
        }
    }
    # T3e · timeFilter curation seam (the ONE behavioral-curation channel for the time/cursor contract). Carries
    # operator-verified per-op TimeFilter fields the heuristic cannot derive (the OData filter FIELD, the wire
    # ValueFormat, the relative param) + the Entry-root knobs LookbackHours/CursorPrecision. Keys are ALLOW-LISTED
    # (the FieldEmittability gate cross-checks this list against the runtime read-surface); an unknown key warns and
    # is SKIPPED — regen never fails on a curation typo (the CadenceTiers precedent). CursorField/NaturalKey are
    # deliberately NOT allowed: the exactly-once fields need LIVE proof, never curation.
    $tfo = @{}
    if ((Test-Path $CurationPath) -and $cur -and $cur.Contains('timeFilter')) {
        foreach ($opK in $cur['timeFilter'].Keys) {
            if ($opK -eq '_doc') { continue }
            $row = $cur['timeFilter'][$opK]
            if ($row -isnot [System.Collections.IDictionary]) { continue }
            $clean = @{}
            foreach ($fk in $row.Keys) {
                if ($fk -in @('source','why','_doc')) { continue }   # provenance keys · not contract fields
                if ($fk -in $script:XdrCurationTimeFilterKeys) { $clean[$fk] = $row[$fk] }
                else { Write-Warning "[Import-XdrCuration] timeFilter.$opK carries unknown key '$fk' (not in the allow-list) · skipped" }
            }
            if ($clean.Count -gt 0) { $tfo[$opK] = $clean }
        }
    }
    # T4-PROJ · projectionAlias seam · an empty-capture op inherits a live-proven schema-sibling's ProjectionMap
    # (curation DATA · documented · real live evidence from the sibling · NOT fabrication). { from; source; why }.
    $palias = @{}
    if ((Test-Path $CurationPath) -and $cur -and $cur.Contains('projectionAlias')) {
        foreach ($opK in $cur['projectionAlias'].Keys) {
            if ($opK -eq '_doc') { continue }
            $row = $cur['projectionAlias'][$opK]
            if (($row -is [System.Collections.IDictionary]) -and $row.Contains('from') -and $row['from']) { $palias[$opK] = [string]$row['from'] }
        }
    }
    # entityParent · OperationId -> { ParentOperationKey; ParentOperationId; EntityIdField; ParamName } · an EXPLICIT
    # fan-out parent override applied AFTER the name/path heuristic (Set-XdrDependsOnEdges). The sanctioned correction
    # (mirrors overlapVerdict for the ship-gate) for when the heuristic binds the WRONG parent or cannot resolve one —
    # e.g. the machine id is exposed as 'id' on GetMachinesWdatp (stem '', not name-matchable to {MachineId}) at a
    # different path prefix, while the only NAME-match is a stale/broken-projection sibling (EndpointDevices.List).
    # Curation DATA, not fabrication: the operator verified the parent op LISTS the entity + exposes the id field live.
    $eparent = @{}
    if ((Test-Path $CurationPath) -and $cur -and $cur.Contains('entityParent')) {
        foreach ($opK in $cur['entityParent'].Keys) {
            if ($opK -eq '_doc') { continue }
            $row = $cur['entityParent'][$opK]
            if (($row -is [System.Collections.IDictionary]) -and $row.Contains('ParentOperationId') -and $row.Contains('EntityIdField') -and $row.Contains('ParamName')) {
                $eparent[$opK] = @{ ParentOperationKey = [string]$row['ParentOperationKey']; ParentOperationId = [string]$row['ParentOperationId']; EntityIdField = [string]$row['EntityIdField']; ParamName = [string]$row['ParamName'] }
            }
        }
    }
    # entityIdSource · id-STEM -> { ParentOperationKey; ParentOperationId; EntityIdField } · the ENTITY-DAG mapping
    # (entity-LEVEL fan-out parent · applied BEFORE the name/path heuristic in Set-XdrDependsOnEdges). ONE entry per
    # entity (e.g. 'machine' -> GetMachinesWdatp.id) binds EVERY {MachineId}/{DeviceId} fan-out op in the category to
    # the canonical id source — the reusable generalization of per-op entityParent (so N near-identical overrides
    # collapse to one). Keyed by the lowercased id-stem (Get-XdrEntityIdStem: 'MachineId'->'machine', 'DeviceId'->
    # 'machine' via the device≡machine alias). The name/path heuristic binds by FIELD NAME and mis-binds a stale-
    # projection sibling that merely exposes 'machineId'; the entity-id-source is the operator-verified live truth.
    $eidsrc = @{}
    if ((Test-Path $CurationPath) -and $cur -and $cur.Contains('entityIdSource')) {
        foreach ($stemK in $cur['entityIdSource'].Keys) {
            if ($stemK -eq '_doc') { continue }
            $row = $cur['entityIdSource'][$stemK]
            if (($row -is [System.Collections.IDictionary]) -and $row.Contains('ParentOperationId') -and $row.Contains('EntityIdField')) {
                $eidsrc[$stemK.ToLower()] = @{ ParentOperationKey = [string]$row['ParentOperationKey']; ParentOperationId = [string]$row['ParentOperationId']; EntityIdField = [string]$row['EntityIdField'] }
            }
        }
    }
    # itemsContainer · OperationId -> <wrapper array key> · the operator-verified live LIST-ENVELOPE key for an op the
    # shape oracle could NOT resolve (an OpenApiDerived op whose OpenAPI schema omits the envelope, or an all-empty live
    # wrapper {Items:[],...} where two empty arrays make the single-array test ambiguous). Sets ItemsContainer +
    # ResponseShape='wrapper' so the runtime UNWRAPS $.<key> (one row per element · 0 rows when empty) instead of emitting
    # the whole wrapper as ONE row (the dup-accumulation bug · ROUND-7c GetMachineTimelineEvents live-caught 18 identical
    # empty-wrapper rows). Live-grounded curation DATA, not fabrication. Keyed by canonical OperationId.
    $icont = @{}
    if ((Test-Path $CurationPath) -and $cur -and $cur.Contains('itemsContainer')) {
        foreach ($opK in $cur['itemsContainer'].Keys) {
            if ($opK -eq '_doc') { continue }
            $row = $cur['itemsContainer'][$opK]
            $key = if ($row -is [System.Collections.IDictionary]) { [string]$row['key'] } else { [string]$row }
            if ($key) { $icont[$opK] = $key }
        }
    }
    # responseShape · OperationId -> 'singleObject' · the INVERSE of itemsContainer: forces ResponseShape='singleObject' +
    # clears ItemsContainer (post-DEPEND) and re-derives the ProjectionMap from the FULL top-level body, so a config-posture
    # body the oracle mis-classified as a wrapper (a sole array beside a metadata-NAMED scalar like IsAllDevicesEnabled, in
    # the oracle's pagination-metadata allow-list) keeps its top-level posture scalar(s) instead of unwrapping the array and
    # dropping them (0 rows when the array is empty · the A2 dropped-wrapper-scalar class). ONLY 'singleObject' is honoured
    # (the safe RawJson-floor shape that never drops a field); any other value warns + is skipped. Live-grounded curation DATA.
    $rshape = @{}
    if ((Test-Path $CurationPath) -and $cur -and $cur.Contains('responseShape')) {
        foreach ($opK in $cur['responseShape'].Keys) {
            if ($opK -eq '_doc') { continue }
            $row = $cur['responseShape'][$opK]
            $sh = if ($row -is [System.Collections.IDictionary]) { [string]$row['shape'] } else { [string]$row }
            if ($sh -in @('singleObject','bareArray')) { $rshape[$opK] = $sh }
            elseif ($sh) { Write-Warning "[Import-XdrCuration] responseShape.$opK = '$sh' is not 'singleObject'/'bareArray' (the only honoured values) · skipped" }
        }
    }
    return @{ ValueClass = $val; ShipHold = $hold; PathReconcile = $path; SubPortalProducts = $subprod
              Cadence = @{ TierDefaults = $cadDefaults; SubcategoryTiers = $cadSub; OperationTiers = $cadOp }
              TimeFilterOverrides = $tfo; ProjectionAlias = $palias; QuerySupplied = $qsup; EntityParent = $eparent; EntityIdSource = $eidsrc; ItemsContainer = $icont; ResponseShape = $rshape }
}
# T3e · the curation timeFilter ALLOW-LIST · TimeFilter-block fields + the Entry-root knobs. The FieldEmittability
# gate asserts every runtime-read curation-class field is HERE (and the live-evidence fields are NOT).
$script:XdrCurationTimeFilterKeys = @('Mode','FieldName','FromDateParam','ToDateParam','ParamLocation','Operator','OuterFormat','ValueFormat','FilterParam','RelativeParam','LookbackHours','CursorPrecision')
# Defender is the only portal with verified corrections today; other portals' ops never match these OperationId keys,
# F1.5 · per-portal curation (de-hardwired): load the curation for the portal BEING catalogued (its own SoT DATA;
# missing file → empty curation + portal-generic cadence defaults). Invoked per-portal inside the foreach ($key in
# $targetKeys) loop below, so Defender is BYTE-IDENTICAL (loads nodoc-defender-xdr/curation.json, exactly as before)
# and a non-Defender portal loads ITS OWN curation, never Defender's. (Resolves the prior "future generalization" note.)
function Set-XdrCurationForPortal([string]$portalKey) {
    $script:XdrCuration          = Import-XdrCuration -CurationPath (Join-Path $RepoRoot "references/inventory/$portalKey/curation.json")
    $script:XdrValueOverrides    = $script:XdrCuration.ValueClass         # OperationId -> 'CoreTelemetry'|'ConfigState'
    $script:XdrShipHold          = $script:XdrCuration.ShipHold           # OperationId -> reason (semantic dedup / supersede)
    $script:XdrQuerySupplied     = $script:XdrCuration.QuerySupplied      # OperationId -> [query params the runtime/curation CAN supply] (onboarding-verified)
    $script:XdrSubPortalProducts = $script:XdrCuration.SubPortalProducts  # SubPortal -> RequiresProducts (license-independence · DATA)
    $script:XdrPathOverrides     = $script:XdrCuration.PathReconcile      # OperationId -> @{ SubPortal; Path } (live > spec)
    $script:XdrCadence           = $script:XdrCuration.Cadence            # D25 tiers (Stage 5.5)
}

# ── HONESTY LOCK §4.D · LIVE-PROVEN registry ──────────────────────────────────────────────────────────────────
# Status=Validated is RESERVED for ops proven live in production (exactly-once re-verified · rows==dcount(NaturalKey)
# under real cadence · §9.3 postdeploy DoD). The OFFLINE derivation NEVER emits Validated from a captured fixture
# alone — a fixture proves SCHEMA, not the live exactly-once chain — that is LiveCaptured. The X-phase promote adds
# the OperationId here AFTER live proof; regen then emits Validated for it (regen-stable promotion · mirrors the
# XdrValueOverrides manual-verify layer). EMPTY until Operations is live-proven (honest: nothing Validated pre-live).
$script:XdrLiveProven = @()

# ── Portal registry · built fresh from portals.json (PortalKey ↔ PortalShort) · no hardcoded Defender map ──
$portalsJson = Get-Content (Join-Path $RepoRoot 'references/inventory/portals.json') -Raw | ConvertFrom-Json -AsHashtable
# Postman collection filename resolver · the file is USUALLY '<PortalShort>.collection.json', but 2 portals diverge:
# nodoc-defender-xdr → defender.collection.json (short=defender-xdr) · nodoc-ibiza-iam → entra-iam.collection.json
# (short=ibiza-iam). Try the short, then per-portal aliases, returning the FIRST that actually exists under
# references/postman/. Falls back to the '<short>.collection.json' relative path when none exist (tier-3 then stays
# a safe empty map — never throws), so behaviour is unchanged for the 18 already-matching portals.
function Resolve-PostmanRel([string]$portalKey, [string]$short) {
    $dir = Join-Path $RepoRoot 'references/postman'
    $aliases = switch ($portalKey) {
        'nodoc-defender-xdr' { @('defender-xdr','defender') }
        'nodoc-ibiza-iam'    { @('ibiza-iam','entra-iam') }
        default              { @($short) }
    }
    # De-dup while preserving order; always include the short first as the primary candidate.
    $cands = @(); foreach ($a in (@($short) + @($aliases))) { if ($a -and ($a -notin $cands)) { $cands += $a } }
    foreach ($c in $cands) {
        $rel = "references/postman/$c.collection.json"
        if (Test-Path (Join-Path $dir "$c.collection.json")) { return $rel }
    }
    return "references/postman/$short.collection.json"   # nothing on disk → safe fallback (empty tier-3, no throw)
}
$registry = @{}
foreach ($p in @($portalsJson['portals'])) {
    $key = [string]$p['PortalKey']; $short = [string]$p['PortalShort']
    # Friendly: the 5 polled portals keep their runtime names; the rest use a PascalCased PortalShort (informational).
    $friendly = switch ($key) {
        'nodoc-defender-xdr'    { 'Defender' }
        'nodoc-purview'         { 'Purview' }
        'nodoc-security-copilot'{ 'SecurityCopilot' }
        default { (($short -split '[-_]' | Where-Object { $_ } | ForEach-Object { $_.Substring(0,1).ToUpper() + $_.Substring(1) }) -join '') }
    }
    $registry[$key] = @{
        Key = $key; Short = $short; Friendly = $friendly
        TableToken = (($short -split '[-_]' | Where-Object { $_ } | ForEach-Object { $_.Substring(0,1).ToUpper() + $_.Substring(1) }) -join '')
        RequiresProducts = $(if ($key -eq 'nodoc-defender-xdr') { @('MDE') } else { @() })
        PostmanRel = (Resolve-PostmanRel $key $short)
    }
}
# Resolve which portal keys to process.
$friendlyToKey = @{}; foreach ($k in $registry.Keys) { $friendlyToKey[$registry[$k].Friendly.ToLower()] = $k }
$targetKeys = if ($AllPortals -or $Portal -eq 'All') {
    @($registry.Keys | Sort-Object)
} elseif ($registry.ContainsKey($Portal)) { @($Portal) }
elseif ($friendlyToKey.ContainsKey($Portal.ToLower())) { @($friendlyToKey[$Portal.ToLower()]) }
else { throw "Unknown portal '$Portal' (use a friendly name, a nodoc-* key, or 'All')" }
$targetKeys = @($targetKeys)   # force array · a single-element if-expression result unwraps to a scalar (no .Count under StrictMode)

# ── Helpers (portal-agnostic) ──
function Get-ReadSemantics([string]$method, [string]$opId, [string]$summary) {
    $m = $method.ToUpper()
    # Write-verb set · the side-effecting POST leaks (invoke/prefetch/log/upload/dismiss/acknowledge/mark/trigger)
    # were missing → InvokeAction/InvokeAdminCommand/PrefetchMachineTimeline/LogTranslationError/UploadLibraryFile
    # mis-classified as ReadViaPost. These are genuine writes (Write → WriteSide → Excluded). Word-boundaried so
    # 'catalog'/'syslog' (log), 'MarkedEvents' (mark) etc. do NOT false-match.
    $writeVerb = ("$opId $summary") -imatch '\b(create|update|delete|remove|merge|issue|approve|reject|remediate|set|add|cancel|submit|enable|disable|assign|unassign|patch|edit|rename|move|invoke|prefetch|log|upload|dismiss|acknowledge|mark|trigger)\b'
    if ($m -eq 'GET') { return 'Read' }
    if ($m -in @('PUT','DELETE','PATCH')) { return 'Write' }
    # POST · a write verb WINS over a read verb (so 'run' — and any read token — never forces a read when a write
    # verb is present). Checked before the read branch to make the precedence explicit.
    if ($writeVerb) { return 'Write' }
    $readVerb = ("$opId $summary") -imatch '\b(get|list|query|count|search|export|fetch|read|run)\b'
    if ($readVerb) { return 'ReadViaPost' }
    return 'ReadViaPost'
}
# Locked official/write exclusions (operator-agreed) — Defender-tag-named; portal-scoped so they don't over-match elsewhere.
$script:OfficialDuplicateTags = @('Advanced Hunting','Alerts','Incidents','Live Response')
function Get-TelemetryClass([string]$tag, [string]$readSem, [string]$portalKey) {
    if ($readSem -eq 'Write') { return 'WriteSide' }
    if (($portalKey -eq 'nodoc-defender-xdr') -and ($tag -in $script:OfficialDuplicateTags)) { return 'OfficialDuplicate' }
    return 'InternalOnly'
}
function Split-SubPortal([string]$fullPath) {
    $p = $fullPath.TrimStart('/'); $seg = $p.Split('/')[0]
    $rest = '/' + $p.Substring($seg.Length).TrimStart('/')
    return @{ SubPortal = $seg; Path = $rest }
}
function ConvertTo-TableToken([string]$s) { Get-XdrCategoryToken -Category $s }   # delegates to THE single tokenizer (Xdr.Common.Parser · WS2.2)
# Operation key · OperationId last-segment when present; else derived from Method + last non-param path segment.
function Get-OperationKey($opId, [string]$method, [string]$fullPath) {
    if ($opId) { return ([string]$opId -split '\.')[-1] }
    $segs = @($fullPath.TrimStart('/').Split('/') | Where-Object { $_ -and ($_ -notmatch '^\{') })
    $tail = if ($segs.Count -gt 0) { $segs[-1] } else { 'root' }
    $verb = switch ($method.ToUpper()) { 'GET' {'Get'} 'POST' {'Post'} 'PUT' {'Put'} 'DELETE' {'Delete'} 'PATCH' {'Patch'} default { $method } }
    $clean = (($tail -replace '[^A-Za-z0-9]', ' ') -split ' ' | Where-Object { $_ } | ForEach-Object { $_.Substring(0,1).ToUpper() + $_.Substring(1) }) -join ''
    if (-not $clean) { $clean = 'Root' }
    return "$verb$clean"
}

# ════════════════════════════════════════════════════════════════════════════════════════════════════════════════
# ── SELECT stage helpers (plan A3) · portal-GENERIC · DETERMINISTIC · ANNOTATION-ONLY ────────────────────────────
# These derive per-op RANKING signals the onboarding loop later uses to PICK the next category one-at-a-time. They
# NEVER remove an op from the catalogue — the only ops that leave (Status=Excluded) are the existing HARD exclusions
# (write verbs + official-duplicate). Selection is a dynamic onboarding decision, NOT a static catalogue filter.
# ════════════════════════════════════════════════════════════════════════════════════════════════════════════════

# MDE/Graph public-surface path markers · an internal path that mirrors one of these LIKELY duplicates a documented
# Microsoft API → lowers onboarding priority (but never auto-excludes · operator-locked).
$script:PublicSurfaceMarkers = @('wdatpApi/', '/machines', '/vulnerabilities', '/recommendations', '/software', '/indicators', '/remediation')
# OfficialApiOverlap ∈ {None, Likely, Exact}. Exact ⇒ the op is a Defender official-duplicate (folds in the EXISTING
# $script:OfficialDuplicateTags via the already-computed TelemetryClass=OfficialDuplicate · Exact is already Excluded
# by the hard exclusion). Likely ⇒ the full path matches the MDE/Graph public surface. Else None.
function Get-OfficialApiOverlap([string]$telClass, [string]$fullPath) {
    if ($telClass -eq 'OfficialDuplicate') { return 'Exact' }
    foreach ($mk in $script:PublicSurfaceMarkers) { if ($fullPath -ilike "*$mk*") { return 'Likely' } }
    return 'None'
}

# ValueClass ∈ {CoreTelemetry, ConfigState, Reference, UiHelper, Noise} · deterministic name/path heuristic, evaluated
# in PRECEDENCE order (UiHelper → ConfigState(GET) → Reference → CoreTelemetry → Noise). Drives the SelectionScore
# value weight. Operates on the Operation key + Summary + Path so it is portal-generic.
function Get-ValueClass([string]$opKey, [string]$summary, [string]$method, [string]$fullPath) {
    # CamelCase-split the op key into words so the \b-anchored CoreTelemetry clause below matches GLUED names too
    # (GetChokePoints -> "...Choke Points" · GetTopEntryPoints -> "...Entry Points"); without this the \b clause
    # only ever matched the SUMMARY text, so sparse-summary security telemetry fell through to Noise. The earlier
    # clauses (UiHelper/ConfigState/Reference) have no leading \b so they already substring-match regardless.
    $hay = "$opKey " + ([regex]::Replace($opKey, '([a-z0-9])([A-Z])', '$1 $2')) + " $summary"
    # UiHelper · grid/filter/autocomplete/picker scaffolding (lowest ingestion value).
    if ($hay -imatch '(Filters|Summary|Tile|Count|Totals?|Metadata|Options|FilterValues|Available|Supported)\b' -or
        $hay -imatch '\b(Autocomplete|Suggest|GetRecent)' -or $hay -imatch '(Suggest\w*|Picker)\b') { return 'UiHelper' }
    # ConfigState · settings/policy/exclusion/rule reads (GET OR read-POST · the WRITE forms are ScopeDecision=Exclude so
    # the Shipped-gate drops them regardless; restricting to GET wrongly demoted read-POST config reads to Noise, e.g.
    # GetAdvancedFeatures POST /settings/GetAdvancedFeaturesSetting — 2026-06-21 P5-2 Endpoint).
    if ($hay -imatch '(Settings|PreviewFeatures|Configuration|Policy|Policies|Exclusion|Rule|Rules)\b') { return 'ConfigState' }
    # Reference · TRUE slow-moving STATIC catalogues only (vendor/model/version/schema lookups). NB: machine/device TAGS
    # and device-type DISTRIBUTION are TENANT CONFIG-STATE (device management posture, not a static lookup) — they were
    # wrongly demoted here and dropped; removed so they classify as CoreTelemetry via the machine/device vocab + the
    # live-evidence promotion (operator 2026-06-21 P5-2: "tags/health/status ARE config-state management across a tenant").
    if ($hay -imatch '(AllVendors|AllModels|Versions|Schema|Header)\b') { return 'Reference' }
    # CoreTelemetry · the security-event/posture substance. The vocabulary spans Defender's security-telemetry domain so
    # the heuristic is GENERIC across portals/categories — not just the audit/event family but posture/exposure/vuln,
    # the attack-surface graph (attack path · chokepoint · entry point · target), security/risk/exposure SCORES,
    # recommendations, CVEs, device/asset inventory, and the threat/alert/incident/finding/remediation family.
    # SAFE BY PRECEDENCE: UiHelper (filters/summary/count/options) · ConfigState (settings/policy) · Reference
    # (schema/tags/versions/vendors) are matched ABOVE, so this clause can only promote what would otherwise be Noise —
    # it can never mis-demote a filter/schema/setting. Validated by the regen→diff gate (no cross-category over-ship).
    if ($hay -imatch '\b(history|audit|event|events|timeline|activity|investigation|detection|indicator|session|change|posture|exposure|vuln\w*|attack\w*|choke\w*|entry\w*|securescore|score|risk|recommendation\w*|cve\w*|threat\w*|alert\w*|incident\w*|finding\w*|remediation|device\w*|machine\w*|endpoint\w*|software\w*|onboard\w*|asset\w*|target\w*)\b') { return 'CoreTelemetry' }
    return 'Noise'
}

# ════════════════════════════════════════════════════════════════════════════════════════════════════════════════
# ── CADENCE-vs-VOLUME validator (plan U5 · §16.2 · NEVER refuse · ADVISE / auto-correct only) ────────────────────
# Derivation-time check that an op's IngestionMode × Cadence is appropriate for the captured VOLUME (evidence-index
# RowCount · captured-page size). It NEVER excludes/refuses an op — it emits an advisory verdict and, for the unsafe
# high-volume-SNAPSHOT-at-fast-cadence case, an AUTO-CORRECTED cadence the caller may apply (honest: slowing the
# cadence needs NO new evidence, unlike fabricating a CursorField). RawJson floor + the op's catalogue presence are
# untouched. Deterministic · pure (no I/O). Returns @{ Fit; Reason; SuggestedMode; SuggestedCadence; RowCount } or
# $null when there is no captured RowCount to judge (no false advice on unmeasured ops).
#   Fit ∈ { Appropriate, AdviseCursor, AdviseSlowerCadence, Unevaluated }
#     Appropriate        · mode/cadence already fits the volume (incl. any CURSOR op — high-volume's correct mode).
#     AdviseCursor       · SNAPSHOT + fast cadence + high volume AND a plausible cursor field exists → prefer CURSOR.
#     AdviseSlowerCadence· SNAPSHOT + fast cadence + high volume with NO cursor candidate → keep SNAPSHOT but slow it.
#     Unevaluated        · op has a RowCount but no behavioral IngestionMode yet (LiveCaptured · honest gating) →
#                          carry the RowCount + an onboarding HINT; emit NO correction (no fabricated behavior).
$script:CadenceVolumeHighRowThreshold = 200   # captured-page rows at/above this ⇒ "high volume" (≈ a full page → paginates)
$script:CadenceVolumeFastCadence      = [TimeSpan]::FromMinutes(15)   # cadence at/below this ⇒ "fast" (SNAPSHOT churn risk)
$script:CadenceVolumeSlowSnapshot     = '01:00:00'                    # the slowed SNAPSHOT cadence the auto-correct suggests
function Get-CadenceVolumeAdvice {
    param(
        [AllowNull()] $IngestionMode,         # 'CURSOR' | 'SNAPSHOT' | 'WINDOW' | $null (LiveCaptured/unproven)
        [AllowNull()] $Cadence,               # 'hh:mm:ss' | $null
        [AllowNull()] $RowCount,              # captured-page record count | $null (no capture → no judgement)
        [AllowNull()] $CursorFieldCandidate   # a plausible cursor column name (LiveCaptured candidate) | $null
    )
    if ($null -eq $RowCount) { return $null }                       # nothing measured → no advice (honest)
    $rc = [int]$RowCount
    $highVolume = $rc -ge $script:CadenceVolumeHighRowThreshold

    # No behavioral mode yet (LiveCaptured) → cannot judge a mode/cadence fit; surface the volume + an onboarding hint.
    if ([string]::IsNullOrWhiteSpace([string]$IngestionMode)) {
        $hint = if ($highVolume) { 'High captured volume — onboard as CURSOR (or slow SNAPSHOT) when behavioral mode is set.' }
                else            { 'Bounded captured volume — SNAPSHOT is viable when onboarded.' }
        return [ordered]@{ Fit = 'Unevaluated'; Reason = $hint; SuggestedMode = $null; SuggestedCadence = $null; RowCount = $rc }
    }

    $mode = [string]$IngestionMode
    $fast = $false
    if (-not [string]::IsNullOrWhiteSpace([string]$Cadence)) {
        # InvariantCulture · parity with the runtime + validators so a culture-sensitive Cadence classifies identically everywhere (FH-9 #3).
        try { $fast = ([TimeSpan]::Parse([string]$Cadence, [System.Globalization.CultureInfo]::InvariantCulture)) -le $script:CadenceVolumeFastCadence } catch { $fast = $false }
    }

    # Only SNAPSHOT at a FAST cadence with HIGH volume is a mis-fit (mass re-emit churn). Everything else fits:
    #   CURSOR (any volume) · SNAPSHOT bounded · SNAPSHOT slow · WINDOW → Appropriate.
    if (($mode -eq 'SNAPSHOT') -and $fast -and $highVolume) {
        if (-not [string]::IsNullOrWhiteSpace([string]$CursorFieldCandidate)) {
            return [ordered]@{ Fit = 'AdviseCursor'
                Reason = "SNAPSHOT at fast cadence ($Cadence) with high captured volume ($rc rows) — a cursor field ('$CursorFieldCandidate') is available; CURSOR avoids full re-emit."
                SuggestedMode = 'CURSOR'; SuggestedCadence = $null; RowCount = $rc }
        }
        return [ordered]@{ Fit = 'AdviseSlowerCadence'
            Reason = "SNAPSHOT at fast cadence ($Cadence) with high captured volume ($rc rows) and no cursor candidate — slow the cadence to reduce full-re-emit churn."
            SuggestedMode = $null; SuggestedCadence = $script:CadenceVolumeSlowSnapshot; RowCount = $rc }
    }
    return [ordered]@{ Fit = 'Appropriate'; Reason = "Mode=$mode cadence=$Cadence fits captured volume ($rc rows)."; SuggestedMode = $null; SuggestedCadence = $null; RowCount = $rc }
}

# ════════════════════════════════════════════════════════════════════════════════════════════════════════════════
# ── DEPEND stage (plan §16 U3b · §4.H entity edges · G‑P) · portal‑GENERIC · DETERMINISTIC · ADDITIVE ─────────────
# Derives, for each ENTITY op (a non‑{TenantId} path {param} · ParamSource='ParentOp'), a DependsOn edge to a PARENT
# list/get‑all op IN THE SAME Category whose response ITEM carries the id field the child's {param} needs. The runtime
# (Invoke‑XdrEntityFanout) consumes this to fan a {param}→id substitution out across the parent's recently‑seen ids.
#   DependsOn = @{ ParentOperationKey; ParentOperationId; EntityIdField; ParamName; MatchKind }
#   EntityResolution ∈ { Resolved, Unresolved }   (Unresolved ⇒ catalogued + RawJson‑capable · runtime SKIPS fan‑out
#                                                   with a warning · NEVER crashes · NEVER refuses the cycle)
# This is a BEST‑EFFORT heuristic (the live per‑op parent→child is validated at onboarding · plan SCOPE); correctness
# here = the edge is deterministic, the resolver never throws, and a missing parent degrades to Unresolved (not a
# fabricated edge). The TARGET param is the LAST non‑TenantId {param} (the deepest entity that scopes the leaf set);
# {TenantId} is auto‑filled by R3 and is NOT an entity param (excluded from candidacy here · plan §4.H).
$script:EntityIdParamMarkers = @('id')   # a child {param} ending in 'id' (case‑insensitive) is an entity reference.

# Normalize an id token to a comparison key: lowercase + drop a trailing 'id' so {MachineId}↔machineId↔id↔Machine all
# compare. e.g. 'MachineId'→'machine', 'CaseId'→'case', 'Id'/'id'→'' (the bare‑id generic), 'Sha256'→'sha256'.
function Get-XdrEntityIdStem([string]$token) {
    if ([string]::IsNullOrWhiteSpace($token)) { return '' }
    $t = $token.ToLower()
    if ($t.Length -gt 2 -and $t.EndsWith('id')) { $t = $t.Substring(0, $t.Length - 2) }
    # MDE domain alias: a 'device' IS a 'machine' (the portal API spells the one entity both ways — a {DeviceId} path
    # param binds the SAME machineId the machine-list parents expose). Canonicalize device->machine so the {DeviceId}
    # entity-fanout (GetTags/GetRbacGroups/GetRbacGroupScopes/GetTimeline) resolves against the machineId-bearing parent
    # (EndpointDevices.Get), exactly as {MachineId} already does. EXACT stem only — 'aadDeviceId'->'aaddevice' (the AAD
    # device id, a DIFFERENT identifier) is untouched. Generic across all categories. 2026-06-21 P5-2 manual audit.
    if ($t -eq 'device') { $t = 'machine' }
    return $t
}
# The COLLECTION BASE of a child entity path = the path up to AND EXCLUDING the segment that contains the target
# {param}. e.g. '/CaseManagement/be/cases/{CaseId}'→'/casemanagement/be/cases' · '/incidents/{IncidentId}/riskfactors'
# →'/incidents'. A PARENT list op living at that exact base is the REST‑canonical source of the child's id (item.id).
# Lowercased + trailing‑slash‑trimmed for comparison. Empty when the path starts with the {param} (no base).
function Get-XdrCollectionBase([string]$fullPath, [string]$paramName) {
    if ([string]::IsNullOrWhiteSpace($fullPath)) { return '' }
    $segs = @($fullPath.TrimStart('/').Split('/'))
    $needle = '{' + $paramName + '}'
    $idx = -1
    for ($i = 0; $i -lt $segs.Count; $i++) { if ($segs[$i] -ieq $needle) { $idx = $i; break } }
    if ($idx -le 0) { return '' }                                   # param is first segment (or absent) → no collection base
    return ('/' + (($segs[0..($idx - 1)]) -join '/')).ToLower().TrimEnd('/')
}
# Match a child {param} against a PARENT record's response fields (its ProjectionMap keys = the item's top‑level fields)
# AND the parent/child PATH relationship. Returns @{ Field; Kind } for the BEST match, else $null. Kind rank (high→low):
# ExactName > StemName > PathChildId. Deterministic: fields walked SORTED so the chosen field is reproducible.
#   ExactName   · a parent field equals the param verbatim, case‑insensitive — '{IncidentId}'↔'incidentId' (precise).
#   StemName    · the param's id‑stem matches an id‑shaped field's stem — '{RuleId}'↔'ruleId' (precise).
#   PathChildId · the parent op LISTS the child's collection base ('/rules' for '/rules/{RuleId}') AND exposes a generic
#                 'id' field — the REST convention guarantees item.id == the child's {param}. This is a PATH‑GROUNDED
#                 fallback (NOT a blanket "any id field in the category"): a parent at an unrelated path is rejected,
#                 so e.g. '{CaseId}' with no '/…/cases' list parent stays UNRESOLVED rather than binding a stray 'id'.
function Find-XdrParentIdField {
    param(
        [Parameter(Mandatory)][string]$ParamName,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ParentFields,
        [string]$ChildCollectionBase = '',
        [string]$ParentFullPath = ''
    )
    if (@($ParentFields).Count -eq 0) { return $null }
    $sorted = @($ParentFields | Sort-Object)
    $pl = $ParamName.ToLower()
    $pstem = Get-XdrEntityIdStem $ParamName
    # 1 · ExactName (case‑insensitive verbatim).
    foreach ($f in $sorted) { if ($f.ToLower() -eq $pl) { return @{ Field = $f; Kind = 'ExactName' } } }
    # 2 · StemName · a field whose id‑stem equals the param's id‑stem AND is itself id‑shaped (ends 'id' OR == the
    #     stem). Skip the empty stem (the bare '{Id}' param) — ExactName already catches its 'id' field above.
    if ($pstem -ne '') {
        foreach ($f in $sorted) {
            $fstem = Get-XdrEntityIdStem $f
            $fl = $f.ToLower()
            if ($fstem -eq $pstem -and ($fl.EndsWith('id') -or $fl -eq $pstem)) { return @{ Field = $f; Kind = 'StemName' } }
        }
    }
    # 3 · PathChildId · ONLY when the parent path IS the child's collection base (REST list→item) and a generic 'id'
    #     field exists. Path‑grounded → never binds a semantically‑unrelated parent that merely happens to expose 'id'.
    if (-not [string]::IsNullOrWhiteSpace($ChildCollectionBase) -and -not [string]::IsNullOrWhiteSpace($ParentFullPath)) {
        if ($ParentFullPath.ToLower().TrimEnd('/') -eq $ChildCollectionBase) {
            foreach ($f in $sorted) { if ($f.ToLower() -eq 'id') { return @{ Field = $f; Kind = 'PathChildId' } } }
        }
    }
    return $null
}

# Derive DependsOn edges across a fully‑mapped record set ($out · each rec carries ProjectionMap + Category/Subcat +
# ParamSource + PathParams + IsCanonical + ReadSemantics). MUTATES each entity rec IN PLACE: sets DependsOn (or leaves
# null) + EntityResolution. Pure aside from that mutation · deterministic (sorted candidate walk) · NEVER throws.
# Parent candidacy: a NON‑entity (ParamSource≠'ParentOp'), CANONICAL, READ (Read|ReadViaPost) op in the SAME Category
# with ≥1 ProjectionMap field. Preference order among matches: same‑Subcategory before cross‑Subcategory, then better
# MatchKind (ExactName>StemName>BareId), then OperationId (stable tiebreak). GetHistory + every non‑entity op: untouched.
function Set-XdrDependsOnEdges {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Records)
    # Index parent CANDIDATES by Category → list of @{ rec; fields; fullPath }. Built once · order‑independent.
    $parentsByCat = @{}
    foreach ($rec in $Records) {
        if ($rec.ParamSource -eq 'ParentOp') { continue }                       # entity ops are never parents (need their own id)
        if (-not $rec.IsCanonical) { continue }                                  # ingest the canonical only
        if ($rec.ReadSemantics -notin @('Read','ReadViaPost')) { continue }      # a write op is not a list source
        if ($rec.Contains('RequiredQueryParams')) { continue }                   # ROUND-7 (2026-06-22): a parent that itself needs an unsuppliable query id (e.g. EndpointDevices.Get needs machineId) is NOT independently pollable → it cannot seed the fan-out id-cache. Excluding it makes the {MachineId}/{DeviceId} fan-out bind a REAL list parent (EndpointDevices.List · machineId), so the fan-out actually gets ids at runtime instead of 0.
        $fields = @(); if ($rec.ProjectionMap) { $fields = @($rec.ProjectionMap.Keys) }
        if (@($fields).Count -eq 0) { continue }                                 # no known response fields → cannot resolve an id
        $cat = [string]$rec.Category
        $pFull = ('/' + [string]$rec.SubPortal + [string]$rec.Path)              # reconstruct the parent's full path (SubPortal + Path)
        if (-not $parentsByCat.ContainsKey($cat)) { $parentsByCat[$cat] = New-Object System.Collections.Generic.List[object] }
        $parentsByCat[$cat].Add(@{ rec = $rec; fields = $fields; fullPath = $pFull })
    }
    foreach ($rec in $Records) {
        if ($rec.ParamSource -ne 'ParentOp') { continue }                        # only entity ops get an edge
        # TARGET param = the LAST non‑TenantId path param (deepest entity scoping the leaf collection).
        $entityParams = @($rec.PathParams | Where-Object { $_ -ne 'TenantId' })
        if (@($entityParams).Count -eq 0) { $rec['EntityResolution'] = 'Unresolved'; continue }   # defensive (ParamSource implies ≥1)
        $paramName = [string]$entityParams[-1]
        $childFull = ('/' + [string]$rec.SubPortal + [string]$rec.Path)
        $childBase = Get-XdrCollectionBase $childFull $paramName                  # REST collection base for the PathChildId signal
        # ENTITY-DAG · curation entityIdSource (applied BEFORE the name/path heuristic): if the param's id-stem maps to
        # an explicit id-source op, bind there deterministically. ONE 'machine'->GetMachinesWdatp.id mapping resolves
        # every {MachineId}/{DeviceId} fan-out op to the canonical machine inventory (28 live ids) — instead of the
        # name-heuristic mis-binding the stale-projection EndpointDevices.List (whose live 'machineId' is null →
        # cache never seeds → 0 children · ROUND-7c audit). MatchKind='CurationOverride' (reuses the shipped-parent guard).
        $eidSrc = if ($script:XdrCuration -and $script:XdrCuration.Contains('EntityIdSource')) { $script:XdrCuration['EntityIdSource'] } else { @{} }
        $pStem  = Get-XdrEntityIdStem $paramName
        if ($eidSrc -and $pStem -and $eidSrc.ContainsKey($pStem)) {
            $src = $eidSrc[$pStem]
            $rec['DependsOn'] = [ordered]@{
                ParentOperationKey = [string]$src.ParentOperationKey
                ParentOperationId  = [string]$src.ParentOperationId
                EntityIdField      = [string]$src.EntityIdField
                ParamName          = $paramName
                MatchKind          = 'CurationOverride'
            }
            $rec['EntityResolution'] = 'Resolved'
            continue
        }
        $cands = if ($parentsByCat.ContainsKey([string]$rec.Category)) { $parentsByCat[[string]$rec.Category] } else { @() }
        $best = $null   # @{ rec; field; kind; sameSub }
        $kindRank = @{ ExactName = 3; StemName = 2; PathChildId = 1 }
        foreach ($c in $cands) {
            if ([object]::ReferenceEquals($c.rec, $rec)) { continue }            # never self‑depend
            $m = Find-XdrParentIdField -ParamName $paramName -ParentFields $c.fields -ChildCollectionBase $childBase -ParentFullPath $c.fullPath
            if ($null -eq $m) { continue }
            $sameSub = [int]([string]$c.rec.Subcategory -eq [string]$rec.Subcategory)
            $better = $false
            if ($null -eq $best) { $better = $true }
            elseif ($sameSub -gt $best.sameSub) { $better = $true }
            elseif ($sameSub -eq $best.sameSub -and $kindRank[$m.Kind] -gt $kindRank[$best.kind]) { $better = $true }
            elseif ($sameSub -eq $best.sameSub -and $kindRank[$m.Kind] -eq $kindRank[$best.kind] -and ([string]$c.rec.OperationId -lt [string]$best.rec.OperationId)) { $better = $true }
            if ($better) { $best = @{ rec = $c.rec; field = $m.Field; kind = $m.Kind; sameSub = $sameSub } }
        }
        if ($null -ne $best) {
            $rec['DependsOn'] = [ordered]@{
                ParentOperationKey = [string]$best.rec.Operation
                ParentOperationId  = [string]$best.rec.OperationId
                EntityIdField      = [string]$best.field
                ParamName          = $paramName
                MatchKind          = [string]$best.kind
            }
            $rec['EntityResolution'] = 'Resolved'
        } else {
            # No parent in this Category carries the id → catalogued + RawJson‑capable; runtime SKIPS fan‑out (warn).
            $rec['EntityResolution'] = 'Unresolved'
        }
    }
    # Curation entityParent OVERRIDE · applied AFTER the heuristic (the sanctioned correction for a mis-bound/unresolved
    # fan-out parent · operator-verified live). Keyed by OperationId; sets a DETERMINISTIC DependsOn to the EXPLICIT
    # parent op (MatchKind='CurationOverride'). The runtime treats it identically to a heuristic edge. Generic across
    # categories. Prepush (EntityDependsOn.Tests) asserts the named parent EXISTS, is canonical+shipped, and the
    # EntityIdField is real — so an override can never bind a phantom parent.
    $ep = if ($script:XdrCuration -and $script:XdrCuration.Contains('EntityParent')) { $script:XdrCuration['EntityParent'] } else { @{} }
    if ($ep -and $ep.Count -gt 0) {
        foreach ($rec in $Records) {
            $ovr = $ep[[string]$rec.OperationId]
            if (-not $ovr) { continue }
            $rec['DependsOn'] = [ordered]@{
                ParentOperationKey = [string]$ovr.ParentOperationKey
                ParentOperationId  = [string]$ovr.ParentOperationId
                EntityIdField      = [string]$ovr.EntityIdField
                ParamName          = [string]$ovr.ParamName
                MatchKind          = 'CurationOverride'
            }
            $rec['EntityResolution'] = 'Resolved'
        }
    }
}

# Normalized path key for PathVariant sibling detection · lowercase · {param}/* segments dropped · the variant-suffix
# segments (count/filters/summary/metadata/export) stripped from the TAIL → the shared base path. Deterministic.
function Get-NormalizedPathKey([string]$fullPath) {
    $n = ($fullPath -replace '\{[^}]+\}', '*').ToLower().Trim('/')
    $segs = @($n -split '/' | Where-Object { $_ -ne '' -and $_ -ne '*' })
    # Strip trailing variant-suffix segments (repeatedly — e.g. .../files/count/metadata → .../files).
    $suffixes = @('count', 'filters', 'summary', 'metadata', 'export')
    while (($segs.Count -gt 1) -and ($segs[-1] -in $suffixes)) { $segs = @($segs[0..($segs.Count - 2)]) }
    return ($segs -join '/')
}
# Normalized TAIL (last ≤2 non-param segments + method) for MtoMirror detection · a /mtoapi/ op that shares this tail
# with a non-mtoapi op is a multi-tenant mirror of it. Deterministic.
function Get-NormalizedTailKey([string]$fullPath, [string]$method) {
    $n = ($fullPath -replace '\{[^}]+\}', '*').ToLower().Trim('/')
    $segs = @($n -split '/' | Where-Object { $_ -ne '' })
    $tail = if ($segs.Count -ge 2) { ($segs[-2..-1] -join '/') } elseif ($segs.Count -eq 1) { $segs[-1] } else { '' }
    return "$tail|$($method.ToUpper())"
}

# ── OpenAPI/Postman schema waterfall (Map stage tiers 2-3) · portal-agnostic · StrictMode-safe ──
# A small loaded-spec cache keyed by absolute file path → ConvertFrom-Yaml dictionary (cross-file $ref resolution).
$script:SpecFileCache = @{}
function Get-XdrSpecFile([string]$absPath) {
    if (-not (Test-Path $absPath)) { return $null }
    if ($script:SpecFileCache.ContainsKey($absPath)) { return $script:SpecFileCache[$absPath] }
    $doc = $null
    try { $doc = ConvertFrom-Yaml (Get-Content $absPath -Raw) } catch { $doc = $null }
    $script:SpecFileCache[$absPath] = $doc
    return $doc
}
# Resolve a $ref string to its target schema node. Supports local (#/components/schemas/X → $localSpec)
# and cross-file (common.yml#/components/schemas/X → $specDir/common.yml). Returns @{ node=<dict>; spec=<dict> }
# where 'spec' is the document the node lives in (so nested refs resolve against the right components root). $null on miss.
function Resolve-XdrRef([string]$ref, $localSpec, [string]$specDir) {
    if ([string]::IsNullOrWhiteSpace($ref)) { return $null }
    $parts = $ref -split '#', 2
    $filePart = $parts[0]
    $fragment = if ($parts.Count -gt 1) { $parts[1] } else { '' }
    $doc = $localSpec
    if ($filePart) {
        $doc = Get-XdrSpecFile (Join-Path $specDir $filePart)
        if ($null -eq $doc) { return $null }
    }
    if ($doc -isnot [System.Collections.IDictionary]) { return $null }
    # Walk the JSON-pointer fragment (e.g. /components/schemas/X). Empty fragment → whole doc.
    $node = $doc
    foreach ($seg in ($fragment -split '/' | Where-Object { $_ -ne '' })) {
        $key = $seg -replace '~1','/' -replace '~0','~'   # JSON-pointer unescape
        if (($node -is [System.Collections.IDictionary]) -and $node.ContainsKey($key)) { $node = $node[$key] }
        else { return $null }
    }
    return @{ node = $node; spec = $doc }
}
# Given a 200-response *schema node*, drill to the per-ITEM schema (the object whose top-level properties
# become projection columns). Handles: $ref · allOf (merge) · bare array (items) · wrapper object with an
# array property (Results/value/data/items/records/actions or ANY array-typed property) → its items.
# $localSpec is the document the node came from; cross-file refs re-root automatically. Depth-guarded.
function Get-XdrResponseItemSchema($schema, $localSpec, [string]$specDir, [int]$depth = 0) {
    if (($null -eq $schema) -or ($schema -isnot [System.Collections.IDictionary]) -or ($depth -gt 12)) { return $null }
    # $ref → resolve and recurse (spec re-roots to the ref's home document).
    if ($schema.ContainsKey('$ref')) {
        $r = Resolve-XdrRef ([string]$schema['$ref']) $localSpec $specDir
        if ($null -eq $r) { return $null }
        return Get-XdrResponseItemSchema $r['node'] $r['spec'] $specDir ($depth + 1)
    }
    # allOf → merge member properties; an array member's items win as the item schema.
    if ($schema.ContainsKey('allOf') -and ($schema['allOf'] -is [System.Collections.IList])) {
        # Plain Hashtable (the recursion below calls .ContainsKey, which OrderedDictionary lacks). Determinism comes
        # from the SORTED merge + the well-known-key/sorted array-property pick downstream — NOT from container order.
        $merged = @{ type = 'object'; properties = @{} }
        foreach ($member in @($schema['allOf'])) {
            $mm = $member
            if (($mm -is [System.Collections.IDictionary]) -and $mm.ContainsKey('$ref')) {
                $r = Resolve-XdrRef ([string]$mm['$ref']) $localSpec $specDir
                if ($null -ne $r) { $mm = $r['node'] }
            }
            if ($mm -isnot [System.Collections.IDictionary]) { continue }
            if ($mm.ContainsKey('properties') -and ($mm['properties'] -is [System.Collections.IDictionary])) {
                foreach ($pk in ($mm['properties'].Keys | Sort-Object)) { $merged['properties'][[string]$pk] = $mm['properties'][$pk] }
            }
        }
        # Recurse into the merged object to pick its array property's items (if any), else use the merged object.
        $sub = Get-XdrResponseItemSchema $merged $localSpec $specDir ($depth + 1)
        if ($null -ne $sub) { return $sub }
        return $merged
    }
    $type = if ($schema.ContainsKey('type')) { [string]$schema['type'] } else { '' }
    # Bare array → its items schema.
    if (($type -eq 'array') -and $schema.ContainsKey('items')) {
        $items = $schema['items']
        if (($items -is [System.Collections.IDictionary]) -and $items.ContainsKey('$ref')) {
            $r = Resolve-XdrRef ([string]$items['$ref']) $localSpec $specDir
            if ($null -ne $r) { return @{ node = $r['node']; spec = $r['spec'] } }
        }
        return @{ node = $items; spec = $localSpec }
    }
    # Object → is it a LIST ENVELOPE? Defer the single-record-vs-wrapper decision to the shared SHAPE ORACLE
    # (Get-XdrSchemaArrayPropertyKey · same canonical-key + single-array + pagination-metadata discipline as the
    # live-body classifier). This replaces the old "first array-typed property" pick that fanned out a record's first
    # array and dropped every sibling. Returns the chosen array property NAME, or $null when the object is a single
    # record (no array property · or several array properties alongside non-metadata siblings → drill nothing).
    if ($schema.ContainsKey('properties') -and ($schema['properties'] -is [System.Collections.IDictionary])) {
        $props = $schema['properties']
        $arrayKey = Get-XdrSchemaArrayPropertyKey -Properties $props
        if ($null -ne $arrayKey -and $props.ContainsKey($arrayKey)) {
            $arrayProp = $props[$arrayKey]
            if (($arrayProp -is [System.Collections.IDictionary]) -and $arrayProp.ContainsKey('items')) {
                $items = $arrayProp['items']
                if (($items -is [System.Collections.IDictionary]) -and $items.ContainsKey('$ref')) {
                    $r = Resolve-XdrRef ([string]$items['$ref']) $localSpec $specDir
                    if ($null -ne $r) { return @{ node = $r['node']; spec = $r['spec'] } }
                }
                return @{ node = $items; spec = $localSpec }
            }
        }
        # No qualifying list property → the object IS the single record (singleObject-style). Return it FLAGGED so the
        # caller DEFERS it to a last-resort (after postman): a real postman example outranks an often-stub/inaccurate
        # nodoc singleObject spec (the A-class regression guard). allOf-merged objects inherit the flag via the recursion.
        return @{ node = $schema; spec = $localSpec; singleObject = $true }
    }
    return $null
}
# Build a ProjectionMap (typed columns) from a resolved item schema. One entry per top-level property:
# scalar type → Get-XdrSafeColumnName(prop); object/array type → '<prop>Json'. Value = '$.' + prop.
function Get-XdrSchemaProjectionMap($resolved) {
    $pm = [ordered]@{}
    if ($null -eq $resolved) { return $pm }
    $node = if (($resolved -is [System.Collections.IDictionary]) -and $resolved.ContainsKey('node')) { $resolved['node'] } else { $resolved }
    if (($node -isnot [System.Collections.IDictionary]) -or -not $node.ContainsKey('properties')) { return $pm }
    $props = $node['properties']
    if ($props -isnot [System.Collections.IDictionary]) { return $pm }
    foreach ($prop in ($props.Keys | Sort-Object)) {
        $pschema = $props[$prop]
        $ptype = ''
        if (($pschema -is [System.Collections.IDictionary]) -and $pschema.ContainsKey('type')) { $ptype = [string]$pschema['type'] }
        $isNonScalar = ($ptype -eq 'object') -or ($ptype -eq 'array')
        $col = if ($isNonScalar) { "${prop}Json" } else { Get-XdrSafeColumnName -Name ([string]$prop) }
        $pm[$col] = '$.' + $prop
    }
    return $pm
}
# Tier 3 (Postman) · OPTIONAL best-effort. Parse the portal collection (12 MB max), find the leaf request whose
# reconstructed path + method match, take its first 200-ish response body example, derive a ProjectionMap from
# the first item's keys. Returns an EMPTY ordered map (never throws) when the file/op/example is absent.
$script:PostmanCache = @{}
$script:PostmanQueryIndex = @{}   # G-D · per-collection query-param index · init at SCRIPT SCOPE (StrictMode-safe · never read-before-set)
$script:PostmanBodyIndex  = @{}   # G-A · per-collection request-body index · init at SCRIPT SCOPE (StrictMode-safe)
$script:PostmanRespIndex  = @{}   # WS2.3 · per-collection saved-RESPONSE-body index (shape evidence · StrictMode-safe)
function Get-XdrPostmanProjectionMap([string]$collectionAbsPath, [string]$path, [string]$method) {
    $pm = [ordered]@{}
    if (-not (Test-Path $collectionAbsPath)) { return $pm }
    if ($script:PostmanCache.ContainsKey($collectionAbsPath)) { $coll = $script:PostmanCache[$collectionAbsPath] }
    else {
        $coll = $null
        try { $coll = Get-Content $collectionAbsPath -Raw | ConvertFrom-Json -AsHashtable -Depth 60 } catch { $coll = $null }
        $script:PostmanCache[$collectionAbsPath] = $coll
    }
    if (($null -eq $coll) -or ($coll -isnot [System.Collections.IDictionary]) -or -not $coll.ContainsKey('item')) { return $pm }
    $wantPath = '/' + ($path.TrimStart('/'))
    $wantMethod = $method.ToUpper()
    # Depth-first walk of the nested item tree; collect the first leaf whose request matches.
    $found = $null
    $stack = [System.Collections.Generic.Stack[object]]::new()
    foreach ($it in @($coll['item'])) { $stack.Push($it) }
    $guard = 0
    while (($stack.Count -gt 0) -and ($null -eq $found) -and ($guard -lt 200000)) {
        $guard++
        $node = $stack.Pop()
        if ($node -isnot [System.Collections.IDictionary]) { continue }
        if ($node.ContainsKey('item') -and ($node['item'] -is [System.Collections.IList])) {
            foreach ($child in @($node['item'])) { $stack.Push($child) }
            continue
        }
        if (-not $node.ContainsKey('request')) { continue }
        $req = $node['request']
        if ($req -isnot [System.Collections.IDictionary]) { continue }
        $m = if ($req.ContainsKey('method')) { ([string]$req['method']).ToUpper() } else { '' }
        if ($m -ne $wantMethod) { continue }
        $segs = @()
        if ($req.ContainsKey('url') -and ($req['url'] -is [System.Collections.IDictionary]) -and $req['url'].ContainsKey('path')) {
            foreach ($s in @($req['url']['path'])) { if ($s -isnot [System.Collections.IDictionary]) { $segs += [string]$s } }
        }
        $reqPath = '/' + ($segs -join '/')
        # Normalize Postman {{var}} / :param placeholders and spec {param} placeholders to a comparable shape.
        $normReq = ($reqPath -replace '\{\{[^}]+\}\}','*' -replace ':[^/]+','*' -replace '\{[^}]+\}','*').TrimEnd('/')
        $normWant = ($wantPath -replace '\{[^}]+\}','*').TrimEnd('/')
        if ($normReq -ne $normWant) { continue }
        if ($node.ContainsKey('response') -and ($node['response'] -is [System.Collections.IList])) {
            foreach ($resp in @($node['response'])) {
                if ($resp -isnot [System.Collections.IDictionary]) { continue }
                $code = if ($resp.ContainsKey('code')) { $resp['code'] } else { 200 }
                if (("$code" -ne '200') -and ("$code" -ne '0')) { continue }
                if (-not $resp.ContainsKey('body')) { continue }
                $bodyStr = [string]$resp['body']
                if ([string]::IsNullOrWhiteSpace($bodyStr)) { continue }
                $parsed = $null
                try { $parsed = $bodyStr | ConvertFrom-Json -AsHashtable -Depth 40 } catch { $parsed = $null }
                if ($null -eq $parsed) { continue }
                $item = $null
                if ($parsed -is [System.Collections.IList]) { if (@($parsed).Count -gt 0) { $item = @($parsed)[0] } }
                elseif ($parsed -is [System.Collections.IDictionary]) {
                    foreach ($wk in @('Results','results','value','data','items','records','actions')) {
                        if ($parsed.ContainsKey($wk) -and ($parsed[$wk] -is [System.Collections.IList]) -and (@($parsed[$wk]).Count -gt 0)) { $item = @($parsed[$wk])[0]; break }
                    }
                    if ($null -eq $item) { $item = $parsed }   # single object
                }
                if (($item -is [System.Collections.IDictionary]) -and (@($item.Keys).Count -gt 0)) {   # .Keys.Count · a 'Count' key would shadow .Count
                    $found = $item; break
                }
            }
        }
    }
    if ($null -ne $found) {
        foreach ($k in ($found.Keys | Sort-Object)) {
            $v = $found[$k]
            $isNonScalar = ($v -is [System.Collections.IDictionary]) -or ($v -is [System.Collections.IList])
            $col = if ($isNonScalar) { "${k}Json" } else { Get-XdrSafeColumnName -Name ([string]$k) }
            $pm[$col] = '$.' + $k
        }
    }
    return $pm
}

# G-D · request-URL QUERY param KEYS for the matched Postman item. The OpenAPI spec carries NO params, so Postman is
# the ONLY source of time-window params (fromDate/toDate/startTime/...). Same DFS path+method match as
# Get-XdrPostmanProjectionMap; returns @(key names) of request.url.query (empty when no match / no query). Deterministic.
function Get-XdrPostmanQueryParams([string]$collectionAbsPath, [string]$path, [string]$method) {
    # One-time per-collection INDEX (normPath|METHOD -> @(query keys)) built on first call · O(tree) once + O(1) lookup
    # (a per-op DFS would be O(ops*tree)). first-wins per key matches the prior DFS first-match semantics. Deterministic.
    if (-not $script:PostmanQueryIndex.ContainsKey($collectionAbsPath)) {
        $idx = @{}
        $coll = $null
        if ($script:PostmanCache.ContainsKey($collectionAbsPath)) { $coll = $script:PostmanCache[$collectionAbsPath] }
        elseif (Test-Path $collectionAbsPath) { try { $coll = Get-Content $collectionAbsPath -Raw | ConvertFrom-Json -AsHashtable -Depth 60 } catch { $coll = $null }; $script:PostmanCache[$collectionAbsPath] = $coll }
        if (($coll -is [System.Collections.IDictionary]) -and $coll.ContainsKey('item')) {
            $stack = [System.Collections.Generic.Stack[object]]::new()
            foreach ($it in @($coll['item'])) { $stack.Push($it) }
            $guard = 0
            while (($stack.Count -gt 0) -and ($guard -lt 500000)) {
                $guard++
                $node = $stack.Pop()
                if ($node -isnot [System.Collections.IDictionary]) { continue }
                if ($node.ContainsKey('item') -and ($node['item'] -is [System.Collections.IList])) { foreach ($child in @($node['item'])) { $stack.Push($child) }; continue }
                if (-not $node.ContainsKey('request')) { continue }
                $req = $node['request']
                if ($req -isnot [System.Collections.IDictionary]) { continue }
                $m = if ($req.ContainsKey('method')) { ([string]$req['method']).ToUpper() } else { '' }
                $segs = @(); $qkeys = @()
                if ($req.ContainsKey('url') -and ($req['url'] -is [System.Collections.IDictionary])) {
                    $u = $req['url']
                    if ($u.ContainsKey('path'))  { foreach ($s in @($u['path']))  { if ($s  -isnot [System.Collections.IDictionary]) { $segs  += [string]$s } } }
                    if ($u.ContainsKey('query')) { foreach ($qp in @($u['query'])) { if (($qp -is [System.Collections.IDictionary]) -and $qp.ContainsKey('key')) { $qkeys += [string]$qp['key'] } } }
                }
                $normReq = ((('/' + ($segs -join '/')) -replace '\{\{[^}]+\}\}','*' -replace ':[^/]+','*' -replace '\{[^}]+\}','*')).TrimEnd('/')
                $k = "$normReq|$m"
                if (-not $idx.ContainsKey($k)) { $idx[$k] = @($qkeys) }
            }
        }
        $script:PostmanQueryIndex[$collectionAbsPath] = $idx
    }
    $idx = $script:PostmanQueryIndex[$collectionAbsPath]
    $normWant = ((('/' + ($path.TrimStart('/'))) -replace '\{[^}]+\}','*')).TrimEnd('/')
    $k = "$normWant|$($method.ToUpper())"
    if ($idx.ContainsKey($k)) { return ,@($idx[$k]) }
    return @()
}

# WS2.3 · postman saved-RESPONSE body (first 200/0-code example per normPath|METHOD · same DFS+index pattern as the
# query/body indices). SHAPE evidence for ops with no live capture: an empty-array example ("[]") proves the response
# is a bareArray even though it carries zero fields (e.g. ActionCenter.ListAutomationRules — spec schema is a stub,
# capture absent, postman example = []) — so the conservative singleObject default never mislabels a proven array.
# Returns the RAW body string ('' indexed as absent) · NEVER fabricates · parse/shape classification is the caller's.
function Get-XdrPostmanResponseBody([string]$collectionAbsPath, [string]$path, [string]$method) {
    if (-not $script:PostmanRespIndex.ContainsKey($collectionAbsPath)) {
        $idx = @{}
        $coll = $null
        if ($script:PostmanCache.ContainsKey($collectionAbsPath)) { $coll = $script:PostmanCache[$collectionAbsPath] }
        elseif (Test-Path $collectionAbsPath) { try { $coll = Get-Content $collectionAbsPath -Raw | ConvertFrom-Json -AsHashtable -Depth 60 } catch { $coll = $null }; $script:PostmanCache[$collectionAbsPath] = $coll }
        if (($coll -is [System.Collections.IDictionary]) -and $coll.ContainsKey('item')) {
            $stack = [System.Collections.Generic.Stack[object]]::new()
            foreach ($it in @($coll['item'])) { $stack.Push($it) }
            $guard = 0
            while (($stack.Count -gt 0) -and ($guard -lt 500000)) {
                $guard++
                $node = $stack.Pop()
                if ($node -isnot [System.Collections.IDictionary]) { continue }
                if ($node.ContainsKey('item') -and ($node['item'] -is [System.Collections.IList])) { foreach ($child in @($node['item'])) { $stack.Push($child) }; continue }
                if (-not $node.ContainsKey('request')) { continue }
                $req = $node['request']
                if ($req -isnot [System.Collections.IDictionary]) { continue }
                $m = if ($req.ContainsKey('method')) { ([string]$req['method']).ToUpper() } else { '' }
                $segs = @()
                if ($req.ContainsKey('url') -and ($req['url'] -is [System.Collections.IDictionary]) -and $req['url'].ContainsKey('path')) { foreach ($s in @($req['url']['path'])) { if ($s -isnot [System.Collections.IDictionary]) { $segs += [string]$s } } }
                $respBody = ''
                if ($node.ContainsKey('response') -and ($node['response'] -is [System.Collections.IList])) {
                    foreach ($resp in @($node['response'])) {
                        if ($resp -isnot [System.Collections.IDictionary]) { continue }
                        $code = if ($resp.ContainsKey('code')) { $resp['code'] } else { 200 }
                        if (("$code" -ne '200') -and ("$code" -ne '0')) { continue }
                        if ($resp.ContainsKey('body') -and -not [string]::IsNullOrWhiteSpace([string]$resp['body'])) { $respBody = [string]$resp['body']; break }
                    }
                }
                $normReq = ((('/' + ($segs -join '/')) -replace '\{\{[^}]+\}\}','*' -replace ':[^/]+','*' -replace '\{[^}]+\}','*')).TrimEnd('/')
                $rk = "$normReq|$m"
                if ((-not $idx.ContainsKey($rk)) -and $respBody) { $idx[$rk] = $respBody }
            }
        }
        $script:PostmanRespIndex[$collectionAbsPath] = $idx
    }
    $idx = $script:PostmanRespIndex[$collectionAbsPath]
    $normWant = ((('/' + ($path.TrimStart('/'))) -replace '\{[^}]+\}','*')).TrimEnd('/')
    $k = "$normWant|$($method.ToUpper())"
    if ($idx.ContainsKey($k)) { return [string]$idx[$k] }
    return $null
}

# G-A · read-via-POST BodyTemplate from the Postman corpus. The OpenAPI spec has 0 requestBody and live/evidence carry
# only RESPONSE bodies, so Postman request.body is the ONLY source. Build-once per-collection index -> O(1) lookup (same
# DFS match as Get-XdrPostmanQueryParams). Returns the request.body.raw JSON STRING only if it parses to a REAL non-empty
# object that is NOT a key_N stub; REJECTS key_N stubs + empty {} + null + non-JSON. NEVER fabricates. Ships 0 today (the
# telemetry-POST candidates carry only garbage/empty bodies · §2 G-A) — honest + foundational (ready when real bodies arrive).
function Get-XdrPostmanBodyTemplate([string]$collectionAbsPath, [string]$path, [string]$method) {
    if (-not $script:PostmanBodyIndex.ContainsKey($collectionAbsPath)) {
        $idx = @{}
        $coll = $null
        if ($script:PostmanCache.ContainsKey($collectionAbsPath)) { $coll = $script:PostmanCache[$collectionAbsPath] }
        elseif (Test-Path $collectionAbsPath) { try { $coll = Get-Content $collectionAbsPath -Raw | ConvertFrom-Json -AsHashtable -Depth 60 } catch { $coll = $null }; $script:PostmanCache[$collectionAbsPath] = $coll }
        if (($coll -is [System.Collections.IDictionary]) -and $coll.ContainsKey('item')) {
            $stack = [System.Collections.Generic.Stack[object]]::new()
            foreach ($it in @($coll['item'])) { $stack.Push($it) }
            $guard = 0
            while (($stack.Count -gt 0) -and ($guard -lt 500000)) {
                $guard++
                $node = $stack.Pop()
                if ($node -isnot [System.Collections.IDictionary]) { continue }
                if ($node.ContainsKey('item') -and ($node['item'] -is [System.Collections.IList])) { foreach ($child in @($node['item'])) { $stack.Push($child) }; continue }
                if (-not $node.ContainsKey('request')) { continue }
                $req = $node['request']
                if ($req -isnot [System.Collections.IDictionary]) { continue }
                $m = if ($req.ContainsKey('method')) { ([string]$req['method']).ToUpper() } else { '' }
                $segs = @(); $raw = ''
                if ($req.ContainsKey('url') -and ($req['url'] -is [System.Collections.IDictionary]) -and $req['url'].ContainsKey('path')) { foreach ($s in @($req['url']['path'])) { if ($s -isnot [System.Collections.IDictionary]) { $segs += [string]$s } } }
                if ($req.ContainsKey('body') -and ($req['body'] -is [System.Collections.IDictionary]) -and $req['body'].ContainsKey('raw')) { $raw = [string]$req['body']['raw'] }
                $normReq = ((('/' + ($segs -join '/')) -replace '\{\{[^}]+\}\}','*' -replace ':[^/]+','*' -replace '\{[^}]+\}','*')).TrimEnd('/')
                $bk = "$normReq|$m"
                if ((-not $idx.ContainsKey($bk)) -and $raw) { $idx[$bk] = $raw }
            }
        }
        $script:PostmanBodyIndex[$collectionAbsPath] = $idx
    }
    $idx = $script:PostmanBodyIndex[$collectionAbsPath]
    $normWant = ((('/' + ($path.TrimStart('/'))) -replace '\{[^}]+\}','*')).TrimEnd('/')
    $raw = $idx["$normWant|$($method.ToUpper())"]
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    if (($raw -replace '\s', '') -in @('{}', '[]', 'null')) { return $null }   # empty object/array/JSON-null → reject (explicit · pre-parse)
    # Validate: a clean NON-empty object that is NOT a key_N stub. ANY parse/shape error → reject (never fabricate).
    try {
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($obj -isnot [pscustomobject]) { return $null }                         # array / scalar / null → reject
        $names = @($obj.PSObject.Properties.Name)
        if ($names.Count -eq 0) { return $null }                                   # empty {} → reject
        if (@($names | Where-Object { $_ -notmatch '^key_?\d+$' }).Count -eq 0) { return $null }  # ALL keys key_N stub → reject
        return $raw
    } catch { return $null }
}

# ── Build one portal's catalogue (all groups, or one) ──
function Build-PortalCatalogue {
    param([hashtable] $Reg, [string] $OnlyGroup)
    $portalKey = $Reg.Key
    $invDir  = Join-Path $RepoRoot "references/inventory/$portalKey"
    $specDir = Join-Path $RepoRoot "references/openapi/$portalKey/specification"
    $specFile = Join-Path $specDir 'openapi.yml'
    if (-not (Test-Path $specFile)) { throw "openapi.yml not found for $portalKey" }
    $root = ConvertFrom-Yaml (Get-Content $specFile -Raw)

    # F4 (§21.7) · BEHAVIORAL-DERIVATION TIER · conservative ship-defaults. A Shipped op with NO live-proven
    # IngestionMode (LiveCaptured / OpenApiDerived) must still be POLLABLE: assign CONSERVATIVE, never-fabricated
    # defaults — SNAPSHOT (full re-emit · no cursor/NaturalKey needed), a conservative cadence, ResponseShape =
    # captured-shape-if-present else singleObject (the RawJson-floor-safe default that never drops data). Tagged
    # derived-conservative; the X-phase LIVE capture later upgrades to the real CURSOR/shape. MUTATES $r in place ·
    # idempotent (no-op unless Shipped with empty IngestionMode). Applied at the in-loop ship-gate AND AGAIN
    # post-DEPEND (G-H · once EntityResolution is final, a newly-shippable entity op needs the same defaults).
    $applyConservativeDefaults = {
        param($r)
        if (-not $r['Shipped']) { return }
        if (-not [string]::IsNullOrEmpty([string]$r['IngestionMode'])) { return }
        $r['IngestionMode'] = 'SNAPSHOT'
        if ([string]::IsNullOrEmpty([string]$r['Cadence']))       { $r['Cadence'] = '00:15:00' }
        if ([string]::IsNullOrEmpty([string]$r['ResponseShape'])) { $r['ResponseShape'] = 'singleObject' }
        if ($null -eq $r['NaturalKey'])                           { $r['NaturalKey'] = @() }
        if ($null -eq $r['TimeFilter'])                           { $r['TimeFilter'] = [ordered]@{ Mode = 'None'; FieldName = $null } }
        $r['BehavioralTier'] = 'derived-conservative'
    }

    # group → tags (x-tagGroups). tag → group reverse-map for fast classification.
    $groups = @($root['x-tagGroups'])
    $tagToGroup = @{}
    foreach ($g in $groups) { foreach ($t in @($g['tags'])) { $tagToGroup[$t] = $g['name'] } }
    $selectGroups = if ($OnlyGroup) { @($OnlyGroup) } else { @($groups | ForEach-Object { $_['name'] }) }

    # live evidence (facts the spec gets wrong · only Defender has any today) — BEHAVIORAL proof source (Validated).
    $evPath = Join-Path $invDir 'live-evidence.json'
    $evidence = @{}
    if (Test-Path $evPath) { $evidence = (Get-Content $evPath -Raw | ConvertFrom-Json -AsHashtable)['operations'] }

    # live-capture EVIDENCE INDEX (Build-EvidenceIndex.ps1) — tier-1 SCHEMA source (LiveCaptured). One record per
    # captured op, keyed here by catalogue OperationId. Carries the chosen RAW body Fixture + ResponseShape/
    # ItemsContainer/SampleFields so the Map stage derives the ProjectionMap from REAL captured fields WITHOUT
    # re-probing — but, unlike live-evidence, it does NOT authorize behavioral fields (those stay null until proven).
    $eiPath = Join-Path $invDir 'evidence-index.json'
    $evIndex = @{}
    if (Test-Path $eiPath) {
        $eiDoc = Get-Content $eiPath -Raw | ConvertFrom-Json -AsHashtable
        foreach ($r in @($eiDoc['Records'])) { if ($r.ContainsKey('OperationId') -and $r['OperationId']) { $evIndex[[string]$r['OperationId']] = $r } }
    }

    # per-category spec op cache · indexed by operationId AND by 'path|METHOD' (the latter reaches ops whose spec
    # path declares NO operationId — the single-file-portal majority). When <cat>.yml is absent (15/20 portals), it
    # falls back to the portal's single specification/openapi.yml so params + response schema are still detected.
    $specCache = @{}
    function Get-SpecOps([string]$category, [string]$specDirLocal) {
        if ($specCache.ContainsKey($category)) { return $specCache[$category] }
        $f = Join-Path $specDirLocal "$category.yml"
        if (-not (Test-Path $f)) { $f = Join-Path $specDirLocal 'openapi.yml' }   # fallback · single-file portals
        $map = @{}
        $spec = Get-XdrSpecFile $f
        if ($spec -is [System.Collections.IDictionary] -and $spec.ContainsKey('paths')) {
            # Sort path keys → deterministic last-write-wins for the operationId index below. ConvertFrom-Yaml yields a
            # process-seed-randomized Hashtable; without the sort, an inventory operationId that maps to >1 spec path
            # (e.g. the case-variant ListChangeEvents duplicate) would bind to a non-reproducible spec op → flaky pagination.
            foreach ($pk in ($spec['paths'].Keys | Sort-Object)) {
                $methods = $spec['paths'][$pk]
                if ($methods -isnot [System.Collections.IDictionary]) { continue }
                foreach ($mk in $methods.Keys) {
                    $op = $methods[$mk]
                    if ($op -isnot [System.Collections.IDictionary]) { continue }
                    if (-not ($mk -in @('get','put','post','delete','patch','head','options'))) { continue }   # skip $ref-only path stubs (multi-file openapi.yml) + non-method keys
                    if ($op.ContainsKey('$ref')) { continue }   # $ref path-item stub → real op lives in the per-category file
                    # Parameter names + (in, required) details · resolve $ref params ('#/components/parameters/X') to the
                    # declared node. $params keeps NAMES (back-compat: time/pagination detection at :1047-1050); $paramDetails
                    # adds the 'in' (query/path/header) + 'required' flag the pollability ship-gate needs — a REQUIRED QUERY
                    # param the runtime cannot supply makes the op 400 every cycle, so it must be HELD (§22-pollable, like an
                    # Unresolved entity). PATH-required params are already modelled by EntityResolution; this is QUERY only.
                    $params = @(); $paramDetails = @()
                    if ($op.ContainsKey('parameters')) {
                        foreach ($pp in @($op['parameters'])) {
                            if ($pp -isnot [System.Collections.IDictionary]) { continue }
                            $node = $pp
                            if (-not $pp.ContainsKey('name') -and $pp.ContainsKey('$ref')) {
                                $rp = Resolve-XdrRef ([string]$pp['$ref']) $spec $specDirLocal
                                if (($null -ne $rp) -and ($rp['node'] -is [System.Collections.IDictionary])) { $node = $rp['node'] }
                            }
                            if (($node -is [System.Collections.IDictionary]) -and $node.ContainsKey('name')) {
                                $params += [string]$node['name']
                                $paramDetails += @{
                                    name     = [string]$node['name']
                                    in       = $(if ($node.ContainsKey('in'))       { [string]$node['in'] } else { '' })
                                    required = $(if ($node.ContainsKey('required')) { [bool]$node['required'] } else { $false })
                                }
                            }
                        }
                    }
                    # 200-response JSON schema node (for the Map stage's tier-2 item-schema derivation).
                    $respSchema = $null
                    if ($op.ContainsKey('responses') -and ($op['responses'] -is [System.Collections.IDictionary])) {
                        $resps = $op['responses']
                        $okKey = @('200','201','default') | Where-Object { $resps.ContainsKey($_) } | Select-Object -First 1
                        if ($okKey) {
                            $r2 = $resps[$okKey]
                            if (($r2 -is [System.Collections.IDictionary]) -and $r2.ContainsKey('content') -and ($r2['content'] -is [System.Collections.IDictionary])) {
                                $cnt = $r2['content']
                                $mt = @('application/json') + @($cnt.Keys | Where-Object { "$_" -like 'application/*json*' })
                                $ct = $mt | Where-Object { $cnt.ContainsKey($_) } | Select-Object -First 1
                                if ($ct -and ($cnt[$ct] -is [System.Collections.IDictionary]) -and $cnt[$ct].ContainsKey('schema')) { $respSchema = $cnt[$ct]['schema'] }
                            }
                        }
                    }
                    $entry = @{ method = $mk.ToUpper(); fullPath = $pk; params = @($params); paramDetails = @($paramDetails); respSchema = $respSchema; spec = $spec; specDir = $specDirLocal }
                    $map["$pk|$($mk.ToUpper())"] = $entry                         # path+method key (always)
                    if ($op.ContainsKey('operationId')) { $map[[string]$op['operationId']] = $entry }   # operationId key (when present)
                }
            }
        }
        $specCache[$category] = $map
        return $map
    }
    # Resolve a spec op for an inventory record: prefer operationId, fall back to inventory path + method.
    function Get-SpecOpFor([string]$category, $opId, [string]$invPath, [string]$method) {
        $ops = Get-SpecOps $category $specDir
        if ($opId -and $ops.ContainsKey([string]$opId)) { return $ops[[string]$opId] }
        $pk = '/' + ([string]$invPath).TrimStart('/')
        $mk = $method.ToUpper()
        if ($ops.ContainsKey("$pk|$mk")) { return $ops["$pk|$mk"] }
        return $null
    }

    # ---- Stages 1-4 · structural · EVERY op (from inventory operations.json) ----
    $records = @()
    foreach ($invf in (Get-ChildItem $invDir -Filter '*.operations.json' -ErrorAction SilentlyContinue)) {
        $inv = Get-Content $invf.FullName -Raw | ConvertFrom-Json -AsHashtable
        $cat = if ($inv.Contains('category') -and $inv['category']) { [string]$inv['category'] } else { [IO.Path]::GetFileNameWithoutExtension($invf.Name) -replace '\.operations$','' }
        foreach ($op in @($inv['operations'])) {
            $tags = @($op['Tags'])
            # Classify into a GROUP via the tag→group reverse-map (first tag that maps).
            $grp = $null; $subcat = $null
            foreach ($t in $tags) { if ($tagToGroup.ContainsKey($t)) { $grp = $tagToGroup[$t]; $subcat = $t; break } }
            if (-not $grp) { continue }                       # tag not in any x-tagGroups group
            if ($grp -notin $selectGroups) { continue }       # not the requested group(s)
            # DualTag signal · count how many of the op's tags resolve to a group. ≥2 ⇒ the SAME op is reachable via
            # two tags (e.g. Files.GetCloudAppsFileCount tagged CloudApps+Files) → annotated DualTag in the Select stage.
            $mappedTagCount = @($tags | Where-Object { $tagToGroup.ContainsKey($_) }).Count
            $opId = if ($op.Contains('OperationId')) { $op['OperationId'] } else { $null }
            $summary = if ($op.Contains('Summary')) { [string]$op['Summary'] } else { '' }
            # Spec op · operationId first (per-category files), else inventory path+method (single-file portals whose paths carry no operationId).
            $specOp = Get-SpecOpFor $cat $opId ([string]$op['Path']) ([string]$op['Method'])
            $fullPath = if ($specOp) { $specOp['fullPath'] } else { [string]$op['Path'] }
            $opKey = Get-OperationKey $opId $op['Method'] $fullPath
            $effOpId = if ($opId) { [string]$opId } else { "$subcat.$opKey" }   # synthesize a stable id when null
            $sp = Split-SubPortal $fullPath
            # Manual-verified live>spec path reconcile (§6/§7 fix #4): a spec server-prefix can mis-locate the op vs the
            # endpoint it actually answers on. When curated, the LIVE-PROVEN (SubPortal, Path) overrides the spec split.
            if ($script:XdrPathOverrides.ContainsKey($effOpId)) {
                $ov = $script:XdrPathOverrides[$effOpId]
                $sp = @{ SubPortal = [string]$ov['SubPortal']; Path = [string]$ov['Path'] }
            }
            # Category is the nodoc x-tagGroup ($grp), ALWAYS — never overridden. (The pilot is the ActionCenter
            # OPS as the Subcategory='Action Center' rows WITHIN Defender_Operations_CL; we do not fabricate a
            # category outside the nodoc taxonomy. Operator-locked 2026-06-11.)
            $pathParams = @([regex]::Matches($fullPath, '\{([^}]+)\}') | ForEach-Object { $_.Groups[1].Value })
            $readSem = Get-ReadSemantics $op['Method'] $effOpId $summary
            $telClass = Get-TelemetryClass $subcat $readSem $portalKey
            $paramSource = 'None'
            if ($pathParams.Count -gt 0) { $paramSource = if ($pathParams -contains 'TenantId') { 'TenantContext' } else { 'ParentOp' } }
            $rec = [ordered]@{
                Portal = $Reg.Friendly; Category = $grp; Subcategory = $subcat; Operation = $opKey; OperationId = $effOpId
                SubPortal = $sp.SubPortal; Path = $sp.Path; Method = $op['Method'].ToUpper(); Summary = $summary
                ReadSemantics = $readSem; TelemetryClass = $telClass
                ScopeDecision = $(if ($telClass -eq 'InternalOnly' -and $readSem -ne 'Write') { 'Include' } else { 'Exclude' })
                IsCanonical = $true; AliasFor = $null; DuplicateClass = $null
                PathParams = $pathParams; ParamSource = $paramSource; DependsOn = $null
                # EntityResolution · DEPEND‑stage field (plan §16 U3b). Entity ops start 'Pending' (the Depend pass
                # resolves them to 'Resolved'/'Unresolved' after Map); non‑entity ops are 'NotEntity' (never fanned out).
                EntityResolution = $(if ($paramSource -eq 'ParentOp') { 'Pending' } else { 'NotEntity' })
            }
            $records += @{ rec = $rec; cat = $cat; specOp = $specOp; mappedTagCount = $mappedTagCount; fullPath = $fullPath
                ev = $(if ($evidence.ContainsKey($effOpId)) { $evidence[$effOpId] } else { $null })
                ei = $(if ($evIndex.ContainsKey($effOpId)) { $evIndex[$effOpId] } else { $null }) }
        }
    }

    # ---- Stage 3 · dedupe (same SubPortal|Path|Method → canonical=first) ----
    $byKey = @{}
    foreach ($r in $records) { $k = $r['rec'].SubPortal + '|' + $r['rec'].Path + '|' + $r['rec'].Method; if (-not $byKey.ContainsKey($k)) { $byKey[$k] = @() }; $byKey[$k] += $r }
    # Sort keys → deterministic dedupe processing (plain @{} .Keys order is process-seed-randomized). The canonical
    # pick within a group is already order-stable ([0] = first by inventory order); sorting the OUTER key walk keeps
    # cross-process output byte-identical even where the inventory carries near-duplicate (case-variant path) entries.
    foreach ($k in ($byKey.Keys | Sort-Object)) { $g = @($byKey[$k]); if ($g.Count -gt 1) { for ($i = 1; $i -lt $g.Count; $i++) { $g[$i]['rec'].IsCanonical = $false; $g[$i]['rec'].AliasFor = $g[0]['rec'].OperationId; $g[$i]['rec'].DuplicateClass = 'SamePath' } } }

    # ---- SELECT · DuplicateClass extension (plan A3) · ANNOTATION-ONLY · sets the LABEL only ----
    # Extends the exact SamePath dedup above with three softer duplicate signals used purely for onboarding ranking.
    # SamePath (already set) is NEVER overwritten; these only fill a STILL-null DuplicateClass. None of them touch
    # IsCanonical/AliasFor/ScopeDecision/Status → the catalogue keeps every op and the Status distribution is unchanged
    # (canonical stays ingestable, the mirror is merely marked). Precedence: DualTag > MtoMirror > PathVariant.
    #   DualTag    · the op itself carries ≥2 group-mapped tags (reachable via two tags) — per-op, order-independent.
    #   MtoMirror  · a /mtoapi/ (SubPortal=mtoapi) op whose normalized tail path matches a NON-mtoapi op (multi-tenant mirror).
    #   PathVariant· the op's path carries a variant suffix (count/filters/summary/metadata/export) AND a sibling op
    #                exists at the stripped base path (same SubPortal) — the suffixed op is flagged as the variant.
    # Build deterministic indices: non-mtoapi tail set (for MtoMirror) and base-path set (for PathVariant).
    $nonMtoTailSet = @{}; $basePathSet = @{}
    foreach ($r in $records) {
        $rr = $r['rec']
        $tailKey = (Get-NormalizedTailKey ([string]$r['fullPath']) ([string]$rr.Method))
        if ($rr.SubPortal -ne 'mtoapi') { $nonMtoTailSet[$tailKey] = $true }
        # base-path index keyed by SubPortal|normalizedBase|Method → lets a suffixed op find its sibling.
        $baseKey = $rr.SubPortal + '|' + (Get-NormalizedPathKey ([string]$r['fullPath'])) + '|' + $rr.Method
        $basePathSet[$baseKey] = $true
    }
    foreach ($r in $records) {
        $rr = $r['rec']
        if ($null -ne $rr.DuplicateClass) { continue }                       # SamePath already won — never overwrite.
        $fp = [string]$r['fullPath']
        # DualTag (most specific soft signal).
        if (([int]$r['mappedTagCount']) -ge 2) { $rr.DuplicateClass = 'DualTag'; continue }
        # MtoMirror · a multi-tenant (mtoapi) op shadowing a non-mtoapi op with the same normalized tail.
        if ($rr.SubPortal -eq 'mtoapi') {
            $tailKey = (Get-NormalizedTailKey $fp ([string]$rr.Method))
            if ($nonMtoTailSet.ContainsKey($tailKey)) { $rr.DuplicateClass = 'MtoMirror'; continue }
        }
        # PathVariant · this op's path has a stripped variant suffix AND a sibling lives at the base path.
        $normFull = ($fp -replace '\{[^}]+\}', '*').ToLower().Trim('/')
        $fullSegs = @($normFull -split '/' | Where-Object { $_ -ne '' -and $_ -ne '*' })
        $baseKey  = $rr.SubPortal + '|' + (Get-NormalizedPathKey $fp) + '|' + $rr.Method
        $baseSegs = @((Get-NormalizedPathKey $fp) -split '/' | Where-Object { $_ -ne '' })
        if (($fullSegs.Count -gt $baseSegs.Count) -and $basePathSet.ContainsKey($baseKey)) { $rr.DuplicateClass = 'PathVariant' }
    }

    # ---- Stages 5-6 · Decide + Map · HONEST gating ----
    $out = @()
    foreach ($r in $records) {
        $rec = $r['rec']; $ev = $r['ev']; $specOp = $r['specOp']
        $tableName  = "$($Reg.Friendly)_$(ConvertTo-TableToken $rec.Category)_CL"
        $streamName = "Custom-$tableName"
        $paramNames = @(); if ($specOp) { $paramNames = @($specOp['params']) }
        $hasPageIdx  = ($paramNames -contains 'pageSize') -and ($paramNames -contains 'pageIndex')
        $hasSkipTop  = ($paramNames -contains '$skip') -and ($paramNames -contains '$top')
        $hasSort     = ($paramNames -contains 'sortByField') -and ($paramNames -contains 'sortOrder')
        $hasTimeParam = @($paramNames | Where-Object { $_ -imatch 'fromdate|todate|starttime|endtime|\$filter|since|after|startdate|enddate' }).Count -gt 0

        # §22-pollable · REQUIRED QUERY params the runtime cannot supply. The cataloguer models PATH params (EntityResolution)
        # but an unmodelled required *query* param (ThreatAnalytics.GetIndicatorReputation's indicator · EntityPivots' entityId
        # · CloudApps.GetActivityLocationsByUser's user) let the op SHIP yet 400 EVERY cycle. The runtime auto-supplies ONLY
        # time-filter + pagination/sort query params; curation querySupplied declares others (operator-verified at onboarding).
        # Any LEFTOVER required query param => not pollable-now => recorded here + HELD at the ship-gate twins (:1336/:1394).
        # SPARSE field (set only when non-empty · the BodyTemplate precedent) so the committed catalogue stays byte-stable
        # for every already-pollable op.
        $reqQueryDetails = @(); if ($specOp -and $specOp.ContainsKey('paramDetails')) { $reqQueryDetails = @($specOp['paramDetails']) }
        $autoSuppliedQuery = @('pageSize','pageIndex','$skip','$top','sortByField','sortOrder')   # runtime-driven pagination/sort
        if ($hasTimeParam) { $autoSuppliedQuery += @($paramNames | Where-Object { $_ -imatch 'fromdate|todate|starttime|endtime|\$filter|since|after|startdate|enddate' }) }
        $curatedQuerySupplied = if ($script:XdrQuerySupplied.ContainsKey([string]$rec['OperationId'])) { @($script:XdrQuerySupplied[[string]$rec['OperationId']]) } else { @() }
        $reqQuery = @($reqQueryDetails |
            Where-Object { ([string]$_.in -eq 'query') -and $_.required -and ([string]$_.name -notin $autoSuppliedQuery) -and ([string]$_.name -notin $curatedQuerySupplied) } |
            ForEach-Object { [string]$_.name } | Sort-Object -Unique)
        if (@($reqQuery).Count -gt 0) { $rec['RequiredQueryParams'] = @($reqQuery) }

        # live fixture (the ONLY source for behavioral fields)
        $fixture = $null; $liveFields = $null; $shape = 'unknown'; $itemsKey = $null; $liveRowCount = $null
        if ($ev -and $ev.ContainsKey('Fixture')) {
            $fp = Join-Path $RepoRoot $ev['Fixture']
            if (Test-Path $fp) {
                $body = Get-Content $fp -Raw | ConvertFrom-Json -AsHashtable -Depth 25
                # V4 (§21.1): classify the live-evidence body via the SHARED shape oracle (Get-XdrBodyShape) — the SAME
                # classifier Build-EvidenceIndex and the LiveCaptured branch (below) use — NOT a private inline
                # canonical-key `.ContainsKey` scan, which missed 'actions', the multi-array/metadata-sibling discipline
                # and the MTO one-level descent. The inline version would RE-mislabel 24 ops (20 Recommended) the moment
                # they are promoted to Validated (a wrapper read as singleObject collapses the whole list to ONE row).
                # GetHistory (top-level wrapper/Results) classifies identically under the oracle, so the committed
                # catalogue stays byte-stable; only future promotions are corrected.
                $shapeO       = Get-XdrBodyShape $body
                $shape        = [string]$shapeO['Shape']
                $itemsKey     = $shapeO['ItemsContainer']
                $liveRowCount = $shapeO['RowCount']
                $liveFields   = $shapeO['FieldUnion']   # F4 · union of fields across ALL items (not item[0]) · sparse fields faithful
                $fixture = $ev['Fixture']
            }
        }
        $liveIsDict = $liveFields -is [System.Collections.IDictionary]

        # T3c (audit 2026-06-12) · RESPONSE continuation-token detection. The token lives in the RESPONSE (body) —
        # request-param derivation cannot see it, so every nextLink/skipToken API catalogued Mode='none' and silently
        # single-paged (the runtime's token mode was fully built yet INERT · the #1 expansion blocker). Tier order
        # (the locked evidence waterfall): live-evidence fixture body > evidence-index captured RAW body > OpenAPI
        # 200-response schema top-level properties. Pagination is structural (not behavioral) — same discipline as the
        # spec-param modes above. A *nextLink* key is a URL cursor (absolute vs relative is VALUE-driven at runtime);
        # an opaque token key re-sends as a query param (CursorQuery = the matching spec request param, else the key).
        $respTokKey = $null
        $tokPref = @('@odata.nextLink','odata.nextLink','nextLink','skipToken','continuationToken','nextPageToken','$skiptoken')
        $scanTok = { param($keys) foreach ($tk in $tokPref) { if (@($keys) -icontains $tk) { return $tk } } return $null }
        if ($fixture -and ($body -is [System.Collections.IDictionary])) {
            $respTokKey = & $scanTok @($body.Keys)
        }
        if (-not $respTokKey) {
            $tokEi = $r['ei']
            if (($tokEi -is [System.Collections.IDictionary]) -and $tokEi.Contains('Fixture') -and ($rec.ScopeDecision -ne 'Exclude')) {
                $tokFp = Join-Path $RepoRoot ([string]$tokEi['Fixture'])
                if (Test-Path $tokFp) {
                    $tokBody = $null
                    try { $tokBody = Get-Content $tokFp -Raw | ConvertFrom-Json -AsHashtable -Depth 25 } catch { $tokBody = $null }
                    if ($tokBody -is [System.Collections.IDictionary]) { $respTokKey = & $scanTok @($tokBody.Keys) }
                }
            }
        }
        if (-not $respTokKey -and $specOp -and $specOp['respSchema']) {
            $tokRs = $specOp['respSchema']
            if (($tokRs -is [System.Collections.IDictionary]) -and $tokRs.ContainsKey('$ref')) {
                $tokRef = Resolve-XdrRef ([string]$tokRs['$ref']) $specOp['spec'] $specOp['specDir']
                if (($null -ne $tokRef) -and ($tokRef['node'] -is [System.Collections.IDictionary])) { $tokRs = $tokRef['node'] }
            }
            if (($tokRs -is [System.Collections.IDictionary]) -and $tokRs.ContainsKey('properties') -and ($tokRs['properties'] -is [System.Collections.IDictionary])) {
                $respTokKey = & $scanTok @($tokRs['properties'].Keys)
            }
        }

        # Pagination · OpenAPI-derivable (spec params) → emit where present (OpenApiDerived OK · not behavioral).
        # Priority: explicit client paging params (pageIndex > skipTop · live-proven modes) > response token > none.
        $pag = [ordered]@{ Mode = 'none' }
        if ($hasPageIdx) {
            $pag = [ordered]@{ Mode = 'pageSize'; ParamLocation = 'query'; PageSizeQuery = 'pageSize'; PageSize = 50
                PageIndexQuery = 'pageIndex'; PageIndexStart = $(if ($ev -and $ev.ContainsKey('PageIndexStart')) { $ev['PageIndexStart'] } else { 0 }); CursorMode = 'pageIndexIncrement'; LoopGuard = 1000 }
            if ($hasSort) { $pag['SortByQuery'] = 'sortByField'; $pag['SortOrderQuery'] = 'sortOrder'; $pag['SortOrder'] = 'Descending' }
            if ($shape -eq 'wrapper') { $pag['TotalCountPath'] = 'Count' }
        } elseif ($hasSkipTop) { $pag = [ordered]@{ Mode = 'skipTop'; ParamLocation = 'query'; SkipQuery = '$skip'; TopQuery = '$top'; PageSize = 50; LoopGuard = 1000 } }
        elseif ($respTokKey) {
            $tokKind = if ($respTokKey -imatch 'nextlink') { 'nextLink' } else { 'cursorToken' }
            $tokPath = if ($respTokKey -match '\.') { "`$['$respTokKey']" } else { "`$.$respTokKey" }
            $pag = [ordered]@{ Mode = 'cursor'; ParamLocation = 'query'; CursorMode = $tokKind; CursorPath = $tokPath; LoopGuard = 1000 }
            if ($tokKind -eq 'cursorToken') {
                $tokEcho = @($paramNames | Where-Object { $_ -iin @('skipToken','$skiptoken','continuationToken','nextPageToken') } | Select-Object -First 1)
                $pag['CursorQuery'] = if ($tokEcho.Count -gt 0) { [string]$tokEcho[0] } else { $respTokKey }
            }
        }

        # LiveCaptured eligibility · op has a captured RAW body in the evidence-index but NOT in live-evidence
        # (no behavioral PROOF). Excluded ops (write/official-duplicate) are NEVER promoted — Excluded overrides.
        $ei = $r['ei']
        $isLiveCaptured = ($null -eq $fixture) -and ($null -ne $ei) -and ($rec.ScopeDecision -ne 'Exclude')

        # ── Behavioral fields · LIVE-EVIDENCE ONLY (never fabricated · LiveCaptured stays null) ──
        if ($fixture) {
            $cursorField = if ($ev -and $ev.ContainsKey('CursorField')) { $ev['CursorField'] } elseif ($liveIsDict -and $liveFields.ContainsKey('EventTime')) { 'EventTime' } else { $null }
            $naturalKey  = if ($ev -and $ev.ContainsKey('NaturalKey')) { @($ev['NaturalKey']) } else { @() }
            $ingMode = 'SNAPSHOT'
            # CURSOR when a cursor field exists AND either (a) live-evidence EXPLICITLY proves IngestionMode=CURSOR (a
            # bucketed-date cursor like GetInsights/createdDate whose op name misses the keyword heuristic — its exactly-once
            # is the EO keyless RecordId boundary, NOT cursor uniqueness · F-KEYLESS-CURSOR), OR (b) the op name/summary
            # matches the time-series keyword heuristic (history/audit/events/log/timeline · the GetHistory family).
            $evCursorMode = ($ev -is [System.Collections.IDictionary]) -and $ev.ContainsKey('IngestionMode') -and ([string]$ev['IngestionMode'] -eq 'CURSOR')
            if ($cursorField -and ($evCursorMode -or ("$($rec.Operation) $($rec.Summary)" -imatch 'history|audit|events|log|timeline'))) { $ingMode = 'CURSOR' }
            $tfMode = if ($hasTimeParam) { 'ServerFromDate' } else { 'None' }
            if ($ingMode -eq 'CURSOR' -and -not $hasTimeParam) { $tfMode = 'ClientSideHighWater' }
            $cadence = switch ($ingMode) { 'CURSOR' { '00:05:00' } 'WINDOW' { '01:00:00' } default { '00:15:00' } }
            if ($hasPageIdx -and $hasSort -and $cursorField) { $pag['SortByField'] = $cursorField; $pag['StopWhenCursorPassed'] = ($ingMode -eq 'CURSOR') }
            $pm = [ordered]@{}
            if ($liveIsDict) { foreach ($f in ($liveFields.Keys | Sort-Object)) { $val = $liveFields[$f]; $isNonScalar = ($val -is [System.Collections.IDictionary]) -or ($val -is [System.Collections.IList]); $col = if ($isNonScalar) { "${f}Json" } else { Get-XdrSafeColumnName -Name $f }; $pm[$col] = '$.' + $f } }
            $rec['IngestionMode'] = $ingMode; $rec['CursorField'] = $cursorField; $rec['NaturalKey'] = $naturalKey
            $rec['TimeFilter'] = [ordered]@{ Mode = $tfMode; FieldName = $cursorField }; $rec['Cadence'] = $cadence; $rec['ProjectionMap'] = $pm
            $rec['ResponseShape'] = $shape; $rec['ItemsContainer'] = $itemsKey
        } elseif ($isLiveCaptured) {
            # ── tier-1 SCHEMA from a captured body · NO behavioral fields (those need live PROOF, absent here) ──
            # Parse the chosen RAW body and resolve its first item via the SHARED SHAPE ORACLE (Get-XdrBodyShape) —
            # the SAME classifier Build-EvidenceIndex used to write ResponseShape/ItemsContainer, so the ProjectionMap
            # is derived from the SAME record the runtime will fan out (a wrapper's first array element · a bare
            # array's first element · an MTO {result:{value:[...]}} nested list's first element · else the single
            # object itself). The Shape/ItemsContainer recorded below come from the oracle's re-read of the body, so
            # a wrapper whose array sits one level down (result.value) reports its LEAF key correctly. Same column
            # rules as the Validated path.
            $capFields = $null; $cbody = $null; $capShape = [string]$ei['ResponseShape']; $capItemsKey = $ei['ItemsContainer']
            $cfp = Join-Path $RepoRoot ([string]$ei['Fixture'])
            if (Test-Path $cfp) {
                $cbody = $null
                try { $cbody = Get-Content $cfp -Raw | ConvertFrom-Json -AsHashtable -Depth 25 } catch { $cbody = $null }
                if ($null -ne $cbody) {
                    $capO = Get-XdrBodyShape $cbody
                    $capShape = [string]$capO['Shape']; $capItemsKey = $capO['ItemsContainer']
                    $capFields = $capO['FieldUnion']   # F4 · union of fields across ALL items (not item[0]) · sparse fields faithful
                }
            }
            $capIsDict = $capFields -is [System.Collections.IDictionary]
            $pm = [ordered]@{}
            if ($capIsDict) { foreach ($f in ($capFields.Keys | Sort-Object)) { $val = $capFields[$f]; $isNonScalar = ($val -is [System.Collections.IDictionary]) -or ($val -is [System.Collections.IList]); $col = if ($isNonScalar) { "${f}Json" } else { Get-XdrSafeColumnName -Name ([string]$f) }; $pm[$col] = '$.' + $f } }
            # V5 (§21.1): MERGE waterfall. A LiveCaptured op whose captured body was an EMPTY list ({value:[]}) or a
            # scalar yields ZERO typed columns from the capture — rather than ship an envelope-only table, FALL THROUGH
            # to the OpenAPI (tier-2) then Postman (tier-3) schema (the SAME tiers the no-capture branch uses) so the
            # Recommended ops with an empty capture but an EXISTING spec schema get typed columns. The capture stays
            # AUTHORITATIVE when it has fields (live tier wins); this fills ONLY the empty-capture gap.
            $capTier = 'live'
            # A SCALAR live body (bool/number/non-empty string) IS the datum → project a single typed `Value` column
            # ('$' resolves to the whole body in Apply-XdrProjectionMap) instead of falling through to the stub spec
            # schema. {} / [] / null is NOT a scalar → stays empty → the spec waterfall below handles it.
            if ((@($pm.Keys).Count -eq 0) -and ($null -ne $cbody) -and ($cbody -isnot [System.Collections.IDictionary]) -and ($cbody -isnot [System.Collections.IList])) {
                $pm = [ordered]@{ Value = '$' }; $capShape = 'scalar'; $capItemsKey = $null
            }
            if (@($pm.Keys).Count -eq 0) {
                $capTier = 'none'
                # Tier-0 · a live shape-only DISCOVERY probe outranks the SYNTHETIC openapi/postman schema when the
                # EvidenceIndex capture was EMPTY (the camelCase-from-spec class · e.g. EndpointDevices.List: /ndr/machines
                # is PascalCase live but the captured fixture was empty → would fall to the openapi camelCase schema →
                # every JSONPath misses live → RawJson-only). A real probe of the live wire shape is ground truth → fill
                # ResponseShape/ItemsContainer/ProjectionMap from it (ProjectionTier='live') BEFORE the spec tiers. Mirrors
                # the no-capture branch's Tier-0 discovery step (same Get-XdrBodyShape oracle · no twin-drift · SPARSE:
                # $null when no shape fixture → byte-identical openapi/postman fallback for every op without one).
                $discoBodyE = Get-XdrDiscoveryShapeBody -RepoRoot $RepoRoot -PortalKey $portalKey -OperationId ([string]$rec.OperationId)
                if ($null -ne $discoBodyE) {
                    $discoOE = Get-XdrBodyShape $discoBodyE; $discoFuE = $discoOE['FieldUnion']; $discoPmE = [ordered]@{}
                    if ($discoFuE -is [System.Collections.IDictionary]) {
                        foreach ($fE in ($discoFuE.Keys | Sort-Object)) {
                            $dvE = $discoFuE[$fE]; $isNonScalarE = ($dvE -is [System.Collections.IDictionary]) -or ($dvE -is [System.Collections.IList])
                            $colE = if ($isNonScalarE) { "${fE}Json" } else { Get-XdrSafeColumnName -Name ([string]$fE) }
                            $discoPmE[$colE] = '$.' + $fE
                        }
                    }
                    if (@($discoPmE.Keys).Count -gt 0) { $pm = $discoPmE; $capTier = 'live'; $capShape = [string]$discoOE['Shape']; $capItemsKey = $discoOE['ItemsContainer'] }
                }
                $capSo = $null   # singleObject OpenAPI · DEFERRED to last-resort (postman outranks · A-class guard)
                if ((@($pm.Keys).Count -eq 0) -and $specOp -and $specOp['respSchema']) {
                    $capItemSchema = Get-XdrResponseItemSchema $specOp['respSchema'] $specOp['spec'] $specOp['specDir']
                    if (($capItemSchema -is [System.Collections.IDictionary]) -and $capItemSchema.Contains('singleObject')) { $capSo = $capItemSchema }
                    else { $capPmSpec = Get-XdrSchemaProjectionMap $capItemSchema; if (@($capPmSpec.Keys).Count -gt 0) { $pm = $capPmSpec; $capTier = 'openapi' } }
                }
                if (@($pm.Keys).Count -eq 0) {
                    $capPmCol = Join-Path $RepoRoot $Reg.PostmanRel
                    $capPmPost = Get-XdrPostmanProjectionMap $capPmCol ([string]$r['fullPath']) $rec.Method
                    if (@($capPmPost.Keys).Count -gt 0) { $pm = $capPmPost; $capTier = 'postman' }
                }
                if (@($pm.Keys).Count -eq 0 -and $capSo) {
                    $capPmSo = Get-XdrSchemaProjectionMap $capSo
                    if (@($capPmSo.Keys).Count -gt 0) { $pm = $capPmSo; $capTier = 'openapi' }
                }
                # Materialize FRESH (copy entries) so a function-returned collection is never stored directly — an empty
                # one can serialize as its .NET reflection members instead of {} (same guard as the no-capture branch).
                $pmFresh = [ordered]@{}
                if (($pm -is [System.Collections.IDictionary]) -and (@($pm.Keys).Count -gt 0)) { foreach ($pk in $pm.Keys) { $pmFresh[[string]$pk] = $pm[$pk] } }
                $pm = $pmFresh
            }
            # Cursor-field CANDIDATE only (NOT authoritative) · surfaced if an EventTime/Timestamp-like column exists.
            $cursorCand = $null
            if ($capIsDict) { foreach ($cf in @('EventTime','Timestamp','TimeGenerated','CreatedTime','LastUpdateTime','LastSeen','LastUpdated','GeneratedTime')) { if ($capFields.ContainsKey($cf)) { $cursorCand = $cf; break } } }
            # Behavioral fields stay NULL — LiveCaptured proves SCHEMA, not ingestion behavior.
            $rec['IngestionMode'] = $null; $rec['CursorField'] = $null; $rec['NaturalKey'] = @()
            $rec['TimeFilter'] = $null; $rec['Cadence'] = $null
            $rec['CursorFieldCandidate'] = $cursorCand
            # T4-PROJ honesty: record the TRUE projection source. The empty-capture branch falls back to the OpenAPI
            # (tier-2) / Postman (tier-3) SYNTHETIC schema; hardcoding 'live' here LIED (hid the camelCase-from-spec
            # class — e.g. GetPending — from every gate). $capTier = live | openapi | postman | none.
            $rec['ProjectionMap'] = $pm; $rec['ProjectionTier'] = $capTier
            $rec['ResponseShape'] = $(if ($capShape) { $capShape } else { $null }); $rec['ItemsContainer'] = $capItemsKey
        } else {
            # NO capture → no behavioral guess (IngestionMode/Cadence/CursorField/NaturalKey stay LIVE-ONLY). Pagination
            # (spec-derived) stays. ProjectionMap (typed cols) gains a waterfall: live-shape(discovery) > live(none) > openapi > postman > empty.
            $rec['IngestionMode'] = $null; $rec['CursorField'] = $null; $rec['NaturalKey'] = @()
            $rec['TimeFilter'] = $null; $rec['Cadence'] = $null
            $rec['ResponseShape'] = $null; $rec['ItemsContainer'] = $null
            # Tier 0 · SHAPE-ONLY DISCOVERY capture (live ground truth · highest priority) · an op with a portal-internal
            # shape-only capture (references/live/<portalKey>/discovery/<OperationId>.json · the GET-only probe output)
            # has NO source-mvp-fixtures body and NO usable spec item-schema (the nodoc list items are typeless stubs →
            # empty projection → RawJson-only). Reconstruct a representative real-valued body from the shape tokens and
            # classify it with the SAME shared oracle the live-captured branch uses → born-correct ResponseShape +
            # ItemsContainer + field-union ProjectionMap (ProjectionTier='live'), so the per-item columns are typed at
            # source (curation.columnTypes) instead of landing RawJson-only. SPARSE/additive: $null when no shape fixture
            # → falls through to the openapi/postman waterfall below (every op without a shape is byte-identical). The
            # behavioral fields stay null (a shape proves SCHEMA, not the live exactly-once chain · same honesty as LiveCaptured).
            $discoveryHandled = $false
            $discoBody = Get-XdrDiscoveryShapeBody -RepoRoot $RepoRoot -PortalKey $portalKey -OperationId ([string]$rec.OperationId)
            if ($null -ne $discoBody) {
                $discoO = Get-XdrBodyShape $discoBody
                $rec['ResponseShape'] = [string]$discoO['Shape']; $rec['ItemsContainer'] = $discoO['ItemsContainer']
                $discoPm = [ordered]@{}
                $discoFu = $discoO['FieldUnion']
                if ($discoFu -is [System.Collections.IDictionary]) {
                    foreach ($f in ($discoFu.Keys | Sort-Object)) {
                        $dv = $discoFu[$f]
                        $isNonScalar = ($dv -is [System.Collections.IDictionary]) -or ($dv -is [System.Collections.IList])
                        $col = if ($isNonScalar) { "${f}Json" } else { Get-XdrSafeColumnName -Name ([string]$f) }
                        $discoPm[$col] = '$.' + $f
                    }
                }
                $rec['ProjectionMap'] = $discoPm
                # ProjectionTier='live' when the shape yielded item fields; an EMPTY-on-lab capture (0 rows · shape <null>
                # or empty wrapper) yields no fields → RawJson floor (tier 'none'), still honest (live-confirmed-empty).
                $rec['ProjectionTier'] = if (@($discoPm.Keys).Count -gt 0) { 'live' } else { 'none' }
                $discoveryHandled = $true
            }
            if (-not $discoveryHandled) {
            # WS2.3 · postman saved-response SHAPE evidence: a 200 example proves the response container shape even
            # when it carries zero items ("[]" ⇒ bareArray) — so the F4 conservative singleObject default never
            # mislabels a proven array. Honest: shape only; fields/behavior still need their own evidence.
            $pmRespRaw = Get-XdrPostmanResponseBody (Join-Path $RepoRoot $Reg.PostmanRel) ([string]$r['fullPath']) ([string]$rec.Method)
            if ($pmRespRaw) {
                $pmRespBody = $null
                # -NoEnumerate: an EMPTY array example ("[]") must survive as an array — the pipeline would unwrap
                # it to $null and silently drop the exact shape evidence this tier exists for.
                try { $pmRespBody = $pmRespRaw | ConvertFrom-Json -AsHashtable -Depth 25 -NoEnumerate } catch { $pmRespBody = $null }
                if ($null -ne $pmRespBody) {
                    $pmRespO = Get-XdrBodyShape $pmRespBody
                    if ($pmRespO['Shape']) { $rec['ResponseShape'] = [string]$pmRespO['Shape']; $rec['ItemsContainer'] = $pmRespO['ItemsContainer'] }
                }
            }
            $pmTier = 'none'; $pm = [ordered]@{}
            # NOTE · use .Keys.Count NOT .Count: an item property literally named 'Count' SHADOWS the dictionary's
            # own .Count member on OrderedDictionary/hashtable (member-vs-key collision) → returns '$.Count' not the size.
            # Tier 2 · OpenAPI · derive from the op's 200-response ITEM schema (allOf/array/wrapper · local + cross-file $ref).
            $soSchema = $null   # a singleObject OpenAPI schema · DEFERRED to the last-resort below (postman outranks it · A-class guard)
            if ($specOp -and $specOp['respSchema']) {
                $itemSchema = Get-XdrResponseItemSchema $specOp['respSchema'] $specOp['spec'] $specOp['specDir']
                if (($itemSchema -is [System.Collections.IDictionary]) -and $itemSchema.Contains('singleObject')) { $soSchema = $itemSchema }
                else { $pm = Get-XdrSchemaProjectionMap $itemSchema; if (@($pm.Keys).Count -gt 0) { $pmTier = 'openapi' } }
            }
            # Tier 3 · Postman · OPTIONAL best-effort (collection may be absent → empty map, never throws).
            # Pass the FULL path (SubPortal + Path) · the collection reconstructs request paths from ALL url segments
            # (incl. the sub-portal segment), so the SubPortal-stripped $rec.Path never matched → tier-3 silently empty.
            # (Latent until A5: the old broken PostmanRel filename made the function return at Test-Path regardless.)
            if (@($pm.Keys).Count -eq 0) {
                $pmCol = Join-Path $RepoRoot $Reg.PostmanRel
                $pm = Get-XdrPostmanProjectionMap $pmCol ([string]$r['fullPath']) $rec.Method
                if (@($pm.Keys).Count -gt 0) { $pmTier = 'postman' }
            }
            # Tier 2b · singleObject OpenAPI LAST-RESORT · runs ONLY when live + openapi-item + postman are ALL empty, so it
            # NEVER overrides a real postman example (A-class guard: an inaccurate nodoc singleObject spec must not beat a
            # real captured response · proven by the ListTenants / CloudApps.GetSettings regression 2026-06-24).
            if (@($pm.Keys).Count -eq 0 -and $soSchema) {
                $pm = Get-XdrSchemaProjectionMap $soSchema
                if (@($pm.Keys).Count -gt 0) { $pmTier = 'openapi' }
            }
            # Tier 4 · empty (RawJson is the runtime floor).
            # Materialize a FRESH ordered dictionary (copy entries) so the stored ProjectionMap is never a
            # function-returned collection reference — an empty one of those can intermittently serialize via
            # ConvertTo-Json as its .NET reflection members (Count/Length/Rank/…) instead of {} in the full graph.
            $pmFinal = [ordered]@{}
            if (($pm -is [System.Collections.IDictionary]) -and (@($pm.Keys).Count -gt 0)) { foreach ($pk in $pm.Keys) { $pmFinal[[string]$pk] = $pm[$pk] } }
            $rec['ProjectionMap'] = $pmFinal
            $rec['ProjectionTier'] = $pmTier
            }   # end if (-not $discoveryHandled) · the openapi/postman waterfall is SKIPPED when a discovery shape supplied the projection
        }
        # ── LIVE-EVIDENCE behavioral OVERRIDE (authoritative · "live > openapi" per live-evidence.json _comment) ──
        # NaturalKey/CursorField are LIVE-PROVEN behavioral facts (count==dcount under real cadence · ProvenUtc in
        # live-evidence.json) and are INDEPENDENT of a schema Fixture — a SNAPSHOT op proven keyed by count==dcount
        # needs NO captured-body fixture (the fixture only drives ProjectionMap). The Decide branch above consumed $ev
        # ONLY when a Fixture was present (the GetHistory path), so a keyed SNAPSHOT op WITHOUT a fixture silently lost
        # its proven NaturalKey -> empty RecordId + unprovable exactly-once (live-caught cat-1 2026-06-16). Apply the
        # override HERE, after the branch, so live-evidence wins for EVERY status (Validated/LiveCaptured/OpenApiDerived)
        # and EVERY category. Set ONLY from live-proof; F4's conservative default never overwrites a non-null NaturalKey.
        # Set ONLY NaturalKey (the live-proven fact). Leave IngestionMode/TimeFilter/Cadence to the branch + the F4
        # conservative-default pass — F4 never overwrites a NON-NULL NaturalKey, and setting IngestionMode HERE would
        # preempt F4 and silently drop its TimeFilter default (caught 2026-06-16). For a future keyless->CURSOR proof
        # without a fixture, extend live-evidence with a Fixture (the GetHistory path already handles CursorField).
        if ($ev -and $ev.ContainsKey('NaturalKey') -and @($ev['NaturalKey']).Count -gt 0) {
            $rec['NaturalKey'] = @($ev['NaturalKey'])
        }
        if (-not $rec.Contains('ProjectionTier')) { $rec['ProjectionTier'] = 'live' }

        # WS2.3 · EvidenceTier · the op-level STRONGEST-evidence label (provenance for the per-field waterfall):
        # live-evidence (behavioral fixture) > live-captured (raw body, schema-only) > postman-example (saved 200
        # response · shape±fields) > openapi-schema (spec 200 schema) > conservative (no source · F4 defaults +
        # RawJson floor; the op SELF-HEALS once its first landed rows become live evidence). Never fabricated —
        # the label states where the schema/shape actually came from.
        $rec['EvidenceTier'] = $(
            if ($fixture) { 'live-evidence' }
            elseif ($isLiveCaptured) { 'live-captured' }
            elseif ((Get-XdrPostmanResponseBody (Join-Path $RepoRoot $Reg.PostmanRel) ([string]$r['fullPath']) ([string]$rec.Method))) { 'postman-example' }
            elseif ($specOp -and $specOp['respSchema']) { 'openapi-schema' }
            else { 'conservative' }
        )

        # G-A · derive BodyTemplate for read-via-POST ops (the spec carries no request body · Postman is the only source).
        # Sets $rec['BodyTemplate'] ONLY when a REAL non-garbage body exists → feeds the ship-gate's pollable clause
        # (GET -or BodyTemplate). Ships 0 today (corpus telemetry-POST bodies are key_N/empty · §2 G-A) · never fabricates.
        if (([string]$rec['Method'] -ne 'GET') -and ($rec.ScopeDecision -ne 'Exclude') -and ([string]$rec['ReadSemantics'] -in @('Read', 'ReadViaPost'))) {
            $bt = Get-XdrPostmanBodyTemplate (Join-Path $RepoRoot $Reg.PostmanRel) ([string]$r['fullPath']) ([string]$rec['Method'])
            if ($bt) { $rec['BodyTemplate'] = $bt }
        }

        $captureFixture = $(if ($isLiveCaptured) { [string]$ei['Fixture'] } else { $null })
        $rec['Pagination'] = $pag
        # RequiresProducts PER-SubPortal (C6 · license-independence · DATA-driven curation `subPortalProducts` map).
        # Replaces the blanket per-portal MDE that broke every MDI/MCAS/MDO-only tenant. Each SubPortal -> its real
        # product(s): mtp->MDE · mcas->MCAS · mdi/aatp/radius->MDI · mdc->MDC · apiproxy/securityplatform->Sentinel ·
        # mtoapi->MTO · astgws->MDO · m365appprotection->MAPG · etc. UNMAPPED SubPortal -> portal default. Non-
        # derivable products (MCAS/MTO have no clean tenant flag) FAIL-OPEN at the dispatch gate (attempt->posture),
        # never a dead gate. [] (msgraph/shell/gws) -> always attempt.
        $rec['RequiresProducts'] = $(if ($script:XdrSubPortalProducts.ContainsKey([string]$rec['SubPortal'])) { @($script:XdrSubPortalProducts[[string]$rec['SubPortal']]) } else { @($Reg.RequiresProducts) })
        $rec['DcrStreamName'] = $streamName; $rec['WorkspaceTable'] = $tableName
        $rec['Evidence'] = [ordered]@{ live = [bool]$fixture; liveCaptured = [bool]$isLiveCaptured; openapi = [bool]$specOp; fixture = $(if ($fixture) { $fixture } else { $captureFixture }) }
        $rec['Provenance'] = [ordered]@{
            OperationId = $rec.OperationId; Live = $fixture; LiveCapture = $captureFixture; Postman = $Reg.PostmanRel
            OpenApi = $(if ($specOp) { "references/openapi/$portalKey/specification/$($r['cat']).yml#$($rec.OperationId)" } else { $null }); DerivedUtc = '2026-06-04T00:00:00Z'
        }
        # Status precedence (HONESTY LOCK §4.D) · Validated (op in $XdrLiveProven · live-proven exactly-once in prod)
        # > Excluded (write/official-duplicate) > LiveCaptured (real response captured · SCHEMA proof, NOT live-proven)
        # > OpenApiDerived (spec) > StructuralOnly. A captured fixture alone is LiveCaptured, never Validated.
        $rec['Status'] = $(if ($script:XdrLiveProven -contains $rec.OperationId) { 'Validated' } elseif ($rec.ScopeDecision -eq 'Exclude') { 'Excluded' } elseif ($isLiveCaptured -or $fixture) { 'LiveCaptured' } elseif ($specOp) { 'OpenApiDerived' } else { 'StructuralOnly' })

        # ── SELECT · per-op RANKING signals (plan A3) · ADDITIVE · these NEVER remove an op ──────────────────────────
        # The onboarding loop uses these to PICK the next category one-at-a-time; they do NOT gate the catalogue.
        $selFull = [string]$r['fullPath']
        $officialOverlap = Get-OfficialApiOverlap $rec.TelemetryClass $selFull            # None | Likely | Exact
        $valueClass      = Get-ValueClass $rec.Operation $rec.Summary $rec.Method $selFull # Core/Config/Reference/UiHelper/Noise
        $hasTimeOrCursor = ($hasTimeParam) -or ($pag.Mode -ne 'none')                      # time filter OR pagination cursor param
        # SelectionScore (0-100) · weighted sum of the five signals + a time/cursor bonus, then clamped.
        $score = 0
        $score += switch ($rec.ReadSemantics) { 'Read' { 30 } 'ReadViaPost' { 20 } default { 0 } }       # Write → 0
        $score += switch ($officialOverlap)   { 'None' { 25 } 'Likely' { 5 } default { 0 } }              # Exact → 0
        $score += $(if ($null -eq $rec.DuplicateClass) { 20 } else { 0 })                                  # non-canonical/dup → 0
        $score += switch ($valueClass) { 'CoreTelemetry' { 25 } 'ConfigState' { 18 } 'Reference' { 6 } 'UiHelper' { 2 } default { 0 } }
        if ($hasTimeOrCursor) { $score += 10 }
        if ($score -lt 0) { $score = 0 } elseif ($score -gt 100) { $score = 100 }                          # clamp 0-100
        # SelectionConfidence · how strongly the signals are grounded in evidence.
        $selConfidence = $(if ($rec.Status -in @('Validated','LiveCaptured')) { 'LiveConfirmed' } elseif ($specOp) { 'SpecConfirmed' } else { 'Heuristic' })
        # Hard-0 component ⇒ a structural disqualifier exists (write semantics · Exact official-duplicate · any duplicate
        # class). Recommended is a HINT only (≥60 and no hard-0) — it MUST NOT remove anything from the catalogue.
        $hasHardZero = ($rec.ReadSemantics -eq 'Write') -or ($officialOverlap -eq 'Exact') -or ($null -ne $rec.DuplicateClass)
        $rec['OfficialApiOverlap']  = $officialOverlap
        $rec['ValueClass']          = $valueClass
        $rec['SelectionScore']      = $score
        $rec['SelectionConfidence'] = $selConfidence
        $rec['Recommended']         = (($score -ge 60) -and -not $hasHardZero)
        # V6 (§21) · DYNAMIC VALUE SHIP-GATE — the JOIN between value-selection and shipping (operator: "filter
        # verified manual at cataloguing · value not just functionality"). An op SHIPS iff it is telemetry-grade VALUE
        # (CoreTelemetry/ConfigState · after the manual-verified override) AND includable AND pollable (GET, or POST
        # with a BodyTemplate). UiHelper/Noise/Reference + write/official-dup + entity-fanout-POST-without-body stay
        # CATALOGUED but NOT shipped (onboardable later · nothing deleted). Generate-Manifest filters on Shipped.
        $opId = [string]$rec['OperationId']
        $effValueClass = if ($opId -and $script:XdrValueOverrides.ContainsKey($opId)) { $script:XdrValueOverrides[$opId] } else { [string]$valueClass }
        # EVIDENCE PROMOTION (operator 2026-06-21 · the LIVE evidence overrides a keyword miss · generic, all categories):
        # the name-heuristic is keyword-only and WILL miss real telemetry (it missed the whole MDE machine* family + read-
        # POST config). A Noise op that is LIVE-CAPTURED with a rich projection (>=5 real fields) OR offered by the official
        # API (OfficialApiOverlap=Likely) is value the heuristic mis-scored → promote to CoreTelemetry. An explicit curation
        # valueClass override still wins (applied above, so this only fires when no operator override). Never touches a
        # write/Exclude op (those are gated out of Shipped downstream regardless). This is the consolidation rule: ship
        # decision = live-probe ∪ openapi ∪ postman ∪ official-API, not keywords alone.
        $pmCount = if ($rec['ProjectionMap']) { @($rec['ProjectionMap'].Keys).Count } else { 0 }
        if ($effValueClass -eq 'Noise' -and (-not ($opId -and $script:XdrValueOverrides.ContainsKey($opId))) -and
            ($rec.Status -in @('Validated','LiveCaptured')) -and (($pmCount -ge 5) -or ($officialOverlap -eq 'Likely'))) {
            $effValueClass = 'CoreTelemetry'
        }
        $rec['EffectiveValueClass'] = $effValueClass
        # POLLABLE: GET is pollable as-is. A POST ships ONLY as a CURATED read-only-post — BodyTemplate present AND
        # ProbeMode='ReadOnlyPost' — matching the binding scope validator (Validate-Scope Rule 21 · :122-130). A
        # corpus-DERIVED BodyTemplate alone is NOT sufficient: captured POST bodies are template-garbage (random
        # pageIndex/pageSize · one-off ad-hoc queries) that poll empty/error. So a POST stays CATALOGUED-not-shipped
        # until its body is VERIFIED and it is explicitly ProbeMode='ReadOnlyPost'-asserted (curation · §22-pollable).
        # Keeps the ship-gate and the scope validator from ever disagreeing (single scope truth).
        $shipPollable = ([string]$rec['Method'] -eq 'GET') -or ($rec.Contains('BodyTemplate') -and $rec['BodyTemplate'] -and ([string]$rec['ProbeMode'] -eq 'ReadOnlyPost'))
        $rec['ShipHeldReason'] = if ($opId -and $script:XdrShipHold.ContainsKey($opId)) { [string]$script:XdrShipHold[$opId] } else { $null }
        # §22 · POLLABLE-NOW gate: an entity op ({CaseId}-gated) ships ONLY when its parent linkage is Resolved — else the
        # runtime can't build the URL (dead columns). Unresolved/Pending entity ops stay CATALOGUED and onboard when the
        # parent's live response reveals the id field (discover/adjust as we go · §22.5). NotEntity/Resolved both pollable.
        $entityPollable = [string]$rec['EntityResolution'] -in @('NotEntity', 'Resolved')
        # §22-pollable (query) · an op with an unsatisfied required QUERY param (RequiredQueryParams set above) cannot be
        # polled autonomously (400 EVERY cycle) → HOLD, exactly like an Unresolved entity. Sparse field → Contains() test.
        $queryParamPollable = -not $rec.Contains('RequiredQueryParams')
        $rec['Shipped'] = ($effValueClass -in @('CoreTelemetry', 'ConfigState')) -and ([string]$rec['ScopeDecision'] -ne 'Exclude') -and $shipPollable -and $entityPollable -and $queryParamPollable -and (-not $rec['ShipHeldReason'])
        # F4 (§21.7) · BEHAVIORAL-DERIVATION TIER — a Shipped op with NO live-proven IngestionMode (LiveCaptured /
        # OpenApiDerived) must still be POLLABLE. Assign CONSERVATIVE, never-fabricated defaults: SNAPSHOT (full
        # re-emit · needs no cursor/NaturalKey), a conservative cadence, ResponseShape = the captured shape if present
        # else singleObject (the RawJson-floor-safe default that never drops data · arrays fold to <Name>Json). Tagged
        # derived-conservative; the X-phase LIVE capture upgrades it to the real CURSOR/shape and promotes to Validated.
        & $applyConservativeDefaults $rec   # F4 · conservative defaults (helper atop Build-PortalCatalogue · re-applied post-DEPEND G-H)

        # ── CADENCE-vs-VOLUME advisory (plan U5) · ADVISE / auto-correct · NEVER refuse ──────────────────────────────
        # RowCount source: evidence-index captured-page size (both Validated + LiveCaptured ops have an $ei record when
        # captured) · fall back to the Validated fixture's own item count. A cursor CANDIDATE (Validated CursorField, or
        # the LiveCaptured CursorFieldCandidate) lets the advice prefer CURSOR over merely slowing a SNAPSHOT.
        $cvRowCount = $null
        if ($null -ne $ei -and $ei.Contains('RowCount')) { $cvRowCount = [int]$ei['RowCount'] }
        elseif ($null -ne $liveRowCount) { $cvRowCount = [int]$liveRowCount }
        $cvCursorCand = if ($rec.Contains('CursorField') -and $rec.CursorField) { [string]$rec.CursorField }
                        elseif ($rec.Contains('CursorFieldCandidate') -and $rec.CursorFieldCandidate) { [string]$rec.CursorFieldCandidate }
                        else { $null }
        $advice = Get-CadenceVolumeAdvice -IngestionMode $rec.IngestionMode -Cadence $rec.Cadence -RowCount $cvRowCount -CursorFieldCandidate $cvCursorCand
        if ($null -ne $advice) {
            # AUTO-CORRECT (honest · evidence-free): a Validated SNAPSHOT op churning at a fast cadence on high volume
            # gets its CADENCE slowed in place (NEVER its mode flipped — that needs a proven CursorField). The op is
            # never dropped. Record the original so the correction is auditable. CURSOR ops + LiveCaptured (null mode)
            # are advisory-only. No Defender op trips this today (GetHistory is CURSOR); the path exists for any future op.
            if (($advice.Fit -eq 'AdviseSlowerCadence') -and ($rec.IngestionMode -eq 'SNAPSHOT') -and $rec.Cadence -and $advice.SuggestedCadence) {
                $rec['CadenceVolumeAutoCorrected'] = [ordered]@{ Field = 'Cadence'; From = [string]$rec.Cadence; To = [string]$advice.SuggestedCadence; Reason = $advice.Reason }
                $rec['Cadence'] = [string]$advice.SuggestedCadence
            }
            # FH-2: the raw CadenceVolumeAdvice object is NOT persisted into the canonical catalogue. It is
            # informational-only (grep-confirmed write-only · no Generate-Manifest / gate / runtime reader) and its
            # free-text Reason prose was the dominant source of catalogue regen->diff instability (132/133 of the
            # Defender drift). The ACTIONABLE result is already captured deterministically above as
            # CadenceVolumeAutoCorrected (the cadence is slowed in place); a future -Report flag can re-emit the full
            # advisory to a sidecar if an operator wants it — but it never belongs in the diff-pinned canonical SoT.
        }

        $out += $rec
    }

    # ---- Stage 4 · DEPEND · entity parent→child edges (plan §16 U3b · §4.H · G‑P) · ADDITIVE · post‑Map ----
    # Runs after Map so every parent candidate's ProjectionMap (its response item fields) is populated to match a
    # child {param} against. Mutates each ENTITY rec's DependsOn + EntityResolution in place; non‑entity ops (incl.
    # ActionCenter.GetHistory) are NEVER touched (DependsOn stays null · EntityResolution='NotEntity'). Deterministic.
    Set-XdrDependsOnEdges -Records $out

    # Curation itemsContainer OVERRIDE (post-DEPEND) · force the list-envelope key the shape oracle missed so the runtime
    # UNWRAPS $.<key> (0 rows when empty) instead of emitting the wrapper as one dup-accumulating row. Generic · keyed by
    # OperationId · sets ItemsContainer + ResponseShape='wrapper'. (Projection re-derivation from a data-present capture is
    # a tracked follow-up; for the empty case 0 items ⇒ 0 rows, so the thin projection is moot.)
    $icOvr = if ($script:XdrCuration -and $script:XdrCuration.Contains('ItemsContainer')) { $script:XdrCuration['ItemsContainer'] } else { @{} }
    if ($icOvr -and $icOvr.Count -gt 0) {
        foreach ($rec in $out) {
            $k = $icOvr[[string]$rec['OperationId']]
            if ($k) { $rec['ItemsContainer'] = [string]$k; $rec['ResponseShape'] = 'wrapper' }
        }
    }

    # Curation responseShape OVERRIDE (post-DEPEND · the INVERSE of itemsContainer) · force ResponseShape='singleObject' +
    # clear ItemsContainer and RE-derive the ProjectionMap from the FULL top-level body, so a config-posture body the shape
    # oracle mis-classified as a wrapper (a sole array beside a metadata-NAMED scalar) keeps its top-level posture scalar(s)
    # — ONE row always emits — instead of unwrapping the array per-element and DROPPING the scalar (0 rows when the array is
    # empty · the A2 dropped-wrapper-scalar class · live-caught GetDiscoveryEnabledTags). Re-derivation uses Get-XdrFieldUnion
    # over the whole body (the SAME projection the oracle's singleObject branch builds: scalars -> typed col · nested
    # arrays/objects -> '<key>Json') from the live capture, so it is live-grounded, not fabricated. Runs after the
    # itemsContainer override (mutually exclusive curation per op) and before the Stage-5 ship-gate, so Shape/projection are
    # final when shipping re-decides. Generic · keyed by OperationId.
    $rsOvr = if ($script:XdrCuration -and $script:XdrCuration.Contains('ResponseShape')) { $script:XdrCuration['ResponseShape'] } else { @{} }
    if ($rsOvr -and $rsOvr.Count -gt 0) {
        foreach ($rec in $out) {
            $opId = [string]$rec['OperationId']
            $rsShape = [string]$rsOvr[$opId]
            if ($rsShape -notin @('singleObject','bareArray')) { continue }
            $rec['ResponseShape'] = $rsShape; $rec['ItemsContainer'] = $null
            # bareArray override (the empty-array case the shape oracle defaults to singleObject · live-caught
            # ListThreatIndicators: real shape is a bare array `[{indicator}…]`, but the empty-tenant `[]` capture
            # mis-derives singleObject → on a tenant WITH IOCs the whole array emits as ONE RawJson row, all typed
            # cols NULL · the A2 array-as-one-row class). The body IS an array of items → the existing per-item
            # ProjectionMap applies per-element → do NOT re-derive from the whole/empty body. Only singleObject
            # re-derives a top-level-posture projection (below).
            if ($rsShape -eq 'bareArray') { continue }
            # Re-derive the projection from the captured body as ONE record (the singleObject FieldUnion · faithful to live).
            $rsEi = $evIndex[$opId]
            if (($rsEi -is [System.Collections.IDictionary]) -and $rsEi.Contains('Fixture')) {
                $rsFp = Join-Path $RepoRoot ([string]$rsEi['Fixture'])
                if (Test-Path $rsFp) {
                    $rsBody = $null
                    try { $rsBody = Get-Content $rsFp -Raw | ConvertFrom-Json -AsHashtable -Depth 25 } catch { $rsBody = $null }
                    if ($rsBody -is [System.Collections.IDictionary]) {
                        $rsFields = Get-XdrFieldUnion @($rsBody)   # whole object as a 1-item list → its top-level field union
                        if ($rsFields -is [System.Collections.IDictionary]) {
                            $rsPm = [ordered]@{}
                            foreach ($f in ($rsFields.Keys | Sort-Object)) {
                                $val = $rsFields[$f]
                                $isNonScalar = ($val -is [System.Collections.IDictionary]) -or ($val -is [System.Collections.IList])
                                $col = if ($isNonScalar) { "${f}Json" } else { Get-XdrSafeColumnName -Name ([string]$f) }
                                $rsPm[$col] = '$.' + $f
                            }
                            if (@($rsPm.Keys).Count -gt 0) { $rec['ProjectionMap'] = $rsPm; $rec['ProjectionTier'] = 'live' }
                        }
                    }
                }
            }
        }
    }

    # ---- Stage 5 · RE-DECIDE Shipped AFTER DEPEND (G-H fix) · the ship-gate's twin, over FINAL EntityResolution ----
    # The in-loop §22 ship-gate ran while every entity op was still 'Pending' (:754 · pre-DEPEND), so its
    # $entityPollable gate was ALWAYS false for entity ops → Resolved entity GETs (e.g. EndpointDevices.Get-
    # MachineTimelineEvents · ExposureManagement.GetPostureOversightInitiative) were silently un-shipped, leaving
    # the catalogue self-inconsistent (EntityResolution='Resolved' yet Shipped=$false). Set-XdrDependsOnEdges above
    # is the ONLY place EntityResolution becomes final, so Shipped is recomputed here over the SAME generic formula
    # (EffectiveValueClass + ScopeDecision + pollable + entity-pollable + ShipHeldReason · mirrors :1009/:1014/:1015),
    # then the F4 conservative defaults are (idempotently) re-applied. NotEntity ops are untouched by DEPEND so this
    # is a no-op for them; entity ops can only GAIN Shipped (Pending→Resolved · monotonic · proven, never lose it).
    # Generic · zero per-op logic · the entity-fanout cadence/volume of any newly-shipped op is tuned at X-phase live.
    foreach ($rec in $out) {
        $shipPollableFinal   = ([string]$rec['Method'] -eq 'GET') -or ($rec.Contains('BodyTemplate') -and $rec['BodyTemplate'] -and ([string]$rec['ProbeMode'] -eq 'ReadOnlyPost'))   # POST ships ONLY as curated ReadOnlyPost (corpus bodies are capture-garbage) · TWIN of the in-loop :1394 gate · matches Validate-Scope Rule 21 (single scope truth)
        $entityPollableFinal = [string]$rec['EntityResolution'] -in @('NotEntity', 'Resolved')
        $queryParamPollableFinal = -not $rec.Contains('RequiredQueryParams')   # §22-pollable (query) · twin of the in-loop gate
        $rec['Shipped'] = ([string]$rec['EffectiveValueClass'] -in @('CoreTelemetry', 'ConfigState')) -and
                          ([string]$rec['ScopeDecision'] -ne 'Exclude') -and $shipPollableFinal -and $entityPollableFinal -and
                          $queryParamPollableFinal -and (-not $rec['ShipHeldReason'])
        & $applyConservativeDefaults $rec

        # G-C/G-D · WINDOW for a SHIPPED op exposing a from+to time-window query PAIR (Postman · the spec carries none).
        # HONESTY LOCK §4.D: ONLY shipped/proven ops carry derived runtime config, so this is gated on the FINAL Shipped
        # (recomputed just above) and lives HERE, post-DEPEND — NOT in the record loop, where non-shipped ops (e.g.
        # ActionCenter.ExportHistory · LiveCaptured-unshipped) would be fabricated. Recompute the pair from the O(1)
        # Postman index; override F4's conservative SNAPSHOT/None with the verified runtime contract (Resolve-XdrTimeWindow
        # + ServerFromDate URL injection · Runtime.psm1:1721-1733,:1841-1898). ResponseShape/NaturalKey stay as F4 set them.
        if ($rec['Shipped']) {
            $pmQ = Get-XdrPostmanQueryParams (Join-Path $RepoRoot $Reg.PostmanRel) ([string]$rec['SubPortal'] + [string]$rec['Path']) ([string]$rec['Method'])
            $wf  = @($pmQ | Where-Object { $_ -imatch '^(fromDate|fromUtc|startTime|startDateTime|startDate)$' }) | Select-Object -First 1
            $wt  = @($pmQ | Where-Object { $_ -imatch '^(toDate|toUtc|endTime|endDateTime|endDate)$' })           | Select-Object -First 1
            if ($wf -and $wt) {
                $rec['IngestionMode'] = 'WINDOW'
                $rec['TimeFilter']    = [ordered]@{ Mode = 'ServerFromDate'; FieldName = [string]$wf; FromDateParam = [string]$wf; ToDateParam = [string]$wt; ParamLocation = 'query' }
                $rec['LookbackHours'] = 24
                $rec['Cadence']       = '01:00:00'
            }
            # T3e · curation timeFilter override (operator-verified DATA · the ONE behavioral seam · same Shipped
            # honesty-gate as the heuristic above). Applied AFTER the from/to heuristic so curation WINS where both
            # speak — the operator's verified contract (OData filter field · wire ValueFormat · relative param ·
            # CursorPrecision · LookbackHours) corrects what no heuristic can see. Keys were allow-list-validated at
            # load (Import-XdrCuration); Entry-root knobs split out, the rest merge into the TimeFilter block.
            $tfoRow = $script:XdrCuration.TimeFilterOverrides[[string]$rec['OperationId']]
            if ($tfoRow -is [System.Collections.IDictionary]) {
                $tfBlock = if ($rec['TimeFilter'] -is [System.Collections.IDictionary]) { $rec['TimeFilter'] } else { [ordered]@{} }
                foreach ($k in $tfoRow.Keys) {
                    switch ($k) {
                        'LookbackHours'   { $rec['LookbackHours']   = [int]$tfoRow[$k] }
                        'CursorPrecision' { $rec['CursorPrecision'] = [string]$tfoRow[$k] }
                        default           { $tfBlock[$k] = $tfoRow[$k] }
                    }
                }
                if (@($tfBlock.Keys).Count -gt 0) { $rec['TimeFilter'] = $tfBlock }
            }
        }
    }

    # ---- Stage 5.45 · T4a ONE-POLL-PER-ENDPOINT (SamePath ship dedup · audit 2026-06-12) ----
    # The Dedupe stage CLASSIFIES SamePath twins (IsCanonical/AliasFor) but the Shipped recompute above never read
    # that classification — both members of a SamePath group could ship (live: GetCloudAppsSettings + CloudApps.
    # GetSettings both shipped · ListChangeEvents shipped twice) = a DOUBLE-POLL of one endpoint (duplicate rows +
    # double load) the moment the category onboards. Per shipped endpoint group keep exactly ONE: canonical first,
    # then the operator-curated (valueClass) record, then lexicographic OperationId (deterministic regen). A group
    # whose canonical does NOT ship keeps its curated alias — the live-proven pilot promotion (MultiTenant.
    # GetTenantContext over the unshipped Configuration.GetTenantContext) — so this is NOT "only canonical ships".
    # Demotion is never silent: the loser records ShipHeldReason naming the winner (provenance · pinned by
    # Catalogue/CanonicalShipGate.Tests).
    foreach ($g in (@($out | Where-Object { $_['Shipped'] }) | Group-Object { "$([string]$_['SubPortal'])|$([string]$_['Path'])|$([string]$_['Method'])" })) {
        if (@($g.Group).Count -le 1) { continue }
        $sorted = @($g.Group | Sort-Object `
            @{ Expression = { if ($_['IsCanonical']) { 0 } else { 1 } } }, `
            @{ Expression = { if ($script:XdrValueOverrides.ContainsKey([string]$_['OperationId'])) { 0 } else { 1 } } }, `
            @{ Expression = { [string]$_['OperationId'] } })
        $winner = $sorted[0]
        foreach ($loser in @($sorted | Select-Object -Skip 1)) {
            $loser['Shipped'] = $false
            $loser['ShipHeldReason'] = "SamePath duplicate of $([string]$winner['OperationId']) (one poll per endpoint)"
        }
    }

    # ---- Stage 5.48 · T4-PROJ PROJECTION ALIAS (schema-sibling inheritance · curation DATA · before Stage-6 casing) ----
    # An op whose live capture was EMPTY (no rows on the lab tenant) and therefore fell back to the WRONG-cased spec
    # synthetic schema inherits a live-proven schema-sibling's ProjectionMap verbatim. This is the consolidated,
    # honest fix for the camelCase-from-empty-capture class (e.g. GetPending inherits GetHistory — identical Action[]
    # schema, pending vs historical rows). Gated: BOTH ops Shipped, the source ProjectionTier=live (a real capture).
    # NOT fabrication — it reuses the sibling's REAL live evidence, recorded as ProjectionTier=live-sibling.
    if ($script:XdrCuration.ProjectionAlias -and $script:XdrCuration.ProjectionAlias.Count -gt 0) {
        $byOpId = @{}; foreach ($rr in $out) { if ($rr['OperationId']) { $byOpId[[string]$rr['OperationId']] = $rr } }
        foreach ($rec in $out) {
            if (-not $rec['Shipped']) { continue }
            $fromId = $script:XdrCuration.ProjectionAlias[[string]$rec['OperationId']]
            if (-not $fromId) { continue }
            $src = $byOpId[[string]$fromId]
            if (($src -is [System.Collections.IDictionary]) -and $src['Shipped'] -and ([string]$src['ProjectionTier'] -eq 'live') -and ($src['ProjectionMap'] -is [System.Collections.IDictionary]) -and (@($src['ProjectionMap'].Keys).Count -gt 0)) {
                $copy = [ordered]@{}; foreach ($k in $src['ProjectionMap'].Keys) { $copy[[string]$k] = $src['ProjectionMap'][$k] }
                $rec['ProjectionMap'] = $copy
                $rec['ProjectionTier'] = 'live-sibling'
                $rec['ResponseShape'] = $src['ResponseShape']; $rec['ItemsContainer'] = $src['ItemsContainer']
            } else {
                Write-Warning "[Build-Catalogue] projectionAlias $([string]$rec['OperationId']) -> $fromId : source not a Shipped live-tier op with a projection · skipped (no change)"
            }
        }
    }

    # ---- Stage 5.5 · CADENCE TIERS (D25 · content-value · curation DATA · decoupled from IngestionMode) ----
    # The ONE authoritative cadence derivation, for every SHIPPED op, AFTER the final ship-gate + mode decisions:
    #   tier := curation.cadence.operationTiers[OperationId]
    #        ?? curation.cadence.subcategoryTiers[Subcategory]
    #        ?? derived: IngestionMode=CURSOR → 'events' · EffectiveValueClass=ConfigState → 'config' · else 'frequent'
    #   Cadence := tierDefaults[tier] · CadenceTier := tier (provenance · pinned by Catalogue/CadenceTiers.Tests).
    # This REPLACES the prior IngestionMode-coupled values (the 79-of-81-ops-at-15-minutes regression: config-state
    # endpoints like GetTenantContext re-polled every 15m). Cadence is now CONTENT-VALUE data the operator curates,
    # with an honest derived fallback — never fabricated, never mode-coupled. The earlier in-loop values (fixture
    # branch, conservative shim, WINDOW override) remain as interim provenance for NON-shipped ops only (they don't
    # poll). The volume advisory above stays advisory; tier values are authoritative. Unknown curated tier name →
    # 'frequent' (safe middle · the regen never fails on a curation typo; the contract test flags it).
    $tierDefaults = $script:XdrCadence.TierDefaults
    foreach ($rec in $out) {
        if (-not $rec['Shipped']) { continue }
        $cadOpId = [string]$rec['OperationId']
        $tier =
            if ($cadOpId -and $script:XdrCadence.OperationTiers.ContainsKey($cadOpId)) { [string]$script:XdrCadence.OperationTiers[$cadOpId] }
            elseif ($script:XdrCadence.SubcategoryTiers.ContainsKey([string]$rec['Subcategory'])) { [string]$script:XdrCadence.SubcategoryTiers[[string]$rec['Subcategory']] }
            elseif ([string]$rec['IngestionMode'] -eq 'CURSOR') { 'events' }
            elseif ([string]$rec['EffectiveValueClass'] -eq 'ConfigState') { 'config' }
            else { 'frequent' }
        if (-not $tierDefaults.ContainsKey($tier)) { $tier = 'frequent' }
        $rec['CadenceTier'] = $tier
        $rec['Cadence']     = [string]$tierDefaults[$tier]
    }

    # ---- Stage 6 · CANONICAL COLUMN CASING (C1a · the case-sensitive-ingest fix · the green-but-null loop-ender) ----
    # Azure Monitor matches JSON properties CASE-SENSITIVELY at ingest. The parser emits each row key using the
    # manifest ProjectionMap KEY verbatim; Build-PerCategorySchema folds case-collisions to ONE column (live-first).
    # If an op's ProjectionMap key casing (e.g. GetPending camelCase 'actionId') differs from the canonical column
    # casing the schema declares (GetHistory PascalCase 'ActionId'), that op's value is SILENTLY DROPPED at ingest
    # (HTTP 204, no error) EVEN at full 136-col parity. Fix: per Category, choose ONE canonical casing per
    # case-insensitive column name (live-proven ops win — SAME precedence as Build-PerCategorySchema's fold) and
    # rewrite every op's ProjectionMap KEY to it. The JSONPath VALUE is untouched — it still reads the real source
    # field's actual casing (e.g. column 'ActionId' <- '$.actionId'). After this pass the schema fold is a no-op
    # (zero case-collisions remain) and manifest-key == schema-column == parser-output for every op. Generic · all
    # categories · deterministic (preserves each ProjectionMap's insertion order; only key casing changes).
    foreach ($catGrp in ($out | Group-Object { [string]$_['Category'] })) {
        $canon = @{}   # lower(key) -> canonical-cased key
        $catOpsSorted = @($catGrp.Group | Sort-Object `
            @{ Expression = { if ($_['Provenance'] -and $_['Provenance']['Live']) { 0 } else { 1 } } }, `
            @{ Expression = { [string]$_['OperationKey'] } })
        foreach ($op in $catOpsSorted) {
            if (-not $op.Contains('ProjectionMap') -or -not $op['ProjectionMap']) { continue }
            foreach ($k in @($op['ProjectionMap'].Keys)) {
                $lc = ([string]$k).ToLowerInvariant()
                if (-not $canon.ContainsKey($lc)) { $canon[$lc] = [string]$k }   # first (live-first) casing wins
            }
        }
        foreach ($op in $catGrp.Group) {
            if (-not $op.Contains('ProjectionMap') -or -not $op['ProjectionMap']) { continue }
            $orig = $op['ProjectionMap']; $rebuilt = [ordered]@{}
            foreach ($k in @($orig.Keys)) {
                $lc = ([string]$k).ToLowerInvariant()
                $canonKey = if ($canon.ContainsKey($lc)) { $canon[$lc] } else { [string]$k }
                if (-not $rebuilt.Contains($canonKey)) { $rebuilt[$canonKey] = $orig[$k] }
            }
            $op['ProjectionMap'] = $rebuilt
        }
    }

    return [ordered]@{
        Portal = $Reg.Friendly; PortalKey = $portalKey
        GeneratedFrom = 'references (openapi x-tagGroups + inventory + live fixtures + live-evidence + live-capture evidence-index) · v13 fresh-derive'
        OperationCount = $out.Count
        StatusCounts = [ordered]@{
            Validated = @($out | Where-Object { $_.Status -eq 'Validated' }).Count
            LiveCaptured = @($out | Where-Object { $_.Status -eq 'LiveCaptured' }).Count
            OpenApiDerived = @($out | Where-Object { $_.Status -eq 'OpenApiDerived' }).Count
            StructuralOnly = @($out | Where-Object { $_.Status -eq 'StructuralOnly' }).Count
            Excluded = @($out | Where-Object { $_.Status -eq 'Excluded' }).Count
        }
        Operations = $out
    }
}

# ── Driver ──
# Serialize with StrictMode OFF (function-scoped) — `Set-StrictMode -Version Latest` + ConvertTo-Json trips on
# null-valued / empty-collection properties ("property 'Count' cannot be found"); serialization needs no StrictMode.
function ConvertTo-CatJson { param($Obj) Set-StrictMode -Off; $Obj | ConvertTo-Json -Depth 30 }
$summary = @()
foreach ($key in $targetKeys) {
    Set-XdrCurationForPortal $key   # F1.5 · the portal's OWN curation (Defender byte-identical · non-Defender = its own, not Defender's)
    $cat = Build-PortalCatalogue -Reg $registry[$key] -OnlyGroup $Group
    $sc = $cat.StatusCounts
    $summary += "  {0,-26} ops={1,-5} V={2} L={3} O={4} S={5} X={6}" -f $key, $cat.OperationCount, $sc.Validated, $sc.LiveCaptured, $sc.OpenApiDerived, $sc.StructuralOnly, $sc.Excluded
    if ($WriteFile) {
        $outPath = Join-Path $RepoRoot "references/inventory/$key/catalogue.json"
        (ConvertTo-CatJson $cat) | Out-File $outPath -Encoding utf8
    } elseif ($targetKeys.Count -eq 1) {
        ConvertTo-CatJson $cat
    }
}
if ($WriteFile -or $targetKeys.Count -gt 1) {
    Write-Host "[Build-Catalogue v13] portals=$($targetKeys.Count) $(if($Group){"group=$Group"}else{'all-groups'})$(if($WriteFile){' · WROTE catalogue.json'})"
    $summary | ForEach-Object { Write-Host $_ }
}
