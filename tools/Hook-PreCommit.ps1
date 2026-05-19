#Requires -Version 7.4
<#
.SYNOPSIS
    Pre-commit gate · S-1 enforcement scaffolding for v0.1.0 P0 v2 RESET plan.

.DESCRIPTION
    Invoked by .git/hooks/pre-commit shim on every git commit. Enforces:
      1. T1 unit tests pass (pwsh tests/Run-Tests.ps1 -Tier 1 -FailFast)
      2. Commit message has AXIS / PRIOR GATES / VERIFY / LOCK sections
      3. Exactly ONE AXIS section (one-axis-per-commit rule G5 enforcement)
      4. If touches auth/portal/manifest/Connect-*: T3-live probe < 24h old
      5. If touches deploy/arm or deploy/sentinel: ARM-TTK passes (when available)

    Helpers extracted to tools/lib/Hook-PreCommit.lib.ps1 for unit testability.

    Install once after clone: pwsh tools/Install-PreCommitHook.ps1

.PARAMETER CommitMsgPath
    Path to staged commit message file. Git pre-commit hook passes .git/COMMIT_EDITMSG.
    If omitted, commit-message gates are skipped (e.g., for ad-hoc CLI invocation).

.PARAMETER SkipT1
    Skip T1 run. Use ONLY during recovery / rebase scenarios. Production commits
    must pass T1 — bypass is a methodology violation per autonomous loop discipline.

.PARAMETER MaxT3AgeHours
    Maximum age in hours for the latest tests/results/iter-*/probe-auth-*.json.
    Default 24h. Auth-touching commits fail if probe is older.

.EXAMPLE
    pwsh tools/Hook-PreCommit.ps1 -CommitMsgPath .git/COMMIT_EDITMSG

.NOTES
    Exit codes:
      0 — all gates green · commit proceeds
      1 — one or more gates failed · commit blocked

    Internal spec: Part VIII (S-1) · pre-commit hook gates spec.
#>

[CmdletBinding()]
param(
    [string]$CommitMsgPath,
    [switch]$SkipT1,
    [int]$MaxT3AgeHours = 24
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Resolve repo root from script location: tools/Hook-PreCommit.ps1 → ..
$repoRoot = Split-Path -Parent $PSScriptRoot

# Dot-source helpers
$libPath = Join-Path $PSScriptRoot 'lib/Hook-PreCommit.lib.ps1'
if (-not (Test-Path $libPath)) {
    Write-Host "Hook-PreCommit: lib not found at '$libPath' — check tools/lib/ structure" -ForegroundColor Red
    exit 1
}
. $libPath

$failures = @()

# --- Gate 1: T1 unit tests pass ---
if (-not $SkipT1) {
    $runTests = Join-Path $repoRoot 'tests/Run-Tests.ps1'
    if (Test-Path $runTests) {
        Write-Host "Hook-PreCommit: running T1 unit tests..." -ForegroundColor Cyan
        & pwsh -NoProfile -File $runTests -Tier 1 -FailFast | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $failures += "Gate 1 (T1): pwsh tests/Run-Tests.ps1 -Tier 1 exited non-zero"
        }
    } else {
        Write-Warning "Hook-PreCommit: T1 driver not found at '$runTests' — skipping T1 gate"
    }
} else {
    Write-Host "Hook-PreCommit: T1 skipped via -SkipT1 (use sparingly!)" -ForegroundColor Yellow
}

# --- Gates 2 & 3: Commit message section sanity ---
if ($CommitMsgPath -and (Test-Path $CommitMsgPath)) {
    $msg = Get-Content -Raw -Path $CommitMsgPath
    $msgIssues = Test-CommitMessageHasRequiredSections -Message $msg
    foreach ($issue in $msgIssues) {
        $failures += "Gate 2/3 (commit message): $issue"
    }
} elseif ($CommitMsgPath) {
    Write-Warning "Hook-PreCommit: commit-msg path '$CommitMsgPath' not found"
}

# --- Discover staged files ---
$stagedFiles = @()
try {
    $stagedFiles = @(& git -C $repoRoot diff --cached --name-only 2>$null)
} catch {
    Write-Warning "Hook-PreCommit: could not enumerate staged files: $($_.Exception.Message)"
}

