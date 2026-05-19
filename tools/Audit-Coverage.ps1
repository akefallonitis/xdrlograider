# Phase 0 coverage audit · breaks down what's populated vs not across all 519 entries.
# Cross-references: classification per metadata.json, ProjectionMap presence per entry,
# and projection-candidates.json availability.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Get-Location).Path
$manifest = & ([scriptblock]::Create((Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'manifests/defender.psd1'))))
$entries = @($manifest.Entries)

# Per-entry classification + projection status
$stats = @{}
$total = @($entries).Count
$haveProj = 0
$haveCandidates = 0
$haveLive = 0
foreach ($e in $entries) {
    $slug = if ($e.ContainsKey('Slug') -and $e.Slug) { $e.Slug } else { ($e.NodocRoute -split '\.')[-1] }
    $refDir = Join-Path $repoRoot ("references/Defender/{0}/{1}" -f $e.SubArea, $slug)
    $metaPath = Join-Path $refDir 'metadata.json'
    $projPath = Join-Path $refDir 'projection-candidates.json'
    $livePath = Join-Path $refDir 'live.json'

    $classification = 'no-metadata'
    if (Test-Path $metaPath) {
        try {
            $meta = Get-Content -Raw $metaPath | ConvertFrom-Json
            if ($meta.PSObject.Properties['Classification']) { $classification = $meta.Classification }
            elseif ($meta.PSObject.Properties['classification']) { $classification = $meta.classification }
        } catch { $classification = 'unparseable-metadata' }
    }

    if (-not $stats.ContainsKey($classification)) {
        $stats[$classification] = @{ Count = 0; HasProj = 0; HasCands = 0; HasLive = 0 }
    }
    $stats[$classification].Count++

    if ($e.ProjectionMap -and $e.ProjectionMap.Count -gt 0) { $stats[$classification].HasProj++; $haveProj++ }
    if (Test-Path $projPath) { $stats[$classification].HasCands++; $haveCandidates++ }
    if (Test-Path $livePath) { $stats[$classification].HasLive++; $haveLive++ }
}

Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Phase 0 Coverage Audit · defender.psd1 ($total entries)" -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host ("  Entries with populated ProjectionMap:  {0,3} ({1:N1}%)" -f $haveProj, (100 * $haveProj / $total)) -ForegroundColor $(if ($haveProj -gt 250) { 'Green' } elseif ($haveProj -gt 100) { 'Yellow' } else { 'Red' })
Write-Host ("  Entries with projection-candidates.json: {0,3} ({1:N1}%)" -f $haveCandidates, (100 * $haveCandidates / $total))
Write-Host ("  Entries with live.json (Phase 0i input): {0,3} ({1:N1}%)" -f $haveLive, (100 * $haveLive / $total))
Write-Host ""
Write-Host "  Breakdown by capture classification:" -ForegroundColor Cyan
$stats.GetEnumerator() | Sort-Object { $_.Value.Count } -Descending | ForEach-Object {
    $c = $_.Value
    $line = ("    {0,-22} count={1,4} live={2,3} proj-cands={3,3} populated={4,3}" -f $_.Key, $c.Count, $c.HasLive, $c.HasCands, $c.HasProj)
    $color = if ($_.Key -in 'live') { 'Green' } elseif ($_.Key -in 'skipped-pathparams','skipped-mutation','skipped-write-post') { 'DarkYellow' } elseif ($_.Key -in 'error-400','html-terminal','exception','no-metadata') { 'Red' } else { 'Yellow' }
    Write-Host $line -ForegroundColor $color
}
Write-Host ""

# IngestionMode breakdown
$im = @{}
foreach ($e in $entries) {
    $mode = if ($e.ContainsKey('IngestionMode') -and $e.IngestionMode) { $e.IngestionMode } else { '<empty>' }
    if (-not $im.ContainsKey($mode)) { $im[$mode] = 0 }
    $im[$mode]++
}
Write-Host "  IngestionMode breakdown:" -ForegroundColor Cyan
$im.GetEnumerator() | Sort-Object { $_.Value } -Descending | ForEach-Object {
    Write-Host ("    {0,-12} count={1,4}" -f $_.Key, $_.Value)
}

# SubArea breakdown
Write-Host ""
Write-Host "  SubArea breakdown (entries with ProjectionMap):" -ForegroundColor Cyan
$bySubArea = $entries | Group-Object SubArea | ForEach-Object {
    $sub = $_.Name
    $cnt = @($_.Group).Count
    $proj = @($_.Group | Where-Object { $_.ProjectionMap -and $_.ProjectionMap.Count -gt 0 }).Count
    [pscustomobject]@{ SubArea = $sub; Total = $cnt; WithProj = $proj; Pct = if ($cnt) { [math]::Round(100 * $proj / $cnt, 0) } else { 0 } }
} | Sort-Object SubArea
$bySubArea | Format-Table -AutoSize
