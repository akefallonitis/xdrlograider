#Requires -Version 7.4
<#
.SYNOPSIS
    13 canonical Sentinel entity-column coverage validator (Plan §3.7 + §10.3).

.DESCRIPTION
    For every manifest entry · counts which of the 13 canonical entity columns
    (DeviceId · UserPrincipalName · IpAddress · Url · FileHash · ProcessName ·
    AlertId · MessageId · Mailbox · AppName · ResourceId · RegistryKey · ThreatName)
    are present in the ProjectionMap. Emits:
      - Per-canonical-column count + %
      - Per-SubArea entity richness
      - Entries flagged as "should have entity column but doesn't" (heuristic)
      - JSON report at manifests/_gate-entity-coverage.json

    NOT a hard gate (entity coverage depends on which endpoints return entity
    data). Quantifies §3.7 compliance · operator reads & decides.

.PARAMETER Portal
    Default 'Defender'.

.PARAMETER MinEntriesWithEntityColumn
    Soft threshold · WARN below (default 40 · current ceiling ~45).

.EXAMPLE
    pwsh ./tools/Validate-EntityCoverage.ps1
    pwsh ./tools/Validate-EntityCoverage.ps1 -Portal Defender
#>
[CmdletBinding()]
param(
    [string]$Portal = 'Defender',
    [int]$MinEntriesWithEntityColumn = 40
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$manifestPath = Join-Path $repoRoot ("manifests/{0}.psd1" -f $Portal.ToLowerInvariant())
if (-not (Test-Path $manifestPath)) {
    throw "Validate-EntityCoverage: manifest not found for portal '$Portal' at '$manifestPath'"
}

# 13 canonical entity columns (Plan §3.7 + §10.3 + Apply-ProjectionMaps mapping)
$canonical = @(
    'DeviceId', 'UserPrincipalName', 'IpAddress', 'Url', 'FileHash',
    'ProcessName', 'AlertId', 'MessageId', 'Mailbox', 'AppName',
    'ResourceId', 'RegistryKey', 'ThreatName'
)

# Heuristic · SubArea names that should bear specific entity columns
# (operator can extend · used for "should-have" detection)
$subAreaEntityExpectations = @{
    'EndpointDevices'       = @('DeviceId','UserPrincipalName')
    'Identity'              = @('UserPrincipalName')
    'Files'                 = @('FileHash')
    'CloudApps'             = @('AppName','UserPrincipalName')
    'VulnerabilityManagement' = @('DeviceId')
    'ExposureManagement'    = @('DeviceId','ResourceId')
    'ThreatAnalytics'       = @('ThreatName','AlertId')
    'AttackSimulator'       = @('UserPrincipalName')
    'EntityPivots'          = @('DeviceId','UserPrincipalName','IpAddress','Url','FileHash')
}

Write-Host "`nValidate-EntityCoverage · Portal=$Portal" -ForegroundColor Cyan
Write-Host ("  Manifest: {0}" -f $manifestPath) -ForegroundColor DarkGray

$manifest = & ([scriptblock]::Create((Get-Content -Raw -LiteralPath $manifestPath)))
$entries  = @($manifest.Entries)
Write-Host ("  Entries: {0}" -f $entries.Count) -ForegroundColor DarkGray

# Per-entry · which canonical columns are present in ProjectionMap?
$perEntry = @{}
$perColumn = @{}
foreach ($c in $canonical) { $perColumn[$c] = 0 }
$entriesWithEntity = 0
foreach ($e in $entries) {
    if (-not $e.ProjectionMap -or @($e.ProjectionMap.Keys).Count -eq 0) {
        $perEntry[$e.EntryKey] = @()
        continue
    }
    $hits = @($e.ProjectionMap.Keys | Where-Object { $_ -in $canonical })
    $perEntry[$e.EntryKey] = $hits
    if ($hits.Count -gt 0) {
        $entriesWithEntity++
        foreach ($h in $hits) { $perColumn[$h]++ }
    }
}

# Per-SubArea richness
$bySubArea = @{}
foreach ($e in $entries) {
    if (-not $bySubArea.ContainsKey($e.SubArea)) {
        $bySubArea[$e.SubArea] = @{ Total = 0; WithEntity = 0; Hits = @{} }
        foreach ($c in $canonical) { $bySubArea[$e.SubArea].Hits[$c] = 0 }
    }
    $bySubArea[$e.SubArea].Total++
    $hits = $perEntry[$e.EntryKey]
    if ($hits.Count -gt 0) {
        $bySubArea[$e.SubArea].WithEntity++
        foreach ($h in $hits) { $bySubArea[$e.SubArea].Hits[$h]++ }
    }
}

# "Should-have" gap detection
$shouldHaveGaps = [System.Collections.Generic.List[pscustomobject]]::new()
foreach ($e in $entries) {
    if ($subAreaEntityExpectations.ContainsKey($e.SubArea)) {
        $expected = @($subAreaEntityExpectations[$e.SubArea])
        $actual = @($perEntry[$e.EntryKey])
        $missing = @($expected | Where-Object { $_ -notin $actual })
        # Only flag if entry has SOME ProjectionMap (skip pure unmapped)
        $hasPMap = $e.ProjectionMap -and @($e.ProjectionMap.Keys).Count -gt 0
        if ($hasPMap -and $missing.Count -gt 0) {
            $shouldHaveGaps.Add([pscustomobject]@{
                EntryKey = $e.EntryKey
                SubArea  = $e.SubArea
                Slug     = $e.Slug
                Missing  = $missing
                Has      = $actual
            }) | Out-Null
        }
    }
}

# ── Report ───────────────────────────────────────────────────────────────────
Write-Host ""
$pctEntities = if ($entries.Count) { [math]::Round(100.0 * $entriesWithEntity / $entries.Count, 1) } else { 0 }
Write-Host ("13 canonical entity column coverage:") -ForegroundColor Cyan
Write-Host ("  Entries with >=1 entity column: {0} / {1} ({2}%)" -f $entriesWithEntity, $entries.Count, $pctEntities)
Write-Host ""
Write-Host ("Per-canonical-column hit count:") -ForegroundColor Cyan
foreach ($c in $canonical) {
    $count = $perColumn[$c]
    $pctC = if ($entries.Count) { [math]::Round(100.0 * $count / $entries.Count, 1) } else { 0 }
    $color = if ($count -ge 5) { 'Green' } elseif ($count -ge 1) { 'Yellow' } else { 'DarkYellow' }
    Write-Host ("  {0,-20} {1,4} entries ({2}%)" -f $c, $count, $pctC) -ForegroundColor $color
}

Write-Host ""
Write-Host ("Per-SubArea entity-richness top 10:") -ForegroundColor Cyan
$bySubArea.GetEnumerator() | Sort-Object { $_.Value.WithEntity } -Descending | Select-Object -First 10 | ForEach-Object {
    $sub = $_.Key
    $info = $_.Value
    $pctSub = if ($info.Total) { [math]::Round(100.0 * $info.WithEntity / $info.Total, 1) } else { 0 }
    Write-Host ("  {0,-25} {1,3}/{2,-3} entries ({3}%) with entity column" -f $sub, $info.WithEntity, $info.Total, $pctSub)
}

if ($shouldHaveGaps.Count -gt 0) {
    Write-Host ""
    Write-Host ("Should-have gaps (heuristic · SubArea expects entity but entry missing it):") -ForegroundColor Yellow
    Write-Host ("  $($shouldHaveGaps.Count) entries flagged · top 10 below:") -ForegroundColor Yellow
    $shouldHaveGaps | Select-Object -First 10 | ForEach-Object {
        Write-Host ("    {0,-50} missing: {1}" -f $_.EntryKey, ($_.Missing -join ', ')) -ForegroundColor DarkYellow
    }
}

# Write JSON report
$report = [pscustomobject]@{
    TimestampUtc            = (Get-Date).ToUniversalTime().ToString('o')
    Portal                  = $Portal
    TotalEntries            = $entries.Count
    EntriesWithEntities     = $entriesWithEntity
    EntityCoveragePct       = $pctEntities
    PerColumn               = $perColumn
    PerSubArea              = ($bySubArea.GetEnumerator() | ForEach-Object {
                                @{
                                    SubArea         = $_.Key
                                    Total           = $_.Value.Total
                                    WithEntity      = $_.Value.WithEntity
                                    EntityCoveragePct = if ($_.Value.Total) { [math]::Round(100.0 * $_.Value.WithEntity / $_.Value.Total, 1) } else { 0 }
                                    Hits            = $_.Value.Hits
                                }
                              })
    ShouldHaveGaps          = @($shouldHaveGaps)
    SoftThreshold           = $MinEntriesWithEntityColumn
    PassesThreshold         = ($entriesWithEntity -ge $MinEntriesWithEntityColumn)
}
$reportPath = Join-Path $repoRoot 'manifests/_gate-entity-coverage.json'
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reportPath -Encoding UTF8

Write-Host ""
$gateColor = if ($entriesWithEntity -ge $MinEntriesWithEntityColumn) { 'Green' } else { 'Yellow' }
$gateMarker = if ($entriesWithEntity -ge $MinEntriesWithEntityColumn) { 'PASS' } else { 'WARN' }
Write-Host ("Entity13 gate: $gateMarker · $entriesWithEntity entries with entity column (threshold: $MinEntriesWithEntityColumn)") -ForegroundColor $gateColor
Write-Host ("Report: $reportPath") -ForegroundColor DarkGray

# Exit 0 even on WARN (entity coverage is soft · driven by live-capture richness)
exit 0
