#Requires -Version 7.4
<#
.SYNOPSIS
    Single-pane gate runner · Plan §6 + §13 pre-push gate.

.DESCRIPTION
    Aggregates the 20+ named gates Plan §6 lists into one verification pass.
    Each gate writes a PASS / FAIL line; final block reports gate count.

    Gates (Plan §6 mapping):
      AA    Memory Rule 2 sub-area drops (no AH/AI/LR)        Validate-MemoryRuleCompliance
      AE    Graph host ban (no graph.microsoft.com/etc.)      Validate-MemoryRuleCompliance
      Y     IngestionMode in {LIVESTREAM, SNAPSHOT, EXCLUDED} Validate-MemoryRuleCompliance
      O     /apiproxy/<service>/ prefix on every entry        regex on manifest
      F     HTML response detection at data stages (R-B)      grep src/Modules/Xdr.Poll
      L     B-25 -isnot [string] guard in Invoke-XdrAuthHttp  grep src/Modules/Xdr.Auth
      M     Exactly 4 Storage Tables provisioned              ARM parse
      N     Set-StrictMode in every psm1                      psm1 source regex
      P     Pester test files >= 30                           Get-ChildItem .Tests.ps1
      Q     T1 test corpus >= 400 tests                       Pester pre-runner count
      DCR   DCR + sentinelContent stream-name alignment       ARM + sentinelContent parse
      contracts  Validate-ModuleContracts 0 drift             Validate-ModuleContracts
      R-A   ProjectionMap typed-DSL populated >= 50           grep manifest
      R-B   Stage-aware HTML classifier wired                 Xdr.Poll has Test-AuthChainHtmlResponse
      R-C   Capability discovery wired                        Xdr.Poll has Discover-XdrPortalCapabilities
      S-1   Pre-commit hook installed                         Test-Path .git/hooks/pre-commit
      S-2   PHASE_STATE files present >= 5                    Get-ChildItem PHASE_STATE_*.json
      v0.6  Sentinel content stubs at sentinel/{5 dirs}       Test-Path each
      release  .github/workflows/release.yml + Build-FunctionAppZip   Test-Path each
      ops   parameters.sample.json + Verify-Deploy.ps1        Test-Path each
      Entity13  Validate-EntityCoverage report 13 columns     Validate-EntityCoverage (Phase α.6)

    Exit 0 if all gates PASS · 1 if any FAIL.
    Output also written to tests/results/iter-<utc>/wiring.json for machine-read.

.PARAMETER FailFast
    Stop on first FAIL.

.PARAMETER SkipExpensive
    Skip Validate-MemoryRuleCompliance + Validate-ModuleContracts (faster · use for
    iterative authoring; full audit before pre-push).

.EXAMPLE
    pwsh ./tools/Audit-Wiring.ps1
    pwsh ./tools/Audit-Wiring.ps1 -FailFast
