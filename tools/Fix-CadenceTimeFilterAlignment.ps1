<#
.SYNOPSIS
    Π10 · One-shot manifest alignment · IngestionMode ↔ TimeFilter rule-based fix.

.DESCRIPTION
    The Π2 heuristic classifier produced 45 IngestionMode↔TimeFilter pairing
    inconsistencies (28 LIVESTREAM without TimeFilter=Supported + 17 SNAPSHOT
    with TimeFilter=Supported). This script applies the canonical rule:

        LIVESTREAM  →  TimeFilter = Supported   (real-time event endpoints
                                                  use incremental delta read)
        SNAPSHOT    →  TimeFilter = NotSupported (full-state snapshots ignore TF)
        EXCLUDED    →  unchanged                  (Memory Rule 2 wholesale-drops)

    Runtime Π8d TimeFilter self-heal catches any endpoints that 400-reject the
    ?since= param after the lift (per-endpoint telemetry · operator-visible).

    Idempotent · safe to re-run · emits delta count + writes manifest in place.

.EXAMPLE
    pwsh tools/Fix-CadenceTimeFilterAlignment.ps1

.NOTES
    Internal spec: Part X (Π10) classifier alignment.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ManifestPath = (Join-Path $PSScriptRoot '..' 'manifests' 'defender.psd1')
)

$ErrorActionPreference = 'Stop'
$manifestPath = (Resolve-Path $ManifestPath).Path
Write-Host "Loading manifest: $manifestPath"

$psd1Raw = Get-Content -Raw $manifestPath
$manifest = & ([scriptblock]::Create($psd1Raw))

$liftCount = 0
$demoteCount = 0
$unchangedCount = 0

foreach ($entry in $manifest.Entries) {
    $mode = if ($entry.ContainsKey('IngestionMode')) { [string]$entry.IngestionMode } else { 'SNAPSHOT' }
    $tf   = if ($entry.ContainsKey('TimeFilter'))    { [string]$entry.TimeFilter    } else { 'NotSupported' }

    if ($mode -eq 'LIVESTREAM' -and $tf -ne 'Supported') {
        $entry.TimeFilter = 'Supported'
        if (-not $entry.ContainsKey('TimeFilterParam') -or [string]::IsNullOrEmpty($entry.TimeFilterParam)) {
            $entry.TimeFilterParam = 'since'
        }
        $liftCount++
    } elseif ($mode -eq 'SNAPSHOT' -and $tf -eq 'Supported') {
        $entry.TimeFilter = 'NotSupported'
        $demoteCount++
    } else {
        $unchangedCount++
    }
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════════"
Write-Host "Classifier alignment results:"
Write-Host "  LIVESTREAM lifted to TimeFilter=Supported:   $liftCount"
Write-Host "  SNAPSHOT demoted to TimeFilter=NotSupported: $demoteCount"
Write-Host "  Unchanged (already aligned):                  $unchangedCount"
Write-Host "  Total entries: $($manifest.Entries.Count)"
Write-Host "═══════════════════════════════════════════════════════════════════"
Write-Host ""

if ($liftCount + $demoteCount -eq 0) {
    Write-Host "Manifest already aligned · no changes needed." -ForegroundColor Green
    exit 0
}

if (-not $PSCmdlet.ShouldProcess($manifestPath, "Rewrite manifest with $($liftCount + $demoteCount) alignment fixes")) {
    Write-Host "Dry-run · manifest NOT written." -ForegroundColor Yellow
    exit 0
}

# Re-serialize psd1 · preserve outer @{ Generated/Portal/Entries }  structure
# We patched the in-memory $manifest object; serialize the modified Entries array
# back into the psd1 by string-replacing TimeFilter+TimeFilterParam fields per entry.
#
# Safer than full psd1 round-trip (which loses formatting + comments).
# Strategy: for each modified entry, find its slug in the psd1 source and re-emit
# its TimeFilter / TimeFilterParam lines.

$lines = $psd1Raw -split "`r?`n"
$newLines = New-Object System.Collections.Generic.List[string]
$currentSlug = $null
$bracketDepth = 0
$entryStarted = $false

foreach ($line in $lines) {
    # Track entry boundaries via Slug pattern
    if ($line -match "^\s+Slug\s*=\s*'([^']+)'") {
        $currentSlug = $matches[1]
    }

    # Find the matching manifest entry for current slug
    $match = $null
    if ($currentSlug) {
        $match = $manifest.Entries | Where-Object Slug -eq $currentSlug | Select-Object -First 1
    }

    if ($match) {
        # Rewrite TimeFilter line
        if ($line -match "^(\s+)TimeFilter\s*=\s*'[^']*'(.*)$") {
            $line = "$($matches[1])TimeFilter        = '$($match.TimeFilter)'$($matches[2])"
        }
        # Rewrite TimeFilterParam line
        elseif ($line -match "^(\s+)TimeFilterParam\s*=\s*'[^']*'(.*)$") {
            $line = "$($matches[1])TimeFilterParam   = '$($match.TimeFilterParam)'$($matches[2])"
        }
    }

    $newLines.Add($line)
}

$newContent = $newLines -join [Environment]::NewLine
Set-Content -LiteralPath $manifestPath -Value $newContent -Encoding utf8BOM -NoNewline

Write-Host "Manifest rewritten · $($liftCount + $demoteCount) entries fixed."
Write-Host "Re-verify with: pwsh -c '`$m = & ([scriptblock]::Create((Get-Content -Raw $manifestPath))); `$m.Entries | Where { `$_.IngestionMode -eq ''LIVESTREAM'' -and `$_.TimeFilter -ne ''Supported'' } | Measure-Object'"
