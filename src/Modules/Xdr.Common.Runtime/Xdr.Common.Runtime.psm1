# XdrLogRaider · Xdr.Common.Runtime module
#
# The keystone activity work-unit: Invoke-XdrEntryPoll. One per-Operation invocation does:
#   1. Resolve session (Auth · cached or fresh via T1/T2/T3)
#   2. Resolve checkpoint (TimeFilter window · IngestionMode dispatch)
#   3. Build request URL (Portal + SubPortal + Path + Workspace context)
#   4. Poll → paginate (loopGuard 1000) → parse (B1/B1b/B3) → ingest (DCE → DLQ on fail)
#   5. Advance checkpoint atomically via ETag conditional
#   6. Return Result · NEVER throws (caller is the Durable Activity boundary)
#
# Atomicity invariants:
#   - Checkpoint cursor MUST NOT advance past unsent rows. The old `Add-AzTableRow -UpdateExisting`
#     pattern wasn't atomic: between read-current-checkpoint and write-new-checkpoint another
#     worker could write and silently win. Now we use `Set-XdrTableEntity -IfMatchETag` —
#     412 Precondition Failed means another worker raced us; retry once with fresh read,
#     then DLQ the batch and leave cursor untouched.
#
# StateStore partition strategy LOCKED:
#   XdrCheckpoint  · PartitionKey = "<Portal>_<Category>"  · RowKey = OperationKey
#   (Grouped by Category so batch reads at next cycle start fetch all Ops in one partition.)

Set-StrictMode -Version Latest

$script:LoopGuardMax = 1000

# Runspace-independent manifest cache (lazy-loaded per runspace · see Get-XdrManifests).
$script:XdrManifestCache = $null

function Get-XdrManifests {
    <#
    .SYNOPSIS
    Runspace-independent manifest loader. Returns @{ <Portal> = @{ <Category> = <psd1 hashtable> } }.

    .DESCRIPTION
    Azure Functions PowerShell runs functions across a POOL of runspaces. profile.ps1 runs ONCE in one
    runspace and populates its $script:LoadedManifests there — but that profile-scope variable is NOT
    visible to the OTHER pooled runspaces that subsequently run XdrDefenderRefresh. Observed live: the
    cold-start cycle (in profile's runspace) enumerated count=1; every cycle after enumerated count=0
    forever → nothing dispatched → 0 rows. profile.ps1 already documents this exact runspace trap for the
    capability cache and solves it with a module-scoped lazy-load (Get-XdrTenantCapabilities); the
    manifests were simply never migrated to that pattern. This function IS that migration: it lazy-loads
    the manifests from disk and caches them in THIS module's $script: scope, so EVERY runspace becomes
    self-sufficient on first call (module functions are auto-imported into every runspace; their $script:
    state is per-runspace, so the cache fills per-runspace on first use). Same fix-class as R3.

    Root resolution order: explicit -Root > $env:XDRLR_MANIFESTS_ROOT (set by profile.ps1 · process-scoped
    so it IS visible across runspaces) > path relative to this module (<root>/Modules/<this> →
    <root>/manifests, the deployed wwwroot layout).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string] $Root,
        [switch] $Force
    )

    if (-not $Force.IsPresent -and $null -ne $script:XdrManifestCache) {
        return $script:XdrManifestCache
    }

    if (-not $Root) { $Root = $env:XDRLR_MANIFESTS_ROOT }
    if (-not $Root -or -not (Test-Path $Root)) {
        # Deployed layout: this module lives at <wwwroot>/Modules/Xdr.Common.Runtime → manifests at
        # <wwwroot>/manifests (two levels up + 'manifests'). Used only when the env var is unset.
        $candidate = Join-Path $PSScriptRoot '..' '..' 'manifests'
        if (Test-Path $candidate) { $Root = (Resolve-Path $candidate).Path }
    }

    $result = @{}
    if ($Root -and (Test-Path $Root)) {
        foreach ($portalDir in (Get-ChildItem -Path $Root -Directory -ErrorAction SilentlyContinue)) {
            $result[$portalDir.Name] = @{}
            foreach ($catFile in (Get-ChildItem -Path $portalDir.FullName -Filter '*.psd1' -ErrorAction SilentlyContinue)) {
                try {
                    $result[$portalDir.Name][$catFile.BaseName] = Import-PowerShellDataFile -Path $catFile.FullName -ErrorAction Stop
                } catch {
                    # INTENTIONAL-FAIL-SAFE: one malformed manifest must not zero out the whole catalog;
                    # skip it and load the rest. Validate-Manifests (build-time gauntlet) is the hard gate.
                    Write-Warning "[Get-XdrManifests] parse failed: $($catFile.FullName) · $($_.Exception.Message)"
                }
            }
        }
    }

    # SELF-DESCRIBING ENTRIES (fix-at-source · generic) · op entries in each psd1 carry only Subcategory; Portal/Category
    # live at the manifest ROOT. Stamp them onto EVERY op entry here, at load, so every consumer reads a non-empty
    # Category off the entry itself — normal poll ($entryCategory), fan-out child ($Entry['Category']), fan-out PARENT
    # poll (Get-XdrParentEntityIds · $ParentEntry['Category']), entity-id cache partition, circuit breaker. WITHOUT this
    # the ParentEntry subset (built from the raw indexed parent op below) had NO Category → ConvertTo-XdrRows -Category ''
    # bind-failed EVERY cycle → Entry.Fanout.ParentPollFailed → the entity fan-out silently starved (live-caught on
    # ListPostureOversightInitiatives, 2026-06-18). Idempotent (fills only missing/empty) so the XdrDefenderRefresh
    # dispatch stamp (run.ps1) stays a harmless re-assert. MUST run BEFORE Set-XdrParentEntryLinks (it indexes these).
    foreach ($portalKey in @($result.Keys)) {
        $catsForPortal = $result[$portalKey]; if ($catsForPortal -isnot [System.Collections.IDictionary]) { continue }
        foreach ($catKey in @($catsForPortal.Keys)) {
            $man = $catsForPortal[$catKey]; if ($man -isnot [System.Collections.IDictionary]) { continue }
            $manPortal   = if ($man['Portal'])   { [string]$man['Portal'] }   else { [string]$portalKey }
            $manCategory = if ($man['Category']) { [string]$man['Category'] } else { [string]$catKey }
            foreach ($op in @($man['Operations'])) {
                if ($op -isnot [System.Collections.IDictionary]) { continue }
                if ([string]::IsNullOrEmpty([string]$op['Portal']))   { $op['Portal']   = $manPortal }
                if ([string]::IsNullOrEmpty([string]$op['Category'])) { $op['Category'] = $manCategory }
            }
        }
    }

    # N4 · attach each ENTITY op's parent poll-contract (ParentEntry · in-memory only · committed manifests stay lean)
    # so the Activity can pass it to Invoke-XdrEntityFanout → Get-XdrParentEntityIds self-seeds the id cache when empty.
    try { Set-XdrParentEntryLinks -Manifests $result } catch { Write-Warning "[Get-XdrManifests] ParentEntry link pass failed (non-fatal): $($_.Exception.Message)" }  # INTENTIONAL-FAIL-SAFE
    $script:XdrManifestCache = $result
    return $result
}

function script:Set-XdrParentEntryLinks {
    <#
    .SYNOPSIS
    N4 entity feeder · attach each ENTITY op's PARENT poll-contract as $op['ParentEntry'] (built from the LOADED
    runtime-shaped entries · no catalogue→runtime shape conversion). The Activity passes it to Invoke-XdrEntityFanout,
    whose Get-XdrParentEntityIds fallback does ONE bounded parent poll to seed the entity-id cache when it is empty —
    so an entity op resolves + polls its {id} in production WITHOUT relying on a same-runspace/same-cycle parent feed.
    Subset = exactly the fields the parent poll reads (excludes DependsOn/ParentEntry · no recursion/bloat). Idempotent.
    #>
    [CmdletBinding()]
    param([Parameter()] [AllowNull()] [hashtable] $Manifests)
    if (-not $Manifests) { return }
    # Flat index: OperationKey → entry (across ALL portals/categories · a parent may live in another Category).
    $index = @{}
    foreach ($portal in @($Manifests.Keys)) {
        $cats = $Manifests[$portal]; if ($cats -isnot [System.Collections.IDictionary]) { continue }
        foreach ($cat in @($cats.Keys)) {
            $man = $cats[$cat]; if ($man -isnot [System.Collections.IDictionary]) { continue }
            foreach ($op in @($man['Operations'])) {
                if ($op -is [System.Collections.IDictionary] -and $op['OperationKey']) { $index[[string]$op['OperationKey']] = $op }
            }
        }
    }
    # E-BLK1 · the subset MUST carry every field the parent poll reads so Get-XdrParentEntityIds shapes a REAL poll
    # (New-XdrRequestUrl/New-XdrRequestBody build URL+body from IngestionMode/TimeFilter/Pagination/CursorField/
    # LookbackHours via Get-XdrRequestParams + Resolve-XdrTimeWindow). Omitting IngestionMode/TimeFilter/CursorField/
    # LookbackHours mis-shaped the self-seeding parent poll for ANY CURSOR/WINDOW/time-filtered parent (the seed poll
    # would emit no server time predicate / wrong window). Exposure's parent is SNAPSHOT so this was latent, but the
    # engine must be GENERIC for any future-category parent. (Pagination was already present; the seed harvest is still
    # page-1-only in Get-XdrParentEntityIds — the extra fields only ensure the FIRST page request is correctly shaped.)
    $subset = @('OperationKey', 'Portal', 'Category', 'Subcategory', 'Method', 'SubPortal', 'Path', 'ResponseShape', 'ItemsContainer', 'ProjectionMap', 'Pagination', 'BodyTemplate', 'IngestionMode', 'TimeFilter', 'CursorField', 'LookbackHours')
    foreach ($portal in @($Manifests.Keys)) {
        $cats = $Manifests[$portal]; if ($cats -isnot [System.Collections.IDictionary]) { continue }
        foreach ($cat in @($cats.Keys)) {
            $man = $cats[$cat]; if ($man -isnot [System.Collections.IDictionary]) { continue }
            foreach ($op in @($man['Operations'])) {
                if ($op -isnot [System.Collections.IDictionary]) { continue }
                $dep = $op['DependsOn']
                if ($dep -isnot [System.Collections.IDictionary]) { continue }
                $pk = [string]$dep['ParentOperationKey']
                if ([string]::IsNullOrEmpty($pk) -or (-not $index.ContainsKey($pk))) { continue }
                $parent = $index[$pk]
                if ($parent -isnot [System.Collections.IDictionary]) { continue }
                $pe = @{}
                foreach ($k in $subset) { if ($parent.Contains($k) -and $null -ne $parent[$k]) { $pe[$k] = $parent[$k] } }
                if ($pe.Count -gt 0) { $op['ParentEntry'] = $pe }
            }
        }
    }
}

function ConvertTo-XdrDeepHashtable {
    <#
    .SYNOPSIS
    Recursively normalize PSCustomObject / IDictionary (incl. OrderedHashtable) to PLAIN [hashtable], arrays
    element-wise, scalars pass-through. WHY: Durable Functions serialization can deliver the Activity input
    (and its NESTED ProjectionMap/TimeFilter/Pagination) as PSCustomObject OR OrderedHashtable depending on the
    payload shape. The Activity normalizes only the TOP level; a nested PSCustomObject then (a) hits
    ConvertTo-XdrRows' [hashtable]$ProjectionMap param → ParameterBindingArgumentTransformationException (the
    live 0-rows blocker), and (b) fails `-is [System.Collections.IDictionary]` checks → pagination/time-filter
    silently skipped. Normalizing the whole entry to plain hashtables once eliminates the entire class.
    #>
    [CmdletBinding()]
    param([Parameter()] [AllowNull()] $InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [string]) { return $InputObject }
    if ($InputObject.GetType().IsPrimitive -or $InputObject -is [datetime] -or $InputObject -is [decimal]) { return $InputObject }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in @($InputObject.Keys)) { $h[[string]$k] = ConvertTo-XdrDeepHashtable -InputObject $InputObject[$k] }
        return $h
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-XdrDeepHashtable -InputObject $p.Value }
        return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable]) {
        return @($InputObject | ForEach-Object { ConvertTo-XdrDeepHashtable -InputObject $_ })
    }
    return $InputObject
}

function ConvertFrom-XdrActivityInput {
    <#
    .SYNOPSIS
    Reconstruct the Defender Activity's { Entry; CycleId } from whatever shape the Durable PowerShell host
    delivered. The Orchestrator passes the activity input as a JSON STRING wrapper
    ({"EntryJson":"<entry-json>","CycleId":"<guid>"}) — the Durable serializer mangled a live hashtable graph
    on the orchestrator->activity hop (keys lost → empty entry → Op=unknown → empty URL → 500 → 0 rows), and a
    string round-trips intact (the same principle the Refresh->Orchestrator hop already uses for Entries).
    This still normalizes DEFENSIVELY: host/serializer versions can hand the input over as String / Hashtable /
    OrderedHashtable / Newtonsoft JObject / PSCustomObject / a 1-element array wrapping any of those. Non-dict,
    non-string objects are round-tripped through JSON so their DATA (not their .NET members — the old
    PSObject.Properties path picked up an array's Length/Count/Rank as bogus keys) becomes the wrapper.

    .OUTPUTS
    @{ Entry = <plain hashtable>; CycleId = <string> }. NEVER throws (the caller is the Durable Activity, whose
    contract is to always return a Result hashtable — a throw here would fault the task → OrchestrationFailureException).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter()] [AllowNull()] $InputData)

    $result = @{ Entry = @{}; CycleId = '' }
    try {
        $src = $InputData
        # Unwrap a 1-element array/list (NOT strings/dicts, which are IEnumerable too but handled below).
        if ($src -is [System.Collections.IList] -and @($src).Count -ge 1) { $src = @($src)[0] }

        $wrapper = @{}
        if ($src -is [System.Collections.IDictionary]) {
            foreach ($k in @($src.Keys)) { $wrapper[[string]$k] = $src[$k] }
        } elseif ($src -is [string]) {
            # The Orchestrator base64-encodes the wrapper because the Durable PS layer parses+empties a raw JSON
            # activity input (string leaves → []). A base64 blob is opaque to Durable so it survives; decode it
            # back to JSON. Bare JSON (legacy/non-base64) still works — base64 is only attempted when the string
            # has no JSON punctuation and decodes to a JSON object/array.
            $str = [string]$src
            $jsonStr = $str
            if ($str.Length -ge 8 -and ($str -notmatch '[\{\}\[\]":,]') -and ($str -match '^[A-Za-z0-9+/]+={0,2}$') -and ($str.Length % 4 -eq 0)) {
                try { $cand = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($str)); if ($cand.TrimStart() -match '^[\{\[]') { $jsonStr = $cand } } catch { <# not base64 · INTENTIONAL-FAIL-SAFE #> }
            }
            $o = $jsonStr | ConvertFrom-Json -AsHashtable -Depth 30
            if ($o -is [System.Collections.IDictionary]) { foreach ($k in @($o.Keys)) { $wrapper[[string]$k] = $o[$k] } }
        } elseif ($null -ne $src) {
            # JObject / PSCustomObject / unknown → serialize DATA then re-parse to a clean hashtable.
            $o = ($src | ConvertTo-Json -Depth 30 -Compress) | ConvertFrom-Json -AsHashtable -Depth 30
            if ($o -is [System.Collections.IDictionary]) { foreach ($k in @($o.Keys)) { $wrapper[[string]$k] = $o[$k] } }
        }

        # Case-insensitive extraction (Durable can change key casing across hosts).
        $ejson = $null; $legacy = $null
        foreach ($k in @($wrapper.Keys)) {
            $kl = [string]$k
            if ($kl -ieq 'CycleId') { $result.CycleId = [string]$wrapper[$k] }
            elseif ($kl -ieq 'EntryJson') { $ejson = $wrapper[$k] }
            elseif ($kl -ieq 'Entry') { $legacy = $wrapper[$k] }
        }

        $entry = if ($ejson) { [string]$ejson | ConvertFrom-Json -AsHashtable -Depth 30 }
                 elseif ($legacy) { $legacy }
                 else { $wrapper }

        # Guarantee a plain [hashtable] for Invoke-XdrEntryPoll's [hashtable] param (deep-normalize handles nesting).
        if ($entry -isnot [hashtable]) {
            $eh = @{}
            if ($entry -is [System.Collections.IDictionary]) { foreach ($k in @($entry.Keys)) { $eh[[string]$k] = $entry[$k] } }
            elseif ($entry -and $entry.PSObject) { foreach ($p in $entry.PSObject.Properties) { $eh[$p.Name] = $p.Value } }
            $entry = $eh
        }
        $result.Entry = $entry
    } catch {
        # INTENTIONAL-FAIL-SAFE: an unparseable input must not throw — return empty so the Activity still
        # returns a Result (Success=$false · Op=unknown). The RAW-INPUT host line records the offending shape.
        $result = @{ Entry = @{}; CycleId = '' }
    }
    return $result
}

# ════════════════════════════════════════════════════════════════════════════════════════════════════════════════
# ─── EXACTLY-ONCE DECISION FUNCTIONS (plan §35.2 · pure · table-testable) ─────────────────────────────────────────
# ════════════════════════════════════════════════════════════════════════════════════════════════════════════════
# The two exactly-once decision blocks of Invoke-XdrEntryPoll, lifted VERBATIM into pure functions so each can be
# table-tested in isolation (no auth/HTTP/DCE/checkpoint mocks). They take only DATA in and return DATA out — NO
# side-effects, NO telemetry, NO I/O. Invoke-XdrEntryPoll calls them from the EXACT same spots with the EXACT same
# args, so the end-to-end ExactlyOnce/ResumablePagination/SnapshotReEmit proofs are unchanged (a pure lift).

# Shared row helpers (the same scriptblocks the inline blocks used · re-declared here so the functions are
# self-contained). $keyOf = composite natural-key ('' when no NaturalKey → boundary ties kept). $parseDt = lenient
# UTC parse ($null on absent/unparseable → fail-safe keep).
$script:XdrKeyOf   = { param($row, $keys) if (@($keys).Count -eq 0) { '' } else { ($keys | ForEach-Object { [string]$row[$_] }) -join '|' } }
$script:XdrParseDt = { param($val) if (-not $val) { $null } else { try { (ConvertTo-XdrUtc $val) } catch { $null } } }
# F-CANON (2026-06-20) · order-INSENSITIVE canonical form for content-identity hashing. LIVE-caught by the manual
# OWNER-read (the automated gate passed it as within-bound): Exposure GetAppsSecureScoreMetric / GetIdentitySecureScoreMetric
# re-emit every cycle though SEMANTICALLY identical — the API returns the `recommendations` array in a DIFFERENT ORDER
# each poll (same set, shuffled), so a raw-string SHA differs every cycle → the snapshot signature sees a FALSE "change"
# → re-emit → cross-cycle dup-accumulation (the #19 class via a FALSE volatile, not a real value change · same class as
# the LaraTM unordered-collection bug). FIX (at source, generic to ALL ops): canonicalize for the HASH ONLY — recursively
# sort object keys AND array elements (ordinal) so a no-op reorder yields the SAME hash → the skip fires; a genuine value
# change still alters the canonical form → new hash → emit (fail-safe preserved). The STORED RawJson keeps source order
# (no data mutation). Non-JSON / unparseable → hash the raw string (fail-safe · never throws).
$script:XdrCanonicalize = {
    param($v)
    if ($null -eq $v) { return 'null' }
    if ($v -is [System.Collections.IDictionary]) {
        $keys = [string[]]@($v.Keys); [System.Array]::Sort($keys, [System.StringComparer]::Ordinal)
        $parts = foreach ($k in $keys) { ([string]$k) + '=' + (& $script:XdrCanonicalize $v[$k]) }
        return '{' + ($parts -join '&') + '}'
    }
    if (($v -is [System.Collections.IEnumerable]) -and ($v -isnot [string])) {
        $items = [string[]]@(foreach ($e in $v) { & $script:XdrCanonicalize $e }); [System.Array]::Sort($items, [System.StringComparer]::Ordinal)
        return '[' + ($items -join ',') + ']'
    }
    return [string]$v
}
# F-VOLATILE-HASH (2026-06-25) · STRIP a per-op-declared set of VOLATILE non-identity fields from the record BEFORE
# canonicalizing/hashing — the content-identity must NOT include a field that changes EVERY poll while the logical
# record is unchanged. WHY (distinct from F-CANON, which neutralized reorder-but-IDENTICAL telemetry): some SNAPSHOT
# ops carry a genuinely-changing non-identity field every cycle (live-caught 2026-06-25: Configuration
# ListCriticalAssetClassifications `timestamp` [the only field differing across two cycles of the same ruleId] ·
# PortalServices CheckAppGovernanceOnboarding `id` [a per-request random GUID on a singleton onboarding-status] ·
# ExposureManagement GetPostureOversightInitiative `dataHistory` [a poll-timestamped rolling time-series]). With the
# field IN the hash, the SAME logical record re-emits every cycle under a NEW RecordId → the _CL table bloats
# UNBOUNDED, and the SnapshotNoDupAccum/ExactlyOnce gates MISS it (the re-emits have DIFFERENT RecordIds → look
# distinct → dupFactor≈1.0). The strip is HASH-ONLY (the STORED RawJson keeps the field · no data mutation — we strip
# a PARSED COPY). PER-OP declaration is REQUIRED, never a global field-name blacklist: a field name that is volatile
# for one op may be the IDENTITY for another, so stripping globally would mask a real change. The strip is TOP-LEVEL
# only (volatile fields are declared as top-level record fields · a nested same-named key is left untouched), and
# CASE-INSENSITIVE on the declared names. Fail-safe preserved: non-JSON / unparseable → hash the raw string as-is
# (the strip simply does not apply); an empty/absent declaration → byte-identical to the pre-fix behavior.
$script:XdrCanonicalJson = {
    param($raw, $volatileFields)
    if ([string]::IsNullOrEmpty([string]$raw)) { return '' }
    try {
        $o = [string]$raw | ConvertFrom-Json -AsHashtable -Depth 64 -ErrorAction Stop
        $vf = @($volatileFields | Where-Object { -not [string]::IsNullOrEmpty([string]$_) })
        if ($vf.Count -gt 0 -and ($o -is [System.Collections.IDictionary])) {
            # Strip declared volatile keys from a COPY at the TOP level only (case-insensitive). $o is already a fresh
            # parse (not the stored RawJson), so removing keys here can never mutate persisted data.
            $vfSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($f in $vf) { [void]$vfSet.Add([string]$f) }
            foreach ($k in @($o.Keys)) { if ($vfSet.Contains([string]$k)) { $o.Remove($k) } }
        }
        return (& $script:XdrCanonicalize $o)
    }
    catch { return [string]$raw }   # INTENTIONAL-FAIL-SAFE: non-JSON → hash the raw string as-is
}
# $XdrContentHash = the KEYLESS RecordId fallback (2026-06-18 · generic, all categories). An op with no proven
# NaturalKey would get an EMPTY RecordId → no dedup identity → a SNAPSHOT's per-cycle re-emits pile up as
# un-dedupable duplicates (live-caught: SecureScore GetInsights 24,300 rows / empty RecordId / 1 distinct). A
# content-hash gives such a row a STABLE identity: identical content → identical RecordId → dedupable (query
# latest-per-RecordId); a genuinely-changed snapshot → new hash → kept. HONEST — the content IS the identity, not a
# guessed semantic key (the honesty-lock reserves NaturalKey for count==dcount live-proof). SHA256 over RawJson (the
# raw item, NOT the volatile envelope) → 64-hex; empty/absent RawJson → '' (no false identity). HashData/ToHexString
# are .NET8 statics (Functions PS7.4) — no per-row HashAlgorithm object to allocate/dispose.
# $volatileFields (optional · F-VOLATILE-HASH) threads the per-op manifest VolatileHashFields through to the
# canonicalizer so the stripped fields never enter the SHA256. Absent/empty → identical to the pre-fix hash.
$script:XdrContentHash = { param($raw, $volatileFields) if ([string]::IsNullOrEmpty([string]$raw)) { '' } else { $c = & $script:XdrCanonicalJson $raw $volatileFields; [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($c))).ToLowerInvariant() } }
# $XdrSnapshotSignature (2026-06-19 · plan §B.3 cross-cycle SNAPSHOT dedup · F-SNAPSHOT-SIG). PURE. The cross-cycle
# IDENTITY of a CURSORLESS SNAPSHOT = SHA256 over its SORTED set of per-row CONTENT hashes (SHA256 of each row's
# RawJson · NOT the RecordId — for a KEYED SNAPSHOT the RecordId is the NaturalKey, so a key-based signature would
# MISS a value change [same keys, new values] and FALSELY skip it = DATA LOSS [verified: GetTenantContext keys on
# OrgId, the posture metrics on id/orgId]; the CONTENT hash captures value changes for BOTH keyed and keyless). A
# cursorless SNAPSHOT re-fetches the FULL state every cycle; without cross-cycle dedup the EO (Select-XdrExactlyOnceRows)
# re-emits the ENTIRE set each cycle (live-caught 2026-06-19: GetInsights 43,200 rows / 2,753 distinct · 16× · Exposure
# GetPostureOversightMetricIds 719× · systemic · the baseline-lock's "verifier must BLOCK dup-accumulation"). When this
# signature == the committed signature the snapshot is UNCHANGED → already ingested → the EO emits NOTHING. A CHANGED
# snapshot (or cold / no-prior) → a new signature → emit ALL (FAIL-SAFE: a volatile RawJson field makes the signature
# never match → re-emits, never DROPS). Empty/no rows → '' (cold · no false skip). Ordinal sort → deterministic +
# culture-independent + order-independent across page/fetch ordering.
# $volatileFields (optional · F-VOLATILE-HASH) is threaded into EACH per-row content hash so the cross-cycle snapshot
# signature is also computed over the volatile-stripped identity — otherwise a volatile field would make the signature
# never match → the snapshot re-emits in full every cycle (the same dup-accumulation this fix blocks). The outer hash
# (over the sorted per-row hashes) needs no strip — its input is already 64-hex digests, not record JSON.
$script:XdrSnapshotSignature = { param($rows, $volatileFields) $hs = [System.Collections.Generic.List[string]]::new(); foreach ($r in @($rows)) { $ch = & $script:XdrContentHash ([string]$r['RawJson']) $volatileFields; if ($ch) { $hs.Add($ch) } }; if ($hs.Count -eq 0) { '' } else { $hs.Sort([System.StringComparer]::Ordinal); & $script:XdrContentHash ([string]::Join("`n", $hs)) } }

# ════════════════════════════════════════════════════════════════════════════════════════════════════════════════
# ─── GENERIC api-version NEGOTIATION (F-APIVERSION · 2026-06-25 · replaces the per-op curation) ───────────────────
# ════════════════════════════════════════════════════════════════════════════════════════════════════════════════
# WHY (the operator's call): the tvm/analytics backend is the SAME apiproxy/mtp portal as every other internal API, so
# the ENGINE supplies its `api-version` REQUEST header UNIFORMLY — NOT curated per op. The query-string form 400s; the
# header is REQUIRED, and the working version VARIES BY ROUTE (LIVE-PROVEN 2026-06-25 explicit-version matrix · Probe-
# TvmApiVersionMatrix-Local: assets/topVulnerable·products·riskscore·advisories·changeEvents/ negotiate '1.0' and REJECT
# '2.0' with UnsupportedApiVersion(400)/405; changeEvents/sca/topPerDay REJECTS '1.0'(405) and needs '2.0'). So a single
# fixed default is impossible → the engine NEGOTIATES: send the default, and on a VERSION-REJECT 4xx retry with the next
# candidate, caching the first that gets past the version gate PER ROUTE-PREFIX so it is a one-time negotiation per route.
# FIRES ONLY for URLs whose path contains '/tvm/analytics/' (route-based · generic) — every other (non-tvm/analytics)
# request is BYTE-IDENTICAL (no api-version header · no extra round-trip · no regression). Modeled on the probe tool's
# Invoke-TvmGetNegotiated (the proven shape). The `requestHeaders` curation MECHANISM is kept as a generic per-op header
# override hook; it just no longer carries api-version.
$script:XdrTvmApiVersionCandidates = @('1.0','2.0')   # 1.0 FIRST · the live matrix shows MOST shipped tvm/analytics routes (assets/products/riskscore/advisories/changeEvents · 10 of 11 ships) negotiate to 1.0; only sca/topPerDay needs 2.0 → 1.0-first minimizes first-poll version-rejects (then cached per route-prefix · order is fail-safe either way: the loser is retried)
$script:XdrApiVersionCache = @{}                       # route-prefix → the version that last got past the version gate (per-runspace · same lifetime/scope as XdrEntityCache)

