<#
.SYNOPSIS
    Entry point for XdrLogRaider test suites. See docs/TESTING.md for the full walkthrough.

.DESCRIPTION
    Pester categories mapped to the four-quadrant testing model (pre-deploy × post-deploy × local × online):

      OFFLINE (zero external deps — CI-friendly)
        unit          Fully mocked unit tests for all 3 modules (~250)
        validate      KQL parser + ARM template schema tests (~55)
        all-offline   unit + validate (what CI runs; default path)

      ONLINE — PRE-DEPLOY (verify your service-account credentials against the live portal)
        local-online  Auth chain live against security.microsoft.com
                      Requires tests/.env.local with the service account's creds.
                      No Azure infra touched. No CI integration — laptop only.

      ONLINE — POST-DEPLOY (verify a deployed instance is working)
        e2e           KQL-based verification of a deployed workspace.
                      Requires Connect-AzAccount + XDRLR_ONLINE=true
                             + XDRLR_TEST_RG + XDRLR_TEST_WORKSPACE set.

.PARAMETER Category
    Which test set to run. Defaults to 'unit'.

.PARAMETER FailFast
    Stop at first failure. Default is to run all tests and report.

.PARAMETER Detailed
    Verbose Pester output. Default is Normal.

.EXAMPLE
    # Default offline run (no external deps)
    ./tests/Run-Tests.ps1 -Category all-offline

.EXAMPLE
    # Pre-deploy online — confirm credentials work
    #   1. cp tests/.env.local.example tests/.env.local
    #   2. fill in XDRLR_TEST_UPN + password + TOTP seed
    ./tests/Run-Tests.ps1 -Category local-online

.EXAMPLE
    # Post-deploy online — confirm deployed instance ingested rows
    Connect-AzAccount
    $env:XDRLR_ONLINE = 'true'
    $env:XDRLR_TEST_RG = 'xdrlr-prod-rg'
    $env:XDRLR_TEST_WORKSPACE = 'sentinel-prod-ws'
    ./tests/Run-Tests.ps1 -Category e2e
#>

[CmdletBinding()]
param(
    # Categories:
    #   unit / validate / all-offline  — CI-friendly, no external deps
    #   local-online                   — pre-deploy: real portal sign-in from laptop
    #   e2e                            — post-deploy: KQL verification of deployed workspace
    [ValidateSet('unit', 'validate', 'e2e', 'local-online', 'all-offline')]
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
    'e2e'          { @('./tests/e2e') }
    'local-online' { @('./tests/integration/Auth-Chain-Live.Tests.ps1') }
    'all-offline'  { @('./tests/unit', './tests/kql', './tests/arm') }
}

# --- Online gating ------------------------------------------------------------

if ($Category -eq 'e2e') {
    if ($env:XDRLR_ONLINE -ne 'true') {
        Write-Warning "e2e tests gated by XDRLR_ONLINE=true. Skipping."
        exit 0
    }
    if (-not $env:XDRLR_TEST_RG -or -not $env:XDRLR_TEST_WORKSPACE) {
        throw "e2e tests require XDRLR_TEST_RG + XDRLR_TEST_WORKSPACE env vars. See docs/TESTING.md."
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
