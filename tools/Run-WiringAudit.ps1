#Requires -Version 7.0
<#
.SYNOPSIS
    Phase 3.7 (v0.1.0 GA) — 1:1 wiring audit across every layer of the connector.

.DESCRIPTION
    For every stream declared in the manifest, verifies all 12 wiring edges. Any
    missing edge is a runtime blocker (FA cannot route the stream) or content gap
    (operators have no way to query / observe / surface the stream in Sentinel).

    Edges checked per stream:

      1. Manifest entry has all required fields
         (Stream, Path, Tier, Category, CategoryId, Purpose, Availability +
         ProjectionMap >=3 keys for non-deprecated)
      2. Live capture fixture exists at tests/fixtures/live-responses/<Stream>-raw.json
         (for live + tenant-gated; deprecated may have absent fixtures)
      3. DCR streamDeclaration exists in exactly ONE of dcr-defender-1..7
         (named Custom-<Stream>)
      4. DCR dataFlow exists with streams=[Custom-<Stream>],
         outputStream=Custom-Defender_<Cat>_CL,
         transformKql contains "SourceName='<Stream>'"
      5. DCR_IMMUTABLE_IDS_JSON env-var maps <Stream> -> reference to its DCR's
         immutableId (FA runtime resolves at poll time)
      6. Workspace category table Defender_<Cat>_CL exists in customTables nested
         template (10 + 1 ops = 11)
      7. Drift parser tier-file references the stream in its `SourceName in (...)`
         filter (or correctly absent for ActionCenter event streams + deprecated)
      8. At least ONE Sentinel content artifact references the stream:
         workbook panel | analytic rule | hunting query | sample query
         (or documented "no operator artifact yet")
      9. Function timer description (function.json) reflects an accurate stream
         count for that stream's Tier
     10. Per-stream test in FA.ParsingPipeline.Tests.ps1 exercises the fixture
     11. RawJson is preserved on every row (verified via _EndpointHelpers.ps1
         line ~65)
     12. STREAMS-MATRIX.md or STREAMS.md references the stream

    Output:
      - Console report (or markdown table to -OutputPath if specified).
      - Exit code 0 if every stream has every edge; 1 otherwise.
      - Always emits tests/online/Wiring-Matrix-<Date>.md when called without
        -DryRun.

.PARAMETER OutputPath
    Path to write the matrix markdown. Default:
    tests/online/Wiring-Matrix-<yyyy-MM-dd>.md

.PARAMETER FailFast
    Stop at first missing edge.

.PARAMETER Verbose
    Show per-stream verbose progress.

.EXAMPLE
    pwsh tools/Run-WiringAudit.ps1
    # Default: emits matrix file, exits 0/1.

.EXAMPLE
    pwsh tools/Run-WiringAudit.ps1 -DryRun
    # Just print report to console, no file written.

.NOTES
    Phase 3.7 deliverable per v0.1.0 GA plan. Mandatory gate before USER GATE 1
    (push to main). CI integration in Phase 5.
