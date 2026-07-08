# XdrLogRaider · Xdr.Common.Parser module
#
# The 3 keystone parser primitives (architectural invariants · NOT optional):
#   B1   · Per-item fan-out · 1 response array → N rows (1 event = 1 row · never collapse)
#   B1b  · Empty-element gate · drop nulls/empties BEFORE row construction (zero empty rows)
#   B3   · RawJson per-item clamp · serialize each item · 240KB LA-safe cap (RawJson always present)
#
# Why these are LOCKED: the workspace table schema commits to one row per event with the
# full raw payload in RawJson. Collapsing arrays loses fan-out; writing empty rows pollutes
# the audit signal; exceeding LA's ~256KB per-string-column cap silently truncates RawJson mid-token — each invariant exists because
# breaking it has a downstream production cost.

Set-StrictMode -Version Latest

$script:RawJsonClampBytes = 240 * 1024   # 240KB · LA-SAFE. SB2 (audit 2026-06-12): the locked "1MB RawJson floor"
                                         # is PHYSICALLY IMPOSSIBLE — Log Analytics caps a single string column at
                                         # ~256KB and SILENTLY truncates past it mid-token (live-proven: a 262144 B
                                         # value cut mid-JSON). Clamp UNDER the cap, head-preserving (Compress-XdrRawJson).
# SINGLE canonical Log-Analytics reserved-column list (R1 single-source · plan §32 · P1/P2). The schema
# generator (Build-PerCategorySchema) and Validate-Manifests import Get-XdrSafeColumnName so the parser's
# OUTPUT column name ALWAYS equals the generated DCR/table column name. Convention = LA's own collision
# suffix `<name>_x` (replaces the divergent parser `Xdr_<name>` vs generator `<name>_x`). The list MUST be the full
# documented LA custom-table reserved set (Microsoft Learn · create-custom-table) — cat-1 live-proved an INCOMPLETE
# list fails the table DEPLOY (`Columns 'title' are invalid or reserved`), which NEITHER the offline schema gate NOR
# `az deployment group what-if` catches (only the real table PUT validates column names). `id` is NOT reserved on the
# live estate (the cat-1 deploy created an `id` column fine AND the pilot already ships `id`), so it is DELIBERATELY
# excluded; `_`-prefixed reserved names (`_ResourceGroup`/`_SubscriptionId`/…) are handled by the `^_` branch below
# (which strips the leading `_`), so they are not duplicated here. `kind` is BACKEND-reserved but NOT in the MS doc's
# enumerated list — cat-6 (Configuration · ListUnifiedConnectors) live-proved the table PUT rejects it (`Columns
# 'kind' are invalid or reserved`); the doc list is therefore a SUBSET of what the backend rejects, so the table PUT
# (NEW-category Onboard-CategorySurgical -Apply) is the ONLY authoritative validator — a reserved-name deploy failure
# = add the name here + redeploy (§4.B reserved-column axis · the PUT lists ALL reserved cols at once, so one redeploy).
$script:XdrLaReservedColumns = @('TimeGenerated','Type','_ResourceId','TenantId','SourceSystem','Computer','MG','ResourceProviderType','_TimeReceived','_ItemId','Title','UniqueId','BilledSize','IsBillable','InvalidTimeGenerated','kind','date','mdm')
$script:ProjectionMapLaReservedKeys = $script:XdrLaReservedColumns  # back-compat alias for existing refs

function Get-XdrCategoryToken {
    <#
    .SYNOPSIS
    THE single canonical Category→token rewrite (WS2.2 · the spaced-category seam). 8 of 10 Defender categories
    carry spaces/'&' ("Cloud Apps", "Analytics & Data"); table/stream/manifest/env-var names must use ONE
    tokenization everywhere or the chain mismatches (catalogue said Defender_CloudApps_CL while the schema
    generator built Defender_Cloud Apps_CL). Build-Catalogue, Generate-Manifest and Build-PerCategorySchema all
    import THIS function. Strips every non-alphanumeric character; deterministic; idempotent.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Category)
    return ($Category -replace '[^A-Za-z0-9]', '')
}

