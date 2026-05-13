<#
.SYNOPSIS
    Runs the offline portion of Step 11 end-to-end verification chain.

.DESCRIPTION
    Per plan §11, the chain is 11a-11n. This script runs 11a-11i (the offline
    half: build chain + validators + Pester + Preflight-Local). The remaining
    chain (11k Probe-Auth-Local · 11l az deployment what-if · 11m Verify-Deploy)
    requires az login + a test resource group; operators run those manually.

    Exit 0 = ALL OFFLINE STEPS PASS — safe to proceed to online steps.
    Exit 1 = any offline step failed — DO NOT push, DO NOT deploy.

.PARAMETER OutputDir
    Where to write the chain summary. Default: tests/results/.
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [string] $OutputDir = (Join-Path $PSScriptRoot '..' 'tests' 'results')
)

$ErrorActionPreference = 'Continue'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
Push-Location $repoRoot

$results = New-Object System.Collections.Generic.List[object]
function Add-Step {
    param([string] $Id, [string] $Cmd, [scriptblock] $Action)
    Write-Host ''
    Write-Host ("=== {0} -- {1} ===" -f $Id, $Cmd) -ForegroundColor Cyan
    $ok = $true; $msg = ''
    $global:LASTEXITCODE = 0
    try {
        & $Action
        if ($global:LASTEXITCODE -and $global:LASTEXITCODE -ne 0) {
            $ok = $false; $msg = "exit=$global:LASTEXITCODE"
        }
    } catch {
        $ok = $false; $msg = $_.Exception.Message
    }
    $results.Add([pscustomobject]@{ Id = $Id; Cmd = $Cmd; OK = $ok; Msg = $msg })
    $color = if ($ok) { 'Green' } else { 'Red' }
    $status = if ($ok) { 'OK' } else { 'FAIL' }
    Write-Host ("  [{0}] {1}" -f $status, $Id) -ForegroundColor $color
    if ($msg) { Write-Host "        $msg" -ForegroundColor DarkGray }
}

try {
    Add-Step '11a' 'Build-Manifest.ps1'        { pwsh -NoProfile -File ./tools/Build-Manifest.ps1 2>&1 | Out-Null }
    Add-Step '11b' 'Build-DcrJson.ps1'         { pwsh -NoProfile -File ./tools/Build-DcrJson.ps1 2>&1 | Out-Null }
    Add-Step '11c' 'Build-FunctionApp.ps1'     { pwsh -NoProfile -File ./tools/Build-FunctionApp.ps1 2>&1 | Out-Null }
    Add-Step '11d' 'Build-SentinelSolution.ps1' { pwsh -NoProfile -File ./tools/Build-SentinelSolution.ps1 2>&1 | Out-Null }
    Add-Step '11e' 'Build-ArmTemplate.ps1'     { pwsh -NoProfile -File ./tools/Build-ArmTemplate.ps1 2>&1 | Out-Null }
    Add-Step '11f' 'Validate-Manifest.ps1'     { pwsh -NoProfile -File ./tools/Validate-Manifest.ps1 2>&1 | Out-Null }
    Add-Step '11g' 'Validate-ArmJson.ps1'      { pwsh -NoProfile -File ./tools/Validate-ArmJson.ps1 2>&1 | Out-Null }
    Add-Step '11h' 'Run-Tests.ps1 all-offline' { pwsh -NoProfile -File ./tests/Run-Tests.ps1 -Category all-offline 2>&1 | Select-Object -Last 8 | Out-Host }
    Add-Step '11i' 'Preflight-Local.ps1'       { pwsh -NoProfile -File ./tools/Preflight-Local.ps1 2>&1 | Select-Object -Last 14 | Out-Host }

    Write-Host ''
    Write-Host '==========================================' -ForegroundColor Cyan
    Write-Host 'STEP 11 OFFLINE CHAIN — SUMMARY' -ForegroundColor Cyan
    Write-Host '==========================================' -ForegroundColor Cyan
    $results | Format-Table -AutoSize Id, Cmd, OK, Msg

    $failures = @($results | Where-Object { -not $_.OK })

    # Emit summary markdown
    $utc = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $md = New-Object System.Text.StringBuilder
    [void]$md.AppendLine("# Step 11 Offline Chain Verification ($utc)")
    [void]$md.AppendLine('')
    [void]$md.AppendLine('| Step | Command | Status | Detail |')
    [void]$md.AppendLine('|------|---------|--------|--------|')
    foreach ($r in $results) {
        $status = if ($r.OK) { 'OK' } else { 'FAIL' }
        [void]$md.AppendLine("| $($r.Id) | $($r.Cmd) | $status | $($r.Msg) |")
    }
    [void]$md.AppendLine('')
    if ($failures.Count -eq 0) {
        [void]$md.AppendLine('**Result: ALL OFFLINE STEPS PASS.** Proceed to online steps (11k, 11l, 11m) with operator credentials. DO NOT push until those pass too.')
    } else {
        [void]$md.AppendLine("**Result: $($failures.Count) FAILURE(s) — DO NOT push, DO NOT deploy.**")
    }
    $mdPath = Join-Path $OutputDir "step11-offline-$utc.md"
    [System.IO.File]::WriteAllText($mdPath, $md.ToString(), [System.Text.UTF8Encoding]::new($false))
    Write-Host ''
    Write-Host "Report: $mdPath"

    if ($failures.Count -eq 0) {
        Write-Host ''
        Write-Host 'ALL 11a-11i PASS. Online steps (11k Probe-Auth-Local · 11l az what-if · 11m Verify-Deploy) require operator credentials.' -ForegroundColor Green
        exit 0
    } else {
        exit 1
    }
} finally {
    Pop-Location
}
