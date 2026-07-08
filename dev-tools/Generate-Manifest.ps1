#Requires -Version 7.4
<#
.SYNOPSIS
v12 catalogue -> manifest generator (plan §6.2). Emits the per-GROUP manifest .psd1 from catalogue.json
for the Validated operations of a Category(group). The catalogue is the source of truth; the .psd1 is a
generated artifact (never hand-authored).

.DESCRIPTION
Reads references/inventory/<portalKey>/catalogue.json, filters Operations whose Category == <Group> and
Status == 'Validated', and writes a manifest .psd1 in the runtime-consumed shape. Includes the new v12
Subcategory field. Default output is a gitignored validation path (-OutPath to place into manifests/ at P3).
#>
[CmdletBinding()]
param(
    [string] $Portal = 'Defender',
    [string] $Group = 'Operations',
    [string] $RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path,
    [string] $OutPath,
    [switch] $IncludePendingLiveProbe
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# UTF-8 stdout (no BOM) so the generated manifest emits non-ASCII losslessly when captured by the gauntlet regen→diff
# axis under any shell (git's sh hook defaults to the OEM codepage, which mangles UTF-8 to `?`). Root cause + the
# parent-side pin are documented in tools/Run-PrePushGauntlet.ps1.
$OutputEncoding = [System.Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

# WS2.2 · THE single category tokenizer (Xdr.Common.Parser.Get-XdrCategoryToken) — -Group matching, the emitted
# Category field, the manifest filename and the DCR env-var all use the SAME tokenization the catalogue used for
# WorkspaceTable/DcrStreamName, so spaced/'&' category names ("Cloud Apps", "Analytics & Data") can never mismatch
# across the chain. For token==raw categories (Operations) every output is byte-identical.
# Module resolves relative to THIS SCRIPT (not -RepoRoot, which callers/tests may point at a data-only root).
Import-Module (Join-Path $PSScriptRoot '..\src\Modules\Xdr.Common.Parser\Xdr.Common.Parser.psd1') -Force -DisableNameChecking -ErrorAction Stop
$groupToken = Get-XdrCategoryToken -Category $Group

# A4 · portal-generic PortalKey resolution from portals.json (accepts Friendly · Key · Short) — no hardcoded single-portal map.
$portalsReg = (Get-Content (Join-Path $RepoRoot 'references/inventory/portals.json') -Raw | ConvertFrom-Json).portals
$portalKey = $null
foreach ($p in $portalsReg) {
    $short = [string]$p.PortalShort
    $friendly = switch ([string]$p.PortalKey) {
        'nodoc-defender-xdr'     { 'Defender' }
        'nodoc-purview'          { 'Purview' }
        'nodoc-security-copilot' { 'SecurityCopilot' }
        default { (($short -split '[-_]' | Where-Object { $_ } | ForEach-Object { $_.Substring(0,1).ToUpper() + $_.Substring(1) }) -join '') }
    }
    if ($Portal -in @([string]$p.PortalKey, $friendly, $short)) { $portalKey = [string]$p.PortalKey; break }
}
if (-not $portalKey) { throw "Generate-Manifest: unknown Portal '$Portal' (not resolvable from portals.json by friendly/key/short)" }
$catPath = Join-Path $RepoRoot "references/inventory/$portalKey/catalogue.json"
$catalogue = Get-Content $catPath -Raw | ConvertFrom-Json
if (-not $OutPath) { $OutPath = Join-Path $RepoRoot "dev-tools/.generated/$groupToken.psd1" }   # WS2.2 · token filename
$null = New-Item -ItemType Directory -Path (Split-Path $OutPath) -Force -ErrorAction SilentlyContinue

# FH-3 · TYPED COLUMNS curation (per-category · operator-verified column types from LIVE evidence · references/inventory/
# <portalKey>/curation.json `columnTypes`, keyed by OperationId). Passed through onto each manifest op below so the schema
# generator (Build-PerCategorySchema) types the DCR/table columns; the runtime ignores it (it emits strings · A6 'source').
$curColumnTypes = @{}
$curVolatileHashFields = @{}
$curSnapshotDrift = @{}
$curRequestHeaders = @{}
$curPathCT = Join-Path $RepoRoot "references/inventory/$portalKey/curation.json"
if (Test-Path $curPathCT) {
    $curJsonCT = Get-Content $curPathCT -Raw | ConvertFrom-Json
    if ($curJsonCT.PSObject.Properties.Name -contains 'columnTypes') {
        foreach ($ctp in $curJsonCT.columnTypes.PSObject.Properties) { if ($ctp.Name -ne '_doc') { $curColumnTypes[$ctp.Name] = $ctp.Value } }
    }
    # F-VOLATILE-HASH (2026-06-25) · per-op VOLATILE-field declaration (curation.json `volatileHashFields`, keyed by
    # OperationId). Emitted onto the manifest as VolatileHashFields so the runtime content-hash STRIPS these top-level
    # fields before hashing (hash-only · the field still lands in RawJson) → a per-poll-changing non-identity field no
    # longer mints a new RecordId each cycle → blocks the keyless-SNAPSHOT cross-cycle dup-accumulation. SPARSE: an op
    # not listed emits NO VolatileHashFields (byte-identical to the pre-fix manifest). curation is the source-of-truth
    # (same direct-read seam as columnTypes · NOT catalogue-derived, so Build-Catalogue/catalogue.json stay untouched).
    if ($curJsonCT.PSObject.Properties.Name -contains 'volatileHashFields') {
        foreach ($vhp in $curJsonCT.volatileHashFields.PSObject.Properties) { if ($vhp.Name -ne '_doc') { $curVolatileHashFields[$vhp.Name] = @($vhp.Value) } }
    }
    # A5 (2026-07-03) · per-op SnapshotDrift declaration (curation.json `snapshotDrift`, keyed by OperationId → true).
    # Emitted onto the manifest as SnapshotDrift so the VolatileHash post-deploy gate ACCEPTS an evolving-data snapshot's
    # GENUINE per-cycle drift (a meaningful non-timestamp field genuinely changes → the distinct re-emit is real content,
    # NOT a volatile-field defect). SPARSE: an op not listed emits NO SnapshotDrift (byte-identical to the pre-fix manifest).
    # curation is the source-of-truth (same direct-read seam as volatileHashFields · NOT catalogue-derived). Verify-time only.
    if ($curJsonCT.PSObject.Properties.Name -contains 'snapshotDrift') {
        foreach ($sdp in $curJsonCT.snapshotDrift.PSObject.Properties) { if ($sdp.Name -ne '_doc' -and $sdp.Value) { $curSnapshotDrift[$sdp.Name] = $true } }
    }
    # F-REQHEADERS (2026-06-25) · per-op REQUEST-HEADER declaration (curation.json `requestHeaders`, keyed by OperationId →
    # { '<header>' = '<value>' }). Emitted onto the manifest as RequestHeaders so the runtime poll path SENDS these as
    # REQUEST headers (e.g. the tvm/analytics backend that requires `api-version` as a header · query-string → 400). SPARSE:
    # an op not listed emits NO RequestHeaders (byte-identical to the pre-fix manifest). curation is the source-of-truth (the
    # SAME direct-read seam as columnTypes/volatileHashFields · NOT catalogue-derived, so Build-Catalogue/catalogue.json stay
    # untouched). Each header value stringified; '_doc' skipped. Stored as an ordered map per op for byte-stable emission.
    if ($curJsonCT.PSObject.Properties.Name -contains 'requestHeaders') {
        foreach ($rhp in $curJsonCT.requestHeaders.PSObject.Properties) {
            if ($rhp.Name -eq '_doc') { continue }
            $hdrMap = [ordered]@{}
            if ($rhp.Value -is [System.Management.Automation.PSCustomObject]) {
                foreach ($hp in ($rhp.Value.PSObject.Properties | Sort-Object Name)) { if ($hp.Name -ne '_doc') { $hdrMap[[string]$hp.Name] = [string]$hp.Value } }
            }
            if ($hdrMap.Count -gt 0) { $curRequestHeaders[$rhp.Name] = $hdrMap }
        }
    }
}

# ---- PSD1 serializer ----
function ConvertTo-Psd1Value {
    param($Value, [int]$Indent)
    $pad = '    ' * $Indent
    if ($null -eq $Value) { return '$null' }
    if ($Value -is [bool]) { return $(if ($Value) { '$true' } else { '$false' }) }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int64] -or $Value -is [double]) { return "$Value" }
    if ($Value -is [string]) { return "'" + ($Value -replace "'", "''") + "'" }
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Count -eq 0) { return '@{}' }
        $lines = @('@{')
        foreach ($k in $Value.Keys) {
            $kn = if ($k -match '^[A-Za-z_][A-Za-z0-9_]*$') { $k } else { "'$k'" }
            $lines += "$pad    $kn = $(ConvertTo-Psd1Value -Value $Value[$k] -Indent ($Indent + 1))"
        }
        $lines += "$pad}"
        return ($lines -join "`n")
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @(foreach ($it in $Value) { ConvertTo-Psd1Value -Value $it -Indent $Indent })
        if ($items.Count -eq 0) { return '@()' }
        return '@(' + ($items -join ', ') + ')'
    }
    return "'" + ($Value.ToString() -replace "'", "''") + "'"
}