function Get-XdrArmGuid {
    <#
    .SYNOPSIS
    Reproduce the ARM/Bicep template `guid(arg1, arg2, ...)` function OFFLINE, byte-for-byte, in PowerShell.

    .DESCRIPTION
    ARM `guid()` is NOT "SHA-256 first-16-bytes" and NOT a random GUID. It is a deterministic RFC 4122 §4.3 /
    RFC 9562 §5.5 NAME-BASED, version-5 UUID over a FIXED Azure namespace. Microsoft documents this on the Bicep
    string-functions page: the arguments are each converted to a string and concatenated with a HYPHEN '-' delimiter,
    hashed (SHA-1) under the namespace GUID `11fb06fb-712d-4ddd-98c7-e71bbd588830`, version forced to 5, variant forced
    to RFC-4122. So `guid('a','b','c')` == uuid5(11fb06fb-…, "a-b-c").

    WHY this exists (single-source · WS-card-sync Defect-1): tools/Onboard-CategorySurgical.ps1 must create the per-DCR
    'Monitoring Metrics Publisher' role assignment with the EXACT SAME deterministic NAME that deploy/mainTemplate.json
    computes via ARM `guid(resourceId('…/dataCollectionRules', dcrName), principalId, 'MMP-DCR-<cat>')`. If the surgical
    onboard instead lets `az role assignment create` mint a RANDOM-GUID name, a later FULL mainTemplate re-deploy issues
    an ARM roleAssignment PUT under the guid()-name; ARM keys roleAssignment idempotency on the assignment NAME, so a
    PUT of a NEW name for a (principal, role, scope) tuple that already exists under a DIFFERENT (random) name 409s
    `RoleAssignmentExists` and rolls back the whole deploy (live-caught · also blocks the GA fresh-deploy gate). Naming
    the surgical role with THIS function (== the template's guid()) makes the re-deploy an idempotent same-name no-op.

    Verified byte-exact against the RFC 9562 §A.4 worked example and Python uuid.uuid5 known-answer vectors
    (tests/unit/Xdr.Common.Parser/ArmGuid.Tests.ps1). Mirrors Get-XdrCategoryToken / Get-XdrArtifactTransformKql:
    ONE implementation both the surgical onboard and any future caller share so they can never drift from the template.

    .PARAMETER Arguments
    The ARM `guid()` positional arguments, in order, each already a string (the caller stringifies non-strings exactly as
    ARM would — for the role-name use case every arg is already a string / resource-id / principalId).

    .PARAMETER Namespace
    The name-based UUID namespace. Defaults to ARM's fixed namespace; never pass anything else for ARM-`guid()` parity.

    .OUTPUTS
    [string] · lowercase 8-4-4-4-12 GUID identical to what ARM `guid(...)` would compute for the same arguments.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [string] $Namespace = '11fb06fb-712d-4ddd-98c7-e71bbd588830'
    )
    # ARM joins the stringified arguments with a literal hyphen (guid('a','b') != guid('ab')).
    $name = ($Arguments -join '-')
    $ns   = [guid]$Namespace
    # RFC 4122 §4.3: hash = SHA1( namespaceBytes(BIG-ENDIAN / network order) || UTF-8(name) ). .NET stores a Guid's
    # first three fields little-endian, so ToByteArray($true) (the .NET 8+ overload) yields network byte order directly.
    $nsBytes   = $ns.ToByteArray($true)
    $nameBytes = [System.Text.Encoding]::UTF8.GetBytes($name)
    $buffer = [byte[]]::new($nsBytes.Length + $nameBytes.Length)
    [Array]::Copy($nsBytes, 0, $buffer, 0, $nsBytes.Length)
    [Array]::Copy($nameBytes, 0, $buffer, $nsBytes.Length, $nameBytes.Length)
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try { $hash = $sha1.ComputeHash($buffer) } finally { $sha1.Dispose() }
    # Take the first 16 bytes; set the version (5) nibble and the RFC-4122 variant bits.
    $g = [byte[]]::new(16)
    [Array]::Copy($hash, 0, $g, 0, 16)
    $g[6] = [byte](($g[6] -band 0x0F) -bor 0x50)   # version 5
    $g[8] = [byte](($g[8] -band 0x3F) -bor 0x80)   # RFC-4122 variant (10xxxxxx)
    # Render directly from the big-endian bytes (the hash output IS network order) as canonical lowercase 8-4-4-4-12 —
    # do NOT round-trip through [guid][byte[]] here, which would re-interpret the first 3 fields as little-endian.
    $hex = -join ($g | ForEach-Object { $_.ToString('x2') })
    return ('{0}-{1}-{2}-{3}-{4}' -f $hex.Substring(0,8), $hex.Substring(8,4), $hex.Substring(12,4), $hex.Substring(16,4), $hex.Substring(20,12))
}

function Get-XdrArtifactTransformKql {
    <#
    .SYNOPSIS
    THE single-source carry of a per-category-schema artifact's DCR dataFlow transformKql into a deploy template.
    BOTH deploy writers — dev-tools/Build-MainTemplate.ps1 (the SOLE marketplace-template writer) and
    tools/Onboard-CategorySurgical.ps1 (the surgical per-category add) — call THIS; neither hardcodes 'source' at
    the dataFlow. Under approach B (type-at-source · 2026-06-16) every category's transformKql is the uniform identity
    'source' (the parser emits NATIVE LA types, so the DCR needs no coercion); this helper is the STRUCTURAL INVARIANT
    that a deploy writer must not DROP or REWRITE the artifact's transformKql — the historical bug was hardcoding
    'source', which silently overrides any future non-identity transform. Fallback to 'source' iff absent/blank.
    Mirrors Get-XdrCategoryToken's role: ONE implementation both deploy assemblers share so they can never drift.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $DcrResource)
    $xform = if ($DcrResource.properties.PSObject.Properties['dataFlows'] -and @($DcrResource.properties.dataFlows).Count -gt 0) {
        [string]@($DcrResource.properties.dataFlows)[0].transformKql
    } else { 'source' }
    if ([string]::IsNullOrWhiteSpace($xform)) { $xform = 'source' }
    return $xform
}

