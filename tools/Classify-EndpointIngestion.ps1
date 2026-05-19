<#
.SYNOPSIS
    Phase 0 Step 7 · classify every manifest entry's IngestionMode (LIVESTREAM | SNAPSHOT | EXCLUDED).

.DESCRIPTION
    Iterates manifests/<portal>.psd1 candidates · applies the Resolve-IngestionMode classifier
    (declarative rules · see tools/lib/Classify-IngestionMode.lib.ps1) · writes IngestionMode
    back into the manifest entry · also updates references/<portal>/<sub_area>/<slug>/metadata.json
    where the dir already exists from Step 6.

    Inputs (per entry):
      - SubArea (Memory Rule 2 defensive)
      - Path (query string time-filter detection)
      - NodocRoute / OperationId (List/Query/History pattern)
      - NodocSummary (event/log/activity keyword)
      - references/.../live.json TimeFilterHints (observed evidence · highest priority)

    Output:
      - manifests/<portal>.psd1 entries updated with IngestionMode field
      - manifests/_step7-classification.json · per-portal distribution + rule traceability
      - references/<portal>/<sub_area>/<slug>/metadata.json gets IngestionMode (when dir exists)
      - tests/results/phase-0-step-7-<utc>/ · operator-reviewable audit

    Idempotent · re-runnable · same input → byte-identical output.

.PARAMETER Portal
    Default 'All' · or restrict to one portal.

.PARAMETER DryRun
    Compute classification + report distribution · do NOT write back to manifests.
#>
[CmdletBinding()]
param(
    [ValidateSet('All','Defender','Purview','Entra','Intune','SecurityCopilot')]
    [string] $Portal = 'All',
    [string] $RepoRoot,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $RepoRoot) { $RepoRoot = Split-Path $PSScriptRoot -Parent }
. (Join-Path $PSScriptRoot 'lib/Classify-IngestionMode.lib.ps1')

$manifestRoot   = Join-Path $RepoRoot 'manifests'
$referencesRoot = Join-Path $RepoRoot 'references'

$portalsToRun = if ($Portal -eq 'All') { @('defender','purview','entra','intune','securitycopilot') } else { @($Portal.ToLowerInvariant()) }

$globalDistribution = [ordered]@{}
$globalTraceability = [System.Collections.Generic.List[hashtable]]::new()

Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Phase 0 Step 7 · classify IngestionMode per endpoint" -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan

foreach ($pName in $portalsToRun) {
    $manifestPath = Join-Path $manifestRoot "$pName.psd1"
    if (-not (Test-Path $manifestPath)) { Write-Warning "Manifest not found: $manifestPath · skipping"; continue }

    Write-Host ""
    Write-Host "── Portal: $pName ──────────────────────────────────────" -ForegroundColor Cyan
    $manifest = & ([scriptblock]::Create((Get-Content -Raw -LiteralPath $manifestPath)))
    $entries = @($manifest.Entries)

    $dist = [ordered]@{ LIVESTREAM=0; SNAPSHOT=0; EXCLUDED=0 }
    foreach ($e in $entries) {
        # If Step 6 wrote a live.json with TimeFilterHints, surface them
        $liveHints = @()
        $subArea = [string]$e.SubArea
        $sub     = if ($e.ContainsKey('SubPortal') -and $e.SubPortal) { [string]$e.SubPortal } else { '' }
        $entryKey= [string]$e.EntryKey
        $slug = ($entryKey -replace '[^A-Za-z0-9]+','-').Trim('-').ToLowerInvariant()
        $portalCap = (Get-Culture).TextInfo.ToTitleCase($pName.ToLowerInvariant()) -replace 'Securitycopilot','SecurityCopilot'
        $relPath = if ($sub) { "$portalCap/$sub/$subArea/$slug" } else { "$portalCap/$subArea/$slug" }
        $epDir = Join-Path $referencesRoot $relPath
        $liveFile = Join-Path $epDir 'live.json'
        if (Test-Path $liveFile) {
            try {
                $live = Get-Content -Raw -LiteralPath $liveFile | ConvertFrom-Json
                if ($live.PSObject.Properties['TimeFilterHints']) {
                    $liveHints = @($live.TimeFilterHints)
                }
            } catch {}
        }

        $result = Resolve-IngestionMode -Entry $e -LiveTimeFilterHints $liveHints
        $e.IngestionMode = $result.Mode
        $dist[$result.Mode]++

        $globalTraceability.Add(@{
            Portal      = $pName
            SubArea     = $subArea
            EntryKey    = $entryKey
            Path        = [string]$e.Path
            Method      = [string]$e.Method
            OperationId = [string]$e.NodocRoute
            Mode        = $result.Mode
            Reason      = $result.Reason
            Signals     = $result.Signals
            LiveHints   = $liveHints
        }) | Out-Null

        # Update metadata.json IngestionMode when dir exists
        $mdFile = Join-Path $epDir 'metadata.json'
        if (-not $DryRun -and (Test-Path $mdFile)) {
            try {
                $md = Get-Content -Raw -LiteralPath $mdFile | ConvertFrom-Json -AsHashtable
                $md['IngestionMode'] = $result.Mode
                $md | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $mdFile -Encoding UTF8
            } catch {}
        }
    }
    $globalDistribution[$pName] = $dist
    Write-Host ("  · {0,-12} {1,5}" -f 'LIVESTREAM', $dist.LIVESTREAM) -ForegroundColor Green
    Write-Host ("  · {0,-12} {1,5}" -f 'SNAPSHOT',   $dist.SNAPSHOT)   -ForegroundColor Yellow
    Write-Host ("  · {0,-12} {1,5}" -f 'EXCLUDED',   $dist.EXCLUDED)   -ForegroundColor DarkRed

    # Rewrite manifest if not dry-run
    if (-not $DryRun) {
        # Use string-replace approach to preserve formatting · only flip the IngestionMode='' field
        $content = Get-Content -Raw -LiteralPath $manifestPath
        foreach ($e in $entries) {
            $entryKey = [string]$e.EntryKey
            $mode = [string]$e.IngestionMode
            # Pattern: capture EntryKey='<key>' ... IngestionMode='<value>' within one entry block.
            # (?s) lets . span newlines · non-greedy .*? stops at the first IngestionMode line.
            # Use [^']* (no apostrophes inside value) so the close-quote is unambiguous.
            $escKey = [regex]::Escape($entryKey)
            $pattern = "(?s)(EntryKey\s+=\s+'$escKey'.*?IngestionMode\s+=\s+')[^']*(')"
            $content = [regex]::Replace($content, $pattern, "`${1}$mode`${2}")
        }
        # Bump SchemaVersion if currently 'candidate' shape
        $content = $content -replace "SchemaVersion = '0\.1\.0-candidate'", "SchemaVersion = '0.1.0-step7-classified'"
        # -NoNewline · preserve original trailing-newline · Test-Determinism contract
        [System.IO.File]::WriteAllText($manifestPath, $content, [System.Text.UTF8Encoding]::new($false))
    }
}

