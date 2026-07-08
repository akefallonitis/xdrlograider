#Requires -Version 7.4
<#
.SYNOPSIS
Validate manifests/<Portal>/<Category>.psd1 per plan v11 §4.17 combined-evidence pipeline.

.DESCRIPTION
Per plan v11:
- §4.11 manifest schema · NO `IsActive` flag · runtime dispatch via §4.18 4 gates
- §4.17 combined-evidence validation · Live + Postman + OpenAPI required · XDRInternals optional
- §4.15 DCR ↔ workspace table parity · per-category-schemas JSON is source of truth
- §4.19 evidence-coverage scoring (informational · scoring runs at Onboard-NextCategory)

Per-Op Status (emitted · VALUE-BASED SHIPPED MODEL · HONESTY LOCK):
- Shipped  · structurally valid + Postman/OpenApi cited + schema-consistent (typed cols ⊆ per-category union).
             The runtime-active tier (dispatched via §4.18 4-gate). Live fixture is OPTIONAL — per the HONESTY
             LOCK this OFFLINE tool NEVER emits Status=Validated (that label is for LIVE-PROVEN ops only).
- Stub     · an auditability source (Postman/OpenApi) is missing (catalog-only · runtime ignores).
- Inactive · a REAL defect — schema parity/envelope mismatch · dead JSONPath · 0-row fixture · IsActive present
             · missing required field · non-canonical naming (BLOCKS push).

Schema parity is the MULTI-OP UNION model: the per-category-schema's typed columns are the deduped union of
EVERY op's ProjectionMap (Build-PerCategorySchema folds all ops into one Defender_<Category>_CL table). Per-op:
each col must EXIST in the schema. Per-category: the union must be SET-EQUAL to the schema's typed columns.

Naming canonical (§4.11 + memory feedback_xdr_lograider_skillset):
- WorkspaceTable = `Defender_<Category>_CL`
- DcrStreamName  = `Custom-Defender_<Category>_CL`

Exit codes:
- 0 · all Ops Shipped OR Stub · ≥1 Shipped · push allowed
- 1 · any Op Inactive (schema mismatch · missing fixture rows · defect) OR 0 Shipped · push blocked
- 2 · tool error (corrupt manifest · IO failure)
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path,
    [switch] $Detailed,
    # FH-4 · emit a SINGLE structured-JSON summary object to stdout (no human text · per-op output is -Detailed-gated, so
    # -Json stdout is JSON-only) so consumers parse counts/verdict robustly instead of regex-scraping Write-Host lines.
    # Exit code is unchanged (1 on FAIL · 0 on PASS).
    [switch] $Json
)

$ErrorActionPreference = 'Stop'
# Set-StrictMode intentionally omitted · this tool iterates collections that StrictMode Latest
# treats as undeclared properties (e.g. @().Count on empty pipe output). Tool is a CI gate · not
# runtime hot path · the verification value comes from the gate logic not from strict typing.

$manifestsRoot = Join-Path $RepoRoot 'manifests'
$schemasRoot   = Join-Path $RepoRoot 'deploy\per-category-schemas'
$referencesRoot = Join-Path $RepoRoot 'references'

if (-not (Test-Path $manifestsRoot)) {
    if ($Json) { [pscustomobject]@{ tool = 'Validate-Manifests'; verdict = 'PASS'; reason = 'no manifests (bootstrap)'; totalChecked = 0; shippedCount = 0; stubCount = 0; inactiveCount = 0; shipped = @(); stub = @(); inactive = @() } | ConvertTo-Json -Depth 5 }
    else { Write-Host 'Validate-Manifests: manifests/ not present · acceptable for bootstrap state' }
    exit 0
}

# Required per-Op fields (NO `IsActive` · v11 §4.11)
$requiredPerOp = @(
    'OperationKey', 'Method', 'SubPortal', 'Path',
    'ResponseShape', 'IngestionMode', 'Cadence',
    'RequiresProducts', 'ProjectionMap',
    'DcrStreamName', 'WorkspaceTable',
    'DcrImmutableIdEnvVar',  # CRITICAL · runtime G-Provisioned gate input · holds DCR immutable ID directly (ARM-time reference() resolves at deploy · DCR co-located with FA in connector RG per operator architectural binding 2026-06-02)
    'Provenance'
)
# T4 (reaudit 2026-06-12) · the allowlist MUST match the runtime switch. Resolve-XdrTimeWindow implements exactly
# SNAPSHOT|CURSOR|WINDOW; LIVESTREAM had NO runtime branch (it fell into the DEGRADE default) and 0 ops use it, so a
# LIVESTREAM op would silently degrade. Removed until a real runtime branch + an op need it (add to BOTH together).
$allowedModes = @('SNAPSHOT', 'CURSOR', 'WINDOW')
# Envelope count derives from the ONE canonical definition in Xdr.Common.Parser (R1 single-source · plan §35.5).
# Canonical envelope is 8 columns and contains NO TenantId (TenantId is LA-reserved; a Category mapping a tenant
# field gets TenantId_x via Get-XdrSafeColumnName). The 8 are: TimeGenerated, OperationKey, Portal, Category,
# Subcategory, Operation, CorrelationId, RawJson. Historical drift (a hardcoded count that disagreed with the
# generator → expected vs actual column mismatch → ActionCenter marked Inactive → BLOCKED PUSH, live-RED gate) is
# now impossible: both the generator AND this validator read this same Get-XdrEnvelopeColumns list.
Import-Module (Join-Path $RepoRoot 'src\Modules\Xdr.Common.Parser\Xdr.Common.Parser.psd1') -Force -DisableNameChecking
$envelopeColumnCount = @(Get-XdrEnvelopeColumns).Count   # = 8 · NO TenantId