function Get-XdrSafeColumnName {
    <#
    .SYNOPSIS
    Canonical LA-reserved-column rewrite · the ONE function parser + schema-generator + validator all use so
    a projected column name is identical everywhere. Reserved name -> `<name>_x`; leading-underscore name
    (LA rejects '^_' · e.g. OData/system '_etag') -> `<stripped>_x`; otherwise unchanged.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Name)
    if ($script:XdrLaReservedColumns -contains $Name) { return "${Name}_x" }
    # Envelope-collision rewrite: a projected column whose name case-collides (LA column names are case-INSENSITIVE)
    # with one of the universal envelope columns (Category/Subcategory/Operation/Portal/RecordId/ParentRecordId/
    # CorrelationId/RawJson/TimeGenerated) would be a DUPLICATE LA column, and the parser's envelope value would fight the projected
    # value. Suffix `_x` (the same discipline as the reserved rewrite) so the projected field coexists. Single-sourced
    # from $XdrEnvelopeColumns (resolved at call time, after module load) so it can never drift from the envelope.
    # cat-1 ExposureManagement surfaced this: a recommendation's `category` field vs the table-group `Category` envelope.
    if (($script:XdrEnvelopeColumns.name) -contains $Name) { return "${Name}_x" }
    # LA column names MUST start with a letter (Log Analytics rejects a leading '_' with
    # "Cannot start with reserved prefix '_'"). A field like '_etag' (OData/system metadata) would
    # 400 the table/DCR deploy. Strip leading underscores and apply the same '_x' suffix convention so
    # the result is LA-valid, deterministic, idempotent, and distinct from a sibling like 'eTag'.
    if ($Name -match '^_') {
        $stripped = ($Name -replace '^_+', '')
        if ([string]::IsNullOrEmpty($stripped) -or $stripped -notmatch '^[A-Za-z]') { $stripped = "Col$stripped" }
        return "${stripped}_x"
    }
    # Any remaining LA-invalid column name: invalid characters (e.g. '@odata.context' carries '@' and '.'), or a
    # non-letter lead that is not a leading underscore. LA custom columns MUST match ^[A-Za-z][A-Za-z0-9_]* or the
    # live table-create 400s ("invalid or reserved"). Strip every non-[A-Za-z0-9_], guarantee a letter lead, then
    # apply the same deterministic '_x' suffix. (Portal Services: CheckAppGovernanceOnboarding '@odata.context'.)
    if ($Name -notmatch '^[A-Za-z][A-Za-z0-9_]*$') {
        $sanitized = ($Name -replace '[^A-Za-z0-9_]', '')
        if ([string]::IsNullOrEmpty($sanitized) -or $sanitized -notmatch '^[A-Za-z]') { $sanitized = "Col$sanitized" }
        return "${sanitized}_x"
    }
    return $Name
}

# SINGLE canonical envelope schema (R1 single-source · plan §35.5/§35.6 · v12 §4.3 adds Subcategory). The 8 columns
# present in EVERY Category's DCR-stream + workspace table, independent of ProjectionMap. The parser produces 6 of
# them per row (TimeGenerated/Portal/Category/Subcategory/Operation/RawJson · ConvertTo-XdrRows); the runtime injects
# the other 3 (CorrelationId/RecordId/ParentRecordId) post-parse in Invoke-XdrEntryPoll. The schema generator
# (Build-PerCategorySchema) DECLARES all 9 and Validate-Manifests COUNTS all 9 — both derive from THIS list so the
# envelope can never drift. Subcategory is the nodoc tag within the Category(group) table (v12 per-group model · e.g.
# Defender_Operations_CL · Subcategory=ActionCenter). F2 (2026-06-16): dropped OperationKey (duplicated Operation),
# added RecordId (= the composite NaturalKey · the exactly-once dedup identity) + ParentRecordId (the entity-DAG link).
# NO TenantId: it is LA-reserved; a Category mapping a tenant field gets TenantId_x via Get-XdrSafeColumnName.
$script:XdrEnvelopeColumns = @(
    @{ name = 'TimeGenerated';  type = 'datetime' }
    @{ name = 'Portal';         type = 'string'   }
    @{ name = 'Category';       type = 'string'   }
    @{ name = 'Subcategory';    type = 'string'   }   # v12 §4.3 · nodoc tag within the per-group table
    @{ name = 'Operation';      type = 'string'   }
    @{ name = 'RecordId';       type = 'string'   }   # F2 · the SAME composite NaturalKey the exactly-once dedup computes ($keyOf · single-sourced, can't diverge) · the row's identity for lineage · runtime-injected
    @{ name = 'ParentRecordId'; type = 'string'   }   # F2 · the fan-out parent entity id (entity-DAG link · '' for a non-fan-out row) · runtime-injected
    @{ name = 'CorrelationId';  type = 'string'   }   # runtime-injected post-parse (Invoke-XdrEntryPoll)
    @{ name = 'RawJson';        type = 'string'   }   # B3 keystone · per-item · 240KB LA-safe clamp
)

function Get-XdrEnvelopeColumns {
    <#
    .SYNOPSIS
    The ONE canonical envelope-column list (name+type) the schema generator declares and the validator counts.
    Returns a fresh copy so callers cannot mutate the shared definition.
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param()
    # Return fresh copies (callers can't mutate the shared definition) as a plain array — NOT a List wrapped in
    # the `,` comma operator (that returns the collection as ONE object, so callers' @() collect 1 element not 7).
    return @($script:XdrEnvelopeColumns | ForEach-Object { @{ name = $_.name; type = $_.type } })
}

# ===========================
# B1 · Per-item fan-out
# ===========================

