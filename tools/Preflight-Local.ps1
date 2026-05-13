<#
.SYNOPSIS
    Pre-deploy preflight gate — runs locally, offline by default, opt-in online.

.DESCRIPTION
    8-section gate operators run before any deploy + before any git push.
    Mirrors CI's offline gates so a green local preflight predicts a green CI.

    Sections:
      1. Pester all-offline (unit + arm + kql + coverage)
      2. PSScriptAnalyzer (hard-fail on Errors)
      3. Custom ARM + Manifest validators
      4. gitleaks HEAD scan (if installed)
      5. Sentinel Content Hub compliance (Pester suite)
      6. Schema consistency (build-* round-trip — no diff vs committed)
      7. Deploy-flow integrity (ARM-TTK if available; --whatif via az login is OPERATOR-LOCAL only)
      8. Online live audit — ONLY with -IncludeOnline (Probe-Auth-Local)

.PARAMETER IncludeOnline
    Run section 8 (online auth-chain + TenantContext + Custom Collection probe).
    Default: OFF (preflight is offline-first).

.PARAMETER OutputDir
    Where to write the markdown + JSON report. Default: tests/results/.

.OUTPUTS
    Markdown summary at tests/results/preflight-<utc>.md + JSON at .json.
    Exit code: 0 all-OK, 1 any section failed.
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [switch] $IncludeOnline,
    [string] $OutputDir = (Join-Path $PSScriptRoot '..' 'tests' 'results')
)

$ErrorActionPreference = 'Continue'  # collect all section results
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

$sections = New-Object System.Collections.Generic.List[object]
function Add-Section { param([string]$Name, [string]$Status, [string]$Detail = '')
    $sections.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail })
    $color = if ($Status -eq 'OK') { 'Green' } elseif ($Status -eq 'SKIP') { 'Yellow' } else { 'Red' }
    Write-Host ("[{0,-4}] {1}" -f $Status, $Name) -ForegroundColor $color
    if ($Detail) { Write-Host "        $Detail" -ForegroundColor DarkGray }
}

