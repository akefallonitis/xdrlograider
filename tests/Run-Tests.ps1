#Requires -Version 7.4
#Requires -Module @{ ModuleName='Pester'; ModuleVersion='5.5.0' }
<#
.SYNOPSIS
    Tier-aware Pester driver. The ONLY test entry point.

.DESCRIPTION
    Tier 1 (unit)        — no IO; mocks + fixtures; runs in CI + pre-commit hook; <30s.
    Tier 2 (integration) — SP credentials; ARM/KQL validate; runs locally + CI OIDC; <2min.
    Tier 3 (live)        — SA + TOTP; live portal probe; LOCAL ONLY, manual; ~60min/batch.
    Tier 4 (live-connected) — SP credentials; KQL + Storage Table probes against
                              DEPLOYED Function App; Pi5 · D-pi4; LOCAL only; ~2min.

    Also runs PSScriptAnalyzer with custom rules (Tier 1) and writes a single-line
    summary so CI logs stay scannable.

.PARAMETER Tier
    1 | 2 | 3 (default: 1)

.PARAMETER FailFast
    Stop after first failure.

.PARAMETER SkipPSSA
    Tier 1 only — skip PSScriptAnalyzer (faster iteration during dev).

.PARAMETER CoverageThreshold
    Tier 1 only — minimum line coverage on src/Modules/Xdr.*. Default 50.

.EXAMPLE
    pwsh tests/Run-Tests.ps1 -Tier 1
    pwsh tests/Run-Tests.ps1 -Tier 1 -FailFast -SkipPSSA
    pwsh tests/Run-Tests.ps1 -Tier 2

.OUTPUTS
    Exits 0 on full pass, 1 on any failure.
#>

[CmdletBinding()]
param(
    [ValidateSet('1','2','3','4')][string]$Tier = '1',
    [switch]$FailFast,
    [switch]$SkipPSSA,
    [int]$CoverageThreshold = 50
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$tierDir  = switch ($Tier) {
    '1' { Join-Path $repoRoot 'tests\unit' }
    '2' { Join-Path $repoRoot 'tests\integration' }
    '3' { Join-Path $repoRoot 'tests\live' }
    '4' { Join-Path $repoRoot 'tests\integration' }  # Pi5 · Tier-4 lives in tests/integration/ · uses Pester -Tag filter to scope
}

# Validate env per tier
& (Join-Path $PSScriptRoot 'Assert-EnvLocal.ps1') -Tier $Tier

# Sanity: tier dir exists (integration/live may be empty in early P0/P1)
if (-not (Test-Path $tierDir)) {
    Write-Warning "Tier $Tier directory '$tierDir' does not exist yet. Nothing to run."
    return
}

# --- PSScriptAnalyzer (Tier 1 only) ---
if ($Tier -eq '1' -and -not $SkipPSSA) {
    Import-Module PSScriptAnalyzer -MinimumVersion 1.21.0 -Force -ErrorAction SilentlyContinue
    if (Get-Module PSScriptAnalyzer) {
        $analyzerRules = Join-Path $repoRoot 'tests\analyzer\XdrCustomRules.psm1'
        $scanRoots = @(
            (Join-Path $repoRoot 'src'),
            (Join-Path $repoRoot 'manifests'),
            (Join-Path $repoRoot 'tools')
        )
        $pssaResults = @()
        foreach ($root in $scanRoots) {
            if (Test-Path $root) {
                $pssaResults += Invoke-ScriptAnalyzer -Path $root -Recurse `
                    -CustomRulePath $analyzerRules `
                    -Severity Error -ErrorAction SilentlyContinue
            }
        }
        if ($pssaResults) {
            Write-Host "PSSA: $($pssaResults.Count) error(s)" -ForegroundColor Red
            $pssaResults | Format-Table RuleName, ScriptName, Line, Message -AutoSize -Wrap |
                Out-String | Write-Host
            if ($FailFast) { exit 1 }
        } else {
            Write-Host "PSSA: 0 errors (custom rules clean)" -ForegroundColor Green
        }
    } else {
        Write-Warning "PSScriptAnalyzer not installed — skipping. Install: Install-Module PSScriptAnalyzer -Scope CurrentUser"
    }
}

# --- Pester ---
$pesterCfg = New-PesterConfiguration
$pesterCfg.Run.Path     = $tierDir
$pesterCfg.Run.PassThru = $true
$pesterCfg.Output.Verbosity = 'Normal'
if ($FailFast) { $pesterCfg.Run.Exit = $true }

# Pi5 · Tier 4 scopes to Tag='tier4' (Runtime.LiveConnected.PostDeploy.Tests.ps1 ·
# 11 Describe blocks · KQL probes against deployed FA). Skips when env vars missing
# OR no xdrlr* deployment in RG.
if ($Tier -eq '4') {
    $pesterCfg.Filter.Tag = @('tier4')
}

if ($Tier -eq '1' -and (Test-Path (Join-Path $repoRoot 'src\Modules'))) {
    $pesterCfg.CodeCoverage.Enabled = $true
    $pesterCfg.CodeCoverage.Path    = (Get-ChildItem (Join-Path $repoRoot 'src\Modules') -Recurse -Filter *.psm1).FullName
}

Write-Host ""
Write-Host "=== Pester Tier $Tier ===" -ForegroundColor Cyan
$result = Invoke-Pester -Configuration $pesterCfg

# Summary
Write-Host ""
Write-Host "Tier $Tier — Passed=$($result.PassedCount) Failed=$($result.FailedCount) Skipped=$($result.SkippedCount) Total=$($result.TotalCount) Duration=$([math]::Round($result.Duration.TotalSeconds,1))s" -ForegroundColor $(if ($result.FailedCount -eq 0) { 'Green' } else { 'Red' })

# Coverage gate (Tier 1)
if ($Tier -eq '1' -and $pesterCfg.CodeCoverage.Enabled) {
    $cov = $result.CodeCoverage
    if ($cov -and $cov.CommandsAnalyzedCount -gt 0) {
        $pct = [math]::Round(100 * $cov.CommandsExecutedCount / $cov.CommandsAnalyzedCount, 1)
        Write-Host "Coverage: $pct% ($($cov.CommandsExecutedCount)/$($cov.CommandsAnalyzedCount) commands)" `
            -ForegroundColor $(if ($pct -ge $CoverageThreshold) { 'Green' } else { 'Yellow' })
        if ($pct -lt $CoverageThreshold) {
            Write-Warning "Coverage $pct% < threshold $CoverageThreshold% (warning only at P0; gated hard at P2)"
        }
    }
}

if ($result.FailedCount -gt 0) {
    exit 1
}
exit 0
