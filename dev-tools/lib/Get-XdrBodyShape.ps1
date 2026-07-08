#Requires -Version 7.4
<#
.SYNOPSIS
Single shared SHAPE ORACLE for the cataloguing toolchain. Classifies a captured response body (or an OpenAPI
response schema's property set) as bareArray | wrapper | singleObject, and — for a wrapper — names the array key
that holds the records. Imported by BOTH dev-tools/Build-EvidenceIndex.ps1 and dev-tools/Build-Catalogue.ps1 so the
two generators can NEVER drift (the historical twin-drift bug: each had its own copy that fanned out the FIRST
array-typed property of a single record, dropping every scalar/object sibling).

.DESCRIPTION
The classification a generator records drives runtime fan-out: a 'wrapper' makes the runtime emit ONE row per
element of ItemsContainer (and DROP the wrapper's other properties); a 'singleObject' emits exactly ONE row and
folds nested arrays/objects into '<key>Json' columns (NO fan-out). Mislabelling a single record as a wrapper
therefore silently discards real telemetry. The oracle is deliberately conservative about calling something a list:

  bareArray     · the body is a top-level JSON array. RowCount = element count.
  wrapper       · the object is a LIST ENVELOPE — it has exactly ONE array property AND every other (non-array)
                  property is EMPTY or a known pagination/list-metadata key — OR its sole array sits under a
                  canonical list key (Results/value/data/items/records/actions). ItemsContainer = that key.
                  RowCount = the array's element count.
  singleObject  · anything else: a record with >1 array (e.g. {BuiltInTags,UserDefinedTags,DynamicRulesTags}),
                  a record whose single array is one field among substantive entity siblings (e.g. TenantContext),
                  or a scalar/null body. ItemsContainer = $null. Nested arrays/objects become '<key>Json' columns.
                  RowCount = 1 for an object body, 0 for a scalar/null body.

ONE-LEVEL DESCENT (MTO-nested lists): a multi-tenant envelope of the form { isMtoResponse, metadata:{...},
result:{ value:[...] } } carries its records at result.value (or result.data). When the TOP level would otherwise
be singleObject, the oracle descends ONE level into a 'result' wrapper and re-applies the wrapper test there so the
nested list is found. ItemsPath then carries the full path (@('result','value')); ItemsContainer is the LEAF key.

DETERMINISM: every place a single key is chosen from a (process-seed-randomised) hashtable, the keys are walked
Sort-Object'd, so the pick — and therefore the generated catalogue/evidence-index — is byte-reproducible across
cold processes. The oracle performs NO I/O and never throws.

STRICTMODE: hashtable members are read with the indexer ($h[$k]) and probed with .ContainsKey(...) — never with
dot-notation property access — so the oracle is safe under Set-StrictMode -Version Latest in either generator.
#>

# Canonical list-container keys · a sole array under one of these is unambiguously the record list (OData 'value',
# REST 'results'/'items'/'records'/'data', Defender 'Results'/'actions'). Matched case-insensitively. When present
# the wrapper verdict does NOT require the metadata-sibling test (the canonical key alone proves a list envelope).
$script:XdrCanonicalListKeys = @('results', 'value', 'data', 'items', 'records', 'actions')

# Pagination / list-level metadata keys · a non-array sibling whose NAME matches one of these describes the
# COLLECTION (its size, its next page, its truncation/recency), not a record field — so it does not disqualify a
# single-array object from being a list envelope. Exact set (lower-cased) plus a few robust shape patterns.
$script:XdrPaginationMetadataKeys = @(
    'count', 'total', 'totalcount', 'totalrecords', 'recordscount',
    'nextlink', 'paginationguid', 'paginationtoken', 'continuationtoken', 'skiptoken',
    'metadata', 'resulttruncated', 'isalldevicesenabled'
)

# Keys that introduce a one-level-descent envelope (MTO multi-tenant response). The records live one level down,
# under this key's nested object, at a canonical list key. Matched case-insensitively.
$script:XdrDescentEnvelopeKeys = @('result')

function Test-XdrEmptyValue {
    <# An array/object/string property counts as EMPTY (an absent/zeroed sibling that cannot be a record field):
       null · []  · {} · ''. A non-empty scalar (number/bool/non-empty string) is NOT empty. #>
    param([AllowNull()] $Value)
    if ($null -eq $Value) { return $true }
    if ($Value -is [System.Collections.IDictionary]) { return (@($Value.Keys).Count -eq 0) }
    if ($Value -is [System.Collections.IList])       { return (@($Value).Count -eq 0) }
    if ($Value -is [string])                          { return [string]::IsNullOrEmpty($Value) }
    return $false
}

function Test-XdrPaginationMetadataKey {
    <# Is this sibling key a pagination / list-level metadata descriptor (so it does NOT make the object a record)?
       Exact membership in $XdrPaginationMetadataKeys, OR an @odata./odata. prefix (OData control fields), OR a
       'contains*' collection flag, OR a name ending in count/records/truncated (record tallies) or time/timestamp
       (snapshot recency). Case-insensitive. #>
    param([Parameter(Mandatory)][string] $Key)
    $k = $Key.ToLower()
    if ($k -in $script:XdrPaginationMetadataKeys) { return $true }
    if ($k.StartsWith('@odata.') -or $k.StartsWith('odata.')) { return $true }
    if ($k.StartsWith('contains')) { return $true }
    if ($k.EndsWith('count') -or $k.EndsWith('records') -or $k.EndsWith('truncated')) { return $true }
    if ($k.EndsWith('time') -or $k.EndsWith('timestamp')) { return $true }
    return $false
}

function Get-XdrArrayPropertyKeys {
    <# The array-typed property keys of a dictionary, Sort-Object'd for a deterministic pick. #>
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Object)
    return @($Object.Keys | Where-Object { $Object[$_] -is [System.Collections.IList] } | Sort-Object { [string]$_ })
}

function Get-XdrFieldUnion {
    <# F4 (projection faithfulness · 2026-06-16) · THE union of top-level keys across ALL record items, each mapped to a
       REPRESENTATIVE value (the FIRST NON-NULL value seen for that key across the items, so the downstream
       scalar-vs-'<key>Json' classification and JSONPath stay faithful). Sparse fields that appear only in LATER items
       are therefore discovered — item[0]-only sampling silently DROPPED them (the green-but-incomplete class). Non-
       dictionary items are skipped. Returns an Ordinal [hashtable] (every consumer Sort-Object's the keys, so the
       generated artifact stays deterministic · a hashtable so callers can use .ContainsKey, which an OrderedDictionary
       lacks) or $null when no dictionary item contributes a key. Ordinal keys (a casing-distinct key is a distinct
       column · C4). NO I/O, never throws. #>
    param([AllowNull()] $Items)
    $rep = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)   # key -> representative (first non-null) value
    foreach ($it in @($Items)) {
        if ($it -isnot [System.Collections.IDictionary]) { continue }
        foreach ($k in $it.Keys) {
            $ks = [string]$k
            if (-not $rep.ContainsKey($ks)) { $rep[$ks] = $it[$k] }
            elseif (($null -eq $rep[$ks]) -and ($null -ne $it[$k])) { $rep[$ks] = $it[$k] }   # upgrade null -> first non-null
        }
    }
    if (@($rep.Keys).Count -eq 0) { return $null }
    return $rep
}

