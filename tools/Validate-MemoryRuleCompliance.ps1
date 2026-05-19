<#
.SYNOPSIS
    NEW Gate AA (Phase 0 Step 5 + plan §6) · enforce Memory Rule 2 on all manifests.

.DESCRIPTION
    Hard-fails (exit 1) if ANY manifest under manifests/<portal>.psd1 contains an entry
    whose SubArea is in the wholesale-excluded list:
       AdvancedHunting · AlertsIncidents · LiveResponse

    Also enforces Gate AE (D-36): no graph.microsoft.com / graph.windows.net hosts in any Path.
    Also enforces Gate Y  (Step 7): every entry has IngestionMode ∈ {LIVESTREAM, SNAPSHOT, EXCLUDED}.

    Loaded by:
      - Phase 0 Step 5 EXIT GATE
      - tools/Audit-Wiring.ps1 (full A-Z sweep)
      - CI gate (release.yml)

.OUTPUTS
    Writes manifests/_gate-aa.json with structured pass/fail.
    Console summary + exit 0/1.
#>
[CmdletBinding()]
param(
    [string]   $ManifestRoot,
    [string[]] $ForbiddenSubAreas = @('AdvancedHunting','AlertsIncidents','LiveResponse'),
    [string]   $ForbiddenHostRegex = 'graph\.microsoft\.com|graph\.windows\.net',
    [switch]   $Quiet
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $ManifestRoot) { $ManifestRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'manifests' }
if (-not (Test-Path $ManifestRoot)) { throw "Manifest root not found: $ManifestRoot" }

$violationsGateAA = [System.Collections.Generic.List[hashtable]]::new()
$violationsGateAE = [System.Collections.Generic.List[hashtable]]::new()
$violationsGateY  = [System.Collections.Generic.List[hashtable]]::new()
$validIngestionModes = @('LIVESTREAM','SNAPSHOT','EXCLUDED')
$manifestStats   = [ordered]@{}

# Find all <portal>.psd1 (exclude _step5-audit and _gate-* meta files)
$manifestFiles = Get-ChildItem -Path $ManifestRoot -Filter '*.psd1' -File | Where-Object { $_.Name -notmatch '^_' }

foreach ($mf in $manifestFiles) {
    $portalName = [System.IO.Path]::GetFileNameWithoutExtension($mf.Name)
    try {
        $manifest = & ([scriptblock]::Create((Get-Content -Raw -LiteralPath $mf.FullName)))
    } catch {
        if (-not $Quiet) { Write-Warning "Validate-MemoryRuleCompliance: failed to parse $($mf.Name): $($_.Exception.Message)" }
        $violationsGateAA.Add(@{ Portal=$portalName; SubArea='<parse-error>'; EntryKey='<n/a>'; Reason="parse error: $($_.Exception.Message)" }) | Out-Null
        continue
    }
    if (-not $manifest.ContainsKey('Entries')) {
        $manifestStats[$portalName] = 0; continue
    }

    $entries = @($manifest.Entries)
    $manifestStats[$portalName] = $entries.Count

    foreach ($e in $entries) {
        $sa = if ($e.ContainsKey('SubArea')) { [string]$e.SubArea } else { '' }
        if ($ForbiddenSubAreas -contains $sa) {
            $violationsGateAA.Add(@{
                Portal   = $portalName
                SubArea  = $sa
                EntryKey = if ($e.ContainsKey('EntryKey')) { [string]$e.EntryKey } else { '<missing>' }
                Path     = if ($e.ContainsKey('Path'))     { [string]$e.Path }     else { '' }
                Reason   = "SubArea '$sa' is wholesale-excluded per Memory Rule 2"
            }) | Out-Null
        }
        $path = if ($e.ContainsKey('Path')) { [string]$e.Path } else { '' }
        if ($path -and $path -match $ForbiddenHostRegex) {
            $violationsGateAE.Add(@{
                Portal   = $portalName
                SubArea  = $sa
                EntryKey = if ($e.ContainsKey('EntryKey')) { [string]$e.EntryKey } else { '<missing>' }
                Path     = $path
                Reason   = "Path matches forbidden host regex '$ForbiddenHostRegex' (Decision D-36)"
            }) | Out-Null
        }

        # Gate Y · IngestionMode populated with a valid value (Step 7)
        $im = if ($e.ContainsKey('IngestionMode')) { [string]$e.IngestionMode } else { '' }
        if (-not $im -or $validIngestionModes -notcontains $im) {
            $violationsGateY.Add(@{
                Portal   = $portalName
                SubArea  = $sa
                EntryKey = if ($e.ContainsKey('EntryKey')) { [string]$e.EntryKey } else { '<missing>' }
                IngestionMode = $im
                Reason   = "IngestionMode '$im' not in (LIVESTREAM, SNAPSHOT, EXCLUDED) · run Classify-EndpointIngestion.ps1"
            }) | Out-Null
        }
    }
}