function ConvertTo-XdrRows {
    <#
    .SYNOPSIS
    Convert a parsed JSON response into N rows · ONE PER ITEM (B1 keystone).
    Applies B1b empty-element gate + B3 RawJson per-item clamp.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[hashtable]])]
    param(
        [Parameter(Mandatory)] [AllowNull()] $ResponseBody,
        [Parameter(Mandatory)] [string] $OperationKey,
        [Parameter()] [string] $Portal = 'Defender',
        [Parameter(Mandatory)] [string] $Category,
        [Parameter()] [string] $Subcategory = '',
        [Parameter()] [string] $ResponseShape = 'auto',
        [Parameter()] [string] $ItemsContainer = '',
        [hashtable] $ProjectionMap = @{},
        [hashtable] $ColumnTypes = @{}
    )

    # B1b · empty-element gate · null/empty response → 0 rows (never write error rows to workspace)
    $rows = [System.Collections.Generic.List[hashtable]]::new()
    if ($null -eq $ResponseBody) { return ,$rows }

    # G2/G9 · Resolve items for BOTH -AsHashtable (IDictionary · the runtime's shape) AND PSCustomObject bodies,
    # honoring the manifest's explicit ResponseShape+ItemsContainer first. Single-sourced through Resolve-XdrItemArray
    # so the RAW (pre-empty-gate) item array here and Get-XdrResponseItemCount (the pagination page-fullness count ·
    # E-MAJ3) can NEVER diverge — one resolution, two consumers.
    $items = Resolve-XdrItemArray -ResponseBody $ResponseBody -ResponseShape $ResponseShape -ItemsContainer $ItemsContainer

    if (@($items).Count -eq 0) { return ,$rows }

    # Fan out · ONE row per item
    foreach ($item in $items) {
        # B1b · empty-element gate
        if (Test-XdrEmptyElement -Item $item) { continue }

        # B3 · RawJson per-item clamp. F3 · pass the projected NON-SCALAR top-level fields (each already captured in
        # full in its own <key>Json column) as stub-fields: if the item is over the LA cap, RawJson stubs them (no
        # double-storage · no data loss · the data is in the column) so the clamp stays a DORMANT never-hit floor.
        $rawStubFields = Get-XdrProjectedNonScalarFields -Item $item -ProjectionMap $ProjectionMap
        $rawJson = Compress-XdrRawJson -Item $item -MaxBytes $script:RawJsonClampBytes -StubFields $rawStubFields

        # Build row · 6 envelope cols the parser fills (CorrelationId/RecordId/ParentRecordId injected post-parse · F2).
        $row = @{
            TimeGenerated = (Get-Date).ToUniversalTime().ToString('o')
            Portal       = $Portal
            Category     = $Category
            Subcategory  = $Subcategory
            Operation    = $OperationKey
            RawJson      = $rawJson
        }
        # F2 · OperationKey dropped (it duplicated Operation). RecordId + ParentRecordId + CorrelationId are
        # runtime-injected post-parse in Invoke-XdrEntryPoll (RecordId needs the op's NaturalKey · ParentRecordId the
        # fan-out parent · both unavailable to the pure parser), exactly like CorrelationId already was.

        # Apply ProjectionMap (per-Op typed columns)
        if ($ProjectionMap -and $ProjectionMap.Count -gt 0) {
            $typedCols = Apply-XdrProjectionMap -Item $item -ProjectionMap $ProjectionMap -ColumnTypes $ColumnTypes -OperationKey $OperationKey
            foreach ($k in $typedCols.Keys) { $row[$k] = $typedCols[$k] }
        }

        $rows.Add($row)
    }

    return ,$rows  # comma-operator preserves list identity (PowerShell unwraps single-element arrays · the comma keeps the List<hashtable> shape for the caller's foreach).
}

# Single-source row-array resolver · the ONE place ResponseShape→items mapping lives. ConvertTo-XdrRows (the parser)
# AND Get-XdrResponseItemCount (the pagination page-fullness count · E-MAJ3) both call it, so the RAW item array used
# for row construction and the count used for "is there a next page?" can NEVER diverge.
#   bareArray    → the body IS the array.
#   singleObject → the body is ONE item (1-element array).
#   wrapper      → the array under the manifest ItemsContainer (PreferKeys); the magic-name list is a LEGACY fallback
#                  ONLY for an explicit wrapper that did not declare a container.
#   auto / other → E-MAJ4 · DO NOT magic-name-guess a container (a guess can fan out the WRONG array · e.g. picking a
#                  metadata 'value'/'data' that isn't the record list). Treat the body as ONE singleObject item — the
#                  RawJson-floor-safe default that never drops data and never mis-fans. Row extraction comes from
#                  manifest DATA (ResponseShape + ItemsContainer), not a name guess.
function script:Resolve-XdrItemArray {
    param($ResponseBody, [string]$ResponseShape = 'auto', [string]$ItemsContainer = '')
    if ($null -eq $ResponseBody) { return @() }
    switch ($ResponseShape) {
        'bareArray'    { return @($ResponseBody) }
        'singleObject' { return @($ResponseBody) }
        'wrapper' {
            $prefer = @(); if (-not [string]::IsNullOrWhiteSpace($ItemsContainer)) { $prefer += $ItemsContainer }
            # AllowMagicFallback only for an explicit wrapper (so a declared-shape op without a container still resolves
            # its canonical list key · back-compat); 'auto' below never reaches this branch.
            return (Resolve-XdrResponseItems -ResponseBody $ResponseBody -PreferKeys $prefer -AllowMagicFallback)
        }
        default {
            # 'auto' (or any unknown shape) · E-MAJ4 · a manifest-declared ItemsContainer is still honored (it is DATA,
            # not a guess); ABSENT one → singleObject (the body is ONE item · NEVER a magic-name container guess).
            if (-not [string]::IsNullOrWhiteSpace($ItemsContainer)) {
                return (Resolve-XdrResponseItems -ResponseBody $ResponseBody -PreferKeys @($ItemsContainer))   # NO magic fallback
            }
            return @($ResponseBody)   # singleObject fallback · safe-not-guessing
        }
    }
}

