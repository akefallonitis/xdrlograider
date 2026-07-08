#Requires -Version 7.4
<#
.SYNOPSIS
GA-readiness gate per plan v11 §3.2 O4 + §7 Phase F + §18.4 (9 explicit conditions).

.DESCRIPTION
The Phase F GA gate. Aggregates evidence across 9 conditions (plan §18.4) to determine whether the
deployed FA + workspace is GA-ready. Tool returns GA-CANDIDATE when all 9 auto-checks pass — the
final 10th gate is operator confirmation ("GA" word) which the tool cannot evaluate and reports as
"awaiting operator confirmation".

9 explicit conditions (plan §18.4):
  C1 Gauntlet exit 0       · pre-push gauntlet GREEN at HEAD
  C2 Sustain passes        · ≥ MinConsecutiveSustains consecutive Sustain windows · each Verify-DeployedConnector exit 0
  C3 AppExceptions          · 0 total across the SinceHours window
  C4 DLQ stable             · XdrIngestDlq Storage Table count == 0 (or stable-non-growing if seed rows exist)
  C5 OpenCircuits           · XdrCircuitState rows with state='Open' count == 0 at sample time
  C6 D8 data-plane-context  · D8c + D8f + D8g + D8h all PASS in the Sustain windows (plan §18.2 keystone)
  C7 Multi-axis invariants  · subsumed by C1 (gauntlet axes 5-30 enforce these)
  C8 Manifest health        · Validate-Manifests exit 0 · subsumed by C1 (gauntlet axis 16)
  C9 Public surface clean   · subsumed by C1 (gauntlet axes 8 anti-attribution + 10 gitignore)

10th gate (operator):
  C10 Operator confirms "GA" or "wait + reason" · cannot be auto-evaluated · tool reports
      "GA-CANDIDATE · awaiting operator confirmation" when C1-C9 all green.

Per operator §F.5 directive: GA = one operator word after I assess.

Exit codes:
  0 · GA-CANDIDATE · all 9 auto-conditions GREEN · operator confirmation required to tag v0.1.0
  1 · INSUFFICIENT-DATA · auto-conditions GREEN but sustain count below threshold
  2 · BLOCKING-FAIL · one or more conditions FAIL · NOT GA-ready
  3 · tool error (workspace unreachable · az login failure · script bug)

CREATE for v11 per plan §11.3 · cites §3.2 O4 + §7 Phase F + §18.4 building blocks.
EXTENDED 2026-06-02 PM per operator binding "consolidate everything not just patch" · was 1-sustain
gate · now enforces all 9 §18.4 conditions.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WorkspaceId,
    [string] $ResourceGroup,
    [string] $WorkspaceResourceId,     # ARM full resource ID · enables D12 V3 surface check via Verify-DeployedConnector
    [string] $StorageAccount,          # connector RG Storage Account · enables C4 DLQ + C5 OpenCircuits queries
    [ValidateSet('Defender','Entra','Intune','Purview','SecurityCopilot')] [string] $Portal = 'Defender',
    [string] $Category = 'Operations', # category whose per-Op content + exactly-once gates C2 verifies (forwarded to Verify-DeployedConnector -Category · they SKIP without it)
    [switch] $AllOps,                  # C2 verifies EVERY Operation in -Category (Verify-DeployedConnector -AllOps) · the GA per-category all-ops landing gate
    [string] $DeployedSinceUtc,        # ISO-8601 cutover instant · scopes the per-Op content + exactly-once gates to THIS deployment's lineage (excludes pre-cutover residue + across-reset re-ingest) · forwarded to Verify-DeployedConnector
    [int] $MinConsecutiveSustains = 3,
    [int] $SinceHours = 12,
    [int] $SustainGapMinutes = 5,      # gap between consecutive Sustain runs · prevents the same window being checked N times
    [int] $SustainInconclusiveRetries = 2,  # a Sustain window that exits 1 (INCONCLUSIVE · transient ingest-lag, NOT a data-integrity defect which is exit 2) is settled + re-polled up to this many times before it counts as a fail; exit 2 never retries (real defect). Proves-legit over a fresh window; a PERSISTENT inconclusive still fails (no mask).
    [ValidateSet('Console','Json','Markdown')] [string] $OutputFormat = 'Console',
    [switch] $Strict,
    [switch] $SkipGauntlet              # diagnostic flag · skip C1 (gauntlet) when re-running C2-C9 only
)

