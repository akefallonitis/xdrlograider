<#
.SYNOPSIS
    Single-command driver that walks you from "laptop clone" to "proven-working
    production deployment" by orchestrating every test phase in order.

.DESCRIPTION
    This is the concierge for the four-phase pipeline:

      PHASE 1. OFFLINE  — unit/KQL/ARM tests, no network. Sanity check.
      PHASE 2. PREDEPLOY — live auth + endpoint audit against real tenant.
                           Gate for "credentials are good; code compiles".
      PHASE 3. DEPLOY   — user clicks Deploy-to-Azure + runs auth helper.
                           (Script pauses + waits for the go-ahead.)
      PHASE 4. POSTDEPLOY — KQL-based e2e checks that every stream ingests,
                            heartbeats flow, Sentinel content lit up.

    Exit code = 0 only if every phase that ran was green. Any skipped phase is
    reported but doesn't fail.

.PARAMETER Skip
    Comma-separated list of phases to skip: offline, predeploy, postdeploy.
    Example: -Skip 'predeploy' when you've already proven creds separately.

.PARAMETER NoInteractive
    Don't pause between phases. Good for CI / unattended runs.

.EXAMPLE
    # Full flight
    pwsh ./tools/Prove-EndToEnd.ps1

.EXAMPLE
    # Skip predeploy (already done), just run post-deploy
    $env:XDRLR_ONLINE = 'true'
    $env:XDRLR_TEST_RG = 'xdrlr-prod-rg'
    $env:XDRLR_TEST_WORKSPACE = 'myws'
    pwsh ./tools/Prove-EndToEnd.ps1 -Skip 'offline,predeploy'

.NOTES
    Safe to re-run. Idempotent. Always exits with an explicit status summary.