function script:Resolve-XdrResponseItems {
    param($ResponseBody, [string[]]$PreferKeys = @(), [switch]$AllowMagicFallback)
    # Resolve the row array from a wrapper body. PreferKeys (the manifest ItemsContainer · DATA) are tried FIRST and
    # ALWAYS. The magic-name list (a guess) is appended ONLY when -AllowMagicFallback is set (an explicit `wrapper`
    # shape with no declared container · E-MAJ4: `auto` never passes it, so `auto` can never magic-fan the wrong array).
    if ($ResponseBody -is [System.Array]) { return @($ResponseBody) }
    if ($ResponseBody -is [string]) { return @() }  # malformed · skip
    $keys = @($PreferKeys | Where-Object { $_ })
    if ($AllowMagicFallback) { $keys += @('Results','results','value','data','items','actions','devices','alerts','records','rows','entities') }
    if ($ResponseBody -is [System.Collections.IDictionary]) {
        foreach ($wrapKey in $keys) {
            if ($ResponseBody.ContainsKey($wrapKey)) {
                $inner = $ResponseBody[$wrapKey]
                if ($inner -is [System.Array]) { return @($inner) }
            }
        }
        return @($ResponseBody)  # single object
    }
    if ($ResponseBody.PSObject -and $ResponseBody.PSObject.Properties) {
        $propNames = @($ResponseBody.PSObject.Properties.Name)
        foreach ($wrapKey in $keys) {
            if ($propNames -contains $wrapKey) {
                $inner = $ResponseBody.$wrapKey
                if ($inner -is [System.Array]) { return @($inner) }
            }
        }
        return @($ResponseBody)
    }
    return @()
}

function Get-XdrResponseItemCount {
    <#
    .SYNOPSIS
    E-MAJ3 · the RAW (pre-empty-gate) item count for a response, resolved via the SAME manifest DATA (ResponseShape +
    ItemsContainer) ConvertTo-XdrRows uses. The page-fullness pagination decision ("is there a next page?") MUST key on
    THIS raw count vs PageSize — NOT on the post-empty-gate row count (ConvertTo-XdrRows output), because a page that
    contained dropped empty/all-null elements would then test SHORT and stop pagination EARLY → silent under-fetch.
    The empty-gate (B1b) must affect what is INGESTED, never what is PAGINATED. Returns 0 for a null/string/scalar body.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter()] [AllowNull()] $ResponseBody,
        [Parameter()] [string] $ResponseShape = 'auto',
        [Parameter()] [string] $ItemsContainer = ''
    )
    if ($null -eq $ResponseBody) { return 0 }
    return @(Resolve-XdrItemArray -ResponseBody $ResponseBody -ResponseShape $ResponseShape -ItemsContainer $ItemsContainer).Count
}

# ===========================
# B1b · Empty-element gate
# ===========================