$gatePass = ($violationsGateAA.Count -eq 0) -and ($violationsGateAE.Count -eq 0) -and ($violationsGateY.Count -eq 0)

# Write structured report
$report = [ordered]@{
    GeneratedUtc      = [datetime]::UtcNow.ToString('o')
    GateAA_pass       = ($violationsGateAA.Count -eq 0)
    GateAE_pass       = ($violationsGateAE.Count -eq 0)
    GateY_pass        = ($violationsGateY.Count -eq 0)
    ManifestRoot      = $ManifestRoot
    ForbiddenSubAreas = $ForbiddenSubAreas
    ForbiddenHostRegex= $ForbiddenHostRegex
    ValidIngestionModes = $validIngestionModes
    ManifestStats     = $manifestStats
    GateAA_violations = $violationsGateAA
    GateAE_violations = $violationsGateAE
    GateY_violations  = $violationsGateY
}
$reportPath = Join-Path $ManifestRoot '_gate-aa.json'
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reportPath -Encoding UTF8

if (-not $Quiet) {
    Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Gate AA (Memory Rule 2) + Gate AE (D-36 host ban) validator" -ForegroundColor Cyan
    Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Manifest root: $ManifestRoot"
    Write-Host "  Forbidden sub-areas: $($ForbiddenSubAreas -join ' · ')"
    Write-Host "  Forbidden host regex: $ForbiddenHostRegex"
    Write-Host ""
    foreach ($p in $manifestStats.Keys) {
        Write-Host ("  · {0,-18} {1,5} entries" -f $p, $manifestStats[$p])
    }
    Write-Host ""
    $aaCol = if ($report.GateAA_pass) { 'Green' } else { 'Red' }
    $aeCol = if ($report.GateAE_pass) { 'Green' } else { 'Red' }
    $yCol  = if ($report.GateY_pass)  { 'Green' } else { 'Red' }
    Write-Host "  Gate AA (no AH/AI/LR sub-areas):    $(if($report.GateAA_pass){'PASS'}else{'FAIL'})" -ForegroundColor $aaCol
    Write-Host "  Gate AE (no graph host in path):    $(if($report.GateAE_pass){'PASS'}else{'FAIL'})" -ForegroundColor $aeCol
    Write-Host "  Gate Y  (IngestionMode populated):  $(if($report.GateY_pass){'PASS'}else{'FAIL'})" -ForegroundColor $yCol
    if (-not $report.GateAA_pass) {
        Write-Host ""
        Write-Host "  Gate AA violations ($($violationsGateAA.Count)):" -ForegroundColor Red
        foreach ($v in $violationsGateAA | Select-Object -First 10) {
            Write-Host "    - $($v.Portal) :: $($v.SubArea) :: $($v.EntryKey)"
        }
        if ($violationsGateAA.Count -gt 10) { Write-Host "    (… $($violationsGateAA.Count - 10) more)" }
    }
    if (-not $report.GateAE_pass) {
        Write-Host ""
        Write-Host "  Gate AE violations ($($violationsGateAE.Count)):" -ForegroundColor Red
        foreach ($v in $violationsGateAE | Select-Object -First 10) {
            Write-Host "    - $($v.Portal) :: $($v.Path)"
        }
    }
    if (-not $report.GateY_pass) {
        Write-Host ""
        Write-Host "  Gate Y violations ($($violationsGateY.Count)):" -ForegroundColor Red
        foreach ($v in $violationsGateY | Select-Object -First 10) {
            Write-Host "    - $($v.Portal) :: $($v.EntryKey) :: IngestionMode='$($v.IngestionMode)'"
        }
        if ($violationsGateY.Count -gt 10) { Write-Host "    (… $($violationsGateY.Count - 10) more)" }
    }
    Write-Host ""
    Write-Host "  Report: $reportPath"
}

if (-not $gatePass) { exit 1 }
exit 0