# ---- JSON object -> ordered hashtable (deterministic field order) ----
function ConvertTo-Ordered {
    param($Obj)
    if ($Obj -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $Obj.PSObject.Properties) { $h[$p.Name] = ConvertTo-Ordered $p.Value }
        return $h
    }
    if ($Obj -is [System.Collections.IList]) { return @($Obj | ForEach-Object { ConvertTo-Ordered $_ }) }
    return $Obj
}

# catalogue.json is the FULL portal catalogue (all groups · v13). Filter to THIS group + the wanted statuses.
# Production manifests carry ONLY Validated ops; -IncludePendingLiveProbe also pulls spec/structural-only (catalog-only).
# V6/F4 (plan §21) · SHIP on the Shipped gate (value-verified · deduplicated · pollable) — NOT Status=Validated.
# Status tracks LIVE-PROOF independently (LiveCaptured -> Validated on live proof). -IncludePendingLiveProbe = legacy
# Status widen (catalog-only). Onboarding a category emits exactly its value-verified, pollable streams.
# WS2.2 · tokenized Group matching: -Group is compared against the catalogue Category via THE shared tokenizer
# ($groupToken computed at import time above), so `-Group CloudApps` matches Category "Cloud Apps" and the emitted
# artifacts use the token everywhere.
if ($IncludePendingLiveProbe) {
    $statuses = @('Validated', 'OpenApiDerived', 'StructuralOnly')
    $ops = @($catalogue.Operations | Where-Object { ((Get-XdrCategoryToken -Category ([string]$_.Category)) -eq $groupToken) -and ($_.Status -in $statuses) })
} else {
    $ops = @($catalogue.Operations | Where-Object { ((Get-XdrCategoryToken -Category ([string]$_.Category)) -eq $groupToken) -and ($_.Shipped -eq $true) })
}
if ($ops.Count -eq 0) { throw "No Shipped operations for $Portal/$Group (Shipped = value-verified + pollable · plan §21)" }