$ErrorActionPreference = 'Stop'
$repoRoot = Resolve-Path "$PSScriptRoot\.." | ForEach-Object Path

$verifyTool = Join-Path $repoRoot 'tools/Verify-DeployedConnector.ps1'
$gauntletTool = Join-Path $repoRoot 'tools/Run-PrePushGauntlet.ps1'

if (-not (Test-Path $verifyTool)) { Write-Error "Verify-DeployedConnector.ps1 missing"; exit 3 }
if (-not (Test-Path $gauntletTool)) { Write-Error "Run-PrePushGauntlet.ps1 missing"; exit 3 }

$report = [ordered]@{
    StartedUtc        = ([DateTime]::UtcNow).ToString('o')
    WorkspaceId       = $WorkspaceId
    ResourceGroup     = $ResourceGroup
    StorageAccount    = $StorageAccount
    MinSustains       = $MinConsecutiveSustains
    SinceHours        = $SinceHours
    Conditions        = [ordered]@{
        C1_Gauntlet           = @{ Pass = $false; Detail = '' }
        C2_SustainPasses      = @{ Pass = $false; Detail = ''; Passes = 0 }
        C3_AppExceptions      = @{ Pass = $false; Detail = '' }
        C4_DlqStable          = @{ Pass = $false; Detail = '' }
        C5_OpenCircuits       = @{ Pass = $false; Detail = '' }
        C6_DataPlaneContext   = @{ Pass = $false; Detail = '' }
        C7_MultiAxis          = @{ Pass = $false; Detail = 'subsumed by C1' }
        C8_ManifestHealth     = @{ Pass = $false; Detail = 'subsumed by C1' }
        C9_PublicSurface      = @{ Pass = $false; Detail = 'subsumed by C1' }
    }
    Verdict           = $null
    Blockers          = @()
    Advisories        = @()
    OperatorNote      = 'C10 (operator GA word) is the final gate · not evaluated by tool'
}

# ─── C1 · Gauntlet exit 0 at HEAD (all axes · subsumes C7 + C8 + C9) ────────────
if ($SkipGauntlet.IsPresent) {
    # HONEST diagnostic (verification-honesty 2026-06-15): -SkipGauntlet re-runs the LIVE gates (C2-C6) only. It must NOT
    # stamp the offline gates GREEN it never ran — that was a FALSE-PASS (a GA verdict could claim C1/C7-9 proven when
    # they were merely "assumed GREEN"). Mark them NOT-EVALUATED (Pass=$false · Inconclusive) + add a GA Blocker, so a
    # -SkipGauntlet run can NEVER be GA-CANDIDATE (the verdict requires every condition Pass=$true AND zero blockers).
    Write-Host '[Test-GaReadiness] C1 NOT EVALUATED (-SkipGauntlet diagnostic) · this run CANNOT yield a GA verdict (re-run without -SkipGauntlet)'
    $report.Conditions.C1_Gauntlet = @{ Pass = $false; Inconclusive = $true; Detail = 'NOT EVALUATED · -SkipGauntlet diagnostic (re-run WITHOUT -SkipGauntlet for a GA verdict)' }
    $report.Conditions.C7_MultiAxis = @{ Pass = $false; Inconclusive = $true; Detail = 'NOT EVALUATED · subsumed by C1 (-SkipGauntlet)' }
    $report.Conditions.C8_ManifestHealth = @{ Pass = $false; Inconclusive = $true; Detail = 'NOT EVALUATED · subsumed by C1 (-SkipGauntlet)' }
    $report.Conditions.C9_PublicSurface = @{ Pass = $false; Inconclusive = $true; Detail = 'NOT EVALUATED · subsumed by C1 (-SkipGauntlet)' }
    $report.Blockers += 'C1/C7-9 NOT EVALUATED (-SkipGauntlet diagnostic) · not GA-assessable · re-run without -SkipGauntlet'
} else {
    Write-Host '[Test-GaReadiness] C1 · pre-push gauntlet on HEAD'
    & pwsh -NoProfile -File $gauntletTool 2>&1 | Out-Null
    $gauntletExit = $LASTEXITCODE
    $c1Pass = $gauntletExit -eq 0
    $report.Conditions.C1_Gauntlet = @{ Pass = $c1Pass; Detail = "gauntlet exit=$gauntletExit (all axes)" }
    $report.Conditions.C7_MultiAxis = @{ Pass = $c1Pass; Detail = "all gauntlet axes (gauntlet exit=$gauntletExit)" }
    $report.Conditions.C8_ManifestHealth = @{ Pass = $c1Pass; Detail = "axis 16 Validate-Manifests (gauntlet exit=$gauntletExit)" }
    $report.Conditions.C9_PublicSurface = @{ Pass = $c1Pass; Detail = "axes 8+10 attribution+gitignore (gauntlet exit=$gauntletExit)" }
    if (-not $c1Pass) {
        $report.Blockers += "C1 · gauntlet exit=$gauntletExit · MUST be 0 for GA"
    }
}

