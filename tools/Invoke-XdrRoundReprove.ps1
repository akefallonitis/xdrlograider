#Requires -Version 7.4
<#
.SYNOPSIS
The LOCKED per-round RE-PROVE orchestrator — PURE WIRING of existing tools (B4: composes, adds NO new gate/assertion).

.DESCRIPTION
The operator-locked 2-leg re-prove, runnable as ONE command per round (was a manual multi-step sequence → drift):
  leg-1  reset ALL deployed cats WITH rewind (Save-XdrCheckpointReset -Apply, per cat)  → cold baseline
         cold-emit-wait                                                                  → the FA re-polls the due ops
         postdeploy (Run-PostDeployVerify -AllOps -Window Cold)                          → per-cat content+connector C6 (G1 0-row wire)
  leg-2  force cycle-2 (Force-XdrFullCycle, NO rewind)                                    → re-poll same high-water
         cold-emit-wait                                                                  → cycle-2 lands
         postdeploy (Run-PostDeployVerify -AllOps -Window Sustain)                        → cross-cycle exactly-once (0 dup)
  roll-up  any non-zero stage exit ⇒ non-zero (no per-cat green hides a sibling red).

Categories are DATA-DRIVEN (Get-XdrDeployedCategories) so the round scales category-at-a-time with zero edits.
The pure planner Get-XdrRoundReprovePlan is dot-sourceable (Pester) with NO Azure. The live driver runs the phases
as child processes / direct calls, fail-fast. NO new verification logic — every gate already lives in the composed tools.

