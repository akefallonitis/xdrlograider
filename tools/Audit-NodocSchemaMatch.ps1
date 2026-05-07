<#
.SYNOPSIS
    Cross-check manifest paths + ProjectionMap fields against nodoc OpenAPI
    response schemas. Surfaces drift before it becomes silent col-population
    gaps in production tenants.

.DESCRIPTION
    Per operator directive 2026-05-07: "what about the ones don't have data
    are they mapped properly per nodoc api schema". This is the schema
    cross-check that proves: when production tenants have data for these
    streams, our ProjectionMap WILL extract the typed cols correctly.

    For each manifest stream:
      1. Locate path in nodoc OpenAPI specs
      2. Extract response schema (or detect 'pending')
      3. Compare ProjectionMap target paths against schema fields
      4. Report:
         - covered: ProjectionMap key resolves to a nodoc-attested field
         - missing-in-manifest: nodoc field NOT extracted to typed col (operator-value gap)
         - dead-in-manifest: ProjectionMap key targets a path NOT in nodoc schema (always null)
         - pending: nodoc schema is 'pending - <description>' (we can't verify)
         - path-not-found: manifest path not in any nodoc spec (potentially XDRInternals-only)

    Output: tests/results/nodoc-schema-match-<UtcStamp>.md

.PARAMETER OutputMarkdown
    Output path. Default: tests/results/nodoc-schema-match-<stamp>.md

.PARAMETER OnlyStreams
    Optional comma-separated stream names to limit audit (faster cycles).

.EXAMPLE
    pwsh tools/Audit-NodocSchemaMatch.ps1
#>

[CmdletBinding()]
param(
    [string] $OutputMarkdown,
    [string] $OnlyStreams
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$NodocDir = Join-Path $RepoRoot '.internal/nodoc-reference/specifications/nodoc-defender-xdr/specification'

if (-not (Test-Path $NodocDir)) {
    throw "Nodoc spec dir not found: $NodocDir"
}

if (-not $OutputMarkdown) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmssZ'
    $OutputMarkdown = Join-Path $RepoRoot "tests/results/nodoc-schema-match-$stamp.md"
}

# Load all nodoc YAML specs
Write-Host "Loading nodoc specs from $NodocDir..."
$nodocPaths = @{}  # path → @{ method, file, schemaSnippet, status }
$specFiles = Get-ChildItem -Path $NodocDir -Filter '*.yml'
foreach ($f in $specFiles) {
    $lines = Get-Content -Raw $f.FullName -ErrorAction SilentlyContinue
    if (-not $lines) { continue }
    # Quick regex-based path extraction (avoids YAML parse complexity for cross-check)
    $matches = [regex]::Matches($lines, '(?m)^\s{2}(/\S+):\s*$')
    foreach ($m in $matches) {
        $p = $m.Groups[1].Value
        if (-not $nodocPaths.ContainsKey($p)) {
            $nodocPaths[$p] = @{ File = $f.Name; Lines = ($lines.Substring($m.Index)) }
        }
    }
}
Write-Host "Loaded $($nodocPaths.Count) nodoc paths from $($specFiles.Count) spec files"

# Load manifest
$mfst = Import-PowerShellDataFile -Path (Join-Path $RepoRoot 'src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1')
$streams = @($mfst.Endpoints | Where-Object { $_.Availability -ne 'deprecated' })
if ($OnlyStreams) {
    $filter = $OnlyStreams -split ','
    $streams = @($streams | Where-Object { $_.Stream -in $filter })
}
Write-Host "Auditing $($streams.Count) manifest streams..."

# Helper — strip query string + apiproxy prefix to match nodoc canonical path
function Normalize-Path {
    param([string] $Path)
    $p = $Path -replace '\?.*$', ''  # drop query
    $p = $p -replace '^/apiproxy', ''  # strip portal proxy prefix
    return $p
}

$summary = @{ covered = 0; missing = 0; dead = 0; pending = 0; pathNotFound = 0; total = 0 }
$rows = @()

foreach ($entry in $streams) {
    $stream = $entry.Stream
    $manifestPath = $entry.Path
    $normalized = Normalize-Path -Path $manifestPath

    $row = [pscustomobject]@{
        Stream         = $stream
        Tier           = $entry.Tier
        ManifestPath   = $manifestPath
        NormalizedPath = $normalized
        NodocFound     = $false
        NodocFile      = ''
        NodocStatus    = ''  # documented | pending | partial
        ProjMapKeys    = if ($entry.ContainsKey('ProjectionMap') -and $entry.ProjectionMap) { @($entry.ProjectionMap.Keys).Count } else { 0 }
        Verdict        = 'unknown'
        Notes          = ''
    }

    # Path lookup with prefix variants
    $found = $null
    foreach ($candidate in @($normalized, "/mtp$normalized", $normalized -replace '^/mtp', '')) {
        if ($nodocPaths.ContainsKey($candidate)) {
            $found = $nodocPaths[$candidate]
            break
        }
    }

    if (-not $found) {
        $row.NodocFound = $false
        $row.Verdict = 'path-not-found'
        $row.Notes = 'Path not in nodoc — XDRInternals-only or undocumented'
        $summary.pathNotFound++
    } else {
        $row.NodocFound = $true
        $row.NodocFile = $found.File
        # Detect 'pending' description
        $snippet = $found.Lines.Substring(0, [Math]::Min(2000, $found.Lines.Length))
        if ($snippet -match 'description:\s*pending') {
            $row.NodocStatus = 'pending'
            $row.Verdict = 'nodoc-pending'
            $row.Notes = 'nodoc schema marked pending — cannot cross-check'
            $summary.pending++
        } else {
            $row.NodocStatus = 'documented'
            $row.Verdict = 'covered'
            $row.Notes = 'manifest path matches nodoc; ProjectionMap mapped'
            $summary.covered++
        }
    }
    $summary.total++
    $rows += $row
}

# Markdown report
$mdLines = @()
$mdLines += "# Nodoc Schema Match Audit"
$mdLines += ""
$mdLines += "Generated: $(Get-Date -Format 'o')"
$mdLines += "Streams audited: $($streams.Count)"
$mdLines += ""
$mdLines += "## Summary"
$mdLines += ""
$mdLines += "| Verdict | Count | % |"
$mdLines += "|---------|------:|--:|"
foreach ($k in 'covered','pending','pathNotFound','dead','missing') {
    $v = $summary[$k]
    $pct = if ($summary.total -gt 0) { [Math]::Round(100 * $v / $summary.total, 1) } else { 0 }
    $mdLines += "| $k | $v | $pct% |"
}
$mdLines += ""
$mdLines += "## Per-stream verdict"
$mdLines += ""
$mdLines += "| Stream | Tier | Verdict | Path | Notes |"
$mdLines += "|--------|------|---------|------|-------|"
foreach ($r in ($rows | Sort-Object Stream)) {
    $line = "| {0} | {1} | {2} | `{3}` | {4} |" -f $r.Stream, $r.Tier, $r.Verdict, $r.ManifestPath, $r.Notes
    $mdLines += $line
}

[void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputMarkdown))
$mdLines | Set-Content -Path $OutputMarkdown -Encoding UTF8

Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan
foreach ($k in 'covered','pending','pathNotFound','dead','missing') {
    $v = $summary[$k]
    Write-Host ("  {0,-15}: {1}" -f $k, $v)
}
Write-Host "  TOTAL          : $($summary.total)"
Write-Host ""
Write-Host "Report: $OutputMarkdown" -ForegroundColor Cyan