# ─── C2 · ≥N consecutive Sustain windows pass ──────────────────────────────────
# Each Sustain run invokes Verify-DeployedConnector -Window Sustain · exit 0 = window pass.
# Gap between runs prevents the same window being counted N times.
Write-Host "[Test-GaReadiness] C2 · $MinConsecutiveSustains consecutive Sustain windows (gap=${SustainGapMinutes}m)"
$sustainPasses = 0
$sustainExits = @()
$sustainOutputs = @()
for ($i = 1; $i -le $MinConsecutiveSustains; $i++) {
    Write-Host "  [$i/$MinConsecutiveSustains] Sustain window in progress..."
    $verifyArgs = @(
        '-WorkspaceId', $WorkspaceId,
        '-Window', 'Sustain',
        '-SinceMinutes', ($SinceHours * 60),
        '-OutputFormat', 'Json'
    )
    if ($ResourceGroup) { $verifyArgs += @('-ResourceGroup', $ResourceGroup) }
    if ($WorkspaceResourceId) { $verifyArgs += @('-WorkspaceResourceId', $WorkspaceResourceId) }
    $verifyArgs += @('-Portal', $Portal, '-Category', $Category)   # forward so the per-Op content gates (D8f/D8g/D8h) + ExactlyOnce actually RUN (they skip without -Category)
    if ($AllOps.IsPresent) { $verifyArgs += '-AllOps' }            # GA per-category all-ops landing proof (loops the per-Op gates over every Operation)
    if ($DeployedSinceUtc) { $verifyArgs += @('-DeployedSinceUtc', $DeployedSinceUtc) }  # scope to this deployment's lineage (exclude pre-cutover / across-reset residue)
    if ($Strict.IsPresent) { $verifyArgs += '-Strict' }

    # Run the Sustain verify with retry-on-INCONCLUSIVE. Verify-DeployedConnector exit codes: 0 = pass ·
    # 1 = INCONCLUSIVE/ADVISORY (ingest-lag / reset-adjacent / empty window — a transient "could-not-prove",
    # NEVER a data-integrity defect) · 2 = BLOCKER (real defect) · 3 = setup error. A bare single strict run
    # counted a momentary transient (exit 1) as a hard fail, making the N-consecutive-window gate fragile. We
    # settle + re-poll an exit-1 window up to $SustainInconclusiveRetries times (proves-legit over a fresh
    # window); exit 2/3 are decisive and never retry; a PERSISTENT inconclusive after all retries still fails
    # (no mask — this is retry, not tolerate).
    $verifyJson = $null; $verifyExit = $null
    for ($attempt = 0; $attempt -le $SustainInconclusiveRetries; $attempt++) {
        $verifyJson = & pwsh -NoProfile -File $verifyTool @verifyArgs 2>&1
        $verifyExit = $LASTEXITCODE
        if ($verifyExit -ne 1) { break }   # 0 / 2 / 3 are decisive — stop retrying
        if ($attempt -lt $SustainInconclusiveRetries) {
            Write-Host "    INCONCLUSIVE (exit=1) · settle ${SustainGapMinutes}m + re-poll (retry $($attempt+1)/$SustainInconclusiveRetries)"
            Start-Sleep -Seconds ($SustainGapMinutes * 60)
        }
    }
    $sustainExits += $verifyExit
    # ,comma-operator: preserve each run's multi-line string[] as ONE array element. A bare `+= $verifyJson`
    # FLATTENS the string[] so every output LINE becomes a separate pseudo-run → C3/C6 then parse each single
    # line as a whole-run JSON → "runN: unparseable Verify output" for all N lines (PowerShell array-flatten trap).
    $sustainOutputs += ,$verifyJson
    if ($verifyExit -eq 0) {
        $sustainPasses++
        Write-Host "    PASS (exit=0)"
    } else {
        Write-Host "    FAIL (exit=$verifyExit)"
    }
    if ($i -lt $MinConsecutiveSustains) {
        Write-Host "  Waiting ${SustainGapMinutes}m before next sustain run..."
        Start-Sleep -Seconds ($SustainGapMinutes * 60)
    }
}
$c2Pass = $sustainPasses -ge $MinConsecutiveSustains
$report.Conditions.C2_SustainPasses = @{
    Pass    = $c2Pass
    Detail  = "$sustainPasses/$MinConsecutiveSustains pass · exits=$(($sustainExits -join ','))"
    Passes  = $sustainPasses
}
if (-not $c2Pass) {
    $report.Blockers += "C2 · only $sustainPasses/$MinConsecutiveSustains sustain windows passed"
}