function Get-XdrWrapperKey {
    <# Apply the wrapper test to ONE object (no descent). Returns the array key that makes it a list envelope, else
       $null. Rule: a canonical-keyed array wins outright (sorted, first canonical key present that is array-typed);
       otherwise the object qualifies only when it has EXACTLY ONE array property AND every other property is empty
       or a pagination-metadata key. Deterministic (sorted walks). #>
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Object)

    # Canonical fast path · a sole array under a canonical list key is unambiguously the records list.
    foreach ($canon in $script:XdrCanonicalListKeys) {
        $hits = @($Object.Keys | Where-Object { ([string]$_).ToLower() -eq $canon -and $Object[$_] -is [System.Collections.IList] } | Sort-Object { [string]$_ })
        if (@($hits).Count -ge 1) { return [string]$hits[0] }
    }

    # @()-wrap the function result · a single-element array returned from a function unwraps to a scalar on
    # assignment, and .Count on that bare scalar throws under StrictMode (the pscustomobject/string foot-gun).
    $arrayKeys = @(Get-XdrArrayPropertyKeys -Object $Object)
    if (@($arrayKeys).Count -ne 1) { return $null }       # zero or many arrays → not a single-list envelope
    $theKey = [string]$arrayKeys[0]
    foreach ($k in ($Object.Keys | Sort-Object { [string]$_ })) {
        if ([string]$k -eq $theKey) { continue }
        if (Test-XdrEmptyValue $Object[$k]) { continue }
        if (Test-XdrPaginationMetadataKey ([string]$k)) { continue }
        return $null                                       # a substantive entity sibling → this is a record, not a list
    }
    return $theKey
}

