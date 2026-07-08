#Requires -Version 7.4
<#
.SYNOPSIS
The COMPLETE offline §4.A cataloguing sweep — enforces ALL A1-A10 structural axes over EVERY shipped op so the
live re-prove CONFIRMS, never DISCOVERS (the anti-trial-and-error lock). Emits a 0-flags gate: exit 2 on ANY flag.

.DESCRIPTION
Loads the SoT (references/inventory/<portalKey>/catalogue.json), the manual curation (curation.json · overlapVerdict),
and the deployed manifests (manifests/<Portal>/*.psd1 · ColumnTypes + canonical ProjectionMap), then runs the
pure A1-A10 sweep (tools/lib/Xdr.PostDeployAudit.ps1 · Get-XdrShippedOpFlags) over every catalogue op with
Shipped=true. Reports each flag with its axis + remediation curation-seam, and the 0-flags verdict.

Axes enforced (the SWEEP TOOL contract · SSOT §4.A):
  A1  ZERO-PROJ                · a data-grade op (CoreTelemetry/ConfigState) with an EMPTY ProjectionMap
  A3  LOW-VALUE-CLASS          · a SHIPPED op scored Noise/UiHelper/Reference/StaticCatalog (→ MANDATORY body-read)
  A3  COLUMNTYPE-NOT-PROJECTED · a manifest ColumnTypes key NOT a CASE-SENSITIVE member of the canonical projection
                                 (the cat-6 2-prepush-round lesson · -contains is case-insensitive so a self-check misses it)
  A4  NO-KEY                   · a CURSOR/WINDOW op with NO NaturalKey AND no CursorField (→ dup-accumulation)
  A6  FANOUT-NO-PARENT         · EntityResolution=Resolved with an empty DependsOn (→ id-cache never seeds = 0 children)
  A8  NEEDS-LIVE-PROBE         · a postman/openapi/conservative EvidenceTier op (never live-captured · pre-ship probe owed)
  A9  OVERLAP-NO-VERDICT       · OfficialApiOverlap in {Likely,Exact} WITHOUT an overlapVerdict (P11 HARD GATE)
  A9  OVERLAP-HOLD-SHIPPED     · overlapVerdict=hold but the op is shipped (contradiction)

A2 (items-shape) / A5 (window contract) / A7 (cadence) / A10 (verify-probeability) are structurally enforced
elsewhere (Validate-Manifests TimeFilter/Pagination contracts · CadenceParseable · the fan-out FANOUT verdict in
Verify-XdrLiveContent) and the MANDATORY MANUAL BODY-READ remains the operator's load-bearing step ON TOP — the
A3 LOW-VALUE-CLASS + A8 NEEDS-LIVE-PROBE flags are the sweep's hooks that FORCE that body-read/probe to happen.

OFFLINE: no Azure, no network — pure file reads. Runs in CI and in the prepush gauntlet.

.EXAMPLE
pwsh tools/Invoke-Xdr4ASweep.ps1
pwsh tools/Invoke-Xdr4ASweep.ps1 -Portal Defender -PortalKey nodoc-defender-xdr
#>
[CmdletBinding()]
param(
    [string] $Portal = 'Defender',
    [string] $PortalKey = 'nodoc-defender-xdr',
    # Scope (SSOT §4.A: "per shipped op" = the ops a category SHIPS, i.e. the DEPLOYED ship-set present in a
    # manifest — those must be byte-clean so the live re-prove CONFIRMS). 'Deployed' (default · the prepush gate)
    # sweeps only catalogue-Shipped ops that are ALSO in a manifest. 'All' sweeps the entire forward catalogue
    # (the orientation aid · surfaces the STILL-OWED debts for un-onboarded cats — expected non-zero, not a gate).
    [ValidateSet('Deployed','All')] [string] $Scope = 'Deployed',
    # Optional · sweep ONE category's ship-set only (the category being onboarded — the SSOT §4.A "converge this
    # category in ONE round" usage: sweep → 0 flags → prepush CONFIRMS). Matches the catalogue's Category field.
    # Omitted → all in-$Scope shipped ops.
    [string] $Category,
    [string] $RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$OutputEncoding = [System.Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

. (Join-Path $PSScriptRoot 'lib/Xdr.PostDeployAudit.ps1')

$cataloguePath = Join-Path $RepoRoot "references/inventory/$PortalKey/catalogue.json"
$curationPath  = Join-Path $RepoRoot "references/inventory/$PortalKey/curation.json"
$manifestsDir  = Join-Path $RepoRoot "manifests/$Portal"

if (-not (Test-Path $cataloguePath)) { Write-Error "catalogue.json not found at $cataloguePath"; exit 3 }

Write-Host "[4A-sweep] catalogue=$cataloguePath · scope=$Scope" -ForegroundColor Cyan
$catalogue = Get-Content $cataloguePath -Raw | ConvertFrom-Json
$shippedAll = @($catalogue.Operations | Where-Object { $_.Shipped })
if ($shippedAll.Count -eq 0) {
    # A vacuous sweep (0 shipped ops) is itself suspect — never silently pass.
    Write-Host '[4A-sweep] NO shipped ops in the catalogue (Shipped=true) — the sweep is vacuous. Expect >=1 shipped op.' -ForegroundColor Red
    exit 2
}

# Deployed OperationId set (the ops actually present in a manifest = the SHIP-SET that must be clean).
$deployedOpIds = @{}
if (Test-Path $manifestsDir) {
    foreach ($f in (Get-ChildItem $manifestsDir -Filter '*.psd1' -ErrorAction SilentlyContinue)) {
        $m = Import-PowerShellDataFile -LiteralPath $f.FullName -ErrorAction SilentlyContinue
        if (-not $m -or -not $m.ContainsKey('Operations')) { continue }
        foreach ($op in @($m.Operations)) {
            if ($op.ContainsKey('Provenance') -and $op.Provenance.ContainsKey('OperationId')) { $deployedOpIds[[string]$op.Provenance.OperationId] = $true }
        }
    }
}
# @()-wrap every filter result (a single-match Where-Object unwraps to a scalar → .Count throws under StrictMode;
# an if/else returning a bare collection can also collapse). Force array context at each assignment.
$shippedScoped = @($shippedAll)
if ($Scope -eq 'Deployed') { $shippedScoped = @($shippedAll | Where-Object { $deployedOpIds.ContainsKey([string]$_.OperationId) }) }
# Optional per-category narrowing (the "converge ONE category" usage · catalogue Category may contain spaces).
$shippedOps = @($shippedScoped)
if ($Category) { $shippedOps = @($shippedScoped | Where-Object { [string]$_.Category -eq $Category }) }
if ($Category -and $shippedOps.Count -eq 0) {
    Write-Host "[4A-sweep] -Category '$Category' selected 0 shipped ops in scope=$Scope. Check the category name (catalogue Category field) and that it has shipped ops." -ForegroundColor Red
    exit 2
}
if ($shippedOps.Count -eq 0) {
    Write-Host "[4A-sweep] scope=$Scope selected 0 ops (no manifest ops match a catalogue Shipped op) — nothing to sweep, but the catalogue HAS $($shippedAll.Count) shipped ops. Check the manifest Provenance.OperationId mapping." -ForegroundColor Red
    exit 2
}
Write-Host "[4A-sweep] $($shippedOps.Count) op(s) to sweep (scope=$Scope · catalogue Shipped=$($shippedAll.Count) · deployed-in-manifest=$($deployedOpIds.Count))" -ForegroundColor Cyan

# ── overlapVerdict map (OperationId -> 'ship'|'hold') · the A9/P11 adjudication source ──────────────
$overlapVerdicts = @{}
if (Test-Path $curationPath) {
    $cur = Get-Content $curationPath -Raw | ConvertFrom-Json
    if ($cur.PSObject.Properties.Name -contains 'overlapVerdict') {
        foreach ($p in $cur.overlapVerdict.PSObject.Properties) {
            if ($p.Name -ne '_doc') { $overlapVerdicts[[string]$p.Name] = [string]$p.Value.decision }
        }
    }
}

# ── manifest projection columns + ColumnTypes keys per OperationId (the A3 subset source · canonical casing) ──
# The manifest carries the CANONICAL-cased ProjectionMap.Keys (post Generate-Manifest) + ColumnTypes, keyed by
# Provenance.OperationId — the SAME OperationId the catalogue uses. Only the SHIPPED (manifest-present) ops have
# these; un-deployed catalogue ops get an empty set (A3 columnType subset is then skipped for them).
$manifestProjByOpId = @{}
$manifestCtKeysByOpId = @{}
if (Test-Path $manifestsDir) {
    foreach ($f in (Get-ChildItem $manifestsDir -Filter '*.psd1' -ErrorAction SilentlyContinue)) {
        $m = Import-PowerShellDataFile -LiteralPath $f.FullName -ErrorAction SilentlyContinue
        if (-not $m -or -not $m.ContainsKey('Operations')) { continue }
        foreach ($op in @($m.Operations)) {
            $oid = if ($op.ContainsKey('Provenance') -and $op.Provenance.ContainsKey('OperationId')) { [string]$op.Provenance.OperationId } else { '' }
            if ([string]::IsNullOrEmpty($oid)) { continue }
            if ($op.ContainsKey('ProjectionMap') -and $op.ProjectionMap) {
                $manifestProjByOpId[$oid] = @($op.ProjectionMap.Keys | ForEach-Object { [string]$_ })
            }
            if ($op.ContainsKey('ColumnTypes') -and $op.ColumnTypes) {
                $manifestCtKeysByOpId[$oid] = @($op.ColumnTypes.Keys | ForEach-Object { [string]$_ })
            }
        }
    }
}

# ── run the pure sweep ──────────────────────────────────────────────────────────────────────────────
$result = Invoke-XdrShipSetSweep -ShippedOps $shippedOps -OverlapVerdicts $overlapVerdicts `
    -ManifestProjectionByOpId $manifestProjByOpId -ManifestColumnTypeKeysByOpId $manifestCtKeysByOpId `
    -DeployedOpIds $deployedOpIds

$flags = @($result.Flags)
Write-Host ''
if ($flags.Count -eq 0) {
    Write-Host "=== §4.A SWEEP · 0 FLAGS over $($shippedOps.Count) shipped ops (A1/A3/A4/A6/A8/A9 clean · prepush will CONFIRM not DISCOVER) ===" -ForegroundColor Green
    Write-Host '[4A-sweep] REMINDER · the MANDATORY MANUAL BODY-READ of every shipped op (genuine-telemetry vs noise/checksum/pick-list/dup) is the load-bearing step ON TOP · the structural sweep is necessary-not-sufficient.' -ForegroundColor DarkGray
    exit 0
}

Write-Host "=== §4.A SWEEP · $($flags.Count) FLAG(S) — fix at the named curation seam, re-catalogue, re-sweep until 0 ===" -ForegroundColor Red
foreach ($fl in $flags) { Write-Host "  ! $fl" -ForegroundColor Yellow }
Write-Host ''
Write-Host "[4A-sweep] $($flags.Count) flag(s) · a flag here is a cataloguing miss the live re-prove would otherwise DISCOVER reactively (one wasted round per miss). Resolve via curation (valueClass/shipHold/overlapVerdict/columnTypes/projectionAlias/entityIdSource/...) BEFORE prepush." -ForegroundColor Red
exit 2