# ─── C3 · 0 AppExceptions across ALL Sustain windows (parsed from EVERY sustain run JSON) ───
# V-M5 (2026-06-18): aggregate across ALL Sustain outputs — a fail in ANY counted window fails C3 (the old
# last-run-only read could pass C3 on a clean FINAL window while an EARLIER window had real exceptions, since
# C2 only counts exit codes, not the AppExceptions gate per-window). Each Sustain run's JSON is parsed; C3 passes
# iff EVERY run's AppExceptions gate is present AND Pass. A run with the gate MISSING is a real miss (not a skip).
# Helper to parse a sustain run's JSON once and cache it (C3 + C6 both consume the same outputs).
$script:parsedSustains = @()
foreach ($out in $sustainOutputs) {
    $p = $null
    if ($out) {
        # $out is ONE run's full output (string[] · Verify's stdout JSON report + any 2>&1 stderr/warning lines).
        # Verify emits a single JSON report object; extract it (first '{' … last '}') so interleaved non-JSON log
        # lines don't break ConvertFrom-Json (a raw `$joined | ConvertFrom-Json` fails the moment a warning line
        # is present in the capture).
        $joined = if ($out -is [array]) { $out -join "`n" } else { [string]$out }
        $braceStart = $joined.IndexOf('{'); $braceEnd = $joined.LastIndexOf('}')
        if ($braceStart -ge 0 -and $braceEnd -gt $braceStart) {
            try { $p = $joined.Substring($braceStart, $braceEnd - $braceStart + 1) | ConvertFrom-Json -ErrorAction Stop } catch { $p = $null }
        }
    }
    $script:parsedSustains += ,$p
}
$c3Pass = $false
$c3Details = @()
$c3AnyParsed = $false
$c3AllPass = $true
for ($si = 0; $si -lt $script:parsedSustains.Count; $si++) {
    $parsedRun = $script:parsedSustains[$si]
    if (-not $parsedRun) { $c3AllPass = $false; $c3Details += "run$($si+1): unparseable Verify output"; continue }
    $c3AnyParsed = $true
    $appExGate = $parsedRun.Gates.AppExceptions
    if ($appExGate) {
        $runPass = ($appExGate.Pass -eq $true -or $appExGate.Pass -eq 'true')
        if (-not $runPass) { $c3AllPass = $false; $c3Details += "run$($si+1): FAIL · $($appExGate.Detail)" }
    } else {
        $c3AllPass = $false; $c3Details += "run$($si+1): AppExceptions gate not present"
    }
}
# Pass ONLY if at least one run parsed AND every parsed run's gate passed (never a silent green on zero data).
$c3Pass = $c3AnyParsed -and $c3AllPass
$c3Detail = if ($c3Details.Count -gt 0) { ($c3Details -join ' · ') } elseif ($c3AnyParsed) { "AppExceptions=0 across all $($script:parsedSustains.Count) Sustain run(s)" } else { 'no parseable Verify output' }
$report.Conditions.C3_AppExceptions = @{ Pass = $c3Pass; Detail = $c3Detail }
if (-not $c3Pass) {
    $report.Blockers += "C3 · AppExceptions check failed: $c3Detail"
}