function script:Test-XdrIsTvmAnalyticsUrl {
    # GENERIC route gate · true ONLY for the tvm/analytics surface (the backend that requires the api-version header).
    # Matches on the PATH segment so a query value can never false-trigger it. Case-insensitive (defensive).
    [OutputType([bool])]
    param([string]$Url)
    if ([string]::IsNullOrEmpty($Url)) { return $false }
    $p = $Url
    try { $p = ([Uri]$Url).AbsolutePath } catch { $p = $Url }   # fall back to the raw string if it is not an absolute URI
    return ($p -match '(?i)/tvm/analytics/')
}

function script:Get-XdrApiVersionRoutePrefix {
    # The cache key = the request PATH with the query stripped (each tvm/analytics op has a distinct path → one-time
    # negotiation per route). A {assetId}-style fan-out path that embeds an id negotiates once per distinct id URL
    # (cheap · always converges · no fragile id-detection heuristic); every non-fan-out op caches exactly once.
    [OutputType([string])]
    param([string]$Url)
    try { return ([Uri]$Url).GetLeftPart([System.UriPartial]::Path) } catch { return ($Url -replace '\?.*$', '') }
}

function Get-XdrCursorAtPrecision {
    <#
    .SYNOPSIS
    G2 · Round/truncate a [DateTime] to an optional CursorPrecision for boundary-tie comparison. DEFAULT (empty /
    $null precision) = the value UNCHANGED (exact tick match · full back-compat · GetHistory unchanged). A coarser
    precision collapses sub-precision jitter so a boundary row that REAPPEARS at a coarser sub-second precision still
    compares EQUAL to the committed high-water (→ dropped, not duplicated, not lost). Fail-safe: an unknown precision
    token leaves the value unchanged.
    .PARAMETER Value
    The [DateTime] to normalize (already UTC).
    .PARAMETER Precision
    One of: '' / $null (exact · default) · 'Ticks' (exact) · 'Microsecond' · 'Millisecond' · 'Second' · 'Minute'.
    #>
    [CmdletBinding()]
    [OutputType([DateTime])]
    param([Parameter(Mandatory)][DateTime]$Value, [string]$Precision = '')
    if ([string]::IsNullOrWhiteSpace($Precision)) { return $Value }
    switch ($Precision.Trim().ToLowerInvariant()) {
        'ticks'       { return $Value }
        'exact'       { return $Value }
        'microsecond' { return [DateTime]::new(($Value.Ticks - ($Value.Ticks % 10)), $Value.Kind) }                 # 10 ticks = 1 µs
        'millisecond' { return [DateTime]::new(($Value.Ticks - ($Value.Ticks % [TimeSpan]::TicksPerMillisecond)), $Value.Kind) }
        'second'      { return [DateTime]::new(($Value.Ticks - ($Value.Ticks % [TimeSpan]::TicksPerSecond)), $Value.Kind) }
        'minute'      { return [DateTime]::new(($Value.Ticks - ($Value.Ticks % [TimeSpan]::TicksPerMinute)), $Value.Kind) }
        default       { return $Value }   # INTENTIONAL-FAIL-SAFE: unknown precision → exact (never widen unexpectedly)
    }
}

function Select-XdrExactlyOnceRows {
    <#
    .SYNOPSIS
    Boundary de-dup → exactly-once (plan §35.2 · NO DCR dedup). PURE. Drop rows OLDER than the high-water. A row AT the
    exact high-water (a boundary tie) defaults to DROP — the committed high-water proves a row at this value was already
    ingested — and is RESCUED (kept) ONLY when proven NEW: a NON-EMPTY boundary key set that does not contain its key.
    An empty/lost boundary key set with a committed high-water is DEGRADED → drop (no-dup priority · F-BOUNDARY: the old
    keep-unless-seen default re-emitted every tie when the set was empty). Keep everything newer. Cold start (no
    HighWaterUtc) → keep all. Unparseable/absent cursor field on a row → kept (fail-safe · the row still carries RawJson).

    .PARAMETER Rows
    The raw fetched rows (any order). Each is a [hashtable]/IDictionary.

    .PARAMETER HighWaterUtc
    The exact committed high-water [DateTime] (UTC) from last cycle, or $null on cold start (→ keep all).

    .PARAMETER CursorField
    The high-water field name on each row, or $null/'' (→ keep all · no cursor to compare).

    .PARAMETER NaturalKey
    The boundary natural-key field name(s) (array). Empty → boundary ties are always kept.

    .PARAMETER PriorKeys
    The set of natural keys that were AT the exact high-water last cycle (HashSet[string] or any collection exposing
    .Contains). A boundary-tie row whose key is in this set is dropped (already ingested).

    .PARAMETER CursorPrecision
    G2 · OPTIONAL precision at which to compare the row cursor to the high-water at the boundary (see
    Get-XdrCursorAtPrecision). DEFAULT empty = exact tick match (back-compat · GetHistory unchanged).

    .OUTPUTS
    [System.Collections.Generic.List[hashtable]] of the rows to ingest (insertion order preserved).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[hashtable]])]
    param(
        [Parameter()] [AllowNull()] [AllowEmptyCollection()] $Rows,
        [Parameter()] [AllowNull()] [Nullable[DateTime]] $HighWaterUtc,
        [Parameter()] [AllowNull()] [string] $CursorField,
        [Parameter()] [AllowNull()] [AllowEmptyCollection()] [string[]] $NaturalKey = @(),
        [Parameter()] [AllowNull()] $PriorKeys,
        [Parameter()] [string] $CursorPrecision = '',
        [Parameter()] [AllowNull()] [string] $CurrentSnapshotSignature = '',
        [Parameter()] [AllowNull()] [string] $PriorSnapshotSignature = ''
    )
    # F-NULLKEY (2026-06-20) · BOUNDARY normalize: collapse $null / @($null) / @('') / @() to one canonical keyless
    # @() so a malformed NaturalKey (any caller, any upstream collapse) can NEVER reach $keyOf as a null index. The
    # @() operator + filter make this generic to ALL keyless ops, not a patch for the one that surfaced it.
    $NaturalKey = @($NaturalKey | Where-Object { -not [string]::IsNullOrEmpty([string]$_) })
    $keyOf   = $script:XdrKeyOf
    $parseDt = $script:XdrParseDt
    $ingestRows = [System.Collections.Generic.List[hashtable]]::new()
    $hwUtc = $HighWaterUtc

    # EO2 (audit 2026-06-12) · INTRA-CYCLE dedup FIRST, CURSOR-MODE ONLY. Under a CURSOR op's descending sort, an
    # arrival between the page-N and page-N+1 HTTP calls re-serves a row across the page boundary; without this it
    # lands TWICE in one DCE batch (count!=dcount on a busy tenant · no crash). SNAPSHOT ops (no CursorField) are
    # EXCLUDED — they intentionally re-emit the full current state, and a snapshot's NaturalKey is not a dedup
    # signal within one poll. Collapse the fetched set by NaturalKey keeping the FIRST occurrence; a row whose
    # composite key is INCOMPLETE ('' — a null component) is NEVER collapsed (EO5: distinct null-key rows survive).
    # The cross-cycle high-water/boundary filter then runs on the deduped set.
    $src = @($Rows)
    if ($CursorField -and @($NaturalKey).Count -gt 0) {
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $deduped = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($r in $src) {
            $k = & $keyOf $r $NaturalKey
            if ($k -and -not $seen.Add($k)) { continue }   # already seen this fetch → intra-cycle dup → skip
            $deduped.Add($r)
        }
        $src = $deduped
    }

    if ($hwUtc -and $CursorField) {
        # Compare the high-water itself at the requested precision so a boundary tie is matched precision-consistently.
        $hwCmp = Get-XdrCursorAtPrecision -Value ([DateTime]$hwUtc) -Precision $CursorPrecision
        # StrictMode-safe element count (HashSet.Count is not surfaced as a PSProperty under Set-StrictMode Latest).
        $priorKeyCount = if ($null -ne $PriorKeys) { @($PriorKeys).Count } else { 0 }
        foreach ($r in $src) {
            $rt = & $parseDt $r[$CursorField]
            if ($null -eq $rt) { $ingestRows.Add($r); continue }
            $rtCmp = Get-XdrCursorAtPrecision -Value $rt -Precision $CursorPrecision
            if ($rtCmp -gt $hwCmp) { $ingestRows.Add($r); continue }
            if ($rtCmp -eq $hwCmp) {
                # F-BOUNDARY (live-proven 2026-06-12) · BOUNDARY TIE default = DROP. The committed high-water IS this
                # exact value, so a row at it was already ingested last cycle. RESCUE (keep) ONLY a provably-NEW
                # same-timestamp row: a NON-EMPTY boundary-key set that does NOT contain this key. A keyless row can't be
                # deduped so keep it (fail-safe · still carries RawJson). An EMPTY/null PriorKeys with a committed
                # high-water is a DEGRADED state (the boundary keys were lost/not-persisted) so DROP, never re-emit.
                # The OLD logic (keep-unless-in-PriorKeys) re-emitted every boundary tie when the key set was empty —
                # the live cold-start/cross-cycle duplicate (GetHistory ActionId re-ingested once per degraded cycle).
                $bk = & $keyOf $r $NaturalKey
                # F-KEYLESS-CURSOR (2026-06-20) · a KEYLESS CURSOR op (a bucketed-date cursor — e.g. GetInsights keyed
                # on createdDate, 30 insights/day sharing one date) has no NaturalKey → the boundary tie would KEEP-ALL
                # and re-emit the volatile current bucket EVERY cycle (count!=dcount · the dup-accumulation class). Fall
                # back to the row's RecordId (the normalized content-hash · $XdrContentHash) as the boundary key so the
                # tie dedups by CONTENT: an UNCHANGED current-bucket row (RecordId in PriorKeys) drops, a CHANGED one
                # (new content-hash) is kept. KEYED CURSOR ops have a non-empty $bk already → UNCHANGED. A truly id-less
                # row (no NaturalKey AND no RecordId) still keeps below (fail-safe · carries RawJson).
                if (-not $bk) { $bk = [string]$r['RecordId'] }
                if (-not $bk) { $ingestRows.Add($r) }
                elseif (($priorKeyCount -gt 0) -and (-not $PriorKeys.Contains($bk))) { $ingestRows.Add($r) }
                # else (PriorKeys empty/null = degraded · OR key already ingested) drop
            }
            # $rtCmp -lt $hwCmp → already ingested last cycle → drop
        }
    } else {
        # SNAPSHOT (cursorless · plan §B.3 · F-SNAPSHOT-SIG) cross-cycle dedup. A keyless SNAPSHOT re-fetches the FULL
        # current state every cycle; the legacy path re-emitted the ENTIRE set each cycle (un-bounded dup-accumulation ·
        # live-caught 2026-06-19 GetInsights 43,200/2,753 · systemic). When the caller passes a CurrentSnapshotSignature
        # (hash of the sorted RecordId set · $script:XdrSnapshotSignature) AND a committed PriorSnapshotSignature, and
        # they MATCH, the snapshot is UNCHANGED → already ingested last cycle → emit NOTHING (exactly-once across cycles,
        # the no-dup priority). A CHANGED snapshot, a cold start (no prior signature), or a caller that passes no
        # signature (back-compat · e.g. a cursor op routed here with $CursorField unset) → emit ALL (fail-safe · the
        # legacy verbatim behavior). The new signature persists via Get-XdrAdvancedFrontier so next cycle can compare.
        if ($PriorSnapshotSignature -and $CurrentSnapshotSignature -and ($CurrentSnapshotSignature -eq $PriorSnapshotSignature)) {
            # unchanged snapshot → already ingested → emit nothing
        } else {
            foreach ($r in $src) { $ingestRows.Add($r) }
        }
    }
    # Comma-protect so a 0/1-element List is returned AS the List (not unrolled to $null/scalar by the pipeline).
    return ,$ingestRows
}

function Get-XdrAdvancedFrontier {
    <#
    .SYNOPSIS
    High-water + boundary accumulation · U1 resume-aware (plan §35.2 + §16 U1). PURE. Computes the cross-cycle
    high-water = max(CursorField) over INGESTED rows and the boundary set = the natural keys at that exact max,
    starting from an accumulation BASELINE so the running max never regresses across resume cycles. Then maps the
    accumulated pending high-water onto what to PERSIST based on drain completeness:
      COMPLETE   → promote the pending high-water to the committed Cursor; clear all resume state.
      INCOMPLETE → keep Cursor/BoundaryKeys at their prior committed value; stash the running max in the Resume* fields.

    .PARAMETER Baseline
    The accumulation baseline high-water STRING — the prior PENDING high-water when mid-resume, else the committed
    high-water (''/$null when neither). The running max never regresses below this.

    .PARAMETER IngestRows
    The de-duped rows being ingested THIS cycle (the Select-XdrExactlyOnceRows output).

    .PARAMETER DrainComplete
    $true when the page loop exited naturally (promote); $false when the per-cycle budget stopped it WITH more data
    (do not advance the committed high-water · stash resume state).

    .PARAMETER CursorField
    The high-water field name, or $null/'' (no cursor → high-water is not derived; committed fallbacks used).

    .PARAMETER NaturalKey
    The boundary natural-key field name(s) (array).

    .PARAMETER AccumKeys
    The baseline boundary keys (the keys at the baseline high-water · prior pending set when resuming, else the prior
    committed set). Accumulated when the running max does NOT advance past the baseline (same-timestamp ties).

    .PARAMETER HasCheckpoint
    $true when a checkpoint row existed (drives the committed fallbacks for the no-CursorField / incomplete branches).

    .PARAMETER CommittedCursor
    The prior committed Cursor value (raw · may be $null) · used as a fallback when CursorField is absent.

    .PARAMETER CommittedBoundaryKeys
    The prior committed BoundaryKeys value, pre-stringified ('' when none).

    .PARAMETER PageCursor
    The page-local server token at loop exit · the last-resort NextCursor fallback when there is no CursorField AND no
    committed cursor (preserves the legacy SNAPSHOT/cursorless complete-drain path verbatim).

    .OUTPUTS
    @{ NextCursor; NextBoundaryKeys; ResumeHighWater; ResumeBoundaryKeys }.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()] [AllowNull()] [string] $Baseline,
        [Parameter()] [AllowNull()] [AllowEmptyCollection()] $IngestRows,
        [Parameter(Mandatory)] [bool] $DrainComplete,
        [Parameter()] [AllowNull()] [string] $CursorField,
        [Parameter()] [AllowNull()] [AllowEmptyCollection()] [string[]] $NaturalKey = @(),
        [Parameter()] [AllowNull()] [AllowEmptyCollection()] $AccumKeys,
        [bool] $HasCheckpoint = $false,
        [Parameter()] [AllowNull()] $CommittedCursor = $null,
        [Parameter()] [AllowNull()] [string] $CommittedBoundaryKeys = '',
        [Parameter()] [AllowNull()] $PageCursor = $null,
        [Parameter()] [AllowNull()] [string] $CurrentSnapshotSignature = '',
        [Parameter()] [AllowNull()] [string] $CommittedSnapshotSignature = ''
    )
    # F-NULLKEY (2026-06-20) · symmetric to Select-XdrExactlyOnceRows · collapse $null / @($null) / @('') / @() to a
    # clean keyless @() so $keyOf (the boundary-key derivation at line ~550) is never indexed by a null component.
    $NaturalKey = @($NaturalKey | Where-Object { -not [string]::IsNullOrEmpty([string]$_) })
    $keyOf   = $script:XdrKeyOf
    $parseDt = $script:XdrParseDt

    $accumHwStr      = if ($Baseline) { [string]$Baseline } else { '' }
    $accumKeys       = @($AccumKeys)
    $accumHwDt       = & $parseDt $accumHwStr
    $newHwStr        = $accumHwStr
    $newBoundaryKeys = ($accumKeys | Sort-Object) -join ','
    $rows = @($IngestRows)
    if ($CursorField -and $rows.Count -gt 0) {
        # Start from the accumulation baseline so the running max never regresses across cycles.
        $maxVal = $accumHwDt
        foreach ($hwRow in $rows) { $dt = & $parseDt $hwRow[$CursorField]; if ($dt -and ($null -eq $maxVal -or $dt -gt $maxVal)) { $maxVal = $dt } }
        if ($maxVal) {
            $newHwStr = $maxVal.ToString('o')
            $boundarySet = [System.Collections.Generic.SortedSet[string]]::new()
            # If the running max did NOT advance past the accumulation baseline (only same-timestamp ties were newly
            # ingested), ACCUMULATE the baseline boundary keys — otherwise an already-seen tie at this exact timestamp
            # could re-ingest. When the max advances, the set is fresh by construction.
            if ($accumHwDt -and $maxVal -eq $accumHwDt) { foreach ($pk in $accumKeys) { [void]$boundarySet.Add($pk) } }
            # F-KEYLESS-CURSOR (2026-06-20) · symmetric to Select-XdrExactlyOnceRows: a keyless CURSOR op has no
            # NaturalKey so the boundary set would be EMPTY (nothing to dedup the next-cycle tie against). Fall back to
            # the RecordId (content-hash) so the boundary set carries the current-bucket content identities → next cycle
            # an unchanged row drops, a changed one is kept. KEYED CURSOR ops keep their NaturalKey ($bk non-empty).
            foreach ($hwRow in $rows) { $dt = & $parseDt $hwRow[$CursorField]; if ($dt -and $dt -eq $maxVal) { $bk = & $keyOf $hwRow $NaturalKey; if (-not $bk) { $bk = [string]$hwRow['RecordId'] }; if ($bk) { [void]$boundarySet.Add($bk) } } }
            $newBoundaryKeys = ($boundarySet) -join ','
        }
    }

    if ($DrainComplete) {
        # COMPLETE → promote the pending high-water to the committed Cursor; clear all resume state.
        $nextCursor       = if ($CursorField) { $newHwStr } elseif ($CommittedCursor) { [string]$CommittedCursor } else { $PageCursor }
        $nextBoundaryKeys = if ($CursorField) { $newBoundaryKeys } elseif ($HasCheckpoint) { [string]$CommittedBoundaryKeys } else { '' }
        $resumeHwOut      = ''
        $resumeKeysOut    = ''
        # F-SNAPSHOT-SIG · a cursorless SNAPSHOT promotes THIS cycle's signature (the full drained snapshot's identity)
        # so next cycle can detect "unchanged" and skip the re-emit. Cursor ops dedup via the high-water → no sig ('').
        $nextSnapSig      = if (-not $CursorField) { [string]$CurrentSnapshotSignature } else { '' }
    } else {
        # INCOMPLETE → DO NOT advance the committed high-water; keep Cursor/BoundaryKeys at prior committed values;
        # stash the running max in the Resume* fields so the next cycle continues the accumulation + the same window.
        $nextCursor       = if ($CommittedCursor) { [string]$CommittedCursor } else { '' }
        $nextBoundaryKeys = if ($HasCheckpoint) { [string]$CommittedBoundaryKeys } else { '' }
        $resumeHwOut      = $newHwStr
        $resumeKeysOut    = $newBoundaryKeys
        # F-SNAPSHOT-SIG · a partial (budget-stopped) drain must NOT commit a partial-snapshot signature (it would
        # falsely "match" next cycle and skip the un-drained remainder) → keep the committed signature until COMPLETE.
        $nextSnapSig      = if (-not $CursorField) { [string]$CommittedSnapshotSignature } else { '' }
    }

    return @{
        NextCursor            = $nextCursor
        NextBoundaryKeys      = $nextBoundaryKeys
        ResumeHighWater       = $resumeHwOut
        ResumeBoundaryKeys    = $resumeKeysOut
        NextSnapshotSignature = $nextSnapSig
    }
}

