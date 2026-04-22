<#
.SYNOPSIS
    Entry point for XdrLogRaider test suites.

.DESCRIPTION
    Runs Pester tests across four categories:
      - unit         Fully mocked, fast (<1 min), offline
      - validate     KQL + workbook/rule JSON + ARM-TTK (<30s)
      - integration  Live portal calls (gated by XDRLR_ONLINE env)
      - e2e          Full deploy+ingest+workbook validation on a test tenant
      - all-offline  Runs unit + validate (CI-default)
      - all-online   Runs integration + e2e (manual only)

.PARAMETER Category
    Which test set to run. Defaults to 'unit'.

.PARAMETER FailFast
    Stop at first failure. Default is to run all tests and report.

.PARAMETER Detailed
    Verbose Pester output. Default is Normal.

.EXAMPLE
    ./tests/Run-Tests.ps1 -Category unit

.EXAMPLE
    $env:XDRLR_ONLINE = 'true'
    ./tests/Run-Tests.ps1 -Category integration
#>

[CmdletBinding()]
param(
    [ValidateSet('unit', 'validate', 'integration', 'e2e', 'local-online', 'all-offline', 'all-online')]
    [string] $Category = 'unit',

    [switch] $FailFast,

    [switch] $Detailed
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- Preflight ----------------------------------------------------------------

$minPesterVersion = [version]'5.5.0'
$pester = Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge $minPesterVersion } | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) {
    throw "Pester $minPesterVersion+ not installed. Run: Install-Module Pester -MinimumVersion $minPesterVersion -Force -Scope CurrentUser"
}
Import-Module $pester.Path -Force

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

# --- Category → paths ---------------------------------------------------------

$paths = switch ($Category) {
    'unit'         { @('./tests/unit') }
    'validate'     { @('./tests/kql', './tests/arm') }
    'integration'  { @('./tests/integration') }
    'e2e'          { @('./tests/e2e') }
    'local-online' { @('./tests/integration/Auth-Chain-Live.Tests.ps1') }
    'all-offline'  { @('./tests/unit', './tests/kql', './tests/arm') }
    'all-online'   { @('./tests/integration', './tests/e2e') }
}

# --- Online gating ------------------------------------------------------------

if ($Category -in @('integration', 'e2e', 'all-online')) {
    if ($env:XDRLR_ONLINE -ne 'true') {
        Write-Warning "Online tests gated by XDRLR_ONLINE=true. Skipping."
        exit 0
    }
    if (-not $env:XDRLR_TEST_KV) {
        throw "XDRLR_TEST_KV env var required for online tests"
    }
}

# Local-online tests use real tenant credentials loaded from env vars or .env file.
# No Key Vault required — user provides TOTP/passkey directly.
if ($Category -eq 'local-online') {
    $envFile = Join-Path $repoRoot 'tests' '.env.local'
    if (Test-Path $envFile) {
        Write-Host "Loading local env from tests/.env.local" -ForegroundColor Yellow
        Get-Content $envFile | Where-Object { $_ -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.+)$' } | ForEach-Object {
            if ($_ -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.+)$') {
                $name  = $Matches[1]
                $value = $Matches[2].Trim().Trim('"').Trim("'")
                [System.Environment]::SetEnvironmentVariable($name, $value, 'Process')
            }
        }
    }
    if (-not $env:XDRLR_TEST_UPN) {
        throw @"
local-online tests require XDRLR_TEST_UPN env var.
Either:
  1. Create tests/.env.local from tests/.env.local.example and fill in values
  2. Set env vars directly:
       `$env:XDRLR_TEST_UPN         = 'svc@your-tenant.com'
       `$env:XDRLR_TEST_AUTH_METHOD = 'CredentialsTotp'   # or 'Passkey'
       `$env:XDRLR_TEST_PASSWORD    = '<your password>'   # CredentialsTotp only
       `$env:XDRLR_TEST_TOTP_SECRET = 'JBSWY3DPEHPK3PXP'  # CredentialsTotp only
       `$env:XDRLR_TEST_PASSKEY_PATH = './my-passkey.json' # Passkey only

See tests/README.md for full instructions.
"@
    }
    $env:XDRLR_ONLINE = 'true'
}

# --- Pester configuration -----------------------------------------------------

$cfg = New-PesterConfiguration
$cfg.Run.Path = $paths
# We handle exit ourselves below so we can print a friendly summary.
$cfg.Run.Exit = $false
$cfg.Run.PassThru = $true
$cfg.Run.Throw = $FailFast.IsPresent
$cfg.Output.Verbosity = if ($Detailed.IsPresent) { 'Detailed' } else { 'Normal' }
$cfg.TestResult.Enabled = $true
$cfg.TestResult.OutputFormat = 'JUnitXml'

$resultsDir = Join-Path $repoRoot 'tests/results'
if (-not (Test-Path $resultsDir)) {
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
}
$cfg.TestResult.OutputPath = Join-Path $resultsDir "$Category.xml"

# Coverage for unit/offline categories
if ($Category -in @('unit', 'all-offline')) {
    $cfg.CodeCoverage.Enabled = $true
    $cfg.CodeCoverage.Path = @('./src/Modules/**/*.ps1', './src/functions/**/*.ps1', './tools/*.ps1')
    $cfg.CodeCoverage.OutputPath = Join-Path $resultsDir "coverage-$Category.xml"
    $cfg.CodeCoverage.OutputFormat = 'JaCoCo'
}

# --- Banner -------------------------------------------------------------------

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  XdrLogRaider — Test Suite" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Category:    $Category" -ForegroundColor Cyan
Write-Host "  Paths:       $($paths -join ', ')" -ForegroundColor Cyan
Write-Host "  Pester:      $($pester.Version)" -ForegroundColor Cyan
Write-Host "  PS version:  $($PSVersionTable.PSVersion)" -ForegroundColor Cyan
Write-Host "  OS:          $($PSVersionTable.OS)" -ForegroundColor Cyan
Write-Host "  Results dir: $resultsDir" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# --- Run ---------------------------------------------------------------------

$result = Invoke-Pester -Configuration $cfg

# Defensive — with Run.Exit=$false + Run.PassThru=$true Pester always returns
# a result object, but strict mode makes missing properties throw, so guard.
$failedCount  = if ($result -and $result.PSObject.Properties['FailedCount'])  { [int]$result.FailedCount }  else { 0 }
$passedCount  = if ($result -and $result.PSObject.Properties['PassedCount'])  { [int]$result.PassedCount }  else { 0 }
$skippedCount = if ($result -and $result.PSObject.Properties['SkippedCount']) { [int]$result.SkippedCount } else { 0 }
$containerFailures = @()
if ($result -and $result.PSObject.Properties['Containers']) {
    $containerFailures = @($result.Containers | Where-Object { $_.Result -eq 'Failed' })
}

if ($failedCount -gt 0 -or $containerFailures.Count -gt 0) {
    Write-Host ""
    if ($failedCount -gt 0) {
        Write-Host "FAILED: $failedCount test(s) failed" -ForegroundColor Red
    }
    if ($containerFailures.Count -gt 0) {
        Write-Host "FAILED: $($containerFailures.Count) container(s) failed at discovery" -ForegroundColor Red
        $containerFailures | ForEach-Object { Write-Host "  - $($_.Item)" -ForegroundColor Red }
    }
    exit 1
}

Write-Host ""
Write-Host "PASSED: $passedCount test(s) · Skipped: $skippedCount" -ForegroundColor Green
exit 0
