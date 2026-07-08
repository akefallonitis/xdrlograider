#Requires -Version 7.4
<#
.SYNOPSIS
Shared SHAPE-ONLY DISCOVERY capture reader for the cataloguing toolchain. Reads a portal-internal SHAPE-ONLY capture
(references/live/<portalKey>/discovery/<OperationId>.json · the GET-only Probe-*Surface-Local output) and reconstructs
a REPRESENTATIVE, real-VALUED JSON body from its `shape` type-token tree, so the EXISTING shared shape oracle
(Get-XdrBodyShape) and the EXISTING projection/type-inference logic can consume it WITHOUT a separate code path.

.DESCRIPTION
Some Defender portal surfaces (e.g. the tvm/analytics TVM ops) have NO raw-body capture in source-mvp-fixtures and NO
usable OpenAPI/Postman item schema (the nodoc spec's list items are typeless 'pending' stubs → an EMPTY ProjectionMap
that would land RawJson-only). A read-only local probe captures the RESPONSE SHAPE ONLY — top-level keys + array-item
field names mapped to their CLR TYPE TOKEN (`<String>` `<Int64>` `<Double>` `<Boolean>` `<DateTime>` · arrays as
`{ '<array>':'count=N'; '<itemShape>': <shape> }`) — never a raw tenant value. That shape is the TIER-1 ground truth
for the op's projection + born-correct column types.

This reader INVERTS the probe's Get-ShapeOnly: it maps each type token to ONE representative value of that JSON wire
type (string→"s" · int→1 · real→1.5 · bool→true · datetime→an ISO-8601 string · empty array→a real empty list that
SURVIVES assignment so the canonical-list-key wrapper test still fires). The resulting body is then classified by the
SAME Get-XdrBodyShape oracle the live-captured path uses — so a discovery-shape op derives its ResponseShape /
ItemsContainer / field-union projection IDENTICALLY to a real capture (no twin-drift), and the SAME conservative
type-inference (Infer-ColumnTypes) reads the representative values to type the columns born-correct.

SCOPE / SAFETY:
  - Reads ONLY files of the shape-only envelope { operationId, shape, ... } whose basename is EXACTLY <OperationId>.json
    (e.g. VulnerabilityManagement.ListProducts.json). The ASR `*.shape.json` captures (a different probe's naming) and
    the full-HTTP `{ Body, Headers, StatusCode }` discovery captures do NOT match (no top-level `shape` token tree of
    type tokens / wrong basename) → they are IGNORED, so this never perturbs an op that already types from a real body.
  - Returns $null when the op has no shape-only discovery fixture, so the caller falls through to its normal waterfall
    (every op WITHOUT a discovery shape is byte-identical · the SPARSE/additive invariant).
  - NEVER emits a raw tenant value (the representative values are synthetic constants); NO I/O beyond the one read; never throws.
#>

# Map ONE shape TYPE TOKEN to a representative real value of that JSON wire type. The value's JSON KIND must match the
# token so the shared oracle + the conservative type classifier (System.Text.Json wire-kind / round-trippable-datetime)
# infer the SAME type the live capture would. Unknown/other scalar CLR tokens → a string (the safe born-default).
function ConvertFrom-XdrShapeToken {
    param([AllowNull()] $Node)
    if ($null -eq $Node) { return $null }
    if ($Node -is [string]) {
        switch -regex ($Node) {
            '^<(String|Char|Guid|Uri|Version|TimeSpan)>$'        { return 's' }                       # textual → string
            '^<(Int64|Int32|Int16|UInt64|UInt32|UInt16|Byte|SByte|BigInteger)>$' { return [int64]1 }  # whole number → long
            '^<(Double|Single|Decimal)>$'                        { return [double]1.5 }                # fractional → real
            '^<(Boolean)>$'                                      { return $true }                      # → boolean
            '^<(DateTime|DateTimeOffset)>$'                      { return '2026-06-25T00:00:00Z' }     # ISO-8601 → datetime
            '^<null>$'                                           { return $null }
            '^count=\d+$'                                        { return $null }                      # array-count marker (parent handles)
            '^<empty>$'                                          { return $null }                      # empty-array item shape (parent handles)
            default                                               { return 's' }                       # any other CLR scalar token → string
        }
    }
    if ($Node -is [System.Collections.IDictionary]) {
        # Array marker · the probe renders an array as { '<array>': 'count=N'; '<itemShape>': <shape> }. Reconstruct a
        # representative array: a 1-element list of the item shape (or a REAL empty list when the item shape is <empty>/
        # absent). Use a typed List[object] (NOT @()) so an EMPTY array survives assignment into an ordered dict — a bare
        # @() unrolls to $null on store, which would hide a canonical list key (e.g. an empty `results`) from the oracle.
        if ($Node.Contains('<array>') -or $Node.Contains('<itemShape>')) {
            $lst = [System.Collections.Generic.List[object]]::new()
            $itemShape = if ($Node.Contains('<itemShape>')) { $Node['<itemShape>'] } else { $null }
            if (-not ($null -eq $itemShape -or ($itemShape -is [string] -and $itemShape -eq '<empty>'))) {
                $lst.Add((ConvertFrom-XdrShapeToken $itemShape))
            }
            return , $lst   # unary comma · return the List itself, never let the pipeline unroll it
        }
        $o = [ordered]@{}
        foreach ($k in $Node.Keys) { $o[[string]$k] = ConvertFrom-XdrShapeToken $Node[$k] }
        return $o
    }
    return 's'
}

# Read the SHAPE-ONLY discovery fixture for ONE op and return a representative real-valued body (ready for
# Get-XdrBodyShape / Infer-ColumnTypes), or $null when there is no shape-only discovery capture for the op.
function Get-XdrDiscoveryShapeBody {
    param(
        [Parameter(Mandatory)][string] $RepoRoot,
        [Parameter(Mandatory)][string] $PortalKey,
        [Parameter(Mandatory)][string] $OperationId
    )
    if ([string]::IsNullOrWhiteSpace($OperationId)) { return $null }
    $fx = Join-Path $RepoRoot "references/live/$PortalKey/discovery/$OperationId.json"
    if (-not (Test-Path -LiteralPath $fx)) { return $null }
    $env = $null
    try { $env = Get-Content -LiteralPath $fx -Raw | ConvertFrom-Json -AsHashtable -Depth 40 } catch { return $null }
    # Only the shape-only envelope qualifies: a top-level `shape` key AND a matching `operationId` (so a full-HTTP
    # capture { Body, Headers, ... } or a mismatched file is ignored). An absent/null/scalar `shape` (e.g. a 0-row
    # capture whose shape is <null>) yields a null body → singleObject/0-rows downstream (RawJson floor), which is correct.
    if (($env -isnot [System.Collections.IDictionary]) -or (-not $env.Contains('shape'))) { return $null }
    if ($env.Contains('operationId') -and ([string]$env['operationId'] -ne $OperationId)) { return $null }
    $body = ConvertFrom-XdrShapeToken $env['shape']
    # A top-level bareArray body must survive the return: PowerShell UNROLLS a returned 1-element collection to its
    # element (turning a bareArray-of-one into a singleObject). The unary comma preserves the List; a dict/scalar body
    # is returned as-is (comma-wrapping a non-list would falsely make it a 1-element array).
    if ($body -is [System.Collections.IList]) { return , $body }
    return $body
}
