#requires -Version 7.0
<#
.SYNOPSIS
  Inject BodyTemplate field into ReadOnlyPost manifest entries from Postman-derived bodies.

.DESCRIPTION
  Phase 2a of Π11 · operator-explicit ask: "86 ReadOnlyPost endpoints with BodyTemplate
  population why not live probe catalogue and add them now".

  Reads Postman bodies from C:\Users\alkef\AppData\Local\Temp\xdrlr-postman-bodies.json
  (extracted via Derive-NodocFallback walker · keyed by EntryKey · 80/86 matched).

  Mutates manifests/defender.psd1 line-by-line · adds BodyTemplate = '<json>' just
  before each entry's closing '},' for the 80 EntryKeys with bodies.

  Idempotent · skips entries that already contain BodyTemplate.

.NOTES
  Author: Alex Kefallonitis <al.kefallonitis@gmail.com>
  Per D-2026-05-18c (NO new modules · in-place tool).
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ManifestPath = 'C:\Users\alkef\Desktop\Repos\xdrlograider-mvp\manifests\defender.psd1',
    [string]$BodiesJsonPath = 'C:\Users\alkef\AppData\Local\Temp\xdrlr-postman-bodies.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ManifestPath))   { throw "Manifest not found: $ManifestPath" }
if (-not (Test-Path $BodiesJsonPath)) { throw "Bodies file not found: $BodiesJsonPath" }

$bodiesJson = Get-Content -Raw $BodiesJsonPath | ConvertFrom-Json -AsHashtable
Write-Host "Loaded $($bodiesJson.Keys.Count) Postman body templates" -ForegroundColor Cyan

$lines = [System.Collections.Generic.List[string]]::new()
Get-Content $ManifestPath | ForEach-Object { [void]$lines.Add($_) }
Write-Host "Read $($lines.Count) lines from manifest" -ForegroundColor Cyan

# Pass 1: locate ReadOnlyPost entry blocks. Each entry block starts with
# '        @{' (8-space) and ends with '        },' or '        }' (last entry).
# Capture per-block:  startIdx · endIdx · EntryKey · ProbeMode · alreadyHasBody
$blocks = [System.Collections.Generic.List[hashtable]]::new()
$inBlock = $false
$current = $null
for ($i = 0; $i -lt $lines.Count; $i++) {
    $ln = $lines[$i]
    if (-not $inBlock -and $ln -match '^        @\{\s*$') {
        $inBlock = $true
        $current = @{ Start = $i; EntryKey = $null; ProbeMode = $null; HasBody = $false; End = $null }
        continue
    }
    if ($inBlock) {
        if ($ln -match "^\s+EntryKey\s+=\s+'([^']+)'") {
            $current.EntryKey = $Matches[1]
        }
        elseif ($ln -match "^\s+ProbeMode\s+=\s+'([^']+)'") {
            $current.ProbeMode = $Matches[1]
        }
        elseif ($ln -match '^\s+BodyTemplate\s+=') {
            $current.HasBody = $true
        }
        elseif ($ln -match '^        \},?\s*$') {
            $current.End = $i
            [void]$blocks.Add($current)
            $inBlock = $false
            $current = $null
        }
    }
}
Write-Host "Located $($blocks.Count) entry blocks" -ForegroundColor Cyan

# Pass 2: identify ReadOnlyPost blocks needing injection
$candidates = $blocks | Where-Object {
    $_.ProbeMode -eq 'ReadOnlyPost' -and -not $_.HasBody -and $bodiesJson.ContainsKey($_.EntryKey)
}
Write-Host "Candidates for injection: $($candidates.Count)" -ForegroundColor Yellow

if ($candidates.Count -eq 0) {
    Write-Host 'Nothing to inject · exiting' -ForegroundColor Green
    return
}

# Pass 3: build new lines list with insertions. Iterate candidates in REVERSE
# order so earlier indices remain valid as we insert.
$candidatesReversed = $candidates | Sort-Object -Property { $_.End } -Descending
foreach ($block in $candidatesReversed) {
    $body = $bodiesJson[$block.EntryKey]
    # PSD1 single-quote escape: ' → ''
    $bodyEscaped = $body -replace "'", "''"
    $bodyLine = "            BodyTemplate         = '$bodyEscaped'"
    # Insert just before the closing '},' at block.End
    $lines.Insert($block.End, $bodyLine)
}

if ($PSCmdlet.ShouldProcess($ManifestPath, "Inject $($candidates.Count) BodyTemplate fields")) {
    [System.IO.File]::WriteAllLines($ManifestPath, $lines.ToArray(), [System.Text.UTF8Encoding]::new($false))
    Write-Host "Wrote $($lines.Count) lines · injected $($candidates.Count) BodyTemplate fields" -ForegroundColor Green
} else {
    Write-Host "WhatIf · would inject $($candidates.Count) fields" -ForegroundColor Yellow
}