# ─── C4 · DLQ stable (count == 0) via Storage Table query ──────────────────────
$c4Pass = $false
$c4Detail = '-StorageAccount not provided · cannot query XdrIngestDlq Storage Table'
if ($StorageAccount -and $ResourceGroup) {
    try {
        $ctx = (Get-AzStorageAccount -ResourceGroupName $ResourceGroup -Name $StorageAccount -ErrorAction Stop).Context
        $tab = Get-AzStorageTable -Name 'XdrIngestDlq' -Context $ctx -ErrorAction SilentlyContinue
        if ($tab) {
            $rows = @(Get-AzTableRow -Table $tab.CloudTable -ErrorAction SilentlyContinue)
            $c4Pass = $rows.Count -eq 0
            $c4Detail = "DLQ row count=$($rows.Count)"
        } else {
            $c4Pass = $true   # missing table is acceptable for v0.1.0 (created on first DLQ write)
            $c4Detail = 'XdrIngestDlq table not yet created (no DLQ events) · acceptable'
        }
    } catch {
        $c4Detail = "Storage Table query failed: $($_.Exception.Message)"
    }
}
$report.Conditions.C4_DlqStable = @{ Pass = $c4Pass; Detail = $c4Detail }
if (-not $c4Pass) {
    if ($StorageAccount) { $report.Blockers += "C4 · DLQ check failed: $c4Detail" }
    else { $report.Advisories += "C4 · -StorageAccount not provided · DLQ check skipped" }
}

# ─── C5 · OpenCircuits == 0 via XdrCircuitState Storage Table ──────────────────
$c5Pass = $false
$c5Detail = '-StorageAccount not provided · cannot query XdrCircuitState Storage Table'
if ($StorageAccount -and $ResourceGroup) {
    try {
        $ctx = (Get-AzStorageAccount -ResourceGroupName $ResourceGroup -Name $StorageAccount -ErrorAction Stop).Context
        $tab = Get-AzStorageTable -Name 'XdrCircuitState' -Context $ctx -ErrorAction SilentlyContinue
        if ($tab) {
            $rows = @(Get-AzTableRow -Table $tab.CloudTable -ErrorAction SilentlyContinue)
            $openRows = @($rows | Where-Object { $_.state -eq 'Open' -or $_.State -eq 'Open' })
            $c5Pass = $openRows.Count -eq 0
            $c5Detail = "circuit rows=$($rows.Count) · open=$($openRows.Count)"
        } else {
            $c5Pass = $true
            $c5Detail = 'XdrCircuitState table not yet created · acceptable'
        }
    } catch {
        $c5Detail = "Storage Table query failed: $($_.Exception.Message)"
    }
}
$report.Conditions.C5_OpenCircuits = @{ Pass = $c5Pass; Detail = $c5Detail }
if (-not $c5Pass) {
    if ($StorageAccount) { $report.Blockers += "C5 · OpenCircuits check failed: $c5Detail" }
    else { $report.Advisories += "C5 · -StorageAccount not provided · circuit check skipped" }
}