function Test-XdrEmptyElement {
    <#
    .SYNOPSIS
    Detect empty/null/error rows that MUST NOT be ingested (req #2).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, ValueFromPipeline)] [AllowNull()] $Item)

    if ($null -eq $Item) { return $true }
    if ($Item -is [string]) { return [string]::IsNullOrWhiteSpace($Item) }
    if ($Item -is [System.Array] -and $Item.Count -eq 0) { return $true }
    if ($Item -is [System.Collections.IDictionary]) { return $Item.Count -eq 0 }
    # A bare scalar (bool/number) is a VALID datum — NEVER "empty" (false/0/0.0 are real values · the scalar Value-col
    # class: a GET op whose whole body is a scalar projects to a single `Value` col via '$').
    if ($Item -is [bool] -or $Item -is [int] -or $Item -is [long] -or $Item -is [double] -or $Item -is [decimal] -or $Item -is [single]) { return $false }
    if ($Item.PSObject -and $Item.PSObject.Properties) {
        $propCount = @($Item.PSObject.Properties).Count
        if ($propCount -eq 0) { return $true }
        # All-null/all-empty check
        $allEmpty = $true
        foreach ($p in $Item.PSObject.Properties) {
            if ($null -ne $p.Value -and "$($p.Value)".Trim() -ne '') {
                $allEmpty = $false
                break
            }
        }
        return $allEmpty
    }
    return $false
}

# ===========================
# B3 · RawJson per-item 240KB LA-safe clamp
# ===========================

function script:Get-XdrProjectedNonScalarFields {
    # F3 · the TOP-LEVEL item fields that are (a) projected via a top-level ProjectionMap path '$.<field>' AND (b)
    # non-scalar (array/object) in THIS item — so their full content lands in their own <key>Json column and RawJson
    # may STUB them (over-cap) without losing data. Returns @() for a scalar item / empty ProjectionMap.
    param([AllowNull()] $Item, [hashtable] $ProjectionMap = @{})
    if (($Item -isnot [System.Collections.IDictionary]) -or (-not $ProjectionMap) -or ($ProjectionMap.Count -eq 0)) { return @() }
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($col in @($ProjectionMap.Keys)) {
        if ([string]$ProjectionMap[$col] -match '^\$\.([A-Za-z0-9_]+)$') {
            $f = $Matches[1]
            if ($Item.Contains($f)) {
                $fv = $Item[$f]
                if ((($fv -is [System.Collections.IList]) -or ($fv -is [System.Collections.IDictionary]) -or ($fv -is [pscustomobject])) -and (-not $out.Contains($f))) { [void]$out.Add($f) }
            }
        }
    }
    return @($out)
}

function Compress-XdrRawJson {
    <#
    .SYNOPSIS
    Serialize one item to compact JSON · clamp LA-SAFE + HEAD-PRESERVING · CRITICAL keystone (req #7).
    SB2 (audit 2026-06-12): Log Analytics SILENTLY truncates a string column past its ~256KB cap MID-TOKEN →
    invalid JSON (live-proven). The locked "1MB floor" is physically impossible here. Clamp UNDER the LA cap and
    preserve a HEAD inside a VALID-JSON observable envelope so the row stays queryable + the truncation is visible
    (never silent, never all-content-dropped). Markers __xdrlr_truncated / __xdrlr_original_bytes are kept (back-compat).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $Item,
        [int] $MaxBytes = 245760,   # 240KB · under LA's 256KB per-string-column cap
        [string[]] $StubFields = @()   # F3 · projected non-scalar top-level fields (their full content is in their own <key>Json cols)
    )

    try {
        $json = $Item | ConvertTo-Json -Depth 25 -Compress -ErrorAction Stop
        $bytes = [System.Text.Encoding]::UTF8.GetByteCount($json)
        if ($bytes -le $MaxBytes) { return $json }

        # F3 · OVER THE CAP → first STUB the projected non-scalar fields (their full content is already in their own
        # <key>Json columns, so RawJson needn't double-store them). Replace each with a compact in-column marker and
        # re-serialize: the clamp becomes a DORMANT floor — only a SINGLE field genuinely > the cap (rare) still falls
        # through to head-preservation. No data loss (the data is in the column), no schema change, generic.
        if (@($StubFields).Count -gt 0 -and ($Item -is [System.Collections.IDictionary])) {
            $stubbed = [ordered]@{}
            foreach ($k in $Item.Keys) {
                if (@($StubFields) -contains [string]$k) { $stubbed[[string]$k] = @{ __xdrlr_in_column = $true } }
                else { $stubbed[[string]$k] = $Item[$k] }
            }
            $sjson  = $stubbed | ConvertTo-Json -Depth 25 -Compress
            $sbytes = [System.Text.Encoding]::UTF8.GetByteCount($sjson)
            if ($sbytes -le $MaxBytes) { return $sjson }
            $json = $sjson; $bytes = $sbytes   # still over (a single jumbo field) → head-preserve the stubbed form
        }

        # Over the LA cap → preserve a HEAD inside a valid-JSON envelope, sized to fit. Embedding the head as a JSON
        # string ~doubles it (internal quotes escape), so start conservatively and shrink until the envelope fits.
        $headChars = [Math]::Min($json.Length, 100000)
        for ($i = 0; $i -lt 8; $i++) {
            $env = @{
                __xdrlr_truncated      = $true
                __xdrlr_original_bytes = $bytes
                __xdrlr_la_cap_bytes   = $MaxBytes
                __xdrlr_head           = $json.Substring(0, $headChars)
            } | ConvertTo-Json -Depth 3 -Compress
            if ([System.Text.Encoding]::UTF8.GetByteCount($env) -le $MaxBytes) { return $env }
            $headChars = [int]($headChars * 0.6)
            if ($headChars -lt 500) { break }
        }
        # Pathological (cannot fit even a tiny head) → marker-only · still valid JSON, still observable.
        return (@{ __xdrlr_truncated = $true; __xdrlr_original_bytes = $bytes; __xdrlr_la_cap_bytes = $MaxBytes; __xdrlr_head = '' } | ConvertTo-Json -Compress)
    } catch {
        return ('{"__xdrlr_serialize_failed":true,"__xdrlr_error":"' + ($_.Exception.Message -replace '"','\\"') + '"}')
    }
}

# ===========================
# ProjectionMap application (per-Op typed cols · LA-reserved key rewrite)
# ===========================

function script:ConvertTo-XdrLaScalarString {
    # SB1 · coerce a SCALAR projection value to a Log-Analytics-string-safe string with SOURCE FIDELITY.
    # The typed columns are string-typed and the DCE upload JSON-serializes the row — a native bool/number sent
    # to a string column is SILENTLY NULLED by LA (live-confirmed 2026-06-12). bool → lowercase 'true'/'false'
    # (matches the RawJson · NOT PowerShell's 'True'); numbers → invariant culture; datetime/offset → ISO-8601
    # 'o'; string → UNCHANGED (B-25: never double-encode a string). Order matters: datetime is IFormattable too,
    # so it must be handled BEFORE the numeric IFormattable catch-all.
    param($Value)
    if ($Value -is [string])                { return $Value }
    if ($Value -is [bool])                  { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [datetime])              { return ([datetime]$Value).ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture) }
    if ($Value -is [System.DateTimeOffset]) { return ([System.DateTimeOffset]$Value).ToString('o', [System.Globalization.CultureInfo]::InvariantCulture) }
    if ($Value -is [System.IFormattable])   { return ([System.IFormattable]$Value).ToString($null, [System.Globalization.CultureInfo]::InvariantCulture) }
    return [System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture)
}