function Invoke-XdrEntryPoll {
    <#
    .SYNOPSIS
    THE keystone Activity work-unit. Returns Result hashtable. NEVER throws.

    .PARAMETER Entry
    One manifest entry (Portal · Category · OperationKey · Method · Path · IngestionMode · …).

    .PARAMETER CorrelationId
    Cycle-level correlation GUID propagated from Refresh → Orchestrator → Activity → here →
    every Track-XdrEvent and every StateStore row. Allows KQL filtering by single cycle.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [hashtable] $Entry,
        [string] $CorrelationId = '',
        [string] $ParentRecordId = ''   # F2 · the fan-out parent entity id (entity-DAG link · '' for a top-level / non-fan-out poll)
    )

    # Deep-normalize FIRST: guarantees the entry AND every nested value (ProjectionMap/TimeFilter/Pagination)
    # is a plain [hashtable] regardless of how Durable serialization delivered it. Without this a nested
    # PSCustomObject ProjectionMap fails ConvertTo-XdrRows' [hashtable] param (ParameterBindingArgumentTransformationException
    # · the live 0-rows blocker) and breaks `-is [IDictionary]` pagination/time-filter detection. Idempotent.
    $Entry = ConvertTo-XdrDeepHashtable -InputObject $Entry

    $startedUtc = [DateTime]::UtcNow
    $result = @{
        OperationKey  = $Entry['OperationKey'] ?? 'unknown'
        Success       = $false
        ItemCount     = 0
        BytesIngested = 0
        ErrorClass    = $null
        ErrorMessage  = $null
        DurationMs    = 0
        StartedUtc    = $startedUtc.ToString('o')
        CorrelationId = $CorrelationId
    }
    # E-BLK2 · the BASE operation key (the fan-out-stripped OperationKey). For a top-level poll it EQUALS
    # $result.OperationKey. For an entity fan-out CHILD, Invoke-XdrEntityFanout set OperationKey to the COMPOSITE
    # checkpoint key "<baseOpKey>|<entityId>" so the checkpoint RowKey / breaker / single-flight lease stay PER-ENTITY
    # (per-entity exactly-once by construction). But the COMPOSITE key must NOT leak into the row's `Operation`
    # envelope column nor the poll telemetry OperationKey: a composite Operation breaks any group-by-Operation AND
    # FALSE-FAILS the op-scoped per-op verifier gate (Operation == '<baseOpKey>'). So $result.OperationKey stays
    # COMPOSITE (checkpoint/breaker/lease/Result), while $baseOperationKey drives the row Operation + poll telemetry.
    # The composite FORMAT is owned by Invoke-XdrEntityFanout, which stamps the authoritative un-composited base on the
    # child as $Entry['BaseOperationKey']; honor it first, else strip a single trailing '|<id>' suffix defensively
    # (the entity id is preserved in ParentRecordId/RawJson regardless). A non-fan-out op has neither → base == op key.
    $baseOperationKey = if (-not [string]::IsNullOrEmpty([string]$Entry['BaseOperationKey'])) { [string]$Entry['BaseOperationKey'] }
                        else { [string]$result.OperationKey -replace '\|[^|]*$', '' }
    if ([string]::IsNullOrEmpty($baseOperationKey)) { $baseOperationKey = [string]$result.OperationKey }
    # Circuit-breaker scope (declared before the try so the end-of-function update is StrictMode-safe even if an
    # early read throws). $circuitPartition stays $null until we know Portal_Category → end-update is then skipped.
    $circuitPartition = $null
    $circuitState = @{ State = 'Closed'; FailureCount = 0; OpenedUtc = $null }
    # G3 single-flight scope (declared before the try so the finally release is StrictMode-safe). $pollLeaseToken
    # stays $null until/unless we acquire it; $pollLeaseKey is the resource key used for the release.
    $pollLeaseToken = $null
    $pollLeaseKey   = $null
    # N3 · poll-lease mid-drain renewal clock + threshold (env-tunable · default 40s · ~15s margin under the 55s TTL).
    $lastLeaseRenewUtc = [DateTime]::UtcNow
    $leaseRenewSeconds = 40; $lrs = 0
    if ($env:XDRLR_LEASE_RENEW_SECONDS -and [int]::TryParse($env:XDRLR_LEASE_RENEW_SECONDS, [ref]$lrs) -and $lrs -ge 0) { $leaseRenewSeconds = $lrs }

    try {
        Track-XdrEvent -Name 'Entry.Poll.Started' -Properties @{ OperationKey = $baseOperationKey; CorrelationId = $CorrelationId }

        # Indexer reads ($Entry['k']) throughout — the manifest entry mixes flat keys with NESTED
        # hashtables (TimeFilter/Pagination) and Portal/Category come from the catalog root; under
        # StrictMode -Version Latest dot-access of a missing key THROWS. Indexer returns $null safely.
        $entryPortal   = if ($Entry['Portal'])   { [string]$Entry['Portal'] }   else { 'Defender' }
        $entryCategory = [string]$Entry['Category']
        $entryMethod   = if ($Entry['Method'])   { [string]$Entry['Method'] }   else { 'GET' }

        # 0. Circuit breaker (F6) · skip the poll entirely if this Op's breaker is Open and still cooling down.
        $circuitPartition = "${entryPortal}_${entryCategory}"
        $circuitState = Get-XdrCircuitState -PartitionKey $circuitPartition -OperationKey $result.OperationKey
        if (-not (Test-XdrCircuitClosed -CircuitState $circuitState)) {
            Track-XdrEvent -Name 'Breaker.SkippedOpen' -Properties @{ OperationKey = $result.OperationKey; CorrelationId = $CorrelationId; FailureCount = $circuitState['FailureCount'] }
            $result.Success = $true       # an intentional skip is NOT a failure · do not touch the breaker
            $result.ErrorMessage = 'circuit open · poll skipped (cooldown)'
            $result.DurationMs = [int]((([DateTime]::UtcNow) - $startedUtc).TotalMilliseconds)
            return $result
        }

        # 0b. G3 · SINGLE-FLIGHT per (Portal_Category, OperationKey). The ETag-conditional checkpoint guards the
        # CHECKPOINT against a lost-update race, but NOT the INGEST: two cycles for the SAME Op that overlap (a slow
        # cycle still running when the timer fires the next) both read the same high-water, both fetch the same rows,
        # and both ingest them = DUPLICATES (the ETag only makes ONE checkpoint write win · the duplicate rows are
        # already in DCE). Serialize the whole poll body with a server-enforced lease so only ONE cycle per Op runs
        # at a time. On CONTENTION (lease held) SKIP this op THIS cycle as a SUCCESSFUL no-op — the timer fires again
        # and the in-flight cycle owns the work (no duplicate, no loss). FAIL-SAFE: if the Lease module/cmd is
        # unavailable (the single-Op v0.1.0 path may not provision it), PROCEED unlocked — never break polling.
        if (Get-Command Lock-XdrSingleFlight -ErrorAction SilentlyContinue) {
            $pollLeaseKey = "poll::${entryPortal}_${entryCategory}::$($result.OperationKey)"
            $pollLeaseToken = Lock-XdrSingleFlight -ResourceKey $pollLeaseKey -LeaseTtlSeconds 55
            if (-not $pollLeaseToken) {
                # Contended → another cycle for THIS Op is already in flight. Skip (no-op success · NOT a breaker fault).
                Track-XdrEvent -Name 'Entry.Poll.SingleFlight.Contended' -Properties @{ OperationKey = $result.OperationKey; CorrelationId = $CorrelationId }
                $pollLeaseKey = $null   # nothing to release in the finally
                $result.Success = $true
                $result.ErrorMessage = 'single-flight contended · poll skipped (another cycle owns this Op)'
                $result.DurationMs = [int]((([DateTime]::UtcNow) - $startedUtc).TotalMilliseconds)
                return $result
            }
        }

        # 1. Session
        $session = Connect-XdrPortal -Portal $entryPortal

        # 1b. Seed {TenantId} path-token from the connected session (Decision-16 / R3 tenant resolution) so
        # New-XdrRequestUrl can substitute {TenantId} in the path (e.g. MultiTenant /tenants/{TenantId}/... ops).
        # The session is the authoritative tenant id; only set when ABSENT so an explicit entry value or an
        # entity fan-out EntityParams value still wins. StrictMode-safe (hashtable indexer, never dot-access).
        if (-not $Entry['TenantId'] -and ($session -is [System.Collections.IDictionary]) -and $session['TenantId']) {
            $Entry['TenantId'] = [string]$session['TenantId']
        }

        # 2. Checkpoint + TimeWindow
        $partitionKey = "${entryPortal}_${entryCategory}"
        $checkpoint = Get-XdrCheckpoint -PartitionKey $partitionKey -OperationKey $result.OperationKey
        $window = Resolve-XdrTimeWindow -Entry $Entry -Checkpoint $checkpoint

        # ── Exactly-once setup (plan §35.2) ─────────────────────────────────────────────────────────────
        # CursorField = the ROW high-water field (manifest CursorField, else TimeFilter.FieldName — but ONLY when
        # that FieldName names a RESPONSE-ROW field). NaturalKey = the boundary-dedup key(s). hwUtc = exact
        # high-water from last cycle. priorKeys = the natural keys that were AT that exact high-water last cycle
        # (so this cycle drops the same ones · NO DCR dedup).
        # F-WINDOW-CURSOR (CORE-2 · 2026-07-07) · the TimeFilter.FieldName fallback is ONLY a valid ROW cursor for
        # Mode='ClientSideHighWater' (there FieldName IS a response-row field — e.g. GetInsights createdDate). For a
        # SERVER time-window mode (ServerFromDate/ServerOData/ServerRelative) FieldName is a QUERY-PARAM name (the
        # window bound, e.g. GetMachineTimelineEvents 'fromDate'), NOT a row field — the rows never carry it. The old
        # unconditional fallback mis-derived $cursorField='fromDate' for that WINDOW op → Select-XdrExactlyOnceRows
        # entered the CURSOR branch, found $row['fromDate']=$null on EVERY row → kept them all as the unparseable-cursor
        # fail-safe AND bypassed the cursorless SNAPSHOT-signature dedup ($snapshotSig='' when $cursorField is truthy)
        # → the whole overlapping window re-ingested every poll (the live ~4.8x WINDOW boundary dup-accumulation). Gate
        # the fallback on the ClientSideHighWater mode so a server-window op keeps $cursorField=$null and routes to the
        # correct cross-poll SNAPSHOT-signature dedup. GENERIC (mode-driven, not per-op): an explicit manifest
        # CursorField still wins unchanged (GetHistory/GetInsights untouched); only a NULL-CursorField + server-mode
        # TimeFilter is corrected. The overlapping-window re-serve is additionally eliminated at the window resolver
        # (Resolve-XdrTimeWindow · exclusive low-bound on resume) so the boundary instant is not re-fetched server-side.
        $tfEntry = $Entry['TimeFilter']
        $tfIsRowCursor = ($tfEntry -is [System.Collections.IDictionary]) -and $tfEntry['FieldName'] -and
                         ([string]$tfEntry['Mode'] -eq 'ClientSideHighWater')
        $cursorField = if ($Entry['CursorField']) { [string]$Entry['CursorField'] }
                       elseif ($tfIsRowCursor) { [string]$tfEntry['FieldName'] }
                       else { $null }
        # F-NULLKEY (2026-06-20) · A keyless op's NaturalKey=@() collapsed to $null here: `$x = if(..){..}else{@()}`
        # emits NOTHING for the empty-array else-block (PowerShell block output enumerates @() to zero items → $null).
        # That $null then arrived at Select/Frontier's [string[]] param and stringified to a one-element @($null), so
        # $keyOf indexed $row[$null] → "array index evaluated to null" (live: GetInsights once reclassified CURSOR; it
        # was DORMANT as SNAPSHOT because EO1/EO2 only call $keyOf under a CursorField). Build the array with the @()
        # OPERATOR (does not collapse) and filter null/empty components so the contract is always a clean [string[]].
        [string[]] $naturalKey = @($Entry['NaturalKey'] | Where-Object { -not [string]::IsNullOrEmpty([string]$_) })
        # F-VOLATILE-HASH (2026-06-25) · the per-op set of VOLATILE non-identity fields to STRIP from the content-hash
        # (manifest VolatileHashFields · curation-declared per OperationId). Threaded into the keyless RecordId
        # content-hash AND the cross-cycle snapshot signature so a field that changes every poll (e.g. a per-call
        # timestamp / random id / rolling history) does NOT mint a new RecordId each cycle → blocks unbounded _CL
        # dup-accumulation. ABSENT/empty (every op without a declaration) → @() → byte-identical to the pre-fix hash.
        [string[]] $volatileHashFields = @($Entry['VolatileHashFields'] | Where-Object { -not [string]::IsNullOrEmpty([string]$_) })
        # F-REQHEADERS (2026-06-25) · per-op REQUEST HEADERS (manifest RequestHeaders · curation-declared per OperationId ·
        # e.g. @{ 'api-version' = '1.0' } for the tvm/analytics backend that 400s without an api-version REQUEST header).
        # Threaded into the page-fetch Invoke-XdrAuthenticated → Invoke-XdrPortalHttp so the engine SENDS the per-route
        # header. ABSENT/empty (every op without a declaration · the same SPARSE invariant as VolatileHashFields) → @{} →
        # byte-identical to the prior fixed header set. StrictMode-safe (hashtable indexer · validate-shape before use).
        [hashtable]$reqHeaders = if ($Entry['RequestHeaders'] -is [System.Collections.IDictionary]) {
            $rh = @{}
            foreach ($rk in @($Entry['RequestHeaders'].Keys)) { if (-not [string]::IsNullOrEmpty([string]$rk)) { $rh[[string]$rk] = [string]$Entry['RequestHeaders'][$rk] } }
            $rh
        } else { @{} }
        # G2 · OPTIONAL manifest CursorPrecision · the precision at which a boundary tie is compared to the high-water.
        # ABSENT (the default for every existing manifest incl. GetHistory) → '' → exact tick match (back-compat).
        $cursorPrecision = if ($Entry['CursorPrecision']) { [string]$Entry['CursorPrecision'] } else { '' }
        $pgCfg = $Entry['Pagination']
        $stopWhenPassed = ($pgCfg -is [System.Collections.IDictionary]) -and $pgCfg['StopWhenCursorPassed']
        # G-J(b) · per-Op Pagination.LoopGuard (manifest contract field). Was IGNORED — only $script:LoopGuardMax
        # bounded the page loop. Honor the per-Op value when present (a positive int); else the module default.
        # Behavior is IDENTICAL when the manifest value equals the default (1000). The per-Op value is an EXPLICIT,
        # operator-declared HARD page cap → it still THROWS (a manifest contract · pinned by PaginationContract.Tests).
        # When it is ABSENT, U1 makes the absolute ceiling ($script:LoopGuardMax) a GRACEFUL stop instead (below):
        # the per-cycle page budget is the real governor and the module max is only an infinite-loop backstop.
        $opLoopGuardExplicit = ($pgCfg -is [System.Collections.IDictionary]) -and $null -ne $pgCfg['LoopGuard']
        $opLoopGuard = $script:LoopGuardMax
        if ($opLoopGuardExplicit) {
            $lg = 0
            if ([int]::TryParse([string]$pgCfg['LoopGuard'], [ref]$lg) -and $lg -ge 1) { $opLoopGuard = $lg } else { $opLoopGuardExplicit = $false }
        }
        # U1 (plan §16 · works at ALL volumes) · PER-CYCLE PAGE BUDGET. A huge SNAPSHOT/WINDOW drain or a cold-start
        # CURSOR backlog can exceed any single-cycle page count and MUST NOT throw (→ DLQ, never drains) NOR drop
        # un-fetched older rows. When the loop reaches this budget WITH MORE DATA AVAILABLE it stops GRACEFULLY and
        # marks the drain INCOMPLETE; the next cycle RESUMES from the persisted page/cursor (ResumePage/ResumeCursor).
        # Default 250 · well under the absolute LoopGuard (1000) so production never reaches the throw path. Fail-safe:
        # a non-positive / unparseable env value falls back to the default.
        $maxPagesPerCycle = 250
        if ($env:XDRLR_MAX_PAGES_PER_CYCLE) {
            $mpc = 0
            if ([int]::TryParse([string]$env:XDRLR_MAX_PAGES_PER_CYCLE, [ref]$mpc) -and $mpc -ge 1) { $maxPagesPerCycle = $mpc }
        }
        # G-J(a) · Pagination.TotalCountPath (manifest contract field, e.g. 'Count'). Was DEAD — no runtime layer
        # read it. The response carries the server-side TOTAL row count at this JSONPath; once the accumulated row
        # count reaches it we have drained the result set and stop paging (in ADDITION to the existing
        # rowcount<pageSize stop in Get-XdrNextCursor). Robust when the final page is exactly == pageSize: that path
        # otherwise returns a next page → an empty extra fetch; the total-count stop short-circuits it.
        $totalCountPath = if (($pgCfg -is [System.Collections.IDictionary]) -and $pgCfg['TotalCountPath']) { [string]$pgCfg['TotalCountPath'] } else { $null }
        $hwUtc = $null
        if ($window['HighWaterUtc']) { try { $hwUtc = (ConvertTo-XdrUtc $window['HighWaterUtc']) } catch { $hwUtc = $null } }  # INTENTIONAL-FAIL-SAFE: bad high-water → treat as cold (keep all)
        $priorKeys = [System.Collections.Generic.HashSet[string]]::new()
        if ($checkpoint -and $checkpoint['BoundaryKeys']) {
            foreach ($pk in ([string]$checkpoint['BoundaryKeys'] -split ',')) { if ($pk) { [void]$priorKeys.Add($pk) } }
        }
        # ── U1 RESUME STATE (plan §16 U1) ───────────────────────────────────────────────────────────────
        # Read where a PRIOR incomplete drain stopped, so THIS cycle CONTINUES the same window instead of re-paging
        # from the top. These are DISTINCT from the high-water Cursor (which Resolve-XdrTimeWindow consumes):
        #   ResumePage   · next page index to fetch (pageIndex-mode pagination)
        #   ResumeCursor · next server token to fetch (token/CursorQuery-mode pagination)
        # And the in-progress drain's PENDING high-water (NOT yet promoted to Cursor, so older un-drained rows are
        # never dropped · the window stayed stable on the un-advanced Cursor):
        #   ResumeHighWater     · running max(CursorField) over rows ingested SO FAR across this drain's cycles
        #   ResumeBoundaryKeys  · natural keys at that exact pending high-water
        # A non-empty ResumePage/ResumeCursor means a drain is IN PROGRESS (mid-resume).
        $resumePageIn   = 0
        if ($checkpoint -and $checkpoint['ResumePage']) { $rp = 0; if ([int]::TryParse([string]$checkpoint['ResumePage'], [ref]$rp) -and $rp -ge 1) { $resumePageIn = $rp } }
        $resumeCursorIn = if ($checkpoint -and $checkpoint['ResumeCursor']) { [string]$checkpoint['ResumeCursor'] } else { '' }
        $isResuming     = ($resumePageIn -ge 1) -or (-not [string]::IsNullOrEmpty($resumeCursorIn))
        $resumeHwIn     = if ($checkpoint -and $checkpoint['ResumeHighWater']) { [string]$checkpoint['ResumeHighWater'] } else { '' }
        $resumeKeysIn   = [System.Collections.Generic.HashSet[string]]::new()
        if ($checkpoint -and $checkpoint['ResumeBoundaryKeys']) {
            foreach ($pk in ([string]$checkpoint['ResumeBoundaryKeys'] -split ',')) { if ($pk) { [void]$resumeKeysIn.Add($pk) } }
        }
        # F2 (2026-06-16): the function-local $keyOf was a dead DUPLICATE of $script:XdrKeyOf (the canonical composite
        # natural-key joiner) — its sole caller (the RecordId envelope injection) now computes the key INLINE, == the
        # exactly-once dedup key. Removed (DRY · single-source). The dedup itself uses $script:XdrKeyOf, unchanged.
        $parseDt = { param($val) if (-not $val) { $null } else { try { (ConvertTo-XdrUtc $val) } catch { $null } } }

        # 3. Pagination loop · descending sort + early-stop once we page past the high-water (plan §35.2).
        # U1 · seed the loop from the RESUME position when a prior incomplete drain is in progress (else page 1 /
        # prior cursor — UNCHANGED for the normal single-cycle case). $page is the LAST fetched page; the loop does
        # $page++ first, so seed it to (ResumePage-1) to make the first fetch land on ResumePage.
        $allRows = [System.Collections.Generic.List[hashtable]]::new()
        $page = if ($resumePageIn -ge 1) { $resumePageIn - 1 } else { 0 }
        $cursor = if ($isResuming) { $resumeCursorIn }
                  elseif ($checkpoint) { $checkpoint['Cursor'] } else { $null }   # page-local server token / page index (NOT the cross-cycle high-water)
        $crossedBoundary = $false
        $totalCountReached = $false   # G-J(a) · set once accumulated rows >= server TotalCount (drained the set)
        $pagesThisCycle = 0           # U1 · pages fetched THIS cycle (independent of the resumed $page index)
        $budgetStopped = $false       # U1 · true → stopped by the per-cycle budget (or graceful absolute ceiling) WITH more data
        do {
            $page++
            $pagesThisCycle++
            # N3 · renew the single-flight poll lease BEFORE it expires mid-drain. The 55s Azure Blob Lease cannot
            # cover a long multi-page drain (page budget · slow portal · backoff); without renewal it lapses and a
            # concurrently-fired next cycle for THIS Op acquires it and DOUBLE-INGESTS. Renew every ~$leaseRenewSeconds
            # (default 40s · margin under the 55s TTL); one immediate retry rides out a transient storage blip. FAIL-LOUD
            # on genuine loss: throw (transient · NO checkpoint advance · this cycle's rows are NOT ingested) rather than
            # keep ingesting under a lost lease — next cycle resumes from the un-advanced cursor (no dup, no loss).
            if ($pollLeaseToken -and (Get-Command Renew-XdrSingleFlight -ErrorAction SilentlyContinue) -and ((([DateTime]::UtcNow) - $lastLeaseRenewUtc).TotalSeconds -ge $leaseRenewSeconds)) {
                $renewed = Renew-XdrSingleFlight -ResourceKey $pollLeaseKey -LeaseToken $pollLeaseToken
                if (-not $renewed) { $renewed = Renew-XdrSingleFlight -ResourceKey $pollLeaseKey -LeaseToken $pollLeaseToken }
                if ($renewed) {
                    $lastLeaseRenewUtc = [DateTime]::UtcNow
                    Track-XdrEvent -Name 'Entry.Poll.SingleFlight.Renewed' -Properties @{ OperationKey = $result.OperationKey; CorrelationId = $CorrelationId; Page = $page }
                } else {
                    throw (New-XdrException -Type PortalTransient -Message "single-flight poll lease lost mid-drain for $($result.OperationKey) (renew failed) · stopping to avoid duplicate ingest" -Properties @{ OperationKey = $result.OperationKey; RetryAfterSeconds = 60; ViolationType = 'N3.LeaseLost' })
                }
            }
            if ($pagesThisCycle -gt $opLoopGuard -and $opLoopGuardExplicit) {
                # G-J(b) · EXPLICIT per-Op manifest LoopGuard = an operator-declared HARD page cap → throw (pinned by
                # PaginationContract.Tests). U1 leaves this contract intact; production ops without an explicit cap take
                # the graceful budget/ceiling path instead, so this throw is a deliberate opt-in, not a data-loss risk.
                throw (New-XdrException -Type Parser -Message "loopGuard exceeded $opLoopGuard pages" -Properties @{ OperationKey = $result.OperationKey; ViolationType = 'B0.LoopGuard' })
            }
            if ($pagesThisCycle -gt $maxPagesPerCycle -or ($pagesThisCycle -gt $opLoopGuard -and -not $opLoopGuardExplicit)) {
                # U1 · GRACEFUL STOP. Hit the per-cycle page budget (or, absent an explicit per-Op cap, the absolute
                # module ceiling acting as an infinite-loop backstop) BEFORE fetching this page. The drain is INCOMPLETE
                # only if there IS more data — i.e. the prior iteration handed us a live $cursor (more pages) and we
                # haven't already hit a natural terminator. NEVER throw → next cycle resumes from $page/$cursor.
                if ($cursor -and -not $window.Exhausted -and -not $crossedBoundary -and -not $totalCountReached) { $budgetStopped = $true }
                $page--; $pagesThisCycle--   # this page was NOT fetched → $page is the last fetched page (the resume point's predecessor)
                Track-XdrEvent -Name 'Entry.Poll.CycleBudgetReached' -Properties @{ OperationKey = $baseOperationKey; CorrelationId = $CorrelationId; PagesThisCycle = $pagesThisCycle; ResumeFromPage = ($page + 1) }
                break
            }

            $url = New-XdrRequestUrl -Entry $Entry -Window $window -Cursor $cursor -Page $page
            $body = New-XdrRequestBody -Entry $Entry -Window $window -Cursor $cursor -Page $page
            # SELF-HEAL: route the page fetch through the reauth wrapper. On an AuthChainBroken (HTML-at-JSON) it
            # invalidates the dead session and reauths ONCE, then transparently returns the retried response — so an
            # in-flight cycle recovers instead of crash-looping. The pre-loop Connect-XdrPortal (above) stays for
            # early validation / breaker warm; the wrapper re-resolves the session internally.
            $response = Invoke-XdrAuthenticated -Portal $entryPortal -Method $entryMethod -Url $url -Body $body -ExtraHeaders $reqHeaders

            # B1/B1b/B3 keystones via Parser. E-BLK2 · the row's `Operation` envelope column = the BASE op key (NOT the
            # composite "<op>|<id>" checkpoint key) so a fanned child row has Operation=='<baseOpKey>' — group-by-Operation
            # works AND the op-scoped per-op verifier gate matches. The entity id lives in ParentRecordId (+ RawJson).
            $pageRows = ConvertTo-XdrRows -ResponseBody $response.Body `
                -OperationKey $baseOperationKey `
                -Portal $entryPortal `
                -Category $entryCategory `
                -Subcategory ([string]$Entry['Subcategory']) `
                -ResponseShape ($Entry['ResponseShape'] ?? 'auto') `
                -ItemsContainer ([string]$Entry['ItemsContainer']) `
                -ProjectionMap ($Entry['ProjectionMap'] ?? @{}) `
                -ColumnTypes ($Entry['ColumnTypes'] ?? @{})

            # E-MAJ3 · the page-fullness pagination decision must key on the RAW (pre-empty-gate) item count — NOT the
            # post-empty-gate $pageRows count. A page that contained dropped empty/all-null elements has fewer $pageRows
            # than items fetched; keying "is there a next page?" on $pageRows.Count would test SHORT (< PageSize) and stop
            # pagination EARLY → silent under-fetch of the older pages. The empty-gate (B1b) governs what's INGESTED, never
            # what's PAGINATED. Resolved via the SAME manifest ResponseShape+ItemsContainer the parser used (single-source).
            $rawItemCount = Get-XdrResponseItemCount -ResponseBody $response.Body -ResponseShape ($Entry['ResponseShape'] ?? 'auto') -ItemsContainer ([string]$Entry['ItemsContainer'])

            # Inject CorrelationId + F2 RecordId/ParentRecordId into every row (envelope cols the pure parser can't fill).
            foreach ($r in $pageRows) {
                if (-not $r.ContainsKey('CorrelationId') -or [string]::IsNullOrEmpty($r.CorrelationId)) {
                    $r.CorrelationId = $CorrelationId
                }
                # F2 · RecordId = the composite natural key (the NaturalKey column values joined with '|') — the SAME
                # logic the exactly-once dedup uses ($script:XdrKeyOf), so a KEYED row's identity can NEVER diverge from
                # its dedup key. Computed INLINE (not via the dead function-local $keyOf scriptblock) so it is
                # self-contained in this loop scope. KEYLESS FALLBACK (2026-06-18 · generic, all categories): keys.Count==0
                # would otherwise yield an EMPTY RecordId → no dedup identity → a SNAPSHOT's per-cycle re-emits accumulate
                # as un-dedupable dups (live-caught: SecureScore GetInsights 24,300 rows / empty RecordId). Fall back to a
                # content-hash of RawJson ($script:XdrContentHash) — honest content-identity, not a guessed semantic key.
                # ParentRecordId = this poll's fan-out parent id ('' for a top-level / non-fan-out poll).
                if (-not $r.ContainsKey('RecordId') -or [string]::IsNullOrEmpty([string]$r['RecordId'])) {
                    $r['RecordId'] = if (@($naturalKey).Count -eq 0) { & $script:XdrContentHash $r['RawJson'] $volatileHashFields } else { (@($naturalKey) | ForEach-Object { [string]$r[$_] }) -join '|' }
                }
                if (-not $r.ContainsKey('ParentRecordId')) { $r['ParentRecordId'] = $ParentRecordId }
                $allRows.Add($r)
                # Early-stop signal: descending sort means a row at/below the high-water = we've reached
                # already-ingested territory · no need to fetch older pages (plan §35.2).
                if ($stopWhenPassed -and $hwUtc -and $cursorField) {
                    $rt = & $parseDt $r[$cursorField]
                    if ($rt -and $rt -le $hwUtc) { $crossedBoundary = $true }
                }
            }

            # G-J(a) · TotalCountPath honor · stop once we've accumulated every server-reported row. Resolve the
            # total off THIS page's response (the count is page-stable for these endpoints). Fail-safe: an absent /
            # non-numeric / non-positive value leaves the flag false (fall back to the cursor/rowcount stop only).
            if ($totalCountPath) {
                $tcVal = Resolve-XdrTotalCount -Response $response.Body -Path $totalCountPath
                if ($null -ne $tcVal -and $tcVal -gt 0 -and $allRows.Count -ge $tcVal) { $totalCountReached = $true }
            }

            # E-MAJ3 · pass the RAW item count (pre-empty-gate) for the page-fullness decision (not @($pageRows).Count).
            $cursor = Get-XdrNextCursor -Response $response.Body -Entry $Entry -Page $page -PageRowCount $rawItemCount
        } while ($cursor -and -not $window.Exhausted -and -not $crossedBoundary -and -not $totalCountReached)

        # ── U1 DRAIN COMPLETENESS (plan §16 U1) ─────────────────────────────────────────────────────────
        # COMPLETE iff the loop exited NATURALLY: no more pages (cursor null) OR window Exhausted OR we crossed the
        # high-water boundary OR reached the server total-count. INCOMPLETE only when the per-cycle budget (or the
        # graceful absolute ceiling) stopped us WITH more data ($budgetStopped). On an incomplete drain we persist a
        # ResumePage/ResumeCursor so the next cycle continues, and we do NOT advance the cross-cycle high-water.
        $drainComplete = -not $budgetStopped
        # Resume position for the NEXT cycle (only meaningful when incomplete). $page is the last fetched page →
        # resume at $page+1; $cursor is the next server token (token-mode pagination · '' for pure pageIndex mode).
        $resumePageOut   = if ($budgetStopped) { $page + 1 } else { 0 }
        $resumeCursorOut = if ($budgetStopped -and $cursor -and ([string]$cursor) -notmatch '^\d+$') { [string]$cursor } else { '' }

        # ── Boundary de-dup → exactly-once (plan §35.2 · NO DCR dedup) · PURE Select-XdrExactlyOnceRows ──
        # Drop rows OLDER than the high-water; drop rows AT the exact high-water whose natural key was already
        # ingested last cycle; keep everything newer + unseen boundary ties. Cold start (no hwUtc) → keep all.
        # Unparseable/absent cursor field → kept (fail-safe · the row still carries RawJson). G2 · the boundary tie
        # is compared at $cursorPrecision (manifest CursorPrecision · default '' = exact tick match · back-compat).
        # EO2 intra-cycle dedup is applied INSIDE Select-XdrExactlyOnceRows (CURSOR-mode, the common busy-tenant
        # page-shift dup — FIXED). The remaining exactly-once edges are BOUNDED KNOWN-LIMITATIONS (audit 2026-06-12),
        # all near-zero probability on the Operations pilot (Action Center history is static / near-zero churn) and
        # all caught by the postdeploy count==dcount gate. Their correct fixes are GA hardening for high-churn
        # expansion ops (tracked · docs/runbooks/troubleshooting.md "Exactly-once known limitations"):
        #   B3/EO3 — a >250-page single multi-cycle drain WITH concurrent arrivals can re-serve a cycle-1 row across
        #            the resume boundary under descending pageIndex pagination → fix: CURSOR-based (not index) paging.
        #   S1/EO4 — TotalCountPath premature stop if mid-drain mutation changes the server Count → same paging class.
        #   EO5    — a boundary row with an INCOMPLETE NaturalKey ('' null component) can re-ingest → fix: a stable
        #            content-hash fallback key (ActionId is always present on the pilot op, so this never fires today).
        #   EO6    — a future-dated cursor (clock skew / poison) could advance the frontier past now → fix: clamp the
        #            frontier max to now()+skew (Action Center EventTime is historical, so this cannot occur on pilot).
        # F-SNAPSHOT-SIG (2026-06-19 · plan §B.3) · for a CURSORLESS SNAPSHOT, compute this cycle's signature (hash of
        # the sorted RecordId set · the RecordIds injected above) and load the committed prior signature, so the EO can
        # SKIP re-emitting an UNCHANGED snapshot (cross-cycle dup-accumulation block · live-caught GetInsights 43,200 /
        # 2,753 distinct · 16×). Cursor ops dedup via the high-water/boundary path → '' so the EO's signature skip never
        # fires for them. The new signature persists ONLY on a COMPLETE drain (gated inside Get-XdrAdvancedFrontier) so
        # a budget-stopped partial drain never commits a partial-snapshot signature (would falsely skip next cycle).
        $snapshotSig  = if (-not $cursorField) { & $script:XdrSnapshotSignature $allRows $volatileHashFields } else { '' }
        $priorSnapSig = if ((-not $cursorField) -and $checkpoint) { [string]$checkpoint['SnapshotSignature'] } else { '' }
        $ingestRows = Select-XdrExactlyOnceRows -Rows $allRows -HighWaterUtc $hwUtc -CursorField $cursorField -NaturalKey $naturalKey -PriorKeys $priorKeys -CursorPrecision $cursorPrecision -CurrentSnapshotSignature $snapshotSig -PriorSnapshotSignature $priorSnapSig
        $droppedDup = $allRows.Count - $ingestRows.Count
        if ($droppedDup -gt 0) {
            Track-XdrEvent -Name 'Entry.Poll.BoundaryDeduped' -Properties @{ OperationKey = $baseOperationKey; CorrelationId = $CorrelationId; Dropped = $droppedDup; Kept = $ingestRows.Count }
        }

        # ── High-water + boundary accumulation · U1 resume-aware (plan §35.2 + §16 U1) ──────────────────
        # The cross-cycle high-water = max(CursorField) over INGESTED rows; the boundary set = the natural keys at
        # that exact max. Nothing new ingested → preserve the prior values (no advance).
        #
        # U1 EXACTLY-ONCE ACROSS RESUME: a multi-cycle drain accumulates a PENDING high-water in the Resume* fields
        # while the committed Cursor stays put (so Resolve-XdrTimeWindow keeps the SAME window and older un-drained
        # rows are never dropped). The pending value is seeded from the prior RESUME state (when mid-drain) instead of
        # the committed Cursor — crucial under DESCENDING sort, where cycle 1 fetches the NEWEST page (the true max)
        # and later cycles fetch older pages: seeding from the running max keeps it monotonic and promotes the correct
        # final high-water on completion. On COMPLETE drain the pending value is promoted to Cursor and the Resume*
        # fields are cleared; on INCOMPLETE drain Cursor/BoundaryKeys are left untouched.
        #
        # The accumulation BASELINE is the prior PENDING high-water when resuming, else the committed high-water; the
        # baseline boundary keys are the prior PENDING set when resuming, else the prior committed set. The PURE
        # Get-XdrAdvancedFrontier computes the running max + boundary set and maps it to the persisted frontier.
        $accumHwStr = if ($isResuming) { $resumeHwIn } elseif ($checkpoint -and $checkpoint['Cursor']) { [string]$checkpoint['Cursor'] } else { '' }
        $accumKeys  = if ($isResuming) { $resumeKeysIn } else { $priorKeys }
        $frontier = Get-XdrAdvancedFrontier `
            -Baseline $accumHwStr `
            -IngestRows $ingestRows `
            -DrainComplete $drainComplete `
            -CursorField $cursorField `
            -NaturalKey $naturalKey `
            -AccumKeys $accumKeys `
            -HasCheckpoint ([bool]$checkpoint) `
            -CommittedCursor $(if ($checkpoint) { $checkpoint['Cursor'] } else { $null }) `
            -CommittedBoundaryKeys $(if ($checkpoint) { [string]$checkpoint['BoundaryKeys'] } else { '' }) `
            -PageCursor $cursor `
            -CurrentSnapshotSignature $snapshotSig `
            -CommittedSnapshotSignature $priorSnapSig
        $nextCursor       = $frontier['NextCursor']
        $nextBoundaryKeys = $frontier['NextBoundaryKeys']
        $nextSnapshotSig  = $frontier['NextSnapshotSignature']
        $resumeHwOut      = $frontier['ResumeHighWater']
        $resumeKeysOut    = $frontier['ResumeBoundaryKeys']

        # V3 (§21.1): normalize the INGEST/SEND order to ASCENDING-by-cursor so the contiguous-landed prefix (the
        # leading run of fully-2xx chunks, in send order · Send-ToDce.LandedContiguousRows) is always the OLDEST rows.
        # This makes the G1 partial-landed-prefix advance VALID for DESCENDING-sorted responses too (GetHistory is
        # SortOrder=Descending): the landed prefix is then the lowest-cursor rows and the un-landed remainder is
        # strictly newer, so advancing the committed high-water over the prefix can never drop the remainder. The
        # cross-cycle frontier above (Get-XdrAdvancedFrontier) is order-independent (max over rows) and DCE ingestion is
        # order-independent (LA is a table), so this ONLY changes which rows form the landed prefix. Unparseable-cursor
        # rows sort LAST so they stay in the remainder (Select-XdrExactlyOnceRows re-keeps them next cycle · fail-safe).
        if ($cursorField -and @($ingestRows).Count -gt 1) {
            $ingestRows = @($ingestRows | Sort-Object -Property @{ Expression = { $d = & $script:XdrParseDt $_[$cursorField]; if ($d) { $d } else { [DateTime]::MaxValue } } })
        }

        # 4. Ingest the DE-DUPED set (exactly-once · never the raw $allRows)
        $landedContiguous = 0
        if ($ingestRows.Count -gt 0) {
            $dceEndpoint = $env:XDRLR_DCE_ENDPOINT
            # E-MAJ5 · pass the op's REAL Portal_Category ($partitionKey · the SAME value the checkpoint uses) so a DLQ row
            # partitions identically — the stream-name strip mismatches a spaced category (e.g. 'Cloud Apps').
            $ingestResult = Send-ToDce -DceEndpoint $dceEndpoint -DcrId $Entry['DcrImmutableId'] -StreamName $Entry['DcrStreamName'] -Rows $ingestRows -PartitionKey $partitionKey
            $result.ItemCount     = $ingestResult.RowsAccepted
            $result.BytesIngested = $ingestResult['BytesIngested'] ?? 0
            $landedContiguous     = [int]($ingestResult['LandedContiguousRows'] ?? 0)
            if (-not $ingestResult.Success) {
                $result.ErrorClass   = $ingestResult.ErrorClass
                $result.ErrorMessage = $ingestResult.ErrorMessage
                # Ingest DLQ already invoked by Send-ToDce on terminal failure — the un-landed remainder is in the DLQ.
            }
        }

        # ── G1 · partial multi-chunk ingest · advance over the CONTIGUOUS LANDED PREFIX (exactly-once) ──────────
        # Today a partial failure (some chunks 2xx, a later chunk DLQ'd) set ErrorClass → NO checkpoint save → next
        # cycle re-polled the OLD high-water and RE-INGESTED the already-landed chunks = duplicates. FIX: when a
        # CONTIGUOUS prefix of rows provably landed (Send-ToDce.LandedContiguousRows · send order = $ingestRows order)
        # and the drain otherwise completed, advance the committed high-water over JUST that landed prefix — but ONLY
        # when the un-landed remainder is STRICTLY ABOVE the new high-water (so re-polling next cycle re-fetches the
        # remainder, never drops it · the task's invariant). When that guard does NOT hold (e.g. a DESCENDING-sorted
        # batch where the landed prefix is the NEWER rows and the remainder is OLDER), we do NOT advance — today's
        # safe behavior — and the un-landed rows are recovered from the DLQ instead (no silent loss either way).
        $partialAdvance = $false
        if ($result.ErrorClass -and $drainComplete -and $cursorField -and $landedContiguous -ge 1 -and $landedContiguous -lt $ingestRows.Count) {
            $landedRows    = [System.Collections.Generic.List[hashtable]]::new()
            $remainderRows = [System.Collections.Generic.List[hashtable]]::new()
            for ($li = 0; $li -lt $ingestRows.Count; $li++) { if ($li -lt $landedContiguous) { $landedRows.Add($ingestRows[$li]) } else { $remainderRows.Add($ingestRows[$li]) } }
            # prefixMax = max(cursor) over the landed prefix · remainderMin = min(cursor) over the un-landed remainder.
            $prefixMax = $null
            foreach ($lr in $landedRows) { $dt = & $parseDt $lr[$cursorField]; if ($dt -and ($null -eq $prefixMax -or $dt -gt $prefixMax)) { $prefixMax = $dt } }
            $remainderMin = $null
            foreach ($rr in $remainderRows) { $dt = & $parseDt $rr[$cursorField]; if ($dt -and ($null -eq $remainderMin -or $dt -lt $remainderMin)) { $remainderMin = $dt } }
            # Guard: the remainder must sit strictly ABOVE the prefix high-water (else advancing would drop it). A
            # remainder row with no parseable cursor is kept by Select-XdrExactlyOnceRows next cycle regardless (safe).
            if ($prefixMax -and ($null -eq $remainderMin -or $remainderMin -gt $prefixMax)) {
                $g1 = Get-XdrAdvancedFrontier `
                    -Baseline $accumHwStr -IngestRows $landedRows -DrainComplete $true `
                    -CursorField $cursorField -NaturalKey $naturalKey -AccumKeys $accumKeys `
                    -HasCheckpoint ([bool]$checkpoint) `
                    -CommittedCursor $(if ($checkpoint) { $checkpoint['Cursor'] } else { $null }) `
                    -CommittedBoundaryKeys $(if ($checkpoint) { [string]$checkpoint['BoundaryKeys'] } else { '' }) `
                    -PageCursor $cursor
                $nextCursor       = $g1['NextCursor']
                $nextBoundaryKeys = $g1['NextBoundaryKeys']
                $resumeHwOut      = $g1['ResumeHighWater']
                $resumeKeysOut    = $g1['ResumeBoundaryKeys']
                $partialAdvance   = $true
                Track-XdrEvent -Name 'Entry.Poll.PartialLandedPrefixAdvance' -Properties @{ OperationKey = $baseOperationKey; CorrelationId = $CorrelationId; Landed = $landedContiguous; Remainder = $remainderRows.Count }
            }
        }

        # 5. Atomic checkpoint advance (only on full ingest success OR empty no-op after dedup · OR a G1 partial-landed
        # prefix advance). U1: this ALSO persists the resume position (ResumePage/ResumeCursor) + pending high-water
        # (ResumeHighWater/ResumeBoundaryKeys) when the drain was INCOMPLETE — so the next cycle continues. On a
        # complete drain those are written empty (cleared). On a NON-advancing ingest FAILURE → no save → resume state
        # untouched → next cycle re-pages from the top (nothing committed = nothing to drop · DLQ holds the failures).
        $advanceCursor = ($result.ItemCount -gt 0 -and -not $result.ErrorClass) -or ($ingestRows.Count -eq 0) -or $partialAdvance
        if ($advanceCursor) {
            $saved = Save-XdrCheckpointAtomic `
                -PartitionKey $partitionKey `
                -OperationKey $result.OperationKey `
                -Cursor $nextCursor `
                -BoundaryKeys $nextBoundaryKeys `
                -SnapshotSignature $nextSnapshotSig `
                -ResumePage $resumePageOut `
                -ResumeCursor $resumeCursorOut `
                -ResumeHighWater $resumeHwOut `
                -ResumeBoundaryKeys $resumeKeysOut `
                -Window $window `
                -ItemCount $result.ItemCount `
                -CorrelationId $CorrelationId `
                -ResetUtc ([string]$(if ($checkpoint) { $checkpoint['ResetUtc'] } else { '' })) `
                -ResetReasonAnnotation ([string]$(if ($checkpoint) { $checkpoint['ResetReasonAnnotation'] } else { '' })) `
                -ExistingETag $(if ($checkpoint) { $checkpoint['ETag'] } else { $null })
            if (-not $saved) {
                # Atomic advance lost the race — leave cursor untouched so the next cycle re-reads from the
                # same high-water. Safe: exactly-once is reconstructed next cycle from the persisted boundary set.
                Track-XdrEvent -Name 'Checkpoint.Advance.RaceLost' -Properties @{
                    OperationKey = $result.OperationKey
                    CorrelationId = $CorrelationId
                }
            }
        }

        $result.Success = $true
        # E-BLK2 · poll-outcome telemetry carries the BASE op key (a fanned child's Entry.Poll.Succeeded must NOT
        # surface the composite "<op>|<id>" — the verifier op-scopes its per-op gate by this OperationKey). The
        # composite identity lives on the per-entity checkpoint/breaker RowKey, not the poll telemetry.
        Track-XdrEvent -Name 'Entry.Poll.Succeeded' -Properties @{
            OperationKey = $baseOperationKey
            CorrelationId = $CorrelationId
            Pages = $pagesThisCycle
            ItemCount = $result.ItemCount
            DrainComplete = $drainComplete   # U1 · $false → an incomplete drain · the next cycle resumes from ResumePage/ResumeCursor
        }
    } catch {
        $ex = $_.Exception
        # ── 3-WAY ERROR CLASSIFICATION (plan §6 · capability-as-telemetry) ──────────────────────────────────────
        # CAPABILITY/DATA ABSENT (403/404 on a read-only op) = the tenant cannot serve this op (no product / no MTO /
        # no data). This is NOT a bug and NOT a crash — per the operator it must be RECORDED AS POSTURE, never a
        # silent skip and never an AppException flood. Treat it as a clean no-op (Success stays $true · ErrorClass
        # stays $null → no DLQ, no breaker trip) AND advance the cadence: the error path below SKIPS the checkpoint
        # write, so LastUpdatedUtc never moves and the op is re-polled EVERY cycle (the live 8-op 400/404/403 flood).
        # 400/401/405 (real contract/auth errors) → terminal path (DLQ + loud). 5xx/429 → transient (already retried).
        # LICENSE-GATE EXCEPTION (operator-locked 2026-06-10 · license-independence §3 · evidence: openapi multi_tenant.yml):
        # a 400 whose body is "InvalidProxyPrefix" = the apiproxy router refusing a DOCUMENTED upstream prefix this tenant
        # cannot route (e.g. /mtoapi/* Multi-Tenant-Org ops on a non-MTO tenant) = capability-absent → POSTURE like 403/404.
        # The prior "InvalidProxyPrefix = contract bug" premise was FALSIFIED (the mtoapi cataloguing is verified correct).
        # Response-driven + GENERIC (no per-op list): ANY OTHER 400 body (real contract error) stays LOUD/breaker-bounded —
        # zero-masking holds: posture is never silent (Capability.OpUnavailable telemetry fires every occurrence).
        if (Test-XdrIsCapabilityAbsent -Exception $ex) {
            $result.Success = $true
            $result.ItemCount = 0
            # E-BLK2 · capability posture telemetry carries the BASE op key (the verifier op-scopes by it). The
            # checkpoint cadence-touch below KEEPS the composite $result.OperationKey (per-entity RowKey).
            Track-XdrEvent -Name 'Capability.OpUnavailable' -Properties @{
                OperationKey = $baseOperationKey; CorrelationId = $CorrelationId
                StatusCode = $ex.StatusCode; Portal = $entryPortal; Category = $entryCategory
            }
            Write-Host "[Capability.OpUnavailable] Op=$baseOperationKey HTTP=$($ex.StatusCode) · tenant cannot serve this op · posture recorded · backing off to cadence"
            # Advance the cadence clock: re-persist the EXISTING high-water unchanged (Save writes a fresh
            # LastUpdatedUtc) so the op backs off to its cadence instead of re-polling every cycle. Best-effort —
            # a write error must not fault the cycle (the cadence gate just re-evaluates next cycle).
            try {
                # WS3.1 · the cadence-touch must PRESERVE the full checkpoint, not just Cursor/BoundaryKeys:
                # Save-XdrCheckpointAtomic writes ALL properties every save, so omitting the Resume* params here wrote
                # their defaults (0/''/''/'') and WIPED an in-progress multi-cycle drain's resume position + pending
                # high-water whenever a capability-absent posture landed mid-drain. Pass the existing values through.
                $cpResumePage = 0; if ($checkpoint['ResumePage']) { $rpT = 0; if ([int]::TryParse([string]$checkpoint['ResumePage'], [ref]$rpT)) { $cpResumePage = $rpT } }
                $null = Save-XdrCheckpointAtomic -PartitionKey $partitionKey -OperationKey $result.OperationKey `
                    -Cursor ([string]$checkpoint['Cursor']) -BoundaryKeys ([string]$checkpoint['BoundaryKeys']) `
                    -SnapshotSignature ([string]$checkpoint['SnapshotSignature']) `
                    -ResumePage $cpResumePage `
                    -ResumeCursor ([string]$checkpoint['ResumeCursor']) `
                    -ResumeHighWater ([string]$checkpoint['ResumeHighWater']) `
                    -ResumeBoundaryKeys ([string]$checkpoint['ResumeBoundaryKeys']) `
                    -ResetUtc ([string]$checkpoint['ResetUtc']) -ResetReasonAnnotation ([string]$checkpoint['ResetReasonAnnotation']) `
                    -ItemCount 0 -CorrelationId $CorrelationId -ExistingETag ([string]$checkpoint['ETag'])
            } catch { Write-Warning "[Runtime] capability-absent cadence touch failed (non-fatal): $($_.Exception.Message)" }
        } else {
            $result.Success      = $false
            $result.ErrorClass   = Get-XdrErrorClass -Exception $_.Exception
            $result.ErrorMessage = $_.Exception.Message
            # §Φ-F.2 (plan RawResponseBody) · surface the portal StatusCode + ResponseBody carried on the typed portal
            # exceptions so a contract error (e.g. HTTP 400 {"Error":"InvalidProxyPrefix"}) is root-caused from
            # Entry.Poll.Failed ITSELF, not by digging AppTraces. StrictMode-safe: read each field only on the type
            # that declares it (Terminal carries StatusCode+ResponseBody · Transient carries StatusCode only).
            $exTypeName = $ex.GetType().Name
            $exSc = ''; $exBody = ''
            if ($exTypeName -eq 'XdrPortalTerminalException')      { $exSc = [string]$ex.StatusCode; $exBody = [string]$ex.ResponseBody }
            elseif ($exTypeName -eq 'XdrPortalTransientException') { $exSc = [string]$ex.StatusCode }
            # A-OBSERVABILITY (§30): workspace-mode AI DROPS Track-XdrException (/v2/track), so the exception
            # message + failing call-site are invisible in AppTraces — leaving Entry.Poll.Failed with only an
            # ErrorClass. Mirror the full detail (message + the script position + condensed stack) to host so a
            # live poll failure is root-caused from AppTraces WITHOUT a redeploy. No secrets (Op key + frames only).
            $posMsg = if ($_.InvocationInfo) { ($_.InvocationInfo.PositionMessage -replace '\r?\n', ' ') } else { '' }
            $stack  = ([string]$_.ScriptStackTrace -replace '\r?\n', ' | ')
            # E-BLK2 · failure telemetry carries the BASE op key (a fanned child's Entry.Poll.Failed must surface the
            # base op, not the composite "<op>|<id>", so the verifier's op-scoped gate sees it).
            Write-Host "[Entry.Poll.Exception] Op=$baseOperationKey Class=$($result.ErrorClass) HTTP=$exSc Msg=$($_.Exception.Message) | Body=$exBody | Pos=$posMsg | Stack=$stack"
            Track-XdrException -Exception $_.Exception -Properties @{ OperationKey = $baseOperationKey; CorrelationId = $CorrelationId; StatusCode = $exSc; ResponseBody = $exBody }
            Track-XdrEvent -Name 'Entry.Poll.Failed' -Properties @{
                OperationKey = $baseOperationKey
                CorrelationId = $CorrelationId
                ErrorClass = $result.ErrorClass
                ErrorMessage = $result.ErrorMessage
                StatusCode = $exSc
                ResponseBody = $exBody
            }
            # NO defensive back-off on a genuine terminal error. The deleted "no-flood-on-terminal" cadence-touch was
            # MASKING: it advanced LastUpdatedUtc so a broken op looked like calm cadence AND spaced its failures so the
            # breaker rarely saw the consecutive failures that OPEN it. Proactive instead: Success=$false (above) →
            # the breaker (Update-XdrCircuitState, post-finally) increments and OPENS after its threshold → a LOUD,
            # observable OpenCircuits back-off. The cursor is NEVER advanced on failure (no data skip). A genuinely
            # broken op is fixed at the SOURCE (correct path · dispatch-time capability gate · scope exclusion), never
            # silently throttled here. (Plan §E · ZERO defensive masking · fail-loud + observable only.)
        }
    } finally {
        # G3 · ALWAYS release the single-flight lease we acquired (success, failure, OR an early return inside the
        # try — the finally runs in all paths). $pollLeaseKey is $null when we never acquired (breaker/contended
        # skips), so this is a no-op there. Release is best-effort: a release error must not fault the cycle (the
        # lease TTL would expire it anyway).
        if ($pollLeaseToken -and $pollLeaseKey -and (Get-Command Unlock-XdrSingleFlight -ErrorAction SilentlyContinue)) {
            try { $null = Unlock-XdrSingleFlight -ResourceKey $pollLeaseKey -LeaseToken $pollLeaseToken }
            catch { Write-Warning "[Runtime] single-flight release failed (non-fatal · TTL will expire): $($_.Exception.Message)" }
        }
    }

    # Update the breaker from this cycle's outcome (success → close/reset · failure → increment, may Open).
    if ($circuitPartition) {
        try {
            Update-XdrCircuitState -PartitionKey $circuitPartition -OperationKey $result.OperationKey -Success ([bool]($result.Success -and -not $result.ErrorClass)) -CircuitState $circuitState -CorrelationId $CorrelationId
        } catch {
            Write-Warning "[Runtime] breaker update failed: $($_.Exception.Message)"  # INTENTIONAL-FAIL-SAFE: breaker is best-effort · a state-store write error must not fail the cycle
        }
    }
    $result.DurationMs = [int]((([DateTime]::UtcNow) - $startedUtc).TotalMilliseconds)
    return $result
}

# ════════════════════════════════════════════════════════════════════════════════════════════════════════════════
# ─── ENTITY FAN-OUT (plan §16 U3b · §4.H entity edges · G-P) · parent→child · BOUNDED · per-entity exactly-once ───
# ════════════════════════════════════════════════════════════════════════════════════════════════════════════════
# An entity op (catalogue DependsOn edge · path {param} like {CaseId}/{DeviceId}/{MachineId}) is not directly pollable
# — its URL needs a concrete id. Invoke-XdrEntityFanout makes it pollable WITHOUT ever exploding the cycle:
#   (a) RESOLVE the parent's entity ids from a BOUNDED, TTL'd module cache (fed from the parent op's recently-ingested
#       rows · the EntityIdField the Depend stage chose), else SKIP gracefully (warn) — never a 10k-entity blowup.
#   (b) For EACH id, up to a CAP (XDRLR_MAX_ENTITIES_PER_CYCLE · default 50 · MOST-OVERDUE-FIRST), substitute {param}→id
#       (via the child entry's EntityParams · New-XdrRequestUrl) and poll the child through the EXISTING Invoke-XdrEntryPoll.
#   (c) Each child poll checkpoints under a COMPOSITE OperationKey "<OperationKey>|<entityId>" → per-entity high-water +
#       boundary set are INDEPENDENT → per-entity EXACTLY-ONCE holds by construction (it reuses the proven §35.2 logic).
# NEVER-REFUSE/DEGRADE (U4): no DependsOn · EntityResolution≠'Resolved' · empty cache · a parent-poll error → the op is
# SKIPPED this cycle with a warning + telemetry; the cycle continues. RawJson floor still applies to whatever DOES poll.
# GetHistory (no entity {param}) NEVER reaches this path — the dispatcher routes it to the normal Invoke-XdrEntryPoll.

# Module-scoped BOUNDED entity cache (per-runspace · same lifetime model as the manifest cache). Key:
# "<Portal>_<Category>_<ParentOperationKey>" → @{ Ids = [System.Collections.Generic.List[string]]; CachedUtc = <utc> }.
# TTL'd (XDRLR_ENTITY_CACHE_TTL_MINUTES · default 30) and HARD-capped (XDRLR_ENTITY_CACHE_MAX · default 10000) so a
# pathological parent (10k+ ids) can NEVER grow the cache without bound — the most-recent ids win up to the ceiling.
$script:XdrEntityCache = @{}

# E-MAJ2 · last-seed-poll outcome signal (per-runspace). Get-XdrParentEntityIds returns a PLAIN [string[]] (its
# callers re-collect with @() · the contract can't carry a status without breaking them), so a THROWN-and-caught seed
# poll (real parent-feed failure) and a benign 0-id result BOTH return @() — indistinguishable. This script-scoped
# flag lets Invoke-XdrEntityFanout tell them apart: the seed poll sets ThrewError on a caught throw (carrying the
# ErrorMessage) and clears it on a successful poll. The fan-out reads it ONLY for the call it just made, so a
# real parent-feed failure surfaces a DISTINCT non-success (breaker-actionable) instead of a benign graceful skip.
$script:XdrLastParentPollFailure = @{ ThrewError = $false; ErrorMessage = '' }

function Get-XdrEntityCacheTtlMinutes {
    $ttl = 30
    if ($env:XDRLR_ENTITY_CACHE_TTL_MINUTES) { $v = 0; if ([int]::TryParse([string]$env:XDRLR_ENTITY_CACHE_TTL_MINUTES, [ref]$v) -and $v -ge 1) { $ttl = $v } }
    return $ttl
}
function Get-XdrEntityCacheMax {
    $max = 10000
    if ($env:XDRLR_ENTITY_CACHE_MAX) { $v = 0; if ([int]::TryParse([string]$env:XDRLR_ENTITY_CACHE_MAX, [ref]$v) -and $v -ge 1) { $max = $v } }
    return $max
}

function Add-XdrEntityIds {
    <#
    .SYNOPSIS
    Feed entity ids into the bounded cache for a (Portal,Category,ParentOperationKey). Called by the dispatcher (or a
    parent poll) with the parent op's recently-ingested rows' id values. De-duplicates, preserves insertion order,
    refreshes CachedUtc, and HARD-caps the stored set at the ceiling (oldest entries evicted first). NEVER throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Portal,
        [Parameter(Mandatory)] [string] $Category,
        [Parameter(Mandatory)] [string] $ParentOperationKey,
        [Parameter()] [AllowNull()] [AllowEmptyCollection()] [string[]] $Ids
    )
    try {
        $key = "${Portal}_${Category}_${ParentOperationKey}"
        if (-not $script:XdrEntityCache.ContainsKey($key)) {
            $script:XdrEntityCache[$key] = @{ Ids = [System.Collections.Generic.List[string]]::new(); CachedUtc = [DateTime]::UtcNow }
        }
        $entry = $script:XdrEntityCache[$key]
        $list = $entry['Ids']
        $seen = [System.Collections.Generic.HashSet[string]]::new([string[]]@($list))
        foreach ($id in @($Ids)) {
            if ($null -eq $id) { continue }
            $s = [string]$id
            if ([string]::IsNullOrEmpty($s)) { continue }
            if ($seen.Add($s)) { [void]$list.Add($s) }
        }
        # HARD cap · evict the OLDEST (front of the list) so the newest ids are retained — bounded forever.
        $max = Get-XdrEntityCacheMax
        while ($list.Count -gt $max) { $list.RemoveAt(0) }
        $entry['CachedUtc'] = [DateTime]::UtcNow
    } catch {
        Write-Warning "[Runtime] Add-XdrEntityIds failed (non-fatal): $($_.Exception.Message)"   # INTENTIONAL-FAIL-SAFE
    }
}

function Clear-XdrEntityCache {
    <#
    .SYNOPSIS
    Clear the module's bounded entity cache — ALL entries, or only those for a (Portal,Category,ParentOperationKey)
    when -ParentOperationKey is given. Operational/diagnostic primitive (force a re-feed) · NEVER throws.
    #>
    [CmdletBinding()]
    param([string] $Portal = '', [string] $Category = '', [string] $ParentOperationKey = '')
    try {
        if ($ParentOperationKey) {
            $key = "${Portal}_${Category}_${ParentOperationKey}"
            if ($script:XdrEntityCache.ContainsKey($key)) { [void]$script:XdrEntityCache.Remove($key) }
        } else {
            $script:XdrEntityCache = @{}
        }
    } catch {
        Write-Warning "[Runtime] Clear-XdrEntityCache failed (non-fatal): $($_.Exception.Message)"   # INTENTIONAL-FAIL-SAFE
    }
}

function Get-XdrCachedEntityIds {
    <#
    .SYNOPSIS
    Read the (still-fresh) cached entity ids for a (Portal,Category,ParentOperationKey). Returns @() on miss / expiry /
    error (NEVER $null · NEVER throws) so the caller's @().Count is StrictMode-safe and an empty cache = graceful skip.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [string] $Portal,
        [Parameter(Mandatory)] [string] $Category,
        [Parameter(Mandatory)] [string] $ParentOperationKey
    )
    try {
        $key = "${Portal}_${Category}_${ParentOperationKey}"
        if (-not $script:XdrEntityCache.ContainsKey($key)) { return @() }
        $entry = $script:XdrEntityCache[$key]
        $cachedUtc = $entry['CachedUtc']
        if ($cachedUtc -isnot [DateTime]) { return @() }
        if (([DateTime]::UtcNow - $cachedUtc).TotalMinutes -ge (Get-XdrEntityCacheTtlMinutes)) { return @() }   # expired → treat as empty (re-feed needed)
        # Return a PLAIN [string[]] (NO comma-protection · callers consistently re-collect with @()). A `,$arr` return
        # would nest the array (the caller's @() then sees one element = the inner array · the live count=1 trap).
        return [string[]]@($entry['Ids'])
    } catch {
        Write-Warning "[Runtime] Get-XdrCachedEntityIds failed (non-fatal): $($_.Exception.Message)"   # INTENTIONAL-FAIL-SAFE
        return @()
    }
}

function Get-XdrEntityIdField {
    <#
    .SYNOPSIS
    Pull the parent's id values out of a set of recently-ingested parent rows for the EntityIdField the Depend stage
    chose (DependsOn.EntityIdField). StrictMode-safe (indexer reads · a row may not carry the field) · de-duped ·
    order-preserving · NEVER throws. Returns @() when no rows / no field / nothing matched.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter()] [AllowNull()] [AllowEmptyCollection()] [object[]] $Rows,
        [Parameter(Mandatory)] [string] $EntityIdField
    )
    $out = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Rows -or @($Rows).Count -eq 0 -or [string]::IsNullOrEmpty($EntityIdField)) { return [string[]]@() }
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($row in $Rows) {
        try {
            $val = $null
            if ($row -is [System.Collections.IDictionary]) { if ($row.Contains($EntityIdField)) { $val = $row[$EntityIdField] } }
            elseif ($null -ne $row -and $row.PSObject -and ($row.PSObject.Properties.Name -contains $EntityIdField)) { $val = $row.$EntityIdField }
            if ($null -ne $val) { $s = [string]$val; if (-not [string]::IsNullOrEmpty($s) -and $seen.Add($s)) { [void]$out.Add($s) } }
        } catch { continue }   # INTENTIONAL-FAIL-SAFE: a bad row never aborts the harvest
    }
    # PLAIN [string[]] return (NO comma-protection · the caller re-collects with @() · a `,` would nest it).
    return [string[]]@($out)
}

function Get-XdrParentEntityIds {
    <#
    .SYNOPSIS
    LIGHTWEIGHT parent poll (plan §16 U3b · cache-population fallback) · fetch ONE bounded page of a PARENT op and
    harvest its EntityIdField values. Used by Invoke-XdrEntityFanout ONLY when the persisted cache is empty and a
    parent manifest entry is supplied, so the fan-out is self-sufficient (does not depend on a same-cycle parent
    activity feeding rows). NEVER ingests (the parent op ingests on its OWN activity · here we only READ ids) and
    NEVER throws — any error returns @() → the fan-out then skips gracefully. Page 1 only (the id set is bounded for
    cache seeding · the Add-XdrEntityIds ceiling caps it regardless).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [hashtable] $ParentEntry,
        [Parameter(Mandatory)] [string] $EntityIdField,
        [string] $CorrelationId = ''
    )
    # E-MAJ2 · clear the seed-poll failure signal up front; the catch sets it on a real (thrown) parent-feed failure so
    # Invoke-XdrEntityFanout can distinguish that from a benign 0-id harvest (and NOT mask repeated failure from the breaker).
    $script:XdrLastParentPollFailure = @{ ThrewError = $false; ErrorMessage = '' }
    try {
        $ParentEntry = ConvertTo-XdrDeepHashtable -InputObject $ParentEntry
        $portal   = if ($ParentEntry['Portal'])   { [string]$ParentEntry['Portal'] }   else { 'Defender' }
        $category = [string]$ParentEntry['Category']
        $method   = if ($ParentEntry['Method'])   { [string]$ParentEntry['Method'] }   else { 'GET' }
        # V-MAJ6 (2026-06-19) · the harvest HTTP routes through Invoke-XdrAuthenticated below — it Connect-XdrPortals AND
        # self-heals a 401/440 (AuthChainBroken → invalidate L1 → KMSI re-mint → retry · the SAME path Invoke-XdrEntryPoll
        # uses). The prior direct Invoke-XdrPortalHttp had NO self-heal, so a session that lapsed before a cache-reseed
        # surfaced HTTP 440 → Entry.Fanout.ParentPollFailed with NO recovery (live 2026-06-19: ListPostureOversightInitiatives
        # 12× while normal polls stayed healthy). Generic: every fanout seed poll now recovers a reactive auth-loss.
        # E-BLK1 · shape a REAL cold window from the parent's own IngestionMode/TimeFilter/LookbackHours (cold checkpoint =
        # empty hashtable → first-cycle bounds). A SNAPSHOT parent → StartUtc=$null (no server time filter · byte-identical
        # to the prior hardcoded empty window, e.g. Exposure's SNAPSHOT parent). A CURSOR/WINDOW/ServerFromDate parent →
        # a bounded lookback window so the seed poll's FIRST page carries the correct server time predicate instead of an
        # unbounded/absent one. Fail-safe: a mis-shaped/throwing resolve falls back to the empty window (never blocks the
        # harvest). The harvest stays PAGE-1-ONLY (id-set seeding · the Add-XdrEntityIds ceiling bounds it regardless).
        $window = @{ StartUtc = $null; EndUtc = $null; Exhausted = $false; HighWaterUtc = $null }
        try { $window = Resolve-XdrTimeWindow -Entry $ParentEntry -Checkpoint @{} } catch { Write-Warning "[Runtime] Get-XdrParentEntityIds window resolve failed (non-fatal · empty window): $($_.Exception.Message)" }
        $url  = New-XdrRequestUrl  -Entry $ParentEntry -Window $window -Cursor $null -Page 1
        $body = New-XdrRequestBody -Entry $ParentEntry -Window $window -Cursor $null -Page 1
        # F-REQHEADERS · the parent op may itself require a per-op REQUEST HEADER (e.g. a tvm/analytics parent that 400s
        # without api-version). Read it from the ParentEntry (same SPARSE shape as the poll path) so the seed read sends
        # it too — else a header-requiring parent's id-harvest would 400 and the fan-out would starve. Empty ⇒ unchanged.
        [hashtable]$parentReqHeaders = if ($ParentEntry['RequestHeaders'] -is [System.Collections.IDictionary]) {
            $prh = @{}
            foreach ($prk in @($ParentEntry['RequestHeaders'].Keys)) { if (-not [string]::IsNullOrEmpty([string]$prk)) { $prh[[string]$prk] = [string]$ParentEntry['RequestHeaders'][$prk] } }
            $prh
        } else { @{} }
        $response = Invoke-XdrAuthenticated -Portal $portal -Method $method -Url $url -Body $body -ExtraHeaders $parentReqHeaders
        $rows = ConvertTo-XdrRows -ResponseBody $response.Body `
            -OperationKey ([string]$ParentEntry['OperationKey']) -Portal $portal -Category $category `
            -Subcategory ([string]$ParentEntry['Subcategory']) -ResponseShape ($ParentEntry['ResponseShape'] ?? 'auto') `
            -ItemsContainer ([string]$ParentEntry['ItemsContainer']) -ProjectionMap ($ParentEntry['ProjectionMap'] ?? @{})
        # PLAIN array return (caller re-collects with @()). ConvertTo-XdrRows returns `,$list` so @($rows) flattens it.
        return [string[]]@(Get-XdrEntityIdField -Rows @($rows) -EntityIdField $EntityIdField)
    } catch {
        # E-MAJ2 · a THROWN seed poll is a REAL parent-feed failure (NOT a benign empty result). Signal it so the
        # fan-out surfaces a distinct non-success (ErrorClass + breaker-actionable), instead of the graceful skip it
        # uses for a legitimate 0-id parent. Still NEVER throws here (the contract: return @() · the fan-out decides).
        $script:XdrLastParentPollFailure = @{ ThrewError = $true; ErrorMessage = [string]$_.Exception.Message }
        Write-Warning "[Runtime] Get-XdrParentEntityIds parent poll failed (non-fatal · fan-out will surface ErrorClass): $($_.Exception.Message)"   # INTENTIONAL-FAIL-SAFE
        if (Get-Command Track-XdrEvent -ErrorAction SilentlyContinue) {
            Track-XdrEvent -Name 'Entry.Fanout.ParentPollFailed' -Properties @{ OperationKey = [string]$ParentEntry['OperationKey']; CorrelationId = $CorrelationId; ErrorMessage = $_.Exception.Message }
        }
        return @()
    }
}

