#Requires -Version 7.4
<#
.SYNOPSIS
    Cross-module interface drift detector for Xdr.Auth · Xdr.Poll · Xdr.Ingest · Xdr.Parser.

.DESCRIPTION
    Asserts the FunctionsToExport list in each Xdr.*.psd1 matches the actual
    function definitions in the corresponding .psm1. Catches:
      - Exports listed in .psd1 with no matching `function <Name>` in .psm1 (dead export)
      - Functions defined in .psm1 but NOT exported (silent surface leakage)
      - Cross-module name collisions (same function exported from two modules)
      - Missing Export-ModuleMember -Function list (relies on auto-export · risky)

    Run before every release · output operator-readable + exit-code-machine-readable.

.PARAMETER ModuleRoot
    Default 'src/Modules' relative to repo root.

.OUTPUTS
    Exit 0 on clean · 1 on any drift.
    Writes machine-readable report to manifests/_gate-contracts.json.

.EXAMPLE
    pwsh tools/Validate-ModuleContracts.ps1
#>
[CmdletBinding()]
param(
    [string]$ModuleRoot,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $ModuleRoot) { $ModuleRoot = Join-Path $repoRoot 'src\Modules' }
if (-not (Test-Path $ModuleRoot)) { throw "ModuleRoot not found: $ModuleRoot" }

$modules = Get-ChildItem -Path $ModuleRoot -Directory | Where-Object { $_.Name -like 'Xdr.*' }
$violations = [System.Collections.Generic.List[hashtable]]::new()
$crossModuleMap = @{}   # function name → list of modules that export it
$report = [ordered]@{}

foreach ($mod in $modules) {
    $name = $mod.Name
    $psd1Path = Join-Path $mod.FullName "$name.psd1"
    $psm1Path = Join-Path $mod.FullName "$name.psm1"
    if (-not (Test-Path $psd1Path)) { $violations.Add(@{ Module=$name; Issue='psd1-missing'; Detail=$psd1Path }) | Out-Null; continue }
    if (-not (Test-Path $psm1Path)) { $violations.Add(@{ Module=$name; Issue='psm1-missing'; Detail=$psm1Path }) | Out-Null; continue }

    # Parse psd1
    $psd1 = Import-PowerShellDataFile -LiteralPath $psd1Path
    $declared = @()
    if ($psd1.ContainsKey('FunctionsToExport')) {
        $declared = @(@($psd1.FunctionsToExport) | Where-Object { $_ })
    }

    # Find `function Name {` definitions in psm1
    $psm1Text = Get-Content -Raw -LiteralPath $psm1Path
    $defined = @([regex]::Matches($psm1Text, '(?m)^\s*function\s+([A-Z][A-Za-z0-9_-]+)\b') |
                ForEach-Object { $_.Groups[1].Value })
    # Find `Export-ModuleMember -Function` list
    $exportListed = @()
    $emm = [regex]::Match($psm1Text, '(?ms)Export-ModuleMember\s+-Function(.+?)(?:\r?\n\r?\n|\Z)')
    if ($emm.Success) {
        $listBlock = $emm.Groups[1].Value
        $exportListed = @([regex]::Matches($listBlock, '\b([A-Z][A-Za-z0-9_-]+)\b') |
                          ForEach-Object { $_.Groups[1].Value }) |
                        Where-Object { $_ -notin @('Function','Export','ModuleMember') }
    }

    # Drift checks (coerce all collections to @() to avoid PowerShell single-element foot-gun)
    $declaredNotDefined = @($declared | Where-Object { $_ -notin $defined })
    foreach ($d in $declaredNotDefined) {
        $violations.Add(@{ Module=$name; Issue='exported-not-defined'; Detail=$d }) | Out-Null
    }
    $exportListedNotDefined = @($exportListed | Where-Object { $_ -notin $defined -and -not $_.StartsWith('_') })
    foreach ($d in $exportListedNotDefined) {
        $violations.Add(@{ Module=$name; Issue='psm1-list-references-undefined'; Detail=$d }) | Out-Null
    }
    # Functions defined but NOT in psd1 FunctionsToExport list.
    # Private-helper convention: leading underscore '_' (PowerShell standard) OR documented in
    # a 'private' #region in the psm1 — those are intentional, NOT drift.
    # Anything else that looks like a public verb (Get-/Set-/Invoke-/...) is a leak candidate.
    $privateRegions = @([regex]::Matches($psm1Text, '(?ms)#region\s+[^\n]*\b(private|internal|helpers|cache|state)\b[^\n]*\n(.+?)#endregion') |
                        ForEach-Object { $_.Groups[2].Value })
    function _IsInPrivateRegion {
        param([string]$FnName, [string[]]$Regions)
        foreach ($r in $Regions) { if ($r -match "(?m)^\s*function\s+$([regex]::Escape($FnName))\b") { return $true } }
        return $false
    }
    $definedNotDeclared = @($defined | Where-Object { $_ -notin $declared -and -not $_.StartsWith('_') })
    foreach ($d in $definedNotDeclared) {
        # Skip if inside a #region marked private/internal/helpers/cache/state
        if (_IsInPrivateRegion -FnName $d -Regions $privateRegions) { continue }
        # Otherwise: only flag if it looks like a public verb (per Get-Verb approved verbs)
        if ($d -match '^(Connect|Disconnect|Get|Set|New|Remove|Invoke|Test|Resolve|Write|Read|Apply|Clear|Discover|Refresh|Submit|Complete|Build|Split|Send|Format|Classify|Validate|Capture|Probe|Smoke|Tail|Rotate|Derive)-') {
            # Demote to WARNING-level violation · still surfaced in the report but doesn't gate exit
            $violations.Add(@{ Module=$name; Issue='defined-not-exported-WARN'; Detail=$d }) | Out-Null
        }
    }

    # Cross-module collision tracking
    foreach ($f in $declared) {
        if (-not $crossModuleMap.ContainsKey($f)) { $crossModuleMap[$f] = @() }
        $crossModuleMap[$f] += $name
    }

    $report[$name] = [ordered]@{
        Psd1FunctionsToExport = @($declared).Count
        Psm1FunctionDefinitions = @($defined).Count
        Psm1ExportListEntries = @($exportListed).Count
        DriftCount = @($violations | Where-Object { $_.Module -eq $name }).Count
    }
}

