<#
.SYNOPSIS
    Phase 0' Step 0' · BASELINE AUDIT · pre-Step-1 inventory + dependency graph + revert verification.

.DESCRIPTION
    Per plan §20.A · senior-dev author · NOT cherry-pick.

    Walks the v3 repo and emits:
      - Inventory of src/Modules/* (per-module Public fn count)
      - Inventory of tools/ (per-tool · senior-dev provenance flag)
      - Inventory of tests/unit/ (per-test-file fn-base coverage)
      - Inventory of manifests/ (per-portal entry count)
      - Inventory of deploy/ (DCR count · ARM presence)
      - Inventory of references/ (per-step doc presence)
      - Revert verification (per plan §20.A `7-polish · AUDIT`)
      - Dependency graph for Step 9 module build order

    Operator-reviewable evidence at `tests/results/phase-0-step-0-baseline-<utc>/`.

.NOTES
    Author: senior-dev (plan §20.A · D-41 · NOT cherry-pick).
    Idempotent: re-run produces byte-identical inventory.json (after timestamp redaction).
#>
[CmdletBinding()]
param(
    [string] $RepoRoot,
    [switch] $NoEvidence
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $RepoRoot) { $RepoRoot = Split-Path $PSScriptRoot -Parent }

# ─── Inventory helpers ─────────────────────────────────────────────────────────
function Get-ModuleInventory {
    param([string] $ModulesRoot)
    $inv = [ordered]@{}
    if (-not (Test-Path $ModulesRoot)) { return $inv }
    foreach ($modDir in (Get-ChildItem $ModulesRoot -Directory | Sort-Object Name)) {
        $pubDir = Join-Path $modDir.FullName 'Public'
        $privDir = Join-Path $modDir.FullName 'Private'
        $psd1 = Join-Path $modDir.FullName "$($modDir.Name).psd1"
        $psm1 = Join-Path $modDir.FullName "$($modDir.Name).psm1"
        $pubFns = @()
        $privFns = @()
        if (Test-Path $pubDir)  { $pubFns  = @(Get-ChildItem $pubDir  -Filter '*.ps1' -File | ForEach-Object { $_.Name }) }
        if (Test-Path $privDir) { $privFns = @(Get-ChildItem $privDir -Filter '*.ps1' -File | ForEach-Object { $_.Name }) }
        $inv[$modDir.Name] = [ordered]@{
            HasPsd1     = (Test-Path $psd1)
            HasPsm1     = (Test-Path $psm1)
            PublicCount = $pubFns.Count
            PublicFns   = $pubFns
            PrivateCount= $privFns.Count
            PrivateFns  = $privFns
            IsEmpty     = ($pubFns.Count -eq 0 -and $privFns.Count -eq 0)
        }
    }
    return $inv
}

function Get-ToolInventory {
    param([string] $ToolsRoot)
    if (-not (Test-Path $ToolsRoot)) { return @{} }
    $inv = [ordered]@{}
    foreach ($f in (Get-ChildItem $ToolsRoot -Filter '*.ps1' -File | Sort-Object Name)) {
        $content = Get-Content -Raw -LiteralPath $f.FullName -ErrorAction SilentlyContinue
        $authoredBy = if ($content -match 'NOT cherry-pick|senior-dev rebuild|senior-dev author') { 'senior-dev' }
                      elseif ($content -match 'cherry-pick(ed)? from prod|cherry-pick(ed)? from v[12]') { 'cherry-pick' }
                      else { 'unknown' }
        $inv[$f.Name] = [ordered]@{
            Bytes = $f.Length
            Lines = @($content -split "`n").Count
            Authoring = $authoredBy
        }
    }
    return $inv
}

function Get-TestInventory {
    param([string] $TestsRoot)
    if (-not (Test-Path $TestsRoot)) { return @{} }
    $inv = [ordered]@{}
    foreach ($f in (Get-ChildItem $TestsRoot -Filter '*.Tests.ps1' -File | Sort-Object Name)) {
        $content = Get-Content -Raw -LiteralPath $f.FullName -ErrorAction SilentlyContinue
        $itCount = ([regex]::Matches($content, '\bIt\b\s+["'']')).Count
        $describeCount = ([regex]::Matches($content, '\bDescribe\b\s+["'']')).Count
        $inv[$f.Name] = [ordered]@{
            Bytes = $f.Length
            Describes = $describeCount
            Its = $itCount
        }
    }
    return $inv
}

function Get-ManifestInventory {
    param([string] $ManRoot)
    if (-not (Test-Path $ManRoot)) { return @{} }
    $inv = [ordered]@{}
    foreach ($f in (Get-ChildItem $ManRoot -Filter '*.psd1' -File | Where-Object Name -notlike '_*' | Sort-Object Name)) {
        try {
            $m = & ([scriptblock]::Create((Get-Content -Raw $f.FullName)))
            $entryCount = if ($m.ContainsKey('Entries')) { @($m.Entries).Count } else { 0 }
            $subAreas = @($m.Entries | Group-Object SubArea | ForEach-Object { @{ SubArea = $_.Name; Count = $_.Count } })
            $modes = @($m.Entries | Group-Object IngestionMode | ForEach-Object { @{ Mode = $_.Name; Count = $_.Count } })
            $inv[$f.Name] = [ordered]@{
                Portal     = if ($m.ContainsKey('Portal')) { [string]$m.Portal } else { '' }
                IsActive   = if ($m.ContainsKey('IsActive')) { [bool]$m.IsActive } else { $false }
                Provenance = if ($m.ContainsKey('Provenance')) { [string]$m.Provenance } else { '' }
                EntryCount = $entryCount
                SubAreas   = $subAreas
                IngestionModes = $modes
            }
        } catch {
            $inv[$f.Name] = [ordered]@{ ParseError = $_.Exception.Message }
        }
    }
    return $inv
}

function Get-DeployInventory {
    param([string] $DeployRoot)
    if (-not (Test-Path $DeployRoot)) { return @{} }
    $arm = @('mainTemplate.json','createUiDefinition.json','sentinelContent.json','parameters.sample.json')
    $inv = [ordered]@{}
    foreach ($f in $arm) {
        $p = Join-Path $DeployRoot $f
        $inv[$f] = [ordered]@{ Present = (Test-Path $p); Bytes = if (Test-Path $p) { (Get-Item $p).Length } else { 0 } }
    }
    $dcrDir = Join-Path $DeployRoot 'dcrs'
    $dcrCount = if (Test-Path $dcrDir) { @(Get-ChildItem $dcrDir -Filter 'dcr-*.json' -File).Count } else { 0 }
    $inv['dcrs'] = [ordered]@{ Count = $dcrCount }
    return $inv
}

function Get-ReferenceDocInventory {
    param([string] $RefRoot)
    if (-not (Test-Path $RefRoot)) { return @{} }
    $expected = @('_auth-chain.md','_capability-snapshots.md','_catalogue-audit.md','_step6-live-probe.md','_step7-ingestion-classification.md','_step8-schema-derivation.md','_step9-dcrs-functions-l4-l5.md','_cherry-pick-log.md','_step0-baseline.md')
    $inv = [ordered]@{}
    foreach ($e in $expected) {
        $p = Join-Path $RefRoot $e
        $inv[$e] = [ordered]@{ Present = (Test-Path $p); Bytes = if (Test-Path $p) { (Get-Item $p).Length } else { 0 } }
    }
    # _index/ dir
    $idxDir = Join-Path $RefRoot '_index'
    if (Test-Path $idxDir) {
        $idxFiles = @(Get-ChildItem $idxDir -Filter '*.json' -File | Sort-Object Name | ForEach-Object { $_.Name })
        $inv['_index'] = [ordered]@{ Present = $true; Files = $idxFiles; Count = $idxFiles.Count }
    } else {
        $inv['_index'] = [ordered]@{ Present = $false; Count = 0 }
    }
    return $inv
}

function Get-RevertVerification {
    param([string] $RepoRoot)
    # Per plan §20.A revert verification:
    # - 22 bulk-cherry-picked tools deleted
    # - 5 module bodies empty post-revert (skeletons restored)
    # - 4 function dirs empty
    # - DCRs cleared
    # - 3 cherry-picked test files deleted
    $expected = [ordered]@{}
    # Tools that should NOT exist (bulk-cherry-picked then reverted)
    $revertedTools = @(
        'Assign-CadenceTiers.ps1','Audit-DataQuality.ps1','Audit-EntityExtraction.ps1','Audit-SchemaDrift.ps1',
        'Audit-StreamCoverage.ps1','Build-DcrJson.ps1','Build-Manifest.ps1','Build-Phase0Indices.ps1',
        'Capture-NodocFallback.ps1','Cleanup-Resources.ps1','Grant-Post-Deploy-Rbac.ps1','Initialize-XdrLogRaiderAuth.ps1',
        'Override-FunctionAppZip.ps1','Override-SentinelSolution.ps1','Preflight-Local.ps1','Simulate-EndToEnd.ps1',
        'Smoke-E2E.ps1','Validate-AzVersions.ps1','Validate-ModuleContracts.ps1','Validate-Phase0Coverage.ps1','Verify-Deploy.ps1'
    )
    $present = @()
    $absent = @()
    foreach ($t in $revertedTools) {
        if (Test-Path (Join-Path $RepoRoot "tools/$t")) { $present += $t } else { $absent += $t }
    }
    $expected['BulkRevertedTools'] = [ordered]@{
        Expected = $revertedTools.Count
        StillPresent = @($present)
        StillPresentCount = $present.Count
        AbsentCorrectly = $absent.Count
        FullyReverted = ($present.Count -eq 0)
    }
    # Test files that should NOT exist
    $revertedTests = @('Orchestrator.PortalRouting.Tests.ps1','Orchestrator.Schedule.Tests.ps1','Sentinel.Ingest.Tests.ps1')
    $testPresent = @($revertedTests | Where-Object { Test-Path (Join-Path $RepoRoot "tests/unit/$_") })
    $expected['BulkRevertedTests'] = [ordered]@{
        Expected = $revertedTests.Count
        StillPresent = $testPresent
        FullyReverted = ($testPresent.Count -eq 0)
    }
    # Modules that should be empty skeletons (Public/ exists but empty)
    $emptyModules = @('Xdr.Common.Manifest','Xdr.Defender.Client','Xdr.Defender.Parser','Xdr.Connector.Orchestrator','Xdr.Sentinel.Ingest')
    $moduleStates = [ordered]@{}
    foreach ($m in $emptyModules) {
        $pubDir = Join-Path $RepoRoot "src/Modules/$m/Public"
        $pubCount = if (Test-Path $pubDir) { @(Get-ChildItem $pubDir -Filter '*.ps1' -File).Count } else { -1 }
        $moduleStates[$m] = $pubCount
    }
    $expected['EmptyModuleSkeletons'] = $moduleStates
    return $expected
}

# ─── Dependency graph (Step 9 build order) ─────────────────────────────────────
$dependencyGraph = [ordered]@{
    'Xdr.Common.Manifest'         = @('Xdr.Common')   # base
    'Xdr.Defender.Parser'         = @('Xdr.Common.Manifest','Xdr.Common.Auth')
    'Xdr.Defender.Client'         = @('Xdr.Common.Auth','Xdr.Defender.Auth','Xdr.Defender.Parser','Xdr.Common.Manifest')
    'Xdr.Sentinel.Ingest'         = @('Xdr.Common.Auth','Xdr.Common.Manifest')
    'Xdr.Connector.Orchestrator'  = @('Xdr.Defender.Client','Xdr.Defender.Parser','Xdr.Sentinel.Ingest','Xdr.Common.Manifest','Xdr.Common.Auth','Xdr.Common.Client')
    'src/functions/*'             = @('Xdr.Connector.Orchestrator','Xdr.Sentinel.Ingest')
    'tools/Build-DcrJson'         = @('manifests/*.psd1','references/<endpoint>/schema.json')
    'deploy/mainTemplate.json'    = @('tools/Build-DcrJson outputs','manifests/*')
}

# ─── Build report ──────────────────────────────────────────────────────────────
$report = [ordered]@{
    GeneratedUtc       = [datetime]::UtcNow.ToString('o')
    RepoRoot           = $RepoRoot
    Modules            = Get-ModuleInventory -ModulesRoot (Join-Path $RepoRoot 'src/Modules')
    Tools              = Get-ToolInventory -ToolsRoot (Join-Path $RepoRoot 'tools')
    Tests              = Get-TestInventory -TestsRoot (Join-Path $RepoRoot 'tests/unit')
    Manifests          = Get-ManifestInventory -ManRoot (Join-Path $RepoRoot 'manifests')
    Deploy             = Get-DeployInventory -DeployRoot (Join-Path $RepoRoot 'deploy')
    References         = Get-ReferenceDocInventory -RefRoot (Join-Path $RepoRoot 'references')
    RevertVerification = Get-RevertVerification -RepoRoot $RepoRoot
    DependencyGraph    = $dependencyGraph
}

# Compute summary
$modSum = $report.Modules.Values | ForEach-Object { $_.PublicCount } | Measure-Object -Sum
$toolSum = $report.Tools.Count
$testSum = $report.Tests.Count
$entrySum = ($report.Manifests.Values | ForEach-Object { $_.EntryCount } | Measure-Object -Sum).Sum
$report.Summary = [ordered]@{
    TotalModules            = @($report.Modules.Keys).Count
    TotalPublicFunctions    = $modSum.Sum
    EmptyModuleCount        = @($report.Modules.GetEnumerator() | Where-Object { $_.Value.IsEmpty }).Count
    TotalTools              = $toolSum
    SeniorDevTools          = @($report.Tools.GetEnumerator() | Where-Object { $_.Value.Authoring -eq 'senior-dev' }).Count
    TotalTests              = $testSum
    TotalManifestEntries    = $entrySum
    RevertFullyClean        = (
        $report.RevertVerification.BulkRevertedTools.FullyReverted -and
        $report.RevertVerification.BulkRevertedTests.FullyReverted
    )
}

# ─── Emit ──────────────────────────────────────────────────────────────────────
if (-not $NoEvidence) {
    $ts = [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss')
    $evDir = Join-Path $RepoRoot "tests/results/phase-0-step-0-baseline-$ts"
    $null = New-Item -ItemType Directory -Path $evDir -Force
    $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $evDir 'inventory.json') -Encoding UTF8

    # Human-readable summary
    $mdLines = [System.Collections.Generic.List[string]]::new()
    $mdLines.Add("# Phase 0' Step 0' · Baseline Audit") | Out-Null
    $mdLines.Add('') | Out-Null
    $mdLines.Add("**Generated**: $($report.GeneratedUtc)") | Out-Null
    $mdLines.Add('') | Out-Null
    $mdLines.Add('## Summary') | Out-Null
    $mdLines.Add('') | Out-Null
    $mdLines.Add("- Total modules: $($report.Summary.TotalModules)") | Out-Null
    $mdLines.Add("- Total Public functions: $($report.Summary.TotalPublicFunctions)") | Out-Null
    $mdLines.Add("- Empty module skeletons: $($report.Summary.EmptyModuleCount) (Xdr.Common.Manifest · Xdr.Defender.Client · Xdr.Defender.Parser · Xdr.Connector.Orchestrator · Xdr.Sentinel.Ingest)") | Out-Null
    $mdLines.Add("- Total tools: $($report.Summary.TotalTools) (senior-dev authored: $($report.Summary.SeniorDevTools))") | Out-Null
    $mdLines.Add("- Total Pester test files: $($report.Summary.TotalTests)") | Out-Null
    $mdLines.Add("- Total manifest entries: $($report.Summary.TotalManifestEntries)") | Out-Null
    $mdLines.Add("- Revert fully clean: $($report.Summary.RevertFullyClean)") | Out-Null
    $mdLines.Add('') | Out-Null
    $mdLines.Add('## Revert verification') | Out-Null
    $mdLines.Add('') | Out-Null
    $mdLines.Add("- 22 bulk-cherry-picked tools deleted: $(@($report.RevertVerification.BulkRevertedTools.AbsentCorrectly))/22 absent · $(@($report.RevertVerification.BulkRevertedTools.StillPresent))/22 still present") | Out-Null
    $mdLines.Add("- 3 cherry-picked test files deleted: $($report.RevertVerification.BulkRevertedTests.FullyReverted)") | Out-Null
    $mdLines.Add("- 5 module bodies emptied (Public count):") | Out-Null
    foreach ($k in $report.RevertVerification.EmptyModuleSkeletons.Keys) {
        $mdLines.Add("  - ${k}: $($report.RevertVerification.EmptyModuleSkeletons[$k]) Public fns") | Out-Null
    }
    $mdLines.Add('') | Out-Null
    $mdLines.Add('## Module Public-function inventory') | Out-Null
    $mdLines.Add('') | Out-Null
    $mdLines.Add('| Module | psd1 | psm1 | Public fns | Private fns | Empty |') | Out-Null
    $mdLines.Add('|---|---|---|---:|---:|---|') | Out-Null
    foreach ($k in $report.Modules.Keys) {
        $m = $report.Modules[$k]
        $mdLines.Add("| $k | $($m.HasPsd1) | $($m.HasPsm1) | $($m.PublicCount) | $($m.PrivateCount) | $($m.IsEmpty) |") | Out-Null
    }
    $mdLines.Add('') | Out-Null
    $mdLines.Add('## Manifests') | Out-Null
    $mdLines.Add('') | Out-Null
    $mdLines.Add('| Portal | IsActive | Entries | Top sub-areas |') | Out-Null
    $mdLines.Add('|---|---|---:|---|') | Out-Null
    foreach ($k in $report.Manifests.Keys) {
        $man = $report.Manifests[$k]
        if ($man.Contains('ParseError')) { continue }
        $top = (($man.SubAreas | Sort-Object { -$_.Count } | Select-Object -First 5 | ForEach-Object { "$($_.SubArea)($($_.Count))" }) -join ', ')
        $mdLines.Add("| $($man.Portal) | $($man.IsActive) | $($man.EntryCount) | $top |") | Out-Null
    }
    $mdLines.Add('') | Out-Null
    $mdLines.Add('## Step 9 dependency graph (build order)') | Out-Null
    $mdLines.Add('') | Out-Null
    foreach ($k in $dependencyGraph.Keys) {
        $mdLines.Add("- **$k** depends on: $(@($dependencyGraph[$k]) -join ' · ')") | Out-Null
    }
    $mdLines -join "`n" | Set-Content -LiteralPath (Join-Path $evDir 'summary.md') -Encoding UTF8

    Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Phase 0' Step 0' Baseline Audit" -ForegroundColor Cyan
    Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ("  Modules:                 {0} ({1} empty skeletons)" -f $report.Summary.TotalModules, $report.Summary.EmptyModuleCount)
    Write-Host ("  Public functions:        {0}" -f $report.Summary.TotalPublicFunctions)
    Write-Host ("  Tools (senior-dev):      {0} / {1}" -f $report.Summary.SeniorDevTools, $report.Summary.TotalTools)
    Write-Host ("  Pester test files:       {0}" -f $report.Summary.TotalTests)
    Write-Host ("  Manifest entries:        {0}" -f $report.Summary.TotalManifestEntries)
    $color = if ($report.Summary.RevertFullyClean) { 'Green' } else { 'Red' }
    Write-Host ("  Revert fully clean:      {0}" -f $report.Summary.RevertFullyClean) -ForegroundColor $color
    Write-Host ""
    Write-Host "  Evidence: $evDir" -ForegroundColor Green
}

if (-not $report.Summary.RevertFullyClean) { exit 1 } else { exit 0 }