#>
[CmdletBinding()]
param(
    [string] $Skip = '',
    [switch] $NoInteractive
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$skipSet  = @($Skip -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
$results  = [ordered]@{}
$startTime = [datetime]::UtcNow

function Write-Phase {
    param([string] $Name, [string] $Color = 'Cyan')
    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor $Color
    Write-Host "  $Name" -ForegroundColor $Color
    Write-Host ("=" * 78) -ForegroundColor $Color
    Write-Host ""
}

function Invoke-Phase {
    param([string] $Name, [scriptblock] $Action)
    if ($skipSet -contains $Name.ToLowerInvariant()) {
        Write-Host "  [SKIPPED — user requested]" -ForegroundColor DarkGray
        $results[$Name] = 'skipped'
        return
    }
    try {
        & $Action
        $results[$Name] = 'passed'
    } catch {
        $results[$Name] = 'failed'
        Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  Continuing to next phase to get full picture..." -ForegroundColor Yellow
    }
}

# -----------------------------------------------------------------------------
# PHASE 1 — OFFLINE (fast, no network)
# -----------------------------------------------------------------------------
Write-Phase 'PHASE 1 / 4 — OFFLINE TESTS (unit + KQL + ARM + ingest)' 'Green'
Invoke-Phase 'offline' {
    pwsh -NoProfile -File ./tests/Run-Tests.ps1 -Category all-offline
    if ($LASTEXITCODE -ne 0) { throw "offline suite exit code $LASTEXITCODE" }
}

# -----------------------------------------------------------------------------
# PHASE 2 — PRE-DEPLOY (live auth + endpoint audit, laptop against real tenant)
# -----------------------------------------------------------------------------
Write-Phase 'PHASE 2 / 4 — PRE-DEPLOY VALIDATION (live tenant, no Azure)' 'Yellow'
Invoke-Phase 'predeploy' {
    if (-not (Test-Path "$repoRoot/tests/.env.local")) {
        throw @"
tests/.env.local not found. Copy tests/.env.local.example and fill in:
  XDRLR_ONLINE=true
  XDRLR_TEST_UPN=<service account UPN>
  XDRLR_TEST_AUTH_METHOD=CredentialsTotp
  XDRLR_TEST_PASSWORD=<svc account password>
  XDRLR_TEST_TOTP_SECRET=<Base32 seed>
"@
    }
    pwsh -NoProfile -File ./tests/Run-Tests.ps1 -Category local-online
    if ($LASTEXITCODE -ne 0) { throw "local-online suite exit code $LASTEXITCODE" }

    # Also run the endpoint audit for visibility
    Write-Host ""
    Write-Host "Running 52-endpoint portal audit..." -ForegroundColor DarkYellow
    pwsh -NoProfile -File ./tests/integration/Audit-Endpoints-Live.ps1 | Tee-Object -Variable auditOut | Out-Null
    $auditLine = $auditOut | Select-String '^VERDICT:' | Select-Object -First 1
    Write-Host "  $auditLine" -ForegroundColor DarkYellow
}

# -----------------------------------------------------------------------------
# PHASE 3 — DEPLOY (user action)
# -----------------------------------------------------------------------------
Write-Phase 'PHASE 3 / 4 — DEPLOY TO AZURE (manual step)' 'Magenta'

if ($skipSet -notcontains 'deploy' -and -not $NoInteractive) {
    Write-Host "  At this point, please:" -ForegroundColor Magenta
    Write-Host "    1. Click the Deploy-to-Azure button in README.md OR run:" -ForegroundColor Magenta
    Write-Host '       az deployment group create --resource-group <rg> --template-file deploy/compiled/mainTemplate.json' -ForegroundColor White
    Write-Host "    2. Fill in the wizard parameters." -ForegroundColor Magenta
    Write-Host "    3. After deployment succeeds, run:" -ForegroundColor Magenta
    Write-Host '       pwsh ./tools/Initialize-XdrLogRaiderAuth.ps1 -KeyVaultName <kv> -AuthMethod CredentialsTotp' -ForegroundColor White
    Write-Host "    4. Wait at least 15 minutes for the first poll cycle to complete." -ForegroundColor Magenta
    Write-Host ""
    Write-Host "  When ready, export:" -ForegroundColor Yellow
    Write-Host '    $env:XDRLR_TEST_RG = "your-rg-name"'               -ForegroundColor White
    Write-Host '    $env:XDRLR_TEST_WORKSPACE = "your-workspace-name"' -ForegroundColor White
    Write-Host ""
    $done = Read-Host "  Press ENTER when deployment is complete + first poll has fired (or 'skip' to skip Phase 4)"
    if ($done -eq 'skip') { $skipSet += 'postdeploy' }
}

# -----------------------------------------------------------------------------
# PHASE 4 — POST-DEPLOY (KQL-based e2e against deployed workspace)
# -----------------------------------------------------------------------------
Write-Phase 'PHASE 4 / 4 — POST-DEPLOY E2E (deployed workspace, live KQL)' 'Green'
Invoke-Phase 'postdeploy' {
    if (-not $env:XDRLR_TEST_RG -or -not $env:XDRLR_TEST_WORKSPACE) {
        throw 'Set $env:XDRLR_TEST_RG + $env:XDRLR_TEST_WORKSPACE before Phase 4.'
    }
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $ctx) {
        Write-Host "  Connect-AzAccount needed..." -ForegroundColor Yellow
        Connect-AzAccount | Out-Null
    }
    pwsh -NoProfile -File ./tests/Run-Tests.ps1 -Category e2e
    if ($LASTEXITCODE -ne 0) { throw "e2e suite exit code $LASTEXITCODE" }
}

# -----------------------------------------------------------------------------
# SUMMARY
# -----------------------------------------------------------------------------
$elapsed = [datetime]::UtcNow - $startTime
Write-Phase 'SUMMARY' 'White'
foreach ($phase in $results.Keys) {
    $status = $results[$phase]
    $colour = switch ($status) { 'passed' { 'Green' } 'failed' { 'Red' } default { 'DarkGray' } }
    Write-Host ("  {0,-12} : {1}" -f $phase, $status) -ForegroundColor $colour
}
Write-Host ""
Write-Host ("  Elapsed  : {0:mm\:ss}" -f $elapsed)

$failed = @($results.Values | Where-Object { $_ -eq 'failed' })
if ($failed) {
    Write-Host ""
    Write-Host "  RESULT: FAIL ($($failed.Count) phase(s) failed — fix + re-run)" -ForegroundColor Red
    exit 1
} else {
    Write-Host ""
    Write-Host "  RESULT: PASS (every ran phase is green)" -ForegroundColor Green
    exit 0
}