.EXAMPLE
pwsh tools/Invoke-XdrRoundReprove.ps1 -ResourceGroup xdrlograider -WorkspaceId <guid> -WorkspaceResourceId <arm> -Apply
#>
param(
    # NOT Mandatory: the file is dot-sourced by Pester for the pure planner (Mandatory would PROMPT and hang).
    [string]   $ResourceGroup,
    [string]   $WorkspaceId,            # customerId GUID or ARM id
    [string]   $WorkspaceResourceId,    # ARM full resource id (connector D12 + estate parity)
    [string]   $FunctionApp,            # ← .env.local XDRLR_FUNCTION_APP if omitted
    [string]   $StorageAccount,         # ← .env.local XDRLR_STORAGE_ACCOUNT if omitted (the reset target)
    [string[]] $Category = @(),         # empty + live → Get-XdrDeployedCategories -Portal $Portal
    [string]   $Portal = 'Defender',
    [int]      $ColdEmitWaitMinutes = 30,   # max wait per cold-emit poll (exits early; must exceed the slowest staggered cadence ~18m + ingest)
    [string]   $DeployedSinceUtc,           # forwarded to the postdeploy connector window floor
    [switch]   $Apply                       # required for the live (destructive: reset+force) run; absent = plan-only
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─── PURE phase plan (Pester-driven · no Azure) ────────────────────────────────────────────────────
function Get-XdrRoundReprovePlan {
    <#
    .SYNOPSIS
    PURE · the ordered per-round re-prove phases. Output: array of @{ Name; Kind; Detail }. The 2-leg sequence is
    fixed; only the category set is data-driven. Kinds: reset · cold-wait · postdeploy · force · rollup.
    #>
    [CmdletBinding()]
    param([string[]] $Category = @())
    $cats = if ($Category.Count) { ($Category -join ',') } else { '<deployed-from-manifests>' }
    $phases = @(
        @{ Name = 'reset-all';        Kind = 'reset';      Detail = "Save-XdrCheckpointReset -Apply per cat (leg-1 REWIND · clean baseline): $cats" }
        @{ Name = 'cadence-reset';    Kind = 'force';      Detail = 'Force-XdrFullCycle (leg-1 · force-WITHOUT-rewind · resets CADENCE so every long-cadence op re-emits in the cold window · operator: reset checkpoint AND cadence)' }
        @{ Name = 'cold-emit-wait-1'; Kind = 'cold-wait';  Detail = 'poll AppEvents until the FA re-polls the reset ops to terminal (stabilizes · no blind sleep)' }
        @{ Name = 'verify-cold';      Kind = 'postdeploy'; Detail = 'Run-PostDeployVerify -AllOps -Window Cold (per-cat content+connector · G1 0-row prove-empty wire)' }
        @{ Name = 'force-leg2';       Kind = 'force';      Detail = 'Force-XdrFullCycle (leg-2 · NO rewind → re-poll same high-water, must land 0 cross-cycle dups)' }
        @{ Name = 'cold-emit-wait-2'; Kind = 'cold-wait';  Detail = 'poll until forced cycle-2 lands' }
        @{ Name = 'verify-sustain';   Kind = 'postdeploy'; Detail = 'Run-PostDeployVerify -AllOps -Window Sustain (cross-cycle exactly-once · SnapshotNoDupAccum)' }
        @{ Name = 'no-regression';    Kind = 'rollup';     Detail = 'any non-zero phase exit ⇒ non-zero (no per-cat green hides a sibling red · nothing proven a priori)' }
    )
    return $phases   # 8 fixed phases — emit as a normal collection (works for both `$p = ...` and `... | ForEach`)
}

# ─── Live driver ────────────────────────────────────────────────────────────────────────────────────
if ($MyInvocation.InvocationName -ne '.') {
    if (-not $ResourceGroup -or -not $WorkspaceId -or -not $WorkspaceResourceId) {
        Write-Host '[Invoke-XdrRoundReprove] -ResourceGroup + -WorkspaceId + -WorkspaceResourceId are required.'
        exit 2
    }
    $repoRoot = (Resolve-Path "$PSScriptRoot\..").Path
    # .env.local fill (the established local source) for the bits not passed.
    $envLocal = Join-Path $repoRoot '.env.local'; $ev = @{}
    if (Test-Path $envLocal) { Get-Content $envLocal | ForEach-Object { if ($_ -match '^\s*([A-Za-z_]\w*)\s*=\s*(.+)$') { $ev[$Matches[1]] = $Matches[2].Trim().Trim('"') } } }
    if (-not $FunctionApp)    { $FunctionApp    = $ev['XDRLR_FUNCTION_APP'] }
    if (-not $StorageAccount) { $StorageAccount = $ev['XDRLR_STORAGE_ACCOUNT'] }

    # cats: data-driven from the deployed manifests.
    if (-not $Category -or $Category.Count -eq 0) {
        . (Join-Path $PSScriptRoot 'lib/Get-XdrDeployedCategories.ps1')
        $Category = @(Get-XdrDeployedCategories -Portal $Portal)
    }
    if (-not $Category -or $Category.Count -eq 0) { Write-Host "[Invoke-XdrRoundReprove] no deployed categories under manifests/$Portal"; exit 2 }
    Write-Host "[Invoke-XdrRoundReprove] cats=$($Category -join ',') · Portal=$Portal · ColdEmitWaitMinutes=$ColdEmitWaitMinutes · Apply=$($Apply.IsPresent)"
    # print the plan — one line per phase
    $plan = Get-XdrRoundReprovePlan -Category $Category
    foreach ($ph in $plan) { Write-Host ("  [{0}] {1} — {2}" -f $ph.Kind, $ph.Name, $ph.Detail) }
    if (-not $Apply) { Write-Host '[Invoke-XdrRoundReprove] PLAN-ONLY (pass -Apply for the live reset+force+verify run).'; exit 0 }
    if (-not $StorageAccount) { Write-Host '[Invoke-XdrRoundReprove] -StorageAccount is required for the live run (force-leg2 → Force-XdrFullCycle mandatory) and was not resolvable from .env.local XDRLR_STORAGE_ACCOUNT. Pass -StorageAccount.'; exit 2 }

    function Invoke-XdrChild { param([string]$File, [string[]]$ChildArgs, [string]$Phase)
        Write-Host "[Invoke-XdrRoundReprove] ── $Phase · tools/$File ──"
        # $ChildArgs — NOT $Args (a param named $Args is shadowed by the automatic $Args, so @Args splats EMPTY and
        # every child silently ran with its defaults). | Out-Host keeps the child's stdout on the console WITHOUT
        # folding it into the function's return, so $rc is the exit code alone (not stdout+code → broken roll-up).
        & pwsh -NoProfile -File (Join-Path $PSScriptRoot $File) @ChildArgs | Out-Host
        return $LASTEXITCODE
    }

    function Invoke-XdrVerifyWithRetry { param([string]$File, [string[]]$ChildArgs, [string]$Phase, [int]$MaxTries = 3, [int]$WaitMin = 4)
        # The verify (Run-PostDeployVerify · version+estate+content+connector) is READ-ONLY + idempotent, so on a non-zero
        # exit we RETRY up to $MaxTries (waiting $WaitMin between) — the GENERIC cure for the AppEvents/AppTraces telemetry
        # table ingesting SLOWER than the verify runs (the ONE root cause behind the Boot / PollCycles / MinRows-cap-absent
        # residuals: a gate reads Entry.Poll.Succeeded | Capability.OpUnavailable | boot-traces that haven't landed yet).
        # OBSERVE the actual gate outcome — let the laggard telemetry ingest + cadence stragglers re-poll — rather than
        # guess a pre-wait that stabilizes on a proxy plateau before the laggards land. Only a STILL-non-zero verify AT the
        # cap is a real failure (the M1 cure holds: it DOES go RED if the state stays genuinely unproven).
        $rc = 0
        for ($try = 1; $try -le $MaxTries; $try++) {
            $rc = Invoke-XdrChild -File $File -ChildArgs $ChildArgs -Phase "$Phase (try $try/$MaxTries)"
            if ($rc -eq 0) { return 0 }
            if ($try -lt $MaxTries) {
                Write-Host "[Invoke-XdrRoundReprove] $Phase · exit $rc on try $try/$MaxTries — retry in ${WaitMin}m (slow AppEvents/AppTraces ingest + cadence stragglers; the verify is read-only/idempotent)"
                Start-Sleep -Seconds ($WaitMin * 60)
            }
        }
        Write-Host "[Invoke-XdrRoundReprove] $Phase · still exit $rc after $MaxTries tries — REAL failure (not just ingest lag)"
        return $rc
    }

    function Wait-XdrCadenceCycle {
        # Bounded POLL (replaces a blind sleep): wait until the FA has run the cadence cycle since $SinceUtc, then proceed.
        #   Mode 'ingest' (after reset / cold-emit): poll the cats' *_CL until the freshly-emitted rows have INGESTED
        #     (distinct landed ops since $SinceUtc stabilizes) — covers BOTH the FA poll AND the DCR→LA lag, so the
        #     verify-cold D2/D6 have rows to evaluate.
        #   Mode 'poll' (after force / leg-2): poll AppEvents until the FA has RE-POLLED the due ops to terminal — the
        #     SNAPSHOT skip lands NO new _CL row, so the poll-cycle (not the _CL) is the signal, giving SnapshotNoDupAccum
        #     its >=2 poll cycles to exercise the cross-cycle skip.
        # Data-driven: stabilize on 2 equal non-zero reads (no hardcoded count); exits early; capped at $TimeoutMin.
        param([string]$SinceUtc, [string]$Phase, [int]$TimeoutMin, [ValidateSet('ingest','poll')][string]$Mode, [int]$ExpectCats = 0)
        # ingest (leg-1): distinct CATEGORIES with landed rows — wait until ALL deployed cats emit (>=ExpectCats); the
        #   onboot poll is staggered + non-deterministic, so an aggregate-op plateau fires before the slow cat polls.
        # poll (leg-2): COUNT of ops with >=2 poll-cycles (dcount Entry.Poll.Succeeded CorrelationIds) since the floor —
        #   the SnapshotNoDupAccum gate's EXACT cross-cycle dependency. AppEvents ingests SLOWER than _CL; a plain
        #   dcount(OperationKey) proxy stabilizes once each op has >=1 event (leg-1 OR leg-2), BEFORE leg-2's events for all
        #   ops ingest → the gate then reads PollCycles=0. Observing the gate's OWN condition (cyc>=2, same floor the gate
        #   uses) means verify-sustain runs only once PollCycles>=2 is genuinely queryable.
        $q = if ($Mode -eq 'ingest') {
            # DATA-DRIVEN union over the DEPLOYED cats' _CL tables (was hardcoded to the 3 pilot tables → a 4th onboarded
            # cat's rows were never observed: dcount(Category) capped at the 3 hardcoded tables < ExpectCats, starving the
            # wait to its cap then racing verify-cold). Table name mirrors the connector's canonical derivation
            # (Verify-DeployedConnector.ps1 "${Portal}_${Category}_CL"); $Category is the resolved deployed-cat set by here.
            $tables = ($Category | ForEach-Object { '{0}_{1}_CL' -f $Portal, $_ }) -join ', '
            "union $tables | where TimeGenerated >= datetime('$SinceUtc') | summarize d=dcount(tostring(Category))"
        } else {
            "AppEvents | where TimeGenerated >= datetime('$SinceUtc') | where Name == 'Entry.Poll.Succeeded' | summarize cyc=dcount(tostring(Properties.CorrelationId)) by op=tostring(Properties.OperationKey) | where cyc >= 2 | summarize d=count()"
        }
        $deadline = (Get-Date).AddMinutes($TimeoutMin); $prev = -1; $stable = 0
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 40
            $out = (az monitor log-analytics query --workspace $WorkspaceId --analytics-query $q -o tsv 2>$null | Out-String)
            $cur = if ($out -match '(\d+)') { [int]$Matches[1] } else { -1 }
            if ($cur -gt 0 -and $cur -eq $prev) { $stable++ } else { $stable = 0 }
            Write-Host "[Invoke-XdrRoundReprove] $Phase · $Mode distinct=$cur (stable x$stable · cap ${TimeoutMin}m)"
            # stable>=3 (4 equal reads ~2.7m) not >=1: a FAST table can plateau while a SLOWER table is still ingesting,
            # so a single repeat would fire prematurely (verify-cold then sees 0 rows for the slow cat's ops).
            # ingest: ALL deployed cats emitted (>=ExpectCats) AND stable — the staggered/non-deterministic onboot means
            # a fast cat plateaus while a slow cat hasn't polled yet, so an aggregate plateau fires too soon; poll: just stable.
            $ready = if ($Mode -eq 'ingest') { ($cur -ge $ExpectCats -and $stable -ge 3) } else { ($stable -ge 3) }
            if ($ready) {
                Write-Host "[Invoke-XdrRoundReprove] $Phase · cadence cycle landed (value=$cur stable x$stable)"
                # +5m settle covers the DCR->LA (_CL) AND AppEvents ingest lag (AppEvents ingests SLOWER than _CL, so a
                # late op's Entry.Poll.Succeeded isn't queryable for SnapshotNoDupAccum's PollCycles right after the poll).
                Write-Host "[Invoke-XdrRoundReprove] $Phase · +5m ingest settle (DCR->LA + AppEvents ingest lag)"; Start-Sleep -Seconds 300
                return
            }
            $prev = $cur
        }
        Write-Host "[Invoke-XdrRoundReprove] $Phase · cadence-wait hit ${TimeoutMin}m cap (proceeding · the verify stage is the gate)"
    }

    # leg-1 · reset ALL cats WITH rewind (the clean baseline)
    $resetSince = (Get-Date).ToUniversalTime().AddSeconds(-30).ToString('yyyy-MM-ddTHH:mm:ssZ')
    foreach ($cat in $Category) {
        $rc = Invoke-XdrChild -File 'Save-XdrCheckpointReset.ps1' -Phase "reset[$cat]" -ChildArgs @('-Portal', $Portal, '-Category', $cat, '-Reason', 'operator-override', '-Apply')
        if ($rc -ne 0) { Write-Host "[Invoke-XdrRoundReprove] FAIL reset[$cat] exit $rc"; exit $rc }
    }

    # leg-1 CADENCE reset · force ALL ops cadence-due so EVERY stream re-emits in the cold window REGARDLESS of cadence
    # (operator: "reset checkpoint AND cadence" · a 6h/1d-cadence op otherwise never emits inside the 30m cold window, so
    # verify-cold's MinRows false-fails it as a "real gap"). Force-WITHOUT-rewind: only LastUpdatedUtc is cleared, the
    # cursor/BoundaryKeys/Resume* frontier is UNTOUCHED, so the exactly-once guarantee is preserved (no duplicates).
    $rcForce1 = Invoke-XdrChild -File 'Force-XdrFullCycle.ps1' -Phase 'cadence-reset-leg1' -ChildArgs @('-ResourceGroup', $ResourceGroup, '-StorageAccount', $StorageAccount)
    if ($rcForce1 -ne 0) { Write-Host "[Invoke-XdrRoundReprove] FAIL cadence-reset-leg1 exit $rcForce1"; exit $rcForce1 }

    # cold-emit-wait (leg-1) — bounded POLL until the reset ops re-emit AND ingest to the _CL (NOT a blind sleep; the
    # connector has NO -WaitMinutes tolerance — that is version-stage-only — so the rows must be landed by verify time).
    Wait-XdrCadenceCycle -SinceUtc $resetSince -Phase 'cold-emit-wait-1' -TimeoutMin $ColdEmitWaitMinutes -Mode 'ingest' -ExpectCats $Category.Count

    # verify-cold · the per-cat postdeploy C6 (Run-PostDeployVerify loops the cats internally)
    $pdvArgs = @('-ResourceGroup', $ResourceGroup, '-WorkspaceId', $WorkspaceId, '-WorkspaceResourceId', $WorkspaceResourceId,
                 '-Window', 'Cold', '-AllOps', '-Category', ($Category -join ','))  # comma-join: pwsh -File binds only the FIRST element of a [string[]] passed as separate tokens
    if ($FunctionApp)      { $pdvArgs += @('-FunctionApp', $FunctionApp) }
    if ($DeployedSinceUtc) { $pdvArgs += @('-DeployedSinceUtc', $DeployedSinceUtc) }
    if ($StorageAccount)   { $pdvArgs += @('-StorageAccount', $StorageAccount) }   # FIX-1 belt: explicit -StorageAccount (Cold's gates don't use reset-awareness, but keep both legs consistent)
    $rcCold = Invoke-XdrVerifyWithRetry -File 'Run-PostDeployVerify.ps1' -Phase 'verify-cold' -ChildArgs $pdvArgs

    # leg-2 · force cycle-2 (no rewind) → re-poll same high-water
    $rcForce = Invoke-XdrChild -File 'Force-XdrFullCycle.ps1' -Phase 'force-leg2' -ChildArgs @('-ResourceGroup', $ResourceGroup, '-StorageAccount', $StorageAccount)
    # cold-emit-wait (leg-2) — bounded POLL until ops reach >=2 poll-cycles (the SNAPSHOT skip lands no new _CL row, so the
    # poll-cycle telemetry is the signal). Floor = the SAME window the SnapshotNoDupAccum gate uses ($DeployedSinceUtc, else
    # the leg-1 $resetSince) so the poll observes the gate's EXACT cross-cycle condition before verify-sustain runs.
    $pollFloor = if ($DeployedSinceUtc) { $DeployedSinceUtc } else { $resetSince }
    Wait-XdrCadenceCycle -SinceUtc $pollFloor -Phase 'cold-emit-wait-2' -TimeoutMin $ColdEmitWaitMinutes -Mode 'poll' -ExpectCats $Category.Count

    # verify-sustain · cross-cycle exactly-once
    $pdvArgsSus = @('-ResourceGroup', $ResourceGroup, '-WorkspaceId', $WorkspaceId, '-WorkspaceResourceId', $WorkspaceResourceId,
                    '-Window', 'Sustain', '-AllOps', '-Category', ($Category -join ','))  # comma-join (see verify-cold note)
    if ($FunctionApp)      { $pdvArgsSus += @('-FunctionApp', $FunctionApp) }
    if ($DeployedSinceUtc) { $pdvArgsSus += @('-DeployedSinceUtc', $DeployedSinceUtc) }   # cross-cycle check must also floor the window (exclude pre-deploy / prior-run rows), not just verify-cold
    $pdvArgsSus += @('-KnownResetUtc', $resetSince)   # §4.B AUTHORITATIVE reset time → reset-awareness (D1/D3/D7/SnapshotNoDupAccum/ExactlyOnce/VolatileHash) is independent of the durable/telemetry count reading a false-0 for the tool-driven reset
    if ($StorageAccount)   { $pdvArgsSus += @('-StorageAccount', $StorageAccount) }        # FIX-1 belt: explicit, not relying on the child re-reading .env.local
    # verify-SUSTAIN tolerates the EXPECTED reset-churn INCONCLUSIVES (never a blocker/exit-2 · data gates must still pass):
    #  - Reauth · INTENTIONALLY inconclusive without a live auth-loss (the round injects none · auth-resilience is a SEPARATE test).
    #  - VolatileHash + the D1/D3/D7 reset-awareness gates · the leg-1 reset(s) churn the keyless SNAPSHOT content-hash / the
    #    (Op,CId) poll set / the sub-30s re-fire cadence in-window → each SELF-DESCRIBES "reset-adjacent · re-verify a reset-free
    #    window · INCONCLUSIVE"; the AUTHORITATIVE cross-cycle exactly-once gate (SnapshotNoDupAccum) still PASSES, so the reset
    #    artifact is not a data regression. D7 was ADDED 2026-07-01: verify-sustain's D7 runs ~2–3.5h after the leg-1 reset, PAST
    #    the old 2h reset-awareness window, so the forced-cycle re-fire (live: AnalyticsData GetEnrichedOutbreakData min=19s)
    #    false-FAILed as a real double-fire; the fix WIDENS that window to a 6h floor (Get-XdrResetAwarenessHours) so the reset is
    #    SEEN → D7 discriminates it to INCONCLUSIVE, tolerated here. A real stuck/orphan/dup/stall stays exit-2 → STILL fails.
    # verify-COLD does NOT tolerate (no Reauth/reset-churn INCO there; its 0-row ops use the G1 prove-empty wire).
    $pdvArgsSus += @('-TolerateInconclusiveGates', 'Reauth,VolatileHash,D1,D3,D7,SnapshotNoDupAccum,ExactlyOnce')   # comma-joined · Run-PostDeployVerify splits · D1/D3/D7/SnapshotNoDupAccum/ExactlyOnce/VolatileHash = the reset-awareness gates: a finalize ALWAYS resets, so their reset-churn INCONCLUSIVE (discriminated via the authoritative KnownResetUtc) is EXPECTED + tolerated HERE; standalone steady-state stays STRICT; the DATA gates (D2/D6/D8f/D8h) NEVER soften
    # verify-sustain gets a WIDER retry budget than verify-cold: it reads the AppEvents poll-lifecycle (D3) + cadence (D7)
    # gates, and AppEvents ingests SLOWER than _CL (up to ~40m vs the default 3x4m=12m budget). 2026-06-21 P5-1: a force-leg
    # poll's terminal ingested >17m late → D3 saw it as stuck (Started, no terminal, stale) + D7 saw a force/natural double-
    # fire across all 3 default tries, yet the SAME window re-verified clean ~30m later (data exactly-once throughout). The
    # GENERIC cure (observe the gate as the laggard telemetry lands) was simply under-budgeted; 5x7=35m (+5m settle = ~40m)
    # spans the AppEvents lag. The D3 3m stuck-grace stays STRICT — this gives ingest time, it does NOT weaken the gate (M1).
    $rcSus = Invoke-XdrVerifyWithRetry -File 'Run-PostDeployVerify.ps1' -Phase 'verify-sustain' -ChildArgs $pdvArgsSus -MaxTries 5 -WaitMin 7

    # no-regression roll-up
    $worst = [int]((@($rcCold, $rcForce, $rcSus) | Measure-Object -Maximum).Maximum)   # clean scalar for exit
    Write-Host "[Invoke-XdrRoundReprove] roll-up · verify-cold=$rcCold force=$rcForce verify-sustain=$rcSus → exit $worst"
    if ($worst -ne 0) { Write-Host '[Invoke-XdrRoundReprove] RE-PROVE FAILED (a leg/cat did not pass · see the stage output above).'; exit $worst }
    Write-Host '[Invoke-XdrRoundReprove] RE-PROVE GREEN · both legs · all cats · no regression.'
    exit 0
}