function Invoke-XdrEntityFanout {
    <#
    .SYNOPSIS
    Fan an ENTITY op (catalogue DependsOn edge) out across its parent's cached entity ids and poll each child via the
    EXISTING Invoke-XdrEntryPoll under a COMPOSITE checkpoint key. BOUNDED · per-entity exactly-once · NEVER throws.

    .PARAMETER Entry
    The entity manifest entry · MUST carry a DependsOn block (@{ ParentOperationKey; EntityIdField; ParamName; ... }) and
    EntityResolution='Resolved'. Anything else → graceful skip.

    .PARAMETER CorrelationId
    Cycle correlation GUID (propagated to every child poll + telemetry event).

    .PARAMETER ParentRows
    OPTIONAL recently-ingested PARENT rows · their EntityIdField values are added to the bounded cache before resolving
    (so a parent op that ran THIS cycle immediately feeds its children). The cache also persists across cycles (TTL'd).

    .PARAMETER ParentEntry
    OPTIONAL parent manifest entry · when the cache is EMPTY (and no ParentRows feed it), the fan-out does ONE bounded
    parent poll (Get-XdrParentEntityIds · never ingests · never throws) to seed the id set so it is self-sufficient.
    Absent → an empty cache simply skips gracefully.

    .OUTPUTS
    @{ OperationKey; Skipped; SkipReason; EntitiesPolled; EntitiesAvailable; ChildResults; ItemCount; Success;
       CorrelationId; DurationMs }. NEVER throws (the cycle must continue regardless).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [hashtable] $Entry,
        [string] $CorrelationId = '',
        [Parameter()] [AllowNull()] [AllowEmptyCollection()] [object[]] $ParentRows,
        [Parameter()] [AllowNull()] [hashtable] $ParentEntry
    )

    $startedUtc = [DateTime]::UtcNow
    $Entry = ConvertTo-XdrDeepHashtable -InputObject $Entry
    $opKey = if ($Entry['OperationKey']) { [string]$Entry['OperationKey'] } else { 'unknown' }
    $result = @{
        OperationKey      = $opKey
        Skipped           = $false
        SkipReason        = $null
        EntitiesPolled    = 0
        EntitiesAvailable = 0
        ChildResults      = @()
        ItemCount         = 0
        Success           = $true     # an intentional skip is a SUCCESSFUL no-op (the cycle continues)
        ErrorClass        = $null     # E-MAJ2 · set on a REAL parent-feed failure (distinct from a benign empty-parent skip)
        CorrelationId     = $CorrelationId
        DurationMs        = 0
    }

    # Local graceful-skip helper · records reason + telemetry, returns the (success) result. NEVER throws.
    $skip = {
        param([string]$reason)
        $result.Skipped = $true
        $result.SkipReason = $reason
        Write-Warning "[Runtime] Invoke-XdrEntityFanout · SKIP op=$opKey · $reason"
        if (Get-Command Track-XdrEvent -ErrorAction SilentlyContinue) {
            Track-XdrEvent -Name 'Entry.Fanout.Skipped' -Properties @{ OperationKey = $opKey; CorrelationId = $CorrelationId; Reason = $reason }
        }
        $result.DurationMs = [int]((([DateTime]::UtcNow) - $startedUtc).TotalMilliseconds)
        return $result
    }

    # E-MAJ2 · parent-FEED-FAILURE helper · the parent SEED poll threw (a real upstream failure, NOT a legitimate
    # 0-id parent). Surface a DISTINCT NON-SUCCESS (Success=$false + ErrorClass + a ParentFeedFailed SkipReason) so the
    # Activity records an ErrorClass and the breaker can act on REPEATED parent-feed failure — instead of the benign
    # Success=$true graceful skip used for a genuinely-empty parent (which the breaker would never escalate). Still
    # NEVER throws (the cycle continues · the breaker, not a throw, governs escalation). The child polls did not run.
    $fail = {
        param([string]$reason, [string]$errMsg)
        $result.Skipped    = $true
        $result.SkipReason = $reason
        $result.Success    = $false
        $result.ErrorClass = 'XdrEntityParentFeedFailed'
        Write-Warning "[Runtime] Invoke-XdrEntityFanout · PARENT-FEED-FAILED op=$opKey · $reason · $errMsg"
        if (Get-Command Track-XdrEvent -ErrorAction SilentlyContinue) {
            Track-XdrEvent -Name 'Entry.Fanout.ParentFeedFailed' -Properties @{ OperationKey = $opKey; CorrelationId = $CorrelationId; Reason = $reason; ErrorMessage = $errMsg }
        }
        $result.DurationMs = [int]((([DateTime]::UtcNow) - $startedUtc).TotalMilliseconds)
        return $result
    }

    try {
        $portal   = if ($Entry['Portal'])   { [string]$Entry['Portal'] }   else { 'Defender' }
        $category = [string]$Entry['Category']

        # ── Gate 1 · the edge must be RESOLVED (else the catalogue could not match a parent id source) ──
        $dependsOn = $Entry['DependsOn']
        $entityResolution = if ($Entry['EntityResolution']) { [string]$Entry['EntityResolution'] } else { '' }
        if ($dependsOn -isnot [System.Collections.IDictionary]) { return & $skip 'no DependsOn edge (Unresolved entity op · catalogued + RawJson-capable · fan-out skipped)' }
        if ($entityResolution -and $entityResolution -ne 'Resolved') { return & $skip "EntityResolution='$entityResolution' (not Resolved · fan-out skipped)" }
        $parentOpKey  = if ($dependsOn['ParentOperationKey']) { [string]$dependsOn['ParentOperationKey'] } else { '' }
        $entityField  = if ($dependsOn['EntityIdField'])      { [string]$dependsOn['EntityIdField'] }      else { '' }
        $paramName    = if ($dependsOn['ParamName'])          { [string]$dependsOn['ParamName'] }          else { '' }
        if ([string]::IsNullOrEmpty($parentOpKey) -or [string]::IsNullOrEmpty($entityField) -or [string]::IsNullOrEmpty($paramName)) {
            return & $skip 'incomplete DependsOn edge (missing ParentOperationKey / EntityIdField / ParamName)'
        }

        # ── Feed the bounded cache from THIS cycle's parent rows (if any), then resolve the id set ──
        if ($ParentRows -and @($ParentRows).Count -gt 0) {
            $freshIds = Get-XdrEntityIdField -Rows $ParentRows -EntityIdField $entityField
            if (@($freshIds).Count -gt 0) { Add-XdrEntityIds -Portal $portal -Category $category -ParentOperationKey $parentOpKey -Ids $freshIds }
        }
        $entityIds = @(Get-XdrCachedEntityIds -Portal $portal -Category $category -ParentOperationKey $parentOpKey)
        # Cache empty + a parent entry supplied → ONE bounded parent poll to seed the ids (self-sufficient · never throws).
        if (@($entityIds).Count -eq 0 -and $ParentEntry -is [hashtable]) {
            $polledIds = Get-XdrParentEntityIds -ParentEntry $ParentEntry -EntityIdField $entityField -CorrelationId $CorrelationId
            if (@($polledIds).Count -gt 0) {
                Add-XdrEntityIds -Portal $portal -Category $category -ParentOperationKey $parentOpKey -Ids $polledIds
                $entityIds = @(Get-XdrCachedEntityIds -Portal $portal -Category $category -ParentOperationKey $parentOpKey)
            }
            # E-MAJ2 · the seed poll returned no ids AND the just-completed seed poll THREW (a real parent-feed failure,
            # NOT a benign 0-id parent) → surface a DISTINCT non-success so the Activity records an ErrorClass and the
            # breaker can act on repeated parent-feed failure (vs the benign empty-parent skip below). Read the signal
            # the seed poll just set; it is scoped to THIS call (cleared at the seed poll's entry).
            if (@($entityIds).Count -eq 0 -and $script:XdrLastParentPollFailure -and $script:XdrLastParentPollFailure['ThrewError']) {
                return & $fail "parent SEED poll FAILED for ParentOperationKey='$parentOpKey' (real parent-feed failure · breaker-actionable)" ([string]$script:XdrLastParentPollFailure['ErrorMessage'])
            }
        }
        $result.EntitiesAvailable = @($entityIds).Count
        if (@($entityIds).Count -eq 0) {
            return & $skip "parent cache empty for ParentOperationKey='$parentOpKey' (no recently-seen entity ids · fan-out skipped · cycle continues)"
        }

        # ── Cap + MOST-OVERDUE-FIRST ordering (bounds the fan-out · 10k entities can't blow the cycle) ──
        # Budget = XDRLR_MAX_ENTITIES_PER_CYCLE (default 50). Order by each entity's composite-checkpoint LastUpdatedUtc
        # ASCENDING (never-polled = DateTime.MinValue = most overdue → first); ties broken by id (stable · deterministic).
        # Entities not reached this cycle fire on subsequent cycles (the budget rotates through the set · like the
        # per-cycle activity cap). Reading each checkpoint is best-effort: a read error → treat as most-overdue (run it).
        $maxEntities = 50
        if ($env:XDRLR_MAX_ENTITIES_PER_CYCLE) { $v = 0; if ([int]::TryParse([string]$env:XDRLR_MAX_ENTITIES_PER_CYCLE, [ref]$v) -and $v -ge 1) { $maxEntities = $v } }
        $partitionKey = "${portal}_${category}"
        $ranked = foreach ($id in $entityIds) {
            $lastUtc = [DateTime]::MinValue
            try {
                $cpId = Get-XdrCheckpoint -PartitionKey $partitionKey -OperationKey ("${opKey}|${id}")
                if ($cpId -and $cpId['LastUpdatedUtc']) { $lastUtc = (ConvertTo-XdrUtc $cpId['LastUpdatedUtc']) }
            } catch { $lastUtc = [DateTime]::MinValue }   # INTENTIONAL-FAIL-SAFE: unreadable checkpoint → most overdue
            [pscustomobject]@{ Id = [string]$id; LastUtc = $lastUtc }
        }
        # E-MAJ3 (2026-06-19) · PER-ENTITY CADENCE GATE. The fanout op writes ONLY composite <opKey>|<id> checkpoints,
        # so the dispatch G-Cadence gate (which point-reads the BASE opKey checkpoint · run.ps1) finds none → treats the
        # op as first-cycle-ever → DUE on every 1-min cycle. Ungated, the fanout re-polled EVERY cached entity EVERY
        # cycle (live 2026-06-19: 1078 child-polls/2h for 9 entities on a 6h tier · skewed verifier D1/D3/D7). Gate each
        # entity by ITS OWN composite checkpoint vs the op's Cadence (the same span the dispatch gate uses for non-fanout
        # ops): an entity is eligible only if NEVER polled (MinValue) OR (now - itsLastUtc) >= cadence. The op still
        # fires every cycle (cheap parent-cache read + rank) but selects 0 entities until one is due. GENERIC — every
        # fanout op now honors its manifest cadence per-entity. Fail-open: no/unparseable Cadence → all eligible (prior
        # behavior · a cadence-gate slip must NEVER block the cycle).
        $cadenceSpan = $null
        if ($Entry['Cadence']) { try { $cadenceSpan = [TimeSpan]::Parse([string]$Entry['Cadence'], [System.Globalization.CultureInfo]::InvariantCulture) } catch { $cadenceSpan = $null } }
        $nowUtc = [DateTime]::UtcNow
        $eligible = if ($cadenceSpan) { @($ranked | Where-Object { $_.LastUtc -eq [DateTime]::MinValue -or ($nowUtc - $_.LastUtc) -ge $cadenceSpan }) } else { @($ranked) }
        $entitiesDue = @($eligible).Count
        $selected = @($eligible | Sort-Object -Property @{ Expression = 'LastUtc'; Descending = $false }, @{ Expression = 'Id'; Descending = $false } | Select-Object -First $maxEntities)

        Track-XdrEvent -Name 'Entry.Fanout.Started' -Properties @{
            OperationKey = $opKey; CorrelationId = $CorrelationId; ParentOperationKey = $parentOpKey
            EntitiesAvailable = $result.EntitiesAvailable; EntitiesDue = $entitiesDue; EntitiesSelected = @($selected).Count; MaxPerCycle = $maxEntities
        }

        # ── Poll each selected entity via the EXISTING Invoke-XdrEntryPoll under a COMPOSITE checkpoint key ──
        # Per-entity isolation: a single entity's poll failure (Invoke-XdrEntryPoll NEVER throws · returns Success=$false)
        # is recorded but the loop continues to the next entity. The child entry is a SHALLOW clone with:
        #   OperationKey = "<opKey>|<id>"  → distinct checkpoint RowKey → independent high-water+boundary (exactly-once)
        #   BaseOperationKey = "<opKey>"   → E-BLK2 · the un-composited base op key Invoke-XdrEntryPoll stamps into the
        #                                     row `Operation` envelope column + poll telemetry (so they are NOT composite);
        #                                     this layer OWNS the composite format, so it hands the base across authoritatively
        #                                     (Invoke-XdrEntryPoll's '|<id>'-strip is the defensive fallback when absent).
        #   EntityParams = @{ <ParamName> = <id> }  → New-XdrRequestUrl substitutes {param}→id
        $childResults = [System.Collections.Generic.List[hashtable]]::new()
        $totalItems = 0
        foreach ($sel in $selected) {
            $id = $sel.Id
            $childEntry = @{}
            foreach ($k in $Entry.Keys) { if ($k -ne 'EntityParams') { $childEntry[$k] = $Entry[$k] } }
            $childEntry['OperationKey'] = "${opKey}|${id}"
            $childEntry['BaseOperationKey'] = $opKey
            $childEntry['EntityParams'] = @{ $paramName = $id }
            $cr = Invoke-XdrEntryPoll -Entry $childEntry -CorrelationId $CorrelationId -ParentRecordId ([string]$id)   # F2 · child rows carry the parent entity id (entity-DAG · child.ParentRecordId == parent.RecordId)
            $childResults.Add($cr)
            if ($cr['ItemCount']) { $totalItems += [int]$cr['ItemCount'] }
        }

        $result.EntitiesPolled = @($selected).Count
        $result.ChildResults   = @($childResults)
        $result.ItemCount      = $totalItems
        $result.Success        = $true
        Track-XdrEvent -Name 'Entry.Fanout.Completed' -Properties @{
            OperationKey = $opKey; CorrelationId = $CorrelationId; EntitiesPolled = $result.EntitiesPolled
            ItemCount = $totalItems; EntitiesAvailable = $result.EntitiesAvailable
        }
    } catch {
        # DEGRADE (U4) · any unexpected error in fan-out orchestration → skip this op, the cycle continues. The breaker /
        # exactly-once of whatever DID poll already committed inside Invoke-XdrEntryPoll (which never threw to here).
        $result.Skipped    = $true
        $result.SkipReason = "fanout-error: $($_.Exception.Message)"
        $result.Success    = $true   # NEVER fault the cycle for a fan-out orchestration error
        Write-Warning "[Runtime] Invoke-XdrEntityFanout · DEGRADE op=$opKey · $($_.Exception.Message)"
        if (Get-Command Track-XdrEvent -ErrorAction SilentlyContinue) {
            Track-XdrEvent -Name 'Entry.Fanout.Error' -Properties @{ OperationKey = $opKey; CorrelationId = $CorrelationId; ErrorMessage = $_.Exception.Message }
        }
    }
    $result.DurationMs = [int]((([DateTime]::UtcNow) - $startedUtc).TotalMilliseconds)
    return $result
}

