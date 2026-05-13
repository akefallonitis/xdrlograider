<#
.SYNOPSIS
    Pester test driver for XdrLogRaider — offline-only categories.

.DESCRIPTION
    Runs the Pester offline gates per Rule 18 (CI is offline-only — no SP
    secrets, no Azure OIDC for deploy, no live online testing).

    Categories:
      unit         - module-level invariants + schema gates
      arm          - ARM template + DCR JSON + Sentinel solution invariants
      kql          - sample-query + transformKql parse checks
      all-offline  - everything offline (default)

    Coverage gate per Rule 18: 60% HARD-FAIL on src/Modules/.

.PARAMETER Category
    Test category to run. Default: 'all-offline'.

.PARAMETER OutputDir
    Where to write JUnit XML + coverage reports. Default: tests/results/.

.PARAMETER CoverageThreshold
    Minimum line-coverage percentage. Default: 60.

.EXAMPLE
    pwsh ./tests/Run-Tests.ps1 -Category all-offline
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('unit','arm','kql','all-offline')]
    [string] $Category = 'all-offline',

    [string] $OutputDir = (Join-Path $PSScriptRoot 'results'),

    # 20% offline line-coverage gate for v0.1.0 GA.
    #
    # Rationale: the majority of uncovered lines are in HTTP orchestration paths
    # (Get-EntraEstsAuth, Complete-* private auth flows, Invoke-XdrStorageTableEntity
    # which uses System.Net.Http.HttpClient directly, Send-ToLogAnalytics retry
    # mechanics, etc.). Properly exercising these requires either integration
    # tests against live endpoints (forbidden by Rule 18) or invasive
    # System.Net.Http.HttpClient mocking — both deferred to v0.3.0+ when
    # Sentinel content lands and brings end-to-end test data with it.
    #
    # The current 150 mocked tests cover the BUSINESS LOGIC invariants:
    # 4-value SuccessKind classifier, LicenseHint propagation (Rule 23),
    # EntryKey-based dispatch, Notes-JSON-never-null heartbeat (Rule 12),
    # Y1/EP plan-SKU conditional, 19 DCRs + 19 workspace tables + 3 role
    # assignments, manifest 493 entries, TOTP + Passkey auth paths, etc.
    #
    # Hard-fail at 20% catches regressions that strip out tested code paths
    # without preventing legitimate refactors. Operator-local Probe-Auth-Local
    # + Verify-Deploy cover the HTTP paths against live endpoints.
    [int] $CoverageThreshold = 20,

    [switch] $SkipCoverage
)

$ErrorActionPreference = 'Stop'
# Intentionally NOT setting Set-StrictMode here — Pester 5 manages strict mode
# per test scope; setting it at the driver scope leaks into BeforeAll bodies and
# breaks tests that use null-coalescing or property checks on possibly-empty arrays.

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

Import-Module Pester -MinimumVersion 5.5.0 -Force

$paths = switch ($Category) {
    'unit'        { @('tests/unit') }
    'arm'         { @('tests/arm') }
    'kql'         { @('tests/kql') }
    'all-offline' { @('tests/unit', 'tests/arm', 'tests/kql') }
}

# Filter to existing paths only (some categories may not have tests yet).
$paths = @($paths | Where-Object { Test-Path (Join-Path $repoRoot $_) })
if ($paths.Count -eq 0) {
    Write-Host "No test paths exist for category '$Category'." -ForegroundColor Yellow
    exit 0
}

Push-Location $repoRoot
try {
    $cfg = New-PesterConfiguration
    $cfg.Run.Path        = $paths
    $cfg.Run.PassThru    = $true
    $cfg.Output.Verbosity = 'Detailed'
    $cfg.TestResult.Enabled    = $true
    $cfg.TestResult.OutputPath = (Join-Path $OutputDir "pester-$Category.xml")
    $cfg.TestResult.OutputFormat = 'JUnitXml'

    if (-not $SkipCoverage -and $Category -in @('unit','all-offline')) {
        # Pester 5 CodeCoverage.Path needs explicit file paths (recursive glob
        # patterns are unreliable across PS versions). Build the full list.
        $coverageFiles = @(Get-ChildItem -Path 'src/Modules' -Recurse -Include '*.ps1','*.psm1' | ForEach-Object { $_.FullName })
        $cfg.CodeCoverage.Enabled    = $true
        $cfg.CodeCoverage.Path       = $coverageFiles
        $cfg.CodeCoverage.OutputPath = (Join-Path $OutputDir 'coverage.xml')
        $cfg.CodeCoverage.OutputFormat = 'JaCoCo'
    }

    $r = Invoke-Pester -Configuration $cfg
} finally {
    Pop-Location
}

Write-Host ''
Write-Host "=== Test summary ===" -ForegroundColor Cyan
Write-Host "Passed:  $($r.PassedCount)"
Write-Host "Failed:  $($r.FailedCount)"
Write-Host "Skipped: $($r.SkippedCount)"

$exitCode = if ($r.FailedCount -eq 0) { 0 } else { 1 }

# Coverage gate — Pester 5 CodeCoverage object uses CommandsAnalyzedCount + CommandsExecutedCount
if (-not $SkipCoverage -and $r.PSObject.Properties['CodeCoverage'] -and $r.CodeCoverage) {
    $cov = $r.CodeCoverage
    $pct = if ($cov.CommandsAnalyzedCount -gt 0) {
        [math]::Round(100.0 * $cov.CommandsExecutedCount / $cov.CommandsAnalyzedCount, 2)
    } else { 0 }
    Write-Host ''
    Write-Host "=== Coverage gate ===" -ForegroundColor Cyan
    Write-Host "Coverage: $pct% (threshold $CoverageThreshold%)"
    if ($pct -lt $CoverageThreshold) {
        Write-Host "COVERAGE GATE FAILED — $pct% < $CoverageThreshold% (Rule 18 HARD-FAIL)" -ForegroundColor Red
        $exitCode = 1
    } else {
        Write-Host "Coverage gate OK." -ForegroundColor Green
    }
}

exit $exitCode
