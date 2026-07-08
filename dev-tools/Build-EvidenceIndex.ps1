#Requires -Version 7.4
<#
.SYNOPSIS
v1 · portal-GENERIC live-capture EVIDENCE INDEX builder (plan tier-1 schema feed). Scans references/live/ and
maps each captured Defender operation to its catalogue OperationKey, emitting one record per mapped op into
references/inventory/<portal>/evidence-index.json. This is the FOUNDATION FEED that lets Build-Catalogue use the
already-captured live corpus as the tier-1 SCHEMA source (Status='LiveCaptured') instead of re-probing.

.DESCRIPTION
The live corpus (documented in references/live/CONSOLIDATION.md) has 3 overlapping source dirs:
  A  source-final-cross/by-path/<category>__<op>.json   — per-op, carries OperationMatch (SubArea/Slug/PathKey) +
                                                          Fields.{ResponseShape,ExampleResponseExcerpt} (contract hints)
  B  source-mvp-fixtures/<Dir>/response.json            — per-op, RAW response body at file root (canonical body pick)
  C  source-xdrlograider-raw/MDE_<Table>_CL-{raw,ingest}.json — per-CL-table (NOT mechanically op-joinable → ignored)

A is the canonical per-op KEY source (its filename == CONSOLIDATION OperationKey `<category>__<op>`; its OperationMatch
carries the SubArea+Slug that join 1:1 to the catalogue's inventory OperationId). B is the canonical BODY source
(raw response at root, directly parseable). Per CONSOLIDATION's recommended pick: prefer the mvp-fixtures (B) raw body,
fall back to final-cross (A) Fields.ExampleResponseExcerpt only when no B body exists. C (table-grained) is ignored here.

Mapping (A → catalogue OperationId), verified 159/159, 0 orphans:
  1. SubArea (alnum-normalized) == OperationId.SubSeg (alnum-normalized)  AND  Slug (alnum) == OperationId.OpSeg (alnum)
  2. Fallback (handles the 2 `tenantcontext` slugs whose op is `GetTenantContext`): same SubArea, OpSeg ENDSWITH Slug.
B-dir resolution (A → B): dir == <SubArea>_<Slug> PREFERRED (disambiguates same-slug ops across SubAreas — C2 fix), else dir == Slug.

Category / Subcategory / Operation are derived EXACTLY as Build-Catalogue derives them (x-tagGroups group · tag · last
OperationId segment) so the catalogue can join the evidence-index by OperationId (primary) or the triple. Path is the
inventory path (sub-portal-trimmed, matching the catalogue's Path field). For the 19 capture-less portals the index is
empty by construction (no references/live/ corpus for them).

OUTPUT record (array element):
  OperationKey   canonical CONSOLIDATION key `<category>__<op>` (== A filename basename)
  OperationId    resolved catalogue/inventory OperationId (join key for Build-Catalogue) e.g. ActionCenter.GetHistory
  Category       x-tagGroups group name (catalogue Category) e.g. Operations
  Subcategory    tag (catalogue Subcategory) e.g. Action Center
  Operation      last OperationId segment (catalogue Operation) e.g. GetHistory
  Method         HTTP method (inventory)
  Path           sub-portal-trimmed path (catalogue Path)
  Fixture        repo-relative path to the chosen RAW body file (B response.json, or A excerpt-derived only if no B)
  ResponseShape  wrapper | bareArray | singleObject
  ItemsContainer wrapper array key (Results/value/data/actions/…) when wrapper, else null
  SampleFields   top-level field names of the first item (wrapper/bareArray) or the object (singleObject); [] for scalars
#>
[CmdletBinding()]
param(
    [string] $Portal = 'Defender',     # friendly name ('Defender') · nodoc key · or 'All'
    [switch] $AllPortals,              # build an index for every nodoc-* portal (19 empty + Defender)
    [string] $RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path,
    [switch] $WriteFile
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# UTF-8 stdout (no BOM) so the evidence-index emits non-ASCII losslessly when captured by the gauntlet regen→diff axis
# under any shell (the OEM codepage mangles UTF-8 to `?`). Root cause documented in tools/Run-PrePushGauntlet.ps1.
$OutputEncoding = [System.Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$script:XdrCurationFixture = $null   # lazy-loaded once by the B-dir resolver (reconcile-aware fixture map · OperationId -> dir)

Import-Module powershell-yaml -ErrorAction Stop
# Shared single-record-vs-wrapper SHAPE ORACLE · the SAME file is dot-sourced by Build-Catalogue.ps1 so the two
# generators classify response bodies identically (no twin-drift). Provides Get-XdrBodyShape (live-body classifier).
. (Join-Path $PSScriptRoot 'lib/Get-XdrBodyShape.ps1')

# ── Portal registry · built fresh from portals.json (same source as Build-Catalogue) ──
$portalsJson = Get-Content (Join-Path $RepoRoot 'references/inventory/portals.json') -Raw | ConvertFrom-Json -AsHashtable
$registry = @{}
foreach ($p in @($portalsJson['portals'])) {
    $key = [string]$p['PortalKey']; $short = [string]$p['PortalShort']
    $friendly = switch ($key) {
        'nodoc-defender-xdr'    { 'Defender' }
        'nodoc-purview'         { 'Purview' }
        'nodoc-security-copilot'{ 'SecurityCopilot' }
        default { (($short -split '[-_]' | Where-Object { $_ } | ForEach-Object { $_.Substring(0,1).ToUpper() + $_.Substring(1) }) -join '') }
    }
    $registry[$key] = @{ Key = $key; Short = $short; Friendly = $friendly }
}
$friendlyToKey = @{}; foreach ($k in $registry.Keys) { $friendlyToKey[$registry[$k].Friendly.ToLower()] = $k }
$targetKeys = if ($AllPortals -or $Portal -eq 'All') {
    @($registry.Keys | Sort-Object)
} elseif ($registry.ContainsKey($Portal)) { @($Portal) }
elseif ($friendlyToKey.ContainsKey($Portal.ToLower())) { @($friendlyToKey[$Portal.ToLower()]) }
else { throw "Unknown portal '$Portal' (use a friendly name, a nodoc-* key, or 'All')" }
$targetKeys = @($targetKeys)

# ── Helpers ──
function Get-Alnum([string]$s) { if ($null -eq $s) { return '' } return ($s -replace '[^A-Za-z0-9]', '') }
function Split-SubPortalPath([string]$fullPath) {
    # Mirror Build-Catalogue's Split-SubPortal: strip the first path segment as the sub-portal.
    $p = $fullPath.TrimStart('/'); $seg = $p.Split('/')[0]
    $rest = '/' + $p.Substring($seg.Length).TrimStart('/')
    return $rest
}
# Top-level field names of a parsed item (ordered, as-captured — NOT sorted, so SampleFields reflects wire order).
function Get-TopFields($item) {
    if ($item -is [System.Collections.IDictionary]) { return @($item.Keys | ForEach-Object { [string]$_ }) }
    return @()
}
# Detect ResponseShape + ItemsContainer + first-item + ITEM COUNT from a parsed body, via the shared SHAPE ORACLE
# (dev-tools/lib/Get-XdrBodyShape.ps1) so this generator and Build-Catalogue classify bodies identically. Honest:
#   wrapper      → a LIST ENVELOPE: exactly one array sibling with only empty/pagination-metadata co-siblings, OR a
#                  canonical-keyed (Results/value/data/items/records/actions) array · OR an MTO {result:{value:[...]}}
#                  nested list (one-level descent). ItemsContainer = the (leaf) array key.
#   bareArray    → top-level JSON array.
#   singleObject → a single record (>1 array, or an array among substantive entity siblings), OR a scalar/null body.
# RowCount (plan U5 cadence-vs-volume feed) = the number of records the CAPTURE actually returned:
#   wrapper → length of the items array · bareArray → array length · singleObject → 1 if an object body, else 0
#   (a scalar/null body carries no rows). This is the captured-page size, which the catalogue's S4 cadence-vs-
#   volume check uses to ADVISE (never refuse) a mode/cadence fit for high-volume ops.
function Resolve-BodyShape($body) {
    $o = Get-XdrBodyShape $body
    return @{ Shape = $o['Shape']; ItemsContainer = $o['ItemsContainer']; FirstItem = $o['FirstItem']; RowCount = $o['RowCount'] }
}

# ── Build the Defender capture map (A → catalogue records) ──
function Build-DefenderEvidenceIndex {
    param([string] $portalKey)
    $liveRoot = Join-Path $RepoRoot 'references/live'
    $aDir = Join-Path $liveRoot 'source-final-cross/by-path'
    $bRoot = Join-Path $liveRoot 'source-mvp-fixtures'
    $invDir = Join-Path $RepoRoot "references/inventory/$portalKey"
    $specFile = Join-Path $RepoRoot "references/openapi/$portalKey/specification/openapi.yml"

    # x-tagGroups: tag → group (Category derivation, identical to Build-Catalogue).
    $root = ConvertFrom-Yaml (Get-Content $specFile -Raw)
    $tagToGroup = @{}
    foreach ($g in @($root['x-tagGroups'])) { foreach ($t in @($g['tags'])) { $tagToGroup[$t] = $g['name'] } }

    # Inventory records: OperationId → (SubSeg, OpSeg, Group, Subcat, Method, Path). Group = first tag that maps.
    $recs = @()
    foreach ($invf in (Get-ChildItem $invDir -Filter '*.operations.json' -ErrorAction SilentlyContinue)) {
        $inv = Get-Content $invf.FullName -Raw | ConvertFrom-Json -AsHashtable
        foreach ($op in @($inv['operations'])) {
            $opId = if ($op.Contains('OperationId')) { [string]$op['OperationId'] } else { $null }
            if (-not $opId) { continue }
            $grp = $null; $sub = $null
            foreach ($t in @($op['Tags'])) { if ($tagToGroup.ContainsKey($t)) { $grp = $tagToGroup[$t]; $sub = $t; break } }
            $parts = $opId -split '\.'
            $recs += [pscustomobject]@{
                OperationId = $opId; SubSeg = $parts[0]; OpSeg = $parts[-1]; Group = $grp; Subcat = $sub
                Method = ([string]$op['Method']).ToUpper(); Path = [string]$op['Path']
            }
        }
    }

    # B-dir lookup (lower-cased name → actual dir name).
    $bSet = @{}
    foreach ($d in (Get-ChildItem $bRoot -Directory -ErrorAction SilentlyContinue)) { $bSet[$d.Name.ToLower()] = $d.Name }

    $records = @()
    $orphans = @()
    $missingFixtures = @()
    foreach ($af in (Get-ChildItem $aDir -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $opKey = $af.BaseName                       # canonical CONSOLIDATION key `<category>__<op>`
        $a = Get-Content $af.FullName -Raw | ConvertFrom-Json -AsHashtable
        $om = $a['OperationMatch']
        $subArea = [string]$om['SubArea']; $slug = [string]$om['Slug']
        $saN = Get-Alnum $subArea; $slN = Get-Alnum $slug

        # Map A → catalogue record (tier 1 exact, tier 2 endswith fallback).
        $cand = @($recs | Where-Object { (Get-Alnum $_.SubSeg) -ieq $saN -and (Get-Alnum $_.OpSeg) -ieq $slN })
        if ($cand.Count -ne 1) {
            $cand = @($recs | Where-Object { (Get-Alnum $_.SubSeg) -ieq $saN -and ((Get-Alnum $_.OpSeg) -ilike ('*' + $slN)) })
        }
        if ($cand.Count -ne 1) {
            $orphans += [pscustomobject]@{ OperationKey = $opKey; SubArea = $subArea; Slug = $slug; Matches = $cand.Count }
            continue
        }
        $rec = $cand[0]

        # Resolve the canonical B body dir, in priority order:
        #  (1) CURATED reconcile-fixture — a path-reconciled op (curation.json pathReconcile[opId].Fixture) polls a
        #      DIFFERENT endpoint than its SubArea implies, so its body lives in a differently-named dir. e.g.
        #      MultiTenant.GetTenantContext is reconciled to mtp /sccManagement/mgmt/TenantContext (the RICH 76-field
        #      body in `TenantContext`), NOT the empty-MTO `MultiTenant_TenantContext` MTO-path capture.
        #  (2) SubArea-qualified `<SubArea>_<Slug>` — disambiguates genuine same-slug ops (the SecurityCopilotTrial pair).
        #  (3) bare `<Slug>`.
        if ($null -eq $script:XdrCurationFixture) {
            $script:XdrCurationFixture = @{}
            $cfp = Join-Path $RepoRoot 'references/inventory/nodoc-defender-xdr/curation.json'
            if (Test-Path $cfp) {
                $cj = Get-Content $cfp -Raw | ConvertFrom-Json -AsHashtable -Depth 20
                if ($cj.Contains('pathReconcile')) { foreach ($ck in $cj['pathReconcile'].Keys) { if (($cj['pathReconcile'][$ck] -is [System.Collections.IDictionary]) -and $cj['pathReconcile'][$ck].Contains('Fixture')) { $script:XdrCurationFixture[$ck] = [string]$cj['pathReconcile'][$ck]['Fixture'] } } }
            }
        }
        $bDir = $null
        $cfx = if ($script:XdrCurationFixture.ContainsKey([string]$rec.OperationId)) { $script:XdrCurationFixture[[string]$rec.OperationId] } else { $null }
        if     ($cfx -and $bSet.ContainsKey($cfx.ToLower()))           { $bDir = $bSet[$cfx.ToLower()] }
        elseif ($bSet.ContainsKey(($subArea + '_' + $slug).ToLower())) { $bDir = $bSet[($subArea + '_' + $slug).ToLower()] }
        elseif ($bSet.ContainsKey($slug.ToLower()))                    { $bDir = $bSet[$slug.ToLower()] }

        # Body pick: prefer B raw body; fall back to A Fields.ExampleResponseExcerpt only when no B body exists.
        $fixtureRel = $null; $body = $null; $bodySource = $null
        if ($bDir) {
            $bAbs = Join-Path (Join-Path $bRoot $bDir) 'response.json'
            if (Test-Path $bAbs) {
                $bodySource = 'mvp-fixtures'
                $fixtureRel = "references/live/source-mvp-fixtures/$bDir/response.json"
                try { $body = Get-Content $bAbs -Raw | ConvertFrom-Json -AsHashtable -Depth 40 } catch { $body = $null }
            }
        }
        if ($null -eq $fixtureRel) {
            # Fallback: A excerpt (the only carrier of the body when B is absent). The fixture is the A file itself;
            # we parse the excerpt purely to derive shape/fields. (Not expected to fire for Defender — all 157 B dirs exist.)
            $excerpt = $null
            if ($a.ContainsKey('Fields') -and ($a['Fields'] -is [System.Collections.IDictionary]) -and $a['Fields'].ContainsKey('ExampleResponseExcerpt')) {
                $excerpt = [string]$a['Fields']['ExampleResponseExcerpt']
            }
            $bodySource = 'final-cross-excerpt'
            $fixtureRel = "references/live/source-final-cross/by-path/$($af.Name)"
            if ($excerpt) { try { $body = $excerpt | ConvertFrom-Json -AsHashtable -Depth 40 } catch { $body = $null } }
        }

        # Verify the chosen fixture exists on disk.
        if (-not (Test-Path (Join-Path $RepoRoot $fixtureRel))) {
            $missingFixtures += $fixtureRel
        }

        $sh = Resolve-BodyShape $body
        $sampleFields = @(Get-TopFields $sh.FirstItem)

        $records += [ordered]@{
            OperationKey   = $opKey
            OperationId    = $rec.OperationId
            Category       = $rec.Group
            Subcategory    = $rec.Subcat
            Operation      = $rec.OpSeg
            Method         = $rec.Method
            Path           = (Split-SubPortalPath $rec.Path)
            Fixture        = $fixtureRel
            BodySource     = $bodySource
            ResponseShape  = $sh.Shape
            ItemsContainer = $sh.ItemsContainer
            RowCount       = $sh.RowCount       # captured-page record count (plan U5 cadence-vs-volume feed)
            SampleFields   = $sampleFields
        }
    }

    return @{ Records = $records; Orphans = $orphans; MissingFixtures = $missingFixtures }
}

# ── Driver ──
function ConvertTo-IndexJson { param($Obj) Set-StrictMode -Off; $Obj | ConvertTo-Json -Depth 12 }
foreach ($key in $targetKeys) {
    $reg = $registry[$key]
    if ($key -eq 'nodoc-defender-xdr') {
        $res = Build-DefenderEvidenceIndex -portalKey $key
        $records = $res.Records
        $orphanCount = @($res.Orphans).Count
        $missingCount = @($res.MissingFixtures).Count

        $shapeCounts = [ordered]@{}
        foreach ($s in @('wrapper','bareArray','singleObject')) {
            $shapeCounts[$s] = @($records | Where-Object { $_.ResponseShape -eq $s }).Count
        }
        $doc = [ordered]@{
            Portal = $reg.Friendly; PortalKey = $key
            GeneratedFrom = 'references/live (source-final-cross OperationMatch + source-mvp-fixtures raw body) · CONSOLIDATION.md canonical keys · v1'
            DerivedUtc = '2026-06-04T00:00:00Z'
            RecordCount = @($records).Count
            OrphanCount = $orphanCount
            ResponseShapeCounts = $shapeCounts
            Records = $records
        }

        if ($WriteFile) {
            $outPath = Join-Path $RepoRoot "references/inventory/$key/evidence-index.json"
            (ConvertTo-IndexJson $doc) | Out-File $outPath -Encoding utf8
        } elseif ($targetKeys.Count -eq 1) {
            ConvertTo-IndexJson $doc
        }

        # Diagnostics → STDERR so non-WriteFile STDOUT stays PURE JSON (consumed by the RAW->SoT gauntlet axis + any
        # pipe). Build-Catalogue guards its summary by -WriteFile; here the orphan/missing warnings must ALWAYS show,
        # so stderr (always-visible · gauntlet discards via 2>$null) is the correct stream — never stdout.
        [Console]::Error.WriteLine("[Build-EvidenceIndex v1] $key · records=$(@($records).Count) orphans=$orphanCount missingFixtures=$missingCount shapes(wrapper=$($shapeCounts['wrapper']) bareArray=$($shapeCounts['bareArray']) singleObject=$($shapeCounts['singleObject']))$(if($WriteFile){' · WROTE evidence-index.json'})")
        if ($orphanCount -gt 0) {
            [Console]::Error.WriteLine("  ORPHANS (captured but unmapped):")
            $res.Orphans | ForEach-Object { [Console]::Error.WriteLine(("    {0}  SubArea={1} Slug={2} matches={3}" -f $_.OperationKey, $_.SubArea, $_.Slug, $_.Matches)) }
        }
        if ($missingCount -gt 0) {
            [Console]::Error.WriteLine("  MISSING FIXTURE FILES:")
            $res.MissingFixtures | ForEach-Object { [Console]::Error.WriteLine("    $_") }
        }
    } else {
        # Capture-less portals: empty index by construction (no references/live/ corpus exists for them).
        $doc = [ordered]@{
            Portal = $reg.Friendly; PortalKey = $key
            GeneratedFrom = 'references/live (no capture corpus for this portal) · v1'
            DerivedUtc = '2026-06-04T00:00:00Z'
            RecordCount = 0; OrphanCount = 0
            ResponseShapeCounts = [ordered]@{ wrapper = 0; bareArray = 0; singleObject = 0 }
            Records = @()
        }
        if ($WriteFile) {
            $outPath = Join-Path $RepoRoot "references/inventory/$key/evidence-index.json"
            (ConvertTo-IndexJson $doc) | Out-File $outPath -Encoding utf8
        } elseif ($targetKeys.Count -eq 1) {
            ConvertTo-IndexJson $doc
        }
        [Console]::Error.WriteLine("[Build-EvidenceIndex v1] $key · records=0 (no capture corpus)$(if($WriteFile){' · WROTE evidence-index.json'})")
    }
}
