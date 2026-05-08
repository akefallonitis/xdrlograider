#Requires -Version 7.0
<#
.SYNOPSIS
    One-shot local pre-commit gate. Mirrors what CI runs server-side.

.DESCRIPTION
    Run before every git commit. Chains:

      1. Pyramid offline tests (tests/Run-Tests.ps1 -Category all-offline) — 1844 tests
      2. WiringAudit (tools/Run-WiringAudit.ps1) — 12-edge × 64 streams
      3. ARM JSON validation (tools/Validate-ArmJson.ps1) — cross-RG dependsOn + parameter usage
      4. Manifest validation (tools/Validate-Manifest.ps1) — schema + uniqueness gates
      5. DCR schema audit (tools/Audit-DcrSchema.ps1) — 4-layer schema integrity
      6. PSScriptAnalyzer (errors only) — src/, tools/, tests/ scoped

    Exit 0 only if ALL stages pass. Exit 1 with structured diagnostic on first failure.
    Run time: ~6-8 minutes locally. Same as CI server-side.

.EXAMPLE
    pwsh ./tools/Pre-Commit-Check.ps1
#>
[CmdletBinding()]
param(
    [switch] $SkipPyramid,
    [switch] $SkipLint
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path -Parent $PSScriptRoot

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " XdrLogRaider Pre-Commit Gate"             -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

$results = [ordered]@{}
$start = Get-Date

function Run-Stage {
    param([string]$Name, [scriptblock]$Action)
    $stageStart = Get-Date
    Write-Host ""
    Write-Host "[$Name]" -ForegroundColor Cyan
    try {
        & $Action
        $duration = ((Get-Date) - $stageStart).TotalSeconds
        Write-Host "  ✓ PASS ($([math]::Round($duration, 1))s)" -ForegroundColor Green
        $script:results[$Name] = @{ Status = 'PASS'; Duration = $duration }
    } catch {
        $duration = ((Get-Date) - $stageStart).TotalSeconds
        Write-Host "  ✗ FAIL ($([math]::Round($duration, 1))s)" -ForegroundColor Red
        Write-Host "    $($_.Exception.Message)" -ForegroundColor Red
        $script:results[$Name] = @{ Status = 'FAIL'; Duration = $duration; Error = $_.Exception.Message }
        # Continue — collect all failures, report at end
    }
}

# Stage 1: Pyramid
if (-not $SkipPyramid) {
    Run-Stage 'Pyramid' {
        & (Join-Path $repoRoot 'tests/Run-Tests.ps1') -Category all-offline | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Pyramid exit $LASTEXITCODE" }
    }
}

# Stage 2: WiringAudit
Run-Stage 'WiringAudit' {
    & (Join-Path $repoRoot 'tools/Run-WiringAudit.ps1') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "WiringAudit exit $LASTEXITCODE" }
}

# Stage 3: Validate-ArmJson
Run-Stage 'Validate-ArmJson' {
    & (Join-Path $repoRoot 'tools/Validate-ArmJson.ps1') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Validate-ArmJson exit $LASTEXITCODE" }
}

# Stage 4: Validate-Manifest
Run-Stage 'Validate-Manifest' {
    & (Join-Path $repoRoot 'tools/Validate-Manifest.ps1') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Validate-Manifest exit $LASTEXITCODE" }
}

# Stage 5: DCR schema audit (4-layer integrity)
Run-Stage 'Audit-DcrSchema' {
    & (Join-Path $repoRoot 'tools/Audit-DcrSchema.ps1') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Audit-DcrSchema exit $LASTEXITCODE — schema layer drift detected; see tests/arm/SchemaConsistency.Tests.ps1 for the gates and tools/Build-DcrSection.ps1 to regenerate" }
}

# Stage 6: PSScriptAnalyzer (errors only)
if (-not $SkipLint) {
    Run-Stage 'PSScriptAnalyzer' {
        if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
            throw 'PSScriptAnalyzer not installed. Run: Install-Module -Name PSScriptAnalyzer -Scope CurrentUser'
        }
        $settings = Join-Path $repoRoot '.config/PSScriptAnalyzerSettings.psd1'
        $errors = @()
        foreach ($path in 'src', 'tools', 'tests') {
            $r = Invoke-ScriptAnalyzer -Path (Join-Path $repoRoot $path) -Recurse -Settings $settings -ErrorAction Continue
            $errors += @($r | Where-Object Severity -eq 'Error')
        }
        if ($errors.Count -gt 0) {
            $errors | ForEach-Object { Write-Host "    $($_.ScriptName):L$($_.Line) — $($_.RuleName): $($_.Message)" -ForegroundColor Yellow }
            throw "$($errors.Count) PSScriptAnalyzer error(s)"
        }
    }
}

# Final report
$totalDuration = ((Get-Date) - $start).TotalSeconds
$passes = @($results.Values | Where-Object Status -eq 'PASS').Count
$fails  = @($results.Values | Where-Object Status -eq 'FAIL').Count

Write-Host ""
Write-Host "============================================" -ForegroundColor Yellow
if ($fails -eq 0) {
    Write-Host " VERDICT: GREEN — ready to commit" -ForegroundColor Green
} else {
    Write-Host " VERDICT: RED — $fails stage(s) failed" -ForegroundColor Red
}
Write-Host "============================================" -ForegroundColor Yellow
Write-Host "  Stages: $passes/$($results.Count) passed"
Write-Host "  Total:  $([math]::Round($totalDuration, 1))s"
Write-Host ""

if ($fails -gt 0) {
    Write-Host "Failed stages:" -ForegroundColor Red
    foreach ($k in $results.Keys) {
        if ($results[$k].Status -eq 'FAIL') {
            Write-Host "  $k — $($results[$k].Error)" -ForegroundColor Red
        }
    }
    exit 1
}
exit 0
