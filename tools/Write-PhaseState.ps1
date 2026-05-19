#Requires -Version 7.4
<#
.SYNOPSIS
    Writes PHASE_STATE_<phase>.json checkpoint at phase exit · S-2 of v0.1.0 P0 v2 RESET.

.DESCRIPTION
    Called at the LOCK step of the final commit of a phase. Writes a JSON
    artefact to tests/results/iter-<utc>/PHASE_STATE_<phase>.json so the next
    session can resume from disk via tools/Read-LatestPhaseState.ps1.

    Captures:
      phase                  — phase identifier
      exit_at                — UTC timestamp
      gates_ticked           — array of gate IDs from plan exit criteria
      live_proof_artefact    — path to live evidence (e.g., probe-auth-multi.json) or $null
      t1_green               — bool · T1 status at checkpoint write (skip via -NoT1Check)
      t2_validated           — bool · optional · set $true if ARM/deploy validated
      t3_live_evidence       — path to T3-live artefact or $null
      head_commit            — git rev-parse HEAD at checkpoint
      head_message_axis      — extracted AXIS: line from HEAD commit body
      prior_phase            — phase that just closed
      next_phase             — phase entered next
      sibling_repo_refs_cited — array of "<repo>/<file>:<line>" prior-art citations

.PARAMETER Phase
    Phase identifier (e.g., '0a' · '0d' · 'G').

.PARAMETER GatesTicked
    Array of gate identifiers ticked at phase exit (format: '<phase>.<area>.<gate>').

.PARAMETER LiveProofArtefact
    Path to live-proof artefact at phase exit ($null if no live evidence).

.PARAMETER T2Validated
    Set to $true if T2 az deployment validate succeeded for this phase.

.PARAMETER T3LiveEvidence
    Path to T3-live evidence (probe-auth-*.json or similar).

.PARAMETER NextPhase
    Identifier of the next phase to enter.

.PARAMETER SiblingRepoRefsCited
    Optional array of "<repo>/<file>:<line>" references cited in phase commits.

.PARAMETER IterDir
    Optional override for iter dir path. Default: tests/results/iter-<utc>/.

.PARAMETER NoT1Check
    Skip the T1 re-run (use for retroactive checkpoint write or bulk operations).

.PARAMETER ExtraData
    Optional hashtable merged into the JSON payload for phase-specific data.

.EXAMPLE
    pwsh tools/Write-PhaseState.ps1 -Phase 0a `
        -GatesTicked @('0a.cleanup.b25-rule-kept', '0a.repo.readme-only-md') `
        -NextPhase 0b -NoT1Check

.NOTES
    Internal spec: Part VIII (S-2) phase-state writer.
    Schema spec: Part III §3.11 continuity model.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Phase,
    [string[]]$GatesTicked = @(),
    [hashtable]$GateEvidence = @{},                                # NEW · A-3b audit · disk-verifiable evidence per gate
    [switch]$StrictVerify,                                          # NEW · fail if any GatesTicked entry lacks GateEvidence
    [string]$LiveProofArtefact,
    [bool]$T2Validated,
    [string]$T3LiveEvidence,
    [string]$NextPhase,
    [string[]]$SiblingRepoRefsCited = @(),
    [string]$IterDir,
    [switch]$NoT1Check,
    [hashtable]$ExtraData = @{}
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot

# ─── Disk-verifiable gate evidence (StrictVerify mode) ─────────────────────
# Evidence-spec types accepted in $GateEvidence values:
#   commit:<sha-or-prefix>            git cat-file -e <sha>
#   file:<repo-relative-path>         Test-Path $repoRoot/<path>
#   test:<test-file>::<assertion>     Test-Path test file + grep assertion text
#   text:<note>                       operator-asserted (last resort · logged WARN)
#
# When -StrictVerify: every GatesTicked entry MUST have a matching GateEvidence
# key. Writer refuses to emit PHASE_STATE if any evidence fails to resolve.
function Resolve-GateEvidence {
    [CmdletBinding()][OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Spec, [Parameter(Mandatory)][string]$RepoRoot)

    if ($Spec -match '^commit:(.+)$') {
        $sha = $Matches[1]
        & git -C $RepoRoot cat-file -e $sha 2>$null
        if ($LASTEXITCODE -eq 0) {
            return @{ Verified = $true; Type = 'commit'; Target = $sha }
        }
        return @{ Verified = $false; Type = 'commit'; Target = $sha; Reason = "commit $sha not in git history" }
    }
    if ($Spec -match '^file:(.+)$') {
        $path = $Matches[1]
        $abs  = Join-Path $RepoRoot $path
        if (Test-Path $abs) {
            return @{ Verified = $true; Type = 'file'; Target = $path }
        }
        return @{ Verified = $false; Type = 'file'; Target = $path; Reason = "file '$path' not on disk" }
    }
    if ($Spec -match '^test:([^:]+)::(.+)$') {
        $testFile  = $Matches[1]
        $assertion = $Matches[2]
        $abs = Join-Path $RepoRoot $testFile
        if (-not (Test-Path $abs)) {
            return @{ Verified = $false; Type = 'test'; Target = "$testFile::$assertion"; Reason = "test file '$testFile' not on disk" }
        }
        $content = Get-Content -Raw $abs
        if ($content -match [regex]::Escape($assertion)) {
            return @{ Verified = $true; Type = 'test'; Target = "$testFile::$assertion" }
        }
        return @{ Verified = $false; Type = 'test'; Target = "$testFile::$assertion"; Reason = "assertion '$assertion' not found in '$testFile'" }
    }
    if ($Spec -match '^text:(.+)$') {
        return @{ Verified = $true; Type = 'text'; Target = $Matches[1]; SoftClaim = $true }
    }
    return @{ Verified = $false; Type = 'unknown'; Target = $Spec; Reason = "evidence spec must start with commit:/file:/test:/text:" }
}