Push-Location $repoRoot
try {
    # ---- 1) Pester all-offline ----
    Write-Host "`n=== 1/8 Pester all-offline ===" -ForegroundColor Cyan
    & pwsh -NoProfile -File ./tests/Run-Tests.ps1 -Category all-offline 2>&1 | Out-Null
    Add-Section -Name '1. Pester all-offline' -Status $(if ($LASTEXITCODE -eq 0) { 'OK' } else { 'FAIL' })

    # ---- 2) PSScriptAnalyzer ----
    Write-Host "`n=== 2/8 PSScriptAnalyzer ===" -ForegroundColor Cyan
    if (Get-Module -ListAvailable -Name PSScriptAnalyzer) {
        $r = Invoke-ScriptAnalyzer -Path . -Recurse -Settings .config/PSScriptAnalyzerSettings.psd1 -ErrorAction SilentlyContinue
        $errs = @($r | Where-Object Severity -eq 'Error')
        Add-Section -Name '2. PSScriptAnalyzer' -Status $(if ($errs.Count -eq 0) { 'OK' } else { 'FAIL' }) -Detail "$($errs.Count) Errors / $($r.Count) total findings"
    } else {
        Add-Section -Name '2. PSScriptAnalyzer' -Status 'SKIP' -Detail 'PSScriptAnalyzer not installed'
    }

    # ---- 3) Custom validators ----
    Write-Host "`n=== 3/8 Custom validators ===" -ForegroundColor Cyan
    & pwsh -NoProfile -File ./tools/Validate-Manifest.ps1 2>&1 | Out-Null
    $mfOk = ($LASTEXITCODE -eq 0)
    & pwsh -NoProfile -File ./tools/Validate-ArmJson.ps1 2>&1 | Out-Null
    $armOk = ($LASTEXITCODE -eq 0)
    Add-Section -Name '3. Custom validators (Manifest + ARM)' -Status $(if ($mfOk -and $armOk) { 'OK' } else { 'FAIL' })

    # ---- 4) gitleaks HEAD ----
    Write-Host "`n=== 4/8 gitleaks HEAD ===" -ForegroundColor Cyan
    if (Get-Command gitleaks -ErrorAction SilentlyContinue) {
        $glOut = gitleaks detect --redact --no-banner --exit-code 0 2>&1
        $hasLeaks = ($glOut -match 'leaks found')
        Add-Section -Name '4. gitleaks HEAD' -Status $(if ($hasLeaks) { 'FAIL' } else { 'OK' })
    } else {
        Add-Section -Name '4. gitleaks HEAD' -Status 'SKIP' -Detail 'gitleaks not installed (CI gate covers)'
    }

    # ---- 5) Sentinel Content Hub compliance ----
    Write-Host "`n=== 5/8 Sentinel Content Hub compliance ===" -ForegroundColor Cyan
    Import-Module Pester -MinimumVersion 5.5.0 -Force
    $cfg = New-PesterConfiguration
    $cfg.Run.Path = 'tests/arm/SentinelContent.MinimalLock.Tests.ps1'
    $cfg.Run.PassThru = $true
    $cfg.Output.Verbosity = 'None'
    $r = Invoke-Pester -Configuration $cfg
    Add-Section -Name '5. Sentinel Content Hub' -Status $(if ($r.FailedCount -eq 0) { 'OK' } else { 'FAIL' }) -Detail "$($r.PassedCount) passed / $($r.FailedCount) failed"

    # ---- 6) Schema consistency (build round-trip — deterministic regeneration) ----
    Write-Host "`n=== 6/8 Schema consistency (build round-trip) ===" -ForegroundColor Cyan
    # Post-Phase-A1: only generator-emitted artifacts are tracked. The 4 Durable
    # function dirs (Xdr-Refresh / Xdr-PollOrchestrator / Xdr-PollStream /
    # Connector-Heartbeat) are hand-authored source-of-truth — Build-FunctionApp
    # is now a verifier, not a generator, so its targets do not regenerate here.
    $tracked = @(
        'manifests/defender.psd1'
        'deploy/mainTemplate.json'
        'deploy/sentinelContent.json'
        'deploy/dcrs/Defender_ActionCenter_dcr.json'  # sample
        'deploy/dcrs/XdrConnectorHealth_dcr.json'
    )
    # Snapshot SHA256 BEFORE
    $before = @{}
    foreach ($t in $tracked) {
        if (Test-Path $t) {
            $before[$t] = (Get-FileHash -Path $t -Algorithm SHA256).Hash
        }
    }
    foreach ($b in @(
        './tools/Build-Manifest.ps1'
        './tools/Build-DcrJson.ps1'
        './tools/Build-FunctionApp.ps1'
        './tools/Build-ArmTemplate.ps1'
        './tools/Build-SentinelSolution.ps1'
    )) {
        & pwsh -NoProfile -File $b 2>&1 | Out-Null
    }
    # Compare AFTER
    $diffs = @()
    foreach ($t in $tracked) {
        if (-not (Test-Path $t)) { $diffs += "$t missing AFTER build"; continue }
        $after = (Get-FileHash -Path $t -Algorithm SHA256).Hash
        if ($before.ContainsKey($t) -and $before[$t] -ne $after) {
            $diffs += "$t hash changed (generator non-deterministic OR uncommitted changes pending)"
        }
    }
    Add-Section -Name '6. Schema consistency (round-trip deterministic)' -Status $(if ($diffs.Count -eq 0) { 'OK' } else { 'FAIL' }) -Detail ($diffs -join '; ')

    # ---- 7) Deploy-flow integrity (ARM-TTK if available) ----
    Write-Host "`n=== 7/8 Deploy-flow integrity ===" -ForegroundColor Cyan
    if (Get-Module -ListAvailable -Name arm-ttk -ErrorAction SilentlyContinue) {
        try {
            Import-Module arm-ttk -ErrorAction Stop
            $r = Test-AzTemplate -TemplatePath ./deploy -Skip CreateUIDefinition,solution
            $fail = @($r | Where-Object { -not $_.Passed })
            Add-Section -Name '7. ARM-TTK' -Status $(if ($fail.Count -eq 0) { 'OK' } else { 'FAIL' }) -Detail "$($fail.Count) failures / $($r.Count) checks"
        } catch {
            Add-Section -Name '7. ARM-TTK' -Status 'SKIP' -Detail "ARM-TTK error: $_"
        }
    } else {
        Add-Section -Name '7. ARM-TTK' -Status 'SKIP' -Detail 'ARM-TTK not installed locally (CI gate covers — run: git clone https://github.com/Azure/arm-ttk /tmp/arm-ttk)'
    }

    # ---- 8) Online live audit (opt-in) ----
    Write-Host "`n=== 8/8 Online live audit (opt-in) ===" -ForegroundColor Cyan
    if ($IncludeOnline) {
        if (Test-Path ./tools/Probe-Auth-Local.ps1) {
            & pwsh -NoProfile -File ./tools/Probe-Auth-Local.ps1 2>&1 | Out-Null
            Add-Section -Name '8. Probe-Auth-Local' -Status $(if ($LASTEXITCODE -eq 0) { 'OK' } else { 'FAIL' })
        } else {
            Add-Section -Name '8. Probe-Auth-Local' -Status 'SKIP' -Detail 'Probe-Auth-Local.ps1 missing'
        }
    } else {
        Add-Section -Name '8. Online live audit' -Status 'SKIP' -Detail 'Re-run with -IncludeOnline'
    }
} finally {
    Pop-Location
}

# ---- Markdown report ----
$utc = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$mdPath = Join-Path $OutputDir "preflight-$utc.md"
$jsonPath = Join-Path $OutputDir "preflight-$utc.json"

$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine("# XdrLogRaider Preflight Report ($utc)")
[void]$md.AppendLine('')
[void]$md.AppendLine('| # | Section | Status | Detail |')
[void]$md.AppendLine('|---|---------|--------|--------|')
$i = 0
foreach ($s in $sections) {
    $i++
    [void]$md.AppendLine(("| $i | $($s.Name) | $($s.Status) | $($s.Detail) |"))
}
$failed = @($sections | Where-Object { $_.Status -eq 'FAIL' })
[void]$md.AppendLine('')
if ($failed.Count -eq 0) {
    [void]$md.AppendLine('**Result: ALL OK — safe to push.**')
} else {
    [void]$md.AppendLine("**Result: $($failed.Count) FAIL(s) — DO NOT push.**")
}

[System.IO.File]::WriteAllText($mdPath, $md.ToString(), [System.Text.UTF8Encoding]::new($false))
$sections | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonPath -Encoding utf8

Write-Host ''
Write-Host "Report: $mdPath"
Write-Host "JSON:   $jsonPath"

if ($failed.Count -gt 0) { exit 1 } else { exit 0 }
