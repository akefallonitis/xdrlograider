#Requires -Version 7.4
<#
.SYNOPSIS
P8 postdeploy driver — PURE WIRING of the four existing verify tools (B4: chains existing checks, adds NO
new assertions, thresholds, or gate logic).

.DESCRIPTION
Sequence (fail-fast; exit code = the failing stage's own exit code):
  1. version   · Verify-DeployedVersion.ps1   — Boot.VersionProbe SHA == HEAD
  2. estate    · Sync-LiveEstate.ps1          — report-only reconcile; carries the BLOCKING
                                                Assert-LiveSchemaParity gate (NEVER double-called here)
  3. connector · Verify-DeployedConnector.ps1 — per-op population/exactly-once/cadence/health/D12 gates
  4. content   · Verify-XdrLiveContent.ps1    — live content shape vs ProjectionMap (refuses CI → exit 2)
LOCAL-ONLY by inheritance of stage 4's CI refusal. Stages run as CHILD processes (the tools use `exit`).

.EXAMPLE
pwsh tools/Run-PostDeployVerify.ps1 -ResourceGroup xdrlograider -WorkspaceId <customerId-guid> `
  -WorkspaceResourceId /subscriptions/.../workspaces/<ws> -Window Hour -AllOps
#>
param(
    # NOT Mandatory: the file is dot-sourced by Pester for the pure planner (Mandatory would PROMPT and hang);
    # the live section validates presence and refuses loudly instead.
    [string] $ResourceGroup,         # ← .env.local XDRLR_CONNECTOR_RG if omitted
    [string] $WorkspaceId,           # customerId GUID or ARM id · ← .env.local XDRLR_WORKSPACE_ID if omitted (version + connector accept both)
    [string] $WorkspaceResourceId,   # ARM full resource id · ← .env.local XDRLR_WORKSPACE_RESOURCE_ID if omitted (estate reconcile + connector D12)
    [ValidateSet('Boot','Cold','Hour','Sustain','FirstIteration','ConsecutiveSustain')] [string] $Window = 'Cold',
    [string] $OperationKey,
    [switch] $AllOps,
    [string] $FunctionApp,   # C-1: ← .env.local XDRLR_FUNCTION_APP (or pass)
    [string] $StorageAccount,  # §4.B: ← .env.local XDRLR_STORAGE_ACCOUNT · forwarded to the connector so D3/D7 read the
                               # DURABLE checkpoint-row ResetUtc for reset-churn discrimination (else they use the lossy
                               # Checkpoint.Reset telemetry fallback · still reset-aware, just lag-prone).
    [int]    $SinceMinutes,
    [int]    $WaitMinutes = 15,          # version-stage ingestion-lag tolerance (poll for Boot.VersionProbe) ·
                                        # only INCURRED on a too-soon run; if already ingested there is no wait
    [string] $DeployedSinceUtc,          # absolute cutover floor · forwarded to the connector stage so its
                                        # window anchors at the deploy (catches Boot · excludes the stop-gap)
    [string[]] $Category = @(),          # per-category postdeploy; empty + a live run → defaulted from Get-XdrDeployedCategories
    # OPT-IN tolerance (default empty = STRICT · preserves the M1 cure for every other caller): on a connector exit-1
    # (INCONCLUSIVE, never a blocker), the live driver CONTINUES iff every inconclusive/advisory's base gate name is in
    # this set. The round-re-prove passes 'Reauth' for verify-SUSTAIN — it deliberately injects no auth-loss, so the
    # self-heal gate's "absence≠proof" INCO is EXPECTED (not a data regression). Never weakens a gate; never tolerates exit-2.
    [string[]] $TolerateInconclusiveGates = @(),
    [string] $KnownResetUtc = '',     # §4.B AUTHORITATIVE reset time · forwarded to each connector stage so reset-awareness is independent of storage/telemetry readability (Invoke-XdrRoundReprove passes its Save-XdrCheckpointReset instant)
    # DIAGNOSTIC keep-going (default OFF · preserves the strict stop-on-first-fail for every existing caller incl. the
    # finalize): when set, a failing stage is RECORDED and the run CONTINUES to the remaining stages, then exits with the
    # MAX stage rc + a per-stage summary. This is the anti-serial-discovery tool — one run surfaces EVERY cat's verdict
    # (not just the first blocker), so a batch-fix targets the whole surface at once instead of one-cat-per-30min-run.
    [switch] $KeepGoing
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─── PURE stage plan (Pester-driven · no Azure) ───────────────────────────────────────────────────
function Get-XdrPostDeployStagePlan {
    <#
    .SYNOPSIS
    PURE · the ordered postdeploy stage plan. Output: array of @{ Name; File; Args } — exactly the four
    existing tools, version → estate → connector → content; estate is report-only (parity gate lives
    INSIDE Sync-LiveEstate — never add a separate parity stage).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $WorkspaceId,
        [Parameter(Mandatory)] [string] $WorkspaceResourceId,
        [string] $Window = 'Cold',
        [string] $OperationKey,
        [bool]   $AllOps = $false,
        [string] $FunctionApp = '',   # C-1: production passes the resolved FA (below); '' is a neutral standalone/Pester default
        [string] $StorageAccount = '',  # §4.B: forwarded to the connector for D3/D7 durable-reset discrimination ('' → telemetry fallback)
        [int]    $SinceMinutes = 0,
        [int]    $WaitMinutes = 0,
        [string] $DeployedSinceUtc = '',
        [string[]] $Category = @(),   # PER-CATEGORY (the toolkit-gap fix): content+connector run ONCE PER category so the
                                      # connector's per-op gates actually evaluate (Verify-DeployedConnector with no -Category
                                      # → empty $workspaceTable → ALL per-op gates silently SKIP = a false-green). Empty →
                                      # single legacy pass (the connector falls back to Operations[0]); the live caller
                                      # defaults this from Get-XdrDeployedCategories so a real run is always per-cat.
        [string] $VerdictDir = '',    # G1 prove-empty wire: PER-CAT {op->Verdict} files (verdicts-<cat>.json) — content
                                      # writes (-VerdictOut), connector reads (-LiveSourceVerdicts). Only wired with -AllOps.
        [string] $KnownResetUtc = ''  # §4.B AUTHORITATIVE reset time forwarded to each connector stage (reset-awareness)
    )
    $versionArgs = @('-WorkspaceId', $WorkspaceId)
    if ($SinceMinutes) { $versionArgs += @('-SinceMinutes', $SinceMinutes) }
    if ($WaitMinutes)  { $versionArgs += @('-WaitMinutes', $WaitMinutes) }

    $estateArgs = @('-ResourceGroup', $ResourceGroup, '-WorkspaceResourceId', $WorkspaceResourceId)  # report-only: no -Apply

    # version + estate are GLOBAL (run once); content + connector are PER-CATEGORY. Empty -Category → one pass with no
    # -Category (legacy single-op / Operations[0] back-compat for the pure-planner Pester tests).
    $stages = @(
        @{ Name = 'version'; File = 'Verify-DeployedVersion.ps1'; Args = $versionArgs },
        @{ Name = 'estate';  File = 'Sync-LiveEstate.ps1';        Args = $estateArgs }
    )
    $cats = if ($Category.Count) { $Category } else { @('') }
    foreach ($cat in $cats) {
        $catTag = if ($cat) { "-$cat" } else { '' }

        $connectorArgs = @('-WorkspaceId', $WorkspaceId, '-ResourceGroup', $ResourceGroup,
                           '-WorkspaceResourceId', $WorkspaceResourceId, '-Window', $Window)
        if ($cat)             { $connectorArgs += @('-Category', $cat) }
        # -AllOps MUST reach the CONNECTOR too (mirror the content stage). Without it the connector's per-op loop falls back
        # to the single empty-$OperationKey op (Operations[0]) → only ONE op is gated per cat, AND an empty op-key short-
        # circuits the G1 LEGIT-NO-DATA probe (Test-XdrOpPolledToTerminal returns false on an empty key) so a 0-row
        # Operations[0] (e.g. cap-absent/empty GetPending) hard-fails MinRows. THE root cause of the GA-blocking re-prove
        # exit-2: the connector was silently single-op while content was AllOps. Mutually exclusive with -OperationKey (same as content).
        if ($AllOps)          { $connectorArgs += '-AllOps' }
        elseif ($OperationKey){ $connectorArgs += @('-OperationKey', $OperationKey) }
        if ($SinceMinutes)    { $connectorArgs += @('-SinceMinutes', $SinceMinutes) }
        if ($DeployedSinceUtc){ $connectorArgs += @('-DeployedSinceUtc', $DeployedSinceUtc) }
        # §4.B D3/D7 reset-awareness: pass the storage account so the connector reads the DURABLE checkpoint-row ResetUtc
        # (telemetry-lag-immune · the B10 FIX-3 source). Absent → the connector uses the Checkpoint.Reset telemetry fallback.
        if ($StorageAccount)  { $connectorArgs += @('-StorageAccount', $StorageAccount) }
        # §4.B AUTHORITATIVE reset time (2026-07-01): the caller knows WHEN it reset → the connector counts a reset if this
        # instant is in-window, independent of the durable/telemetry count (which can read a false-confident 0 for a tool-reset).
        if ($KnownResetUtc)   { $connectorArgs += @('-KnownResetUtc', $KnownResetUtc) }

        $contentArgs = @('-FunctionApp', $FunctionApp)
        if ($cat)      { $contentArgs += @('-Category', $cat) }
        if ($AllOps)   { $contentArgs += '-AllOps' }
        elseif ($OperationKey) { $contentArgs += @('-OperationKey', $OperationKey) }

        # G1 prove-empty wire (PER CAT): content writes the cat's verdict file FIRST, connector reads it for its 0-row
        # gate (B4: wires the existing Verify-XdrLiveContent proof; no new gate). Only with -AllOps.
        if ($AllOps -and $VerdictDir) {
            $vp = [System.IO.Path]::Combine($VerdictDir, "verdicts$catTag.json")   # .NET Combine · pure (no PSDrive validation, unlike Join-Path)
            $contentArgs   += @('-VerdictOut', $vp)
            $connectorArgs += @('-LiveSourceVerdicts', $vp)
        }

        # JSON report (consumed by -TolerateInconclusiveGates): the connector writes its structured verdict here so the
        # live driver can inspect WHICH gates were inconclusive on an exit-1. Only when a $VerdictDir exists (live run).
        $connReport = if ($VerdictDir) { [System.IO.Path]::Combine($VerdictDir, "connector-report$catTag.json") } else { '' }
        if ($connReport) { $connectorArgs += @('-JsonReportPath', $connReport) }

        # Order per cat: content (writes verdicts) → connector (consumes them).
        $stages += @{ Name = "content$catTag";   File = 'Verify-XdrLiveContent.ps1';    Args = $contentArgs }
        $stages += @{ Name = "connector$catTag"; File = 'Verify-DeployedConnector.ps1'; Args = $connectorArgs; ReportPath = $connReport }
    }
    return , $stages
}

# ─── PURE · tolerance decision (Pester-driven · no Azure) ──────────────────────────────────────────
function Test-XdrInconclusiveTolerable {
    <#
    .SYNOPSIS
    PURE · is a connector exit-1 (INCONCLUSIVE / ADVISORY) TOLERABLE for THIS caller? TRUE iff the tolerate set is non-empty
    AND the report has NO blockers AND every INCONCLUSIVE's BASE gate name is in the tolerate set. ADVISORIES are non-blocking
    by design (flag-for-review · surfaced for the manual audit) → they do NOT need to be tolerated (an advisory-only exit-1 is
    tolerable). Base gate name = the GateId before ' · ' and before the per-op '[opTag]'. Empty set / null report / any blocker
    / an UNtolerated inconclusive → FALSE (the M1 cure: an unproven axis goes RED unless the caller EXPLICITLY opted in).
    #>
    [CmdletBinding()]
    param($Report, [string[]] $Tolerate)
    if (-not $Tolerate -or @($Tolerate).Count -eq 0) { return $false }
    if ($null -eq $Report) { return $false }
    if (@($Report.Blockers).Count -gt 0) { return $false }
    # ADVISORIES are non-blocking by design (a flag-for-review signal · e.g. CapabilityRegression: an op that went 403/404
    # in-window but had rows in the broader lookback · surfaced in the report for the MANUAL audit) → they NEVER gate the
    # automated finalize. Only INCONCLUSIVES (an axis UNPROVEN this window) must each be an explicitly-tolerated gate class
    # (M1: an untolerated inconclusive still goes RED). An exit-1 with ONLY advisories (no inconclusives) is tolerable.
    $inconclusives = @(@($Report.Inconclusives) | Where-Object { $_ })
    $advisories    = @(@($Report.Advisories)    | Where-Object { $_ })
    if ($inconclusives.Count -eq 0 -and $advisories.Count -eq 0) { return $false }
    foreach ($it in $inconclusives) {
        $base = ((([string]$it) -split ' · ')[0] -split '\[')[0].Trim()
        if ($base -notin $Tolerate) { return $false }
    }
    return $true
}

# ─── Live driver (child processes · fail-fast) ────────────────────────────────────────────────────
if ($MyInvocation.InvocationName -ne '.') {
    # C-1 (2026-06-18) + §4.B FIX-4 (2026-06-24): resolve the estate from .env.local (the established source · gitignored ·
    # no hardcoded maintainer default) when not passed, BEFORE the required-args check, so the D-gates self-resolve with
    # NO manual flag. Same XDRLR_* convention as Run-PostDeployAudit: WorkspaceResourceId was the B6 INCONCLUSIVE cause
    # (Run-PostDeployVerify exited 2 'WorkspaceResourceId required' → B6 reported INCONCLUSIVE) — wire its resolution here.
    $envLocal = Join-Path (Resolve-Path "$PSScriptRoot\..").Path '.env.local'; $ev = @{}
    if (Test-Path $envLocal) { Get-Content $envLocal | ForEach-Object { if ($_ -match '^\s*([A-Za-z_]\w*)\s*=\s*(.+)$') { $ev[$Matches[1]] = $Matches[2].Trim().Trim('"') } } }
    if (-not $ResourceGroup)       { $ResourceGroup       = $ev['XDRLR_CONNECTOR_RG'] }
    if (-not $WorkspaceResourceId) { $WorkspaceResourceId = $ev['XDRLR_WORKSPACE_RESOURCE_ID'] }
    if (-not $WorkspaceId)         { $WorkspaceId         = $ev['XDRLR_WORKSPACE_ID'] }
    if (-not $FunctionApp)         { $FunctionApp         = $ev['XDRLR_FUNCTION_APP'] }
    if (-not $StorageAccount)      { $StorageAccount      = $ev['XDRLR_STORAGE_ACCOUNT'] }   # §4.B D3/D7 durable-reset source
    if (-not $ResourceGroup -or -not $WorkspaceId -or -not $WorkspaceResourceId) {
        # A verify driver that cannot run must NOT exit 0 — exit 2 (blocker class, same as the CI refusal).
        Write-Host '[Run-PostDeployVerify] -ResourceGroup + -WorkspaceId + -WorkspaceResourceId are required (set XDRLR_CONNECTOR_RG / XDRLR_WORKSPACE_ID / XDRLR_WORKSPACE_RESOURCE_ID in .env.local, or pass them · pure planner is dot-sourceable for tests).'
        exit 2
    }
    if (-not $FunctionApp) { throw 'XDRLR_FUNCTION_APP missing from .env.local (or pass -FunctionApp)' }
    # Per-category postdeploy: default -Category from the deployed manifests so a live run ALWAYS exercises the per-op
    # connector gates PER cat (a no -Category run leaves $workspaceTable empty → every per-op gate silently skips = a
    # false-green). The pure planner stays category-agnostic for the Pester tests.
    if (-not $Category -or $Category.Count -eq 0) {
        . (Join-Path $PSScriptRoot 'lib/Get-XdrDeployedCategories.ps1')
        $Category = @(Get-XdrDeployedCategories -Portal 'Defender')
    }
    # normalize -Category: `pwsh -File` cannot bind a multi-element [string[]] (separate tokens spill onto positional
    # params; a comma-joined token stays ONE element and PowerShell does NOT auto-split a string on comma), so a caller
    # (e.g. Invoke-XdrRoundReprove) passes the cats comma-joined — split them back so the per-cat loop sees real
    # categories, not one 'A,B,C' pseudo-category. No-op for an already-array (no embedded commas).
    $Category = @($Category | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    # SAME comma-join normalization for -TolerateInconclusiveGates (pwsh -File binds a multi-element [string[]] as ONE
    # comma-joined token · Invoke-XdrRoundReprove passes 'Reauth,VolatileHash,D3' for verify-SUSTAIN) — split so the
    # per-gate tolerance match (Test-XdrInconclusiveTolerable) sees real base gate names, not one 'A,B,C' pseudo-gate.
    $TolerateInconclusiveGates = @($TolerateInconclusiveGates | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    # G1 wire: PER-CAT direct-source verdict files in a fresh temp dir (content writes -VerdictOut, connector reads
    # -LiveSourceVerdicts). Clear it first so each connector consumes only THIS run's verdicts (absent file → the
    # connector treats a 0-row op as unproven INCONCLUSIVE, never a silent green).
    $verdictDir = Join-Path ([System.IO.Path]::GetTempPath()) 'xdr-postdeploy-verdicts'
    if (Test-Path $verdictDir) { Remove-Item $verdictDir -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $verdictDir -Force | Out-Null
    $plan = Get-XdrPostDeployStagePlan -ResourceGroup $ResourceGroup -WorkspaceId $WorkspaceId `
        -WorkspaceResourceId $WorkspaceResourceId -Window $Window -OperationKey $OperationKey `
        -AllOps $AllOps.IsPresent -FunctionApp $FunctionApp -StorageAccount $StorageAccount -SinceMinutes $SinceMinutes -WaitMinutes $WaitMinutes -DeployedSinceUtc $DeployedSinceUtc -Category $Category -VerdictDir $verdictDir -KnownResetUtc $KnownResetUtc

    $keepGoingFails = @()   # -KeepGoing accumulator: every non-tolerated stage failure (Name+rc) for the end-of-run summary
    $keepGoingMaxRc = 0
    foreach ($s in $plan) {
        Write-Host "[Run-PostDeployVerify] ── stage '$($s.Name)' · tools/$($s.File) ──"
        & pwsh -NoProfile -File (Join-Path $PSScriptRoot $s.File) @($s.Args)
        $rc = $LASTEXITCODE
        if ($rc -ne 0) {
            # OPT-IN tolerance: a connector exit-1 (INCONCLUSIVE · a blocker is exit-2) is tolerable ONLY when the caller
            # named the exact gate class in -TolerateInconclusiveGates AND the connector's JSON shows EVERY residual
            # inconclusive/advisory is in that set (Test-XdrInconclusiveTolerable · the M1 cure stays intact for default
            # callers). The round-re-prove uses this for verify-SUSTAIN's expected Reauth INCO (no auth-loss injected).
            if ($rc -eq 1 -and @($TolerateInconclusiveGates).Count -gt 0 -and $s.Name -like 'connector*' -and $s['ReportPath'] -and (Test-Path $s['ReportPath'])) {
                $report = $null
                try { $report = Get-Content $s['ReportPath'] -Raw | ConvertFrom-Json } catch { $report = $null }
                if (Test-XdrInconclusiveTolerable -Report $report -Tolerate $TolerateInconclusiveGates) {
                    Write-Host "[Run-PostDeployVerify] TOLERATED at stage '$($s.Name)' · exit 1 · only expected inconclusive gate(s) [$($TolerateInconclusiveGates -join ',')] · no blockers / no data inconclusives — continuing"
                    continue
                }
            }
            if ($KeepGoing) {
                # DIAGNOSTIC: record + continue so ONE run surfaces every cat's verdict (anti-serial-discovery). The run's
                # exit still reflects the WORST stage (max rc) — nothing is silently passed; -KeepGoing only defers the exit.
                Write-Host "[Run-PostDeployVerify] KEEP-GOING · stage '$($s.Name)' FAILED exit $rc · recorded, continuing to remaining stages"
                $keepGoingFails += [pscustomobject]@{ Stage = $s.Name; Rc = $rc }
                $keepGoingMaxRc = [Math]::Max($keepGoingMaxRc, $rc)
                continue
            }
            Write-Host "[Run-PostDeployVerify] FAIL at stage '$($s.Name)' · exit $rc (the stage's own code — see its output above)"
            exit $rc
        }
    }
    if ($KeepGoing -and $keepGoingFails.Count -gt 0) {
        Write-Host "[Run-PostDeployVerify] KEEP-GOING SUMMARY · $($keepGoingFails.Count) stage(s) failed (worst exit $keepGoingMaxRc):"
        foreach ($kf in $keepGoingFails) { Write-Host "    FAIL exit $($kf.Rc) · $($kf.Stage)" }
        exit $keepGoingMaxRc
    }
    Write-Host '[Run-PostDeployVerify] ALL STAGES GREEN · version == HEAD · estate/parity clean · connector gates · content shapes'
    exit 0
}