# OperationKey within-category UNIQUENESS (2026-06-24 · Cloud Apps surfaced AppGovernance.ListPolicies +
# CloudApps.ListPolicies, both short-name 'ListPolicies' in category 'Cloud Apps'). OperationKey is BOTH the
# checkpoint RowKey (PK=table, RK=OperationKey · Save-XdrCheckpointReset) AND the emitted row Operation value — a
# within-category short-name collision = checkpoint OVERWRITE + indistinguishable rows. Count short-names so the
# loop prefixes the (tokenized) Subcategory ONLY for collisions; non-colliding ops keep the bare Operation
# (byte-stable · the 7 deployed cats have ZERO collisions · verified 2026-06-24, so this is a no-op for them).
$opNameCounts = @{}
foreach ($o in $ops) { $k = [string]$o.Operation; $opNameCounts[$k] = ([int]$opNameCounts[$k]) + 1 }

# TYPE-CONSISTENCY UNION (FH-3+ · live-surfaced 2026-06-16) · an op that PROJECTS a column for which ANOTHER shipped op
# in this category carries a curated native type MUST emit that native type too — else the parser emits the field as a
# STRING into the real/bool table column and the value is DROPPED at ingest (the 'green-but-null' class · the
# ExposureManagement secure-score ops share latestValue/latestCount/latestTotal/... with the posture-metrics op but
# carried no own ColumnTypes → typed columns landed None despite faithful RawJson). Resolve each column's type across
# the category (same rule as Build-PerCategorySchema: known-vs-DIFFERENT-known ⇒ string · string/absent ⊑ known); each
# op below INHERITS it for every column it projects. GENERIC · no per-op curation for shared typed columns · an
# all-string category (no curated types · incl. the Operations pilot) yields an empty map → every op byte-identical.
$colUnionTypes = @{}
foreach ($o in $ops) {
    $oid = [string]$o.OperationId
    if (-not $curColumnTypes.ContainsKey($oid)) { continue }
    foreach ($cp in $curColumnTypes[$oid].PSObject.Properties) {
        if ($cp.Name -eq '_doc') { continue }
        $t = [string]$cp.Value
        if (-not $colUnionTypes.ContainsKey($cp.Name)) { $colUnionTypes[$cp.Name] = $t }
        elseif ($colUnionTypes[$cp.Name] -ne $t) { $colUnionTypes[$cp.Name] = 'string' }
    }
}