# ─── Portal HTTP helper (per-portal Client modules override the URL+cookie specifics) ──
function Invoke-XdrPortalHttp {
    # EXPORTED (was `function script:` = module-private, which threw CommandNotFoundException when the 5 cross-module
    # callers used it — Xdr.Common.Capabilities R3 discovery [→ products=[(none)]] + the 4 portal Client modules).
    param([hashtable]$Session, [string]$Method, [string]$Url, [object]$Body = $null, [hashtable]$ExtraHeaders = @{})
    # Defender /apiproxy requires Cookie: sccauth AND X-XSRF-TOKEN (URL-decoded · captured at auth) —
    # without XSRF the portal returns 403 csrf-token-mismatch. Indexer reads (StrictMode-safe).
    $headers = @{ Accept = 'application/json' }
    if ($Session) {
        # F1.4b · the Portal Registry's AuthMode routes the auth header (fail-safe: Cookie = the Defender path, BYTE-
        # IDENTICAL). Bearer portals (Entra/Intune/SecurityCopilot) send Authorization: Bearer <token>; cookie portals
        # (Defender/Purview) send Cookie + X-XSRF-TOKEN. An unregistered/unknown portal falls back to Cookie.
        $authMode = 'Cookie'
        if ($Session['Portal']) { try { $authMode = [string](Get-XdrPortalConfig -Portal ([string]$Session['Portal']))['AuthMode'] } catch { $authMode = 'Cookie' } }
        if ($authMode -eq 'Bearer') {
            $token = if ($Session['AccessToken']) { [string]$Session['AccessToken'] } elseif ($Session['Token']) { [string]$Session['Token'] } else { '' }
            if ($token) { $headers['Authorization'] = "Bearer $token" }   # fail-safe: no token → no header (never a malformed "Bearer ")
        } else {
            $cookie = if ($Session['Cookie']) { [string]$Session['Cookie'] } elseif ($Session['Sccauth']) { "sccauth=$($Session['Sccauth'])" } else { '' }
            if ($cookie) { $headers['Cookie'] = $cookie }
            if ($Session['XsrfToken']) { $headers['X-XSRF-TOKEN'] = [string]$Session['XsrfToken'] }
        }
    }
    # F-REQHEADERS (2026-06-25) · GENERIC per-op REQUEST HEADERS overlay. Some Defender backends require a header that
    # is per-route DATA, not a fixed transport constant — the tvm/analytics surface (all TVM + ASR ops) needs an
    # `api-version` REQUEST HEADER or the backend 400s (the query-string form is rejected). The per-op value rides the
    # manifest Entry (RequestHeaders · curation-declared per OperationId) and the poll path passes it here. Merged AFTER
    # the base+auth headers so a per-op override is intentional, yet it MUST NOT clobber the auth/csrf headers in
    # practice (curation never declares those · they are transport-owned). Empty default ⇒ byte-identical to the prior
    # fixed header set (no regression for every op without a declaration). StrictMode-safe (hashtable indexer · key/value
    # stringified · empty-key guarded). ADDITIVE: a portal Client override or a future header type needs no signature
    # change — it is data, flowing curation → manifest → poll → here.
    if ($ExtraHeaders) {
        foreach ($k in @($ExtraHeaders.Keys)) {
            if (-not [string]::IsNullOrEmpty([string]$k)) { $headers[[string]$k] = [string]$ExtraHeaders[$k] }
        }
    }
    try {
        # F-APIVERSION (2026-06-25) · GENERIC api-version NEGOTIATION wired into the transport. The §F-APIVERSION helpers
        # at the top of this module (Test-XdrIsTvmAnalyticsUrl · Get-XdrApiVersionRoutePrefix · the candidates + cache)
        # were DEFINED BUT UNWIRED — a manual-audit catch: with the per-op curation removed, nothing supplied api-version,
        # so every tvm/analytics op would 400. The /tvm/analytics/ backend REQUIRES an `api-version` REQUEST header and the
        # working version VARIES BY ROUTE (1.0 for assets/products/riskscore/advisories/changeEvents · 2.0 for sca/topPerDay
        # · LIVE-matrix-proven) with NO single default — each route REJECTS the other version (400/405). So the engine
        # NEGOTIATES uniformly (NO per-op curation): send a candidate, on a version-reject (400/405) retry the next, and
        # CACHE the first that passes the version gate PER ROUTE-PREFIX (one-time per route · then a single byte-identical
        # send). EVERY non-tvm/analytics request makes exactly ONE pass with NO api-version header (the @($null) candidate)
        # → byte-identical, zero regression for all other surfaces.
        # -SkipHttpErrorCheck (PS7): do NOT throw on 4xx/5xx — capture the response + body inline (the prior $_.ErrorDetails
        # path returned empty for Defender's bodyless 500s; reading $resp.Content directly is reliable).
        $isTvmAnalytics = Test-XdrIsTvmAnalyticsUrl $Url
        $verPrefix = if ($isTvmAnalytics) { Get-XdrApiVersionRoutePrefix $Url } else { '' }
        # if-STATEMENTS (NOT an if-EXPRESSION assignment) + a trailing @() — a 1-element if-expression result UNWRAPS to a
        # scalar and `.Count` then throws under StrictMode (hit on the cached-version send + the @($null) no-version pass).
        if (-not $isTvmAnalytics) { $verCandidates = @($null) }                                                                            # one pass · no api-version header
        elseif ($script:XdrApiVersionCache.ContainsKey($verPrefix)) { $verCandidates = @([string]$script:XdrApiVersionCache[$verPrefix]) }  # cached winner → one send
        else { $verCandidates = @($script:XdrTvmApiVersionCandidates) }                                                                     # negotiate the ordered candidates
        $verCandidates = @($verCandidates)                                                                                                 # FORCE array (defeat single-element unwrap)
        $resp = $null; $sc = 0; $bodyText = ''
        for ($vi = 0; $vi -lt $verCandidates.Count; $vi++) {
            $ver = [string]$verCandidates[$vi]
            # SET the negotiated api-version (tvm/analytics). On the @($null) no-version pass ($ver = '') leave $headers
            # UNTOUCHED so a per-op ExtraHeaders api-version on a NON-tvm/analytics URL is preserved (overlay seam intact).
            if ($ver) { $headers['api-version'] = $ver }
            $params = @{ Method = $Method; Uri = $Url; Headers = $headers; TimeoutSec = 60; SkipHttpErrorCheck = $true; ErrorAction = 'Stop'; SslProtocol = 'Tls12, Tls13' }   # TLS-1.2+ pinned code-side (§3)
            if ($Body -and ($Method -in @('POST','PUT','PATCH'))) {
                # B-25 trap guard: only objects get serialized; strings pass through verbatim.
                if ($Body -isnot [string]) { $params.Body = $Body | ConvertTo-Json -Depth 15 -Compress } else { $params.Body = $Body }
                $params.ContentType = 'application/json'
            }
            $resp = Invoke-WebRequest @params
            $sc = [int]$resp.StatusCode
            $bodyText = [string]$resp.Content
            # tvm/analytics version-reject → negotiate the next version. A 405 (Method-Not-Allowed) is STRUCTURALLY a
            # version/method reject for that route (the live matrix returns 405 with NO body for the wrong version) → retry
            # on 405 unconditionally. A 400 is AMBIGUOUS — a version reject ONLY when the body proves it (UnsupportedApiVersion
            # / 'expected header', exactly as the proven probe Invoke-TvmGetNegotiated checks); a 400 for ANOTHER reason
            # (e.g. 'Wrong pagination parameters') must SURFACE the real error, not be mis-retried as a version issue. The
            # prior over-broad (any-400/405) retry MASKED the live pagination 400 as UnsupportedApiVersion (verify-trust-none
            # · live-proven 2026-06-25). A non-version 405 still surfaces — it 405s on every candidate → exhausts → terminal.
            if ($isTvmAnalytics -and ($vi -lt ($verCandidates.Count - 1)) -and (($sc -eq 405) -or ($sc -eq 400 -and ($bodyText -match '(?i)unsupported.?api.?version|expected[ -]?header')))) {
                Write-Host "[Invoke-XdrPortalHttp] api-version '$ver' version-rejected (HTTP $sc) for $verPrefix · negotiating next candidate"
                continue
            }
            # accepted (or candidates exhausted) → cache the winning version per route-prefix (on success only) and proceed.
            if ($isTvmAnalytics -and $ver -and $sc -lt 400) { $script:XdrApiVersionCache[$verPrefix] = $ver }
            break
        }
        if ($sc -ge 400) {
            $respClip = if ($bodyText.Length -gt 600) { $bodyText.Substring(0, 600) } else { $bodyText }
            Write-Host "[Invoke-XdrPortalHttp] HTTP $sc · $Method $Url · body=$respClip"
            # AUTH-LOSS by STATUS (F1 · complements the HTML-at-JSON guard below): an expired/revoked cookie or bearer
            # can surface as a literal 401 (Unauthorized) or 440 (Microsoft "login timeout") on the DATA endpoint
            # INSTEAD of a 302→HTML login redirect. Classify those as AuthChainBroken so Invoke-XdrAuthenticated
            # SELF-HEALS (one reauth) instead of DLQ-ing them as terminal. NOT defensive masking — it SURFACES auth-loss
            # and recovers it. 403/404 are NOT auth-loss (capability-absent → posture, handled upstream); every other
            # <500 (≠429) is a genuine terminal contract error → fail-loud → DLQ+breaker.
            if ($sc -eq 401 -or $sc -eq 440) {
                throw (New-XdrException -Type AuthChainBroken -Message "HTTP $sc (auth-loss) for $Url" -Properties @{ Portal = $Session['Portal']; FailureStage = "Http$sc"; StatusCode = $sc })
            }
            # CR2 (audit 2026-06-12) · a 403 whose body is a CSRF/XSRF-token-mismatch is AUTH-LOSS (a stale/rotated
            # XSRF on an otherwise-valid sccauth · the portal requires X-XSRF-TOKEN), NOT capability-absence. Route it
            # to AuthChainBroken so the reauth re-captures a fresh sccauth+XSRF — else the op posture-skips FOREVER
            # (silent zero-rows stall while ExpiresUtc keeps the session "alive"). A NON-csrf 403 stays terminal below.
            if ($sc -eq 403 -and ([string]$respClip -match '(?i)csrf|xsrf|x-xsrf-token|token[ _-]?(validation|mismatch)')) {
                throw (New-XdrException -Type AuthChainBroken -Message "HTTP 403 (csrf/xsrf-token-mismatch · auth-loss) for $Url" -Properties @{ Portal = $Session['Portal']; FailureStage = 'Http403Csrf'; StatusCode = 403 })
            }
            if ($sc -lt 500 -and $sc -ne 429) {
                throw (New-XdrException -Type PortalTerminal -Message "HTTP $sc for $Url · $respClip" -Properties @{ StatusCode = $sc; OperationKey = ''; Url = $Url; ResponseBody = $respClip })
            }
            # 429/5xx transient · honor the server's Retry-After header (delta-seconds OR HTTP-date · capped 300s)
            # when present, instead of always guessing 30s (plan §7 M7). Fail-safe: unparseable → keep the 30s default.
            $retryAfter = 30
            $raVal = $null; try { $raVal = $resp.Headers['Retry-After'] } catch { $raVal = $null }
            if ($raVal) {
                if ($raVal -is [System.Array]) { $raVal = $raVal[0] }
                $raVal = [string]$raVal; $secs = 0
                if ([int]::TryParse($raVal, [ref]$secs) -and $secs -ge 0) { $retryAfter = [Math]::Min($secs, 300) }
                else { try { $d = [DateTimeOffset]::Parse($raVal, [Globalization.CultureInfo]::InvariantCulture); $sd = [int]($d - [DateTimeOffset]::UtcNow).TotalSeconds; if ($sd -gt 0) { $retryAfter = [Math]::Min($sd, 300) } } catch { } }
            }
            throw (New-XdrException -Type PortalTransient -Message "HTTP $sc for $Url · $respClip" -Properties @{ StatusCode = $sc; OperationKey = ''; RetryAfterSeconds = $retryAfter; Url = $Url; ResponseBody = $respClip })
        }
        $body = $null
        if ($bodyText) {
            try { $body = $bodyText | ConvertFrom-Json -AsHashtable -Depth 25 } catch { $body = $bodyText }
        }
        # HTML-at-JSON guard (cookie expired or KMSI rotated → portal redirects to login → HTML body).
        # BROADENED: the live login page body leads with `<!-- Copyright (C) Microsoft... -->` BEFORE
        # `<!DOCTYPE html>`, so the prior `^\s*(<!DOCTYPE|<html)` anchor MISSED it (the comment is not whitespace).
        # Trim a leading UTF-8 BOM + whitespace, then match an HTML/comment START shape. Deliberately NOT broadened
        # to match arbitrary HTML substrings inside a JSON value (false-positive risk) — only the leading shape.
        $btTrim = $bodyText.TrimStart([char]0xFEFF, ' ', "`t", "`r", "`n")
        if ($btTrim -match '^(<!DOCTYPE\s+html|<html\b|<!--)') {
            throw (New-XdrException -Type AuthChainBroken -Message 'Got HTML where JSON expected · auth chain broken' -Properties @{ Portal = $Session['Portal']; FailureStage = 'HtmlResponse' })
        }
        # F1.4b · Headers returned so RFC5988 `Link:`-header cursor pagination (Graph/Entra/SharePoint) can read them.
        return @{ StatusCode = $sc; Body = $body; RawBody = $bodyText; Headers = $resp.Headers }
    } catch {
        # Re-throw our OWN typed exceptions as-is; wrap a genuine transport error (DNS/timeout/TLS — no HTTP response
        # at all) as a transient so the breaker + retry treat it correctly.
        # FIX: the prior `-like 'Xdr*'` name guard MISSED AuthChainBrokenException (its name does NOT start with
        # 'Xdr') → the HTML-at-JSON AuthChainBroken thrown just above was caught HERE and re-wrapped as a transient,
        # so Invoke-XdrAuthenticated could never see it and self-heal (the auth-loss masqueraded as a 5xx retry-loop).
        # Walk the base-type chain by NAME instead: every typed XdrException subclass derives from 'XdrException'.
        # (A bare `-is [XdrException]` does NOT resolve here — the class lives in another module and its type literal
        # is not importable across the module boundary without `using module`; the name-walk is the portable check.)
        $isOurs = $false
        for ($t = $_.Exception.GetType(); $t; $t = $t.BaseType) { if ($t.Name -eq 'XdrException') { $isOurs = $true; break } }
        if ($isOurs) { throw }
        Write-Host "[Invoke-XdrPortalHttp] transport error · $Method $Url · $($_.Exception.GetType().Name): $($_.Exception.Message)"
        throw (New-XdrException -Type PortalTransient -Message "transport error for $Url · $($_.Exception.Message)" -Properties @{ StatusCode = 0; OperationKey = ''; RetryAfterSeconds = 30; Url = $Url })
    }
}

