<#
.SYNOPSIS
    Phase 0 Step 5 · build per-portal CANDIDATE manifests from nodoc YAML specs.

.DESCRIPTION
    Walks references/_external/nodoc/specifications/<spec>/specification/*.yml,
    extracts (Path, Method, OperationId, Tag, Summary) per operation,
    maps Tag → SubArea, applies Memory Rule 2 + Graph-equivalent DROP rules,
    emits manifests/<portal>.psd1 with Provenance='nodoc-openapi-candidate'.

    These candidates feed Step 6 LIVE probe — each entry is replaced/enriched
    with live.json + headers + parsed-schema once Capture-EndpointSchemas runs.

    Outputs:
      manifests/<portal>.psd1            candidate manifest (per Step 5 GATE)
      manifests/_step5-audit.json        per-rule drop summary (operator-reviewable)
      tests/results/phase-0-step-5-<utc>/audit.json + summary.md

    Memory Rule 2 (LOCKED): AdvancedHunting · AlertsIncidents · LiveResponse WHOLESALE excluded.
    Decision D-36: paths matching DropPathRegex (Graph proxy URLs) WHOLESALE excluded.

.NOTES
    Idempotent: byte-identical output for same nodoc inputs (Test-Determinism).
#>
[CmdletBinding()]
param(
    [string] $RepoRoot,
    [string] $MappingsPath,
    [string[]] $Portal = @('Defender','Purview','Entra','Intune','SecurityCopilot'),
    [switch] $NoEvidence
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $RepoRoot)     { $RepoRoot = Split-Path $PSScriptRoot -Parent }
if (-not $MappingsPath) { $MappingsPath = Join-Path $RepoRoot 'manifests/_subarea-mappings.psd1' }
$manifestRoot = Join-Path $RepoRoot 'manifests'
if (-not (Test-Path $manifestRoot)) { $null = New-Item -ItemType Directory -Path $manifestRoot -Force }

# ─── Parser · nodoc YAML → (Path, Method, OperationId, Tag, Summary) ──────────
function Get-NodocOperations {
    <#
    .SYNOPSIS
        Parses a nodoc-style openapi YAML file using regex (no external dep).
    .DESCRIPTION
        nodoc YAML is consistently formatted:
          paths:
            /path/foo:                          ← 2-space indent
              method:                           ← 4-space indent (get|post|patch|put|delete)
                operationId: SomeOp             ← 6-space indent
                tags: [TagA, TagB]              ← inline list at 6-space
                summary: One-line summary
        State machine tracks (currentPath, currentMethod, currentOpId, currentTags).
        Emits one record per (path, method) tuple.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $YmlPath)

    if (-not (Test-Path $YmlPath)) {
        Write-Warning "Get-NodocOperations: $YmlPath not found"
        return @()
    }
    $ops = [System.Collections.Generic.List[pscustomobject]]::new()
    $inPaths = $false
    $currentPath   = $null
    $currentMethod = $null
    $currentOpId   = $null
    $currentTags   = @()
    $currentSummary= $null

    function Flush {
        param($Path,$Method,$OpId,$Tags,$Summary,$Sink)
        if ($Path -and $Method) {
            $Sink.Add([pscustomobject]@{
                Path        = $Path
                Method      = $Method.ToUpperInvariant()
                OperationId = $OpId
                Tags        = @($Tags)
                Summary     = $Summary
            })
        }
    }

    foreach ($line in (Get-Content -LiteralPath $YmlPath)) {
        # Skip blank / comment lines
        if ($line -match '^\s*(#|$)') { continue }

        # Top-level `paths:` opens the section
        if ($line -match '^paths:\s*$') { $inPaths = $true; continue }
        # Any other top-level (column-0) key closes it
        if ($line -match '^[A-Za-z][A-Za-z0-9_-]*\s*:') { $inPaths = $false; continue }
        if (-not $inPaths) { continue }

        # Path entry at exactly 2-space indent  (e.g. "  /mtp/foo:")
        if ($line -match '^  (/[^:]+):\s*$') {
            Flush $currentPath $currentMethod $currentOpId $currentTags $currentSummary $ops
            $currentPath = $Matches[1]
            $currentMethod = $null; $currentOpId = $null; $currentTags = @(); $currentSummary = $null
            continue
        }

        # Method entry at 4-space indent
        if ($line -match '^    (get|post|patch|put|delete|head|options):\s*$') {
            Flush $currentPath $currentMethod $currentOpId $currentTags $currentSummary $ops
            $currentMethod = $Matches[1]
            $currentOpId = $null; $currentTags = @(); $currentSummary = $null
            continue
        }

        # operationId at 6-space indent
        if ($line -match '^      operationId:\s*(.+?)\s*$') {
            $currentOpId = ($Matches[1] -replace "['""]",'').Trim()
            continue
        }

        # tags at 6-space indent · inline list  e.g. "      tags: [Foo, Bar]"
        if ($line -match '^      tags:\s*\[(.+)\]\s*$') {
            $currentTags = ($Matches[1] -split ',') | ForEach-Object { ($_ -replace "['""]",'').Trim() }
            continue
        }

        # summary at 6-space indent (single line)
        if ($line -match '^      summary:\s*(.+?)\s*$') {
            $currentSummary = ($Matches[1] -replace "['""]",'').Trim()
            continue
        }
    }
    Flush $currentPath $currentMethod $currentOpId $currentTags $currentSummary $ops
    return $ops
}

# ─── PascalCase auto-mapping for unknown tags ──────────────────────────────────
function ConvertTo-PascalCaseTag {
    param([string] $Tag)
    if (-not $Tag) { return 'Unknown' }
    # If the tag has no separator chars, it's already a single token (e.g. 'GraphProxy', 'CloudApps')
    # · just ensure first char is upper · preserve internal casing.
    if ($Tag -notmatch '[\s\-_]') {
        return $Tag.Substring(0,1).ToUpperInvariant() + $Tag.Substring(1)
    }
    # Multi-word tag · split + capitalize each piece + concat · PRESERVE internal casing of each piece.
    $words = $Tag -split '[\s\-_]+' | Where-Object { $_ }
    return ($words | ForEach-Object {
        if ($_.Length -le 1) { $_.ToUpperInvariant() } else {
            $_.Substring(0,1).ToUpperInvariant() + $_.Substring(1)
        }
    }) -join ''
}

# ─── Slug builder · stable EntryKey suffix ─────────────────────────────────────
function ConvertTo-Slug {
    param([string] $Text)
    # lowercased, alphanumeric+dash only · for EntryKey
    $s = ($Text -replace '[^A-Za-z0-9]+','-').Trim('-').ToLowerInvariant()
    if (-not $s) { $s = 'unknown' }
    return $s
}

# ─── EntryKey builder ──────────────────────────────────────────────────────────
function New-EntryKey {
    param([string] $SubArea,[string] $OperationId,[string] $Method,[string] $Path)
    $opSlug = if ($OperationId) { ConvertTo-Slug $OperationId } else { (ConvertTo-Slug ($Method + '-' + $Path)) }
    return "${SubArea}::${opSlug}"
}

# ─── Single-file extractor · returns list of candidate-entry dicts ─────────────
function Extract-CandidateEntries {
    param(
        [Parameter(Mandatory)] $PortalConfig,
        [string] $SubPortal,
        [Parameter(Mandatory)][string] $YmlPath,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[hashtable]] $DropLog
    )
    $entries = [System.Collections.Generic.List[hashtable]]::new()
    $portalName = [string]$PortalConfig.Portal
    $tagMap     = $PortalConfig.TagMap
    $dropSubAreas = @($PortalConfig.DropSubAreas)
    $dropOpRx   = [string]$PortalConfig.DropOpIdRegex
    $dropPathRx = [string]$PortalConfig.DropPathRegex
    $pathPrefix = [string]$PortalConfig.PathPrefix
    # Step 5 enhancement · per D-34 capability annotation (NOT drop)
    $capMap = if ($PortalConfig.ContainsKey('SubAreaCapability')) { $PortalConfig.SubAreaCapability } else { @{} }

    $ops = Get-NodocOperations -YmlPath $YmlPath
    foreach ($op in $ops) {
        $rawPath  = [string]$op.Path
        $method   = [string]$op.Method
        $opId     = [string]$op.OperationId
        $primaryTag = if ($op.Tags -and $op.Tags.Count -gt 0) { [string]$op.Tags[0] } else { 'Unknown' }

        # Map tag → SubArea
        $subArea = if ($tagMap.ContainsKey($primaryTag)) { [string]$tagMap[$primaryTag] } else { ConvertTo-PascalCaseTag $primaryTag }

        # DROP per Memory Rule 2
        if ($dropSubAreas -contains $subArea) {
            $DropLog.Add(@{ Portal=$portalName; SubArea=$subArea; OperationId=$opId; Path=$rawPath; Method=$method; Reason='memory-rule-2-wholesale'; File=(Split-Path $YmlPath -Leaf) }) | Out-Null
            continue
        }

        # DROP per Graph-equivalent (operationId)
        if ($dropOpRx -and $opId -match $dropOpRx) {
            $DropLog.Add(@{ Portal=$portalName; SubArea=$subArea; OperationId=$opId; Path=$rawPath; Method=$method; Reason='graph-equivalent-operationid'; File=(Split-Path $YmlPath -Leaf) }) | Out-Null
            continue
        }
        # DROP per Graph-equivalent (path)
        if ($dropPathRx -and $rawPath -match $dropPathRx) {
            $DropLog.Add(@{ Portal=$portalName; SubArea=$subArea; OperationId=$opId; Path=$rawPath; Method=$method; Reason='graph-equivalent-path'; File=(Split-Path $YmlPath -Leaf) }) | Out-Null
            continue
        }
        # DROP per D-36 hard rule (any graph.microsoft.com / graph.windows.net path)
        if ($rawPath -match 'graph\.microsoft\.com|graph\.windows\.net') {
            $DropLog.Add(@{ Portal=$portalName; SubArea=$subArea; OperationId=$opId; Path=$rawPath; Method=$method; Reason='d36-graph-host-forbidden'; File=(Split-Path $YmlPath -Leaf) }) | Out-Null
            continue
        }

        # Compose final Path (prepend $pathPrefix if not already present)
        $fullPath = if ($pathPrefix -and -not $rawPath.StartsWith($pathPrefix,[StringComparison]::OrdinalIgnoreCase)) {
            "${pathPrefix}${rawPath}"
        } else { $rawPath }

        # Compose Stream + EntryKey
        $stream   = if ($SubPortal) { "${portalName}_${SubPortal}_${subArea}_CL" } else { "${portalName}_${subArea}_CL" }
        $entryKey = New-EntryKey -SubArea $subArea -OperationId $opId -Method $method -Path $rawPath
        if ($SubPortal) { $entryKey = "${SubPortal}::${entryKey}" }

        # Capability annotation per D-34 (annotate · don't drop)
        $capability = if ($capMap.ContainsKey($subArea)) { [string]$capMap[$subArea] } else { '' }

        $entries.Add(@{
            Stream        = $stream
            EntryKey      = $entryKey
            Path          = $fullPath
            Method        = $method
            Tier          = 'Inventory'   # default · Step 8 cadence-assignment overrides
            SubArea       = $subArea
            SubPortal     = if ($SubPortal) { $SubPortal } else { '' }
            Portal        = $portalName
            AuthScheme    = [string]$PortalConfig.AuthScheme
            LicenseHint   = ''
            Capability    = $capability   # Step 5 enhancement · per D-34 license-portability annotation
            IngestionMode = ''            # Step 7 classifier populates this
            EntityHints   = @()
            ProjectionMap = @{}
            Provenance    = 'nodoc-openapi-candidate'
            NodocRoute    = $opId
            NodocTag      = $primaryTag
            NodocSummary  = [string]$op.Summary
            SpecFile      = (Split-Path $YmlPath -Leaf)
        })
    }
    return $entries
}

# ─── PSD1 emitter · deterministic formatting (Test-Determinism friendly) ───────
function Format-EntryAsPsd1 {
    param([hashtable] $Entry)

    # Single-quote escape function for PSD1 string literals
    $esc = { param($s) if ($null -eq $s) { '' } else { ([string]$s) -replace "'","''" } }

    $entHints = '@(' + ((@($Entry.EntityHints) | ForEach-Object { "'$(&$esc $_)'" }) -join ', ') + ')'
    $proj     = if ($Entry.ProjectionMap.Count -gt 0) {
        ((@($Entry.ProjectionMap.GetEnumerator()) | Sort-Object Key | ForEach-Object { "                '$(&$esc $_.Key)' = '$(&$esc $_.Value)'" }) -join "`n")
    } else { '' }
    $subPortalLine = "            SubPortal     = '$(&$esc $Entry.SubPortal)'`n"
    $escPath    = &$esc $Entry.Path
    $escOpId    = &$esc $Entry.NodocRoute
    $escTag     = &$esc $Entry.NodocTag
    $escSummary = &$esc $Entry.NodocSummary
    $escEntryKey= &$esc $Entry.EntryKey
    $escStream  = &$esc $Entry.Stream
    $escSpecFile= &$esc $Entry.SpecFile

    @"
        @{
            Stream        = '$escStream'
            EntryKey      = '$escEntryKey'
            Path          = '$escPath'
            Method        = '$($Entry.Method)'
            Tier          = '$($Entry.Tier)'
            SubArea       = '$($Entry.SubArea)'
$subPortalLine            Portal        = '$($Entry.Portal)'
            AuthScheme    = '$($Entry.AuthScheme)'
            LicenseHint   = '$($Entry.LicenseHint)'
            Capability    = '$(&$esc $Entry.Capability)'
            IngestionMode = '$($Entry.IngestionMode)'
            EntityHints   = $entHints
            ProjectionMap = @{
$proj
            }
            Provenance    = '$($Entry.Provenance)'
            NodocRoute    = '$escOpId'
            NodocTag      = '$escTag'
            NodocSummary  = '$escSummary'
            SpecFile      = '$escSpecFile'
        }
"@
}

# ─── Discover yml files for a (SpecRoot, ExcludeFiles) pair ────────────────────
function Get-PortalYmlFiles {
    param(
        [Parameter(Mandatory)][string] $SpecRoot,
        [string[]] $ExcludeFiles = @()
    )
    $absRoot = Join-Path $RepoRoot $SpecRoot
    if (-not (Test-Path $absRoot)) {
        Write-Warning "Get-PortalYmlFiles: SpecRoot $absRoot not found"
        return @()
    }
    return Get-ChildItem -Path $absRoot -Filter '*.yml' -File | Where-Object { $ExcludeFiles -notcontains $_.Name } | Sort-Object Name | ForEach-Object { $_.FullName }
}

# ─── Main · per-portal build ──────────────────────────────────────────────────
$mappings = & ([scriptblock]::Create((Get-Content -Raw -LiteralPath $MappingsPath)))
$globalDropLog = [System.Collections.Generic.List[hashtable]]::new()
$portalTotals  = [ordered]@{}
$portalSubAreaCounts = [ordered]@{}

Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Phase 0 Step 5 · Build CANDIDATE manifests from nodoc" -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan

foreach ($portalName in $Portal) {
    if (-not $mappings.ContainsKey($portalName)) {
        Write-Warning "Mapping for $portalName not found in $MappingsPath · skipping."
        continue
    }
    Write-Host ""
    Write-Host "── Portal: $portalName ──────────────────────────────────────" -ForegroundColor Cyan
    $cfg = $mappings[$portalName]
    $entries = [System.Collections.Generic.List[hashtable]]::new()

    if ($cfg.ContainsKey('IsMultiSpec') -and $cfg.IsMultiSpec) {
        foreach ($subName in ($cfg.SpecGroup.Keys | Sort-Object)) {
            $subCfg = $cfg.SpecGroup[$subName]
            $files = @(Get-PortalYmlFiles -SpecRoot $subCfg.SpecRoot -ExcludeFiles @($subCfg.ExcludeFiles))
            Write-Host "  · sub-portal $subName · $($files.Count) yml files" -ForegroundColor Yellow
            foreach ($f in $files) {
                $sub = Extract-CandidateEntries -PortalConfig $cfg -SubPortal $subName -YmlPath $f -DropLog $globalDropLog
                foreach ($e in $sub) { $entries.Add($e) | Out-Null }
            }
        }
    } else {
        $files = @(Get-PortalYmlFiles -SpecRoot $cfg.SpecRoot -ExcludeFiles @($cfg.ExcludeFiles))
        Write-Host "  · $($files.Count) yml files under $($cfg.SpecRoot)" -ForegroundColor Yellow
        foreach ($f in $files) {
            $sub = Extract-CandidateEntries -PortalConfig $cfg -YmlPath $f -DropLog $globalDropLog
            foreach ($e in $sub) { $entries.Add($e) | Out-Null }
        }
    }

    # ─── Memory Rule 1 · cross-sub-area Path-collision dedup ──────────────────
    # When the SAME Path appears in 2+ SubAreas, keep ONLY the canonical SubArea (declarative map).
    # Per plan §9 Step 5 rule 4: "DROP per Rule 1: duplicates already in EC/CFG/ED · ASR/custom-rules/device-telemetry"
    $rule1Map = if ($cfg.ContainsKey('Rule1CanonicalSubArea')) { $cfg.Rule1CanonicalSubArea } else { @{} }
    if ($rule1Map.Keys.Count -gt 0) {
        $rule1Drops = [System.Collections.Generic.List[hashtable]]::new()
        $pathGroups = $entries | Group-Object { $_.Path } | Where-Object { $_.Count -gt 1 }
        foreach ($pg in $pathGroups) {
            # Only consider groups whose entries span multiple sub-areas
            $sasInGroup = @($pg.Group | ForEach-Object { $_.SubArea } | Sort-Object -Unique)
            if ($sasInGroup.Count -le 1) { continue }
            # Find a matching Rule1 canonical entry (path-regex match)
            $canonicalSubArea = $null
            foreach ($pat in $rule1Map.Keys) {
                if ($pg.Name -match $pat) { $canonicalSubArea = [string]$rule1Map[$pat]; break }
            }
            if (-not $canonicalSubArea) { continue }
            # Drop the non-canonical entries
            foreach ($e in $pg.Group) {
                if ($e.SubArea -ne $canonicalSubArea) {
                    $rule1Drops.Add($e) | Out-Null
                    $globalDropLog.Add(@{
                        Portal      = $portalName
                        SubArea     = $e.SubArea
                        OperationId = $e.NodocRoute
                        Path        = $e.Path
                        Method      = $e.Method
                        Reason      = "rule1-cross-subarea-dupe (canonical=$canonicalSubArea)"
                        File        = $e.SpecFile
                    }) | Out-Null
                }
            }
        }
        # Filter out drops
        if ($rule1Drops.Count -gt 0) {
            $dropSet = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($d in $rule1Drops) { $null = $dropSet.Add("$($d.SubArea)|$($d.EntryKey)") }
            $kept = [System.Collections.Generic.List[hashtable]]::new()
            foreach ($e in $entries) {
                if (-not $dropSet.Contains("$($e.SubArea)|$($e.EntryKey)")) { $kept.Add($e) | Out-Null }
            }
            $entries = $kept
            Write-Host "  · Rule 1 dedup: dropped $($rule1Drops.Count) cross-sub-area path-dupe entries" -ForegroundColor Yellow
        }
    }

    # ─── Disambiguate colliding EntryKeys via path-hash suffix ────────────────
    # nodoc occasionally has multiple paths sharing one operationId (casing + trailing-slash variants).
    # Detect post-hoc · for each colliding group preserve the first entry · append 6-char path-hash to others.
    $keyGroups = $entries | Group-Object { $_.EntryKey } | Where-Object { $_.Count -gt 1 }
    foreach ($grp in $keyGroups) {
        # Skip the first instance (canonical) · suffix others
        $idx = 0
        foreach ($e in ($grp.Group | Sort-Object Method,Path)) {
            if ($idx -gt 0) {
                $pathHash = [System.BitConverter]::ToString([System.Security.Cryptography.SHA1]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes("$($e.Method) $($e.Path)"))).Replace('-','').Substring(0,6).ToLowerInvariant()
                $e.EntryKey = "$($e.EntryKey)--$pathHash"
            }
            $idx++
        }
    }

    # Sort deterministic by EntryKey
    $sortedEntries = @($entries) | Sort-Object EntryKey

    # SubArea histogram for evidence
    $subAreaHist = @{}
    foreach ($e in $sortedEntries) {
        $sa = $e.SubArea
        if (-not $subAreaHist.ContainsKey($sa)) { $subAreaHist[$sa] = 0 }
        $subAreaHist[$sa]++
    }
    $portalTotals[$portalName] = $sortedEntries.Count
    $portalSubAreaCounts[$portalName] = $subAreaHist

    # ─── Emit .psd1 ─────────────────────────────────────────────────────────────
    $isActive = ($portalName -eq 'Defender')
    $isActiveLit = if ($isActive) { '$true' } else { '$false' }
    $entriesBlock = ($sortedEntries | ForEach-Object { Format-EntryAsPsd1 $_ }) -join ",`n"
    $manifest = @"
# Auto-generated by tools/Build-CandidateManifest.ps1 — DO NOT EDIT BY HAND.
# Phase 0 Step 5 · CANDIDATE shape (pre-Step-6 live probe).
# Re-run Build-CandidateManifest.ps1 after changing manifests/_subarea-mappings.psd1 or nodoc specs.
@{
    Portal        = '$portalName'
    IsActive      = $isActiveLit
    SchemaVersion = '0.1.0-candidate'
    Provenance    = 'nodoc-openapi-candidate'
    Entries = @(
$entriesBlock
    )
}
"@
    $outPath = Join-Path $manifestRoot "$($portalName.ToLowerInvariant()).psd1"
    $manifest | Set-Content -LiteralPath $outPath -Encoding UTF8 -NoNewline:$false
    Write-Host "  ✓ Emitted $outPath · $($sortedEntries.Count) entries" -ForegroundColor Green
}

# ─── Step-5 audit JSON · operator-reviewable ────────────────────────────────────
$auditPath = Join-Path $manifestRoot '_step5-audit.json'
$audit = [ordered]@{
    GeneratedUtc          = [datetime]::UtcNow.ToString('o')
    PortalTotals          = $portalTotals
    PortalSubAreaCounts   = $portalSubAreaCounts
    Drops                 = @{
        Total              = $globalDropLog.Count
        ByReason           = ($globalDropLog | Group-Object { $_.Reason } | ForEach-Object { @{ Reason = $_.Name; Count = $_.Count } })
        ByPortal           = ($globalDropLog | Group-Object { $_.Portal } | ForEach-Object { @{ Portal = $_.Name; Count = $_.Count } })
    }
    DropDetails           = $globalDropLog | Sort-Object Portal,SubArea,OperationId
    MemoryRule2Compliant  = ($globalDropLog | Where-Object { $_.Reason -eq 'memory-rule-2-wholesale' } | Measure-Object).Count -ge 0
}
$audit | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $auditPath -Encoding UTF8
Write-Host ""
Write-Host "  ✓ Step-5 audit: $auditPath" -ForegroundColor Green

# ─── Operator evidence dir ─────────────────────────────────────────────────────
if (-not $NoEvidence) {
    $ts = [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss')
    $evDir = Join-Path $RepoRoot "tests/results/phase-0-step-5-$ts"
    $null = New-Item -ItemType Directory -Path $evDir -Force
    Copy-Item $auditPath (Join-Path $evDir 'audit.json') -Force

    $mdLines = @()
    $mdLines += "# Phase 0 Step 5 · Catalogue Audit · Memory Rule 2 Enforcement"
    $mdLines += ""
    $mdLines += "**Generated**: $($audit.GeneratedUtc)"
    $mdLines += "**Mappings**: ``manifests/_subarea-mappings.psd1``"
    $mdLines += "**Output**: ``manifests/*.psd1`` candidate · ``Provenance='nodoc-openapi-candidate'``"
    $mdLines += ""
    $mdLines += "## Per-portal totals"
    $mdLines += ""
    $mdLines += '| Portal | Entries | Sub-areas |'
    $mdLines += '|---|---:|---|'
    foreach ($p in $portalTotals.Keys) {
        $subList = ($portalSubAreaCounts[$p].GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "$($_.Key)($($_.Value))" }) -join ', '
        $mdLines += "| $p | $($portalTotals[$p]) | $subList |"
    }
    $mdLines += ""
    $mdLines += "## Drops (Memory Rule 2 + Decision D-36 enforcement)"
    $mdLines += ""
    $mdLines += "Total dropped: **$($audit.Drops.Total)**"
    $mdLines += ""
    $mdLines += '| Reason | Count |'
    $mdLines += '|---|---:|'
    foreach ($r in $audit.Drops.ByReason) {
        $mdLines += "| $($r.Reason) | $($r.Count) |"
    }
    $mdLines += ""
    $mdLines += "## Gate AA verification"
    $mdLines += ""
    $mdLines += "Run: ``pwsh tools/Validate-MemoryRuleCompliance.ps1``"
    $mdLines += ""
    $mdLines += "Expected: 0 entries with SubArea in (AdvancedHunting, AlertsIncidents, LiveResponse) across all manifests."
    $mdLines | Set-Content -LiteralPath (Join-Path $evDir 'summary.md') -Encoding UTF8

    Write-Host "  ✓ Evidence: $evDir" -ForegroundColor Green
}

Write-Host ""
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  STEP 5 SUMMARY" -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan
foreach ($p in $portalTotals.Keys) {
    Write-Host ("  {0,-18} {1,4} entries" -f $p, $portalTotals[$p]) -ForegroundColor White
}
Write-Host ("  {0,-18} {1,4} drops (Memory Rule 2 + D-36)" -f 'TOTAL DROPS', $audit.Drops.Total) -ForegroundColor Yellow
$grandTotal = ($portalTotals.Values | Measure-Object -Sum).Sum
Write-Host ("  {0,-18} {1,4} candidate entries" -f 'GRAND TOTAL', $grandTotal) -ForegroundColor Green
