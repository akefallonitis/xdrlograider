#Requires -Version 7.4
<#
.SYNOPSIS
    Reads the most recent PHASE_STATE_<phase>.json checkpoint · S-2 of v0.1.0 P0 v2 RESET.

.DESCRIPTION
    Used at session start to determine current phase + ticked gates. Scans
    tests/results/iter-*/PHASE_STATE_*.json files and returns the highest-phase
    checkpoint as a PSCustomObject. If no checkpoints exist yet, returns $null.

    Phase ordering (highest wins): G > 0m > 0l > 0k > 0j > 0i > 0h > 0g > 0f > 0e > 0d > 0c > 0b > 0a.
    Within the same phase, most recent LastWriteTime wins.

.PARAMETER Phase
    Optional filter — return checkpoint for a specific phase only (returns $null if not found).

.PARAMETER AllPhases
    Return ALL phase checkpoints (one entry per phase, most recent per phase).

.EXAMPLE
    pwsh tools/Read-LatestPhaseState.ps1
    pwsh tools/Read-LatestPhaseState.ps1 -Phase 0a
    pwsh tools/Read-LatestPhaseState.ps1 -AllPhases | Sort-Object phase

.NOTES
    Internal spec: Part VIII (S-2) phase-state reader · Part III §3.11 continuity model.
#>

[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [string]$Phase,
    [switch]$AllPhases
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$iterRoot = Join-Path $repoRoot 'tests/results'

if (-not (Test-Path $iterRoot)) {
    return $null
}

$allCheckpoints = Get-ChildItem -Path $iterRoot -Recurse -Filter 'PHASE_STATE_*.json' -ErrorAction SilentlyContinue
if (-not $allCheckpoints) {
    return $null
}

$phaseOrder = @{
    '0a' = 1; '0b' = 2; '0c' = 3; '0d' = 4; '0e' = 5; '0f' = 6
    '0g' = 7; '0h' = 8; '0i' = 9; '0j' = 10; '0k' = 11; '0l' = 12; '0m' = 13
    'G'  = 99
}

$enriched = $allCheckpoints | ForEach-Object {
    $phaseName = $_.BaseName -replace '^PHASE_STATE_', ''
    [pscustomobject]@{
        File          = $_.FullName
        Phase         = $phaseName
        Rank          = if ($phaseOrder.ContainsKey($phaseName)) { $phaseOrder[$phaseName] } else { 0 }
        LastWriteTime = $_.LastWriteTime
    }
}

# Specific-phase filter
if ($Phase) {
    $hit = $enriched | Where-Object { $_.Phase -eq $Phase } |
                       Sort-Object LastWriteTime -Descending |
                       Select-Object -First 1
    if (-not $hit) { return $null }
    return (Get-Content -Raw $hit.File | ConvertFrom-Json)
}

# All phases (latest per phase)
if ($AllPhases) {
    return $enriched | Group-Object Phase | ForEach-Object {
        $latest = $_.Group | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        Get-Content -Raw $latest.File | ConvertFrom-Json
    }
}

# Highest-rank phase, most-recent file within that phase
$latest = $enriched | Sort-Object Rank, LastWriteTime -Descending | Select-Object -First 1
if (-not $latest) {
    return $null
}

return (Get-Content -Raw $latest.File | ConvertFrom-Json)