# ─── Self-healing reauth wrapper (the connector detected auth-loss but NEVER recovered) ──
# Invoke-XdrPortalHttp throws AuthChainBroken on an HTML-at-JSON body (cookie expired / KMSI rotated → portal
# redirects to login → HTML). The dead session stays cached → the next cycle re-reads it → IDENTICAL failure =
# crash-loop. This wrapper closes the loop: on AuthLost it INVALIDATES the dead session — L1 HotCache ONLY,
# PRESERVING the L2 row (its 90d KMSI cookie keeps the re-mint TOTP-free) — and reauths ONCE via
# Connect-XdrPortal -Force (the old L2-destroying Remove-XdrL2Session is removed · WS3.1). The -Force path's
# single-flight lease serializes concurrent ops so a burst causes exactly ONE TOTP. If the single reauth still
# fails it throws — but the dead session is now GONE, so the NEXT cycle starts a clean fresh auth instead of
# replaying the cached failure. Crash-loop broken. Only AuthChainBrokenException triggers reauth; a
# PortalTransient/PortalTerminal is rethrown verbatim (breaker/DLQ classification stays intact).
function Invoke-XdrAuthenticated {
    param([Parameter(Mandatory)][string]$Portal, [Parameter(Mandatory)][string]$Method, [Parameter(Mandatory)][string]$Url, [object]$Body = $null, [hashtable]$ExtraHeaders = @{}, [int]$MaxReauth = 1)
    $session = Connect-XdrPortal -Portal $Portal
    for ($attempt = 0; ; $attempt++) {
        # F-REQHEADERS · thread the per-op REQUEST HEADERS through the self-heal wrapper to Invoke-XdrPortalHttp. Empty
        # default ⇒ byte-identical to the prior call (no regression for every caller that does not pass headers).
        try { return Invoke-XdrPortalHttp -Session $session -Method $Method -Url $Url -Body $Body -ExtraHeaders $ExtraHeaders }
        catch {
            $isAuthLost = ($_.Exception.GetType().Name -eq 'AuthChainBrokenException')
            if ($isAuthLost -and $attempt -lt $MaxReauth) {
                $upn = $env:XDRLR_SERVICE_ACCOUNT_UPN
                Write-Host "[evt] Auth.Reauth.Triggered portal=$Portal attempt=$attempt"
                if (Get-Command Track-XdrEvent -ErrorAction SilentlyContinue) { Track-XdrEvent -Name 'Auth.Reauth.Triggered' -Properties @{ Portal = $Portal; Attempt = $attempt } }
                # PRESERVE KMSI for a TOTP-FREE T2 re-mint. Invalidate L1 ONLY (drop the stale hot session) and KEEP the
                # L2 row — it carries the 90d ESTSAUTHPERSISTENT KmsiCookie that Connect -Force's T2 KMSI silent re-mint
                # needs. -Force already skips SERVING the dead session (T1 bypass), and a successful re-mint overwrites L2.
                # The prior Remove-XdrL2Session DESTROYED the KMSI cookie → every reactive 440 fell through to a T3 TOTP
                # burn (verified-live root cause · 2026-06-11) — which is the only reason the static 110-min sccauth cap
                # existed (to proactively re-mint and dodge the 440). With KMSI preserved, reactive recovery is TOTP-free,
                # so the cap is gone and ExpiresUtc is the real dynamic KMSI expiry. ($upn unused now · kept for telemetry.)
                Invalidate-XdrCache -L1KeyPrefix "session::$Portal::"
                $session = Connect-XdrPortal -Portal $Portal -Force
                if (Get-Command Track-XdrEvent -ErrorAction SilentlyContinue) { Track-XdrEvent -Name 'Auth.Reauth.Succeeded' -Properties @{ Portal = $Portal; Attempt = $attempt } }
                continue
            }
            throw
        }
    }
}

# ─── Checkpoint I/O via HttpClient REST (Xdr.Common.Storage) ──────────────────
# StateStore: XdrCheckpoint table · PartitionKey="Portal_Category" · RowKey=OperationKey

function Get-XdrCheckpointsForPartition {
    <#
    .SYNOPSIS
    F7 · batch-read ALL XdrCheckpoint rows for a partition (Portal_Category) in ONE query → a hashtable keyed by
    OperationKey (RowKey) → the checkpoint entity (incl. LastUpdatedUtc). Kills the cadence gate's O(N) per-op
    cold-start point-reads. BEST-EFFORT / FAIL-OPEN: a read error or absent table returns @{} so the gate treats every
    op as due (the SAME fail-open the per-op cadence gate uses). This feeds the CADENCE/overdue gate ONLY — NOT the
    poll's EO1-strict read: Invoke-XdrEntryPoll still does its own Get-XdrCheckpoint (with the ETag for atomic
    write-back), so a batch read-blip can never cause a duplicate ingest (it only over-includes an op as "due").
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)] [string] $PartitionKey)
    $map = @{}
    try {
        if (-not (Get-Command Get-XdrTableEntities -ErrorAction SilentlyContinue)) { return $map }
        $res = Get-XdrTableEntities -TableName 'XdrCheckpoint' -PartitionKey $PartitionKey
        if ($res -and $res['Found']) {
            foreach ($e in @($res['Entities'])) {
                $rk = [string]$e['RowKey']
                if ($rk) { $map[$rk] = $e }
            }
        }
    } catch {
        # §4.B B11: emit the fail-open as a gateable event (alongside the warning) so the cadence gate's
        # "treat all due" fallback is visible to gating, not just host-noise. Guarded like the reauth Track call.
        Write-Warning "[Runtime] Get-XdrCheckpointsForPartition read failed (fail-open · cadence gate treats all due): $($_.Exception.Message)"
        if (Get-Command Track-XdrEvent -ErrorAction SilentlyContinue) { Track-XdrEvent -Name 'Entry.FailOpen' -Properties @{ GateName = 'CadenceCheckpointRead'; PartitionKey = $PartitionKey } }
    }
    return $map
}

function Get-XdrCheckpoint {
    <#
    .SYNOPSIS
    Read checkpoint row. Returns @{ OperationKey; Cursor; WindowStartUtc; WindowEndUtc;
    LastUpdatedUtc; LastItemCount; ETag }. ETag is needed for atomic write back.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $PartitionKey,
        [Parameter(Mandatory)] [string] $OperationKey
    )

    $default = @{
        OperationKey   = $OperationKey
        Cursor         = $null
        BoundaryKeys   = $null   # comma-joined natural keys at the exact high-water (exactly-once · plan §35.2)
        SnapshotSignature = $null   # F-SNAPSHOT-SIG · last cursorless-SNAPSHOT signature (hash of sorted RecordId set · skip the re-emit when unchanged)
        ResumePage         = $null   # U1 · resumable pagination · next page of an in-progress incomplete drain
        ResumeCursor       = $null   # U1 · next server token of an in-progress incomplete drain
        ResumeHighWater    = $null   # U1 · pending high-water of an in-progress multi-cycle drain
        ResumeBoundaryKeys = $null   # U1 · boundary keys at the pending high-water
        WindowStartUtc = $null
        WindowEndUtc   = $null
        LastUpdatedUtc = $null
        LastItemCount  = 0
        # B10/B9/D3/D7 reset-discrimination breadcrumb (advance-immunity · audit 2026-06-24). Written ONLY by
        # Save-XdrCheckpointReset; the FA runtime does NOT consume it (re-baseline is signalled by Cursor=''),
        # so surfacing it here is purely so Save-XdrCheckpointAtomic can CARRY IT FORWARD unchanged on every
        # advance instead of dropping it (the full-entity PUT omitted it → the first advance after a reset
        # erased the reset stamp → the audit reset-counter false-read "NO reset" and could FALSE-FAIL B10).
        ResetUtc              = $null   # original reset timestamp · the audit reader ages it out via its 24h in-window check
        ResetReasonAnnotation = $null   # original reset reason · carried alongside ResetUtc for breadcrumb completeness
        ETag           = $null   # null ETag → first write uses Insert (no conditional)
    }

    # EO1 (audit 2026-06-12): a storage READ error is NOT "no checkpoint exists". The old catch→cold-default made
    # a transient 500/timeout/throttle indistinguishable from genuine absence → the CURSOR op re-ingested the full
    # history as DUPLICATES and the follow-up null-ETag save CLOBBERED the real row. Retry the read (the storage
    # REST layer is single-shot); a single blip self-heals within the cycle. If it STILL fails, FAIL LOUD as
    # transient (same precedent as the lease-lost stop above) so the poll aborts WITHOUT ingesting or advancing
    # and retries next cadence — the real checkpoint stays intact. Genuine absence is `Found=false` (cold default).
    $result = $null
    $readErr = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try { $result = Get-XdrTableEntity -TableName 'XdrCheckpoint' -PartitionKey $PartitionKey -RowKey $OperationKey; $readErr = $null; break }
        catch { $readErr = $_; if ($attempt -lt 3) { Start-Sleep -Milliseconds (200 * $attempt) } }
    }
    if ($readErr) {
        Write-Warning "[Runtime] Get-XdrCheckpoint read failed after 3 attempts (transient · NOT cold-start): $($readErr.Exception.Message)"
        throw (New-XdrException -Type PortalTransient -Message "checkpoint read failed (transient · refusing to cold-start, would duplicate) for ${PartitionKey}|${OperationKey}: $($readErr.Exception.Message)" -Properties @{ OperationKey = $OperationKey; RetryAfterSeconds = 30; ViolationType = 'EO1.CheckpointReadFailed' })
    }
    if (-not $result.Found) { return $default }
    # $row is the `ConvertFrom-Json -AsHashtable` table entity (Get-XdrTableEntity). DOT-access of a column
    # that a given checkpoint row happens not to carry (schema migration, partial write) THROWS under
    # StrictMode; the INDEXER returns $null safely. Read via indexer.
    $row = $result.Entity
    # WS-A (audit 2026-06-12) · READ-BOUNDARY CANONICALISATION (the keystone of the cursor-fidelity fix). The
    # table read (ConvertFrom-Json -AsHashtable) PROMOTES the stored ISO strings to [DateTime]; returning them raw
    # let every downstream `[string]` cast truncate the high-water to whole seconds → the no-ingest cycle re-wrote a
    # truncated cursor → the boundary row tested `>` the truncated value → the live cross-cycle DUPLICATE. Canonicalise
    # the datetime-typed high-water fields HERE (Cursor + ResumeHighWater) to a full-fidelity ISO 'o' STRING, so every
    # consumer's `[string]` cast is a lossless no-op. Token/key fields (ResumeCursor, BoundaryKeys, ResumeBoundaryKeys)
    # are opaque — left raw. Window/LastUpdated are consumed via ConvertTo-XdrUtc (lossless) — left raw on read.
    return @{
        OperationKey   = $OperationKey
        Cursor         = (ConvertTo-XdrUtcString $row['Cursor'])
        BoundaryKeys   = $row['BoundaryKeys']
        SnapshotSignature = $row['SnapshotSignature']    # F-SNAPSHOT-SIG · indexer read (StrictMode-safe · absent on legacy rows → $null · cold → emit all)
        ResumePage         = $row['ResumePage']          # U1 · indexer read (StrictMode-safe · absent on legacy rows → $null)
        ResumeCursor       = $row['ResumeCursor']        # U1 · opaque server token — NEVER canonicalised as a datetime
        ResumeHighWater    = (ConvertTo-XdrUtcString $row['ResumeHighWater'])     # U1 · datetime high-water → canonical
        ResumeBoundaryKeys = $row['ResumeBoundaryKeys']  # U1
        WindowStartUtc = $row['WindowStartUtc']
        WindowEndUtc   = $row['WindowEndUtc']
        LastUpdatedUtc = $row['LastUpdatedUtc']
        LastItemCount  = $row['LastItemCount'] ?? 0
        ResetUtc              = (ConvertTo-XdrUtcString $row['ResetUtc'])   # advance-immunity · datetime → canonical ISO (the -AsHashtable promotion makes it a [DateTime]; a bare [string] cast would truncate sub-seconds · same WS-A read-boundary discipline as Cursor)
        ResetReasonAnnotation = $row['ResetReasonAnnotation']  # advance-immunity · opaque annotation (NOT a datetime) · indexer read (StrictMode-safe · absent → $null)
        ETag           = $result.ETag
    }
}

function Save-XdrCheckpointAtomic {
    <#
    .SYNOPSIS
    Atomic checkpoint advance via ETag conditional. Returns $true on success, $false on race-lost.

    Workflow:
      1. PUT entity with `If-Match: <etag>` (or `If-Match: *` on first-ever write).
      2. 204 No Content → success, cursor advanced.
      3. 412 Precondition Failed → another worker raced us. Re-read, retry once with fresh ETag.
      4. Second 412 → DLQ the batch (NOT this layer's job — caller decides) and return $false.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $PartitionKey,
        [Parameter(Mandatory)] [string] $OperationKey,
        [string]    $Cursor,
        [string]    $BoundaryKeys = '',
        [string]    $SnapshotSignature = '',
        # U1 (plan §16) · resumable-pagination state · DISTINCT from the high-water Cursor. ResumePage/ResumeCursor =
        # where an INCOMPLETE drain stopped (next page / next server token); ResumeHighWater/ResumeBoundaryKeys = the
        # in-progress drain's PENDING high-water (promoted to Cursor only on completion). All written EMPTY on a
        # complete drain (cleared). Defaulted so legacy callers (Set-XdrCheckpoint shim) keep their exact behaviour.
        [int]       $ResumePage = 0,
        [string]    $ResumeCursor = '',
        [string]    $ResumeHighWater = '',
        [string]    $ResumeBoundaryKeys = '',
        [hashtable] $Window,
        [int]       $ItemCount = 0,
        [string]    $CorrelationId = '',
        [string]    $ExistingETag = '',
        # ADVANCE-IMMUNITY (audit 2026-06-24) · the reset breadcrumb that the audit reset-counter (B9/B10 · and the
        # connector verifier's D3/D7 path) reads off the durable XdrCheckpoint row. This full-entity Insert-Or-Replace
        # USED to omit ResetUtc, so the FIRST advance after a Save-XdrCheckpointReset ERASED it → the reader counted that
        # op as "no reset" → B10 produced a misleading "clean window (NO reset)" FALSE-FAIL shortly after a reset. The
        # cure: carry the ORIGINAL reset timestamp/reason FORWARD UNCHANGED on every advance (the reader's own 24h
        # in-window parse-check ages it out naturally). The FA runtime never reads ResetUtc (re-baseline is signalled by
        # Cursor='' · see Get-XdrCheckpoint / Save-XdrCheckpointReset), so carrying it forward changes NO runtime behaviour.
        # PASSED-OR-NOT is detected via $PSBoundParameters (a [string] param coerces $null→'' at bind, so a $null
        # sentinel can't survive). NOT passed = "carry forward the prior row's value" (the hot-path callers DO pass the
        # in-hand checkpoint's ResetUtc so NO extra storage read is incurred; a caller that omits it triggers a
        # best-effort read-back below). Passed '' = "clear" (the reset writer is Save-XdrCheckpointReset, which writes
        # ResetUtc itself; this atomic advance never clears it — it only carries forward).
        [string] $ResetUtc = '',
        [string] $ResetReasonAnnotation = ''
    )

    # ADVANCE-IMMUNITY (audit 2026-06-24) · resolve the reset breadcrumb to CARRY FORWARD. If the caller did not pass
    # -ResetUtc, this advance must preserve whatever reset stamp the prior row already held (omitting it from the
    # full-entity PUT is exactly the erasure bug). Hot-path callers DO pass the in-hand checkpoint's ResetUtc (no extra
    # read). For any caller that omits it, do a BEST-EFFORT read-back of the existing row — wrapped so a storage blip
    # during read-back can NEVER fault the save (the never-throws contract holds: at worst the breadcrumb is not carried
    # this cycle, a degraded-not-fatal outcome). An explicit '' from the caller is honoured verbatim (no read-back).
    $resetUtcToWrite    = $ResetUtc
    $resetReasonToWrite = $ResetReasonAnnotation
    if (-not $PSBoundParameters.ContainsKey('ResetUtc')) {
        try {
            $priorCp = Get-XdrCheckpoint -PartitionKey $PartitionKey -OperationKey $OperationKey
            if ($priorCp) {
                $resetUtcToWrite = [string]$priorCp['ResetUtc']
                if (-not $PSBoundParameters.ContainsKey('ResetReasonAnnotation')) { $resetReasonToWrite = [string]$priorCp['ResetReasonAnnotation'] }
            }
        } catch {
            # Best-effort ONLY — a read-back failure must not break the advance (degraded: breadcrumb not carried this
            # cycle). The NEXT advance that DOES read the row cleanly re-carries it while it is still in-window.
            Write-Warning "[Runtime] Save-XdrCheckpointAtomic · ResetUtc carry-forward read-back failed (non-fatal · breadcrumb not carried this cycle) · OperationKey=$OperationKey · $($_.Exception.Message)"
        }
    }

    # WS-A (audit 2026-06-12) · WRITE-BOUNDARY CANONICALISATION (defense-in-depth · the second guarantee). Every
    # datetime-typed field is normalised to full-fidelity ISO 'o' here, so NO caller can ever persist a truncated /
    # culture-formatted high-water regardless of how it arrived (the read boundary is the primary fix; this pins it
    # for any direct/future caller). ResumeCursor + boundary keys are opaque tokens — NEVER canonicalised. LastUpdatedUtc
    # is freshly generated 'o' (already canonical). ConvertTo-XdrUtcString passes '' / unparseable values through.
    $props = @{
        Cursor             = (ConvertTo-XdrUtcString $Cursor)
        BoundaryKeys       = $BoundaryKeys   # comma-joined natural keys at the exact high-water (exactly-once · plan §35.2)
        SnapshotSignature  = $SnapshotSignature   # F-SNAPSHOT-SIG · opaque hash of the sorted RecordId set (NOT a datetime · not canonicalised)
        ResumePage         = $ResumePage          # U1 · 0 = no resume in progress (drain complete)
        ResumeCursor       = $ResumeCursor        # U1 · '' = no token-mode resume in progress · opaque token (not a datetime)
        ResumeHighWater    = (ConvertTo-XdrUtcString $ResumeHighWater)     # U1 · pending high-water of an in-progress multi-cycle drain
        ResumeBoundaryKeys = $ResumeBoundaryKeys  # U1 · boundary keys at the pending high-water
        WindowStartUtc = if ($Window) { (ConvertTo-XdrUtcString $Window.StartUtc) } else { '' }
        WindowEndUtc   = if ($Window) { (ConvertTo-XdrUtcString $Window.EndUtc) } else { '' }
        LastUpdatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        LastItemCount  = $ItemCount
        CorrelationId  = $CorrelationId
        # ADVANCE-IMMUNITY · carry the ORIGINAL reset breadcrumb forward unchanged (the full-entity PUT no longer
        # drops it). The audit reset-counter (B9/B10 · D3/D7) ages it out via its own 24h in-window parse-check.
        ResetUtc              = (ConvertTo-XdrUtcString $resetUtcToWrite)   # canonicalised like every datetime field ('' / unparseable pass through)
        ResetReasonAnnotation = $resetReasonToWrite                        # opaque annotation — NOT a datetime · carried verbatim
    }

    # First-ever write (no prior ETag): send NO If-Match header → Azure Tables "Insert Or Replace Entity"
    # (upsert). Using If-Match:* here was a BUG — that is "Update Entity" semantics, which 404s on a
    # non-existent entity. LIVE 2026-06-04: the first checkpoint write 404'd every cycle → cursor never
    # persisted → every cycle cold-started and re-ingested ALL rows (~10x duplication · plan §39.11).
    # A real prior ETag → conditional update (412 on a concurrent-cycle race · retried once below).
    $ifMatch = if ([string]::IsNullOrEmpty($ExistingETag)) { '' } else { $ExistingETag }

    # FH-7 · NEVER-throws contract. Set-XdrTableEntity (the first PUT below AND the 412-retry PUT) throws on a storage
    # network error / missing XDRLR_STORAGE_ACCOUNT (Storage.psm1:140/215), and Get-XdrCheckpoint (the 412 re-read) throws
    # after 3 failed reads (CheckpointReadFailLoud). UN-wrapped, such a throw on a storage blip escapes as if the SAVE
    # failed — but the caller already pushed rows to DCE this cycle, so it MISCLASSIFIES: cursor NOT advanced -> the rows
    # RE-INGEST next cycle (a silent cross-cycle DUPLICATE) + the breaker spuriously trips. The contract is $false on ANY
    # failure, never throw (the caller leaves the cursor untouched and telemetry records Checkpoint.Advance.RaceLost).
    try {
        $resp = Set-XdrTableEntity -TableName 'XdrCheckpoint' -PartitionKey $PartitionKey -RowKey $OperationKey -Properties $props -IfMatchETag $ifMatch
        if ($resp.Success) { return $true }

        # 412 Precondition Failed → race lost. Retry once with fresh ETag.
        if ($resp.StatusCode -eq 412) {
            $fresh = Get-XdrCheckpoint -PartitionKey $PartitionKey -OperationKey $OperationKey
            $freshETag = if ($fresh -and $fresh['ETag']) { $fresh['ETag'] } else { '*' }   # null-safe (cold/absent re-read)
            $resp2 = Set-XdrTableEntity -TableName 'XdrCheckpoint' -PartitionKey $PartitionKey -RowKey $OperationKey -Properties $props -IfMatchETag $freshETag
            if ($resp2.Success) { return $true }
            Write-Warning "[Runtime] Save-XdrCheckpointAtomic lost race twice · OperationKey=$OperationKey · status=$($resp2.StatusCode)"
            return $false
        }

        Write-Warning "[Runtime] Save-XdrCheckpointAtomic failed · OperationKey=$OperationKey · status=$($resp.StatusCode) · $($resp.Error)"
        return $false
    } catch {
        # Storage-layer throw (transient network / missing-SA on a PUT, or the loud 412 re-read) -> honor the contract:
        # return $false so the caller leaves the cursor unadvanced (safe re-poll), instead of faulting/misclassifying.
        # HARDENING (mega-audit 2026-06-23 · the Azure-Tables 2s partition-timeout class): a TRANSIENT throw is retryable —
        # mirror the read-side bounded backoff (Get-XdrCheckpoint 3×@200ms·attempt) so a single table-timeout advances the
        # cursor IN-CYCLE instead of deferring a whole cadence (a wasted re-poll). Still FH-7: $false only AFTER retries.
        $exMsg = $_.Exception.Message
        if ($exMsg -match 'timeout|timed out|OperationTimedOut|ServerBusy|temporarily|\b50[0-3]\b') {
            for ($wr = 1; $wr -le 2; $wr++) {
                Start-Sleep -Milliseconds (200 * $wr)
                try {
                    $rResp = Set-XdrTableEntity -TableName 'XdrCheckpoint' -PartitionKey $PartitionKey -RowKey $OperationKey -Properties $props -IfMatchETag $ifMatch
                    if ($rResp.Success) { return $true }
                    if ($rResp.StatusCode -eq 412) { break }   # a concurrent cycle won the race · fall through to $false (next cadence re-reads cleanly)
                } catch { continue }                            # still transient within the bound · keep retrying
            }
        }
        Write-Warning "[Runtime] Save-XdrCheckpointAtomic threw (transient · storage I/O) · OperationKey=$OperationKey · $($_.Exception.Message) · returning `$false (never-throws contract · cursor NOT advanced after bounded retry)"
        return $false
    }
}