function script:ConvertTo-XdrTypedColumnValue {
    # B (type-at-source · 2026-06-16 · operator-decided over the A DCR-transform): emit the NATIVE Log-Analytics type for
    # a TYPED projection column (from curation ColumnTypes) so the DCR stream + table declare native types and the dataFlow
    # transformKql stays the UNIFORM 'source' (no per-category coercion · one DCR shape for every category · the type is
    # applied at the EARLIEST point = the parser = source). The DCE upload ($rowList | ConvertTo-Json · Ingest) preserves a
    # native [double]/[long]/[int]/[bool], which lands in the native column directly. datetime → ISO-8601 string (LA coerces
    # string→datetime leniently at the stream boundary · the ONE proven cross-type coercion · the pilot's TimeGenerated).
    # string/untyped/unknown → source-fidelity string (B-25 · no double-encode). A value that won't convert → $null
    # (graceful · the cell lands null, the row still ingests · matches the A transform's toreal('bad')→null). ColumnTypes
    # is the SAME curation DATA the schema generator types from — ONE source of truth, applied here at source.
    param($Value, [string] $ColumnType)
    switch ($ColumnType) {
        'real' {
            if ($Value -is [double] -or $Value -is [single] -or $Value -is [int] -or $Value -is [long]) { return [double]$Value }
            $d = [double]0
            if ([double]::TryParse([string]$Value, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
            return $null
        }
        'long' {
            if ($Value -is [long] -or $Value -is [int]) { return [long]$Value }
            $l = [long]0
            if ([long]::TryParse([string]$Value, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$l)) { return $l }
            return $null
        }
        'int' {
            if ($Value -is [int] -or $Value -is [long]) { return [int]$Value }
            $i = [int]0
            if ([int]::TryParse([string]$Value, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$i)) { return $i }
            return $null
        }
        'boolean' {
            if ($Value -is [bool]) { return $Value }
            switch (([string]$Value).Trim().ToLowerInvariant()) {
                'true'  { return $true }
                '1'     { return $true }
                'false' { return $false }
                '0'     { return $false }
                default { return $null }
            }
        }
        default {
            # datetime → ISO-8601 string (stream=datetime + transformKql='source' coerces it) · string/untyped → string
            return (ConvertTo-XdrLaScalarString -Value $Value)
        }
    }
}

function Apply-XdrProjectionMap {
    <#
    .SYNOPSIS
    Apply ProjectionMap to extract per-Op typed columns from raw item.
    ProjectionMap format: @{ targetCol = 'jsonpath' } · e.g. @{ ActionId = '$.id'; Status = '$.status' }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] $Item,
        [Parameter(Mandatory)] [hashtable] $ProjectionMap,
        [hashtable] $ColumnTypes = @{},
        [string] $OperationKey = ''
    )

    $result = @{}
    if (-not $ProjectionMap -or $ProjectionMap.Count -eq 0) { return $result }

    foreach ($targetCol in $ProjectionMap.Keys) {
        $sourcePath = $ProjectionMap[$targetCol]

        # LA-reserved column rewrite via the SINGLE canonical function (shared with the schema generator +
        # Validate-Manifests so the parser's output column name == the generated DCR/table column name).
        # Reserved name -> `<name>_x`; otherwise unchanged.
        $safeCol = Get-XdrSafeColumnName -Name $targetCol

        # Resolve JSONPath
        $value = Resolve-XdrJsonPath -Item $item -Path $sourcePath
        if ($null -ne $value) {
            # B (type-at-source) · the DCE upload does `$rowList | ConvertTo-Json` (Ingest.psm1), which PRESERVES native
            # JSON types, and under B the DCR stream column is declared with the SAME native type as the table — so a
            # native [bool]/[long]/[double] lands correctly in its native column (no string round-trip, no coercion). Non-
            # scalars (arrays/objects) → compact JSON string; scalars → ConvertTo-XdrTypedColumnValue emits the NATIVE typed
            # value for a TYPED projection column (real/long/int/boolean), or a source-fidelity string for an untyped column
            # and an ISO-8601 'o' string for datetime (LA coerces · string UNCHANGED, no double-encode), bad-value → $null.
            $isNonScalar = ($value -isnot [string]) -and (
                ($value -is [System.Array]) -or
                ($value -is [System.Collections.IList]) -or
                ($value -is [System.Collections.IDictionary]) -or
                ($value -is [pscustomobject])
            )
            if ($isNonScalar) {
                try {
                    $value = $value | ConvertTo-Json -Compress -Depth 10 -ErrorAction Stop
                } catch {
                    # INTENTIONAL-FAIL-SAFE: ConvertTo-Json failure on edge type · fall back to ToString().
                    # Better to land a serialized representation than drop the column.
                    $value = "$value"
                }
            } else {
                # B (type-at-source) · emit the NATIVE LA type for a TYPED projection column (real/long/int/boolean) so the
                # DCR stream+table are native and transformKql stays the uniform 'source'; datetime→ISO string (LA coerces),
                # string/untyped→string, bad-value→$null (graceful). ColumnTypes keys are the ORIGINAL ProjectionMap names
                # (pre-_x-rewrite) — the SAME keys the schema generator's ColumnTypes consumer uses ($targetCol, not $safeCol).
                $colType = if ($ColumnTypes -and $ColumnTypes.ContainsKey($targetCol)) { [string]$ColumnTypes[$targetCol] } else { 'string' }
                $value = ConvertTo-XdrTypedColumnValue -Value $value -ColumnType $colType
            }
            $result[$safeCol] = $value
        }
    }

    return $result
}

# Read a single named property off a dict / PSObject node. Returns @{ found=<bool>; value=<obj> } so a
# present-but-$null value is distinguishable from an absent key (the walker stops on absent, passes $null through).
function script:Get-XdrNodeProperty {
    param($Node, [string]$Name)
    if ($Node -is [System.Collections.IDictionary]) {
        if ($Node.ContainsKey($Name)) { return @{ found = $true; value = $Node[$Name] } }
        return @{ found = $false; value = $null }
    }
    if ($Node -and $Node.PSObject -and ($Node.PSObject.Properties.Name -contains $Name)) {
        return @{ found = $true; value = $Node.$Name }
    }
    return @{ found = $false; value = $null }
}

# As-array coercion for wildcard fan-out. A real array/IList → itself; a single object → 1-element wrap;
# strings are NOT enumerable here (a string is one value, never a char list). $null → empty.
function script:ConvertTo-XdrArray {
    param($Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [string]) { return @($Value) }
    if ($Value -is [System.Collections.IDictionary]) { return @($Value) }   # a dict is ONE item, not its entries
    if ($Value -is [System.Array] -or $Value -is [System.Collections.IList]) { return @($Value) }
    return @($Value)
}

