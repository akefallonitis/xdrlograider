#requires -Version 7.0
<#
.SYNOPSIS
  P7 · Reclassify ProbeMode based on EMPIRICAL probe results · lifts heuristic
  reclassifications back to Probe when actual response was 2xx.

.DESCRIPTION
  Reads latest capture-summary.json · for each SubPortalAuth or PathParamGated
  entry that returned 'live' or 'live-empty' empirically, reclassifies to Probe.

  This implements the operator's correct intuition that heuristic reclassification
  (path-prefix matching for sub-portals · placeholder presence for path-params)
  was over-conservative · the proxy CAN carry sccauth for many sub-portal paths.

  Preserves reclassifications when probe returned 4xx/5xx/html-terminal (those
  endpoints truly need additional auth · v0.2.0 work).

.NOTES
  Author: Alex Kefallonitis · 2026-05-20.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ManifestPath  = (Join-Path $PSScriptRoot '..' 'manifests' 'defender.psd1'),
    [string]$ProbeIterDir  = ''   # auto-detect latest if empty
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $ProbeIterDir) {
    $ProbeIterDir = (Get-ChildItem (Join-Path $repoRoot 'tests/results') -Directory |
        Where-Object Name -like 'iter-2026*' |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}
$summary = Join-Path $ProbeIterDir 'capture-summary.json'
if (-not (Test-Path $summary)) { throw "No capture-summary.json in $ProbeIterDir" }

$d = Get-Content -Raw $summary | ConvertFrom-Json
$manifest = & ([scriptblock]::Create((Get-Content -Raw -LiteralPath $ManifestPath)))
$entries = @($manifest.Entries)

# Build lookup: EntryKey → Classification
$probeMap = @{}
foreach ($r in $d.Results) { $probeMap[$r.EntryKey] = $r.Classification }

# Identify candidates for lift: ProbeMode in {SubPortalAuth · PathParamGated} AND probe returned 2xx
$plan = @()
foreach ($e in $entries) {
    if ($e.ProbeMode -notin @('SubPortalAuth','PathParamGated')) { continue }
    if (-not $probeMap.ContainsKey($e.EntryKey)) { continue }
    $cls = $probeMap[$e.EntryKey]
    if ($cls -in @('live','live-empty')) {
        $plan += @{ EntryKey = $e.EntryKey; OldMode = $e.ProbeMode; NewMode = 'Probe'; Classification = $cls }
    }
}

Write-Host "Empirical reclassification plan:"
Write-Host ("  SubPortalAuth → Probe: " + (@($plan | Where-Object { $_.OldMode -eq 'SubPortalAuth' })).Count)
Write-Host ("  PathParamGated → Probe: " + (@($plan | Where-Object { $_.OldMode -eq 'PathParamGated' })).Count)
Write-Host ("  Total entries to lift: " + $plan.Count)

if ($plan.Count -eq 0) { Write-Host "Nothing to reclassify"; return }
if (-not $PSCmdlet.ShouldProcess($ManifestPath, "Reclassify $($plan.Count) entries")) { return }

# Line-by-line mutation
$lines = [System.Collections.Generic.List[string]]::new()
Get-Content $ManifestPath | ForEach-Object { [void]$lines.Add($_) }

# Index entry-block boundaries
$blocks = @{}
$current = $null
for ($i = 0; $i -lt $lines.Count; $i++) {
    $ln = $lines[$i]
    if (-not $current -and $ln -match '^        @\{\s*$') { $current = @{Start=$i; ProbeLine=$null; EntryKey=$null} }
    if ($current) {
        if ($ln -match "^\s+EntryKey\s+=\s+'([^']+)'") { $current.EntryKey = $Matches[1] }
        elseif ($ln -match '^(\s+ProbeMode\s+=\s+)') { $current.ProbeLine = $i }
        elseif ($ln -match '^        \},?\s*$') {
            if ($current.EntryKey -and $current.ProbeLine) { $blocks[$current.EntryKey] = $current }
            $current = $null
        }
    }
}

$applied = 0
foreach ($p in $plan) {
    $b = $blocks[$p.EntryKey]
    if (-not $b) { continue }
    $ln = $lines[$b.ProbeLine]
    if ($ln -match "^(\s+ProbeMode\s+=\s+)'([^']+)'(.*)$") {
        $lines[$b.ProbeLine] = $Matches[1] + "'$($p.NewMode)'" + $Matches[3]
        $applied++
    }
}

[System.IO.File]::WriteAllLines($ManifestPath, $lines.ToArray(), [System.Text.UTF8Encoding]::new($false))
Write-Host "Applied $applied empirical reclassifications" -ForegroundColor Green

# Verify
$m = & ([scriptblock]::Create((Get-Content -Raw -LiteralPath $ManifestPath)))
$dist = $m.Entries | Group-Object ProbeMode | Sort-Object Count -Descending
Write-Host "`nFinal ProbeMode distribution:"
$dist | Format-Table Count, Name -AutoSize