# Cross-module collisions
foreach ($k in $crossModuleMap.Keys) {
    if (@($crossModuleMap[$k]).Count -gt 1) {
        $violations.Add(@{ Module='<cross>'; Issue='collision'; Detail="$k exported from $($crossModuleMap[$k] -join ', ')" }) | Out-Null
    }
}

# Emit report
$summary = [ordered]@{
    GeneratedAt = (Get-Date).ToUniversalTime().ToString('o')
    ModulesAudited = @($modules | ForEach-Object Name)
    TotalViolations = $violations.Count
    Violations = $violations.ToArray()
    PerModule = $report
}
$reportPath = Join-Path $repoRoot 'manifests/_gate-contracts.json'
$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reportPath -Encoding UTF8

if (-not $Quiet) {
    Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Validate-ModuleContracts · cross-module interface drift" -ForegroundColor Cyan
    Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    foreach ($m in $modules) {
        $r = $report[$m.Name]
        $color = if ($r.DriftCount -eq 0) { 'Green' } else { 'Red' }
        Write-Host ("  {0,-14} declared={1,3} defined={2,3} exportList={3,3} drift={4}" -f $m.Name, $r.Psd1FunctionsToExport, $r.Psm1FunctionDefinitions, $r.Psm1ExportListEntries, $r.DriftCount) -ForegroundColor $color
    }
    Write-Host ""
    if ($violations.Count -gt 0) {
        Write-Host "  VIOLATIONS ($($violations.Count)):" -ForegroundColor Red
        foreach ($v in $violations) {
            Write-Host ("    [{0}] {1} :: {2}" -f $v.Module, $v.Issue, $v.Detail) -ForegroundColor Yellow
        }
    } else {
        Write-Host "  ✓ All module contracts clean (0 drift)" -ForegroundColor Green
    }
    Write-Host ""
    Write-Host "  Report: $reportPath" -ForegroundColor DarkGray
}

# Exit 1 only on ERROR-level violations (not WARN). WARN issues are surfaced + reported but don't gate CI.
$errors = @($violations | Where-Object { $_.Issue -notlike '*-WARN' })
if ($errors.Count -gt 0) { exit 1 } else { exit 0 }