function Get-XdrBodyShape {
    <#
    .SYNOPSIS
    Classify a parsed response body. THE oracle for live captured bodies (Build-EvidenceIndex + the Build-Catalogue
    LiveCaptured projection).
    .OUTPUTS
    A hashtable: @{
      Shape          = 'bareArray' | 'wrapper' | 'singleObject'
      ItemsContainer = <leaf array key>  (wrapper only; the descended LEAF key for an MTO-nested list) · else $null
      ItemsPath      = @(<key>[, <key>])  the full path to the array (1 element flat · 2 elements when descended) ·
                       @() for bareArray/singleObject
      FirstItem      = first array element (wrapper/bareArray) · the object itself (singleObject object body) · $null
      FieldUnion     = F4 · Ordinal [hashtable] · the UNION of top-level keys across ALL items (each → first non-null value) ·
                       $null when no dict item contributes a key · the FAITHFUL field set (item[0] alone dropped sparse fields)
      RowCount       = captured-page record count (wrapper/bareArray: element count · singleObject object: 1 · scalar/null: 0)
    }
    #>
    param([AllowNull()] $Body)

    # Top-level array → bareArray.
    if ($Body -is [System.Collections.IList]) {
        $arr = @($Body)
        return @{ Shape = 'bareArray'; ItemsContainer = $null; ItemsPath = @(); FirstItem = $(if ($arr.Count -gt 0) { $arr[0] } else { $null }); FieldUnion = (Get-XdrFieldUnion $arr); RowCount = $arr.Count }
    }

    # Scalar / null → singleObject with no rows.
    if ($Body -isnot [System.Collections.IDictionary]) {
        return @{ Shape = 'singleObject'; ItemsContainer = $null; ItemsPath = @(); FirstItem = $null; FieldUnion = $null; RowCount = 0 }
    }

    # Object · top-level wrapper test.
    $wrapKey = Get-XdrWrapperKey -Object $Body
    if ($null -ne $wrapKey) {
        $arr = @($Body[$wrapKey])
        return @{ Shape = 'wrapper'; ItemsContainer = $wrapKey; ItemsPath = @($wrapKey); FirstItem = $(if ($arr.Count -gt 0) { $arr[0] } else { $null }); FieldUnion = (Get-XdrFieldUnion $arr); RowCount = $arr.Count }
    }

    # No top-level wrapper · try a ONE-LEVEL descent into an MTO 'result' envelope ({ result: { value:[...] } }).
    foreach ($envKey in ($Body.Keys | Sort-Object { [string]$_ })) {
        if (([string]$envKey).ToLower() -notin $script:XdrDescentEnvelopeKeys) { continue }
        $inner = $Body[$envKey]
        if ($inner -isnot [System.Collections.IDictionary]) { continue }
        $innerKey = Get-XdrWrapperKey -Object $inner
        if ($null -ne $innerKey) {
            $arr = @($inner[$innerKey])
            return @{ Shape = 'wrapper'; ItemsContainer = [string]$innerKey; ItemsPath = @([string]$envKey, [string]$innerKey); FirstItem = $(if ($arr.Count -gt 0) { $arr[0] } else { $null }); FieldUnion = (Get-XdrFieldUnion $arr); RowCount = $arr.Count }
        }
    }

    # Otherwise the object is a single record.
    return @{ Shape = 'singleObject'; ItemsContainer = $null; ItemsPath = @(); FirstItem = $Body; FieldUnion = (Get-XdrFieldUnion @($Body)); RowCount = 1 }
}

function Get-XdrSchemaArrayPropertyKey {
    <#
    .SYNOPSIS
    Schema-side counterpart of Get-XdrWrapperKey, for an OpenAPI response object's 'properties' map (used by
    Build-Catalogue's Get-XdrResponseItemSchema). Picks the property whose schema is an ARRAY and that makes the
    object a list envelope, applying the SAME canonical-key + single-array discipline as the live-body oracle so the
    two paths can't diverge. A schema cannot express run-time emptiness, so the sibling test here admits only
    pagination-metadata-named siblings (it cannot see that a sibling array is empty) — the canonical fast path covers
    the common list shapes; the single-array rule covers the rest. Returns the chosen property NAME, or $null when
    the object is a single record (no array property, or several array properties with non-metadata siblings).
    .PARAMETER Properties
    The OpenAPI schema node's 'properties' dictionary (property name → property schema).
    #>
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Properties)

    # Which properties are array-typed (their schema declares type: array)? Sorted for determinism.
    $arrayProps = @($Properties.Keys | Where-Object {
            $ps = $Properties[$_]
            ($ps -is [System.Collections.IDictionary]) -and $ps.ContainsKey('type') -and ([string]$ps['type'] -eq 'array')
        } | Sort-Object { [string]$_ })

    # Canonical fast path.
    foreach ($canon in $script:XdrCanonicalListKeys) {
        $hits = @($arrayProps | Where-Object { ([string]$_).ToLower() -eq $canon } | Sort-Object { [string]$_ })
        if (@($hits).Count -ge 1) { return [string]$hits[0] }
    }

    if (@($arrayProps).Count -ne 1) { return $null }       # zero or many arrays → treat the object as a single record
    $theKey = [string]$arrayProps[0]
    foreach ($k in ($Properties.Keys | Sort-Object { [string]$_ })) {
        if ([string]$k -eq $theKey) { continue }
        if (Test-XdrPaginationMetadataKey ([string]$k)) { continue }
        return $null                                       # a non-metadata sibling property → a record, not a list
    }
    return $theKey
}