# ─── C6 · D8 data-plane-context sub-gates all PASS across ALL Sustain windows ──────
# The keystone "actual events per requirements" check (operator binding 2026-06-02 PM).
# All D8 sub-gates (D8c · D8f · D8g · D8h) MUST be Pass=true in EVERY Sustain window.
#
# V-M5 (2026-06-18 · coupled to Verify-DeployedConnector V-M4) — TWO fixes:
#   (1) GATE-KEY REGEX: under -AllOps the per-op gates are tagged "D8f[<opKey>]" / "D8g[<opKey>]" / … (one entry
#       per Operation · GateIds disambiguated so they don't collide). The old code read the UN-SUFFIXED fixed keys
#       ($parsed.Gates.D8f) → under -AllOps that key is ABSENT → marked MISSING → C6 always-FAILED (or, worse, had
#       it treated missing-as-skip, it would have FALSE-PASSED while every op's real D8f verdict went unread). We
#       now match every gate whose name is D8c/D8f/D8g/D8h with an OPTIONAL "[...]" op suffix via the regex
#       ^D8[cfgh](\[.*\])?$ and require ALL matching gates to PASS (so all N ops' per-op sub-gates are enforced).
#       This is consistent with how C2 forwards -AllOps to each Sustain run (it loops the per-op gates over every op).
#   (2) ALL-RUNS AGGREGATE: evaluate EVERY Sustain run's JSON (not just the final run) — a D8 fail in ANY
#       counted window fails C6 (exit codes alone, which C2 counts, would not surface a D8-only fail in an earlier
#       window). Also honest on emptiness: C6 passes only if ≥1 run parsed AND carried ≥1 matching D8 gate that
#       ALL passed — a run with NO matching D8 gate (e.g. -Category not forwarded → the per-op gates skipped) is a
#       real miss, never a silent green.
$c6Pass = $false
$c6Detail = 'unable to parse Verify output'
$d8KeyRegex = '^D8[cfgh](\[.*\])?$'
$c6Details = @()
$c6AllPass = $true
$c6AnyD8Gate = $false
for ($si = 0; $si -lt $script:parsedSustains.Count; $si++) {
    $parsedRun = $script:parsedSustains[$si]
    if (-not $parsedRun) { $c6AllPass = $false; $c6Details += "run$($si+1): unparseable Verify output"; continue }
    # Gates is an ordered object (from ConvertTo-Json) → enumerate its NoteProperty members by name.
    $gateNames = @()
    if ($parsedRun.PSObject.Properties['Gates'] -and $parsedRun.Gates) {
        $gateNames = @($parsedRun.Gates.PSObject.Properties.Name)
    }
    $d8Names = @($gateNames | Where-Object { $_ -match $d8KeyRegex })
    if ($d8Names.Count -eq 0) {
        # No D8 sub-gate present in this run → the keystone was NOT evaluated → a real miss (not a skip-to-green).
        $c6AllPass = $false
        $c6Details += "run$($si+1): NO D8 sub-gate present (D8c/D8f/D8g/D8h · suffixed or not) — keystone not evaluated"
        continue
    }
    $c6AnyD8Gate = $true
    foreach ($gn in $d8Names) {
        $gate = $parsedRun.Gates.$gn
        $gPass = $gate -and ($gate.Pass -eq $true -or $gate.Pass -eq 'true')
        if (-not $gPass) {
            $c6AllPass = $false
            $det = if ($gate) { $gate.Detail } else { 'gate object null' }
            $c6Details += "run$($si+1): $gn=FAIL · $det"
        }
    }
}
# Pass ONLY if at least one run carried D8 gates AND every matching gate in every parsed run passed.
$c6Pass = $c6AnyD8Gate -and $c6AllPass
$c6Detail = if ($c6Details.Count -gt 0) { ($c6Details -join ' · ') } elseif ($c6AnyD8Gate) { "all D8c/D8f/D8g/D8h sub-gates PASS across all $($script:parsedSustains.Count) Sustain run(s) (matched by /$d8KeyRegex/ · -AllOps-aware)" } else { 'no D8 sub-gates found in any Sustain run' }
$report.Conditions.C6_DataPlaneContext = @{ Pass = $c6Pass; Detail = $c6Detail }
if (-not $c6Pass) {
    $report.Blockers += "C6 · D8 data-plane-context FAIL: $c6Detail"
}