$summary = @{
    Shipped  = @()
    Stub     = @()
    Inactive = @()
}
$totalChecked = 0
$failures = @()

# GM-1(c) · LIVE-PROVEN-TYPING source (data-pin prevention · 2026-06-18). Infer the CONSERVATIVE LA type of every op's
# columns from its LIVE capture body via the SHARED oracle (dev-tools/Infer-ColumnTypes.ps1) — the SAME inference the
# curation was meant to encode. This closes the failure CLASS that froze compliantAssets/notCompliantAssets/totalAssets
# as 'string': a column the live data proves numeric/bool/datetime but curation OMITTED deploys 'string' and LA freezes
# it on first ingest (green-but-null). The capture bodies live under references/live/ (gitignored · operator-local ·
# ABSENT on a public/CI clone BY DESIGN · the SAME honesty-lock as the Provenance.Live fallback below). So this is a
# LOCAL-PROVE gate: captures present (prepush) -> it BLOCKS a pin; captures absent (CI) -> it self-skips and RECORDS the
# reason (never a silent pass · surfaced in the summary). Run in a CHILD pwsh so Infer's Set-StrictMode/module state
# cannot leak into this tool (which intentionally runs StrictMode-off · line 45). Run ONCE here · per-op cross-check below.
$inferAll = $null
$inferTypingSkipReason = $null
try {
    $inferScript = Join-Path $RepoRoot 'dev-tools/Infer-ColumnTypes.ps1'
    if (-not (Test-Path $inferScript)) {
        $inferTypingSkipReason = 'dev-tools/Infer-ColumnTypes.ps1 not found · live-proven-typing cross-check SKIPPED'
    } else {
        $inferJson = & pwsh -NoProfile -Command "& '$inferScript' -Portal Defender | ConvertTo-Json -Depth 8" 2>$null
        $inferRaw = if ($inferJson) { ($inferJson | Out-String) | ConvertFrom-Json -ErrorAction Stop } else { $null }
        if ($inferRaw -and @($inferRaw.PSObject.Properties).Count -gt 0) { $inferAll = $inferRaw }
        else { $inferTypingSkipReason = 'Infer-ColumnTypes returned no typed ops (live capture bodies absent · CI/public clone) · live-proven-typing cross-check SKIPPED' }
    }
} catch {
    $inferTypingSkipReason = "Infer-ColumnTypes could not run (live captures absent? · CI/public clone) · live-proven-typing cross-check SKIPPED: $($_.Exception.Message)"
}

# GM-1(c) LIFECYCLE EXCEPTION (2026-06-19) · cols in curation.legacyTypePendingRecreate ship 'string' on a LIVE-pinned
# pre-gate table (their true numeric/datetime type can't be landed without the DEFERRED purge->recreate). The data-pin
# BLOCK below would otherwise reject them (Infer-numeric vs schema-string) — but that string is INTENTIONAL + CORRECT
# (it MATCHES the live pinned col so values LAND · the alternative is the empty-col regression). Keyed by TABLE
# (Defender_<Category>_CL · the block derives the same table per op). NEW categories are never on this list
# (born-correct), so the exception is bounded to the dev-era pilots + never relaxes the gate for new work.
$vmLegacyTolerated = @{}
try {
    $vmCurPath = Join-Path $RepoRoot 'references/inventory/nodoc-defender-xdr/curation.json'
    if (Test-Path $vmCurPath) {
        $vmCur = Get-Content $vmCurPath -Raw | ConvertFrom-Json
        if ($vmCur.PSObject.Properties.Name -contains 'legacyTypePendingRecreate') {
            foreach ($vmTbl in @($vmCur.legacyTypePendingRecreate.PSObject.Properties | Where-Object { $_.Name -ne '_doc' })) {
                $vmSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
                foreach ($vmC in @($vmTbl.Value)) { [void]$vmSet.Add([string]$vmC) }
                $vmLegacyTolerated[[string]$vmTbl.Name] = $vmSet
            }
        }
    }
} catch { }   # a malformed curation never breaks the gate (the prepush JSON-parse axis catches that separately)