$opBlocks = @()
foreach ($op in $ops) {
    $envVar = "XDRLR_DCR_$($Portal.ToUpper())_$($groupToken.ToUpper())"   # WS2.2 · shared tokenizer (was an inline regex copy)
    # OperationKey uniqueness (per the within-category guard above): prefix the tokenized Subcategory for a colliding
    # short-name so the checkpoint RowKey + the emitted Operation value stay distinct; bare Operation otherwise.
    $opKey = if (([int]$opNameCounts[[string]$op.Operation]) -gt 1) { (Get-XdrCategoryToken -Category ([string]$op.Subcategory)) + [string]$op.Operation } else { [string]$op.Operation }
    $entry = [ordered]@{
        OperationKey         = $opKey
        Subcategory          = $op.Subcategory
        Method               = $op.Method
        SubPortal            = $op.SubPortal
        Path                 = $op.Path
        ResponseShape        = $op.ResponseShape
        ItemsContainer       = $op.ItemsContainer
        Cadence              = $op.Cadence
        IngestionMode        = $op.IngestionMode
        CursorField          = $op.CursorField
        NaturalKey           = @(@($op.NaturalKey) | Where-Object { -not [string]::IsNullOrEmpty([string]$_) })   # F-KEYLESS-CURSOR (2026-06-20): drop null/empty elements so a keyless op emits @() not @('') — the catalogue's empty NaturalKey serializes to JSON null (PS @()->null quirk) and a bare @($null) would leak an empty-string key that crashes the NaturalKey⊆ProjectionMap gate + falsely keys the boundary
        TimeFilter           = ConvertTo-Ordered $op.TimeFilter
        Pagination           = ConvertTo-Ordered $op.Pagination
        RequiresProducts     = @($op.RequiresProducts)
        ProjectionMap        = ConvertTo-Ordered $op.ProjectionMap
        DcrStreamName        = $op.DcrStreamName
        WorkspaceTable       = $op.WorkspaceTable
        DceEndpoint          = '<env:DCE_ENDPOINT>'
        DcrImmutableIdEnvVar = $envVar
        Provenance           = [ordered]@{
            OperationId = $op.OperationId
            Live        = $op.Provenance.Live
            Postman     = $op.Provenance.Postman
            OpenApi     = $op.Provenance.OpenApi
            DerivedFrom = 'catalogue.json (v12 6-stage engine)'
        }
    }
    # G-B · ENTITY-ROUTING fields. Invoke-XdrEntityFanout (Xdr.Common.Runtime.psm1:1184-1190) routes an op to the
    # entity fan-out path iff its manifest entry carries a DependsOn IDictionary with EntityResolution='Resolved',
    # then reads DependsOn.ParentOperationKey/EntityIdField/ParamName. These are DERIVED by Build-Catalogue's DEPEND
    # stage but were dropped here. Emitted ONLY for entity ops (EntityResolution != 'NotEntity' → a real edge); a
    # non-entity op has no DependsOn so the runtime routes it to the normal poll path, so it needs neither field.
    # Conditional emission keeps non-entity entries lean and the Operations pilot manifest byte-stable. ParamSource /
    # PathParams are NOT emitted — the runtime never reads them ({id} subst uses the fan-out-set EntityParams).
    if ($op.EntityResolution -and ([string]$op.EntityResolution) -ne 'NotEntity') {
        $entry['EntityResolution'] = [string]$op.EntityResolution
        if ($op.DependsOn) { $entry['DependsOn'] = ConvertTo-Ordered $op.DependsOn }
    }
    # G-C · WINDOW LookbackHours (runtime Resolve-XdrTimeWindow reads $Entry['LookbackHours'] · Runtime.psm1:1859) —
    # emit ONLY when set (WINDOW ops) so non-WINDOW manifests (incl. the Operations pilot) stay byte-stable.
    if (($op.PSObject.Properties.Name -contains 'LookbackHours') -and $op.LookbackHours) { $entry['LookbackHours'] = [int]$op.LookbackHours }
    # T3e · G2 CursorPrecision (runtime boundary-tie comparison precision · $Entry['CursorPrecision'] · Runtime.psm1:614)
    # — curation-emitted (the timeFilter seam); conditional so existing manifests stay byte-stable. Closes the last
    # known INERT field: the runtime read it, but neither the generator nor curation could ever emit it.
    if (($op.PSObject.Properties.Name -contains 'CursorPrecision') -and $op.CursorPrecision) { $entry['CursorPrecision'] = [string]$op.CursorPrecision }
    # G-A · read-via-POST BodyTemplate (runtime reads $Entry['BodyTemplate'] for the POST body · Runtime.psm1:1774) —
    # emit ONLY when set so GET/non-POST manifests (incl. the Operations pilot) stay byte-stable. Ships 0 today (no
    # telemetry-grade POST op has a real body · §2 G-A); the manifest chain is ready when a real body arrives.
    if (($op.PSObject.Properties.Name -contains 'BodyTemplate') -and $op.BodyTemplate) { $entry['BodyTemplate'] = [string]$op.BodyTemplate }
    # F-VOLATILE-HASH · emit VolatileHashFields = @('<field>', ...) ONLY when this op has a curation declaration, so
    # every op WITHOUT one stays byte-identical (the SPARSE invariant · the 4 deployed cats with no volatile op are a
    # no-op). Keyed by the catalogue OperationId. The runtime strips these from the content-hash (hash-only · the field
    # still lands). Order preserved from curation (a list of top-level RawJson field names).
    if ($curVolatileHashFields.ContainsKey([string]$op.OperationId)) {
        $vhf = @($curVolatileHashFields[[string]$op.OperationId] | Where-Object { -not [string]::IsNullOrEmpty([string]$_) })
        if ($vhf.Count -gt 0) { $entry['VolatileHashFields'] = $vhf }
    }
    # A5 · emit SnapshotDrift = $true ONLY when this op is a curation-declared, diff-confirmed evolving-data snapshot, so
    # every op WITHOUT one stays byte-identical (the SPARSE invariant · same as VolatileHashFields). Keyed by the catalogue
    # OperationId. The VolatileHash post-deploy gate reads it to accept the op's genuine per-cycle drift; the runtime ignores it.
    if ($curSnapshotDrift.ContainsKey([string]$op.OperationId)) {
        $entry['SnapshotDrift'] = $true
    }
    # F-REQHEADERS · emit RequestHeaders = @{ '<header>' = '<value>' } ONLY when this op has a curation declaration, so
    # every op WITHOUT one stays byte-identical (the SPARSE invariant · the same as VolatileHashFields). Keyed by the
    # catalogue OperationId. The runtime poll path reads $Entry['RequestHeaders'] and merges them into the HTTP request
    # (Runtime.psm1 Invoke-XdrPortalHttp · ExtraHeaders). Empty/non-string keys dropped at read; an empty map emits nothing.
    if ($curRequestHeaders.ContainsKey([string]$op.OperationId)) {
        $rhEntry = [ordered]@{}
        foreach ($hk in $curRequestHeaders[[string]$op.OperationId].Keys) {
            if (-not [string]::IsNullOrEmpty([string]$hk)) { $rhEntry[[string]$hk] = [string]$curRequestHeaders[[string]$op.OperationId][$hk] }
        }
        if ($rhEntry.Count -gt 0) { $entry['RequestHeaders'] = $rhEntry }
    }
    # FH-3 · TYPED COLUMNS passthrough — emit $Entry['ColumnTypes'] = { <col> = datetime|long|real|boolean } ONLY when this
    # op has operator-verified typed columns in curation, so all-string ops (incl. the Operations pilot) stay byte-identical.
    # Build-PerCategorySchema reads it SPARSE (a column not listed => string). Keyed by the catalogue OperationId.
    # Emit the op's OWN curated types UNION the per-category resolved type for EVERY column it PROJECTS ($colUnionTypes
    # above) — a shared typed column is then emitted NATIVE by every op, not only the curated one (kills the string→real
    # ingest drop). Sorted for byte-stability. SPARSE: a projected column with no resolved native type stays string.
    # .get_Count() (not .Count) · a column named 'count' would shadow the .Count accessor on the ordered hashtable.
    $ctEntry = [ordered]@{}
    if ($curColumnTypes.ContainsKey([string]$op.OperationId)) {
        foreach ($cp in $curColumnTypes[[string]$op.OperationId].PSObject.Properties) { if ($cp.Name -ne '_doc') { $ctEntry[$cp.Name] = [string]$cp.Value } }
    }
    if ($op.ProjectionMap) {
        # foreach over the Properties OBJECTS (not .Properties.Name member-enumeration) — the latter throws under
        # StrictMode when an op has an EMPTY ProjectionMap (empty Properties collection · e.g. a bare-scalar op).
        foreach ($pmProp in $op.ProjectionMap.PSObject.Properties) {
            $pmCol = $pmProp.Name
            if ($colUnionTypes.ContainsKey($pmCol) -and $colUnionTypes[$pmCol] -ne 'string' -and -not $ctEntry.Contains($pmCol)) { $ctEntry[$pmCol] = $colUnionTypes[$pmCol] }
        }
    }
    if ($ctEntry.get_Count()) {
        $ctSorted = [ordered]@{}; foreach ($k in (@($ctEntry.Keys) | Sort-Object)) { $ctSorted[$k] = $ctEntry[$k] }
        $entry['ColumnTypes'] = $ctSorted
    }
    $opBlocks += (ConvertTo-Psd1Value -Value $entry -Indent 2)
}

$header = @"
# manifests/$Portal/$groupToken.psd1 · GENERATED from references/inventory/$portalKey/catalogue.json (plan v12 §6.2).
# DO NOT hand-edit · re-run dev-tools/Generate-Manifest.ps1. Category = nodoc x-tagGroups GROUP; Subcategory = tag.
# NO IsActive flag · runtime dispatch via plan §4.7 4-gate model.
@{
    Portal   = '$Portal'
    Category = '$groupToken'
    Operations = @(
$($opBlocks -join ",`n")
    )
}
"@

$header | Out-File -FilePath $OutPath -Encoding utf8
Write-Host "[Generate-Manifest] wrote $OutPath · $($ops.Count) op(s): $($ops.Operation -join ', ')"