# WS3.1 · the Set-XdrCheckpoint backwards-compat shim was REMOVED (operator no-compat directive · zero callers ·
# it also dropped BoundaryKeys/Resume* on every write — the same wipe class fixed at the capability-absent touch).
# The canonical writer is Save-XdrCheckpointAtomic; the operator rewind is Save-XdrCheckpointReset.

# ─── Save-XdrCheckpointReset · per plan §4.20 + §8.7 ──────────────────────────
# Forced rewind · NOT a cursor-advance.
#
# Trigger conditions (any of):
#   1. Op transitions Stub → Validated (first ever validated)
#   2. Op's ProjectionMap adds new fields (cursor pre-change wouldn't have captured them)
#   3. Op's TimeFilter FieldName changes (different cursor field)
#   4. Op's IngestionMode changes (CURSOR ↔ WINDOW ↔ SNAPSHOT)
#   5. Operator manual reset (diagnostic · via Override-XdrSync.ps1 -ResetCursor)
#
# Invariant: reset NEVER advances cursor · always rewinds. The unconditional Insert-Or-Replace
# (IfMatchETag='*') is intentional: a cycle's ETag-conditional write that loses the race re-reads
# fresh state · sees the reset · advances from there. Operator intent always wins.
#
# Sets LastUpdatedUtc = $null so the G-Cadence gate (plan §4.18) treats it as first-cycle-ever ·
# next TimerTrigger fires this Op immediately regardless of cadence.
# Column names match Save-XdrCheckpointAtomic canonical schema (LastUpdatedUtc + LastItemCount).
function Save-XdrCheckpointReset {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $PartitionKey,
        [Parameter(Mandatory)] [string] $OperationKey,
        [Parameter(Mandatory)] [ValidateSet('first-validate','schema-change','timefilter-change','ingestionmode-change','operator-override')] [string] $Reason,
        [string] $CorrelationId = ''
    )

    if (-not $CorrelationId) { $CorrelationId = [Guid]::NewGuid().ToString() }
    $nowUtc = [DateTime]::UtcNow

    $props = @{
        Cursor                = ''
        WindowStartUtc        = ''
        WindowEndUtc          = ''
        LastUpdatedUtc        = ''   # empty string · treated as "absent" by G-Cadence (cadence not enforced for next cycle)
        LastItemCount         = 0
        CorrelationId         = $CorrelationId
        ResetReasonAnnotation = $Reason
        ResetUtc              = $nowUtc.ToString('o')
        SchemaVersion         = 1
    }

    if (-not (Get-Command Set-XdrTableEntity -ErrorAction SilentlyContinue)) {
        Write-Warning "[Runtime] Save-XdrCheckpointReset · Xdr.Common.Storage not loaded · cannot write reset row"
        return $false
    }

    # Unconditional Insert-Or-Replace · IfMatchETag='*' means "succeed regardless of current state"
    $resp = Set-XdrTableEntity -TableName 'XdrCheckpoint' `
        -PartitionKey $PartitionKey -RowKey $OperationKey `
        -Properties $props -IfMatchETag '*'

    if ($resp.Success) {
        if (Get-Command Track-XdrEvent -ErrorAction SilentlyContinue) {
            Track-XdrEvent -Name 'Checkpoint.Reset' -Properties @{
                PartitionKey          = $PartitionKey
                OperationKey          = $OperationKey
                ResetReasonAnnotation = $Reason
                CorrelationId         = $CorrelationId
                ResetUtc              = $nowUtc.ToString('o')
            }
        }
        Write-Host "[Runtime] Save-XdrCheckpointReset · OperationKey=$OperationKey · reason=$Reason · CorrelationId=$CorrelationId"
        return $true
    }

    Write-Warning "[Runtime] Save-XdrCheckpointReset FAILED · OperationKey=$OperationKey · status=$($resp.StatusCode) · $($resp.Error)"
    return $false
}

# ─── Circuit breaker (F6) · per-Op · StateStore XdrCircuitState · PartitionKey=Portal_Category · RowKey=OperationKey ──
# Opens after N consecutive failures so a persistently-failing Op stops hammering the portal + burning DCE quota;
# auto half-opens after a cooldown (one trial cycle); closes on the first success. Plan §4.3 + F6 (§31.3 · was
# provisioned-but-unimplemented · the recovery/Verify D10 gates were vacuous until now).
$script:XdrBreakerFailureThreshold = 5
$script:XdrBreakerCooldownMinutes  = 15

function Get-XdrCircuitState {
    <# .SYNOPSIS Read per-Op breaker state. Returns @{ State; FailureCount; OpenedUtc; ETag }. Defaults Closed/0. #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$PartitionKey, [Parameter(Mandatory)][string]$OperationKey)
    $default = @{ State = 'Closed'; FailureCount = 0; OpenedUtc = $null; ETag = $null }
    try {
        $r = Get-XdrTableEntity -TableName 'XdrCircuitState' -PartitionKey $PartitionKey -RowKey $OperationKey
        if (-not $r.Found) { return $default }
        $row = $r.Entity   # -AsHashtable entity · indexer reads (StrictMode-safe · a column may be absent)
        return @{
            State        = if ($row['State']) { [string]$row['State'] } else { 'Closed' }
            FailureCount = if ($row['FailureCount']) { [int]$row['FailureCount'] } else { 0 }
            OpenedUtc    = $row['OpenedUtc']
            ETag         = $r.ETag
        }
    } catch {
        # §4.B B11: emit the fail-open as a gateable event (alongside the warning) so the breaker-read
        # "treat as Closed" fallback is visible to gating. OperationKey is in scope here. Guarded like above.
        Write-Warning "[Runtime] Get-XdrCircuitState failed: $($_.Exception.Message)"
        if (Get-Command Track-XdrEvent -ErrorAction SilentlyContinue) { Track-XdrEvent -Name 'Entry.FailOpen' -Properties @{ GateName = 'BreakerRead'; OperationKey = $OperationKey } }
        return $default   # INTENTIONAL-FAIL-SAFE: breaker-read error → treat as Closed (fail-open · a state-store blip must not block polling)
    }
}

function Test-XdrCircuitClosed {
    <# .SYNOPSIS $true if the Op MAY run. Closed/HalfOpen → yes. Open → yes only once the cooldown elapsed (half-open trial). #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][hashtable]$CircuitState)
    if ([string]$CircuitState['State'] -ne 'Open') { return $true }
    $openedUtc = $CircuitState['OpenedUtc']
    if (-not $openedUtc) { return $true }
    try {
        $opened = (ConvertTo-XdrUtc $openedUtc)
        return ([DateTime]::UtcNow - $opened).TotalMinutes -ge $script:XdrBreakerCooldownMinutes
    } catch {
        return $true   # INTENTIONAL-FAIL-SAFE: unparseable OpenedUtc → allow (never wedge an Op permanently)
    }
}

function Update-XdrCircuitState {
    <# .SYNOPSIS On success → Closed/0. On failure → increment; at threshold → Open. Emits Breaker.Opened/Closed. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PartitionKey,
        [Parameter(Mandatory)][string]$OperationKey,
        [Parameter(Mandatory)][bool]$Success,
        [hashtable]$CircuitState = @{},
        [string]$CorrelationId = ''
    )
    if (-not (Get-Command Set-XdrTableEntity -ErrorAction SilentlyContinue)) { return }
    $prevState = if ($CircuitState['State']) { [string]$CircuitState['State'] } else { 'Closed' }
    $prevCount = if ($CircuitState['FailureCount']) { [int]$CircuitState['FailureCount'] } else { 0 }
    $nowIso = [DateTime]::UtcNow.ToString('o')

    if ($Success) {
        # Close on any success (incl the half-open trial). Only write when state actually changes (avoid churn).
        if ($prevState -ne 'Closed' -or $prevCount -gt 0) {
            $null = Set-XdrTableEntity -TableName 'XdrCircuitState' -PartitionKey $PartitionKey -RowKey $OperationKey `
                -Properties @{ State = 'Closed'; FailureCount = 0; OpenedUtc = ''; LastUpdatedUtc = $nowIso } -IfMatchETag '*'
            if ($prevState -eq 'Open' -and (Get-Command Track-XdrEvent -ErrorAction SilentlyContinue)) {
                Track-XdrEvent -Name 'Breaker.Closed' -Properties @{ OperationKey = $OperationKey; CorrelationId = $CorrelationId }
            }
        }
    } else {
        $newCount  = $prevCount + 1
        $newState  = if ($newCount -ge $script:XdrBreakerFailureThreshold) { 'Open' } else { $prevState }
        # CR1 (audit 2026-06-12): RE-STAMP OpenedUtc=now on EVERY Open-failure. A failure while Open can only be a
        # half-open TRIAL that ran (Test-XdrCircuitClosed gates running until the cooldown elapsed) → the trial failed
        # → the cooldown MUST restart, else the breaker stays permanently half-open (re-trialling every cycle = 1,440
        # failing portal hits/day). The old "keep the original OpenedUtc" defeated the cooldown after its first elapse.
        $openedUtc = if ($newState -eq 'Open') { $nowIso } else { '' }
        $null = Set-XdrTableEntity -TableName 'XdrCircuitState' -PartitionKey $PartitionKey -RowKey $OperationKey `
            -Properties @{ State = $newState; FailureCount = $newCount; OpenedUtc = $openedUtc; LastUpdatedUtc = $nowIso } -IfMatchETag '*'
        if ($newState -eq 'Open' -and $prevState -ne 'Open' -and (Get-Command Track-XdrEvent -ErrorAction SilentlyContinue)) {
            Track-XdrEvent -Name 'Breaker.Opened' -Properties @{ OperationKey = $OperationKey; CorrelationId = $CorrelationId; FailureCount = $newCount }
        }
    }
}

# ─── Request builder · clean contract · drives URL (query) AND body from ONE classifier ───────
# Get-XdrRequestParams is the single source: it classifies every paging/time param by ParamLocation
# ('query'|'body') so POST-read body-paging and GET query-paging share one code path. No legacy field-name
# fallbacks — the manifest is generated from the catalogue against THIS contract; correctness is proven by the
# regenerated replay test, not by dual-support. Modes: pageSize · pageIndex(1-based) · skipTop · cursor-token ·
# nextLink-absolute (a full-URL cursor IS the next request) · ServerOData ($filter) · ServerFromDate (From/To).
function script:Format-XdrTimeValue {
    <#
    .SYNOPSIS
    T3d (audit 2026-06-12) · ONE generic time-value formatter for every server wire shape in the corpus. The old
    builder emitted ISO 'o' unconditionally — an epoch op (integer startTime/endTime · epoch-ms-in-path) got an ISO
    string the API rejects, and the live OData filter shape needs ms-precision. The TimeFilter.ValueFormat contract
    field selects the shape; absent/unknown → full-fidelity ISO 'o' (back-compat + fail-safe). Value routes through
    ConvertTo-XdrUtc (invariant · assume-UTC for naive); an unparseable value returns verbatim (never destroy data).
    Formats: ''/Iso8601Z (o) · Iso8601ZMillis (...000Z) · Iso8601DateOnly (yyyy-MM-dd) · EpochSeconds · EpochMillis.
    #>
    param([Parameter(Mandatory)] $Value, [string]$Format = '')
    $utc = ConvertTo-XdrUtc $Value
    if ($null -eq $utc) { return [string]$Value }   # INTENTIONAL-FAIL-SAFE: unparseable → verbatim
    switch (($Format ?? '').Trim()) {
        'Iso8601ZMillis'  { return $utc.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [System.Globalization.CultureInfo]::InvariantCulture) }
        'Iso8601DateOnly' { return $utc.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) }
        'EpochSeconds'    { return [string][System.DateTimeOffset]::new($utc, [TimeSpan]::Zero).ToUnixTimeSeconds() }
        'EpochMillis'     { return [string][System.DateTimeOffset]::new($utc, [TimeSpan]::Zero).ToUnixTimeMilliseconds() }
        default           { return $utc.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture) }
    }
}

function Get-XdrRequestParams {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [hashtable] $Entry,
        [hashtable] $Window = @{},
        [string]    $Cursor = '',
        [int]       $Page = 1
    )
    $r = @{ Query = @{}; Body = @{}; Path = @{}; UrlOverride = $null; RelativeNextLink = $null }
    # nextLink-absolute · an OData @odata.nextLink cursor is a full URL → it IS the next request verbatim.
    # SSRF GUARD: this URL is fetched with the live portal session cookies, so it MUST be constrained to the
    # Microsoft portal domains (a corrupted/malicious response could otherwise aim the authenticated client at
    # an arbitrary host). Require https + a *.microsoft.com host; anything else is a terminal anomaly.
    if ($Cursor -and ($Cursor -match '^https?://')) {
        $u = $null
        if (-not [Uri]::TryCreate([string]$Cursor, [UriKind]::Absolute, [ref]$u) -or
            $u.Scheme -ne 'https' -or
            ($u.Host -ne 'microsoft.com' -and -not $u.Host.EndsWith('.microsoft.com'))) {
            $badHost = if ($u) { $u.Host } else { '<unparseable>' }
            throw (New-XdrException -Type Parser -Message "nextLink cursor rejected (SSRF guard · host '$badHost' not https://*.microsoft.com)" -Properties @{ ViolationType = 'SSRF.NextLinkHost'; Host = $badHost })
        }
        $r.UrlOverride = [string]$Cursor; return $r
    }
    # nextLink-relative · a RELATIVE continuation token ('?...' query-rel · '/...' path-rel · the Attack-Simulator
    # live shape `?$skiptoken=...`) is composed against the request base by New-XdrRequestUrl (it stays on the portal
    # host, so there is no SSRF surface). Signalled here — NOT emitted as a CursorQuery param — and short-circuits the
    # rest exactly like the absolute path, because the token fully encodes the next page.
    if ($Cursor -and ($Cursor -match '^[?/]')) { $r.RelativeNextLink = [string]$Cursor; return $r }

    $specs = [System.Collections.Generic.List[hashtable]]::new()

    # ── TimeFilter (mode-branched · client modes emit NOTHING · server modes emit a real predicate) ──
    # T3d · every server value is shaped by Format-XdrTimeValue per TimeFilter.ValueFormat (default ISO 'o' —
    # back-compat exact). ServerOData supports OuterFormat='ParenOData' (the live `(date ge ...000Z)` filter shape).
    # ServerRelative emits a rolling-window integer (daysToLookBack family) derived from LookbackHours — no absolute
    # window param exists for those APIs. ParamLocation extends to 'path' (epoch-in-path ops · substituted by
    # New-XdrRequestUrl). All contract-driven: an op of ANY corpus time-mode is served by manifest DATA alone.
    $tf = $Entry['TimeFilter']
    if ($tf -is [System.Collections.IDictionary]) {
        $tfMode = if ($tf['Mode']) { [string]$tf['Mode'] } else { 'None' }
        $tfLoc  = if ($tf['ParamLocation']) { [string]$tf['ParamLocation'] } else { 'query' }
        $tfFmt  = if ($tf['ValueFormat']) { [string]$tf['ValueFormat'] } else { '' }
        if ($tfMode -eq 'ServerRelative') {
            if ($tf['RelativeParam']) {
                $lbHours = if ($Entry['LookbackHours']) { [int]$Entry['LookbackHours'] } else { 24 }
                $relV = if ($tfFmt -eq 'RelativeHours') { [string]$lbHours } else { [string][int][Math]::Ceiling($lbHours / 24.0) }
                $specs.Add(@{ N = [string]$tf['RelativeParam']; V = $relV; L = $tfLoc })
            }
        }
        elseif ($tfMode -notin @('ClientSideHighWater','None') -and $Window -and $Window['StartUtc'] -and $tf['FieldName']) {
            $startV = Format-XdrTimeValue -Value $Window['StartUtc'] -Format $tfFmt
            switch ($tfMode) {
                'ServerOData'    { $op = if ($tf['Operator']) { [string]$tf['Operator'] } else { 'ge' }
                                   $pred = "$([string]$tf['FieldName']) $op $startV"
                                   if ([string]$tf['OuterFormat'] -eq 'ParenOData') { $pred = "($pred)" }
                                   $filterP = if ($tf['FilterParam']) { [string]$tf['FilterParam'] } else { '$filter' }
                                   $specs.Add(@{ N = $filterP; V = $pred; L = $tfLoc }) }
                'ServerFromDate' { $fromP = if ($tf['FromDateParam']) { [string]$tf['FromDateParam'] } else { [string]$tf['FieldName'] }
                                   $specs.Add(@{ N = $fromP; V = $startV; L = $tfLoc })
                                   if ($tf['ToDateParam'] -and $Window['EndUtc']) { $specs.Add(@{ N = [string]$tf['ToDateParam']; V = (Format-XdrTimeValue -Value $Window['EndUtc'] -Format $tfFmt); L = $tfLoc }) } }
            }
        }
    }

    # ── Pagination (pageSize · pageIndex 1-based · skipTop · cursor-token · sort · by ParamLocation) ──
    $pg = $Entry['Pagination']
    if ($pg -is [System.Collections.IDictionary]) {
        $pgLoc = if ($pg['ParamLocation']) { [string]$pg['ParamLocation'] } else { 'query' }
        if ($pg['PageSizeQuery'] -and $null -ne $pg['PageSize']) { $specs.Add(@{ N = [string]$pg['PageSizeQuery']; V = [string]$pg['PageSize']; L = $pgLoc }) }
        if ($pg['PageIndexQuery']) {
            $pis = if ($null -ne $pg['PageIndexStart']) { [int]$pg['PageIndexStart'] } else { 0 }
            $specs.Add(@{ N = [string]$pg['PageIndexQuery']; V = [string](($Page - 1) + $pis); L = $pgLoc })
        }
        if ($pg['SkipQuery'] -and $pg['TopQuery']) {
            $top = if ($null -ne $pg['PageSize']) { [int]$pg['PageSize'] } else { 50 }
            $specs.Add(@{ N = [string]$pg['SkipQuery']; V = [string](($Page - 1) * $top); L = $pgLoc })
            $specs.Add(@{ N = [string]$pg['TopQuery'];  V = [string]$top; L = $pgLoc })
        }
        if ($Cursor -and $pg['CursorQuery']) { $specs.Add(@{ N = [string]$pg['CursorQuery']; V = [string]$Cursor; L = $pgLoc }) }
        if ($pg['SortByQuery'] -and $pg['SortByField'])  { $specs.Add(@{ N = [string]$pg['SortByQuery'];  V = [string]$pg['SortByField']; L = $pgLoc }) }
        if ($pg['SortOrderQuery'] -and $pg['SortOrder']) { $specs.Add(@{ N = [string]$pg['SortOrderQuery']; V = [string]$pg['SortOrder']; L = $pgLoc }) }
    }

    foreach ($s in $specs) {
        switch ($s['L']) {
            'body' { $r.Body[$s['N']] = $s['V'] }
            'path' { $r.Path[$s['N']] = $s['V'] }   # T3d · substituted into {tokens} by New-XdrRequestUrl
            default { $r.Query[$s['N']] = $s['V'] }
        }
    }
    return $r
}

# Build the POST-read body: clone BodyTemplate (parse if JSON string) + merge body-located paging/time params.
# Returns $null when there is no template and no body params (GET / query-only op) — identical to the prior path.
function New-XdrRequestBody {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Entry,
        [hashtable] $Window = @{},
        [string]    $Cursor = '',
        [int]       $Page = 1
    )
    $rp = Get-XdrRequestParams -Entry $Entry -Window $Window -Cursor $Cursor -Page $Page
    $tmpl = $Entry['BodyTemplate']
    if (($null -eq $tmpl) -and $rp['Body'].Count -eq 0) { return $null }
    $body = @{}
    if ($tmpl -is [System.Collections.IDictionary]) {
        foreach ($k in $tmpl.Keys) { $body[$k] = $tmpl[$k] }
    } elseif (($tmpl -is [string]) -and -not [string]::IsNullOrWhiteSpace($tmpl)) {
        try {
            $parsed = $tmpl | ConvertFrom-Json -AsHashtable -Depth 25
            if ($parsed -is [System.Collections.IDictionary]) { foreach ($k in $parsed.Keys) { $body[$k] = $parsed[$k] } }
        } catch { $body = @{} }   # INTENTIONAL-FAIL-SAFE: unparseable template → start empty + merge params
    }
    foreach ($k in $rp['Body'].Keys) { $body[$k] = $rp['Body'][$k] }
    return $body
}

# ─── URL builder · portal base + path-token substitution + query from the classifier ──────────
# ── F1.4 (operator 2026-06-14 · multi-portal v0.1.0) · PORTAL REGISTRY · the keystone that de-Defender-izes transport
# /dispatch: onboarding a portal = a registry row (+ its catalogue DATA), ZERO engine edits. New-XdrRequestUrl resolves
# base+grammar here; the dispatch partition prefix + the Capabilities probe/product map read PartitionPrefix/AuthMode
# (wired incrementally · F1.4c/d). Defender's row reproduces the prior hardcoded switch value EXACTLY → the pilot URL is
# byte-identical (regen/replay stable). UrlGrammar: ApiProxy = <BaseUrl>/apiproxy (the Defender-family workload router ·
# all 5 portals today); DirectHost = <BaseUrl> verbatim (SharePoint _api · SecurityCopilot pod-host · the non-apiproxy
# expansion grammars). AuthMode: Cookie (sccauth+XSRF · Defender/Purview) | Bearer (AccessToken · Entra/Intune/SecCop ·
# the transport wire branch = F1.4b).
# ProbeEndpoint folded in (P2 single-SoT consolidation 2026-06-14): the registry is now the ONE portal-config source —
# transport (BaseUrl/UrlGrammar/AuthMode) + dispatch (PartitionPrefix) + capability discovery (ProbeEndpoint, the
# tenant-context probe, read by Xdr.Common.Capabilities via Get-XdrPortalConfig). Onboarding a portal = ONE registry row.
$script:XdrPortalRegistry = @{
    Defender        = @{ BaseUrl = 'https://security.microsoft.com';        UrlGrammar = 'ApiProxy'; AuthMode = 'Cookie'; PartitionPrefix = 'Defender';        ProbeEndpoint = @{ SubPortal = 'mtp';    Path = '/sccManagement/mgmt/TenantContext'; Method = 'GET' } }
    Entra           = @{ BaseUrl = 'https://entra.microsoft.com';           UrlGrammar = 'ApiProxy'; AuthMode = 'Bearer'; PartitionPrefix = 'Entra';           ProbeEndpoint = @{ SubPortal = 'iam';    Path = '/Directories/Properties'; Method = 'GET' } }
    Intune          = @{ BaseUrl = 'https://intune.microsoft.com';          UrlGrammar = 'ApiProxy'; AuthMode = 'Bearer'; PartitionPrefix = 'Intune';          ProbeEndpoint = @{ SubPortal = 'portal'; Path = '/configuration/tenant'; Method = 'GET' } }
    Purview         = @{ BaseUrl = 'https://purview.microsoft.com';         UrlGrammar = 'ApiProxy'; AuthMode = 'Cookie'; PartitionPrefix = 'Purview';         ProbeEndpoint = @{ SubPortal = 'mtp';    Path = '/configuration/tenantContext'; Method = 'GET' } }
    SecurityCopilot = @{ BaseUrl = 'https://securitycopilot.microsoft.com'; UrlGrammar = 'ApiProxy'; AuthMode = 'Bearer'; PartitionPrefix = 'SecurityCopilot'; ProbeEndpoint = @{ SubPortal = 'api';    Path = '/tenant/me'; Method = 'GET' } }
}
function Get-XdrPortalConfig {   # EXPORTED · the single portal-config SoT reader (Runtime + Capabilities both consume it)
    param([Parameter(Mandatory)][string]$Portal)
    if ($script:XdrPortalRegistry.ContainsKey($Portal)) { return $script:XdrPortalRegistry[$Portal] }
    throw "Unknown Portal '$Portal' · not in the Portal Registry (onboard a portal by adding a registry row — DATA, not an engine edit)"
}
function script:Get-XdrPortalBaseUrl {
    param([Parameter(Mandatory)][hashtable]$Config)
    switch ([string]$Config['UrlGrammar']) {
        'ApiProxy'   { return "$([string]$Config['BaseUrl'])/apiproxy" }
        'DirectHost' { return [string]$Config['BaseUrl'] }
        default      { return "$([string]$Config['BaseUrl'])/apiproxy" }   # INTENTIONAL-FAIL-SAFE: unknown grammar → apiproxy
    }
}

