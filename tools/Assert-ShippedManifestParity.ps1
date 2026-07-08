#Requires -Version 7.4
<#
.SYNOPSIS
INVERSE-MANIFEST INVARIANT gate · every Shipped category in the catalogue MUST have a manifest (plan §6.2 ship-gate
twin). The INVERSE of tools/Validate-Manifests.ps1 (which only validates manifests that EXIST · it cannot see a
Shipped category that produced NO manifest).

.DESCRIPTION
The catalogue ship-gate (dev-tools/Build-Catalogue.ps1) marks an op Shipped=$true WITHOUT any manifest term — the
manifest is a DOWNSTREAM per-category artifact (dev-tools/Generate-Manifest.ps1 · `Where Shipped -eq $true` for a
given -Group). So a category can sit Shipped=true in the catalogue with NO manifest file silently (the
VulnerabilityManagement-class drift: 15 ops Shipped=true under a category whose manifest was never generated /
committed). Validate-Manifests walks manifests/<Portal>/*.psd1, so it is BLIND to that gap.

This tool closes it from the catalogue side:
  1. Read the Defender catalogue (the SAME source the ship-gate writes · references/inventory/<portalKey>/catalogue.json).
  2. Compute the distinct set of Categories with >=1 op where Shipped -eq $true (the EXACT ship-gate predicate).
  3. Map each such Category to its manifest filename via the SHARED canonical tokenizer Get-XdrCategoryToken — the
     IDENTICAL logic Generate-Manifest.ps1 uses to turn -Group "Endpoint Management" into manifests/Defender/
     EndpointManagement.psd1 (NOT a new normalization · single-source so the axis can never disagree with the generator).
  4. FAIL (exit 1) — listing each offending category + its expected manifest path — if any Shipped category lacks a
     manifest under manifests/<Portal>/.

Portal-generic: -Portal resolves through references/inventory/portals.json EXACTLY as Generate-Manifest does
(Friendly · Key · Short), so this is not hardcoded to a single portal.

Exit codes:
- 0 · every Shipped category has a manifest (OR the catalogue/manifests dir is absent · bootstrap) · push allowed
- 1 · >=1 Shipped category has NO manifest (the inverse-invariant violation) · push blocked
- 2 · tool error (corrupt catalogue · IO failure)
#>
[CmdletBinding()]
param(
    [string] $Portal = 'Defender',
    [string] $RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path,
    # Emit a SINGLE structured-JSON summary object to stdout (parity with Validate-Manifests -Json · the gauntlet axis
    # ConvertFrom-Json's it instead of regex-scraping). Exit code unchanged (1 on FAIL · 0 on PASS).
    [switch] $Json
)
$ErrorActionPreference = 'Stop'
# UTF-8 stdout (no BOM) · same rationale as Generate-Manifest/Run-PrePushGauntlet (the sh pre-push hook launches pwsh
# under the OEM codepage · a category name with non-ASCII would mangle when this tool's stdout is captured by the axis).
$OutputEncoding = [System.Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
# Set-StrictMode intentionally omitted · parity with Validate-Manifests (this is a CI gate iterating ConvertFrom-Json
# objects · StrictMode Latest treats absent JSON properties as errors). The verification value is the gate logic.

# SHARED category tokenizer (Xdr.Common.Parser.Get-XdrCategoryToken) — THE single Category->token rewrite that
# Build-Catalogue, Generate-Manifest and Build-PerCategorySchema all import. Reusing it here (not a private copy) is
# what makes the category->manifest-filename mapping byte-identical to the one Generate-Manifest emits: -Group
# "Endpoint Management" -> $groupToken "EndpointManagement" -> manifests/Defender/EndpointManagement.psd1. Module
# resolves relative to THIS SCRIPT (not -RepoRoot · callers/tests may point -RepoRoot at a data-only synthetic root).
Import-Module (Join-Path $PSScriptRoot '..\src\Modules\Xdr.Common.Parser\Xdr.Common.Parser.psd1') -Force -DisableNameChecking -ErrorAction Stop

# Portal-generic PortalKey resolution from portals.json (accepts Friendly · Key · Short) — copied verbatim from
# Generate-Manifest.ps1 so the -Portal -> portalKey -> catalogue.json path is the SAME on both sides (no drift).
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
if (-not $portalKey) { throw "Assert-ShippedManifestParity: unknown Portal '$Portal' (not resolvable from portals.json by friendly/key/short)" }

$catPath      = Join-Path $RepoRoot "references/inventory/$portalKey/catalogue.json"
$manifestsDir = Join-Path $RepoRoot "manifests/$Portal"

# Bootstrap tolerance (parity with Validate-Manifests' "no manifests / no catalogue" early-out): if the catalogue does
# not exist there is nothing Shipped to assert against — a clean PASS, never a silent crash.
if (-not (Test-Path $catPath)) {
    if ($Json) { [pscustomobject]@{ tool = 'Assert-ShippedManifestParity'; portal = $Portal; verdict = 'PASS'; reason = "no catalogue at $catPath (bootstrap)"; shippedCategoryCount = 0; matched = @(); missing = @() } | ConvertTo-Json -Depth 5 }
    else { Write-Host "Assert-ShippedManifestParity: catalogue not present at $catPath · acceptable for bootstrap state" }
    exit 0
}

$catalogue = Get-Content $catPath -Raw | ConvertFrom-Json

# THE ship-gate predicate (identical to Generate-Manifest's `$_.Shipped -eq $true` filter): the distinct set of
# Categories that have >=1 Shipped op. These are EXACTLY the categories the generator would emit a manifest for, so
# each MUST have one committed. (A category with ops but 0 Shipped — e.g. Advanced Hunting / VulnerabilityManagement
# after un-ship — is correctly NOT required to have a manifest · the runtime never dispatches it.)
$shippedCats = @($catalogue.Operations | Where-Object { $_.Shipped -eq $true } | ForEach-Object { [string]$_.Category } | Sort-Object -Unique)

$matched = [System.Collections.Generic.List[object]]::new()
$missing = [System.Collections.Generic.List[object]]::new()
foreach ($cat in $shippedCats) {
    $token        = Get-XdrCategoryToken -Category $cat                 # SAME mapping Generate-Manifest uses ($groupToken)
    $manifestName = "$token.psd1"
    $manifestPath = Join-Path $manifestsDir $manifestName
    $rel          = "manifests/$Portal/$manifestName"
    if (Test-Path $manifestPath) {
        $matched.Add([pscustomobject]@{ category = $cat; manifest = $rel })
    } else {
        $missing.Add([pscustomobject]@{ category = $cat; expectedManifest = $rel })
    }
}

$verdict = if ($missing.Count -gt 0) { 'FAIL' } else { 'PASS' }
$reason  = if ($missing.Count -gt 0) {
    "$($missing.Count) Shipped category(ies) WITHOUT a manifest (inverse-invariant violation): " + (($missing | ForEach-Object { "$($_.category) -> $($_.expectedManifest)" }) -join ' · ')
} else {
    "all $($shippedCats.Count) Shipped category(ies) have a manifest"
}

if ($Json) {
    [pscustomobject]@{
        tool                 = 'Assert-ShippedManifestParity'
        portal               = $Portal
        verdict              = $verdict
        reason               = $reason
        shippedCategoryCount = $shippedCats.Count
        matched              = @($matched)
        missing              = @($missing)
    } | ConvertTo-Json -Depth 5
} else {
    Write-Host ''
    Write-Host '======================================================================'
    Write-Host "Assert-ShippedManifestParity · INVERSE manifest invariant ($Portal)"
    Write-Host '======================================================================'
    Write-Host "Shipped categories (catalogue · >=1 Shipped op) : $($shippedCats.Count)"
    Write-Host '----------------------------------------------------------------------'
    foreach ($m in $matched) { Write-Host "  OK      $($m.category)  ->  $($m.manifest)" -ForegroundColor DarkGray }
    if ($missing.Count -gt 0) {
        Write-Host ''
        Write-Host 'MISSING manifests (Shipped in catalogue · BLOCKS push):' -ForegroundColor Red
        foreach ($x in $missing) { Write-Host "  MISSING $($x.category)  ->  $($x.expectedManifest)" -ForegroundColor Red }
        Write-Host ''
        Write-Host "Assert-ShippedManifestParity · FAIL · generate+commit the missing manifest(s) OR un-ship the category in the catalogue"
    } else {
        Write-Host ''
        Write-Host "Assert-ShippedManifestParity GREEN · every Shipped category has a manifest"
    }
}
if ($verdict -eq 'FAIL') { exit 1 } else { exit 0 }