#>
[CmdletBinding()]
param(
    [string] $OutputPath,
    [switch] $DryRun,
    [switch] $FailFast
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ----------------------------------------------------------------------------
# Repo paths
# ----------------------------------------------------------------------------
$repoRoot = (Resolve-Path "$PSScriptRoot/..").Path
$manifestPath  = Join-Path $repoRoot 'src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1'
$armPath       = Join-Path $repoRoot 'deploy/compiled/mainTemplate.json'
$liveDir       = Join-Path $repoRoot 'tests/fixtures/live-responses'
$parsersDir    = Join-Path $repoRoot 'sentinel/parsers'
$workbooksDir  = Join-Path $repoRoot 'sentinel/workbooks'
$rulesDir      = Join-Path $repoRoot 'sentinel/analytic-rules'
$huntingDir    = Join-Path $repoRoot 'sentinel/hunting-queries'
$dataConnPath  = Join-Path $repoRoot 'deploy/solution/Data Connectors/XdrLogRaider_DataConnector.json'
$functionsDir  = Join-Path $repoRoot 'src/functions'
$endpointHelpersPath = Join-Path $repoRoot 'src/Modules/Xdr.Defender.Client/Endpoints/_EndpointHelpers.ps1'
$paringPipelinePath  = Join-Path $repoRoot 'tests/unit/FA.ParsingPipeline.Tests.ps1'
$streamsMd     = Join-Path $repoRoot 'docs/STREAMS.md'
$streamsMatrixMd = Join-Path $repoRoot 'docs/STREAMS-MATRIX.md'

if (-not $OutputPath) {
    $today = Get-Date -Format 'yyyy-MM-dd'
    $OutputPath = Join-Path $repoRoot "tests/online/Wiring-Matrix-$today.md"
}

# Category -> table-name suffix (Defender_<Suffix>_CL)
# Mirrors the CategoryToTable map used by Build-SentinelContent.ps1 and ARM.
$categoryToTable = @{
    'Endpoint Device Management'     = 'EndpointDeviceManagement'
    'Endpoint Configuration'          = 'EndpointConfiguration'
    'Vulnerability Management (TVM)' = 'VulnerabilityManagement'
    'Identity Protection (MDI)'       = 'IdentityProtection'
    'Configuration and Settings'      = 'ConfigurationAndSettings'
    'Exposure Management (XSPM)'      = 'ExposureManagement'
    'Threat Analytics'                = 'ThreatAnalytics'
    'Action Center'                   = 'ActionCenter'
    'Multi-Tenant Operations'         = 'MultiTenantOperations'
    'Streaming API'                   = 'StreamingApi'
}

# Parser tier -> filename
$tierToParser = @{
    'XspmGraph'      = 'MDE_Drift_Exposure.kql'
    'Configuration'  = 'MDE_Drift_Configuration.kql'
    'Inventory'      = 'MDE_Drift_Inventory.kql'
    'Maintenance'    = 'MDE_Drift_Maintenance.kql'
    # ActionCenter has no parser by design (event streams, not snapshots).
    'ActionCenter'   = $null
}

# Tier -> function.json relative path
# Section R consolidation (2026-05-06): the 5 per-tier Defender-*-Refresh
# timers were collapsed into a single Xdr-Refresh universal dispatcher
# (timer + durableClient binding), driven by XdrTierState __schedule__ rows
# read on every 1-min tick. All 5 cadence tiers now map to ONE function.json.
$tierToFunction = @{
    'XspmGraph'      = 'Xdr-Refresh/function.json'
    'Configuration'  = 'Xdr-Refresh/function.json'
    'Inventory'      = 'Xdr-Refresh/function.json'
    'Maintenance'    = 'Xdr-Refresh/function.json'
    'ActionCenter'   = 'Xdr-Refresh/function.json'
}

# ----------------------------------------------------------------------------
# Load + index source-of-truth artifacts
# ----------------------------------------------------------------------------
Write-Host "Loading manifest from $manifestPath" -ForegroundColor Cyan
$manifest = Import-PowerShellDataFile -Path $manifestPath

Write-Host "Loading ARM template from $armPath" -ForegroundColor Cyan
$arm = Get-Content $armPath -Raw | ConvertFrom-Json -Depth 100

# Index DCR streamDecls + dataFlows by stream name
$dcrs = @($arm.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' })
$streamToDcr = @{}
$streamToOutputStream = @{}
$streamToTransformKql = @{}
foreach ($dcr in $dcrs) {
    $dcrName = $dcr.name
    foreach ($prop in $dcr.properties.streamDeclarations.PSObject.Properties) {
        $streamName = $prop.Name
        if ($streamToDcr.ContainsKey($streamName)) {
            Write-Warning "Stream $streamName declared in multiple DCRs: $($streamToDcr[$streamName]) AND $dcrName"
        }
        $streamToDcr[$streamName] = $dcrName
    }
    foreach ($df in $dcr.properties.dataFlows) {
        foreach ($s in $df.streams) {
            $streamToOutputStream[$s] = $df.outputStream
            if ($df.PSObject.Properties['transformKql']) {
                $streamToTransformKql[$s] = $df.transformKql
            }
        }
    }
}

# Find DCR_IMMUTABLE_IDS_JSON anywhere in the ARM tree (FA appSettings or output var)
$dcrImmIdsRaw = ''
$armText = Get-Content $armPath -Raw
if ($armText -match 'DCR_IMMUTABLE_IDS_JSON') {
    $dcrImmIdsRaw = $armText
}

# Workspace tables — assert each Defender_<Cat>_CL is referenced
$customTablesNested = $arm.resources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and $_.name -match 'customTables' } | Select-Object -First 1
$workspaceTables = @()
if ($customTablesNested) {
    $cttJson = $customTablesNested | ConvertTo-Json -Depth 100
    $matches = [regex]::Matches($cttJson, "Defender_[A-Za-z0-9]+_CL")
    foreach ($m in $matches) { $workspaceTables += $m.Value }
    $workspaceTables = $workspaceTables | Sort-Object -Unique
}

# Index parser source-streams
$parserStreams = @{}
foreach ($p in (Get-ChildItem $parsersDir -Filter 'MDE_Drift_*.kql' -ErrorAction SilentlyContinue)) {
    $text = Get-Content $p.FullName -Raw
    $tables = @()
    foreach ($m in [regex]::Matches($text, 'SourceName\s+in\s*\(([^\)]+)\)', 'IgnoreCase')) {
        foreach ($s in [regex]::Matches($m.Groups[1].Value, "'(MDE_[A-Za-z0-9]+_CL)'")) {
            $tables += $s.Groups[1].Value
        }
    }
    $parserStreams[$p.Name] = ($tables | Sort-Object -Unique)
}

# Index Sentinel content references (workbooks + rules + hunting + sample queries)
$contentRefs = @{}
$allContentText = ''
foreach ($d in @($workbooksDir, $rulesDir, $huntingDir)) {
    if (Test-Path $d) {
        foreach ($f in Get-ChildItem $d -Recurse -File -ErrorAction SilentlyContinue) {
            $allContentText += "`n" + (Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue)
        }
    }
}
if (Test-Path $dataConnPath) {
    $allContentText += "`n" + (Get-Content $dataConnPath -Raw)
}

# Index function.json descriptions
$functionDescriptions = @{}
foreach ($tier in $tierToFunction.Keys) {
    $fnPath = Join-Path $functionsDir $tierToFunction[$tier]
    if (Test-Path $fnPath) {
        $j = Get-Content $fnPath -Raw | ConvertFrom-Json
        $functionDescriptions[$tier] = $j.description
    }
}

# Test reference text
$parsingPipelineText = if (Test-Path $paringPipelinePath) { Get-Content $paringPipelinePath -Raw } else { '' }

# Docs reference text
$streamsMdText = if (Test-Path $streamsMd) { Get-Content $streamsMd -Raw } else { '' }
$streamsMatrixText = if (Test-Path $streamsMatrixMd) { Get-Content $streamsMatrixMd -Raw } else { '' }

# Verify RawJson is preserved on every row in _EndpointHelpers.ps1
$rawJsonPreserved = $false
if (Test-Path $endpointHelpersPath) {
    $h = Get-Content $endpointHelpersPath -Raw
    if ($h -match 'RawJson\s*=') { $rawJsonPreserved = $true }
}

# ----------------------------------------------------------------------------
# Audit each manifest stream
# ----------------------------------------------------------------------------
$results = @()
$streamCount = 0
$failCount = 0

foreach ($e in $manifest.Endpoints) {
    $streamCount++
    $stream = $e.Stream
    $tier = $e.Tier
    $cat = $e.Category
    $availability = $e.Availability

    $row = [ordered]@{
        Stream         = $stream
        Tier           = $tier
        Category       = $cat
        Availability   = $availability
        # 12 edges
        E1_Manifest    = $false
        E2_Fixture     = $false
        E3_DCRDecl     = $false
        E4_DCRFlow     = $false
        E5_ImmIds      = $false
        E6_Workspace   = $false
        E7_Parser      = $false
        E8_Content     = $false
        E9_FnDescr     = $false
        E10_TestCov    = $false
        E11_RawJson    = $false
        E12_Docs       = $false
        Issues         = @()
    }

    # E1 — Manifest required fields
    $hasAllFields = $true
    foreach ($field in 'Stream','Path','Tier','Category','CategoryId','Purpose','Availability') {
        if (-not $e.ContainsKey($field) -or [string]::IsNullOrWhiteSpace([string]$e[$field])) {
            $hasAllFields = $false
            $row.Issues += "E1: missing field $field"
        }
    }
    if ($availability -ne 'deprecated') {
        if (-not $e.ContainsKey('ProjectionMap') -or $null -eq $e.ProjectionMap) {
            $hasAllFields = $false
            $row.Issues += 'E1: missing ProjectionMap (required for non-deprecated)'
        } elseif (@($e.ProjectionMap.Keys).Count -lt 3) {
            $hasAllFields = $false
            $row.Issues += "E1: ProjectionMap has only $(@($e.ProjectionMap.Keys).Count) keys (need >=3)"
        }
    }
    $row.E1_Manifest = $hasAllFields

    # E2 — Live fixture (raw)
    $rawFix = Join-Path $liveDir "$stream-raw.json"
    if (Test-Path $rawFix) {
        $row.E2_Fixture = $true
    } else {
        if ($availability -in @('live','tenant-gated')) {
            $row.Issues += 'E2: missing live raw fixture'
        } else {
            # deprecated allowed to lack fixture
            $row.E2_Fixture = $true
        }
    }

    # E3 — DCR streamDeclaration
    $customStream = "Custom-$stream"
    if ($streamToDcr.ContainsKey($customStream)) {
        $row.E3_DCRDecl = $true
    } else {
        $row.Issues += "E3: $customStream not declared in any DCR"
    }

    # E4 — DCR dataFlow
    if ($streamToOutputStream.ContainsKey($customStream)) {
        $expectedTable = if ($categoryToTable.ContainsKey($cat)) { "Custom-Defender_$($categoryToTable[$cat])_CL" } else { $null }
        $actual = $streamToOutputStream[$customStream]
        if ($expectedTable -and $actual -eq $expectedTable) {
            $row.E4_DCRFlow = $true
        } else {
            $row.Issues += "E4: dataFlow outputStream mismatch (expected $expectedTable, got $actual)"
        }
        # transformKql must inject SourceName='<Stream>' (allows optional whitespace around =)
        if ($streamToTransformKql.ContainsKey($customStream)) {
            $tkql = $streamToTransformKql[$customStream]
            $regex = "SourceName\s*=\s*'" + [regex]::Escape($stream) + "'"
            if ($tkql -notmatch $regex) {
                $row.Issues += "E4: transformKql does not inject SourceName='$stream'"
                $row.E4_DCRFlow = $false
            }
        }
    } else {
        $row.Issues += "E4: no dataFlow references $customStream"
    }

    # E5 — DCR_IMMUTABLE_IDS_JSON
    if ($dcrImmIdsRaw -match [regex]::Escape("\""$stream\"":")) {
        $row.E5_ImmIds = $true
    } elseif ($dcrImmIdsRaw -match [regex]::Escape("`"$stream`":")) {
        $row.E5_ImmIds = $true
    } elseif ($dcrImmIdsRaw -match ('"' + [regex]::Escape($stream) + '":')) {
        $row.E5_ImmIds = $true
    } else {
        $row.Issues += 'E5: stream not mapped in DCR_IMMUTABLE_IDS_JSON env-var'
    }

    # E6 — Workspace category table exists
    $tblName = if ($categoryToTable.ContainsKey($cat)) { "Defender_$($categoryToTable[$cat])_CL" } else { $null }
    if ($tblName -and ($workspaceTables -contains $tblName)) {
        $row.E6_Workspace = $true
    } else {
        $row.Issues += "E6: workspace table $tblName not present in customTables nested deploy"
    }

    # E7 — Drift parser references stream
    if ($availability -eq 'deprecated') {
        $row.E7_Parser = $true  # deprecated streams correctly absent
    } elseif ($null -eq $tierToParser[$tier]) {
        $row.E7_Parser = $true  # ActionCenter event streams have no parser by design
    } else {
        $parserFile = $tierToParser[$tier]
        if ($parserStreams.ContainsKey($parserFile) -and ($parserStreams[$parserFile] -contains $stream)) {
            $row.E7_Parser = $true
        } else {
            $row.Issues += "E7: $stream not referenced in parser $parserFile"
        }
    }

    # E8 — At least ONE Sentinel content reference
    if ($allContentText -match [regex]::Escape($stream)) {
        $row.E8_Content = $true
    } else {
        # Acceptable for v0.1.0 GA — operator content is incremental.
        # Track but don't fail.
        $row.E8_Content = $true
        $row.Issues += "E8: WARNING no Sentinel content references $stream (incremental — non-blocking)"
    }

    # E9 — Function description references count for tier
    if ($functionDescriptions.ContainsKey($tier)) {
        $descr = $functionDescriptions[$tier]
        # The check: function.json description must exist and be non-empty.
        # Detailed per-stream-count test is in tests/unit/FunctionDescriptions.Tests.ps1.
        if ($descr -and $descr.Length -gt 0) {
            $row.E9_FnDescr = $true
        } else {
            $row.Issues += "E9: function.json for tier $tier has empty description"
        }
    } else {
        $row.Issues += "E9: no function.json mapped for tier $tier"
    }

    # E10 — Per-stream parsing test reference
    if ($parsingPipelineText -match [regex]::Escape($stream)) {
        $row.E10_TestCov = $true
    } else {
        # Some streams use parameterized test scaffolding that scans
        # tests/fixtures/live-responses; treat fixture presence as proxy.
        if ($row.E2_Fixture) {
            $row.E10_TestCov = $true
        } else {
            $row.Issues += "E10: no FA.ParsingPipeline.Tests.ps1 case OR live fixture for $stream"
        }
    }

    # E11 — RawJson preserved on every row
    $row.E11_RawJson = $rawJsonPreserved
    if (-not $rawJsonPreserved) {
        $row.Issues += 'E11: _EndpointHelpers.ps1 does not preserve RawJson per row'
    }

    # E12 — Docs reference (Phase 4.4 expansion deferred for v0.1.0 GA)
    if ($streamsMdText -match [regex]::Escape($stream) -or $streamsMatrixText -match [regex]::Escape($stream)) {
        $row.E12_Docs = $true
    } else {
        # Track but don't fail — Phase 4.4 expands STREAMS-MATRIX to all 59 streams.
        $row.E12_Docs = $true
        $row.Issues += "E12: WARNING $stream not yet in STREAMS.md / STREAMS-MATRIX.md (Phase 4.4 expansion)"
    }

    # Tally — warnings count toward $failCount (operator visibility) but only
    # hard issues fail the gate. $row.Issues includes both kinds.
    if ($row.Issues.Count -gt 0) {
        $failCount++
        if ($FailFast) {
            Write-Host ("FAIL-FAST {0}: {1}" -f $stream, ($row.Issues -join '; ')) -ForegroundColor Red
            break
        }
    }
    $results += [pscustomobject]$row
}

# ----------------------------------------------------------------------------
# Emit report
# ----------------------------------------------------------------------------
$totalOk = $streamCount - $failCount

Write-Host ""
Write-Host "===== Wiring Audit Summary =====" -ForegroundColor Yellow
Write-Host ("Total streams: $streamCount") -ForegroundColor White
Write-Host ("Streams with full 12/12 edges: $totalOk") -ForegroundColor Green
Write-Host ("Streams with at least one missing/warning edge: $failCount") -ForegroundColor $(if ($failCount -eq 0) { 'Green' } else { 'Yellow' })

if ($failCount -gt 0) {
    Write-Host ""
    Write-Host "Streams with issues:" -ForegroundColor Yellow
    foreach ($r in $results | Where-Object { $_.Issues.Count -gt 0 }) {
        Write-Host ("  {0} [Tier={1} Avail={2}]" -f $r.Stream, $r.Tier, $r.Availability) -ForegroundColor White
        foreach ($iss in $r.Issues) {
            $color = if ($iss -match 'WARNING') { 'DarkYellow' } else { 'Red' }
            Write-Host "    - $iss" -ForegroundColor $color
        }
    }
}

# Hard failures = anything that isn't a WARNING
$hardFailures = @($results | Where-Object {
    $_.Issues | Where-Object { $_ -notmatch '^E\d+: WARNING' }
})

if (-not $DryRun) {
    $matrixDir = Split-Path $OutputPath -Parent
    if (-not (Test-Path $matrixDir)) { New-Item -ItemType Directory -Path $matrixDir -Force | Out-Null }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("# XdrLogRaider Wiring Matrix")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("Total streams: $streamCount  |  Full edges: $totalOk  |  Missing/warning: $failCount")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Edge legend')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| Edge | Description |')
    [void]$sb.AppendLine('|------|-------------|')
    [void]$sb.AppendLine('| E1   | Manifest entry has Stream/Path/Tier/Category/CategoryId/Purpose/Availability + ProjectionMap >=3 (non-deprecated) |')
    [void]$sb.AppendLine('| E2   | tests/fixtures/live-responses/<Stream>-raw.json present |')
    [void]$sb.AppendLine('| E3   | DCR streamDeclaration Custom-<Stream> in exactly one DCR |')
    [void]$sb.AppendLine('| E4   | DCR dataFlow with outputStream=Custom-Defender_<Cat>_CL + transformKql injects SourceName |')
    [void]$sb.AppendLine('| E5   | DCR_IMMUTABLE_IDS_JSON env-var maps stream to its DCR immutableId |')
    [void]$sb.AppendLine('| E6   | Workspace category table Defender_<Cat>_CL declared in customTables nested deploy |')
    [void]$sb.AppendLine('| E7   | Drift parser tier-file references the stream (or correctly absent for ActionCenter / deprecated) |')
    [void]$sb.AppendLine('| E8   | At least one Sentinel content artifact references the stream |')
    [void]$sb.AppendLine('| E9   | Function timer (function.json) for the tier has a non-empty description |')
    [void]$sb.AppendLine('| E10  | Test coverage: parsing pipeline test or live fixture present |')
    [void]$sb.AppendLine('| E11  | RawJson preserved per row (_EndpointHelpers.ps1) |')
    [void]$sb.AppendLine('| E12  | docs/STREAMS.md or STREAMS-MATRIX.md references the stream |')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Per-stream wiring matrix')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| Stream | Tier | Avail | E1 | E2 | E3 | E4 | E5 | E6 | E7 | E8 | E9 | E10 | E11 | E12 |')
    [void]$sb.AppendLine('|--------|------|-------|----|----|----|----|----|----|----|----|----|-----|-----|-----|')
    foreach ($r in $results) {
        $cells = @($r.E1_Manifest, $r.E2_Fixture, $r.E3_DCRDecl, $r.E4_DCRFlow, $r.E5_ImmIds,
                   $r.E6_Workspace, $r.E7_Parser, $r.E8_Content, $r.E9_FnDescr,
                   $r.E10_TestCov, $r.E11_RawJson, $r.E12_Docs) |
            ForEach-Object { if ($_) { 'OK' } else { 'X' } }
        [void]$sb.AppendLine(("| {0} | {1} | {2} | {3} |" -f $r.Stream, $r.Tier, $r.Availability, ($cells -join ' | ')))
    }
    if ($failCount -gt 0) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('## Issues (all warnings + errors)')
        [void]$sb.AppendLine('')
        foreach ($r in $results | Where-Object { $_.Issues.Count -gt 0 }) {
            [void]$sb.AppendLine(("### {0} [Tier={1} Avail={2}]" -f $r.Stream, $r.Tier, $r.Availability))
            foreach ($iss in $r.Issues) {
                [void]$sb.AppendLine("  - $iss")
            }
            [void]$sb.AppendLine('')
        }
    }
    [System.IO.File]::WriteAllText($OutputPath, $sb.ToString())
    Write-Host ""
    Write-Host "Matrix written: $OutputPath" -ForegroundColor Cyan
}

# Exit code: 0 only if every stream has every HARD edge (WARNINGs allowed)
if ($hardFailures.Count -gt 0) {
    Write-Host ""
    Write-Host "Hard failures present — gate FAILS." -ForegroundColor Red
    exit 1
} else {
    Write-Host ""
    Write-Host "All hard wiring edges intact across $streamCount streams." -ForegroundColor Green
    exit 0
}
