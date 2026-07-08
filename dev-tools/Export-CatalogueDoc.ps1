#Requires -Version 7.4
<#
.SYNOPSIS
  Generates docs/CATALOGUE.md (canonical, operation-level) and a README summary
  fragment from the SHIPPED ground truth (manifests/Defender/*.psd1) enriched by
  references/inventory/nodoc-defender-xdr/catalogue.json (ValueClass, held reasons)
  and references/inventory/portals.json + categories.json (the research/expansion
  surface). NEVER hardcodes counts -- every number is derived from those files.

.DESCRIPTION
  Source-of-truth model (matches the workspace "NEVER hardcoded counts" lock):

    * WHAT SHIPS          = manifests/Defender/*.psd1   (the deployed operation set:
                            table, ingestion mode, cadence, path, sub-portal).
    * VALUE / HELD REASON = catalogue.json              (EffectiveValueClass, Shipped
                            flag, ShipHeldReason, friendly Category name).
    * EXPANSION SURFACE   = portals.json / categories.json (the portal-agnostic
                            research corpus contributors can wire in).

  The manifests and the catalogue MUST agree: the number of manifest operations is
  asserted equal to the number of catalogue operations with Shipped == true. A drift
  there means the doc would be a lie, so the generator throws instead of emitting.

  Outputs (deterministic, LF, so -Check can byte-compare):
    docs/CATALOGUE.md   -- full artifact (banner, counts, category summary, operation
                           table, held summary, expansion surface, legends).
    README.md           -- with -UpdateReadme, the compact category table is spliced
                           between the <!-- CATALOGUE:START --> / <!-- CATALOGUE:END -->
                           markers (off by default; -Check verifies the block in place).

.PARAMETER RepoRoot
  Repo root. Defaults to the parent of dev-tools/.

.PARAMETER Check
  Do not write. Regenerate in memory and diff against the committed docs/CATALOGUE.md
  and docs/CATALOGUE-README-FRAGMENT.md (and, if README.md carries the marker block,
  the content between the markers). Exit 1 on any drift. Wire this into the pre-push
  gauntlet next to Assert-ShippedManifestParity.ps1 so a stale doc fails the build.

.PARAMETER UpdateReadme
  Additionally splice the fresh fragment into README.md between the
  <!-- CATALOGUE:START --> / <!-- CATALOGUE:END --> markers, if present. Off by
  default -- the generator never touches README.md unless explicitly asked.

.EXAMPLE
  pwsh dev-tools/Export-CatalogueDoc.ps1
  Regenerate docs/CATALOGUE.md and the README fragment.

.EXAMPLE
  pwsh dev-tools/Export-CatalogueDoc.ps1 -Check
  Fail (exit 1) if the committed catalogue doc has drifted from the manifests.

.NOTES
  Public, contributor-facing dev-tool. Reads only committed manifests + inventory
  JSON -- no live tenant, no secrets. Belongs in the public allowlist.
  Author: Alex Kefallonitis (al.kefallonitis@gmail.com).
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [switch] $Check,
    [switch] $UpdateReadme
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------------------------
# Constants (labels/legends -- NOT counts). Cadence tiers are DERIVED from the
# distinct Cadence TimeSpans present in the manifests; any cadence not mapped
# here falls back to its raw value and is surfaced verbatim (so a new tier can
# never be silently mislabelled).
# ----------------------------------------------------------------------------
$CadenceTier = [ordered]@{
    '00:10:00'   = @{ Rank = 1; Label = '10-min (T1)' }
    '01:00:00'   = @{ Rank = 2; Label = 'Hourly (T2)' }
    '06:00:00'   = @{ Rank = 3; Label = '6-hourly (T3)' }
    '1.00:00:00' = @{ Rank = 4; Label = 'Daily (T4)' }
}
function Get-CadenceTierLabel([string] $Cadence) {
    if ($CadenceTier.Contains($Cadence)) { return $CadenceTier[$Cadence].Label }
    return "$Cadence (raw)"
}
function Get-CadenceTierRank([string] $Cadence) {
    if ($CadenceTier.Contains($Cadence)) { return $CadenceTier[$Cadence].Rank }
    return 99
}

# Compact distribution: "SNAPSHOT x120, CURSOR x2" (name-sorted, deterministic).
function Format-Dist {
    param([object[]] $Items, [string] $Property)
    if (-not $Items -or $Items.Count -eq 0) { return '-' }
    ($Items | Group-Object -Property $Property | Sort-Object Name |
        ForEach-Object { '{0} x{1}' -f $_.Name, $_.Count }) -join ', '
}
# Cadence distribution sorted by tier rank (fastest first), not alphabetically.
function Format-CadenceDist {
    param([object[]] $Items)
    if (-not $Items -or $Items.Count -eq 0) { return '-' }
    ($Items | Group-Object CadenceRaw |
        Sort-Object { Get-CadenceTierRank $_.Name } |
        ForEach-Object { '{0} x{1}' -f (Get-CadenceTierLabel $_.Name), $_.Count }) -join ', '
}

# ----------------------------------------------------------------------------
# 1. DEPLOYED SET = the manifests (authoritative for WHAT SHIPS).
# ----------------------------------------------------------------------------
$manifestDir = Join-Path $RepoRoot 'manifests/Defender'
$manifestFiles = @(Get-ChildItem -Path (Join-Path $manifestDir '*.psd1') | Sort-Object Name)
if ($manifestFiles.Count -eq 0) { throw "No manifests found under $manifestDir" }

$portal = $null
$manifestRows = foreach ($f in $manifestFiles) {
    $m = Import-PowerShellDataFile -Path $f.FullName
    if (-not $portal) { $portal = $m.Portal }
    foreach ($op in $m.Operations) {
        [pscustomobject]@{
            Portal      = $m.Portal
            CategoryKey = $m.Category                 # compact, e.g. AnalyticsData
            Table       = $op.WorkspaceTable
            Stream      = $op.Subcategory
            Op          = $op.Provenance.OperationId
            SubPortal   = $op.SubPortal
            Path        = $op.Path
            Mode        = $op.IngestionMode
            CadenceRaw  = $op.Cadence
            CadenceTier = Get-CadenceTierLabel $op.Cadence
        }
    }
}
$manifestRows = @($manifestRows)

# ----------------------------------------------------------------------------
# 2. CATALOGUE = value class + held reasons + friendly Category name.
# ----------------------------------------------------------------------------
$cataloguePath = Join-Path $RepoRoot 'references/inventory/nodoc-defender-xdr/catalogue.json'
$catalogue = Get-Content -Path $cataloguePath -Raw | ConvertFrom-Json
# Index by OperationId. The nodoc spec double-tags some endpoints (SamePath
# duplicates): the same OperationId appears once canonical (Shipped) and once held.
# Prefer the Shipped/canonical entry so the manifest join resolves to what deploys.
$catById = @{}
foreach ($o in $catalogue.Operations) {
    if ($catById.ContainsKey($o.OperationId)) {
        $existing = $catById[$o.OperationId]
        $prefer = ($o.Shipped -and -not $existing.Shipped) -or
                  ($o.Shipped -eq $existing.Shipped -and $o.IsCanonical -and -not $existing.IsCanonical)
        if ($prefer) { $catById[$o.OperationId] = $o }
    } else {
        $catById[$o.OperationId] = $o
    }
}

$shipped = @($catalogue.Operations | Where-Object { $_.Shipped })
$held    = @($catalogue.Operations | Where-Object { -not $_.Shipped })

# ----------------------------------------------------------------------------
# 3. PARITY ASSERT -- the manifests and the catalogue Shipped-set MUST match.
# ----------------------------------------------------------------------------
if ($manifestRows.Count -ne $shipped.Count) {
    throw ("PARITY FAIL: manifests carry $($manifestRows.Count) operations but " +
           "catalogue.json marks $($shipped.Count) as Shipped. The catalogue and the " +
           "deployed set have drifted -- re-run Generate-Manifest.ps1 / re-derive the catalogue.")
}
$missingInCatalogue = @($manifestRows | Where-Object { -not $catById.ContainsKey($_.Op) })
if ($missingInCatalogue.Count -gt 0) {
    throw ("PARITY FAIL: $($missingInCatalogue.Count) manifest operation(s) have no catalogue " +
           "entry (first: $($missingInCatalogue[0].Op)).")
}
$shippedNotShipping = @($manifestRows | Where-Object { -not $catById[$_.Op].Shipped })
if ($shippedNotShipping.Count -gt 0) {
    throw ("PARITY FAIL: $($shippedNotShipping.Count) manifest operation(s) are NOT flagged " +
           "Shipped in the catalogue (first: $($shippedNotShipping[0].Op)).")
}

# Enrich each manifest row with catalogue-derived fields (friendly category + value class).
foreach ($r in $manifestRows) {
    $c = $catById[$r.Op]
    $r | Add-Member -NotePropertyName Category   -NotePropertyValue $c.Category -Force
    $r | Add-Member -NotePropertyName ValueClass -NotePropertyValue $c.EffectiveValueClass -Force
}
# Deterministic order: friendly Category, then Stream, then OperationId.
$rows = @($manifestRows | Sort-Object Category, Stream, Op)

# ----------------------------------------------------------------------------
# 4. DERIVE every count (never a literal).
# ----------------------------------------------------------------------------
$catCount       = @($rows | Select-Object -ExpandProperty Category -Unique).Count
$streamCount    = @($rows | Select-Object -ExpandProperty Stream   -Unique).Count
$tableCount     = @($rows | Select-Object -ExpandProperty Table    -Unique).Count
$subPortalDist  = Format-Dist -Items $rows -Property SubPortal
$modeDist       = Format-Dist -Items $rows -Property Mode
$cadenceDist    = Format-CadenceDist -Items $rows
$valueDist      = Format-Dist -Items $rows -Property ValueClass

# All catalogue categories (shipped + held-only), for the summary + held view.
$catByCategory = $catalogue.Operations | Group-Object Category | Sort-Object Name
$heldOnlyCats  = @($catByCategory | Where-Object { @($_.Group | Where-Object Shipped).Count -eq 0 })
$heldWithReason = @($held | Where-Object { $_.ShipHeldReason -and "$($_.ShipHeldReason)".Trim() })
$heldOverlap    = @($held | Where-Object { $_.OfficialApiOverlap -in @('Exact', 'Likely') })

# Expansion surface (portals.json / categories.json) -- research corpus, derived.
$portalsPath    = Join-Path $RepoRoot 'references/inventory/portals.json'
$categoriesPath = Join-Path $RepoRoot 'references/inventory/nodoc-defender-xdr/categories.json'
$portalsDoc     = Get-Content -Path $portalsPath -Raw | ConvertFrom-Json
$defenderCats   = Get-Content -Path $categoriesPath -Raw | ConvertFrom-Json
$portalCount    = @($portalsDoc.portals).Count
$researchOps    = [int](@($portalsDoc.portals) | Measure-Object -Property OperationCount -Sum).Sum
$researchCats   = [int](@($portalsDoc.portals) | Measure-Object -Property CategoryCount  -Sum).Sum
$defenderEntry  = @($portalsDoc.portals | Where-Object { $_.PortalKey -eq 'nodoc-defender-xdr' })[0]
$defenderResearchOps  = [int]$defenderEntry.OperationCount
$defenderResearchCats = @($defenderCats).Count

# ----------------------------------------------------------------------------
# 5. Build docs/CATALOGUE.md as a list of LF-joined lines (source CRLF never leaks).
# ----------------------------------------------------------------------------
$L = [System.Collections.Generic.List[string]]::new()
$add = { param($s) $L.Add([string]$s) }

& $add '<!--'
& $add '  GENERATED FILE -- do not hand-edit.'
& $add '  Regenerate:  pwsh dev-tools/Export-CatalogueDoc.ps1'
& $add '  Drift gate:  pwsh dev-tools/Export-CatalogueDoc.ps1 -Check   (exit 1 if stale)'
& $add '  Sources: manifests/Defender/*.psd1 (deployed set) enriched by'
& $add '           references/inventory/nodoc-defender-xdr/catalogue.json (value class, held reasons).'
& $add '-->'
& $add ''
& $add '# XdrLogRaider -- Operation Catalogue'
& $add ''
& $add "This is the canonical, machine-generated inventory of every operation XdrLogRaider ships, plus a summary of the catalogued surface it deliberately holds back. Every number below is derived from the manifests and the catalogue at generation time -- nothing is hand-maintained."
& $add ''
& $add 'XdrLogRaider is an authorized purple-team / detection-engineering data connector: it turns the Microsoft Defender XDR portal-internal (`/apiproxy/*`) surfaces -- the audit, reporting, configuration, and posture endpoints that have no public REST API -- into read-only Sentinel telemetry. The ship-set is *curated* telemetry, not a raw endpoint dump; the held surface below is the honest other half of that curation.'
& $add ''

# ---- At a glance ------------------------------------------------------------
& $add '## At a glance'
& $add ''
& $add '| Metric | Value | Derived from |'
& $add '|---|---:|---|'
& $add "| Portal | $portal | manifests |"
& $add "| Shipped operations | $($rows.Count) | manifest ops (== catalogue ``Shipped == true``) |"
& $add "| Shipped categories | $catCount | distinct manifest category (== count of ``.psd1`` files) |"
& $add "| Shipped Sentinel tables | $tableCount | one ``Defender_<Category>_CL`` per category |"
& $add "| Shipped streams (subcategories) | $streamCount | distinct manifest subcategory |"
& $add "| Ingestion modes | $modeDist | manifest ``IngestionMode`` |"
& $add "| Cadence tiers | $cadenceDist | manifest ``Cadence`` |"
& $add "| Value classes | $valueDist | catalogue ``EffectiveValueClass`` |"
& $add "| Sub-portals touched | $subPortalDist | manifest ``SubPortal`` |"
& $add "| Catalogued but held | $($held.Count) | catalogue ``Shipped == false`` |"
& $add "| Catalogued total | $($catalogue.Operations.Count) | catalogue ``Operations`` |"
& $add ''
& $add '**Cadence tiers** map the distinct poll intervals: `10-min (T1)` `Hourly (T2)` `6-hourly (T3)` `Daily (T4)`.'
& $add ''
& $add '**Value classes** -- what a stream *is*: **CoreTelemetry** = per-entity security event/state (the reason to deploy); **ConfigState** = configuration / policy / posture snapshots. Held-only classes never ship: **UiHelper** (portal chrome), **Noise** (pick-lists, bare-string catalogs, checksums), **Reference** (id catalogs).'
& $add ''

# ---- Category summary (all catalogue categories) ----------------------------
& $add '## Categories'
& $add ''
& $add "All shipped operations land in the $portal portal. Each category maps to exactly one Sentinel custom table. Categories with 0 shipped operations are held in full (see [Held surface](#held-surface))."
& $add ''
& $add '| Category | Sentinel table | Streams | Shipped | Held | Ingestion (shipped) | Cadence (shipped) | Value class (shipped) |'
& $add '|---|---|---:|---:|---:|---|---|---|'
foreach ($g in $catByCategory) {
    $catName    = $g.Name
    $catShipRows = @($rows | Where-Object { $_.Category -eq $catName })
    $shipN      = $catShipRows.Count
    $heldN      = $g.Count - $shipN
    $table      = @($g.Group | Select-Object -ExpandProperty WorkspaceTable -Unique)[0]
    if ($shipN -gt 0) {
        $streams  = @($catShipRows | Select-Object -ExpandProperty Stream -Unique).Count
        $ingest   = Format-Dist -Items $catShipRows -Property Mode
        $cad      = Format-CadenceDist -Items $catShipRows
        $val      = Format-Dist -Items $catShipRows -Property ValueClass
    } else {
        $streams  = 0
        $ingest   = '-'
        $cad      = '-'
        $val      = '-'
    }
    & $add "| $catName | ``$table`` | $streams | $shipN | $heldN | $ingest | $cad | $val |"
}
& $add "| **Total** | **$tableCount tables** | **$streamCount** | **$($rows.Count)** | **$($held.Count)** | $modeDist | $cadenceDist | $valueDist |"
& $add ''

# ---- Full operation table ---------------------------------------------------
& $add '## Shipped operations'
& $add ''
& $add "All $($rows.Count) operations below are read-only and ship in v0.1.0. Each capability-gates at runtime and lights up only on a tenant that licenses the underlying product."
& $add ''
& $add '| Portal | Category | Stream | Operation | Sub-portal | Path | Mode | Cadence tier | Value class | Ship state |'
& $add '|---|---|---|---|---|---|---|---|---|---|'
foreach ($r in $rows) {
    & $add "| $($r.Portal) | $($r.Category) | $($r.Stream) | ``$($r.Op)`` | $($r.SubPortal) | ``$($r.Path)`` | $($r.Mode) | $($r.CadenceTier) | $($r.ValueClass) | shipped |"
}
& $add ''

# ---- Held surface -----------------------------------------------------------
& $add '## Held surface'
& $add ''
& $add "$($held.Count) catalogued operations are deliberately **held out of the ship-set** -- held is not dead. An operation is re-shipped the moment its basis changes (a new tenant capture, a runtime capability landing, a value re-classification). The dominant hold classes:"
& $add ''
& $add '| Hold class | Count | Why held |'
& $add '|---|---:|---|'
$heldNoise     = @($held | Where-Object { $_.EffectiveValueClass -eq 'Noise' }).Count
$heldUi        = @($held | Where-Object { $_.EffectiveValueClass -eq 'UiHelper' }).Count
$heldReference = @($held | Where-Object { $_.EffectiveValueClass -eq 'Reference' }).Count
$heldCore      = @($held | Where-Object { $_.EffectiveValueClass -eq 'CoreTelemetry' }).Count
$heldConfig    = @($held | Where-Object { $_.EffectiveValueClass -eq 'ConfigState' }).Count
& $add "| Official-API overlap | $($heldOverlap.Count) | Served by a public Defender / Graph / ARM API -- XdrLogRaider ships only portal-unique telemetry, so overlapping endpoints are held. |"
& $add "| Noise (pick-lists / bare-string catalogs / checksums) | $heldNoise | Not per-entity telemetry -- UI filter lists, id catalogs, change-detection hashes. |"
& $add "| UI helper (portal chrome) | $heldUi | Portal shell assets, summaries, and pickers -- not a telemetry stream. |"
& $add "| Reference (id catalogs) | $heldReference | Bare id/name catalogs (which entities *exist*), not their keyed state. |"
& $add "| Value/capability pending | $heldCore | CoreTelemetry-classed but blocked on a runtime capability (e.g. query/body entity fan-out) or an unresolved portal requirement -- re-ships once the basis lands. |"
& $add "| Config state (held) | $heldConfig | Config/posture endpoints held as duplicate or superseded by a shipped stream. |"
& $add ''
& $add "$($heldWithReason.Count) held operations carry an explicit, recorded ``ShipHeldReason`` (the manually body-read / live-verified holds); the remainder are held by their value class or scope decision. Categories held in full: " + (($heldOnlyCats | ForEach-Object { "**$($_.Name)**" }) -join ', ') + ' (each an official-API overlap -- the public Advanced Hunting / Incidents APIs already serve that data).'
& $add ''

# ---- Expansion surface ------------------------------------------------------
& $add '## Expansion surface'
& $add ''
& $add "XdrLogRaider's engine is **portal-agnostic** -- the derivation, build, deploy, and verify pipeline does not hardcode anything Defender-specific. ``references/inventory/`` carries a researched surface of **$researchOps operations** across **$researchCats categories** in **$portalCount Microsoft portals** (Defender XDR, Entra, Purview, Teams, Intune, Power Platform, SharePoint, Exchange, and more)."
& $add ''
& $add "v0.1.0 ships the Defender XDR slice: **$($rows.Count) of the $defenderResearchOps** researched Defender operations (across $defenderResearchCats catalogued Defender category files). Contributors can wire any catalogued portal / category / stream the engine already supports -- the manifests and per-category schemas are generated the same way for every portal. The portal research under ``references/`` is public precisely so that expansion is a data exercise, not an engine rewrite."
& $add ''

# ---- Legend / regeneration --------------------------------------------------
& $add '## How this file is generated'
& $add ''
& $add 'This catalogue is emitted by `dev-tools/Export-CatalogueDoc.ps1` from two committed sources:'
& $add ''
& $add '- **`manifests/Defender/*.psd1`** -- the deployed operation set (table, ingestion mode, cadence, path, sub-portal).'
& $add '- **`references/inventory/nodoc-defender-xdr/catalogue.json`** -- value class, ship/held decision, and held reasons.'
& $add ''
& $add 'The generator asserts that the manifest operation count equals the catalogue `Shipped == true` count, so this doc can never silently drift from what actually deploys. Run `pwsh dev-tools/Export-CatalogueDoc.ps1 -Check` to fail a build on drift.'
& $add ''

$catalogueMd = ($L -join "`n") + "`n"

# ----------------------------------------------------------------------------
# 6. Build the README fragment (compact category table, marker-wrapped).
# ----------------------------------------------------------------------------
$F = [System.Collections.Generic.List[string]]::new()
$addF = { param($s) $F.Add([string]$s) }
& $addF '<!-- CATALOGUE:START -->'
& $addF '<!-- GENERATED by dev-tools/Export-CatalogueDoc.ps1 -- do not hand-edit. -->'
& $addF ''
& $addF "**Shipped surface (v0.1.0):** $($rows.Count) read-only operations across $catCount Defender categories / $tableCount Sentinel tables / $streamCount streams. A further $($held.Count) operations are catalogued and deliberately held (see [docs/CATALOGUE.md](docs/CATALOGUE.md))."
& $addF ''
& $addF '| Category | Sentinel table | Ops | Streams | Cadence | Value class |'
& $addF '|---|---|---:|---:|---|---|'
foreach ($g in $catByCategory) {
    $catName     = $g.Name
    $catShipRows = @($rows | Where-Object { $_.Category -eq $catName })
    if ($catShipRows.Count -eq 0) { continue }   # README shows shipped categories only
    $table   = @($g.Group | Select-Object -ExpandProperty WorkspaceTable -Unique)[0]
    $streams = @($catShipRows | Select-Object -ExpandProperty Stream -Unique).Count
    $cad     = Format-CadenceDist -Items $catShipRows
    $val     = Format-Dist -Items $catShipRows -Property ValueClass
    & $addF "| $catName | ``$table`` | $($catShipRows.Count) | $streams | $cad | $val |"
}
& $addF "| **Total** | **$tableCount tables** | **$($rows.Count)** | **$streamCount** | $cadenceDist | $valueDist |"
& $addF ''
& $addF 'Full operation-level detail: [docs/CATALOGUE.md](docs/CATALOGUE.md).'
& $addF '<!-- CATALOGUE:END -->'
$fragmentMd = ($F -join "`n") + "`n"

# ----------------------------------------------------------------------------
# 7. Emit or check.
# ----------------------------------------------------------------------------
$catalogueOut = Join-Path $RepoRoot 'docs/CATALOGUE.md'
$readmePath   = Join-Path $RepoRoot 'README.md'

function Get-NormalizedText([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    ((Get-Content -LiteralPath $Path -Raw) -replace "`r`n", "`n")
}
function Compare-OrReport([string] $Path, [string] $Expected, [System.Collections.Generic.List[string]] $Drift) {
    $actual = Get-NormalizedText $Path
    $want   = $Expected -replace "`r`n", "`n"
    if ($null -eq $actual) { $Drift.Add("MISSING: $Path"); return }
    if ($actual -ne $want) { $Drift.Add("STALE:   $Path") }
}

if ($Check) {
    $drift = [System.Collections.Generic.List[string]]::new()
    Compare-OrReport $catalogueOut $catalogueMd $drift

    # If README carries the marker block, the content between markers must match the fragment body.
    $readmeRaw = Get-NormalizedText $readmePath
    if ($readmeRaw -and $readmeRaw -match '(?s)<!-- CATALOGUE:START -->.*?<!-- CATALOGUE:END -->') {
        $readmeBlock   = ($Matches[0]) -replace "`r`n", "`n"
        $fragmentBlock = (($fragmentMd -replace "`r`n", "`n").TrimEnd("`n"))
        if ($readmeBlock.TrimEnd("`n") -ne $fragmentBlock) { $drift.Add('STALE:   README.md (CATALOGUE marker block)') }
    }

    if ($drift.Count -gt 0) {
        Write-Host 'Catalogue doc DRIFT detected -- run: pwsh dev-tools/Export-CatalogueDoc.ps1' -ForegroundColor Red
        $drift | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        exit 1
    }
    Write-Host "Catalogue doc up to date ($($rows.Count) ops / $catCount categories / $streamCount streams)." -ForegroundColor Green
    exit 0
}

# utf8 (no BOM) + explicit LF -- .md files are eol=lf per .gitattributes.
[System.IO.File]::WriteAllText($catalogueOut, $catalogueMd, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Wrote $catalogueOut ($($rows.Count) ops / $catCount categories / $streamCount streams / $($held.Count) held)." -ForegroundColor Green

if ($UpdateReadme) {
    if (-not (Test-Path -LiteralPath $readmePath)) { throw "README.md not found at $readmePath" }
    $readmeText = (Get-Content -LiteralPath $readmePath -Raw) -replace "`r`n", "`n"
    if ($readmeText -notmatch '(?s)<!-- CATALOGUE:START -->.*?<!-- CATALOGUE:END -->') {
        throw 'README.md has no <!-- CATALOGUE:START --> / <!-- CATALOGUE:END --> marker block to update.'
    }
    $newBlock = ($fragmentMd -replace "`r`n", "`n").TrimEnd("`n")
    $updated  = [System.Text.RegularExpressions.Regex]::Replace(
        $readmeText, '(?s)<!-- CATALOGUE:START -->.*?<!-- CATALOGUE:END -->', $newBlock)
    [System.IO.File]::WriteAllText($readmePath, $updated, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Updated README.md marker block." -ForegroundColor Green
}