# ─── Step-7 audit JSON ────────────────────────────────────────────────────────
$auditPath = Join-Path $manifestRoot '_step7-classification.json'
$audit = [ordered]@{
    GeneratedUtc  = [datetime]::UtcNow.ToString('o')
    DryRun        = [bool]$DryRun
    Distribution  = $globalDistribution
    GlobalSummary = @{
        LIVESTREAM = @($globalTraceability | Where-Object Mode -eq 'LIVESTREAM').Count
        SNAPSHOT   = @($globalTraceability | Where-Object Mode -eq 'SNAPSHOT').Count
        EXCLUDED   = @($globalTraceability | Where-Object Mode -eq 'EXCLUDED').Count
    }
    Traceability  = $globalTraceability
}
$audit | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $auditPath -Encoding UTF8
Write-Host ""
Write-Host "  Audit: $auditPath" -ForegroundColor Green

# ─── Operator evidence dir ─────────────────────────────────────────────────────
$ts = [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss')
$evDir = Join-Path $RepoRoot "tests/results/phase-0-step-7-$ts"
$null = New-Item -ItemType Directory -Path $evDir -Force
Copy-Item $auditPath (Join-Path $evDir 'audit.json') -Force

$md = @(
    '# Phase 0 Step 7 · IngestionMode classification'
    ''
    "Generated: $($audit.GeneratedUtc)  ·  DryRun: $($audit.DryRun)"
    ''
    '## Global distribution'
    ''
    '| Mode | Count | % |'
    '|---|---:|---:|'
)
$total = 0
foreach ($k in 'LIVESTREAM','SNAPSHOT','EXCLUDED') { $total += [int]$audit.GlobalSummary[$k] }
foreach ($k in 'LIVESTREAM','SNAPSHOT','EXCLUDED') {
    $v = [int]$audit.GlobalSummary[$k]
    $pct = if ($total -gt 0) { [math]::Round(100 * $v / $total, 1) } else { 0 }
    $md += "| $k | $v | $pct% |"
}
$md += ''
$md += '## Per-portal distribution'
$md += ''
$md += '| Portal | LIVESTREAM | SNAPSHOT | EXCLUDED |'
$md += '|---|---:|---:|---:|'
foreach ($p in $globalDistribution.Keys) {
    $d = $globalDistribution[$p]
    $md += "| $p | $($d.LIVESTREAM) | $($d.SNAPSHOT) | $($d.EXCLUDED) |"
}
$md | Set-Content -LiteralPath (Join-Path $evDir 'summary.md') -Encoding UTF8

Write-Host "  Evidence: $evDir" -ForegroundColor Green

Write-Host ""
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  STEP 7 SUMMARY" -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ("  LIVESTREAM    {0,5}  ({1}%)" -f $audit.GlobalSummary.LIVESTREAM, $(if($total){[math]::Round(100*$audit.GlobalSummary.LIVESTREAM/$total,1)}else{0}))
Write-Host ("  SNAPSHOT      {0,5}  ({1}%)" -f $audit.GlobalSummary.SNAPSHOT,   $(if($total){[math]::Round(100*$audit.GlobalSummary.SNAPSHOT/$total,1)}else{0}))
Write-Host ("  EXCLUDED      {0,5}  ({1}%)" -f $audit.GlobalSummary.EXCLUDED,   $(if($total){[math]::Round(100*$audit.GlobalSummary.EXCLUDED/$total,1)}else{0}))
Write-Host ("  TOTAL         {0,5}" -f $total)