# --- Gate 4: T3-LIVE freshness + probe-success visibility (auth/portal/manifest touched) ---
#
# Two-tier reporting:
#   Tier A (gate · BLOCKS commit if missing/stale): probe file exists within $MaxT3AgeHours
#   Tier B (visibility · warns but does NOT block): per-portal ChainSuccess content read
#
# Why visibility-only for content:
#   Operator probes are NOT budget-constrained (TOTP handled dynamically by chain · D-33).
#   The hook gates "evidence is current" · the operator decides when to re-probe.
#   Semantic verification (must all 5 portals show ChainSuccess=true) belongs at PHASE
#   EXIT (Write-PhaseState.ps1) where the operator explicitly affirms phase completion.
if (Test-StagedFilesNeedT3 -StagedFiles $stagedFiles) {
    $iterRoot = Join-Path $repoRoot 'tests/results'
    $freshness = Test-T3Freshness -IterRoot $iterRoot -MaxAgeHours $MaxT3AgeHours
    if (-not $freshness.Fresh) {
        $failures += "Gate 4 (T3-LIVE freshness · auth/portal/manifest touched): $($freshness.Reason)"
    } else {
        Write-Host "Hook-PreCommit: T3 evidence fresh at '$($freshness.Path)' ($($freshness.HoursOld)h)" -ForegroundColor Green

        # Visibility: read probe content + surface per-portal ChainSuccess
        $probe = Test-T3ProbeSuccess -IterRoot $iterRoot
        if ($probe.Found -and $probe.ProbeCount -gt 0) {
            if ($probe.AllSuccess) {
                Write-Host "Hook-PreCommit: probe shows $($probe.ProbeCount)/$($probe.ProbeCount) ChainSuccess GREEN across all portals" -ForegroundColor Green
            } else {
                $okCount = ($probe.ProbeCount - $probe.FailuresByPortal.Count)
                Write-Host ""
                Write-Host "Hook-PreCommit (visibility · NOT blocking): probe shows $okCount/$($probe.ProbeCount) ChainSuccess · failures:" -ForegroundColor Yellow
                foreach ($f in $probe.FailuresByPortal) {
                    $portalKey = if ($f.SubPortal) { "$($f.Portal)::$($f.SubPortal)" } else { "$($f.Portal)" }
                    $errPreview = if ($f.Error.Length -gt 120) { $f.Error.Substring(0, 120) + '...' } else { $f.Error }
                    Write-Host "  ⚠ $portalKey · $errPreview" -ForegroundColor Yellow
                }
                Write-Host "  Re-probe with: pwsh tools/Probe-Auth-Local.ps1 -Portal All" -ForegroundColor Yellow
                Write-Host ""
            }
        }
    }
}

# --- Gate 5: ARM-TTK (deploy touched) ---
if (Test-StagedFilesNeedArmTtk -StagedFiles $stagedFiles) {
    $armTtkInvoker = Join-Path $repoRoot 'tools/Run-ArmTtk.ps1'
    if (Test-Path $armTtkInvoker) {
        Write-Host "Hook-PreCommit: running ARM-TTK..." -ForegroundColor Cyan
        & pwsh -NoProfile -File $armTtkInvoker -FailFast | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $failures += "Gate 5 (ARM-TTK · deploy touched): tools/Run-ArmTtk.ps1 exited non-zero"
        }
    } else {
        # ARM-TTK invoker arrives in Phase 0m · gate degrades to warning until then
        Write-Warning "Hook-PreCommit: ARM-TTK invoker not found at '$armTtkInvoker' — gate deferred until Phase 0m"
    }
}

# --- Report ---
if ($failures.Count -gt 0) {
    Write-Host ""
    Write-Host "Hook-PreCommit gate FAILED ($($failures.Count) issue$(if ($failures.Count -ne 1) { 's' })):" -ForegroundColor Red
    foreach ($f in $failures) {
        Write-Host "  ✗ $f" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "Fix the issues above OR (if absolutely necessary) bypass with:" -ForegroundColor Yellow
    Write-Host "  git commit --no-verify   ← METHODOLOGY VIOLATION · operator approval required" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

Write-Host ""
Write-Host "Hook-PreCommit gate GREEN — $($stagedFiles.Count) staged file$(if ($stagedFiles.Count -ne 1) { 's' }) cleared all checks" -ForegroundColor Green
exit 0