function script:Resolve-XdrJsonPath {
    <#
    .SYNOPSIS
    Resolve a JSONPath against a parsed item. Supports dot-walk · single `[N]` index · NESTED dictionaries/objects
    of arbitrary depth · and the `[*]` WILDCARD over an array (plan U3 · §16.2 nested/wildcard JSONPath).

    Wildcard semantics:
      $.a.b[*]      → the WHOLE array at a.b (Apply-XdrProjectionMap serializes the non-scalar to JSON · array typed).
      $.a.b[*].c    → fan: collect `.c` from EACH element of the a.b array → a list (then JSON-serialized).
      $.a[*].b[*]   → nested fan: flatten one level per wildcard.
    A `[*]` over a non-array scalar fans that single value (1-element list). RawJson floor is unaffected — the
    resolver only ever READS; a miss returns $null and the typed column is simply omitted (data still in RawJson).

    Flat / single-index paths take the original iterative fast-path UNCHANGED (byte-identical resolution · the
    GetHistory replay relies on it) — recursion is entered ONLY when a `[*]` wildcard segment is present.
    #>
    param($Item, [string]$Path)

    if ($null -eq $Item -or [string]::IsNullOrWhiteSpace($Path)) { return $null }
    if ($Path -eq '$' -or $Path -eq '$.') { return $Item }

    # Strip leading $.
    $path = $Path -replace '^\$\.?',''
    if ([string]::IsNullOrWhiteSpace($path)) { return $Item }

    $segments = @($path -split '\.')

    # Fast-path (UNCHANGED behavior): no wildcard anywhere → original iterative dot-walk + single-[N] index.
    if ($path -notmatch '\[\*\]') {
        $current = $Item
        foreach ($seg in $segments) {
            if ($null -eq $current) { return $null }
            # Handle [N] indexing
            if ($seg -match '^(\w+)\[(\d+)\]$') {
                $propName = $Matches[1]
                $idx = [int]$Matches[2]
                $propVal = $null
                if ($current -is [System.Collections.IDictionary] -and $current.ContainsKey($propName)) { $propVal = $current[$propName] }
                elseif ($current.PSObject -and $current.PSObject.Properties.Name -contains $propName) { $propVal = $current.$propName }
                if ($propVal -is [System.Array] -and $idx -lt $propVal.Count) { $current = $propVal[$idx] } else { return $null }
                continue
            }
            if ($current -is [System.Collections.IDictionary]) {
                if ($current.ContainsKey($seg)) { $current = $current[$seg] } else { return $null }
            } elseif ($current.PSObject -and $current.PSObject.Properties.Name -contains $seg) {
                $current = $current.$seg
            } else { return $null }
        }
        return $current
    }

    # Wildcard path → recursive segment walker (handles `[*]` fan-out + arbitrary nesting).
    return (Resolve-XdrJsonPathSegments -Node $Item -Segments $segments -Index 0)
}

# Recursive segment walker. $Segments is the dot-split path; $Index is the current segment. Returns the resolved
# value, an array (after a `[*]` fan), or $null on a miss. Depth is bounded by the path length (no cycles possible).
function script:Resolve-XdrJsonPathSegments {
    param($Node, [string[]]$Segments, [int]$Index)

    # Consumed all segments → this node IS the value.
    if ($Index -ge $Segments.Count) { return $Node }
    if ($null -eq $Node) { return $null }

    $seg = $Segments[$Index]

    # `prop[*]` (wildcard) — resolve prop to an array, then fan the REMAINDER of the path over each element.
    if ($seg -match '^(\w+)\[\*\]$') {
        $prop = Get-XdrNodeProperty -Node $Node -Name $Matches[1]
        if (-not $prop.found) { return $null }
        $arr = ConvertTo-XdrArray $prop.value
        # Terminal wildcard ($.a.b[*]) → return the array itself (caller serializes the non-scalar).
        if ($Index -eq ($Segments.Count - 1)) { return @($arr) }
        # Mid-path wildcard ($.a.b[*].c …) → map each element through the remaining segments; flatten one level.
        $collected = [System.Collections.Generic.List[object]]::new()
        foreach ($el in $arr) {
            $sub = Resolve-XdrJsonPathSegments -Node $el -Segments $Segments -Index ($Index + 1)
            if ($null -eq $sub) { continue }                                   # element lacked the tail → skip it
            if (($sub -is [System.Array]) -or ($sub -is [System.Collections.IList])) {
                foreach ($s in $sub) { $collected.Add($s) }                    # flatten nested wildcard results
            } else { $collected.Add($sub) }
        }
        return @($collected)
    }

    # `prop[N]` (single index) — same semantics as the fast-path, then continue walking.
    if ($seg -match '^(\w+)\[(\d+)\]$') {
        $prop = Get-XdrNodeProperty -Node $Node -Name $Matches[1]
        if (-not $prop.found) { return $null }
        $idx = [int]$Matches[2]
        $propVal = $prop.value
        if (($propVal -is [System.Array] -or $propVal -is [System.Collections.IList]) -and $idx -lt @($propVal).Count) {
            return (Resolve-XdrJsonPathSegments -Node (@($propVal)[$idx]) -Segments $Segments -Index ($Index + 1))
        }
        return $null
    }

    # Plain property — descend.
    $prop = Get-XdrNodeProperty -Node $Node -Name $seg
    if (-not $prop.found) { return $null }
    return (Resolve-XdrJsonPathSegments -Node $prop.value -Segments $Segments -Index ($Index + 1))
}

Export-ModuleMember -Function ConvertTo-XdrRows, Apply-XdrProjectionMap, Test-XdrEmptyElement, Compress-XdrRawJson, Get-XdrSafeColumnName, Get-XdrEnvelopeColumns, Get-XdrCategoryToken, Get-XdrArmGuid, Get-XdrArtifactTransformKql, Get-XdrResponseItemCount