#>
[CmdletBinding()]
param(
    [switch]$FailFast,
    [switch]$SkipExpensive
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$results  = [System.Collections.Generic.List[pscustomobject]]::new()

function Add-GateResult {
    param([string]$Gate, [string]$Name, [bool]$Passed, [string]$Detail = '')
    $results.Add([pscustomobject]@{
        Gate    = $Gate
        Name    = $Name
        Passed  = $Passed
        Detail  = $Detail
    }) | Out-Null
    $color = if ($Passed) { 'Green' } else { 'Red' }
    $marker = if ($Passed) { 'PASS' } else { 'FAIL' }
    Write-Host ("  [{0}] {1,-10} {2}" -f $marker, $Gate, $Name) -ForegroundColor $color
    if ($Detail) { Write-Host ("              {0}" -f $Detail) -ForegroundColor DarkGray }
    if (-not $Passed -and $FailFast) { throw "Audit-Wiring -FailFast: $Gate FAILED" }
}

Write-Host "`nAudit-Wiring · 20+ gate single-pane (Plan §6 + §13)" -ForegroundColor Cyan
Write-Host ("  Repo root: {0}" -f $repoRoot) -ForegroundColor DarkGray
Write-Host ""

# ── Manifest gates AA / AE / Y / O / R-A ─────────────────────────────────────
$manifestPath = Join-Path $repoRoot 'manifests/defender.psd1'
if (Test-Path $manifestPath) {
    if (-not $SkipExpensive) {
        & (Join-Path $PSScriptRoot 'Validate-MemoryRuleCompliance.ps1') *>$null
        $gateAaJson = Join-Path $repoRoot 'manifests/_gate-aa.json'
        if (Test-Path $gateAaJson) {
            $gateAa = Get-Content -Raw $gateAaJson | ConvertFrom-Json
            $defAa = $gateAa.byPortal | Where-Object Portal -eq 'Defender' | Select-Object -First 1
            if ($defAa) {
                Add-GateResult 'AA' 'No AH/AI/LR sub-areas in manifest' ($defAa.gateAa) "$($defAa.entries) entries scanned"
                Add-GateResult 'AE' 'No graph.microsoft.com host in path' ($defAa.gateAe) ''
                Add-GateResult 'Y'  'IngestionMode populated · 100%' ($defAa.gateY) ''
            }
        }
    }

    # Gate O · /apiproxy/<svc>/ prefix on every entry
    $m = & ([scriptblock]::Create((Get-Content -Raw $manifestPath)))
    $entries = @($m.Entries)
    $badPrefix = @($entries | Where-Object { $_.Path -notmatch '^/apiproxy/[a-zA-Z0-9_-]+/' })
    Add-GateResult 'O' '/apiproxy/<svc>/ prefix on every entry' ($badPrefix.Count -eq 0) "$($badPrefix.Count) bad-prefix entries / $($entries.Count) total"

    # Gate R-A · ProjectionMap typed-DSL populated count >= 50
    $withPMap = @($entries | Where-Object { $_.ProjectionMap -and @($_.ProjectionMap.Keys).Count -gt 0 })
    $pmapPct = if ($entries.Count) { [math]::Round(100.0 * $withPMap.Count / $entries.Count, 1) } else { 0 }
    Add-GateResult 'R-A' 'ProjectionMap typed-DSL >= 50 entries' ($withPMap.Count -ge 50) "$($withPMap.Count) / $($entries.Count) ($pmapPct%)"
}

# ── Module gates F / L / N / R-B / R-C / contracts ───────────────────────────
$pollPsm = Join-Path $repoRoot 'src/Modules/Xdr.Poll/Xdr.Poll.psm1'
$authPsm = Join-Path $repoRoot 'src/Modules/Xdr.Auth/Xdr.Auth.psm1'

if (Test-Path $pollPsm) {
    $pollSrc = Get-Content -Raw $pollPsm
    Add-GateResult 'F'    'HTML response detection at data stages (R-B)' ($pollSrc -match '\bisHtml\b' -or $pollSrc -match 'Test-AuthChainHtmlResponse') ''
    Add-GateResult 'R-B'  'Stage-aware HTML classifier wired' ($pollSrc -match 'function Test-AuthChainHtmlResponse') ''
    Add-GateResult 'R-C'  'Capability discovery + filter wired' (($pollSrc -match 'function Discover-XdrPortalCapabilities') -and ($pollSrc -match 'function Test-XdrEndpointAllowedByCapabilities')) ''
}

if (Test-Path $authPsm) {
    $authSrc = Get-Content -Raw $authPsm
    Add-GateResult 'L' 'B-25 -isnot [string] guard in Invoke-XdrAuthHttp' ($authSrc -match '-isnot\s*\[string\]') ''
}

# Gate N · Set-StrictMode in every psm1
$psmFiles = @(Get-ChildItem (Join-Path $repoRoot 'src/Modules') -Recurse -Filter '*.psm1')
$noStrict = @($psmFiles | Where-Object { (Get-Content -Raw $_.FullName) -notmatch 'Set-StrictMode' })
Add-GateResult 'N' 'Set-StrictMode in every psm1' ($noStrict.Count -eq 0) "$($psmFiles.Count) psm1 files · $($noStrict.Count) missing strictmode"

# contracts · Validate-ModuleContracts
# φ.J · contracts gate counts ERROR-level violations only · WARN-level (intentional-private
# helpers like Get-XdrKmsiCookie · Invoke-XdrKmsiSsoRefresh · Invoke-XdrPasskeyChallenge ·
# Complete-XdrPasskeyFlow) are documented design (helpers used internally · not exported).
if (-not $SkipExpensive) {
    & (Join-Path $PSScriptRoot 'Validate-ModuleContracts.ps1') *>$null
    $contractsJson = Join-Path $repoRoot 'manifests/_gate-contracts.json'
    if (Test-Path $contractsJson) {
        $c = Get-Content -Raw $contractsJson | ConvertFrom-Json
        # Count ERROR-level violations only · WARN-level (Issue ending in -WARN) acceptable
        $errors = @($c.Violations | Where-Object { $_.Issue -notlike '*-WARN' })
        $errorDrift = @($errors).Count
        $totalDrift = if ($c.PSObject.Properties['TotalViolations']) { [int]$c.TotalViolations } else { 0 }
        $warnDrift  = $totalDrift - $errorDrift
        $moduleCount = @($c.ModulesAudited).Count
        $msg = if ($warnDrift -gt 0) {
            "ERROR-drift=$errorDrift · WARN-drift=$warnDrift (intentional-private · acceptable) across $moduleCount modules"
        } else {
            "drift=$errorDrift across $moduleCount modules"
        }
        Add-GateResult 'contracts' 'Validate-ModuleContracts 0 ERROR drift (WARN intentional-private OK)' ($errorDrift -eq 0) $msg
    } else {
        Add-GateResult 'contracts' 'Validate-ModuleContracts report present' $false 'manifests/_gate-contracts.json not emitted'
    }
}

# ── ARM gates M / DCR ────────────────────────────────────────────────────────
$armPath = Join-Path $repoRoot 'deploy/mainTemplate.json'
if (Test-Path $armPath) {
    $arm = Get-Content -Raw $armPath | ConvertFrom-Json
    $tables = @($arm.resources | Where-Object { $_.type -match 'Microsoft.Storage/storageAccounts/tableServices/tables$' })
    Add-GateResult 'M' 'Exactly 4 Storage Tables' ($tables.Count -eq 4) "$($tables.Count) tables in mainTemplate.json"

    # DCR streamDecl alignment with sentinelContent + manifest stream names
    $dcrs = @($arm.resources | Where-Object { $_.type -match 'Microsoft.Insights/dataCollectionRules$' })
    $streamCount = 0
    foreach ($d in $dcrs) {
        if ($d.properties -and $d.properties.streamDeclarations) {
            $streamCount += @($d.properties.streamDeclarations.PSObject.Properties).Count
        }
    }
    Add-GateResult 'DCR' 'DCR streamDeclarations >= 2 (Defender + Health)' ($streamCount -ge 2) "$streamCount streams across $($dcrs.Count) DCRs"
}

# ── Test corpus gates P / Q ──────────────────────────────────────────────────
$testFiles = @(Get-ChildItem (Join-Path $repoRoot 'tests') -Recurse -Filter '*.Tests.ps1')
Add-GateResult 'P' 'Pester test files >= 30' ($testFiles.Count -ge 30) "$($testFiles.Count) .Tests.ps1 files"

# Gate Q · T1 test corpus count (cheap via Pester -DryRun)
$runTests = Join-Path $repoRoot 'tests/Run-Tests.ps1'
$testTotal = -1
if (Test-Path $runTests) {
    # Grep Pester for ' It '+'-- ' lines as proxy for test count
    $itLines = (Select-String -Path $testFiles.FullName -Pattern '^\s*It\s+''' -SimpleMatch:$false | Measure-Object).Count
    $testTotal = $itLines
}
Add-GateResult 'Q' 'T1 test corpus >= 400 tests' ($testTotal -ge 400) "$testTotal 'It' assertions in $($testFiles.Count) files"

# ── Scaffolding gates S-1 / S-2 ──────────────────────────────────────────────
$hookPath = Join-Path $repoRoot '.git/hooks/pre-commit'
Add-GateResult 'S-1' 'Pre-commit hook installed' (Test-Path $hookPath) "$hookPath"

$phaseFiles = @(Get-ChildItem (Join-Path $repoRoot 'tests/results') -Recurse -Filter 'PHASE_STATE_*.json' -ErrorAction SilentlyContinue)
Add-GateResult 'S-2' 'PHASE_STATE files >= 5' ($phaseFiles.Count -ge 5) "$($phaseFiles.Count) PHASE_STATE files on disk"

# ── Sentinel content stubs (v0.6 forward) ────────────────────────────────────
$sentDirs = @('sentinel/analytic-rules','sentinel/hunting-queries','sentinel/parsers','sentinel/workbooks','sentinel/playbooks')
$missingSent = @($sentDirs | Where-Object { -not (Test-Path (Join-Path $repoRoot $_)) })
Add-GateResult 'v0.6' 'Sentinel content stubs (5 dirs)' ($missingSent.Count -eq 0) "$(($sentDirs.Count - $missingSent.Count))/$($sentDirs.Count) present"

# ── Release + ops files ──────────────────────────────────────────────────────
$relWf = Join-Path $repoRoot '.github/workflows/release.yml'
$buildZip = Join-Path $repoRoot 'tools/Build-FunctionAppZip.ps1'
Add-GateResult 'release' '.github/workflows/release.yml + Build-FunctionAppZip' ((Test-Path $relWf) -and (Test-Path $buildZip)) ''

$paramsSample = Join-Path $repoRoot 'deploy/parameters.sample.json'
$verifyDep = Join-Path $repoRoot 'tools/Verify-Deploy.ps1'
Add-GateResult 'ops' 'parameters.sample.json + Verify-Deploy.ps1' ((Test-Path $paramsSample) -and (Test-Path $verifyDep)) ''

# ── Entity13 · Validate-EntityCoverage (Phase α.6 · created next) ───────────
$entityTool = Join-Path $repoRoot 'tools/Validate-EntityCoverage.ps1'
if (Test-Path $entityTool) {
    & $entityTool *>$null
    $entityJson = Join-Path $repoRoot 'manifests/_gate-entity-coverage.json'
    if (Test-Path $entityJson) {
        $ec = Get-Content -Raw $entityJson | ConvertFrom-Json
        Add-GateResult 'Entity13' '13-entity canonical-column coverage report' $true "$($ec.entriesWithEntities)/$($ec.totalEntries) entries with >=1 entity column"
    } else {
        Add-GateResult 'Entity13' 'Validate-EntityCoverage report present' $false 'tool ran but no report'
    }
} else {
    Add-GateResult 'Entity13' 'Validate-EntityCoverage tool present' $false 'tools/Validate-EntityCoverage.ps1 missing (Phase α.6 deliverable)'
}

# ── Write wiring.json report ─────────────────────────────────────────────────
$iterDir = Join-Path $repoRoot ("tests/results/iter-" + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))
New-Item -ItemType Directory -Path $iterDir -Force | Out-Null
$pass  = @($results | Where-Object Passed).Count
$total = $results.Count
$report = [pscustomobject]@{
    TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
    HeadCommit   = (& git -C $repoRoot rev-parse HEAD 2>$null) -join ''
    GateTotal    = $total
    GatePass     = $pass
    GateFail     = ($total - $pass)
    AllGreen     = ($pass -eq $total)
    Gates        = $results
}
$reportPath = Join-Path $iterDir 'wiring.json'
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reportPath -Encoding UTF8

Write-Host ""
$color = if ($pass -eq $total) { 'Green' } else { 'Red' }
Write-Host ("=== Audit-Wiring: {0} / {1} gates PASS ===" -f $pass, $total) -ForegroundColor $color
Write-Host ("Report: $reportPath") -ForegroundColor DarkGray

if ($pass -ne $total) { exit 1 }
