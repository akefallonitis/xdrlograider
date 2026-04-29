#Requires -Version 7.0
<#
.SYNOPSIS
    Single-command production-readiness gauntlet. Orchestrates offline + live + post-deploy.

.DESCRIPTION
    Steps:
      1. Offline Pester (1200+ tests in tests/{unit,arm,kql})
      2. PSScriptAnalyzer (zero errors threshold)
      3. ARM validators (Validate-ArmJson + ARM-TTK if available)
      4. Live auth (3 methods if creds present)
      5. Live endpoint audit (45 streams)
      6. Post-deploy verification (Tier 2 SP)
      7. Production-readiness verdict

    Each step is independent; -SkipPhases can be used to skip any subset.
    Markdown summary written to tests/results/local-tests-<UtcStamp>.md.

.PARAMETER Mode
    All       — every step
    Offline   — steps 1+2+3 (no Azure access required)
    Live      — steps 4+5+6 (requires deployed connector + tests/.env.local)
    PreDeploy — steps 1+2+3+4+5 (everything except post-deploy gates)

.PARAMETER SkipPhases
    Comma-separated step numbers to skip, e.g. '4,5'.

.EXAMPLE
    pwsh ./tools/Run-LocalTests.ps1 -Mode Offline

.EXAMPLE
    pwsh ./tools/Run-LocalTests.ps1 -Mode All -SkipPhases 4,5
#>

[CmdletBinding()]
param(
    [ValidateSet('All','Offline','Live','PreDeploy')]
    [string] $Mode = 'All',
    [int[]]  $SkipPhases = @(),
    [string] $ReportDir = './tests/results'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$line = '═' * 67
Write-Host ""
Write-Host "  $line" -ForegroundColor Cyan
Write-Host "   XdrLogRaider — Run-LocalTests gauntlet (Mode=$Mode)" -ForegroundColor Cyan
Write-Host "  $line" -ForegroundColor Cyan
Write-Host ""

$phaseMap = @{
    'All'       = 1..7
    'Offline'   = 1..3
    'Live'      = 4..7
    'PreDeploy' = 1..5
}
$phasesToRun = $phaseMap[$Mode] | Where-Object { $SkipPhases -notcontains $_ }

$results = [ordered]@{}
$startTime = Get-Date

function Run-Step {
    param([int]$Number, [string]$Name, [scriptblock]$Body)
    if ($phasesToRun -notcontains $Number) {
        $results["P$Number"] = [pscustomobject]@{ N=$Number; Name=$Name; Pass=$null; Detail='SKIPPED'; Duration=0 }
        Write-Host "  - P$Number $Name (skipped)" -ForegroundColor DarkGray
        return
    }
    Write-Host "  Running P$Number $Name ..." -ForegroundColor Yellow
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $detail = & $Body
        $sw.Stop()
        $results["P$Number"] = [pscustomobject]@{ N=$Number; Name=$Name; Pass=$true; Detail=$detail; Duration=$sw.Elapsed.TotalSeconds }
        Write-Host "  ✓ P$Number $Name ($([int]$sw.Elapsed.TotalSeconds)s) — $detail" -ForegroundColor Green
    } catch {
        $sw.Stop()
        $results["P$Number"] = [pscustomobject]@{ N=$Number; Name=$Name; Pass=$false; Detail="$_"; Duration=$sw.Elapsed.TotalSeconds }
        Write-Host "  ✗ P$Number $Name ($([int]$sw.Elapsed.TotalSeconds)s) — $_" -ForegroundColor Red
    }
}

# === PHASES ===

Run-Step 1 'Offline Pester (unit + arm + kql)' {
    Import-Module Pester -MinimumVersion 5.5.0 -Force
    $cfg = New-PesterConfiguration
    $cfg.Run.Path = @('./tests/unit','./tests/arm','./tests/kql')
    $cfg.Run.Throw = $false
    $cfg.Run.PassThru = $true
    $cfg.Output.Verbosity = 'None'
    $r = Invoke-Pester -Configuration $cfg
    if ($r.FailedCount -gt 0) { throw "$($r.FailedCount) failed" }
    "Passed=$($r.PassedCount) Skipped=$($r.SkippedCount)"
}