if ($StrictVerify) {
    $verifyFailures = @()
    $verifySoftClaims = @()
    foreach ($g in $GatesTicked) {
        if (-not $GateEvidence.ContainsKey($g)) {
            $verifyFailures += "  ✗ gate '$g' · no evidence in -GateEvidence hashtable"
            continue
        }
        $spec = [string]$GateEvidence[$g]
        $res  = Resolve-GateEvidence -Spec $spec -RepoRoot $repoRoot
        if (-not $res.Verified) {
            $verifyFailures += "  ✗ gate '$g' · spec '$spec' · $($res.Reason)"
        } elseif ($res.ContainsKey('SoftClaim') -and $res.SoftClaim) {
            $verifySoftClaims += "  ⚠ gate '$g' · spec '$spec' · text-only claim accepted"
        }
    }
    if ($verifyFailures.Count -gt 0) {
        Write-Host ""
        Write-Host "Write-PhaseState: -StrictVerify REFUSED to emit PHASE_STATE_$Phase.json:" -ForegroundColor Red
        $verifyFailures | ForEach-Object { Write-Host $_ -ForegroundColor Red }
        Write-Host ""
        Write-Host "Fix the misses · add disk artefacts · re-run. Do NOT use -text: to paper over." -ForegroundColor Yellow
        # Throw (not exit) so callers can catch · pwsh -File still exits non-zero on uncaught throw
        throw "Write-PhaseState: -StrictVerify REFUSED — $($verifyFailures.Count) gate(s) failed disk-evidence resolution"
    }
    if ($verifySoftClaims.Count -gt 0) {
        Write-Host "Write-PhaseState: soft (text-only) gate claims:" -ForegroundColor Yellow
        $verifySoftClaims | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
    }
    Write-Host "Write-PhaseState: -StrictVerify resolved $($GatesTicked.Count) gates against disk evidence ✓" -ForegroundColor Green
}

# Resolve iter dir (auto-generate UTC if not provided)
if (-not $IterDir) {
    $utc = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $IterDir = Join-Path $repoRoot "tests/results/iter-$utc"
}
if (-not (Test-Path $IterDir)) {
    New-Item -ItemType Directory -Path $IterDir -Force | Out-Null
}

# Capture HEAD info
$headCommit = $null
$headAxis   = $null
try {
    $headCommit = ((& git -C $repoRoot rev-parse HEAD 2>$null) -as [string]).Trim()
    $fullMsg = (& git -C $repoRoot log -1 --format='%B' 2>$null) -join "`n"
    if ($fullMsg -match '(?m)^AXIS:\s*(.+)$') {
        $headAxis = $Matches[1].Trim()
    }
} catch {
    Write-Warning "Write-PhaseState: could not read git HEAD: $($_.Exception.Message)"
}

# T1 status (skip via -NoT1Check)
$t1Green = $null
if (-not $NoT1Check) {
    $runTests = Join-Path $repoRoot 'tests/Run-Tests.ps1'
    if (Test-Path $runTests) {
        Write-Host "Write-PhaseState: confirming T1 status..." -ForegroundColor Cyan
        & pwsh -NoProfile -File $runTests -Tier 1 -SkipPSSA 2>&1 | Out-Null
        $t1Green = ($LASTEXITCODE -eq 0)
    }
}

# Determine prior phase
$priorPhase = $null
$phaseChain = @('0a','0b','0c','0d','0e','0f','0g','0h','0i','0j','0k','0l','0m','G')
$idx = $phaseChain.IndexOf($Phase)
if ($idx -gt 0) {
    $priorPhase = $phaseChain[$idx - 1]
}

$payload = [ordered]@{
    phase                   = $Phase
    exit_at                 = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    gates_ticked            = @($GatesTicked)
    gate_evidence           = $GateEvidence                         # NEW · gate-name -> spec (commit:/file:/test:/text:)
    gates_strict_verified   = [bool]$StrictVerify                   # NEW · TRUE means each gate was disk-resolved
    live_proof_artefact     = $LiveProofArtefact
    t1_green                = $t1Green
    t2_validated            = $T2Validated
    t3_live_evidence        = $T3LiveEvidence
    head_commit             = $headCommit
    head_message_axis       = $headAxis
    prior_phase             = $priorPhase
    next_phase              = $NextPhase
    sibling_repo_refs_cited = @($SiblingRepoRefsCited)
}

# Merge extra data
foreach ($key in $ExtraData.Keys) {
    $payload[$key] = $ExtraData[$key]
}

$jsonPath = Join-Path $IterDir "PHASE_STATE_$Phase.json"
$payload | ConvertTo-Json -Depth 6 | Set-Content -Path $jsonPath -Encoding utf8

Write-Host ""
Write-Host "Write-PhaseState GREEN — wrote $jsonPath" -ForegroundColor Green
Write-Host "  Phase: $Phase  → next: $NextPhase" -ForegroundColor Cyan
Write-Host "  Gates ticked: $($GatesTicked.Count)" -ForegroundColor Cyan
Write-Host "  T1 green: $t1Green" -ForegroundColor Cyan
Write-Host "  Head commit: $headCommit" -ForegroundColor Cyan
Write-Host "  Head axis: $headAxis" -ForegroundColor Cyan
