#Requires -Version 7.4
<#
.SYNOPSIS
Infer CONSERVATIVE Log-Analytics column types for Defender operations from their LIVE capture bodies — automating the
per-op `columnTypes` curation an operator did by hand for the pilot ops, for ALL ~159 ops.

.DESCRIPTION
For each operation in the evidence-index, this loads the op's live capture body
(references/live/source-mvp-fixtures/<Dir>/response.json), classifies its shape with the SHARED shape oracle
(dev-tools/lib/Get-XdrBodyShape.ps1 — identical to the cataloguer, so it can NEVER drift), unwraps the items container,
and for every TOP-LEVEL field of the response ITEM collects ALL observed NON-NULL values across all items, then applies
the conservative inference rule (see RULE). It emits, per op, an ordered { column: type } object (keys Sort-Object'd),
keyed by OperationId — the SAME shape as curation.json's `columnTypes` map.

WHY RAW-JSON READING (System.Text.Json), NOT ConvertFrom-Json:
PowerShell's ConvertFrom-Json AUTO-COERCES JSON tokens — an ISO-8601 string becomes [datetime], a JSON number becomes
[long]/[double], 'true'/'false' becomes [bool] — which DESTROYS the JSON-level type distinction the conservative rule
is defined over (string-that-parses-as-datetime is NOT the same as a JSON datetime; an integer-valued JSON number is
`long` only if it has no fractional part in the WIRE text). So the body's leaf values are read as raw JsonElements via
System.Text.Json.JsonDocument, and the per-value classifier looks at JsonValueKind (+ the raw number text for the
integer/real split, + a round-trippable-datetime parse for strings). The shape oracle, however, only needs the body's
STRUCTURE (which properties are arrays, canonical list keys, metadata siblings) to pick Shape/ItemsPath — leaf-scalar
coercion never changes that verdict — so the body is ALSO parsed once with ConvertFrom-Json (-AsHashtable, StrictMode-safe)
purely to drive Get-XdrBodyShape, and the resulting ItemsPath is then walked over the RAW JsonElement tree to get the
items WITHOUT coercion. The two parses see the same structure by construction.

INFERENCE RULE (conservative · MUST match curation.json `columnTypes` _doc exactly):
For each projection column (top-level field of the response ITEM — unwrap ItemsContainer for wrapper/bareArray; for
singleObject the item is the object itself), collect ALL observed NON-NULL values across all items, then:
  boolean  · every value is a JSON boolean (True/False).
  long     · every value is a JSON number with no fractional part (a whole number on the wire).
  real     · every value is a JSON number AND at least one is non-integer.
  datetime · every value is a JSON string that parses as a round-trippable / ISO-8601 datetime.
  (omit)   · otherwise — string, object, array, mixed kinds, or any disagreement — the column defaults to string and is
             NOT listed (`columnTypes` is SPARSE; "string" is never emitted). A column with ZERO non-null observed
             values is also omitted (a type cannot be proven).

OUTPUT KEYS = RAW item field names (e.g. `mpsSliceId`, `EventTime`, `createdTimestamp`), exactly as curation.json keys
them. The catalogue ProjectionMap decorates field names (`<field>Json` for nested object/array fields, `<field>_x` for
collision-renamed scalars) — those decorations are IRRELEVANT here because nested fields are never scalar (always
omitted) and the curated oracle keys on raw field names. The ProjectionMap is consulted ONLY as a fallback column
universe when a record's capture body yields no fields (e.g. an empty/absent body), so the per-op result is still keyed
by the op's real projection columns (each then omitted, since no values prove a type).

.PARAMETER Portal
The portal to infer for. Only 'Defender' is wired (the nodoc-defender-xdr inventory). Default: Defender.

.PARAMETER OperationId
Optional single OperationId to restrict the run to one op (for validation / spot-checks).

.PARAMETER OutFile
Optional path to ALSO write the emitted columnTypes JSON to (the same JSON is always returned to the pipeline). This
tool NEVER writes curation.json and NEVER commits.

.OUTPUTS
A [pscustomobject] whose properties are OperationIds (only ops with >=1 typed column), each an ordered { column: type }
object with Sort-Object'd keys. ConvertTo-Json this to get a block shaped like curation.json's `columnTypes`.

.NOTES
Read-only except an optional -OutFile. No curation.json edits, no catalogue rebuilds, no git, no Azure. PS 7.
#>
[CmdletBinding()]
param(
    [ValidateSet('Defender')]
    [string] $Portal = 'Defender',

    [string] $OperationId,

    [string] $OutFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------------------------------------------------
# Paths · resolved relative to the repo root (this script lives in <repo>/dev-tools).
# ---------------------------------------------------------------------------------------------------------------------
$RepoRoot       = Split-Path -Parent $PSScriptRoot
$ShapeOracle    = Join-Path $PSScriptRoot 'lib/Get-XdrBodyShape.ps1'
$InventoryDir   = Join-Path $RepoRoot 'references/inventory/nodoc-defender-xdr'
$EvidenceIndex  = Join-Path $InventoryDir 'evidence-index.json'
$CatalogueFile  = Join-Path $InventoryDir 'catalogue.json'

foreach ($p in @($ShapeOracle, $EvidenceIndex, $CatalogueFile)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "Required input not found: $p" }
}

. $ShapeOracle   # dot-source the shared shape oracle (Get-XdrBodyShape + helpers)
# Shared SHAPE-ONLY DISCOVERY reader · lets this tool infer born-correct types for an op that has ONLY a shape-only
# discovery capture (references/live/<portalKey>/discovery/<OperationId>.json · no source-mvp-fixtures body) — the SAME
# capture the catalogue's discovery projection tier reads, so the inferred columnTypes match what the catalogue projects
# (and the GM-1(c) live-proven-typing cross-check agrees with curation). $null when no shape fixture exists. OPTIONAL:
# guarded by Test-Path so a minimal scaffold that copies only the tool + Get-XdrBodyShape (the cross-op-ambiguity unit
# harness · no discovery dir) still runs — the discovery pass below is itself guarded by Test-Path $discoDir, and
# Get-XdrDiscoveryShapeBody is invoked ONLY when the lib loaded, so absence is a clean no-discovery degrade, never a crash.
$DiscoveryLib = Join-Path $PSScriptRoot 'lib/Get-XdrDiscoveryShape.ps1'
$script:XdrDiscoveryReaderLoaded = $false
if (Test-Path -LiteralPath $DiscoveryLib) { . $DiscoveryLib; $script:XdrDiscoveryReaderLoaded = $true }

# ---------------------------------------------------------------------------------------------------------------------
# Per-VALUE classifier · maps ONE raw JsonElement to a coarse class token, looking only at the JSON wire form.
#   'bool'     · JsonValueKind True/False
#   'int'      · a JSON number whose wire text has NO fractional/exponent part (a whole number)
#   'real'     · a JSON number whose wire text IS fractional/exponential (1.5, 1e3, 2.0, -0.0)
#   'datetime' · a JSON string that round-trips as a DateTime/DateTimeOffset (ISO-8601 / 'o'-style)
#   'string'   · any other JSON string (non-datetime)
#   'complex'  · JsonValueKind Object or Array (never a scalar column)
# Null is filtered by the CALLER (Null/absent are not "observed non-null values").
# ---------------------------------------------------------------------------------------------------------------------
function Get-XdrValueClass {
    param([Parameter(Mandatory)][System.Text.Json.JsonElement] $Element)

    switch ($Element.ValueKind) {
        ([System.Text.Json.JsonValueKind]::True)   { return 'bool' }
        ([System.Text.Json.JsonValueKind]::False)  { return 'bool' }
        ([System.Text.Json.JsonValueKind]::Object) { return 'complex' }
        ([System.Text.Json.JsonValueKind]::Array)  { return 'complex' }
        ([System.Text.Json.JsonValueKind]::Number) {
            # Integer vs real is decided by the WIRE TEXT, not by a parse that might silently coerce 2.0 -> 2.
            # A whole number on the wire (no '.', no exponent) is `long`-eligible; anything with a fraction/exponent
            # (1.5, 2.0, 1e3) is real. (JSON has no NaN/Inf, so GetRawText is always a plain numeric literal here.)
            $raw = $Element.GetRawText()
            if ($raw -match '^[+-]?[0-9]+$') { return 'int' }
            return 'real'
        }
        ([System.Text.Json.JsonValueKind]::String) {
            $s = $Element.GetString()
            if ([string]::IsNullOrWhiteSpace($s)) { return 'string' }   # '' / whitespace is a string, never a datetime
            if (Test-XdrIsoDateTime -Value $s) { return 'datetime' }
            return 'string'
        }
        default { return 'string' }   # Null is handled by the caller; Undefined/other => treat as string (will omit)
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# Round-trippable / ISO-8601 datetime test for a STRING value. Conservative: requires a date-shaped, culture-invariant,
# round-trippable parse so plain integers-as-strings, GUIDs, durations, or free text are NOT mistaken for datetimes.
#   - Must contain a date separator ('-') AND a 4-digit year, so '12:00:00' (time-only) or '5' do not qualify.
#   - Parsed with InvariantCulture + AssumeUniversal|RoundtripKind|NoCurrentDateDefault so it is the WIRE value that
#     decides, never the host locale/clock (the Greek-culture / current-date-default traps).
#   - Tries DateTimeOffset first (tz-aware ISO), then DateTime — both round-trip ISO-8601 'o' and the common
#     'yyyy-MM-ddTHH:mm:ss[.fffffff]' Defender wire form.
# ---------------------------------------------------------------------------------------------------------------------
function Test-XdrIsoDateTime {
    param([Parameter(Mandatory)][string] $Value)

    $s = $Value.Trim()
    # Cheap structural pre-filter: an ISO datetime has a 4-digit year then '-' then 2-digit month then '-' ... We
    # require at minimum 'YYYY-MM-DD' so date-less / year-less strings (durations, times, ids) are rejected up front.
    if ($s -notmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}([T ].*)?$') { return $false }

    $inv = [System.Globalization.CultureInfo]::InvariantCulture

    # DateTimeOffset.TryParse does NOT accept NoCurrentDateDefault (it always carries a full date+offset), so its style
    # set is just AssumeUniversal|AdjustToUniversal — the wire value still decides (no host-locale/clock influence).
    $dtoStyles = [System.Globalization.DateTimeStyles]::AssumeUniversal `
        -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    [datetimeoffset] $dto = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse($s, $inv, $dtoStyles, [ref] $dto)) { return $true }

    # DateTime fallback · add NoCurrentDateDefault so a time-only string can't borrow today's date and falsely parse
    # (defence-in-depth; the YYYY-MM-DD pre-filter already requires a date component).
    $dtStyles = $dtoStyles -bor [System.Globalization.DateTimeStyles]::NoCurrentDateDefault
    [datetime] $dt = [datetime]::MinValue
    if ([datetime]::TryParse($s, $inv, $dtStyles, [ref] $dt)) { return $true }

    return $false
}

# ---------------------------------------------------------------------------------------------------------------------
# Reduce the SET of class tokens observed for one column (across all non-null values) to the emitted LA type, or $null
# to OMIT. Implements the conservative rule's "every value agrees" discipline exactly.
# ---------------------------------------------------------------------------------------------------------------------
function Resolve-XdrColumnType {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Classes)

    if ($Classes.Count -eq 0) { return $null }                       # zero non-null observed values => omit
    $set = [System.Collections.Generic.HashSet[string]]::new([string[]]$Classes)

    if ($set.Contains('complex')) { return $null }                   # any object/array => string (omit)
    if ($set.Contains('string'))  { return $null }                   # any non-datetime string => string (omit)

    # Every value is bool?  boolean.
    if ($set.Count -eq 1 -and $set.Contains('bool')) { return 'boolean' }
    # Every value is a datetime-string?  datetime.
    if ($set.Count -eq 1 -and $set.Contains('datetime')) { return 'datetime' }

    # Numeric family: every value must be a JSON number (int and/or real, nothing else).
    $numericOnly = $true
    foreach ($c in $set) { if ($c -ne 'int' -and $c -ne 'real') { $numericOnly = $false; break } }
    if ($numericOnly) {
        if ($set.Contains('real')) { return 'real' }                 # >=1 non-integer number => real
        return 'long'                                                # all whole numbers => long
    }

    # Mixed disagreement that isn't pure-numeric (e.g. bool+datetime, int+bool, datetime+real) => string (omit).
    return $null
}

# ---------------------------------------------------------------------------------------------------------------------
# Navigate a RAW JsonElement tree along an ItemsPath (the array-key chain the shape oracle returned) and return the
# ARRAY element's items as a list of JsonElement, OR — for singleObject (empty path) — the single object element wrapped
# in a one-element list. Returns @() when the path cannot be resolved to an array/object (defensive; never throws).
# ---------------------------------------------------------------------------------------------------------------------
function Get-XdrItemElements {
    param(
        [Parameter(Mandatory)][System.Text.Json.JsonElement] $Root,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $ItemsPath,
        [Parameter(Mandatory)][ValidateSet('wrapper', 'bareArray', 'singleObject')][string] $Shape
    )

    $items = [System.Collections.Generic.List[System.Text.Json.JsonElement]]::new()

    if ($Shape -eq 'bareArray') {
        if ($Root.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
            foreach ($e in $Root.EnumerateArray()) { $items.Add($e) }
        }
        return $items
    }

    if ($Shape -eq 'singleObject') {
        # The item IS the object itself (wrap in a one-element list). A scalar/null body yields no fields downstream.
        if ($Root.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) { $items.Add($Root) }
        return $items
    }

    # wrapper · walk the ItemsPath (1 element flat, 2 elements for an MTO-descended list) to the array element.
    $cur = $Root
    foreach ($key in $ItemsPath) {
        if ($cur.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { return $items }   # path broke => no items
        $found = $false
        foreach ($prop in $cur.EnumerateObject()) {
            # Case-insensitive key match: the oracle picks canonical keys case-insensitively; honour the SAME match so
            # the raw-tree walk lands on the exact array the oracle named (e.g. 'results' vs 'Results').
            if ([string]::Equals($prop.Name, [string]$key, [System.StringComparison]::OrdinalIgnoreCase)) {
                $cur = $prop.Value; $found = $true; break
            }
        }
        if (-not $found) { return $items }   # named key absent in the raw tree => no items
    }
    if ($cur.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
        foreach ($e in $cur.EnumerateArray()) { $items.Add($e) }
    }
    return $items
}

# ---------------------------------------------------------------------------------------------------------------------
# Infer the typed-column map for ONE op from its capture body. Returns an [ordered] dictionary (Sort-Object'd keys) of
# only the typed (non-string) columns, or an EMPTY ordered dictionary when none can be proven.
# $ItemElements: the list of item JsonElements (already unwrapped per shape).
# ---------------------------------------------------------------------------------------------------------------------
function Get-XdrTypedColumns {
    # [AllowNull]/[AllowEmptyCollection] + no [JsonElement[]] coercion: an EMPTY items collection unrolls to $null
    # through the pipeline (the PowerShell collection-unroll foot-gun), and a body that legitimately yields zero items
    # (empty array, scalar/null body, empty wrapper list) MUST resolve to "no typed columns" — NOT throw a bind error.
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()] $ItemElements)

    # Per-column accumulation of observed NON-NULL class tokens, in first-seen order (output is sorted at the end, but
    # we keep an ordered backing dict so the column universe is deterministic regardless of hashtable seed).
    $colClasses = [ordered]@{}   # column(raw field name) -> List[string] of class tokens

    foreach ($item in @($ItemElements)) {
        if ($item -isnot [System.Text.Json.JsonElement]) { continue }   # $null / non-element (empty collection) => skip
        if ($item.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { continue }   # non-object item contributes no fields
        foreach ($prop in $item.EnumerateObject()) {
            $name = $prop.Name
            $val  = $prop.Value
            if ($val.ValueKind -eq [System.Text.Json.JsonValueKind]::Null) {
                # A NULL occurrence is not an "observed non-null value": register the column (so it exists in the
                # universe) but contribute no class token.
                if (-not $colClasses.Contains($name)) { $colClasses[$name] = [System.Collections.Generic.List[string]]::new() }
                continue
            }
            if (-not $colClasses.Contains($name)) { $colClasses[$name] = [System.Collections.Generic.List[string]]::new() }
            ($colClasses[$name]).Add((Get-XdrValueClass -Element $val))
        }
    }

    # Resolve each column to a type (or omit), then emit ONLY typed columns with Sort-Object'd keys.
    $typed = [ordered]@{}
    foreach ($col in ($colClasses.Keys | Sort-Object { [string]$_ })) {
        $t = Resolve-XdrColumnType -Classes ([string[]]@($colClasses[$col]))
        if ($null -ne $t) { $typed[$col] = $t }
    }
    return $typed
}

# ---------------------------------------------------------------------------------------------------------------------
# Collect, for ONE op's item elements, the FULL set of observed NON-NULL value-class tokens per item field — NOT
# reduced to a type (that is Get-XdrTypedColumns' job). The cross-op ambiguity pass unions these across ALL ops to detect
# a col-NAME whose real wire type DISAGREES across ops (e.g. `Id` is long here but a GUID string in another op). Returns a
# hashtable { fieldName -> HashSet[string] of class tokens } (empty when no items / no fields). Same class oracle
# (Get-XdrValueClass) + same null-skip discipline as Get-XdrTypedColumns, so the two can NEVER drift.
# ---------------------------------------------------------------------------------------------------------------------
function Get-XdrColumnClassSets {
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()] $ItemElements)

    $sets = @{}   # fieldName -> HashSet[string]
    foreach ($item in @($ItemElements)) {
        if ($item -isnot [System.Text.Json.JsonElement]) { continue }
        if ($item.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { continue }
        foreach ($prop in $item.EnumerateObject()) {
            $val = $prop.Value
            if ($val.ValueKind -eq [System.Text.Json.JsonValueKind]::Null) { continue }   # null is not an observed value
            if (-not $sets.ContainsKey($prop.Name)) { $sets[$prop.Name] = [System.Collections.Generic.HashSet[string]]::new() }
            [void]$sets[$prop.Name].Add((Get-XdrValueClass -Element $val))
        }
    }
    return $sets
}

# ---------------------------------------------------------------------------------------------------------------------
# Load inputs.
# ---------------------------------------------------------------------------------------------------------------------
$evidence  = Get-Content -LiteralPath $EvidenceIndex -Raw | ConvertFrom-Json
$catalogue = Get-Content -LiteralPath $CatalogueFile  -Raw | ConvertFrom-Json

# evidence-index is an OBJECT WRAPPER; the 159 records are nested under .Records.
$records = @($evidence.Records)
if ($records.Count -eq 0) { throw "evidence-index.json has no .Records array (got keys: $(@($evidence.PSObject.Properties.Name) -join ', '))" }

# Index the catalogue by OperationId for the ProjectionMap fallback (column universe when a body yields no fields).
$catById = @{}
foreach ($op in @($catalogue.Operations)) { if ($op.OperationId) { $catById[[string]$op.OperationId] = $op } }

if ($OperationId) {
    $records = @($records | Where-Object { [string]$_.OperationId -eq $OperationId })
}

# SHAPE-ONLY DISCOVERY records · supplement the evidence-index with synthetic records for catalogue ops that have a
# portal-internal SHAPE-ONLY discovery capture but NO source-mvp-fixtures body (so they are absent from the evidence
# index). Each synthetic record carries the op's representative body as in-memory RawJson (built from the shape tokens
# by the SAME reader the catalogue uses), so the per-op loop infers its types identically — keeping curation.columnTypes
# in lock-step with both the catalogue projection AND the GM-1(c) cross-check. Defender-only (the only catalogued portal).
$discoPortalKey = 'nodoc-defender-xdr'
$discoDir = Join-Path $RepoRoot "references/live/$discoPortalKey/discovery"
$alreadyIndexed = @{}; foreach ($rr in $records) { if ($rr.OperationId) { $alreadyIndexed[[string]$rr.OperationId] = $true } }
if ($script:XdrDiscoveryReaderLoaded -and (Test-Path -LiteralPath $discoDir)) {
    foreach ($op in @($catalogue.Operations)) {
        $opId = [string]$op.OperationId
        if (-not $opId) { continue }
        if ($OperationId -and $opId -ne $OperationId) { continue }
        if ($alreadyIndexed.ContainsKey($opId)) { continue }   # a real capture already covers it (never override real-body evidence)
        $body = Get-XdrDiscoveryShapeBody -RepoRoot $RepoRoot -PortalKey $discoPortalKey -OperationId $opId
        if ($null -eq $body) { continue }
        # Serialize the representative body to JSON so the per-op loop's System.Text.Json value pass reads the SAME wire
        # kinds (string/number/bool/iso-datetime) the catalogue's discovery tier classified. Depth covers nested objects.
        $rawJson = $null
        try { $rawJson = $body | ConvertTo-Json -Depth 40 } catch { $rawJson = $null }
        if ([string]::IsNullOrWhiteSpace($rawJson)) { continue }
        $records += [pscustomobject]@{ OperationId = $opId; Fixture = ''; RawJson = $rawJson }
    }
}
if ($records.Count -eq 0) {
    if ($OperationId) { throw "OperationId '$OperationId' not found in evidence-index Records or discovery shapes." }
    throw 'no records to infer from (evidence-index empty and no discovery shapes).'
}

# ---------------------------------------------------------------------------------------------------------------------
# Per-op inference.
# ---------------------------------------------------------------------------------------------------------------------
$result = [ordered]@{}   # OperationId -> ordered { column: type }   (only ops with >=1 typed column)

# CROSS-OP AMBIGUITY accumulator (resolved AFTER the per-op loop). The type-consistency union in Generate-Manifest
# propagates a curated col-type to EVERY op projecting that col-NAME; if the same col-name has a DIFFERENT real wire
# type across ops, the union over-propagates and DROPS values at ingest (e.g. `Id` is long=1000000024 in
# ListSuppressionRules but a GUID-string '550e8400-…' in ListUnifiedConnectors / 'SentinelExportSettings-…' in
# GetDataExportSettings → typed long → the GUIDs drop). Keyed by the LOWER-CASED col-name (the shared LA table treats
# column names case-insensitively, so `Id` and `id` are the SAME column) → a HashSet of every class token observed for
# that name across ALL ops. The cross-op pass uses this to drop a col-name's type whenever any op disagrees.
$crossOpClassesByName = @{}   # lower(colName) -> HashSet[string] of class tokens observed across ALL ops

foreach ($rec in ($records | Sort-Object { [string]$_.OperationId })) {
    $opId = [string]$rec.OperationId
    # A synthetic SHAPE-ONLY discovery record carries its representative body in-memory as RawJson (no Fixture file);
    # a real evidence record carries a repo-relative Fixture path. Prefer the in-memory RawJson when present.
    $recRawJson = if ($rec.PSObject.Properties['RawJson']) { [string]$rec.RawJson } else { $null }
    if (-not [string]::IsNullOrWhiteSpace($recRawJson)) {
        $rawJson = $recRawJson
    } else {
        $fixtureRel = [string]$rec.Fixture
        if ([string]::IsNullOrWhiteSpace($fixtureRel)) {
            Write-Verbose "[$opId] no Fixture path in evidence record — skipping (no body to infer from)."
            continue
        }

        # Fixtures are repo-relative; resolve against the repo root.
        $fixturePath = if ([System.IO.Path]::IsPathRooted($fixtureRel)) { $fixtureRel } else { Join-Path $RepoRoot $fixtureRel }
        if (-not (Test-Path -LiteralPath $fixturePath)) {
            Write-Verbose "[$opId] fixture not found: $fixturePath — skipping."
            continue
        }

        $rawJson = Get-Content -LiteralPath $fixturePath -Raw
        if ([string]::IsNullOrWhiteSpace($rawJson)) {
            Write-Verbose "[$opId] empty fixture body — no typed columns."
            continue
        }
    }

    # 1) STRUCTURE pass: ConvertFrom-Json (-AsHashtable, StrictMode-safe) ONLY to drive the shared shape oracle, which
    #    decides Shape + ItemsPath from structure (array props / canonical keys / metadata siblings). Leaf-scalar
    #    coercion here is irrelevant to that verdict.
    $shape = $null
    try {
        $bodyForShape = $rawJson | ConvertFrom-Json -AsHashtable -Depth 100
        $shape = Get-XdrBodyShape -Body $bodyForShape
    }
    catch {
        Write-Warning "[$opId] failed to parse/classify body ($fixturePath): $($_.Exception.Message) — skipping."
        continue
    }

    # 2) VALUE pass: parse the SAME bytes with System.Text.Json (no coercion) and walk the oracle's ItemsPath over the
    #    raw tree to get the item elements, then infer types from raw wire tokens.
    $doc = $null
    try {
        $doc  = [System.Text.Json.JsonDocument]::Parse($rawJson)
        $root = $doc.RootElement
        # @()-wrap: Get-XdrItemElements returns a List[JsonElement] that the pipeline UNROLLS — an empty list becomes
        # $null and a 1-item list becomes a bare struct; @() re-normalizes to an array so the type pass sees a uniform
        # collection (zero items => empty array => "no typed columns", never a bind error).
        $itemEls = @(Get-XdrItemElements -Root $root -ItemsPath (@($shape.ItemsPath)) -Shape ([string]$shape.Shape))
        $typed   = Get-XdrTypedColumns -ItemElements $itemEls
        # CROSS-OP: union this op's per-field class tokens into the global by-name accumulator (lower-cased name · the
        # case-insensitive shared-table column identity) so the post-loop pass can see EVERY op's real wire type for a name.
        foreach ($cn in (Get-XdrColumnClassSets -ItemElements $itemEls).GetEnumerator()) {
            $nameKey = $cn.Key.ToLowerInvariant()
            if (-not $crossOpClassesByName.ContainsKey($nameKey)) { $crossOpClassesByName[$nameKey] = [System.Collections.Generic.HashSet[string]]::new() }
            foreach ($cls in $cn.Value) { [void]$crossOpClassesByName[$nameKey].Add($cls) }
        }
    }
    catch {
        Write-Warning "[$opId] raw-JSON value pass failed ($fixturePath): $($_.Exception.Message) — skipping."
        continue
    }
    finally {
        if ($null -ne $doc) { $doc.Dispose() }
    }

    if ($typed.Keys.Count -gt 0) {
        # Re-wrap as a fresh ordered dict to guarantee Sort-Object'd key order in the emitted object.
        $ordered = [ordered]@{}
        foreach ($k in ($typed.Keys | Sort-Object { [string]$_ })) { $ordered[$k] = $typed[$k] }
        $result[$opId] = [pscustomobject]$ordered
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# CROSS-OP AMBIGUITY pass · resolve a col-NAME that an op typed as a scalar (long/real/datetime/boolean) but that ANOTHER
# op shows as a NON-SCALAR or a conflicting scalar/string. Because Generate-Manifest's type-consistency union propagates a
# col-type to EVERY op projecting that col-name, a single disagreeing op silently DROPS values at ingest (the typed
# numeric `Id` drops the GUID-string `id`; the typed long `RuleType` drops 'Predefined'). Conservative resolution: when a
# typed col-name is contradicted by ANY op → emit NO type for it (string, the safe shared-table default), dropped from the
# ENTIRE output. The per-op pass already unifies long+real → real (same numeric family · not a drop), so a numeric/numeric
# disagreement is NOT a conflict here; only a cross-FAMILY clash (numeric vs datetime vs boolean), a non-datetime STRING
# (e.g. a GUID), or a non-scalar (object/array) is.
# ---------------------------------------------------------------------------------------------------------------------
# The scalar FAMILY the per-op rule could have inferred from a class token (the union target an op would have produced).
$familyOf = @{ int = 'numeric'; real = 'numeric'; bool = 'boolean'; datetime = 'datetime' }   # 'string'/'complex' have no scalar family
# Gather every typed col-NAME (lower-cased · shared-table identity) and the scalar family it was typed as. If two ops typed
# the SAME name into different families (e.g. long here, datetime there) that is itself a conflict.
$typedFamilyByName = @{}   # lower(name) -> HashSet[string] of inferred scalar families across ops
foreach ($opId in $result.Keys) {
    foreach ($p in $result[$opId].PSObject.Properties) {
        $nameKey = $p.Name.ToLowerInvariant()
        $fam = switch ($p.Value) { 'long' { 'numeric' } 'real' { 'numeric' } 'boolean' { 'boolean' } 'datetime' { 'datetime' } default { $null } }
        if ($null -eq $fam) { continue }
        if (-not $typedFamilyByName.ContainsKey($nameKey)) { $typedFamilyByName[$nameKey] = [System.Collections.Generic.HashSet[string]]::new() }
        [void]$typedFamilyByName[$nameKey].Add($fam)
    }
}
# Decide which lower-cased names are AMBIGUOUS and must be dropped everywhere.
$dropNames = [System.Collections.Generic.HashSet[string]]::new()
foreach ($nameKey in $typedFamilyByName.Keys) {
    $typedFams = $typedFamilyByName[$nameKey]
    $conflict = $false
    $reason   = ''
    if ($typedFams.Count -gt 1) { $conflict = $true; $reason = "ops typed it as multiple families ($([string]::Join('+', $typedFams)))" }
    if (-not $conflict -and $crossOpClassesByName.ContainsKey($nameKey)) {
        $observed = $crossOpClassesByName[$nameKey]
        $typedFam = @($typedFams)[0]   # exactly one when we reach here
        if ($observed.Contains('complex')) { $conflict = $true; $reason = "another op observes a non-scalar (object/array)" }
        elseif ($observed.Contains('string')) { $conflict = $true; $reason = "another op observes a non-datetime string (e.g. a GUID)" }
        else {
            # No string/complex, but a scalar from a DIFFERENT family than the typed one (numeric vs datetime vs boolean).
            foreach ($cls in $observed) {
                $obsFam = $familyOf[$cls]
                if ($null -ne $obsFam -and $obsFam -ne $typedFam) { $conflict = $true; $reason = "another op observes a $obsFam value but it was typed $typedFam"; break }
            }
        }
    }
    if ($conflict) {
        [void]$dropNames.Add($nameKey)
        Write-Host "[Infer-ColumnTypes] cross-op ambiguity · dropping type for col '$nameKey' (resolve to string · $reason)"
    }
}
# Apply the drops: rebuild each op's object WITHOUT the ambiguous col-names; remove ops left with zero typed cols.
if ($dropNames.Count -gt 0) {
    $resolved = [ordered]@{}
    foreach ($opId in $result.Keys) {
        $kept = [ordered]@{}
        foreach ($p in $result[$opId].PSObject.Properties) {
            if (-not $dropNames.Contains($p.Name.ToLowerInvariant())) { $kept[$p.Name] = $p.Value }
        }
        if ($kept.Keys.Count -gt 0) { $resolved[$opId] = [pscustomobject]$kept }
    }
    $result = $resolved
}

# ---------------------------------------------------------------------------------------------------------------------
# Emit · a single pscustomobject keyed by OperationId, each an ordered { column: type } object — the shape of
# curation.json's `columnTypes` (minus the _doc). Ops with zero typed columns are omitted (sparse, like curation).
# ---------------------------------------------------------------------------------------------------------------------
$out = [pscustomobject]$result

if ($OutFile) {
    $json = $out | ConvertTo-Json -Depth 10
    # Normalise to LF and ensure a trailing newline (artifact hygiene); this is the ONLY file this tool may write.
    $json = ($json -replace "`r`n", "`n")
    if (-not $json.EndsWith("`n")) { $json += "`n" }
    [System.IO.File]::WriteAllText($OutFile, $json, [System.Text.UTF8Encoding]::new($false))
    Write-Verbose "Wrote inferred columnTypes to $OutFile"
}

$out