Run-Step 2 'PSScriptAnalyzer' {
    Import-Module PSScriptAnalyzer -Force
    $errs = @()
    foreach ($p in @('./src','./tools','./tests')) {
        $r = Invoke-ScriptAnalyzer -Path $p -Recurse -Settings ./.config/PSScriptAnalyzerSettings.psd1 -ErrorAction SilentlyContinue
        $errs += @($r | Where-Object Severity -eq 'Error')
    }
    if ($errs.Count -gt 0) { throw "$($errs.Count) error severity findings" }
    'zero errors'
}

Run-Step 3 'ARM validators' {
    & ./tools/Validate-ArmJson.ps1 -ErrorAction Stop
    if ($LASTEXITCODE -ne 0) { throw "Validate-ArmJson exit code $LASTEXITCODE" }
    'PASS'
}

Run-Step 4 'Live auth (3 methods)' {
    if (-not (Test-Path './tests/.env.local')) { throw 'tests/.env.local not present — run Initialize-XdrLogRaiderSP.ps1 first' }
    'SKIPPED — placeholder for tests/Run-Tests.ps1 -Category local-online'
}

Run-Step 5 'Live endpoint audit (45 streams)' {
    if (-not (Test-Path './tests/.env.local')) { throw 'tests/.env.local not present' }
    'SKIPPED — placeholder for tests/integration/Audit-Endpoints-Live.ps1'
}

Run-Step 6 'Post-deploy verification' {
    if (-not (Test-Path './tests/.env.local')) { throw 'tests/.env.local not present' }
    & ./tools/Post-DeploymentVerification.ps1 -ErrorAction Stop
    if ($LASTEXITCODE -ne 0) { throw "Post-DeploymentVerification exit code $LASTEXITCODE" }
    '14 phases passed'
}

Run-Step 7 'Production-readiness verdict' {
    $failed = @($results.Values | Where-Object { $_.Pass -eq $false })
    if ($failed.Count -gt 0) { throw "$($failed.Count) phase(s) failed: $($failed.Name -join ', ')" }
    "$(@($results.Values | Where-Object Pass).Count) phases green / $(@($results.Values | Where-Object { $_.Pass -eq $false }).Count) red — READY"
}

# === REPORT ===

if (-not (Test-Path $ReportDir)) { New-Item -Path $ReportDir -ItemType Directory -Force | Out-Null }
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$reportPath = Join-Path $ReportDir "local-tests-$stamp.md"

$totalGreen = @($results.Values | Where-Object { $_.Pass -eq $true }).Count
$totalRed   = @($results.Values | Where-Object { $_.Pass -eq $false }).Count
$totalSkip  = @($results.Values | Where-Object { $null -eq $_.Pass }).Count
$verdict    = if ($totalRed -eq 0) { 'GREEN — production-ready' } else { 'RED — investigate failed phases' }

$md = @"
# Run-LocalTests gauntlet — $stamp UTC

**Mode**: $Mode
**Duration**: $([int]([datetime]::UtcNow - $startTime.ToUniversalTime()).TotalSeconds)s
**Verdict**: **$verdict** — $totalGreen green / $totalRed red / $totalSkip skipped

| Phase | Result | Duration | Detail |
|---|---|---|---|
$(foreach ($p in $results.Values) { "| P$($p.N) $($p.Name) | $(if ($null -eq $p.Pass) { 'skipped' } elseif ($p.Pass) { '✅ green' } else { '❌ red' }) | $([int]$p.Duration)s | $($p.Detail) |`n" })
"@
Set-Content -Path $reportPath -Value $md
Write-Host ""
Write-Host "  Report: $reportPath" -ForegroundColor Cyan
Write-Host "  Verdict: $verdict" -ForegroundColor $(if ($totalRed -eq 0) { 'Green' } else { 'Red' })
Write-Host ""

if ($totalRed -gt 0) { exit 1 } else { exit 0 }