function New-XdrRequestUrl {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [hashtable] $Entry,
        [hashtable] $Window = @{},
        [string]    $Cursor = '',
        [int]       $Page = 1
    )

    # Indexer reads (StrictMode-safe) · the manifest mixes flat keys with NESTED TimeFilter/Pagination blocks.
    # F1.4 · base+grammar resolve through the Portal Registry (Defender row = the prior literal → byte-identical).
    $portal = if ($Entry['Portal']) { [string]$Entry['Portal'] } else { 'Defender' }
    $portalBase = Get-XdrPortalBaseUrl -Config (Get-XdrPortalConfig -Portal $portal)
    $subPortal = if ($Entry['SubPortal']) { [string]$Entry['SubPortal'] } else { 'mtp' }
    $path = [string]$Entry['Path']
    # Path-token substitution · {TenantId} from R3 tenant context (seeded on the entry by the dispatcher).
    if ($path -match '\{TenantId\}' -and $Entry['TenantId']) { $path = $path -replace '\{TenantId\}', [string]$Entry['TenantId'] }
    # Entity-token substitution (plan §16 U3b · parent→child fan-out) · Invoke-XdrEntityFanout seeds an EntityParams
    # map @{ '<ParamName>' = '<id>' } on the child entry; substitute each {param}→its resolved id. Kept GENERIC (any
    # param name · NOT just TenantId) so the SAME builder serves GetHistory (no EntityParams → byte-identical) and a
    # fanned-out child ({CaseId}/{DeviceId}/{MachineId}). The id is URL-encoded — an entity id can carry reserved
    # characters (e.g. an Sha256 or a path-shaped resource id) that would otherwise break the request path.
    $entityParams = $Entry['EntityParams']
    if ($entityParams -is [System.Collections.IDictionary]) {
        foreach ($pn in @($entityParams.Keys)) {
            $pv = $entityParams[$pn]
            if ($null -ne $pv -and -not [string]::IsNullOrEmpty([string]$pv)) {
                $path = $path -replace ('\{' + [regex]::Escape([string]$pn) + '\}'), [uri]::EscapeDataString([string]$pv)
            }
        }
    }

    $rp = Get-XdrRequestParams -Entry $Entry -Window $Window -Cursor $Cursor -Page $Page
    if ($rp['UrlOverride']) { return [string]$rp['UrlOverride'] }   # nextLink-absolute (full-URL cursor)

    # T3d · path-located time params (ParamLocation='path' · the epoch-in-path ops): substitute each {param} with
    # its formatted value — the SAME generic token substitution as entity params, fed from the request classifier.
    $rpPath = $rp['Path']
    if (($rpPath -is [System.Collections.IDictionary]) -and $rpPath.Count -gt 0) {
        foreach ($pn in @($rpPath.Keys)) {
            $path = $path -replace ('\{' + [regex]::Escape([string]$pn) + '\}'), [uri]::EscapeDataString([string]$rpPath[$pn])
        }
    }

    $url = "$portalBase/$subPortal$path"
    # nextLink-relative · compose the relative continuation token against the request base. Query-relative ('?...')
    # → base path + the token's query; path-relative ('/...') → portal scheme+host + the path. Both stay on the
    # portal host (no SSRF surface · cf. the absolute path's *.microsoft.com guard).
    if ($rp['RelativeNextLink']) {
        $rel = [string]$rp['RelativeNextLink']
        if ($rel.StartsWith('?')) { return $url + $rel }
        $root = [Uri]::new($portalBase)
        return "$($root.Scheme)://$($root.Host)$rel"
    }
    $params = $rp['Query']
    if ($params.Count -gt 0) {
        $qs = ($params.GetEnumerator() | ForEach-Object { "$([uri]::EscapeDataString($_.Key))=$([uri]::EscapeDataString([string]$_.Value))" }) -join '&'
        $url += ($url -match '\?') ? "&$qs" : "?$qs"
    }
    return $url
}

function Resolve-XdrTimeWindow {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [hashtable] $Entry,
        [Parameter(Mandatory)] [hashtable] $Checkpoint
    )

    $now = [DateTime]::UtcNow
    # HighWaterUtc = exact cross-cycle boundary for CLIENT-SIDE dedup (plan §35.2). For ClientSideHighWater
    # endpoints StartUtc is NOT sent to the server (no server time filter); HighWaterUtc drives the in-connector
    # drop of already-ingested rows. $null on cold start → ingest everything.
    $window = @{ StartUtc = $null; EndUtc = $now.ToString('o'); Exhausted = $false; HighWaterUtc = $null }

    # Indexer reads (StrictMode-safe) · $Checkpoint may be an empty hashtable, $Entry lacks LookbackHours.
    $ingestionMode = [string]$Entry['IngestionMode']
    $cpCursor      = if ($Checkpoint) { $Checkpoint['Cursor'] } else { $null }
    $cpWindowEnd   = if ($Checkpoint) { $Checkpoint['WindowEndUtc'] } else { $null }
    # §4.B FIX-1b · SANE-LOOKBACK FLOOR. A WINDOW/CURSOR cold-start window is now - LookbackHours; if LookbackHours is
    # absent OR present-but-non-positive (a malformed manifest value: 0, negative, or a non-numeric string that [int]
    # coerces to 0), the naive `if ($Entry['LookbackHours'])` truthy-test let it through as <= 0 → now.AddHours(0)/future
    # = a ~now→now EMPTY window (0 rows that are merely window-too-narrow, not genuinely absent · the GMTE 0-events class).
    # Parse defensively and FLOOR to the 24h default so NO WINDOW op can ever silently resolve a trivial/empty lookback.
    $lbDefault = 24
    $lbParsed  = 0
    $lookback  = if ([int]::TryParse([string]$Entry['LookbackHours'], [ref]$lbParsed) -and $lbParsed -gt 0) { $lbParsed } else { $lbDefault }
    switch ($ingestionMode) {
        'SNAPSHOT' {
            # Current-state poll · no time filter · one cycle drains all.
            $window.StartUtc = $null
            $window.EndUtc   = $null
            $window.Exhausted = $false
        }
        'CURSOR' {
            # Cross-cycle continuation = the EXACT high-water of the cursor field (max EventTime) persisted last
            # cycle. NO rewind (plan §35.2 · supersedes the prior -5min overlap, which manufactured duplicates at
            # every boundary). Exactly-once is achieved by HighWaterUtc + the boundary natural-key set, both applied
            # CLIENT-SIDE in Invoke-XdrEntryPoll — NOT by a DCR dedup. Cold start (no checkpoint) → lookback window,
            # HighWaterUtc=$null (ingest all). Unparseable cursor → safe lookback, HighWaterUtc stays $null.
            if ($cpCursor) {
                try   { $hw = (ConvertTo-XdrUtc $cpCursor); $window.HighWaterUtc = $hw.ToString('o'); $window.StartUtc = $hw.ToString('o') }
                catch { $window.StartUtc = $now.AddHours(-1 * $lookback).ToString('o') }  # INTENTIONAL-FAIL-SAFE: unparseable cursor → safe lookback (no client drop)
            } else {
                $window.StartUtc = $now.AddHours(-1 * $lookback).ToString('o')
            }
        }
        'WINDOW' {
            # Explicit start-end · checkpoint stores last-end · NO rewind (plan §35.2 · the prior -5min overlap
            # manufactured boundary duplicates). Exactly-once = window bounds + boundary natural-key dedup (as CURSOR).
            # F-WINDOW-EXCLUSIVE (CORE-2 · 2026-07-07 · SSOT A5 WINDOW contract) · the server window [StartUtc, now] is
            # INCLUSIVE-INCLUSIVE and StartUtc == last cycle's WindowEndUtc, so an event sitting EXACTLY at the prior
            # window end is re-served EVERY poll = a guaranteed server-side boundary dup. For a WINDOW op WITHOUT a
            # response-row CursorField + NaturalKey (e.g. GetMachineTimelineEvents · the events carry ActionTime, not
            # the 'fromDate' query param) NO client-side boundary key can drop it → the overlapping-window boundary
            # events re-ingest every poll (the live ~4.8x dup-accumulation). FIX: on a RESUME cycle advance the low-bound
            # EXCLUSIVELY — one tick past the prior committed WindowEndUtc — so the boundary instant (already fully
            # covered by the prior inclusive [.., toDate] window) is NOT re-fetched. Generic to ALL WINDOW ops. The 168h
            # COLD backfill is UNTOUCHED: the exclusive nudge only applies when resuming from a committed WindowEndUtc;
            # the cold-start (no $cpWindowEnd) still takes the full lookback window below. One tick is the minimal
            # exclusive delta (the corpus windows are datetime-precise) and can never skip a genuinely-newer event
            # (those are strictly AFTER the prior end · already outside the prior window).
            if ($cpWindowEnd) {
                $prevEnd = (ConvertTo-XdrUtc $cpWindowEnd)
                # Exclusive resume low-bound: prior end + 1 tick (100 ns). Guard against a future-skewed checkpoint end
                # advancing past now (→ an empty/inverted window) by clamping to now.
                $exclusiveStart = $prevEnd.AddTicks(1)
                if ($exclusiveStart -gt $now) { $exclusiveStart = $now }
                $window.StartUtc = $exclusiveStart.ToString('o')
            } else {
                $window.StartUtc = $now.AddHours(-1 * $lookback).ToString('o')
            }
            # T3b (audit 2026-06-12) · WIRE the boundary dedup this branch always PROMISED but never delivered. Set
            # HighWaterUtc = StartUtc → the SAME client-side boundary-key dedup as CURSOR drops a boundary tie whose
            # natural key was already ingested and keeps a provably-new same-instant row (for a WINDOW op that DOES carry
            # a CursorField + NaturalKey · e.g. the WindowBoundaryExactlyOnce corpus). For a keyless/cursorless WINDOW op
            # the exclusive low-bound above (server-side) is what prevents the boundary re-serve, and the cross-poll
            # SNAPSHOT-signature dedup (Select-XdrExactlyOnceRows) collapses an UNCHANGED whole window. Sent to the CLIENT
            # dedup only · NOT the server (the server bound is StartUtc itself, already exclusive on resume).
            $window.HighWaterUtc = $window.StartUtc
        }
        default {
            # G-K + U4 (NEVER-REFUSE): an unknown/missing IngestionMode must NOT silently full re-emit (SNAPSHOT
            # amplification) NOR refuse the op (throw). DEGRADE → poll a BOUNDED recent window (lookback) + warn LOUD:
            # the op stays FUNCTIONAL (gets recent data · no amplification · no drop) while the misconfig surfaces.
            Write-Warning "[Resolve-XdrTimeWindow] Unknown IngestionMode '$ingestionMode' for OperationKey '$([string]$Entry['OperationKey'])' — DEGRADING to a bounded WINDOW (expected CURSOR|WINDOW|SNAPSHOT · fix the manifest)"
            $window.StartUtc = $now.AddHours(-1 * $lookback).ToString('o')
            $window.EndUtc   = $now.ToString('o')
            # E-MAJ1 · MIRROR THE WINDOW BRANCH: set HighWaterUtc = StartUtc so client-side boundary dedup
            # (Select-XdrExactlyOnceRows) ACTUALLY RUNS on a degraded op. Without it HighWaterUtc stayed $null → the
            # dedup was skipped → an unknown/typo IngestionMode token = unbounded full re-emit every cycle with no client
            # dedup (the SecureScore-24,300-dup class). The bounded lookback window already caps the re-fetch; this caps
            # the re-INGEST (a boundary tie whose natural key was already ingested is dropped · a keyed op). And surface a
            # GATE-OBSERVABLE event (not only Write-Warning) so the hardened verifier can SEE the degradation in telemetry.
            $window.HighWaterUtc = $window.StartUtc
            if (Get-Command Track-XdrEvent -ErrorAction SilentlyContinue) {
                Track-XdrEvent -Name 'IngestionMode.Degraded' -Properties @{
                    OperationKey  = [string]$Entry['OperationKey']
                    IngestionMode = $ingestionMode
                    Portal        = if ($Entry['Portal']) { [string]$Entry['Portal'] } else { 'Defender' }
                    Category      = [string]$Entry['Category']
                    LookbackHours = $lookback
                }
            }
        }
    }
    return $window
}

function script:Resolve-XdrTotalCount {
    <#
    .SYNOPSIS
    G-J(a) · Read the server-reported TOTAL row count from a response at the manifest Pagination.TotalCountPath
    JSONPath (e.g. 'Count'). Returns an [int] when the path resolves to a non-negative integer, else $null.
    Indexer-safe dot-walk (same traversal as Get-XdrNextCursor's CursorPath · StrictMode-safe for both the
    -AsHashtable IDictionary body and a PSCustomObject body). Fail-safe: any miss / non-numeric value → $null.
    #>
    param($Response, [string]$Path)
    if (-not $Response -or [string]::IsNullOrWhiteSpace($Path)) { return $null }
    $p = $Path -replace '^\$\.?', ''
    if ([string]::IsNullOrWhiteSpace($p)) { return $null }
    $current = $Response
    foreach ($seg in ($p -split '\.')) {
        if ($null -eq $current) { return $null }
        if ($current -is [System.Collections.IDictionary]) {
            # IDictionary FIRST and EXCLUSIVELY · a hashtable exposes intrinsic PSObject members (.Count/.Keys/...)
            # so the PSObject fallback below would mis-resolve a MISSING 'Count' key to the dictionary's .Count
            # (the live TotalCountPath='Count' foot-gun). Only a real KEY counts; absent key → $null.
            if ($current.ContainsKey($seg)) { $current = $current[$seg] } else { return $null }
        }
        elseif ($current.PSObject -and $current.PSObject.Properties.Name -contains $seg) { $current = $current.$seg }
        else { return $null }
    }
    if ($null -eq $current) { return $null }
    $n = 0
    if ([int]::TryParse([string]$current, [ref]$n) -and $n -ge 0) { return $n }
    return $null
}

function script:Split-XdrJsonPath {
    <#
    .SYNOPSIS
    T3a (audit 2026-06-12) · Tokenize a JSONPath into segments, supporting BOTH dotted (`$.a.b`) AND bracket
    (`$['a.b']` / `$["a"]`) notation. Bracket notation lets a LITERAL response key that itself contains a dot — the
    OData `odata.nextLink` / `@odata.nextLink` continuation key (the Defender Attack-Simulator live shape) — be
    addressed as ONE segment; the old plain `-split '.'` split it (odata -> nextLink) and resolved to $null, so the
    token never extracted and the op silently single-paged (data loss). Strips the leading `$`. The single generic
    JSONPath splitter (cursor token + total-count traversal share it). Malformed bracket → stops fail-safe at what
    resolved so far.
    #>
    param([string]$Path)
    $segs = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($Path)) { return $segs }
    $s = $Path
    if ($s.StartsWith('$')) { $s = $s.Substring(1) }
    $i = 0
    while ($i -lt $s.Length) {
        $ch = $s[$i]
        if ($ch -eq '.') { $i++; continue }
        if ($ch -eq '[') {
            $close = $s.IndexOf(']', $i)
            if ($close -lt 0) { break }
            $inner = $s.Substring($i + 1, $close - $i - 1).Trim()
            if ($inner.Length -ge 2 -and (($inner.StartsWith("'") -and $inner.EndsWith("'")) -or ($inner.StartsWith('"') -and $inner.EndsWith('"')))) {
                $inner = $inner.Substring(1, $inner.Length - 2)
            }
            if ($inner) { $segs.Add($inner) }
            $i = $close + 1
        } else {
            $j = $i
            while ($j -lt $s.Length -and $s[$j] -ne '.' -and $s[$j] -ne '[') { $j++ }
            $seg = $s.Substring($i, $j - $i)
            if ($seg) { $segs.Add($seg) }
            $i = $j
        }
    }
    return $segs
}

function script:Get-XdrNextCursor {
    param($Response, [hashtable]$Entry, [int]$Page = 1, [int]$PageRowCount = 0)
    if (-not $Response) { return $null }
    $pg = $Entry['Pagination']
    $pgDict = if ($pg -is [System.Collections.IDictionary]) { $pg } else { $null }
    # Mode 1 · server-provided cursor token. CursorPath lives in the Pagination block (CONSOLIDATED — every pagination
    # contract field in ONE place, alongside CursorMode/CursorQuery); a legacy top-level Entry['CursorPath'] is honoured
    # as a fallback. Split-XdrJsonPath resolves a literal dotted response key (odata.nextLink) as a single segment.
    $cursorPath = if ($pgDict -and $pgDict['CursorPath']) { [string]$pgDict['CursorPath'] }
                  elseif ($Entry['CursorPath']) { [string]$Entry['CursorPath'] } else { '' }
    if ($cursorPath) {
        $current = $Response
        foreach ($seg in (Split-XdrJsonPath $cursorPath)) {
            if ($null -eq $current) { return $null }
            if ($current -is [System.Collections.IDictionary]) {
                if ($current.ContainsKey($seg)) { $current = $current[$seg] } else { return $null }
            }
            elseif ($current.PSObject -and $current.PSObject.Properties.Name -contains $seg) { $current = $current.$seg }
            else { return $null }
        }
        # An EMPTY token is a TERMINATOR, not a continuation. Two live-proven shapes: a bare ""/$null, AND a
        # URL-shaped cursor whose query carries ONLY EMPTY values — the Attack-Simulator last/empty page returns
        # odata.nextLink = "?$skiptoken=" (relative URL, empty token). Following it re-fetches the SAME page forever
        # (bounded only by the cycle budget · and a SNAPSHOT op would MULTIPLY rows — intra-cycle dedup is
        # CURSOR-only). A URL with at least one non-empty query value, or a path-only link, continues as-is.
        if ($current -is [string]) {
            if ([string]::IsNullOrWhiteSpace($current)) { return $null }
            if ($current -match '^([?/]|https?://)') {
                $qIdx = $current.IndexOf('?')
                if ($qIdx -ge 0) {
                    $hasValue = $false
                    foreach ($pair in ($current.Substring($qIdx + 1) -split '&')) {
                        $eq = $pair.IndexOf('=')
                        $v = if ($eq -ge 0) { $pair.Substring($eq + 1) } else { '' }
                        if (-not [string]::IsNullOrWhiteSpace($v)) { $hasValue = $true; break }
                    }
                    if (-not $hasValue) { return $null }
                }
            }
        }
        return $current
    }
    # Mode 2 · pageIndex-increment · Mode 3 · skipTop offset+limit. More pages while a FULL page returns
    # (PageRowCount >= PageSize); stop on the first short/empty page. New-XdrRequestUrl reads the incremented $Page.
    # skipTop keys on the SkipQuery+TopQuery pair (not CursorMode) to stay aligned with the URL builder — else it
    # under-fetches at page 1 (the loop would stop on a null cursor).
    if ($pgDict) {
        $mode = [string]$pgDict['CursorMode']
        $pageSize = if ($pgDict['PageSize']) { [int]$pgDict['PageSize'] } else { 0 }
        if (($mode -eq 'pageIndexIncrement' -or $mode -eq 'pageIndex') -and $pageSize -gt 0 -and $PageRowCount -ge $pageSize) {
            return [string]($Page + 1)   # truthy → loop continues; URL builder uses $Page
        }
        if ($pgDict['SkipQuery'] -and $pgDict['TopQuery'] -and $pageSize -gt 0 -and $PageRowCount -ge $pageSize) {
            return [string]($Page + 1)
        }
    }
    return $null
}

function Select-XdrCycleEntries {
    <#
    .SYNOPSIS
    Per-cycle activity cap + most-overdue-first staggering (plan §4.5/§4.9 · the iter32 519-op 10-min-timeout guard).
    .DESCRIPTION
    Generic dispatch-fairness mechanism — a no-op when the eligible-entry count is <= the cap, and correct at
    Defender's 594-op scale. The per-Op G-Cadence gate (in Refresh) already isolates poll-rate; this caps how many
    *due* Ops dispatch in ONE cycle so a cold-start "everything due at once" burst (no checkpoint → all treated due)
    cannot exceed the Y1 Linux-Consumption 10-min function timeout. Ordering = most-overdue-first (the longest-waiting
    Op runs first · fair); capped Ops fire on subsequent cycles. Staggering emerges naturally: capped Ops that DO run
    get fresh checkpoints and fall out of the due-set next cycle, desynchronising same-cadence Ops WITHOUT fragile
    phase-offset arithmetic. Reads an optional '_OverdueSeconds' bookkeeping key per entry (set by the dispatcher);
    absent → treated as 0. The key is internal — the dispatcher strips '_'-prefixed keys before the Activity payload.
    .OUTPUTS
    The capped, overdue-ordered subset (array). Returns the input verbatim when count <= cap; empty array for null/empty.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowNull()] [object[]] $Entries,
        [int] $MaxPerCycle = 50
    )
    if ($null -eq $Entries -or $Entries.Count -eq 0) { return @() }
    if ($MaxPerCycle -lt 1) { $MaxPerCycle = 1 }
    if ($Entries.Count -le $MaxPerCycle) { return $Entries }
    $sorted = $Entries | Sort-Object -Property @{
        Expression = {
            $e = $_
            if ($e -is [System.Collections.IDictionary] -and $e.Contains('_OverdueSeconds')) {
                [double]$e['_OverdueSeconds']
            } else { 0.0 }
        }
        Descending = $true
    }
    return @($sorted | Select-Object -First $MaxPerCycle)
}

# ── Capability-absent classifier (license-independence §3 · operator-locked 2026-06-10 · response-driven · GENERIC) ──
function Test-XdrIsCapabilityAbsent {
    <#
    .SYNOPSIS
    TRUE when a poll exception means THIS tenant cannot serve the op (product/license/capability absent) → POSTURE.
    Response-driven + generic (NO per-op hardcoding): PortalTerminal 403/404, OR a 400 whose body carries the apiproxy
    "InvalidProxyPrefix" — a DOCUMENTED upstream prefix (e.g. /mtoapi Multi-Tenant-Org · references/openapi
    multi_tenant.yml) that a tenant WITHOUT the product cannot route. The connector must always work across
    tenants/products/portals: capability-absent → posture (visible Capability.OpUnavailable telemetry · never silent ·
    auto-activates on a licensed tenant). ANY OTHER 400 (real contract error) stays LOUD/terminal — zero-masking holds.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowNull()][object] $Exception)
    if ($null -eq $Exception) { return $false }
    if ($Exception.GetType().Name -ne 'XdrPortalTerminalException') { return $false }
    $sc = 0; try { $sc = [int]$Exception.StatusCode } catch { $sc = 0 }
    if ($sc -eq 403 -or $sc -eq 404) { return $true }
    if ($sc -eq 400 -and ([string]$Exception.ResponseBody) -match 'InvalidProxyPrefix') { return $true }
    # license/product-absent on THIS tenant (e.g. 400 "The following licenses are required to be on: TvmPremium" ·
    # live-caught 2026-06-25 ListExtensions/ListCertificates on the unlicensed lab tvm/analytics surface) → capability-
    # absent, NOT a contract error (F18 dynamic-multi-tenant lock: classify a license-400 like 403/404 · the op SHIPS +
    # auto-lights-up on a licensed tenant · NEVER a hand-added per-op cap-gate). SPECIFIC marker (license + required, near
    # each other) so a real contract 400 still stays LOUD/terminal — zero-masking holds.
    if ($sc -eq 400 -and ([string]$Exception.ResponseBody) -match '(?i)\blicen[sc]es?\b[^.;]{0,60}\brequired\b|\brequire[sd]?\b[^.;]{0,40}\blicen[sc]es?\b') { return $true }
    return $false
}

# ── Selective ingestion · category allow-set parser (SSOT §7 · G-Selection · additive · operator-locked) ──────────────
function Get-XdrEnabledCategorySet {
    <#
    .SYNOPSIS
    Parse the optional XDRLR_ENABLED_CATEGORIES app setting into a category allow-set (SSOT §7 · selective ingestion).
    .DESCRIPTION
    G-Selection: the per-cycle dispatcher consults this to skip categories the operator has NOT enabled. It composes
    with G-Capability (product-present) and G-Cadence (poll-due) as a THIRD orthogonal skip-gate. The infra
    (DCRs/tables/DCE) is fully onboarded regardless — this gates only POLLING — so re-selecting is a pure app-setting
    flip + Function App restart (checkpoints persist · NO ARM/DCR/table redeploy).

    Semantics (operator-locked · backward-compatible): UNSET / EMPTY / whitespace-only / commas-only => $null =>
    ALL categories enabled (the default · an existing deployment with no app setting behaves exactly as before). A
    non-empty CSV => a case-insensitive HashSet of the named categories; entries are trimmed and blank entries dropped.
    .OUTPUTS
    $null                                        → no selection (ALL categories enabled · the default)
    [System.Collections.Generic.HashSet[string]] → the explicit allow-set (case-insensitive membership)
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.HashSet[string]])]
    param([AllowNull()][string] $Raw)

    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }   # unset/empty => ALL enabled (backward-compatible)
    $parts = @($Raw.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($parts.Count -eq 0) { return $null }                    # only blanks/commas => ALL enabled
    # Comparer-first constructor + Add loop: the two-arg HashSet(IEnumerable, comparer) overload does NOT reliably bind
    # the IEqualityComparer under PowerShell overload resolution (the comparer is dropped → case-SENSITIVE membership,
    # which would silently disable a category on portal/app-setting casing drift). This form is unambiguous.
    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $parts) { [void]$set.Add($p) }
    return ,$set
}

function Test-XdrCategoryEnabled {
    <#
    .SYNOPSIS
    G-Selection dispatch decision: TRUE when a category should actively poll under the operator's selection (SSOT §7).
    .DESCRIPTION
    The single source of truth for the selection decision the dispatcher branches on — run.ps1 skips a category IFF this
    returns $false. Factored out (mirrors Test-XdrRequiresProducts for G-Capability) so the decision is unit-tested
    directly rather than re-implemented in tests. Membership defers to the HashSet's own comparer (OrdinalIgnoreCase as
    built by Get-XdrEnabledCategorySet), so casing drift never silently disables a category.
    .OUTPUTS
    $true  → category is enabled (no selection active, OR the set contains it) → dispatch it
    $false → a selection is active AND the set does not contain it → skip (emit Entry.Selection.Skipped)
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()] $EnabledCategories,   # $null => no selection (ALL enabled); else a HashSet[string]
        [AllowNull()][AllowEmptyString()][string] $Category
    )
    if ($null -eq $EnabledCategories) { return $true }         # no selection => all enabled (backward-compatible)
    return [bool]$EnabledCategories.Contains([string]$Category)
}

Export-ModuleMember -Function `
    Get-XdrEnabledCategorySet, Test-XdrCategoryEnabled, `
    Invoke-XdrEntryPoll, Invoke-XdrPortalHttp, Invoke-XdrAuthenticated, Test-XdrIsCapabilityAbsent, `
    Select-XdrExactlyOnceRows, Get-XdrAdvancedFrontier, Get-XdrCursorAtPrecision, `
    Invoke-XdrEntityFanout, Get-XdrParentEntityIds, Add-XdrEntityIds, Get-XdrCachedEntityIds, Clear-XdrEntityCache, Get-XdrEntityIdField, `
    Get-XdrCheckpoint, Get-XdrCheckpointsForPartition, Save-XdrCheckpointAtomic, Save-XdrCheckpointReset, `
    New-XdrRequestUrl, New-XdrRequestBody, Get-XdrRequestParams, Resolve-XdrTimeWindow, Select-XdrCycleEntries, `
    Get-XdrCircuitState, Test-XdrCircuitClosed, Update-XdrCircuitState, `
    Get-XdrManifests, ConvertTo-XdrDeepHashtable, ConvertFrom-XdrActivityInput, `
    Get-XdrPortalConfig