function Test-XdrJsonPathResolves {
    <#
    Lightweight JSONPath resolver mirror of Resolve-XdrJsonPath in Xdr.Common.Parser.psm1.
    Returns $true if the path NAVIGATES (key chain exists in the item) · regardless of whether
    the final value is null. This is the correct API-contract semantics: a key present with
    value=null is a sparse-but-valid field (e.g. InvestigationId on non-investigated actions).
    Returns $false only when a key in the path is ABSENT (genuine ProjectionMap bug).
    #>
    param($Item, [string]$Path)
    if ($null -eq $Item -or [string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($Path -eq '$' -or $Path -eq '$.') { return $true }
    $stripped = $Path -replace '^\$\.?', ''
    if ([string]::IsNullOrWhiteSpace($stripped)) { return $true }
    $segments = $stripped -split '\.'
    $current = $Item
    foreach ($seg in $segments) {
        if ($null -eq $current) { return $false }  # cannot navigate further from null
        if ($seg -match '^(\w+)\[(\d+)\]$') {
            $propName = $Matches[1]
            $idx = [int]$Matches[2]
            $propVal = $null
            $propPresent = $false
            if ($current -is [System.Collections.IDictionary] -and $current.ContainsKey($propName)) { $propVal = $current[$propName]; $propPresent = $true }
            elseif ($current.PSObject -and $current.PSObject.Properties.Name -contains $propName) { $propVal = $current.$propName; $propPresent = $true }
            if (-not $propPresent) { return $false }
            if ($propVal -is [System.Array] -and $idx -lt $propVal.Count) { $current = $propVal[$idx] } else { return $false }
            continue
        }
        if ($current -is [System.Collections.IDictionary]) {
            if ($current.ContainsKey($seg)) { $current = $current[$seg] } else { return $false }
        } elseif ($current.PSObject -and $current.PSObject.Properties.Name -contains $seg) {
            $current = $current.$seg
        } else { return $false }
    }
    return $true  # path navigated successfully · final value may be null (sparse field) but key chain exists
}

foreach ($portalDir in (Get-ChildItem -Path $manifestsRoot -Directory -ErrorAction SilentlyContinue)) {
    foreach ($psd1File in (Get-ChildItem -Path $portalDir.FullName -Filter '*.psd1')) {
        $relPath = $psd1File.FullName.Substring($RepoRoot.Length + 1)
        try {
            $catData = Import-PowerShellDataFile -Path $psd1File.FullName -ErrorAction Stop
        } catch {
            $failures += "$relPath - PARSE FAIL: $($_.Exception.Message)"
            $summary.Inactive += "$relPath (parse fail)"
            continue
        }

        # Top-level fields
        if (-not $catData.ContainsKey('Portal'))     { $failures += "$relPath - top-level 'Portal' missing"; continue }
        if (-not $catData.ContainsKey('Category'))   { $failures += "$relPath - top-level 'Category' missing"; continue }
        if (-not $catData.ContainsKey('Operations')) { $failures += "$relPath - top-level 'Operations' array missing"; continue }

        $portal = $catData.Portal
        $category = $catData.Category
        $expectedTable  = "${portal}_${category}_CL"
        $expectedStream = "Custom-${expectedTable}"

        # ── PER-CATEGORY SCHEMA (multi-op UNION model · §4.15 corrected for the 9-op per-group table) ──────────
        # The per-category-schema's typed columns are the UNION (deduped · LA-reserved-safe) of EVERY op's
        # ProjectionMap — NOT any single op's column set (Build-PerCategorySchema folds all ops into ONE
        # Defender_<Category>_CL table). So schema parity is a SET-EQUALITY between {union of all ops' safe
        # column names} and {schema typed columns}, checked ONCE per category after the op loop. Pre-load the
        # schema's typed-column NAME set here so each op can also be checked as a SUBSET (catches a rogue/typo'd
        # column on any single op), and accumulate the manifest-side union across the op loop.
        $schemaPath = Join-Path $schemasRoot "$portal-$category.json"
        $schemaTypedNames = $null   # $null ⇒ no schema artifact yet (Stub-acceptable) · else a [string[]] of typed col names
        $schemaColTypes = $null     # GM-1(c) · name->declared-type map (post-union) for the live-proven-typing cross-check
        $schemaDeclaredTyped = $null
        $schemaDeclaredTotal = $null
        if (Test-Path $schemaPath) {
            try {
                $schemaJson = Get-Content $schemaPath -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                if ($schemaJson.ContainsKey('Summary')) {
                    $schemaDeclaredTyped = $schemaJson.Summary.TypedColumnCount
                    $schemaDeclaredTotal = $schemaJson.Summary.TotalColumnCount
                }
                $envNameSet = @(Get-XdrEnvelopeColumns | ForEach-Object { $_.name })
                $allTableCols = @($schemaJson.TableResource.properties.schema.columns | ForEach-Object { $_.name })
                $schemaTypedNames = @($allTableCols | Where-Object { $_ -notin $envNameSet })
                # GM-1(c) · name->declared-type map (post-union · the TYPE the deployed table column WILL hold) for the
                # live-proven-typing cross-check in the op loop. -AsHashtable: each column is an IDictionary {name,type}.
                $schemaColTypes = @{}
                foreach ($scol in @($schemaJson.TableResource.properties.schema.columns)) {
                    if ($scol -is [System.Collections.IDictionary] -and $scol.ContainsKey('name')) { $schemaColTypes[[string]$scol['name']] = [string]$scol['type'] }
                }
            } catch {
                # A corrupt schema artifact is a category-level blocking failure (recorded against the first op below).
                $schemaTypedNames = 'PARSE_FAIL'
            }
        }
        $manifestUnionTyped = [ordered]@{}   # safe-column-name ⇒ $true · accumulated across ops · vs schema after loop

        foreach ($op in $catData.Operations) {
            $totalChecked++
            $opKey = if ($op.ContainsKey('OperationKey')) { $op.OperationKey } else { '<no-OperationKey>' }
            $opPath = "$relPath/$opKey"
            $opIssues = @()

            # Required-fields check (v11 §4.11 · NO IsActive)
            foreach ($req in $requiredPerOp) {
                if (-not $op.ContainsKey($req)) { $opIssues += "missing required field '$req'" }
            }

            # IsActive must NOT be present (v11 architectural correction)
            if ($op.ContainsKey('IsActive')) {
                $opIssues += "'IsActive' field present · v11 drops this · use §4.17 evidence pipeline + §4.18 4-gate runtime dispatch (catalog entries always considered · gates filter dynamically)"
            }

            # IngestionMode enum
            if ($op.ContainsKey('IngestionMode') -and $op.IngestionMode -notin $allowedModes) {
                $opIssues += "IngestionMode '$($op.IngestionMode)' not in $($allowedModes -join '|')"
            }

            # Canonical naming
            if ($op.ContainsKey('WorkspaceTable') -and $op.WorkspaceTable -ne $expectedTable) {
                $opIssues += "WorkspaceTable='$($op.WorkspaceTable)' not canonical (expected '$expectedTable')"
            }
            if ($op.ContainsKey('DcrStreamName') -and $op.DcrStreamName -ne $expectedStream) {
                $opIssues += "DcrStreamName='$($op.DcrStreamName)' not canonical (expected '$expectedStream')"
            }

            # Cadence parses as TimeSpan
            if ($op.ContainsKey('Cadence')) {
                # InvariantCulture · parity with the runtime G-Cadence parse (XdrDefenderRefresh/run.ps1) so the offline
                # ship-gate verdict can never disagree with the runtime over a culture-sensitive value (FH-9 #3).
                try { $null = [TimeSpan]::Parse($op.Cadence, [System.Globalization.CultureInfo]::InvariantCulture) } catch { $opIssues += "Cadence '$($op.Cadence)' not parseable as TimeSpan (InvariantCulture)" }
            }

            # WS2.4 · NaturalKey ⊆ ProjectionMap (the boundary-set-collapse hole): the runtime builds the exactly-once
            # boundary key from row[NaturalKey] — a NaturalKey field the parser never projects yields '' keys, silently
            # collapsing the boundary set (dup/loss at the high-water tie). Every declared NaturalKey field must be a
            # ProjectionMap key (compared post Get-XdrSafeColumnName · case-sensitive, same rule as ingest).
            if ($op.ContainsKey('NaturalKey') -and @($op.NaturalKey).Count -gt 0) {
                $pmSafe = @()
                if ($op.ContainsKey('ProjectionMap')) { $pmSafe = @($op.ProjectionMap.Keys | ForEach-Object { Get-XdrSafeColumnName -Name $_ }) }
                foreach ($nk in @($op.NaturalKey)) {
                    $nkSafe = Get-XdrSafeColumnName -Name ([string]$nk)
                    if ($nkSafe -cnotin $pmSafe) { $opIssues += "NaturalKey field '$nk' not in ProjectionMap (boundary-set would collapse to '' at runtime)" }
                }
            }

            # WS2.4 · WINDOW validity: a WINDOW op polls an explicit from→to server window — it MUST declare a usable
            # ServerFromDate TimeFilter (FromDateParam + ToDateParam) and a LookbackHours cold-start bound, or the
            # runtime window resolve degrades. Validated here so a curated/derived WINDOW op can never ship half-wired.
            if ($op.ContainsKey('IngestionMode') -and [string]$op.IngestionMode -eq 'WINDOW') {
                $tf = if ($op.ContainsKey('TimeFilter')) { $op.TimeFilter } else { $null }
                $tfOk = ($tf -is [System.Collections.IDictionary]) -and ([string]$tf['Mode'] -eq 'ServerFromDate') -and $tf['FromDateParam'] -and $tf['ToDateParam']
                if (-not $tfOk) { $opIssues += "WINDOW op without a complete ServerFromDate TimeFilter (FromDateParam+ToDateParam required)" }
                if (-not ($op.ContainsKey('LookbackHours') -and $op.LookbackHours)) { $opIssues += "WINDOW op without LookbackHours (cold-start bound required)" }
            }

            # T4 (reaudit 2026-06-12 · keyless-CURSOR 2026-06-20) · CURSOR validity — the exactly-once contract. A CURSOR
            # op derives its cross-cycle high-water from a datetime CursorField. WITHOUT a CursorField,
            # Select-XdrExactlyOnceRows keeps ALL rows every cycle (silent full re-emit) AND Get-XdrAdvancedFrontier
            # persists the page-local server token as the high-water Cursor (a stale token seeds next cycle's page loop) —
            # so a CursorField is ALWAYS required. A NaturalKey is OPTIONAL: a KEYED CURSOR dedups boundary ties by the
            # NaturalKey; a KEYLESS CURSOR (a bucketed-date cursor — e.g. GetInsights on createdDate, where many rows share
            # one day-bucket and the same id's value changes intra-bucket) dedups the tie by the RecordId content-hash
            # (F-KEYLESS-CURSOR · Select-XdrExactlyOnceRows + Get-XdrAdvancedFrontier fall back to RecordId when NaturalKey
            # is empty), which also CORRECTLY keeps a changed-value same-id row that an id-NaturalKey would wrongly drop.
            # So the boundary-tie dedup is DEFINED either way — only a missing CursorField is a defect.
            if ($op.ContainsKey('IngestionMode') -and [string]$op.IngestionMode -eq 'CURSOR') {
                if (-not ($op.ContainsKey('CursorField') -and $op.CursorField)) { $opIssues += "CURSOR op without a CursorField (exactly-once high-water undefined -> silent full re-emit + stale-token cursor)" }
            }

            # ── EVIDENCE PIPELINE per §4.17 + VALUE-BASED SHIPPED MODEL (§21/§22 · HONESTY LOCK) ──────
            # Provenance auditability (Postman + OpenApi) is REQUIRED — every shipped op must cite its
            # derivation sources. Provenance.Live is OPTIONAL: per the HONESTY LOCK, offline NOTHING is
            # Status=Validated — a Defender op ships on OpenApiDerived/LiveCaptured evidence (CoreTelemetry/
            # ConfigState value · includable · pollable · entity-resolvable), and only the ONE live-proven op
            # (GetHistory) carries a Live fixture. So a missing Live is NOT a defect. BUT: if an op DOES cite a
            # Live fixture, that file MUST exist (a dangling Live reference is a real provenance bug) AND its
            # ProjectionMap must resolve against it (the JSONPath-resolve gate below keeps full teeth).
            $provenance = if ($op.ContainsKey('Provenance')) { $op.Provenance } else { $null }
            $hasLive = $false; $hasPostman = $false; $hasOpenApi = $false; $liveFixturePath = $null
            if ($provenance) {
                $hasLive    = $provenance.ContainsKey('Live')    -and $provenance.Live
                $hasPostman = $provenance.ContainsKey('Postman') -and $provenance.Postman
                $hasOpenApi = $provenance.ContainsKey('OpenApi') -and $provenance.OpenApi
                if ($hasLive) {
                    $liveFixturePath = Join-Path $RepoRoot $provenance.Live
                    if (-not (Test-Path $liveFixturePath)) {
                        # G4 single-repo model (WS1/WS2.4): references/live is the operator-local INTERNAL layer —
                        # absent on a public/CI clone by design. Resolve through the tracked SANITIZED mirror. Try BOTH:
                        # (a) the flat filename tests/fixtures/live/<file> (the original GetHistory mirror), then (b) a
                        # SUB-PATH mirror that PRESERVES the references/live/* structure under tests/fixtures/live/ —
                        # collision-free for the source-mvp-fixtures family where EVERY op's capture is named
                        # response.json (a flat mirror would collide · added 2026-06-20 for SecureScore.GetInsights).
                        $liveRel = [string]$provenance.Live
                        $mirrorFlat = Join-Path $RepoRoot (Join-Path 'tests/fixtures/live' ([IO.Path]::GetFileName($liveRel)))
                        $mirrorSub  = Join-Path $RepoRoot ('tests/fixtures/live/' + ($liveRel -replace '^references/live/', ''))
                        if (Test-Path $mirrorFlat) {
                            $liveFixturePath = $mirrorFlat
                        } elseif (Test-Path $mirrorSub) {
                            $liveFixturePath = $mirrorSub
                        } else {
                            $opIssues += "Provenance.Live file does not exist (nor a tests/fixtures/live mirror · flat or sub-path): $($provenance.Live)"
                            $hasLive = $false
                        }
                    }
                }
            } else {
                $opIssues += "no Provenance block"
            }

            # Live OPTIONAL (HONESTY LOCK · see above) · Postman + OpenApi REQUIRED for audit-trail completeness.
            if (-not $hasPostman) { $opIssues += "Provenance.Postman missing (required per §4.17)" }
            if (-not $hasOpenApi) { $opIssues += "Provenance.OpenApi missing (required per §4.17)" }

            # ── SCHEMA PARITY check per §4.15 (multi-op UNION · per-op SUBSET) ─────────────────────────
            # Accumulate this op's safe column names into the category union (checked for set-equality vs the
            # schema AFTER the loop · the union is the real parity invariant for the per-group table). Per-op we
            # also assert every one of THIS op's columns EXISTS in the schema's typed-column set — so a single op
            # with a rogue/typo'd/extra column (a column the deployed table can't receive) fails here immediately.
            $schemaParityOk = $true
            if ($op.ContainsKey('ProjectionMap')) {
                foreach ($pmKey in $op.ProjectionMap.Keys) {
                    $safeName = Get-XdrSafeColumnName -Name $pmKey
                    $manifestUnionTyped[$safeName] = $true
                    if ($schemaTypedNames -is [string] -and $schemaTypedNames -eq 'PARSE_FAIL') {
                        # handled once below; avoid per-column noise
                    } elseif ($null -ne $schemaTypedNames -and $safeName -cnotin $schemaTypedNames) {
                        # -cnotin (WS2.4 · CASE-SENSITIVE): Azure Monitor matches ingest JSON properties to table/DCR
                        # columns case-SENSITIVELY — a casing drift between manifest and schema silently drops the
                        # column at ingest (the green-but-null class). The parity check must therefore be Ordinal.
                        $opIssues += "schema parity FAIL · ProjectionMap col '$pmKey' (-> '$safeName') absent from per-category-schema typed columns (case-sensitive)"
                        $schemaParityOk = $false
                    }
                }
            }
            # GM-1 (offline · 2026-06-16) · ColumnTypes VALIDITY — fail-fast at the manifest (the curation SOURCE) so a
            # typo'd type or a dead key never reaches the schema generator: (a) every ColumnTypes VALUE is a valid LA
            # scalar; (b) every ColumnTypes KEY is a real ProjectionMap column (a key not in ProjectionMap types nothing
            # at runtime — a silent no-op that leaves the column string). Axis 30 (regen→committed) + Assert-LiveSchemaParity
            # (live type-parity) close the rest of the manifest→committed→deployed chain; this is the source-end of GM-1.
            if ($op.ContainsKey('ColumnTypes') -and $op.ColumnTypes) {
                $validScalars = @('string','int','long','real','boolean','datetime','guid','dynamic')
                $pmKeySet = if ($op.ContainsKey('ProjectionMap')) { @($op.ProjectionMap.Keys) } else { @() }
                foreach ($ctKey in @($op.ColumnTypes.Keys)) {
                    $ctVal = [string]$op.ColumnTypes[$ctKey]
                    if ($ctVal.ToLowerInvariant() -notin $validScalars) {
                        $opIssues += "ColumnTypes FAIL · '$ctKey' = '$ctVal' is not a valid Log-Analytics scalar ($($validScalars -join '/'))"
                        $schemaParityOk = $false
                    }
                    if ($ctKey -cnotin $pmKeySet) {
                        $opIssues += "ColumnTypes FAIL · key '$ctKey' is not a ProjectionMap column (dead type declaration · types nothing at runtime)"
                        $schemaParityOk = $false
                    }
                }
            }
            # GM-1(c) · LIVE-PROVEN-TYPING (data-pin prevention · 2026-06-18). The checks above prove the DECLARED types
            # are VALID + NON-DEAD; this proves they are COMPLETE vs the live evidence. A column the capture body proves
            # numeric/bool/datetime but which the POST-UNION schema declares 'string' WILL data-pin (LA freezes the column
            # type on first ingest · the compliantAssets/notCompliantAssets/totalAssets class). Checks the post-union
            # SCHEMA type (NOT the per-op ColumnTypes) so a column legitimately typed via the multi-op union is NOT
            # false-flagged. Fires only when the captures are present (local prepush); SKIPPED-with-a-recorded-reason on a
            # CI/public clone ($inferTypingSkipReason · surfaced in the summary · never a silent pass).
            if ($inferAll -and ($schemaColTypes -is [hashtable]) -and $op.ContainsKey('Provenance') -and ($op.Provenance -is [System.Collections.IDictionary]) -and $op.Provenance.ContainsKey('OperationId')) {
                $vmOpId = [string]$op.Provenance.OperationId
                $vmInferForOp = if (@($inferAll.PSObject.Properties.Name) -contains $vmOpId) { $inferAll.$vmOpId } else { $null }
                if ($vmInferForOp) {
                    foreach ($vmIcol in @($vmInferForOp.PSObject.Properties)) {
                        $vmRaw = [string]$vmIcol.Name; $vmType = [string]$vmIcol.Value
                        if ($vmType.ToLowerInvariant() -in @('long','real','boolean','datetime','guid')) {
                            $vmSafe = Get-XdrSafeColumnName -Name $vmRaw
                            if ($schemaColTypes.ContainsKey($vmSafe) -and ([string]$schemaColTypes[$vmSafe]).ToLowerInvariant() -eq 'string') {
                                # GM-1(c) lifecycle exception · a legacyTypePendingRecreate col SHIPS 'string' by design (it
                                # MATCHES its LIVE-pinned pre-gate table · landing the true type needs the deferred
                                # purge->recreate). Tolerate (warn · NOT block) for exactly that table.col; every OTHER
                                # data-pin still BLOCKS born-correct (the gate is not relaxed for new categories).
                                $vmTable = "${portal}_${category}_CL"
                                $vmTolerated = $vmLegacyTolerated.ContainsKey($vmTable) -and ($vmLegacyTolerated[$vmTable].Contains($vmRaw) -or $vmLegacyTolerated[$vmTable].Contains($vmSafe))
                                if ($vmTolerated) {
                                    if (-not $Json) { Write-Host "  [GM-1(c)] TOLERATED (legacyTypePendingRecreate · ships string until $vmTable is recreated fresh-typed): col '$vmRaw' live-'$vmType' vs schema-'string'" -ForegroundColor Yellow }   # gate under -Json: this advisory must NOT pollute the JSON stdout (Axis 7 ConvertFrom-Json's it)
                                } else {
                                    $opIssues += "ColumnTypes FAIL · data-pin · live evidence proves col '$vmRaw' (-> '$vmSafe') is '$vmType' but the post-union schema declares it 'string' (LA freezes the column type on first ingest · add '$vmRaw' = '$vmType' to curation.json columnTypes['$vmOpId'])"
                                    $schemaParityOk = $false
                                }
                            }
                        }
                    }
                }
            }
            if ($schemaTypedNames -is [string] -and $schemaTypedNames -eq 'PARSE_FAIL') {
                $opIssues += "per-category-schema parse FAIL · $portal-$category.json could not be read"
                $schemaParityOk = $false
            }
            # If schemaPath absent ($schemaTypedNames -eq $null) · it's a STUB (catalog entry without ARM nested
            # block yet) · not a failure. The category-level union set-equality + envelope total check runs after
            # the op loop (below) where BOTH sides are fully known.

            # ── JSONPath RESOLVE CHECK against lab fixture (sample first 5 rows) ───────
            $jsonPathResolveOk = $true
            if ($hasLive -and $op.ContainsKey('ProjectionMap')) {
                try {
                    $liveData = Get-Content $liveFixturePath -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                    # Unwrap by ResponseShape
                    $items = $null
                    if ($op.ResponseShape -eq 'wrapper' -and $op.ContainsKey('ItemsContainer') -and $liveData.ContainsKey($op.ItemsContainer)) {
                        $items = $liveData[$op.ItemsContainer]
                    } elseif ($liveData -is [System.Array]) {
                        $items = $liveData
                    } else {
                        $items = @($liveData)
                    }

                    if (-not $items -or $items.Count -eq 0) {
                        $opIssues += "lab fixture has 0 rows (Inactive · cannot prove Op returns data)"
                        $jsonPathResolveOk = $false
                    } else {
                        # Sample first 5 rows · check each ProjectionMap path resolves in ≥1
                        $sampleCount = [Math]::Min($items.Count, 5)
                        $pathHits = @{}
                        foreach ($targetCol in $op.ProjectionMap.Keys) {
                            $pathHits[$targetCol] = 0
                            for ($i = 0; $i -lt $sampleCount; $i++) {
                                if (Test-XdrJsonPathResolves -Item $items[$i] -Path $op.ProjectionMap[$targetCol]) {
                                    $pathHits[$targetCol]++
                                }
                            }
                        }
                        # Each ProjectionMap key should resolve in ≥1 of the 5 sampled rows
                        # (sparse fields are OK · totally-absent fields are bugs)
                        $deadPaths = @($pathHits.GetEnumerator() | Where-Object { $_.Value -eq 0 } | ForEach-Object { $_.Key })
                        if ($deadPaths.Count -gt 0) {
                            $opIssues += "ProjectionMap paths resolve in 0/$sampleCount sample rows: $($deadPaths -join ',')"
                            $jsonPathResolveOk = $false
                        }
                    }
                } catch {
                    $opIssues += "lab fixture parse FAIL: $($_.Exception.Message)"
                    $jsonPathResolveOk = $false
                }
            }

            # ── EMIT STATUS · VALUE-BASED SHIPPED MODEL (§21/§22 · HONESTY LOCK) ───────────────────────
            # HONESTY LOCK: this OFFLINE tool NEVER reports Status=Validated (that label is reserved for
            # LIVE-PROVEN ops only). An op that passes every structural + provenance(Postman/OpenApi) + schema
            # gate is SHIPPED (active · runtime dispatches it via the §4.18 4-gate model). Live is optional, so a
            # missing Live fixture no longer demotes an op to Stub. Stub now means: an auditability source
            # (Postman/OpenApi) is missing — catalog-only until cited. Inactive = a REAL defect that blocks push.
            $hasAnyMissingSource = -not ($hasPostman -and $hasOpenApi)
            $hasBlockingFail = ($opIssues | Where-Object { $_ -match 'schema parity FAIL|schema envelope FAIL|ColumnTypes FAIL|lab fixture has 0 rows|IsActive.*field present|ProjectionMap paths resolve in 0' }).Count -gt 0

            $status = if ($opIssues.Count -eq 0) {
                'Shipped'
            } elseif ($hasBlockingFail) {
                'Inactive'
            } elseif ($hasAnyMissingSource) {
                'Stub'
            } else {
                # Other issues (missing required fields · canonical naming) · blocking
                'Inactive'
            }

            $entry = "$opPath [Status=$status]"
            if ($opIssues.Count -gt 0) { $entry += "`n    - " + ($opIssues -join "`n    - ") }

            switch ($status) {
                'Shipped'  { $summary.Shipped += $entry }
                'Stub'     { $summary.Stub += $entry }
                'Inactive' { $summary.Inactive += $entry; $failures += $entry }
            }

            if ($Detailed) {
                Write-Host "  $opPath -> $status"
                if ($opIssues.Count -gt 0) { $opIssues | ForEach-Object { Write-Host "    - $_" } }
            }
        }

        # ── CATEGORY-LEVEL SCHEMA PARITY (multi-op UNION set-equality + envelope total · §4.15) ─────────────
        # Now that every op has contributed to $manifestUnionTyped, assert the manifest-side union of typed
        # column names is SET-EQUAL to the per-category-schema's typed columns, AND that the schema's declared
        # TypedColumnCount / TotalColumnCount are internally consistent (Total = envelope + typed). This is the
        # REAL parity invariant for the per-group Defender_<Category>_CL table: any column that exists in the
        # manifest-union but not the schema (or vice-versa), or any count drift, fails the build. Recorded as a
        # category-level Inactive entry (attributed to the manifest file) so the gate blocks push.
        if ($schemaTypedNames -is [array]) {
            $catIssues = @()
            $unionNames = @($manifestUnionTyped.Keys)
            $unionMissingInSchema = @($unionNames     | Where-Object { $_ -notin $schemaTypedNames })
            $schemaMissingInUnion = @($schemaTypedNames | Where-Object { $_ -notin $unionNames })
            if ($unionMissingInSchema.Count -gt 0) {
                $catIssues += "schema parity FAIL · manifest-union typed cols absent from schema: $($unionMissingInSchema -join ',')"
            }
            if ($schemaMissingInUnion.Count -gt 0) {
                $catIssues += "schema parity FAIL · schema typed cols absent from manifest-union: $($schemaMissingInUnion -join ',')"
            }
            if ($null -ne $schemaDeclaredTyped -and $unionNames.Count -ne $schemaDeclaredTyped) {
                $catIssues += "schema parity FAIL · manifest-union typed count=$($unionNames.Count) · schema Summary.TypedColumnCount=$schemaDeclaredTyped"
            }
            if ($null -ne $schemaDeclaredTyped -and $null -ne $schemaDeclaredTotal -and $schemaDeclaredTotal -ne ($envelopeColumnCount + $schemaDeclaredTyped)) {
                $catIssues += "schema envelope FAIL · TotalColumnCount=$schemaDeclaredTotal · expected=envelope($envelopeColumnCount)+typed($schemaDeclaredTyped)=$($envelopeColumnCount + $schemaDeclaredTyped)"
            }
            if ($catIssues.Count -gt 0) {
                $catEntry = "$relPath [Category schema parity · Status=Inactive]`n    - " + ($catIssues -join "`n    - ")
                $summary.Inactive += $catEntry
                $failures += $catEntry
            }
        }
    }
}

# ── SUMMARY ────────────────────────────────────────────────────────────────────────
# HONESTY LOCK: this OFFLINE tool reports SHIPPED (value-gated · active) — never Validated (live-proven only).
# FH-4 · compute the verdict ONCE (Inactive blocks · runtime needs >=1 Shipped), then emit JSON-or-human with a SINGLE
# exit. -Json stdout is the structured object only (per-op output is -Detailed-gated above).
$shippedCount  = @($summary.Shipped).Count
$stubCount     = @($summary.Stub).Count
$inactiveCount = @($summary.Inactive).Count
$verdict = if ($inactiveCount -gt 0 -or $shippedCount -lt 1) { 'FAIL' } else { 'PASS' }
$reason  = if ($inactiveCount -gt 0)    { "$inactiveCount Inactive entries · schema mismatch or missing required evidence" }
           elseif ($shippedCount -lt 1) { '0 Shipped ops · runtime has nothing to dispatch (need >=1 Shipped)' }
           else                         { "$shippedCount Shipped · $stubCount Stub · 0 Inactive" }

if ($Json) {
    [pscustomobject]@{
        tool          = 'Validate-Manifests'
        verdict       = $verdict
        reason        = $reason
        totalChecked  = $totalChecked
        shippedCount  = $shippedCount
        stubCount     = $stubCount
        inactiveCount = $inactiveCount
        inferTypingSkipped = $inferTypingSkipReason
        shipped       = @($summary.Shipped)
        stub          = @($summary.Stub)
        inactive      = @($summary.Inactive)
    } | ConvertTo-Json -Depth 5
} else {
    Write-Host ''
    Write-Host '======================================================================'
    Write-Host "Validate-Manifests v11 §4.17 · value-based Shipped pipeline (HONESTY LOCK)"
    Write-Host '======================================================================'
    Write-Host "Total Ops checked      : $totalChecked"
    Write-Host "Shipped (runtime use)  : $shippedCount"
    Write-Host "Stub (catalog-only)    : $stubCount"
    Write-Host "Inactive (BLOCKS push) : $inactiveCount"
    if ($inferTypingSkipReason) { Write-Host "Live-proven typing     : SKIPPED · $inferTypingSkipReason" -ForegroundColor Yellow }
    else { Write-Host "Live-proven typing     : CHECKED (captures present · data-pin gate active)" -ForegroundColor DarkGray }
    Write-Host '----------------------------------------------------------------------'
    if ($shippedCount -gt 0) {
        Write-Host ''
        Write-Host 'Shipped entries (runtime picks up · dynamic per tenant via §4.18 gates):'
        $summary.Shipped | ForEach-Object { Write-Host "  - $_" }
    }
    if ($stubCount -gt 0) {
        Write-Host ''
        Write-Host 'Stub entries (catalog-only · runtime ignores):'
        $summary.Stub | ForEach-Object { Write-Host "  - $_" }
    }
    if ($inactiveCount -gt 0) {
        Write-Host ''
        Write-Host 'Inactive entries (BLOCKING · push not allowed):'
        $summary.Inactive | ForEach-Object { Write-Host "  - $_" }
        Write-Host ''
        Write-Host 'Validate-Manifests · FAIL · fix Inactive entries before push'
    } elseif ($shippedCount -lt 1) {
        Write-Host ''
        Write-Host "Validate-Manifests · FAIL · 0 Shipped ops · runtime has nothing to dispatch (need >=1 Shipped)"
    } else {
        Write-Host ''
        Write-Host "Validate-Manifests GREEN · $shippedCount Shipped · $stubCount Stub · 0 Inactive"
    }
}
if ($verdict -eq 'FAIL') { exit 1 } else { exit 0 }