# ─── Verdict ───────────────────────────────────────────────────────────────────
$allConditionsPass = ($report.Conditions.Values | Where-Object { $_.Pass -ne $true }).Count -eq 0
if ($allConditionsPass -and $report.Blockers.Count -eq 0) {
    $report.Verdict = 'GA-CANDIDATE · awaiting operator confirmation (C10)'
    $exitCode = 0
} elseif ($report.Conditions.C2_SustainPasses.Passes -lt $MinConsecutiveSustains -and $report.Blockers.Count -le 1) {
    $report.Verdict = "INSUFFICIENT-DATA · only $($report.Conditions.C2_SustainPasses.Passes)/$MinConsecutiveSustains sustain windows · re-run after more elapsed time"
    $exitCode = 1
} else {
    $report.Verdict = 'BLOCKING-FAIL · NOT GA-ready · operator should NOT issue GA word'
    $exitCode = 2
}

$report.CompletedUtc = ([DateTime]::UtcNow).ToString('o')

# ─── Output ────────────────────────────────────────────────────────────────────
switch ($OutputFormat) {
    'Json' { $report | ConvertTo-Json -Depth 6 }
    'Markdown' {
        Write-Host '# Test-GaReadiness · Phase F GA gate'
        Write-Host ''
        Write-Host "**Workspace**: $WorkspaceId"
        Write-Host "**MinSustains**: $MinConsecutiveSustains | **SinceHours**: $SinceHours"
        Write-Host ''
        Write-Host '| # | Condition | Pass | Detail |'
        Write-Host '|---|---|---|---|'
        foreach ($key in $report.Conditions.Keys) {
            $c = $report.Conditions[$key]
            $sym = if ($c.Pass) { 'PASS' } else { 'FAIL' }
            Write-Host "| $key | $key | $sym | $($c.Detail) |"
        }
        Write-Host ''
        Write-Host "**Verdict**: $($report.Verdict)"
        if ($report.Blockers.Count -gt 0) {
            Write-Host ''
            Write-Host '## Blockers'
            $report.Blockers | ForEach-Object { Write-Host "- $_" }
        }
        if ($report.Advisories.Count -gt 0) {
            Write-Host ''
            Write-Host '## Advisories'
            $report.Advisories | ForEach-Object { Write-Host "- $_" }
        }
    }
    default {
        Write-Host ''
        Write-Host '======================================================================'
        Write-Host 'Test-GaReadiness · Phase F GA gate (plan §18.4 · 9 auto + 1 operator)'
        Write-Host '======================================================================'
        foreach ($key in $report.Conditions.Keys) {
            $c = $report.Conditions[$key]
            $sym = if ($c.Pass) { 'PASS' } else { 'FAIL' }
            Write-Host ("  {0,-6} {1,-25} {2}" -f $sym, $key, $c.Detail)
        }
        Write-Host '----------------------------------------------------------------------'
        Write-Host "Verdict: $($report.Verdict)"
        if ($report.Blockers.Count -gt 0) {
            Write-Host '  Blockers:'
            $report.Blockers | ForEach-Object { Write-Host "    - $_" }
        }
        if ($report.Advisories.Count -gt 0) {
            Write-Host '  Advisories:'
            $report.Advisories | ForEach-Object { Write-Host "    - $_" }
        }
        Write-Host ''
        if ($exitCode -eq 0) {
            Write-Host '  ALL 9 AUTO-CONDITIONS GREEN'
            Write-Host '  Present this report to operator · await "GA" word per plan §F.3 / §13 decision-point 3'
            Write-Host '  On "GA": git tag v0.1.0 · gh release create v0.1.0 --prerelease=false (NOT v0.1.0-pre)'
        } elseif ($exitCode -eq 1) {
            Write-Host '  INSUFFICIENT-DATA · re-run after more sustain windows have accumulated'
        } else {
            Write-Host '  BLOCKING-FAIL · operator should NOT issue GA word until blockers cleared'
        }
    }
}

exit $exitCode
