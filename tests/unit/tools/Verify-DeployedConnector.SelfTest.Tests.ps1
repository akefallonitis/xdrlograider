#Requires -Version 7.4
# F-A self-test (plan §18 honesty bar · "provably able to fail"). Every gate in tools/Verify-DeployedConnector.ps1
# factors its decision into a PURE function Test-XdrGate_<id>(Row[,...]) → @{ Pass; Inconclusive; Detail }.
# This suite proves each pure function is HONEST without any live `az`:
#   • a known-BAD row   → Pass=$false   (the gate can fail)
#   • a known-GOOD row  → Pass=$true    (the gate can pass)
#   • an empty/null row → Inconclusive=$true (presence-of-DATA gates) OR a hard Pass=$false
#                          (presence-of-SIGNAL gates: row absence == the thing never landed == real fail),
#                          NEVER a silent green for a gate whose logic would otherwise pass on zero rows.
# A gate with no failing self-test is not allowed — each gate below has all three assertions.
#
# The tool is DOT-SOURCED with $env:XDRLR_VERIFY_DOTSOURCE_ONLY=1 so ONLY its function definitions load
# (the live-az execution body returns early). Rows are built as hashtables with STRING values to mirror
# exactly what `az monitor log-analytics query --output json | ConvertFrom-Json -AsHashtable` yields
# (KQL bool cols arrive as "True"/"False"; numeric cols as "34"). Runs fully offline in CI Tier-1.

Set-StrictMode -Version Latest

BeforeAll {
    $script:Tool = (Resolve-Path "$PSScriptRoot/../../../tools/Verify-DeployedConnector.ps1").Path
    # Sentinel: load functions only · skip the live-az body (returns, does NOT exit — Pester host survives).
    $env:XDRLR_VERIFY_DOTSOURCE_ONLY = '1'
    . $script:Tool -WorkspaceId '00000000-0000-0000-0000-000000000000'

    # Row factory · a hashtable with the named columns each gate's KQL `project`/`summarize` emits, values
    # as STRINGS (the az JSON shape). $null is passed directly to model an empty/zero-row window.
    function New-Row { param([hashtable]$Cells) return $Cells }
}

AfterAll { Remove-Item Env:\XDRLR_VERIFY_DOTSOURCE_ONLY -ErrorAction SilentlyContinue }

# ── Shared coercion helpers (the foundation every gate relies on) ────────────────────────────────
Describe 'F-A · shared coercion helpers' {
    It 'ConvertTo-XdrBool treats the az string "True" as $true and "False" as $false' {
        ConvertTo-XdrBool 'True'  | Should -BeTrue
        ConvertTo-XdrBool 'true'  | Should -BeTrue
        ConvertTo-XdrBool 'False' | Should -BeFalse
        ConvertTo-XdrBool $true   | Should -BeTrue
        ConvertTo-XdrBool $null   | Should -BeFalse
    }
    It 'ConvertTo-XdrInt parses the az string "34" and defaults safely on junk/null' {
        ConvertTo-XdrInt '34'   | Should -Be 34
        ConvertTo-XdrInt 34     | Should -Be 34
        ConvertTo-XdrInt $null  | Should -Be 0
        ConvertTo-XdrInt 'x'    | Should -Be 0
        (ConvertTo-XdrInt $null -Default 7) | Should -Be 7
    }
    It 'Get-XdrRowValue reads by NAME (indexer) and is StrictMode-safe on missing keys / null row' {
        (Get-XdrRowValue @{ A = '1' } 'A')       | Should -Be '1'
        (Get-XdrRowValue @{ A = '1' } 'Missing') | Should -BeNullOrEmpty
        (Get-XdrRowValue $null 'A')              | Should -BeNullOrEmpty
    }
}

# ── Add-XdrGateResult verdict-bucket routing (2026-07-04) · an ADVISORY gate's INCONCLUSIVE must be NON-blocking ─────
Describe 'F-A · Add-XdrGateResult routes an ADVISORY inconclusive to Advisories (non-blocking · Reauth not-exercised)' {
    It 'advisory + inconclusive -> Advisories (NOT Inconclusives) · non-advisory inconclusive still blocks (M1)' {
        # An ADVISORY gate (its real proof is elsewhere · e.g. Reauth self-heal proven by the auth-loss inject test #3b)
        # that is inconclusive over a natural window (triggered=0 · not-exercised) must route to Advisories so the verdict
        # is GREEN-WITH-ADVISORIES (exit 0), NOT GREEN-WITH-INCONCLUSIVES (exit 1). A NON-advisory inconclusive still blocks.
        $results = @{ Gates=@{}; Inconclusives=@(); Advisories=@(); Blockers=@() }
        Add-XdrGateResult -GateId 'Reauth' -Description 'x' -Pass $false -Inconclusive $true -Advisory $true
        $results.Advisories.Count    | Should -Be 1
        $results.Inconclusives.Count | Should -Be 0
        $results = @{ Gates=@{}; Inconclusives=@(); Advisories=@(); Blockers=@() }
        Add-XdrGateResult -GateId 'D1' -Description 'x' -Pass $false -Inconclusive $true -Advisory $false
        $results.Inconclusives.Count | Should -Be 1   # M1 · a non-advisory inconclusive is NOT softened
        $results.Advisories.Count    | Should -Be 0
        $results = @{ Gates=@{}; Inconclusives=@(); Advisories=@(); Blockers=@() }
        Add-XdrGateResult -GateId 'MinRows' -Description 'x' -Pass $false -Advisory $false
        $results.Blockers.Count      | Should -Be 1   # M1 · a non-advisory FAIL still blocks
    }
}

# ── -AllOps per-Operation loop · the helper that enumerates the loop domain (offline-provable) ──────
Describe 'F-A · poll-liveness window spans a WIDE recent span (Get-XdrPollLivenessClause)' {
    # Regression guard for the 2026-06-23 GA-blocker + its 2026-07-01 sampling variant: a FIXED ago(2h) liveness window
    # false-FAILed Operations cap-absent ops (GetEffectiveTenantGroup/ListTenantGroups/GetWorkloadStatus/ListAssignments/
    # GetConfiguration · 6h cadence) whose terminal Capability.OpUnavailable was >2h old / AppInsights-sampled by re-verify
    # time. The fallback must span a WIDE span (72h · captures ~a dozen+ events for a 6h op → survives sampling), cadence/
    # mode-independent, INDEPENDENT of the cold rows window. "Provably able to fail": a return to the narrow 2h slice fails.
    It 'with a deploy floor → the clause covers the floor AND keeps a wide fallback (OR-widened)' {
        $c = Get-XdrPollLivenessClause -DeployedSinceUtc '2026-06-23T15:28:00Z'
        $c | Should -Match 'datetime\(2026-06-23T15:28:00Z\)'   # anchored at cutover → an op's early terminal poll is found
        $c | Should -Match 'ago\(72h\)'                          # OR'd with the WIDE fallback (long-cadence + sampling tolerance)
    }
    It 'PROVABLY FAILS a regression to the narrow ago(2h): a floor run must NOT collapse to a bare recent slice' {
        $c = Get-XdrPollLivenessClause -DeployedSinceUtc '2026-06-23T15:28:00Z'
        $c | Should -Not -Be 'TimeGenerated >= ago(2h)'         # the exact bug that GA-blocked Operations cap-absent ops
        $c | Should -Not -Be 'TimeGenerated >= ago(72h)'        # a floor run must ALSO carry the datetime anchor, not just the fallback
    }
    It 'no deploy floor → falls back to the WIDE ago(72h) window (standalone / recent-deploy · survives sampling)' {
        Get-XdrPollLivenessClause -DeployedSinceUtc ''    | Should -Be 'TimeGenerated >= ago(72h)'
        Get-XdrPollLivenessClause -DeployedSinceUtc $null | Should -Be 'TimeGenerated >= ago(72h)'
    }
}

Describe 'F-A · -AllOps per-Operation loop domain (Get-XdrManifestOperationKeys)' {
    It 'returns every Operation key for the Defender/Operations pilot manifest (>1 · the loop has work)' {
        $keys = @(Get-XdrManifestOperationKeys -Portal 'Defender' -Category 'Operations')
        $keys.Count | Should -BeGreaterThan 1
        $keys | Should -Contain 'GetHistory'
        $keys | Should -Contain 'GetTenantContext'
    }
    It 'returns an EMPTY array (not throw) for an unresolvable Portal/Category' {
        @(Get-XdrManifestOperationKeys -Portal 'Defender' -Category 'NoSuchCategory') | Should -BeNullOrEmpty
        @(Get-XdrManifestOperationKeys -Portal '' -Category '') | Should -BeNullOrEmpty
    }
    It 'the tool declares the -AllOps switch (the per-Op gates loop over the domain · GateIds tagged "[op]")' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Tool, [ref]$null, [ref]$null)
        $names = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $names | Should -Contain 'AllOps'
    }
}

# ── Presence-of-SIGNAL gates · a row is EXPECTED; its ABSENCE is the real negative → hard Pass=$false
#    (NOT inconclusive). bad row → fail · good row → pass · null → fail. ────────────────────────────
Describe 'F-A · presence-of-signal gates (absence == hard FAIL)' {
    It 'Boot: bad→fail · good→pass · null→fail (not inconclusive)' {
        (Test-XdrGate_Boot -Row (New-Row @{ Pass = 'False'; Count = '0';  MostRecent = ''; LatestCommit = '' })).Pass | Should -BeFalse
        (Test-XdrGate_Boot -Row (New-Row @{ Pass = 'True';  Count = '12'; MostRecent = '2026-06-05T00:00:00Z'; LatestCommit = 'abc123' })).Pass | Should -BeTrue
        $n = Test-XdrGate_Boot -Row $null
        $n.Pass         | Should -BeFalse
        $n.Inconclusive | Should -BeFalse
    }
    It 'Boot: steady-state (BootLines=0) → vacuous PASS; cold-start in window (BootLines>0) but no probe → FAIL; -1 default → legacy strict' {
        # no cold-start in window (a checkpoint-reset re-prove does NOT restart the FA) → vacuously OK (SHA proven by the version stage)
        (Test-XdrGate_Boot -Row (New-Row @{ Pass = 'False'; Count = '0'; MostRecent = ''; LatestCommit = '' }) -BootLines 0).Pass | Should -BeTrue
        (Test-XdrGate_Boot -Row $null -BootLines 0).Pass | Should -BeTrue
        # a REAL cold-start in window (BootLines>0) but the probe is absent (count=0) → still FAIL (broken boot)
        (Test-XdrGate_Boot -Row (New-Row @{ Pass = 'False'; Count = '0'; MostRecent = ''; LatestCommit = '' }) -BootLines 3).Pass | Should -BeFalse
        # cold-start WITH probe → PASS
        (Test-XdrGate_Boot -Row (New-Row @{ Pass = 'True'; Count = '4'; MostRecent = '2026-06-20T22:17:20Z'; LatestCommit = 'abc' }) -BootLines 4).Pass | Should -BeTrue
        # not supplied (-1 default) → legacy strict (count=0 → FAIL · back-compat with non-AllOps / older callers)
        (Test-XdrGate_Boot -Row (New-Row @{ Pass = 'False'; Count = '0'; MostRecent = ''; LatestCommit = '' })).Pass | Should -BeFalse
    }
    It 'D0: in-window boot w/ module-load OR Legion error→fail · clean boot→pass · no-boot-in-window (null OR BootLines=0)→pass (steady-state · liveness via D3)' {
        # boot IN window with a module-load failure → FAIL
        (Test-XdrGate_D0 -Row (New-Row @{ Pass = 'False'; ModuleLoadFailures = '1'; BootLines = '3'; LegionErr = '0'; LastBoot = '' })).Pass | Should -BeFalse
        # boot IN window with a Legion managed-dependency error → FAIL (even with 0 module-load failures)
        (Test-XdrGate_D0 -Row (New-Row @{ Pass = 'False'; ModuleLoadFailures = '0'; BootLines = '2'; LegionErr = '1'; LastBoot = '' })).Pass | Should -BeFalse
        # clean boot IN window → PASS
        (Test-XdrGate_D0 -Row (New-Row @{ Pass = 'True';  ModuleLoadFailures = '0'; BootLines = '3'; LegionErr = '0'; LastBoot = '2026-06-05T00:00:00Z' })).Pass | Should -BeTrue
        # GATE-LEARNING (2026-06-17): NO cold-start in window is the steady-state norm → module-load health
        # vacuously OK → PASS (this was the old false-fail). Both a $null row and a BootLines=0 row.
        $n = Test-XdrGate_D0 -Row $null
        $n.Pass | Should -BeTrue; $n.Inconclusive | Should -BeFalse
        (Test-XdrGate_D0 -Row (New-Row @{ Pass = 'False'; ModuleLoadFailures = '0'; BootLines = '0'; LegionErr = '0'; LastBoot = '' })).Pass | Should -BeTrue
    }
    It 'D4 recovery-aware: unrecovered-fail-portal>0 → fail · recovered transient → pass · zero-succeeded → fail · null → fail' {
        # a portal that NEVER succeeded / ended in a Failed (UnrecoveredFailPortals>0) = real discovery defect → FAIL
        (Test-XdrGate_D4 -Row (New-Row @{ Total = '3'; Succeeded = '1'; Failed = '2'; UnrecoveredFailPortals = '1'; MostRecent = '' })).Pass | Should -BeFalse
        # a RECOVERED transient (single-flight contention · a later Succeeded after the Failed → UnrecoveredFailPortals=0) → PASS
        (Test-XdrGate_D4 -Row (New-Row @{ Total = '51'; Succeeded = '50'; Failed = '1'; UnrecoveredFailPortals = '0'; MostRecent = '2026-07-01T07:45:00Z' })).Pass | Should -BeTrue
        # clean (no failures) → PASS
        (Test-XdrGate_D4 -Row (New-Row @{ Total = '2'; Succeeded = '2'; Failed = '0'; UnrecoveredFailPortals = '0'; MostRecent = '2026-06-05T00:00:00Z' })).Pass | Should -BeTrue
        # zero Succeeded (R3 never succeeded this window) → FAIL even with UnrecoveredFailPortals=0
        (Test-XdrGate_D4 -Row (New-Row @{ Total = '0'; Succeeded = '0'; Failed = '0'; UnrecoveredFailPortals = '0'; MostRecent = '' })).Pass | Should -BeFalse
        $n = Test-XdrGate_D4 -Row $null
        $n.Pass | Should -BeFalse; $n.Inconclusive | Should -BeFalse
    }
    It 'MinRows: bad (0 rows)→fail · good (>=1)→pass · null→fail (this gate exists to catch zero-rows)' {
        (Test-XdrGate_MinRows -Row (New-Row @{ Count = '0' })).Pass | Should -BeFalse
        (Test-XdrGate_MinRows -Row (New-Row @{ Count = '5' })).Pass | Should -BeTrue
        $n = Test-XdrGate_MinRows -Row $null
        $n.Pass | Should -BeFalse; $n.Inconclusive | Should -BeFalse
    }
}

# ── Presence-of-DATA gates · run against the workspace table. An empty table can't prove a per-row
#    property → INCONCLUSIVE (never a silent green). bad row → fail · good row → pass · empty/null → INCO.
Describe 'F-A · row-population gates (empty window == INCONCLUSIVE)' {
    It 'D2 (no empty rows): bad→fail · good→pass · empty→INCO · null→INCO' {
        (Test-XdrGate_D2 -Row (New-Row @{ Pass = 'False'; Empty = '3'; Total = '34' })).Pass | Should -BeFalse
        (Test-XdrGate_D2 -Row (New-Row @{ Pass = 'True';  Empty = '0'; Total = '34' })).Pass | Should -BeTrue
        (Test-XdrGate_D2 -Row (New-Row @{ Pass = 'False'; Empty = '0'; Total = '0'  })).Inconclusive | Should -BeTrue
        (Test-XdrGate_D2 -Row $null).Inconclusive | Should -BeTrue
        (Test-XdrGate_D2 -Row $null).Pass         | Should -BeFalse
    }
    It 'D6 (RawJson valid): bad→fail · good→pass · empty→INCO · null→INCO' {
        (Test-XdrGate_D6 -Row (New-Row @{ Pass = 'False'; Invalid = '2'; Total = '10' })).Pass | Should -BeFalse
        (Test-XdrGate_D6 -Row (New-Row @{ Pass = 'True';  Invalid = '0'; Total = '10' })).Pass | Should -BeTrue
        (Test-XdrGate_D6 -Row (New-Row @{ Pass = 'False'; Invalid = '0'; Total = '0'  })).Inconclusive | Should -BeTrue
        (Test-XdrGate_D6 -Row $null).Inconclusive | Should -BeTrue
    }
    It 'G1b · D2/D6 vacuous-PASS on a 0-row LEGIT-NO-DATA-PROVEN op; unproven-0 stays INCONCLUSIVE' {
        # proven-empty (LegitNoDataProven=$true): 0 rows ⇒ vacuously clean/valid ⇒ PASS (not INCO · clean-GREEN re-prove)
        (Test-XdrGate_D2 -Row (New-Row @{ Pass = 'False'; Empty = '0'; Total = '0' }) -LegitNoDataProven $true).Pass | Should -BeTrue
        (Test-XdrGate_D2 -Row (New-Row @{ Pass = 'False'; Empty = '0'; Total = '0' }) -LegitNoDataProven $true).Inconclusive | Should -BeFalse
        (Test-XdrGate_D6 -Row (New-Row @{ Pass = 'False'; Invalid = '0'; Total = '0' }) -LegitNoDataProven $true).Pass | Should -BeTrue
        # unproven-0 (explicit $false AND the back-compat default): stays INCONCLUSIVE — never a silent green
        (Test-XdrGate_D2 -Row (New-Row @{ Pass = 'False'; Empty = '0'; Total = '0' }) -LegitNoDataProven $false).Inconclusive | Should -BeTrue
        (Test-XdrGate_D6 -Row (New-Row @{ Pass = 'False'; Invalid = '0'; Total = '0' })).Inconclusive | Should -BeTrue
        # proven-empty must NOT mask a real bad row (total>0 with empties still FAILS)
        (Test-XdrGate_D2 -Row (New-Row @{ Pass = 'False'; Empty = '3'; Total = '34' }) -LegitNoDataProven $true).Pass | Should -BeFalse
    }
    It 'P0-2 · all 7 zero-row gates vacuous-PASS on a LEGIT-NO-DATA-PROVEN op; unproven-0 stays INCONCLUSIVE (Sustain/GA path)' {
        # a 0-row op proven legit-empty has nothing to violate ⇒ vacuous-PASS in EVERY window (incl Sustain, where MinRows
        # is absent — $legitNoData is now computed at the loop top, not piggybacked on MinRows window-membership).
        (Test-XdrGate_CorrelationId       -Row (New-Row @{ Total = '0' })                              -LegitNoDataProven $true).Pass | Should -BeTrue
        (Test-XdrGate_D8c                 -Row (New-Row @{ Total = '0' })                              -LegitNoDataProven $true).Pass | Should -BeTrue
        (Test-XdrGate_D8g                 -Row (New-Row @{ Total = '0' }) -Columns @('foo_x')          -LegitNoDataProven $true).Pass | Should -BeTrue
        (Test-XdrGate_D8h                 -Row (New-Row @{ Total = '0' }) -Columns @('barJson')        -LegitNoDataProven $true).Pass | Should -BeTrue
        (Test-XdrGate_ExactlyOnce         -Row (New-Row @{ Rows = '0' }) -NaturalKey 'k'               -LegitNoDataProven $true).Pass | Should -BeTrue
        (Test-XdrGate_ExactlyOncePerCycle -Row (New-Row @{ Cycles = '0'; TotalRows = '0' }) -NaturalKey 'k' -Mode 'SNAPSHOT' -LegitNoDataProven $true).Pass | Should -BeTrue
        (Test-XdrGate_SnapshotNoDupAccum  -Row (New-Row @{ Total = '0'; Distinct = '0'; Cycles = '0' }) -Key 'k'            -LegitNoDataProven $true).Pass | Should -BeTrue
        # unproven-0 (back-compat default $false): every one stays INCONCLUSIVE — never a silent green
        (Test-XdrGate_CorrelationId       -Row (New-Row @{ Total = '0' })).Inconclusive | Should -BeTrue
        (Test-XdrGate_D8c                 -Row (New-Row @{ Total = '0' })).Inconclusive | Should -BeTrue
        (Test-XdrGate_D8g                 -Row (New-Row @{ Total = '0' }) -Columns @('foo_x')).Inconclusive | Should -BeTrue
        (Test-XdrGate_D8h                 -Row (New-Row @{ Total = '0' }) -Columns @('barJson')).Inconclusive | Should -BeTrue
        (Test-XdrGate_ExactlyOnce         -Row (New-Row @{ Rows = '0' }) -NaturalKey 'k').Inconclusive | Should -BeTrue
        (Test-XdrGate_ExactlyOncePerCycle -Row (New-Row @{ Cycles = '0'; TotalRows = '0' }) -NaturalKey 'k').Inconclusive | Should -BeTrue
        (Test-XdrGate_SnapshotNoDupAccum  -Row (New-Row @{ Total = '0'; Distinct = '0'; Cycles = '0' }) -Key 'k').Inconclusive | Should -BeTrue
    }
    It 'CorrelationId: bad→fail · good→pass · empty→INCO · null→INCO' {
        (Test-XdrGate_CorrelationId -Row (New-Row @{ Pass = 'False'; NullCount = '4'; Total = '34' })).Pass | Should -BeFalse
        (Test-XdrGate_CorrelationId -Row (New-Row @{ Pass = 'True';  NullCount = '0'; Total = '34' })).Pass | Should -BeTrue
        (Test-XdrGate_CorrelationId -Row (New-Row @{ Pass = 'False'; NullCount = '0'; Total = '0'  })).Inconclusive | Should -BeTrue
        (Test-XdrGate_CorrelationId -Row $null).Inconclusive | Should -BeTrue
    }
    It 'D8c (5 envelope cols populated): bad→fail · good→pass · empty→INCO · null→INCO' {
        $bad  = New-Row @{ Pass = 'False'; Total = '10'; OperationKey_pop = '10'; Portal_pop = '8'; Category_pop = '10'; Operation_pop = '10'; CorrelationId_pop = '10' }
        $good = New-Row @{ Pass = 'True';  Total = '10'; OperationKey_pop = '10'; Portal_pop = '10'; Category_pop = '10'; Operation_pop = '10'; CorrelationId_pop = '10' }
        (Test-XdrGate_D8c -Row $bad).Pass  | Should -BeFalse
        (Test-XdrGate_D8c -Row $good).Pass | Should -BeTrue
        (Test-XdrGate_D8c -Row (New-Row @{ Pass = 'False'; Total = '0'; OperationKey_pop = '0'; Portal_pop = '0'; Category_pop = '0'; Operation_pop = '0'; CorrelationId_pop = '0' })).Inconclusive | Should -BeTrue
        (Test-XdrGate_D8c -Row $null).Inconclusive | Should -BeTrue
    }
}

# ── Event-reconcile / cadence / auth gates · summarise AppEvents|AppTraces; a silent window is
#    INCONCLUSIVE (a property of events that did not occur is unprovable). bad→fail · good→pass · empty→INCO.
Describe 'F-A · event-stream gates (silent window == INCONCLUSIVE)' {
    It 'D1 (event-row reconcile): bad→fail · good→pass · empty→INCO · null→INCO' {
        (Test-XdrGate_D1 -Row (New-Row @{ Pass = 'False'; Mismatched = '2'; Total = '9' })).Pass | Should -BeFalse
        (Test-XdrGate_D1 -Row (New-Row @{ Pass = 'True';  Mismatched = '0'; Total = '9' })).Pass | Should -BeTrue
        (Test-XdrGate_D1 -Row (New-Row @{ Pass = 'False'; Mismatched = '0'; Total = '0' })).Inconclusive | Should -BeTrue
        (Test-XdrGate_D1 -Row $null).Inconclusive | Should -BeTrue
    }
    It 'D3 (1 telemetry per poll): bad→fail · good→pass · empty→INCO · null→INCO' {
        (Test-XdrGate_D3 -Row (New-Row @{ Pass = 'False'; Bad = '1'; Total = '5' })).Pass | Should -BeFalse
        (Test-XdrGate_D3 -Row (New-Row @{ Pass = 'True';  Bad = '0'; Total = '5' })).Pass | Should -BeTrue
        (Test-XdrGate_D3 -Row (New-Row @{ Pass = 'False'; Bad = '0'; Total = '0' })).Inconclusive | Should -BeTrue
        (Test-XdrGate_D3 -Row $null).Inconclusive | Should -BeTrue
    }
    It 'D7 (cadence honored): bad→fail · good→pass · empty(<2 fires)→INCO · null→INCO' {
        (Test-XdrGate_D7 -Row (New-Row @{ Pass = 'False'; Bad = '1'; Total = '2' })).Pass | Should -BeFalse
        (Test-XdrGate_D7 -Row (New-Row @{ Pass = 'True';  Bad = '0'; Total = '2' })).Pass | Should -BeTrue
        (Test-XdrGate_D7 -Row (New-Row @{ Pass = 'False'; Bad = '0'; Total = '0' })).Inconclusive | Should -BeTrue
        (Test-XdrGate_D7 -Row $null).Inconclusive | Should -BeTrue
    }
    It 'D8 (auth chain healthy): bad(all-zero tiers)→fail/INCO · good→pass · null→INCO' {
        # A zeros row means no tier seated a session → not a pass; absence is indeterminate → INCO.
        $zero = Test-XdrGate_D8 -Row (New-Row @{ Pass = 'False'; T1 = '0'; T2 = '0'; T3 = '0' })
        $zero.Pass         | Should -BeFalse
        $zero.Inconclusive | Should -BeTrue
        (Test-XdrGate_D8 -Row (New-Row @{ Pass = 'True'; T1 = '40'; T2 = '2'; T3 = '1' })).Pass | Should -BeTrue
        (Test-XdrGate_D8 -Row $null).Inconclusive | Should -BeTrue
    }
    It 'Reauth (self-heal): no-fire→INCO · every Triggered reaches Succeeded→pass · Triggered>Succeeded (unrecovered)→FAIL' {
        # Reauth fires ONLY on a live auth-loss → a quiet window is NOT a green (self-heal not exercised) → INCO.
        (Test-XdrGate_Reauth -Row $null).Inconclusive | Should -BeTrue
        (Test-XdrGate_Reauth -Row (New-Row @{ Pass = 'False'; Triggered = '0'; Succeeded = '0' })).Inconclusive | Should -BeTrue
        $ok = Test-XdrGate_Reauth -Row (New-Row @{ Pass = 'True'; Triggered = '2'; Succeeded = '2' })
        $ok.Pass | Should -BeTrue; $ok.Inconclusive | Should -BeFalse
        $bad = Test-XdrGate_Reauth -Row (New-Row @{ Pass = 'False'; Triggered = '3'; Succeeded = '1' })
        $bad.Pass | Should -BeFalse; $bad.Inconclusive | Should -BeFalse
        $bad.Detail | Should -Match 'unrecovered=2'
    }
}

# ── Circuit breaker · NO activity is the steady-state norm but is UNPROVABLE ("every Open closed" with
#    zero Opens → the "every Open closes" invariant is VACUOUSLY satisfied → PASS. An FA outage (which the old
#    INCONCLUSIVE guarded against) is already a BLOCKING fail via D3 (no terminals → exit 2) + AppExceptions, so the
#    D10 inconclusive was redundant outage-protection that only blocked HEALTHY quiet runs. bad→fail · good→pass ·
#    0/0→vacuous-PASS · null-row→INCO (genuine no-data / KQL issue).
Describe 'F-A · D10 circuit breaker (every Open closes · 0 opens = vacuously satisfied · outage gated by D3/AppExceptions)' {
    It 'bad (open!=close)→fail' {
        (Test-XdrGate_D10 -Row (New-Row @{ Pass = 'False'; Opens = '2'; Closes = '1' })).Pass | Should -BeFalse
    }
    It 'good (open==close, both>0)→pass' {
        (Test-XdrGate_D10 -Row (New-Row @{ Pass = 'True'; Opens = '2'; Closes = '2' })).Pass | Should -BeTrue
    }
    It 'no breaker activity (0/0)→vacuous PASS (healthy · invariant trivially holds · outage gated by D3 not D10)' {
        $z = Test-XdrGate_D10 -Row (New-Row @{ Pass = 'True'; Opens = '0'; Closes = '0' })
        $z.Pass         | Should -BeTrue
        $z.Inconclusive | Should -BeFalse
    }
    It 'null row→INCONCLUSIVE, not pass' {
        $n = Test-XdrGate_D10 -Row $null
        $n.Pass         | Should -BeFalse
        $n.Inconclusive | Should -BeTrue
    }
    # V-M3 · the prior-window stuck-open hole: 0 in-window opens/closes BUT a breaker still open (from before the window).
    It 'V-M3: 0/0 in-window + a currently-OPEN breaker (CurrentlyOpen>0)→FAIL (not vacuous pass · prior-window stuck-open)' {
        $d = Test-XdrGate_D10 -Row (New-Row @{ Pass = 'True'; Opens = '0'; Closes = '0' }) -CurrentlyOpen 1
        $d.Pass         | Should -BeFalse
        $d.Inconclusive | Should -BeFalse
        $d.Detail       | Should -Match 'currently OPEN'
    }
    It 'V-M3: 0/0 in-window + CurrentlyOpen=0→PASS (genuinely healthy · no breaker open now)' {
        $d = Test-XdrGate_D10 -Row (New-Row @{ Pass = 'True'; Opens = '0'; Closes = '0' }) -CurrentlyOpen 0
        $d.Pass         | Should -BeTrue
        $d.Inconclusive | Should -BeFalse
    }
    It 'V-M3: $CurrentlyOpen=$null (no live probe · back-compat) keeps the original vacuous PASS' {
        (Test-XdrGate_D10 -Row (New-Row @{ Pass = 'True'; Opens = '0'; Closes = '0' }) -CurrentlyOpen $null).Pass | Should -BeTrue
    }
    It 'V-M3: a normal in-window open==close still PASSES regardless of CurrentlyOpen=0 (the breaker re-closed)' {
        (Test-XdrGate_D10 -Row (New-Row @{ Pass = 'True'; Opens = '2'; Closes = '2' }) -CurrentlyOpen 0).Pass | Should -BeTrue
    }
}

# ── V-M3 · Breaker.SkippedOpen (a poll suppressed by an open breaker → zero new data · no Started/terminal →
#    invisible to D3/D7/MinRows). ADVISORY visibility gate (a self-healed transient must not block); a STUCK-open
#    breaker is the BLOCK caught by D10's CurrentlyOpen widening. bad→advisory-pass-with-detail · clean→pass · null→pass.
Describe 'V-M3 · Test-XdrGate_BreakerSkip (suppressed-poll visibility · advisory)' {
    It 'skips present (Count>0)→Pass=$true (ADVISORY) but the detail reports the count + ops (the data-stall made visible)' {
        $d = Test-XdrGate_BreakerSkip -Row (New-Row @{ Count = '6'; Ops = '2' })
        $d.Pass         | Should -BeTrue          # advisory · never hard-fails a self-healed transient
        $d.Inconclusive | Should -BeFalse
        $d.Detail       | Should -Match 'breakerSkips=6'
        $d.Detail       | Should -Match 'SUPPRESSED by an open breaker'
    }
    It 'no skips (Count=0)→PASS clean detail' {
        $d = Test-XdrGate_BreakerSkip -Row (New-Row @{ Count = '0'; Ops = '0' })
        $d.Pass   | Should -BeTrue
        $d.Detail | Should -Match 'breakerSkips=0'
    }
    It 'null row (no Breaker.SkippedOpen events in window)→PASS, not inconclusive' {
        $n = Test-XdrGate_BreakerSkip -Row $null
        $n.Pass         | Should -BeTrue
        $n.Inconclusive | Should -BeFalse
    }
}

# ── V-M2 · never-completing drain. An op whose arrival rate exceeds its per-cycle page budget emits
#    DrainComplete=false + CycleBudgetReached EVERY cycle and is permanently behind, yet D3/D7/MinRows stay green.
#    Gate asserts each op reached DrainComplete=true at least once. StuckOps>0 BLOCKS. bad→fail · good→pass · empty→INCO.
Describe 'V-M2 · Test-XdrGate_DrainStuck (never-completing drain · BLOCKING)' {
    It 'bad (an op never completed a drain: StuckOps>0)→FAIL (BLOCKING · permanent backlog)' {
        $d = Test-XdrGate_DrainStuck -Row (New-Row @{ Ops = '3'; StuckOps = '1'; StuckOpList = '["GetHistory"]' })
        $d.Pass         | Should -BeFalse
        $d.Inconclusive | Should -BeFalse
        $d.Detail       | Should -Match 'NEVER completed a drain'
        $d.Detail       | Should -Match 'GetHistory'
    }
    It 'good (every op completed a drain at least once: StuckOps=0)→pass' {
        $d = Test-XdrGate_DrainStuck -Row (New-Row @{ Ops = '3'; StuckOps = '0'; StuckOpList = '[]' })
        $d.Pass         | Should -BeTrue
        $d.Inconclusive | Should -BeFalse
    }
    It 'empty (Ops=0 · no Entry.Poll.Succeeded in window)→INCONCLUSIVE, NOT a vacuous pass (D3 covers no-poll liveness)' {
        $d = Test-XdrGate_DrainStuck -Row (New-Row @{ Ops = '0'; StuckOps = '0'; StuckOpList = '[]' })
        $d.Pass         | Should -BeFalse
        $d.Inconclusive | Should -BeTrue
    }
    It 'null row→INCONCLUSIVE, NOT pass' {
        $n = Test-XdrGate_DrainStuck -Row $null
        $n.Pass         | Should -BeFalse
        $n.Inconclusive | Should -BeTrue
    }
}

# ── m1 · capability-REGRESSION discriminator for the D8f/MinRows LEGIT-NO-DATA path. An op that goes
#    Capability.OpUnavailable yet WAS populated historically is a regression (license lapse / API deprecation),
#    not a never-licensed empty — ADVISORY. A first-seen-empty op or a Succeeded-empty op is NOT a regression.
Describe 'm1 · Get-XdrCapabilityRegressionVerdict (OpUnavailable transition for a previously-populated op)' {
    It 'regression (went OpUnavailable AND has historical rows)→Advisory=$true with a regression detail' {
        $v = Get-XdrCapabilityRegressionVerdict -WentUnavailable $true -HistoricalRows 1500
        $v.Advisory | Should -BeTrue
        $v.Detail   | Should -Match 'capability REGRESSION'
    }
    It 'never-licensed empty (went OpUnavailable but 0 historical rows)→NOT advisory (genuinely never had the capability)' {
        (Get-XdrCapabilityRegressionVerdict -WentUnavailable $true -HistoricalRows 0).Advisory | Should -BeFalse
    }
    It 'Succeeded-empty (did NOT go OpUnavailable · just empty)→NOT advisory even with historical rows (not a 403 transition)' {
        (Get-XdrCapabilityRegressionVerdict -WentUnavailable $false -HistoricalRows 9000).Advisory | Should -BeFalse
    }
    It 'string-coerces the historical count (az json strings) safely' {
        (Get-XdrCapabilityRegressionVerdict -WentUnavailable $true -HistoricalRows '42').Advisory | Should -BeTrue
        (Get-XdrCapabilityRegressionVerdict -WentUnavailable $true -HistoricalRows '0').Advisory  | Should -BeFalse
    }
}

# ── m4 · D8 T1-cached-dominance advisory over a STEADY-STATE window (a full re-auth EVERY cycle reads "healthy"
#    but burns the slow path). The Pass verdict is UNCHANGED (any tier seated → pass); only the Detail gains the note.
Describe 'm4 · D8 T1-dominance advisory (steady-state · cache regression surfaced, Pass unchanged)' {
    It 'T1 NOT dominant in steady-state (T1<=max(T2,T3))→Pass still true BUT detail carries the advisory note' {
        $d = Test-XdrGate_D8 -Row (New-Row @{ Pass = 'True'; T1 = '1'; T2 = '0'; T3 = '40' }) -SteadyState $true
        $d.Pass   | Should -BeTrue                     # Pass semantics unchanged (a tier DID seat a session)
        $d.Detail | Should -Match 'T1 \(cached\) is NOT dominant'
    }
    It 'T1 dominant in steady-state→no advisory note (healthy cache reuse)' {
        $d = Test-XdrGate_D8 -Row (New-Row @{ Pass = 'True'; T1 = '40'; T2 = '1'; T3 = '1' }) -SteadyState $true
        $d.Pass   | Should -BeTrue
        $d.Detail | Should -Not -Match 'NOT dominant'
    }
    It 'NOT steady-state (Boot/Cold · default $SteadyState=$false): T3-heavy is expected → no advisory note' {
        $d = Test-XdrGate_D8 -Row (New-Row @{ Pass = 'True'; T1 = '0'; T2 = '0'; T3 = '5' })
        $d.Pass   | Should -BeTrue
        $d.Detail | Should -Not -Match 'NOT dominant'
    }
    It 'still INCONCLUSIVE on an all-zero-tier row even in steady-state (no tier seated · advisory note not reached)' {
        (Test-XdrGate_D8 -Row (New-Row @{ Pass = 'False'; T1 = '0'; T2 = '0'; T3 = '0' }) -SteadyState $true).Inconclusive | Should -BeTrue
    }
}

# ── m3 · Reauth-LOOP advisory: Triggered≈Succeeded EVERY cycle passes the recovered-equality check yet means auth
#    breaks + self-heals on every poll (cache/session-binding regression). Advisory when reauth fires on a HIGH
#    fraction of poll cycles. The Pass verdict (every Triggered reaches Succeeded) is UNCHANGED.
Describe 'm3 · Reauth-loop advisory (high reauth fraction · Pass unchanged)' {
    It 'reauth fires on a HIGH fraction of cycles (triggered>=50% of PollCycles)→Pass still true BUT detail flags a possible loop' {
        $d = Test-XdrGate_Reauth -Row (New-Row @{ Pass = 'True'; Triggered = '9'; Succeeded = '9' }) -PollCycles 10
        $d.Pass   | Should -BeTrue                     # every Triggered reached Succeeded → recovered → Pass
        $d.Detail | Should -Match 'possible reauth LOOP'
    }
    It 'reauth fires RARELY (low fraction)→no loop advisory (a genuine one-off self-heal)' {
        $d = Test-XdrGate_Reauth -Row (New-Row @{ Pass = 'True'; Triggered = '1'; Succeeded = '1' }) -PollCycles 50
        $d.Pass   | Should -BeTrue
        $d.Detail | Should -Not -Match 'reauth LOOP'
    }
    It 'PollCycles=0 (not supplied / no polls): no fraction note (back-compat · the bare Triggered/Succeeded verdict stands)' {
        $d = Test-XdrGate_Reauth -Row (New-Row @{ Pass = 'True'; Triggered = '5'; Succeeded = '5' }) -PollCycles 0
        $d.Pass   | Should -BeTrue
        $d.Detail | Should -Not -Match 'reauth LOOP'
    }
    It 'an UNRECOVERED reauth (Triggered>Succeeded) still FAILS even on a high fraction (the block is independent of the advisory)' {
        $d = Test-XdrGate_Reauth -Row (New-Row @{ Pass = 'False'; Triggered = '10'; Succeeded = '4' }) -PollCycles 10
        $d.Pass | Should -BeFalse
    }
}

# ── Absence-as-PASS gates · for DLQ-empty and exceptions==0, az returning NO row IS the healthy state
#    (an empty DLQ / zero exceptions is exactly what "pass" looks like). bad→fail · good→pass · null→pass.
Describe 'F-A · absence-as-pass gates (DLQ / exceptions)' {
    It 'D9 (DLQ empty): bad(count>0)→fail · good(count=0)→pass · null(no DLQ events)→pass' {
        (Test-XdrGate_D9 -Row (New-Row @{ Pass = 'False'; Count = '3' })).Pass | Should -BeFalse
        (Test-XdrGate_D9 -Row (New-Row @{ Pass = 'True';  Count = '0' })).Pass | Should -BeTrue
        $n = Test-XdrGate_D9 -Row $null
        $n.Pass         | Should -BeTrue
        $n.Inconclusive | Should -BeFalse
    }
    It 'AppExceptions: real(non-transient)>0→fail · count=0→pass · null→pass · all-transient(recovered)→pass · mixed→fail' {
        # exceptions with NONE tagged transient → all real → BLOCK
        (Test-XdrGate_AppExceptions -Row (New-Row @{ Pass = 'False'; Count = '4'; Transient = '0' })).Pass | Should -BeFalse
        (Test-XdrGate_AppExceptions -Row (New-Row @{ Pass = 'True';  Count = '0'; Transient = '0' })).Pass | Should -BeTrue
        (Test-XdrGate_AppExceptions -Row $null).Pass | Should -BeTrue
        # GATE-LEARNING (2026-06-17): all-transient (XdrPortalTransientException · recovered · D9/D10 backstop loss) → PASS
        (Test-XdrGate_AppExceptions -Row (New-Row @{ Pass = 'False'; Count = '3'; Transient = '3' })).Pass | Should -BeTrue
        # mixed: 1 real + 2 transient → the REAL one BLOCKs
        (Test-XdrGate_AppExceptions -Row (New-Row @{ Pass = 'False'; Count = '3'; Transient = '2' })).Pass | Should -BeFalse
    }
    It 'AppExceptions: handled poll/fan-out FAILURE events BLOCK (coverage fix 2026-06-18 · ParentPollFailed silently starves fan-out)' {
        $clean = New-Row @{ Pass = 'True'; Count = '0'; Transient = '0' }
        # clean exceptions + poll-failures present → BLOCK (the class the old gate was structurally blind to: a parent
        # poll fails every cycle, logged to AppEvents not AppExceptions, fan-out children starve · the Exposure miss)
        (Test-XdrGate_AppExceptions -Row $clean -PollFailRow (New-Row @{ Count = '11'; Ops = '1' })).Pass | Should -BeFalse
        # clean exceptions + zero poll-failures → PASS
        (Test-XdrGate_AppExceptions -Row $clean -PollFailRow (New-Row @{ Count = '0'; Ops = '0' })).Pass | Should -BeTrue
        # no poll-failure row at all (az returned nothing) → 0 → PASS (backward-compatible · optional -PollFailRow)
        (Test-XdrGate_AppExceptions -Row $clean -PollFailRow $null).Pass | Should -BeTrue
        # a REAL exception still BLOCKs even with zero poll-failures (the two legs are independent)
        (Test-XdrGate_AppExceptions -Row (New-Row @{ Pass = 'False'; Count = '2'; Transient = '0' }) -PollFailRow (New-Row @{ Count = '0'; Ops = '0' })).Pass | Should -BeFalse
        # all-transient exceptions + zero poll-failures → PASS (transients are recovered retry telemetry)
        (Test-XdrGate_AppExceptions -Row (New-Row @{ Pass = 'False'; Count = '3'; Transient = '3' }) -PollFailRow (New-Row @{ Count = '0'; Ops = '0' })).Pass | Should -BeTrue
        # TRANSIENT poll-failures (2026-06-18 · XdrPortalTransientException 503/429) are advisory, NOT a block — Count is
        # the NON-transient count; a transient-only poll-fail row → PASS (else §4 false-fails on a routine portal 503, live-caught)
        (Test-XdrGate_AppExceptions -Row $clean -PollFailRow (New-Row @{ Count = '0'; TransientCount = '2'; Ops = '0' })).Pass | Should -BeTrue
        # a REAL (non-transient) poll-failure still BLOCKs even alongside transients
        (Test-XdrGate_AppExceptions -Row $clean -PollFailRow (New-Row @{ Count = '3'; TransientCount = '5'; Ops = '1' })).Pass | Should -BeFalse
    }
    It 'AppExceptions: NON-BENIGN fan-out skips BLOCK · BENIGN skips PASS (advisory) (V-B1 2026-06-18)' {
        $clean = New-Row @{ Pass = 'True'; Count = '0'; Transient = '0' }
        $noPoll = New-Row @{ Count = '0'; Ops = '0' }
        # NON-BENIGN fan-out skip (EntityResolution!=Resolved / incomplete DependsOn edge → child can never resolve) → BLOCK
        $bad = Test-XdrGate_AppExceptions -Row $clean -PollFailRow $noPoll -FanoutSkipRow (New-Row @{ NonBenign = '4'; Benign = '0' })
        $bad.Pass | Should -BeFalse
        $bad.Detail | Should -Match 'NON-BENIGN fan-out skip'
        # BENIGN-ONLY skips (parent-cache-empty on a 0-data tenant / RawJson-only no-edge op) → PASS, surfaced as advisory detail
        $benign = Test-XdrGate_AppExceptions -Row $clean -PollFailRow $noPoll -FanoutSkipRow (New-Row @{ NonBenign = '0'; Benign = '7' })
        $benign.Pass | Should -BeTrue
        $benign.Detail | Should -Match 'benign fan-out skip'
        # mixed: any non-benign present → BLOCK (the benign count is still reported)
        (Test-XdrGate_AppExceptions -Row $clean -PollFailRow $noPoll -FanoutSkipRow (New-Row @{ NonBenign = '1'; Benign = '5' })).Pass | Should -BeFalse
        # no fan-out-skip row at all (az returned nothing) → 0/0 → PASS (back-compat · -FanoutSkipRow optional)
        (Test-XdrGate_AppExceptions -Row $clean -PollFailRow $noPoll -FanoutSkipRow $null).Pass | Should -BeTrue
        # a non-benign fan-out skip BLOCKs even with clean exceptions AND zero poll-failures (the three legs are independent)
        (Test-XdrGate_AppExceptions -Row $clean -PollFailRow $null -FanoutSkipRow (New-Row @{ NonBenign = '2'; Benign = '0' })).Pass | Should -BeFalse
    }
    # FIX 5 (2026-07-01 robustness · safe-additive · mirrors D4's UnrecoveredFailPortals): the poll-fail leg is now
    # RECOVERY-AWARE. When the poll-fail row carries an `Unrecovered` column, the BLOCK is on Unrecovered (an op with a
    # non-transient failure and NO later success terminal in-window), not the raw non-transient Count — a failed op that
    # a LATER cycle cleared has RECOVERED. An op whose LAST terminal is a failure stays Unrecovered → still BLOCKS (M1).
    It 'FIX-5 · AppExceptions poll-fail RECOVERED (Count>0 but Unrecovered=0) → PASS · UNRECOVERED (Unrecovered>0) → BLOCK · back-compat (no Unrecovered col) → strict Count block' {
        $clean = New-Row @{ Pass = 'True'; Count = '0'; Transient = '0' }
        # RECOVERED: 3 non-transient poll-failures happened, but every failing op had a LATER success terminal (Unrecovered=0)
        # → the tenant IS returning data → NO block (the old strict Count>0 would have false-blocked this under finalize load).
        $recovered = Test-XdrGate_AppExceptions -Row $clean -PollFailRow (New-Row @{ Count = '3'; TransientCount = '1'; Ops = '2'; Unrecovered = '0'; UnrecoveredOps = '' })
        $recovered.Pass   | Should -BeTrue
        $recovered.Detail | Should -Match 'unrecovered=0'
        # UNRECOVERED: an op failed and its LAST terminal in-window is a failure (Unrecovered=1) → real dark op → BLOCK (M1)
        $unrec = Test-XdrGate_AppExceptions -Row $clean -PollFailRow (New-Row @{ Count = '4'; TransientCount = '0'; Ops = '2'; Unrecovered = '1'; UnrecoveredOps = '["ListPostureOversightInitiatives"]' })
        $unrec.Pass   | Should -BeFalse
        $unrec.Detail | Should -Match 'UNRECOVERED'
        $unrec.Detail | Should -Match 'ListPostureOversightInitiatives'
        # BACK-COMPAT (no Unrecovered column · older query / existing rows): fall back to the strict non-transient Count block
        # — a poll-failure Count>0 with NO recovery signal STILL BLOCKS (never a silent pass on an unknowable recovery state).
        (Test-XdrGate_AppExceptions -Row $clean -PollFailRow (New-Row @{ Count = '2'; TransientCount = '0'; Ops = '1' })).Pass | Should -BeFalse
        # a REAL exception STILL blocks regardless of a recovered poll-fail leg (the legs are independent · M1)
        (Test-XdrGate_AppExceptions -Row (New-Row @{ Pass = 'False'; Count = '2'; Transient = '0' }) -PollFailRow (New-Row @{ Count = '3'; TransientCount = '0'; Ops = '1'; Unrecovered = '0'; UnrecoveredOps = '' })).Pass | Should -BeFalse
        # transients never enter the blocking tally: a transient-only poll-fail with Unrecovered=0 → PASS
        (Test-XdrGate_AppExceptions -Row $clean -PollFailRow (New-Row @{ Count = '0'; TransientCount = '5'; Ops = '0'; Unrecovered = '0'; UnrecoveredOps = '' })).Pass | Should -BeTrue
    }
}

# ── FIX 5 STRUCTURAL · the poll-fail KQL computes the per-op recovery signal (Unrecovered) the same way D4 does ──
Describe 'FIX-5 · AppExceptions poll-fail RECOVERY-awareness KQL wiring (structural · offline)' {
    BeforeAll { $script:aetxt = Get-Content $script:Tool -Raw }
    It 'the poll-fail $qpf KQL brings in the success terminals (Entry.Poll.Succeeded + Entry.Fanout.Completed) to compute recovery' {
        $b = [regex]::Match($script:aetxt, "(?s)\`$qpf = @`".*?`"@").Value
        $b | Should -Match "'Entry\.Poll\.Succeeded'"
        $b | Should -Match "'Entry\.Fanout\.Completed'"
    }
    It 'it computes per-op LastFail (non-transient) vs LastOk and an Unrecovered = FailN>0 and (isnull(LastOk) or LastFail > LastOk)' {
        $b = [regex]::Match($script:aetxt, "(?s)\`$qpf = @`".*?`"@").Value
        $b | Should -Match 'LastFail=maxif\(TimeGenerated, _isFail and not\(_isTransient\)\)'
        $b | Should -Match 'LastOk=maxif\(TimeGenerated, not\(_isFail\)\)'
        $b | Should -Match '_unrecovered = FailN > 0 and \(isnull\(LastOk\) or LastFail > LastOk\)'
        $b | Should -Match 'Unrecovered=countif\(_unrecovered\)'
    }
    It 'M1 · the _isTransient exclusion is UNCHANGED (a transient failure never enters FailN → never blocks)' {
        $b = [regex]::Match($script:aetxt, "(?s)\`$qpf = @`".*?`"@").Value
        $b | Should -Match "ErrorMessage\) contains 'transient'"
        $b | Should -Match "ErrorMessage\) contains 'retry-after'"
        $b | Should -Match 'FailN=countif\(_isFail and not\(_isTransient\)\)'
    }
    It 'the gate body still passes -PollFailRow $rowp (the recovery-aware row) to the decision fn' {
        $b = [regex]::Match($script:aetxt, "(?s)Gate: AppExceptions.*?-FanoutSkipRow \`$rowf\)").Value
        $b | Should -Match '-PollFailRow \$rowp'
    }
}

# ── FIX 1 / FIX 2 / FIX 3 · KQL time-filter / predicate widenings (structural · offline). These are KQL-only
#    lag-immunity / transient-tolerance changes; the pure decision fns are UNCHANGED, so they are proven structurally
#    (grep the raw source for the exact new clause) + an M1 assertion that the genuine-defect FAIL path is untouched.
Describe 'FIX-1/2/3 · D4 window-widen · DrainStuck lag-immunity · Posture transient-tolerance (structural · offline)' {
    BeforeAll { $script:vtext = Get-Content $script:Tool -Raw }

    # FIX 1 · D4's Discovery KQL time filter widened from $sinceClause to $pollLivenessClause so a slow-to-ingest /
    # boot-time Discovery is still seen (no false "R3 cold-start did not fire" under ingest lag). The null-row→FAIL
    # logic in Test-XdrGate_D4 is UNCHANGED (M1: no Discovery over the WIDE window STILL hard-FAILs).
    It 'FIX-1 · the D4 Discovery KQL queries over the WIDE $pollLivenessClause (not the narrow $sinceClause)' {
        $b = [regex]::Match($script:vtext, "(?s)Gate: D4 R3 capability discovery.*?Label 'D4'").Value
        $b | Should -Match "where \`$pollLivenessClause and Name startswith 'PortalCapabilities\.Discovery\.'"
        $b | Should -Not -Match "where \`$sinceClause and Name startswith 'PortalCapabilities\.Discovery\.'"
    }
    It 'FIX-1 · M1 · the D4 null-row → hard-FAIL logic is UNCHANGED (no Discovery over the WIDE window STILL FAILs)' {
        # the pure fn still hard-FAILs a null row (no inconclusive) — the widen only changes WHICH events feed the row
        $n = Test-XdrGate_D4 -Row $null
        $n.Pass | Should -BeFalse; $n.Inconclusive | Should -BeFalse
        # and a WIDE-window row that saw discovery but 0 succeeded still FAILs (R3 never succeeded)
        (Test-XdrGate_D4 -Row (New-Row @{ Total = '0'; Succeeded = '0'; Failed = '0'; UnrecoveredFailPortals = '0'; MostRecent = '' })).Pass | Should -BeFalse
        # the recovery-aware UnrecoveredFailPortals block is untouched (a never-recovered portal STILL FAILs)
        (Test-XdrGate_D4 -Row (New-Row @{ Total = '3'; Succeeded = '1'; Failed = '2'; UnrecoveredFailPortals = '1'; MostRecent = '' })).Pass | Should -BeFalse
    }

    # FIX 2 · DrainStuck counts the DrainComplete Completes (+ the Polls gating Ops) over the WIDE $pollLivenessClause
    # while CycleBudgetReached stays on the NARROW $sinceClause — a late-landing completion clears the op, but a CHRONIC
    # stuck op (0 completes over the WIDE window + budget in-window) STILL trips StuckOps (M1).
    It 'FIX-2 · DrainStuck counts Completes over the WIDE $pollLivenessClause but Budget over the NARROW $sinceClause' {
        $b = [regex]::Match($script:vtext, "(?s)Gate: DrainStuck.*?Label 'DrainStuck'").Value
        # the Succeeded/DrainComplete leg is on the wide window
        $b | Should -Match "where \`$pollLivenessClause and Name == 'Entry\.Poll\.Succeeded'"
        # the CycleBudgetReached leg stays on the narrow deploy-floor window
        $b | Should -Match "where \`$sinceClause and Name == 'Entry\.Poll\.CycleBudgetReached'"
        # the stuck predicate is unchanged: 0 completed drains AND a budget-stop
        $b | Should -Match 'StuckOps=countif\(Completes == 0 and Budget > 0\)'
    }
    It 'FIX-2 · M1 · a CHRONIC stuck op (StuckOps>0) STILL hard-FAILs · the pure fn is unchanged' {
        # the widen only changes the WINDOW the Completes/Budget are counted over — the decision fn still blocks on StuckOps>0
        $d = Test-XdrGate_DrainStuck -Row (New-Row @{ Ops = '3'; StuckOps = '1'; StuckOpList = '["GetHistory"]' })
        $d.Pass | Should -BeFalse; $d.Inconclusive | Should -BeFalse
        $d.Detail | Should -Match 'NEVER completed a drain'
        # DrainStuck stays BLOCKING (no -Advisory on its decision call)
        $call = [regex]::Match($script:vtext, "Add-XdrGateDecision -GateId 'DrainStuck'[^\r\n]*").Value
        $call | Should -Not -Match '-Advisory'
    }

    # FIX 3 · the Posture TerminalProxy countif now EXCLUDES a line that ALSO carries the connector's transient marker
    # ('transient' / 'retry-after') — a portal transient surfacing momentarily is not a license-gate regression. A
    # GENUINE (non-transient) InvalidProxyPrefix terminal is still counted (M1: license-gate regression STILL FAILs).
    It 'FIX-3 · the Posture TerminalProxy countif excludes transient / retry-after lines' {
        $b = [regex]::Match($script:vtext, "(?s)Gate: Posture.*?Label 'Posture'").Value
        $b | Should -Match "TerminalProxy = countif\(Message startswith '\[Entry\.Poll\.Exception\]' and Message contains 'InvalidProxyPrefix' and not\(Message contains 'transient'\) and not\(Message contains 'retry-after'\)\)"
    }
    It 'FIX-3 · M1 · a genuine (non-transient) InvalidProxyPrefix TERMINAL (TerminalProxy>0) STILL hard-FAILs · the pure fn is unchanged' {
        # the exclusion only affects WHICH trace lines increment TerminalProxy — a TerminalProxy>0 row still FAILs
        $d = Test-XdrGate_Posture -Row (New-Row @{ PollActivity = '10'; TerminalProxy = '2'; PostureEvents = '0' })
        $d.Pass | Should -BeFalse; $d.Inconclusive | Should -BeFalse
        $d.Detail | Should -Match 'license-gate REGRESSION'
    }
}

Describe 'F-A · AppExceptions poll-fail transient detection covers FAN-OUT ErrorMessage (2026-07-01 · structural regression)' {
    BeforeAll { $script:aetxt = Get-Content $script:Tool -Raw }
    # REGRESSION: fan-out failure events (Entry.Fanout.ParentPollFailed) stamp the transient-ness in ErrorMessage ("Portal
    # transient 503 ... retry-after 30"), NOT in ErrorClass (empty for them). The old ErrorClass-only exclusion counted a
    # routine parent-poll 503 as a REAL failure → hard-blocked ExposureManagement's ListPostureOversightInitiatives under
    # the finalize's aggressive re-poll load. The poll-fail KQL must ALSO treat an ErrorMessage containing 'transient' /
    # 'retry-after' (the connector's OWN retryable-error label) as transient (excluded from the blocking Count · M1 intact).
    It 'the poll-fail KQL _isTransient predicate reads Properties.ErrorMessage (not ErrorClass alone)' {
        $script:aetxt | Should -Match "_isTransient[\s\S]{0,220}Properties\.ErrorMessage"
    }
    It "the predicate matches the connector's own transient markers ('transient' AND 'retry-after')" {
        $script:aetxt | Should -Match "ErrorMessage\)\s+contains\s+'transient'"
        $script:aetxt | Should -Match "ErrorMessage\)\s+contains\s+'retry-after'"
    }
    It 'the blocking count uses not(_isTransient) so a genuinely non-transient failure STILL blocks (M1)' {
        # FIX 5 (2026-07-01) made $qpf recovery-aware: the per-op non-transient failure tally is FailN=countif(_isFail and
        # not(_isTransient)) and the reported Count=sum(FailN) — a non-transient failure STILL enters the blocking tally
        # (M1). The transient exclusion is unchanged; only the shape moved (per-op, to compute recovery).
        $b = [regex]::Match($script:aetxt, "(?s)\`$qpf = @`".*?`"@").Value
        $b | Should -Match 'FailN=countif\(_isFail and not\(_isTransient\)\)'
        $b | Should -Match 'Count=sum\(FailN\)'
    }
    It 'the EXCEPTIONS leg excludes AuthChainBrokenException (auth-self-heal is the Reauth advisory''s job · 2026-07-01 · reauth-loop false-block)' {
        $script:aetxt | Should -Match "ProblemId in \('XdrPortalTransientException','AuthChainBrokenException'\)"
    }
}

# ── V-B3 / V-B4 · ingest-integrity gates the prior gate-set never covered: chunked partial-batch loss
#    (DCE.Ingest.Chunked AllSucceeded==false) and in-place row/column truncation (Ingest.RowClamped /
#    Ingest.ColumnClamped). ChunkedLoss BLOCKS; Truncation is ADVISORY (visibility, never a hard fail).
Describe 'F-A · V-B3 ChunkedLoss (partial-batch ingest loss · BLOCKING)' {
    It 'bad (a multi-chunk batch had AllSucceeded==false → trailing chunk failed)→fail (BLOCKING)' {
        $bad = Test-XdrGate_ChunkedLoss -Row (New-Row @{ BadBatches = '2'; Total = '5' })
        $bad.Pass         | Should -BeFalse
        $bad.Inconclusive | Should -BeFalse
        $bad.Detail       | Should -Match 'partial ingest loss'
    }
    It 'good (every multi-chunk batch fully landed: BadBatches=0)→pass' {
        (Test-XdrGate_ChunkedLoss -Row (New-Row @{ BadBatches = '0'; Total = '5' })).Pass | Should -BeTrue
    }
    It 'no row (no multi-chunk ingest in window · single-chunk is all-or-nothing)→PASS, not inconclusive' {
        $n = Test-XdrGate_ChunkedLoss -Row $null
        $n.Pass         | Should -BeTrue
        $n.Inconclusive | Should -BeFalse
    }
}

Describe 'F-A · V-B4 Truncation (in-place row/column data loss · ADVISORY · always Pass, surfaces the loss)' {
    It 'row clamps present→Pass=$true (ADVISORY) but the detail reports the count + ops (silent loss made visible)' {
        $d = Test-XdrGate_Truncation -RowClampRow (New-Row @{ Count = '3'; Ops = '2' }) -ColClampRow $null
        $d.Pass   | Should -BeTrue          # advisory · never hard-fails
        $d.Detail | Should -Match 'rowClamps=3'
        $d.Detail | Should -Match 'in-place truncation event'
    }
    It 'column clamps present→Pass=$true (ADVISORY) and the affected columns are reported' {
        $d = Test-XdrGate_Truncation -RowClampRow $null -ColClampRow (New-Row @{ Count = '4'; Columns = 'RelatedEntitiesJson,AdditionalFieldsJson' })
        $d.Pass   | Should -BeTrue
        $d.Detail | Should -Match 'colClamps=4'
        $d.Detail | Should -Match 'RelatedEntitiesJson'
    }
    It 'no clamps (both rows null)→Pass=$true with a clean detail (no truncation in window)' {
        $d = Test-XdrGate_Truncation -RowClampRow $null -ColClampRow $null
        $d.Pass   | Should -BeTrue
        $d.Detail | Should -Match 'no in-place truncation'
    }
    It 'both row + column clamps→total reported, still Pass (advisory)' {
        $d = Test-XdrGate_Truncation -RowClampRow (New-Row @{ Count = '2'; Ops = '1' }) -ColClampRow (New-Row @{ Count = '3'; Columns = 'BigCol' })
        $d.Pass   | Should -BeTrue
        $d.Detail | Should -Match '5 in-place truncation event'
    }
}

# ── Dynamic-shape gates · the result row carries one count column PER manifest-derived col, so the pure
#    fn takes the row PLUS the expected column list. bad→fail · good→pass · empty→INCO · vacuous→pass.
Describe 'F-A · dynamic-shape gates (D8f / D8g / D8h)' {
    Context 'D8f · typed cols populated (keystone parser-fires gate)' {
        It 'bad (one col has ZERO non-null rows)→fail' {
            $bad = New-Row @{ Total = '20'; ActionId_pop = '20'; EventTime_pop = '0' }
            (Test-XdrGate_D8f -Row $bad -Columns @('ActionId','EventTime')).Pass | Should -BeFalse
        }
        It 'good (every col >0)→pass' {
            $good = New-Row @{ Total = '20'; ActionId_pop = '20'; EventTime_pop = '20' }
            (Test-XdrGate_D8f -Row $good -Columns @('ActionId','EventTime')).Pass | Should -BeTrue
        }
        It 'empty table→INCONCLUSIVE (cannot prove parser fired with no rows)' {
            $empty = New-Row @{ Total = '0'; ActionId_pop = '0'; EventTime_pop = '0' }
            (Test-XdrGate_D8f -Row $empty -Columns @('ActionId','EventTime')).Inconclusive | Should -BeTrue
        }
        It 'null row→INCONCLUSIVE' {
            (Test-XdrGate_D8f -Row $null -Columns @('ActionId')).Inconclusive | Should -BeTrue
        }
        It 'no ProjectionMap keys→hard FAIL (cannot verify nothing)' {
            $d = Test-XdrGate_D8f -Row (New-Row @{ Total = '5' }) -Columns @()
            $d.Pass | Should -BeFalse; $d.Inconclusive | Should -BeFalse
        }
        # WS4.3 · source cross-check: empty-in-table is a parser bug ONLY when the source carried a value.
        It 'parser bug (col empty-in-table BUT source NON-null)→FAIL' {
            $bug = New-Row @{ Total = '20'; ActionId_pop = '20'; ActionId_src = '20'; EventTime_pop = '0'; EventTime_src = '20' }
            $d = Test-XdrGate_D8f -Row $bug -Columns @('ActionId','EventTime')
            $d.Pass | Should -BeFalse
            $d.Detail | Should -Match 'EventTime'
        }
        It 'legitimately source-null (col empty-in-table AND source also null)→PASS (e.g. ActionDecision)' {
            $legit = New-Row @{ Total = '1870'; ActionId_pop = '1870'; ActionId_src = '1870'; ActionDecision_pop = '0'; ActionDecision_src = '0' }
            $d = Test-XdrGate_D8f -Row $legit -Columns @('ActionId','ActionDecision')
            $d.Pass | Should -BeTrue
            $d.Detail | Should -Match 'source-null'
        }
        # D8f EMPTY-CONTAINER tolerance (Fix 2): a col whose source is an EMPTY CONTAINER on every row ([] / [[]] / {} / '')
        # legitimately serializes to empty and lands empty — NOT a parser bug. The _src KQL now EXCLUDES empty-containers, so
        # such a col reports _src=0 → the pure fn treats it exactly like a source-null col → PASS. (Concretely:
        # ListSuppressionRules.DeserializedScopeConditions = [] on every row; the real conditions ship via RuleConditions.)
        It 'empty-container source (col empty-in-table · source all []/[[]]/{} → _src=0)→PASS (e.g. ListSuppressionRules.DeserializedScopeConditions)' {
            $ec = New-Row @{ Total = '142'; RuleConditions_pop = '142'; RuleConditions_src = '142'; DeserializedScopeConditions_pop = '0'; DeserializedScopeConditions_src = '0' }
            $d = Test-XdrGate_D8f -Row $ec -Columns @('RuleConditions','DeserializedScopeConditions')
            $d.Pass | Should -BeTrue
            $d.Detail | Should -Match 'source-null'
        }
        It 'mixed: a real parser bug still FAILs even alongside a legitimately source-null col' {
            $mix = New-Row @{ Total = '10'; A_pop = '10'; A_src = '10'; B_pop = '0'; B_src = '0'; C_pop = '0'; C_src = '7' }
            $d = Test-XdrGate_D8f -Row $mix -Columns @('A','B','C')
            $d.Pass | Should -BeFalse                       # C is a real bug (empty-in-table · source has 7)
            $d.Detail | Should -Match 'C \(source has 7'     # C flagged with its source count
        }
    }

    Context 'ConvertTo-XdrRawJsonAccessor · JSONPath → pre-parsed _rj KQL accessor (D8f source cross-check · parse-once)' {
        It 'translates a simple $.Field to _rj[''Field''] (BRACKET · reserved-word-safe · reuses the once-extended _rj)' {
            ConvertTo-XdrRawJsonAccessor '$.ActionDecision' | Should -Be "_rj['ActionDecision']"
        }
        It 'translates a nested $.A.B path to bracket-per-segment' {
            ConvertTo-XdrRawJsonAccessor '$.Outer.Inner' | Should -Be "_rj['Outer']['Inner']"
        }
        It 'falls back to the whole _rj object for an array/wildcard path (conservative · reverts to strict)' {
            ConvertTo-XdrRawJsonAccessor '$.items[*].x' | Should -Be '_rj'
        }
        It 'falls back to the whole _rj object for an empty/$ path' {
            ConvertTo-XdrRawJsonAccessor '$'  | Should -Be '_rj'
            ConvertTo-XdrRawJsonAccessor ''   | Should -Be '_rj'
        }
    }
    Context 'D8g · LA-reserved rewrite (_x cols)' {
        It 'bad (_x col has ZERO non-null rows)→fail' {
            (Test-XdrGate_D8g -Row (New-Row @{ Total = '10'; TenantId_x_pop = '0' }) -Columns @('TenantId_x')).Pass | Should -BeFalse
        }
        It 'good (_x col populated)→pass' {
            (Test-XdrGate_D8g -Row (New-Row @{ Total = '10'; TenantId_x_pop = '10' }) -Columns @('TenantId_x')).Pass | Should -BeTrue
        }
        It 'empty table WITH a real _x contract→INCONCLUSIVE (was the silent-PASS bug)' {
            (Test-XdrGate_D8g -Row (New-Row @{ Total = '0'; TenantId_x_pop = '0' }) -Columns @('TenantId_x')).Inconclusive | Should -BeTrue
        }
        It 'null row WITH a real _x contract→INCONCLUSIVE' {
            (Test-XdrGate_D8g -Row $null -Columns @('TenantId_x')).Inconclusive | Should -BeTrue
        }
        It 'no _x cols (the live Defender/Operations manifest case: EndTime is NOT LA-reserved)→vacuous PASS' {
            $d = Test-XdrGate_D8g -Row (New-Row @{ Total = '10' }) -Columns @()
            $d.Pass | Should -BeTrue; $d.Inconclusive | Should -BeFalse
        }
    }
    Context 'D8h · serialized non-scalars round-trip parse (Json cols)' {
        It 'bad (col populated but some value does not parse: ok < ne)→fail' {
            $bad = New-Row @{ Total = '10'; RelatedEntitiesJson_ne = '10'; RelatedEntitiesJson_ok = '7' }
            (Test-XdrGate_D8h -Row $bad -Columns @('RelatedEntitiesJson')).Pass | Should -BeFalse
        }
        It 'good (every populated value parses: ok == ne)→pass' {
            $good = New-Row @{ Total = '10'; RelatedEntitiesJson_ne = '10'; RelatedEntitiesJson_ok = '10' }
            (Test-XdrGate_D8h -Row $good -Columns @('RelatedEntitiesJson')).Pass | Should -BeTrue
        }
        It 'col never populated (ne=0)→pass (nothing to disprove)' {
            $unp = New-Row @{ Total = '10'; RelatedEntitiesJson_ne = '0'; RelatedEntitiesJson_ok = '0' }
            (Test-XdrGate_D8h -Row $unp -Columns @('RelatedEntitiesJson')).Pass | Should -BeTrue
        }
        It 'empty table→INCONCLUSIVE (was the silent-PASS bug)' {
            (Test-XdrGate_D8h -Row (New-Row @{ Total = '0'; RelatedEntitiesJson_ne = '0'; RelatedEntitiesJson_ok = '0' }) -Columns @('RelatedEntitiesJson')).Inconclusive | Should -BeTrue
        }
        It 'null row→INCONCLUSIVE' {
            (Test-XdrGate_D8h -Row $null -Columns @('RelatedEntitiesJson')).Inconclusive | Should -BeTrue
        }
        It 'no Json cols→vacuous PASS' {
            (Test-XdrGate_D8h -Row (New-Row @{ Total = '10' }) -Columns @()).Pass | Should -BeTrue
        }
    }
}

# ── ExactlyOnce · the headline honesty fix: MinRows>=1 FLOOR. The count==dcount equality is asserted
#    ONLY when rows exist; an empty window is INCONCLUSIVE, NOT a silent vacuous PASS (the original bug).
Describe 'F-A · ExactlyOnce (MinRows>=1 floor · empty window is NOT a silent vacuous pass)' {
    It 'bad (a duplicate landed: Rows > DistinctKeys)→fail (BLOCKING data-integrity)' {
        $bad = New-Row @{ Pass = 'False'; Rows = '34'; DistinctKeys = '30'; Duplicates = '4' }
        $d = Test-XdrGate_ExactlyOnce -Row $bad -NaturalKey 'ActionId'
        $d.Pass         | Should -BeFalse
        $d.Inconclusive | Should -BeFalse
    }
    It 'good (Rows == DistinctKeys, rows>0)→pass' {
        $good = New-Row @{ Pass = 'True'; Rows = '34'; DistinctKeys = '34'; Duplicates = '0' }
        (Test-XdrGate_ExactlyOnce -Row $good -NaturalKey 'ActionId').Pass | Should -BeTrue
    }
    It 'empty window (Rows=0)→INCONCLUSIVE, NOT pass (the floor: zero dups over zero rows proves nothing)' {
        $empty = New-Row @{ Pass = 'True'; Rows = '0'; DistinctKeys = '0'; Duplicates = '0' }
        $d = Test-XdrGate_ExactlyOnce -Row $empty -NaturalKey 'ActionId'
        $d.Pass         | Should -BeFalse
        $d.Inconclusive | Should -BeTrue
    }
    It 'null row→INCONCLUSIVE, NOT pass' {
        $n = Test-XdrGate_ExactlyOnce -Row $null -NaturalKey 'ActionId'
        $n.Pass         | Should -BeFalse
        $n.Inconclusive | Should -BeTrue
    }
    It 'CURSOR dups WITH a reset-in-window → INCONCLUSIVE (a reset rewinds a CURSOR op → pre-reset keys re-emit · reset-churn · 2026-07-01)' {
        $dup = New-Row @{ Rows = '10'; DistinctKeys = '7'; Duplicates = '3' }
        $d = Test-XdrGate_ExactlyOnce -Row $dup -NaturalKey 'ActionId' -ResetsInWindow 1
        $d.Pass         | Should -BeFalse
        $d.Inconclusive | Should -BeTrue
        $d.Detail       | Should -Match 'reset'
    }
    It 'CURSOR dups with NO reset → still FAIL (a genuine duplicate is a data-integrity defect · M1 intact)' {
        $dup = New-Row @{ Rows = '10'; DistinctKeys = '7'; Duplicates = '3' }
        $d = Test-XdrGate_ExactlyOnce -Row $dup -NaturalKey 'ActionId' -ResetsInWindow 0
        $d.Pass         | Should -BeFalse
        $d.Inconclusive | Should -BeFalse
    }
    It 'CLEAN (rows==distinct) with a reset → still PASS (the reset does not mask a clean exactly-once)' {
        $good = New-Row @{ Rows = '7'; DistinctKeys = '7'; Duplicates = '0' }
        (Test-XdrGate_ExactlyOnce -Row $good -NaturalKey 'ActionId' -ResetsInWindow 2).Pass | Should -BeTrue
    }
}

# ── ExactlyOncePerCycle · plan §4 "exactly-once per INGESTION MODE". SNAPSHOT/WINDOW ops re-emit their full
#    state every cadence cycle, so a NaturalKey recurs ACROSS cycles BY DESIGN — exactly-once means PER-CYCLE
#    dup-free (group by CorrelationId). The whole-window count==dcount form false-failed SNAPSHOT the instant
#    >1 cycle was in the window; this per-cycle form is what makes the C6 "sustained >=N cycles" leg measurable.
Describe 'F-A · ExactlyOncePerCycle (SNAPSHOT/WINDOW · re-emit per cycle → PER-CYCLE dup-free, not whole-window)' {
    It 'all cycles dup-free (BadCycles=0, rows>0)→pass (the SNAPSHOT exactly-once proof)' {
        $good = New-Row @{ Pass = 'True'; Cycles = '5'; BadCycles = '0'; TotalRows = '620'; MaxRowsPerCycle = '124' }
        $d = Test-XdrGate_ExactlyOncePerCycle -Row $good -NaturalKey 'id' -Mode 'SNAPSHOT'
        $d.Pass         | Should -BeTrue
        $d.Inconclusive | Should -BeFalse
    }
    It 'an intra-cycle duplicate (BadCycles>0)→fail (a snapshot landed a dup within ONE cycle · BLOCKING)' {
        $bad = New-Row @{ Pass = 'False'; Cycles = '5'; BadCycles = '1'; TotalRows = '621'; MaxRowsPerCycle = '125' }
        $d = Test-XdrGate_ExactlyOncePerCycle -Row $bad -NaturalKey 'id' -Mode 'SNAPSHOT'
        $d.Pass         | Should -BeFalse
        $d.Inconclusive | Should -BeFalse
    }
    It 'cross-cycle re-emit is NOT a failure (the whole-window false-fail this form cures)' {
        # 5 cycles each internally dup-free (BadCycles=0). The OLD whole-window gate would FAIL the same data
        # (620 rows != 124 distinct keys); per-cycle PASSES because exactly-once is asserted WITHIN each cycle.
        $reemit = New-Row @{ Pass = 'True'; Cycles = '5'; BadCycles = '0'; TotalRows = '620'; MaxRowsPerCycle = '124' }
        (Test-XdrGate_ExactlyOncePerCycle -Row $reemit -NaturalKey 'id' -Mode 'SNAPSHOT').Pass | Should -BeTrue
    }
    It 'empty window (Cycles=0/TotalRows=0)→INCONCLUSIVE, NOT pass (MinRows floor · same honesty as CURSOR form)' {
        $empty = New-Row @{ Pass = 'False'; Cycles = '0'; BadCycles = '0'; TotalRows = '0'; MaxRowsPerCycle = '0' }
        $d = Test-XdrGate_ExactlyOncePerCycle -Row $empty -NaturalKey 'id' -Mode 'SNAPSHOT'
        $d.Pass         | Should -BeFalse
        $d.Inconclusive | Should -BeTrue
    }
    It 'null row→INCONCLUSIVE, NOT pass' {
        $n = Test-XdrGate_ExactlyOncePerCycle -Row $null -NaturalKey 'id' -Mode 'SNAPSHOT'
        $n.Pass         | Should -BeFalse
        $n.Inconclusive | Should -BeTrue
    }
}

# ── SnapshotNoDupAccum · F-SNAPSHOT-SIG · the CROSS-cycle dup-accumulation BLOCK. The per-cycle gate above proves
#    only INTRA-cycle dup-free; it TOLERATED the live 16×/719× cross-cycle re-emit. This gate asserts a cursorless
#    SNAPSHOT does NOT multiply its row count across cycles (total <= distinct(dedup-key) * 3) — the EO signature skip.
Describe 'F-A · SnapshotNoDupAccum (cross-cycle dup-accumulation BLOCK · the verifier MUST block the re-emit)' {
    It 'post-fix unchanged snapshot (total≈distinct, multi-cycle)→pass (the signature skip held)' {
        $good = New-Row @{ Total = '2753'; Distinct = '2753'; Cycles = '5' }
        $d = Test-XdrGate_SnapshotNoDupAccum -Row $good -Key 'RecordId(content-hash)'
        $d.Pass         | Should -BeTrue
        $d.Inconclusive | Should -BeFalse
    }
    It 'bounded legit value-changes (dupFactor 2.5 <= x3)→pass (a CHANGED snapshot legitimately re-emits)' {
        $changed = New-Row @{ Total = '250'; Distinct = '100'; Cycles = '5' }
        (Test-XdrGate_SnapshotNoDupAccum -Row $changed -Key 'id').Pass | Should -BeTrue
    }
    It 'the live dup-accumulation (43,200/2,753 ≈ 16x over 16 cycles)→FAIL (BLOCKING · the gap this gate closes)' {
        $dup = New-Row @{ Total = '43200'; Distinct = '2753'; Cycles = '16' }
        $d = Test-XdrGate_SnapshotNoDupAccum -Row $dup -Key 'RecordId(content-hash)'
        $d.Pass         | Should -BeFalse
        $d.Inconclusive | Should -BeFalse
    }
    It 'Exposure 719x (719/1)→FAIL (BLOCKING)' {
        $dup = New-Row @{ Total = '719'; Distinct = '1'; Cycles = '719' }
        (Test-XdrGate_SnapshotNoDupAccum -Row $dup -Key 'id').Pass | Should -BeFalse
    }
    It '<2 cycles (the skip cannot have fired yet)→INCONCLUSIVE, NOT pass' {
        $one = New-Row @{ Total = '2753'; Distinct = '2753'; Cycles = '1' }
        $d = Test-XdrGate_SnapshotNoDupAccum -Row $one -Key 'id'
        $d.Pass         | Should -BeFalse
        $d.Inconclusive | Should -BeTrue
    }
    It 'clean skip: 1 TABLE cycle BUT telemetry shows FA polled >=2 + no accum→PASS (the perfect-skip proof · live 2026-06-19)' {
        # A perfect signature-skip emits 0 rows on cycle-2+, so a stable snapshot NEVER shows 2 table cycles.
        $skip = New-Row @{ Total = '448'; Distinct = '448'; Cycles = '1' }
        $d = Test-XdrGate_SnapshotNoDupAccum -Row $skip -Key 'RecordId(content-hash)' -PollCycles 2
        $d.Pass         | Should -BeTrue
        $d.Inconclusive | Should -BeFalse
    }
    It 'clean skip but FA has NOT polled >=2 yet (PollCycles=1)→INCONCLUSIVE (skip not exercised · force a 2nd cycle)' {
        $one = New-Row @{ Total = '448'; Distinct = '448'; Cycles = '1' }
        (Test-XdrGate_SnapshotNoDupAccum -Row $one -Key 'id' -PollCycles 1).Inconclusive | Should -BeTrue
    }
    It '1 table cycle + telemetry >=2 BUT accumulating (total > distinct x3)→NOT pass (the bound still guards · no vacuous skip-pass)' {
        $acc = New-Row @{ Total = '4000'; Distinct = '448'; Cycles = '1' }
        (Test-XdrGate_SnapshotNoDupAccum -Row $acc -Key 'id' -PollCycles 5).Pass | Should -BeFalse
    }
    It 'empty window (Total=0)→INCONCLUSIVE, NOT pass' {
        $empty = New-Row @{ Total = '0'; Distinct = '0'; Cycles = '0' }
        (Test-XdrGate_SnapshotNoDupAccum -Row $empty -Key 'id').Inconclusive | Should -BeTrue
    }
    It 'null row→INCONCLUSIVE, NOT pass' {
        $n = Test-XdrGate_SnapshotNoDupAccum -Row $null -Key 'id'
        $n.Pass         | Should -BeFalse
        $n.Inconclusive | Should -BeTrue
    }
    It 'over-bound WITH a reset-in-window → INCONCLUSIVE (reset+forced re-emits inflate total, not a real accumulation · 2026-07-01)' {
        $acc = New-Row @{ Total = '100'; Distinct = '10'; Cycles = '5' }
        $d = Test-XdrGate_SnapshotNoDupAccum -Row $acc -Key 'id' -PollCycles 5 -ResetsInWindow 1
        $d.Pass         | Should -BeFalse
        $d.Inconclusive | Should -BeTrue
        $d.Detail       | Should -Match 'reset'
    }
    It 'over-bound with NO reset → still FAIL (genuine dup-accumulation is BLOCKING · M1 intact)' {
        $acc = New-Row @{ Total = '100'; Distinct = '10'; Cycles = '5' }
        $d = Test-XdrGate_SnapshotNoDupAccum -Row $acc -Key 'id' -PollCycles 5 -ResetsInWindow 0
        $d.Pass         | Should -BeFalse
        $d.Inconclusive | Should -BeFalse
    }
    It 'within-bound with a reset → still PASS (the reset does not force INCONCLUSIVE when there is no accumulation)' {
        $ok = New-Row @{ Total = '20'; Distinct = '10'; Cycles = '3' }
        (Test-XdrGate_SnapshotNoDupAccum -Row $ok -Key 'id' -PollCycles 3 -ResetsInWindow 2).Pass | Should -BeTrue
    }
    It 'SIGNATURE-AWARE · legit full-snapshot-each-cycle (dupFactor 5 > x3 BUT every cycle a DISTINCT snapshot)→PASS (drift=KQL · what the flat bound false-RED · e.g. ListPostureOversightInitiatives)' {
        $legit = New-Row @{ Total = '50'; Distinct = '10'; Cycles = '5' }
        $d = Test-XdrGate_SnapshotNoDupAccum -Row $legit -Key 'id' -DistinctSnaps 5 -EmitCycles 5 -ResetsInWindow 0
        $d.Pass         | Should -BeTrue
        $d.Inconclusive | Should -BeFalse
        $d.Detail       | Should -Match 'genuine content change'
    }
    It 'SIGNATURE-AWARE · an IDENTICAL snapshot re-emitted (distinctSnaps=1 < emitCycles=5), no reset→FAIL (the content-signature skip regressed · real dup-accumulation)' {
        $reg = New-Row @{ Total = '50'; Distinct = '10'; Cycles = '5' }
        $d = Test-XdrGate_SnapshotNoDupAccum -Row $reg -Key 'RecordId(content-hash)' -DistinctSnaps 1 -EmitCycles 5 -ResetsInWindow 0
        $d.Pass         | Should -BeFalse
        $d.Inconclusive | Should -BeFalse
        $d.Detail       | Should -Match 'skip regressed'
    }
    It 'SIGNATURE-AWARE · identical re-emit WITH a reset-in-window→INCONCLUSIVE (the reset legitimately re-emits the pre-reset snapshot · never a false RED)' {
        $reg = New-Row @{ Total = '50'; Distinct = '10'; Cycles = '5' }
        $d = Test-XdrGate_SnapshotNoDupAccum -Row $reg -Key 'id' -DistinctSnaps 1 -EmitCycles 5 -ResetsInWindow 1
        $d.Pass         | Should -BeFalse
        $d.Inconclusive | Should -BeTrue
    }
}

# ── VolatileHash · F-VOLATILE-HASH · the SHARPER cross-cycle gate SnapshotNoDupAccum is BLIND to. When the keyless
#    content-hash RecordId is ITSELF volatile (a record carrying a per-poll-changing field), the re-emits get DISTINCT
#    RecordIds → SnapshotNoDupAccum reads dupFactor≈1 as "healthy". The DISCRIMINATOR is TABLE-cycles=dcount(CorrelationId)
#    in the op-scoped _CL, NOT telemetry pollCycles: the connector's signature-SKIP makes a HEALTHY stable snapshot dedup
#    AT SOURCE (cold-emit N once, then BoundaryDeduped → no new CorrelationId) → TableCycles≈1 AND dupFactor=1 (IDENTICAL
#    to a volatile op on the old dupFactor≈pollCycles premise — which therefore FALSE-RED every healthy-skip op). A
#    VOLATILE op re-mints a fresh hash every cycle → fresh rows under a new CorrelationId EVERY cycle → TableCycles≈pollCycles.
#    PASS ⇔ TableCycles<=1 (skip fired) · RED ⇔ TableCycles>=2 AND dupFactor<2 (emitted distinct rows on >=2 cycles w/o
#    deduping). The decisive regression: a healthy-skip row {dupFactor=1, TableCycles=1} now PASSES (the old gate RED it).
Describe 'F-A · VolatileHash (table-cycles discriminator · catches what SnapshotNoDupAccum is structurally blind to)' {
    It 'REGRESSION (the false-RED the fix cures): healthy signature-skip {Total=152;DistinctRec=152;PollCycles=5;TableCycles=1} → PASS (dupFactor=1 yet only the cold emit landed)' {
        # Post-fix live ListCriticalAssetClassifications: cold-emits 152 then BoundaryDeduped on every later poll → Total=152,
        # DistinctRec=152 (dupFactor=1), TableCycles=1. The OLD dupFactor≈pollCycles premise RED this (dupFactor 1 << 5/2);
        # the table-cycles discriminator correctly PASSES it (only 1 cadence cycle ever landed rows = the skip fired).
        $healthy = New-Row @{ Total = '152'; DistinctRec = '152' }
        $d = Test-XdrGate_VolatileHash -Row $healthy -Key 'RecordId(content-hash · keyless)' -PollCycles 5 -TableCycles 1
        $d.Pass         | Should -BeTrue
        $d.Inconclusive | Should -BeFalse
        $d.Detail       | Should -Match 'tableCycles=1'
    }
    It 'THE GAP: a row SnapshotNoDupAccum reads as healthy (total≈distinct) is FAILED here when DISTINCT rows landed on >=2 cadence cycles (volatile RecordId never dedups)' {
        # Live pre-fix volatile op: every cycle re-mints a fresh content-hash → DISTINCT rows land under a NEW CorrelationId
        # every cycle → total≈distinct → SnapshotNoDupAccum dupFactor≈1 PASSES (blind); but TableCycles=5 with no dedup →
        # THIS gate FAILS (the real bug). "Provably able to fail": that row reds here and (correctly) greens there.
        $volatile = New-Row @{ Total = '760'; DistinctRec = '760' }
        $snapView = New-Row @{ Total = '760'; Distinct = '760'; Cycles = '5' }
        (Test-XdrGate_SnapshotNoDupAccum -Row $snapView -Key 'RecordId(content-hash)').Pass | Should -BeTrue   # blind: looks healthy
        $d = Test-XdrGate_VolatileHash -Row $volatile -Key 'RecordId(content-hash · keyless)' -PollCycles 5 -TableCycles 5
        $d.Pass         | Should -BeFalse                                                                       # caught here
        $d.Inconclusive | Should -BeFalse
        $d.Detail       | Should -Match 'volatileHashFields'
    }
    It 'a fully-volatile singleton (every cycle a fresh id · CheckAppGovernanceOnboarding pre-fix) → FAIL (TableCycles≈pollCycles, dupFactor=1)' {
        $vol = New-Row @{ Total = '26'; DistinctRec = '26' }   # dupFactor 1 · a fresh row each of 26 cycles
        (Test-XdrGate_VolatileHash -Row $vol -Key 'RecordId(content-hash · keyless)' -PollCycles 26 -TableCycles 26).Pass | Should -BeFalse
    }
    It 'a stable SNAPSHOT that legitimately re-emits across cycles (dupFactor>=2 over >=2 table cycles) → PASS (collapses to a stable set)' {
        # Belt-and-braces: even if a few cycles DO land rows (skip lagged a cycle), a dupFactor>=2 proves the hash IS
        # stabilizing (152 stable rules seen across 2 landed cycles = 304 rows → dupFactor 2) → healthy re-emit → PASS.
        $stable = New-Row @{ Total = '304'; DistinctRec = '152' }   # dupFactor 2
        $d = Test-XdrGate_VolatileHash -Row $stable -Key 'RecordId(content-hash · keyless)' -PollCycles 5 -TableCycles 2
        $d.Pass         | Should -BeTrue
        $d.Inconclusive | Should -BeFalse
    }
    It '<2 poll cycles (re-emit not exercised) → INCONCLUSIVE, NOT pass' {
        $r = New-Row @{ Total = '152'; DistinctRec = '152' }
        $d = Test-XdrGate_VolatileHash -Row $r -Key 'k' -PollCycles 1 -TableCycles 1
        $d.Pass         | Should -BeFalse
        $d.Inconclusive | Should -BeTrue
    }
    It 'a checkpoint reset in the window churned the RecordId set → INCONCLUSIVE (reset-aware · NOT a false RED)' {
        $vol = New-Row @{ Total = '760'; DistinctRec = '760' }
        (Test-XdrGate_VolatileHash -Row $vol -Key 'k' -PollCycles 5 -TableCycles 5 -ResetsInWindow 1).Inconclusive | Should -BeTrue
    }
    It '0 rows with LEGIT-NO-DATA proven → vacuous PASS (nothing emitted to accumulate)' {
        (Test-XdrGate_VolatileHash -Row (New-Row @{ Total = '0'; DistinctRec = '0' }) -Key 'k' -PollCycles 5 -TableCycles 0 -LegitNoDataProven $true).Pass | Should -BeTrue
    }
    It '0 rows WITHOUT a proof → INCONCLUSIVE, NOT pass' {
        (Test-XdrGate_VolatileHash -Row (New-Row @{ Total = '0'; DistinctRec = '0' }) -Key 'k' -PollCycles 5 -TableCycles 0).Inconclusive | Should -BeTrue
    }
    It 'null row → INCONCLUSIVE, NOT pass' {
        $n = Test-XdrGate_VolatileHash -Row $null -Key 'k' -PollCycles 5 -TableCycles 5
        $n.Pass         | Should -BeFalse
        $n.Inconclusive | Should -BeTrue
    }
}

# ── Executor contract · Invoke-XdrKqlQuery is the seam both bugs lived in. It must (a) pass the query via az's
#    @FILE convention — NOT inline (a 76-col gate query is ~10KB · overruns the Windows ~8191-char command-line
#    limit → az exit=1 · WS4.3 live-hit 2026-06-14) and NOT the @- stdin form (that EOFs) — and (b) return Data as
#    a BARE ARRAY of row-hashtables read by NAME. `az` is mocked so this stays fully offline; we assert the SHAPE.
Describe 'F-A · Invoke-XdrKqlQuery executor contract (offline · az mocked)' {
    It 'passes the query via az @file (handles >8KB high-col queries · the query lives in the FILE, not the arg)' {
        $script:capturedArgs = $null; $script:fileBody = $null
        function az {
            $script:capturedArgs = $args
            for ($i = 0; $i -lt $args.Count; $i++) {
                if ($args[$i] -eq '--analytics-query' -and $args[$i + 1] -match '^@(.+)$') { $script:fileBody = Get-Content $Matches[1] -Raw }
            }
            $global:LASTEXITCODE = 0; '[]'   # shadow `az` · LASTEXITCODE=0 so no retry fires
        }
        $null = Invoke-XdrKqlQuery -Query 'MyTable | count' -Label 't'
        ($script:capturedArgs -join ' ') | Should -Match '--analytics-query @'   # @file form, NOT inline
        $script:fileBody | Should -Match 'MyTable \| count'                       # the query lives IN the file
        Remove-Item function:az -ErrorAction SilentlyContinue
    }
    It 'FLATTENS a multi-line here-string query to ONE line in the @file (az would truncate inline at a newline)' {
        # The gates build readable multi-line queries; az under PowerShell would otherwise see only the
        # first line and drop every | summarize / | project clause → projected cols vanish → false 0s.
        $script:fileBody = $null
        function az {
            for ($i = 0; $i -lt $args.Count; $i++) {
                if ($args[$i] -eq '--analytics-query' -and $args[$i + 1] -match '^@(.+)$') { $script:fileBody = Get-Content $Matches[1] -Raw }
            }
            $global:LASTEXITCODE = 0; '[]'
        }
        $multi = @"
Defender_Operations_CL | where TimeGenerated > ago(30m)
| summarize Count=count()
| project Pass = Count >= 1, Count
"@
        $null = Invoke-XdrKqlQuery -Query $multi -Label 't'
        $script:fileBody | Should -Not -Match "`n"        # flattened · no embedded newline survives in the file
        $script:fileBody | Should -Match 'summarize Count=count\(\)'   # the dropped-on-truncation clause IS present
        $script:fileBody | Should -Match 'project Pass = Count >= 1, Count'
        Remove-Item function:az -ErrorAction SilentlyContinue
    }
    It 'returns Data as a BARE ARRAY of row-hashtables with NAMED columns (no .tables[].rows envelope)' {
        function az { '[{"Pass":"True","Count":"34","MostRecent":"2026-06-05T00:00:00Z"}]' }
        $global:LASTEXITCODE = 0
        $r = Invoke-XdrKqlQuery -Query 'q' -Label 't'
        $r.Success | Should -BeTrue
        @($r.Data).Count | Should -Be 1
        $row = @($r.Data) | Select-Object -First 1
        $row | Should -BeOfType ([System.Collections.IDictionary])
        $row['Pass']  | Should -Be 'True'
        $row['Count'] | Should -Be '34'
        Remove-Item function:az -ErrorAction SilentlyContinue
    }
    It 'a zero-row result (az emits whitespace/empty) normalises to an empty Data array (Success=$true)' {
        function az { '' }
        $global:LASTEXITCODE = 0
        $r = Invoke-XdrKqlQuery -Query 'q' -Label 't'
        $r.Success | Should -BeTrue
        @($r.Data).Count | Should -Be 0
        Remove-Item function:az -ErrorAction SilentlyContinue
    }
    It 'a non-zero az exit surfaces Success=$false with an error and an empty Data array' {
        function az { $global:LASTEXITCODE = 1; '' }
        $r = Invoke-XdrKqlQuery -Query 'q' -Label 't'
        $r.Success | Should -BeFalse
        $r.Error   | Should -Match 'az query exit='
        @($r.Data).Count | Should -Be 0
        Remove-Item function:az -ErrorAction SilentlyContinue
    }
}

# ── F-A2 · 2026-06-12 live-run gate cures (stale-gate classes found by the first Hour window on the
# shipped pilot: D3 ignored the capability-absent + yielded-start terminal classes (7+1 of 13 polls);
# D7 hardcoded the dead flat-5m era (450s) instead of the per-op WS2 cadence tiers AND measured gaps
# across op boundaries; D8/Reauth queried the sampling-thinned AppTraces host-mirror while AppEvents
# carries Track-XdrEvent reliably (live evidence: N==Raw for every event name). ─────────────────────
Describe 'F-A2 · live-run gate cures' {
    It 'D3 KQL counts capability-absent + yielded-start terminals' {
        $text = Get-Content $script:Tool -Raw
        $d3 = [regex]::Match($text, '(?s)Gate: D3.*?Invoke-XdrKqlQuery').Value
        $d3 | Should -Match 'Capability\.OpUnavailable'
        $d3 | Should -Match 'Entry\.Poll\.SingleFlight\.Contended'
    }
    It 'D7 KQL partitions gaps per op (no cross-op prev) and the block consumes the manifest cadence map' {
        $text = Get-Content $script:Tool -Raw
        $d7 = [regex]::Match($text, '(?s)Gate: D7.*?Add-XdrGateDecision').Value
        $d7 | Should -Match 'prev\(Op\)'
        $d7 | Should -Match 'Get-XdrCadenceVerdict'
        $d7 | Should -Not -Match '450'
    }
    It 'D8 and Reauth query AppEvents, not the sampled AppTraces mirror' {
        $text = Get-Content $script:Tool -Raw
        $d8 = [regex]::Match($text, '(?s)Gate: D8 Auth.*?Invoke-XdrKqlQuery').Value
        $d8 | Should -Match 'AppEvents'
        $d8 | Should -Not -Match 'AppTraces \|'   # query-usage only (the comment may NAME it)
        $re = [regex]::Match($text, '(?s)Gate: Reauth.*?Invoke-XdrKqlQuery').Value
        $re | Should -Match 'AppEvents'
    }
    It 'Get-XdrCadenceVerdict: 10m op gap 850s ok / 950s bad (>1.5x tier) / a <30s poll gap is NO LONGER bad (double-fire DROPPED · SnapshotNoDupAccum owns dup EMISSIONs) / unmapped op skipped / no rows Total=0' {
        $map = @{ GetHistory = 600; GetTenantContext = 21600 }
        $ok = Get-XdrCadenceVerdict -GapRows @(@{ Op='GetHistory'; MaxGap='850'; MinGap='590' }, @{ Op='UnknownOp'; MaxGap='10'; MinGap='10' }) -CadenceSecondsByOp $map
        $ok.Bad | Should -Be 0
        $ok.Total | Should -Be 1
        (Get-XdrCadenceVerdict -GapRows @(@{ Op='GetHistory'; MaxGap='950'; MinGap='590' }) -CadenceSecondsByOp $map).Bad | Should -Be 1
        # a <30s MinGap is NO LONGER a defect (a yield/dedup double-poll has no data impact · a real dup EMISSION REDs in SnapshotNoDupAccum · §10 xix)
        (Get-XdrCadenceVerdict -GapRows @(@{ Op='GetHistory'; MaxGap='600'; MinGap='20' }) -CadenceSecondsByOp $map).Bad | Should -Be 0
        (Get-XdrCadenceVerdict -GapRows @() -CadenceSecondsByOp $map).Total | Should -Be 0
    }
    It 'Get-XdrCadenceVerdict: P90-robust - a single recovered blip (p90 on-cadence, max under 3x tier) is NOT bad; sustained-late (p90 over 1.5x tier) and stall (max over 3x tier) ARE bad; a legacy row without P90Gap keeps the strict max-over-1.5x fallback' {
        $map = @{ GetHistory = 600 }
        # single recovered blip: p90 on-cadence (700 < 900 = 1.5x tier), max 1173 (=1.96x tier) but < 3x tier (1800) -> EXCUSED (outlier)
        (Get-XdrCadenceVerdict -GapRows @(@{ Op='GetHistory'; MaxGap='1173'; MinGap='590'; P90Gap='700' }) -CadenceSecondsByOp $map).Bad | Should -Be 0
        # sustained lateness: p90 950 > 1.5x tier (900) -> bad (>=90 pct of gaps late, a real off-schedule defect)
        (Get-XdrCadenceVerdict -GapRows @(@{ Op='GetHistory'; MaxGap='1000'; MinGap='590'; P90Gap='950' }) -CadenceSecondsByOp $map).Bad | Should -Be 1
        # stall: max 2000 > 3x tier (1800) -> bad even with p90 on-cadence (the op stopped for a cycle-and-a-half+)
        (Get-XdrCadenceVerdict -GapRows @(@{ Op='GetHistory'; MaxGap='2000'; MinGap='590'; P90Gap='650' }) -CadenceSecondsByOp $map).Bad | Should -Be 1
        # legacy row (no P90Gap) -> strict max > 1.5x tier fallback preserved: 950 > 900 -> bad (never silently weaker)
        (Get-XdrCadenceVerdict -GapRows @(@{ Op='GetHistory'; MaxGap='950'; MinGap='590' }) -CadenceSecondsByOp $map).Bad | Should -Be 1
    }
    It 'Get-XdrManifestCadenceMap loads per-op declared cadence seconds from the manifest' {
        $map = Get-XdrManifestCadenceMap -Portal 'Defender' -Category 'Operations'
        $map['GetHistory'] | Should -Be 600
        $map['GetTenantContext'] | Should -Be 21600
    }
    # FIX 4 (2026-07-01 robustness · safe-additive): an UNPARSEABLE manifest cadence used to be SILENTLY dropped →
    # Get-XdrCadenceVerdict skipped the op → a real cadence defect on it became a false-PASS (the inverse hazard).
    # Now the unparseable op routes D7 to a LOUD INCONCLUSIVE — never a silent skip. Parseable ops are UNAFFECTED.
    It 'FIX-4 · Get-XdrCadenceVerdict: an unparseable-cadence op (parseable ops CLEAN) → Inconclusive, NOT a silent skip/PASS' {
        $map = @{ GetHistory = 600 }   # note: the unparseable op is deliberately ABSENT from the map (as the real drop would leave it)
        $v = Get-XdrCadenceVerdict -GapRows @(@{ Op='GetHistory'; MaxGap='850'; MinGap='590' }) -CadenceSecondsByOp $map -UnparseableOps @('BadCadenceOp')
        $v.Bad          | Should -Be 0
        $v.Inconclusive | Should -BeTrue
        $v.Unparseable  | Should -Be 1
        $v.Detail       | Should -Match 'BadCadenceOp'
        $v.Detail       | Should -Match 'unparseable-cadence'
    }
    It 'FIX-4 · M1 · a GENUINE Bad>0 on a PARSEABLE op still FAILs even alongside an unparseable op (real defect NEVER masked by inconclusive)' {
        $map = @{ GetHistory = 600 }
        $v = Get-XdrCadenceVerdict -GapRows @(@{ Op='GetHistory'; MaxGap='950'; MinGap='590' }) -CadenceSecondsByOp $map -UnparseableOps @('BadCadenceOp')
        $v.Bad          | Should -Be 1          # the parseable op's MaxGap 950 > 1.5×600 tier is a real cadence defect
        $v.Inconclusive | Should -BeFalse       # NOT softened to inconclusive by the unparseable sibling — still a hard FAIL
    }
    It 'FIX-4 · no unparseable ops (default empty) → behaviour is byte-identical to before (never inconclusive · parseable ops unaffected)' {
        $map = @{ GetHistory = 600 }
        $v = Get-XdrCadenceVerdict -GapRows @(@{ Op='GetHistory'; MaxGap='850'; MinGap='590' }) -CadenceSecondsByOp $map
        $v.Bad          | Should -Be 0
        $v.Inconclusive | Should -BeFalse
        $v.Unparseable  | Should -Be 0
    }
    # CAP-ABSENT POSTURE (F18 · 2026-07-03): a cap-absent op (403/404 · backed-off polling) has a large inter-poll gap
    # that is CORRECT, not a cadence defect → Get-XdrCadenceVerdict must SKIP it. Live: GetRecommendations 21625s gap,
    # both polls 403/404. Without the skip its gap > 1.5×tier false-FAILs D7 (the anti-tolerate discrimination: a real
    # cadence defect on an ACTIVE op still FAILs; only the posture op's backoff is excused).
    It 'CAP-ABSENT · Get-XdrCadenceVerdict: a cap-absent op with a would-be-bad gap is SKIPPED (Bad=0, Total=0) · an active op is still measured' {
        $map = @{ GetRecommendations = 3600; GetHistory = 600 }
        # cap-absent op alone: its 21625s gap would be Bad without the skip → skipped → Total=0, Bad=0
        $v = Get-XdrCadenceVerdict -GapRows @(@{ Op='GetRecommendations'; MaxGap='21625'; MinGap='21625' }) -CadenceSecondsByOp $map -CapAbsentOps @('GetRecommendations')
        $v.Bad   | Should -Be 0
        $v.Total | Should -Be 0
        # M1 · a GENUINE cadence defect on an ACTIVE (non-cap-absent) op still FAILs even alongside a skipped cap-absent op
        $v2 = Get-XdrCadenceVerdict -GapRows @(@{ Op='GetRecommendations'; MaxGap='21625'; MinGap='21625' }, @{ Op='GetHistory'; MaxGap='950'; MinGap='590' }) -CadenceSecondsByOp $map -CapAbsentOps @('GetRecommendations')
        $v2.Bad   | Should -Be 1     # GetHistory's real defect NOT masked
        $v2.Total | Should -Be 1     # only the active op counted
    }
    It 'FIX-4 · Get-XdrManifestCadenceMap records an unparseable Cadence into the [ref]$UnparseableOps out-param (not a silent drop) · parseable map unchanged' {
        # A synthetic manifest with one parseable + one unparseable Cadence, so the collection is provable offline.
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("xdrlr-cadfix-" + [Guid]::NewGuid().ToString('N'))
        $manDir = Join-Path (Resolve-Path "$PSScriptRoot/../../../").Path 'manifests/Defender'
        # Write a throwaway manifest under the real manifests dir so the function's Join-Path resolves it, then remove it.
        $tmpManifest = Join-Path $manDir '__CadFixSelfTest.psd1'
        try {
            Set-Content -Path $tmpManifest -Encoding UTF8 -Value @'
@{
    Operations = @(
        @{ OperationKey = 'GoodCad'; Cadence = '00:05:00' },
        @{ OperationKey = 'BadCad';  Cadence = 'not-a-timespan' }
    )
}
'@
            $unparse = [System.Collections.ArrayList]::new()
            $map = Get-XdrManifestCadenceMap -Portal 'Defender' -Category '__CadFixSelfTest' -UnparseableOps $unparse
            $map['GoodCad']       | Should -Be 300           # parseable op still in the map, unchanged
            $map.ContainsKey('BadCad') | Should -BeFalse     # unparseable op is not in the parse map
            @($unparse)           | Should -Contain 'BadCad' # but it IS surfaced (loud) via the out-param — no silent loss
        } finally {
            Remove-Item $tmpManifest -Force -ErrorAction SilentlyContinue
            Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ── F-A3 · 2026-06-12 deploy-aware window (postdeploy verification straddles the stop/cutover gap: a 120m
# window reaches before the deploy → freeze-gap + old-build telemetry false-fail D7/AppExc/D0; a hand-scoped
# window clips the cold-start Boot probe and catches an in-flight poll → false-fail D0/D3. The verifier must
# floor the window at the deploy instant AND give the newest in-flight poll a grace to close). ───────────
Describe 'F-A3 · deploy-aware window floor + D3 in-flight grace' {
    It 'an absolute -DeployedSinceUtc floors the sinceClause at the deploy instant (not ago(Nm))' {
        $text = Get-Content $script:Tool -Raw
        $text | Should -Match 'DeployedSinceUtc'
        # the since clause must be able to anchor at a datetime literal, not only a relative ago() window
        $text | Should -Match 'TimeGenerated >= datetime\('
    }
    It 'D3 KQL gives the newest unclosed poll a grace window (does not penalize an in-flight start); orphan-close is EXCUSED (sampling/window artifact); stuck and double-close still RED' {
        $text = Get-Content $script:Tool -Raw
        $d3 = [regex]::Match($text, '(?s)Gate: D3.*?Invoke-XdrKqlQuery').Value
        $d3 | Should -Match 'LastSeen'
        $d3 | Should -Match 'ago\(3m\)'
        # 2026-07-04: orphan-close (Started==0 and Closed>0; the poll COMPLETED, its Started was sampled/window-clipped) is
        # NO LONGER penalised - the non-fanout Bad must NOT contain the bare orphan-close term. This true guard is immune to
        # the FanStarted==0 substring collision (the KQL string is 'FanStarted == 0 and LastSeen', not 'Started == 0 and Closed > 0').
        $d3 | Should -Not -Match 'Started == 0 and Closed > 0'
        # stuck (started, never closed, stale) still RED; double-close still RED
        $d3 | Should -Match 'Started >= 1 and Closed == 0'
        $d3 | Should -Match 'not\(IsFanout\) and \(Closed > 1'
    }
    It 'D3 KQL tolerates a Durable at-least-once RETRY (keys on completion · no bare Started>1 false-flag)' {
        $text = Get-Content $script:Tool -Raw
        $d3 = [regex]::Match($text, '(?s)Gate: D3.*?Invoke-XdrKqlQuery').Value
        # REGRESSION (2026-06-21 P5-1): a SEQUENTIAL retry (Started>1 but Closed>=1 · e.g. a cold-start poll whose 1st
        # attempt's instance recycled and a later attempt completed) must PASS — Start-count is NOT an at-least-once
        # invariant; the EXACTLY-ONCE data proof is ExactlyOnce/SnapshotNoDupAccum. The non-fanout bad keys on Closed.
        $d3 | Should -Not -Match 'not\(IsFanout\) and \(Started > 1'
        $d3 | Should -Match 'not\(IsFanout\) and \(Closed > 1'
    }
}

# ── WS4.3 · the per-Op gates (D8f/D8g/D8h/ExactlyOnce) each assert ONE Operation's ProjectionMap/NaturalKey
# contract, but a category table holds EVERY op's rows. Pre-fix they queried `$workspaceTable | where
# $sinceClause` with NO OperationKey filter → GetTenantContext rows evaluated against GetHistory's spec →
# guaranteed false-fail (the keystone verifier bug the operator caught via live screenshots). The fix scopes
# each per-op query to the resolved op's rows via Get-XdrOpScopedClause. D12's matcher was ALSO wrong (loose
# portal/category token OR'd in → false-PASS on Microsoft's stock 'Defender' packages even with ours absent). ─
Describe 'WS4.3 · Get-XdrOpScopedClause (per-op gate scoping)' {
    It 'op-scopes to the resolved Operation OperationKey when present' {
        $c = Get-XdrOpScopedClause -SinceClause 'TimeGenerated >= datetime(2026-01-01)' -Operation @{ OperationKey = 'GetHistory' } -FallbackKey ''
        $c | Should -Be "TimeGenerated >= datetime(2026-01-01) and Operation == 'GetHistory'"
    }
    It 'falls back to -FallbackKey (the -OperationKey param) when the op object carries no key' {
        $c = Get-XdrOpScopedClause -SinceClause 'T >= x' -Operation $null -FallbackKey 'GetPending'
        $c | Should -Be "T >= x and Operation == 'GetPending'"
    }
    It 'returns the BARE time clause when neither the op nor a fallback yields a key (gate guard fires instead)' {
        $c = Get-XdrOpScopedClause -SinceClause 'T >= x' -Operation @{} -FallbackKey ''
        $c | Should -Be 'T >= x'   # never silently scope to a wrong/empty key
    }
    It 'prefers the op object key over the fallback (per-op resolution wins for multi-op manifests)' {
        $c = Get-XdrOpScopedClause -SinceClause 'T >= x' -Operation @{ OperationKey = 'GetTenantContext' } -FallbackKey 'GetHistory'
        $c | Should -Match "Operation == 'GetTenantContext'"
    }
    It 'defensively escapes a single-quote in the op key by DOUBLING it (KQL literal · consistent with the sibling op-scoped clauses)' {
        $c = Get-XdrOpScopedClause -SinceClause 'T >= x' -Operation @{ OperationKey = "Get'X" } -FallbackKey ''
        $c | Should -Be "T >= x and Operation == 'Get''X'"
    }
}

Describe 'WS4.3 · per-op gate QUERIES are op-scoped (not bare $sinceClause)' {
    BeforeAll { $script:vtext = Get-Content $script:Tool -Raw }
    It 'D8f resolves an op-scoped clause and its KQL uses it (not the bare since clause)' {
        $b = [regex]::Match($script:vtext, "(?s)Gate: D8f.*?Invoke-XdrKqlQuery -Query \`$q -Label 'D8f'").Value
        $b | Should -Match 'Get-XdrOpScopedClause -SinceClause \$sinceClause -Operation \$d8fOp'
        $b | Should -Match 'where \$d8fClause'
        $b | Should -Not -Match 'where \$sinceClause\b'
    }
    It 'D8f also emits a per-col SOURCE non-null count (<col>_src) for the legitimately-null discriminator (excludes empty + empty-containers [] [[]] {} null + the in-column sentinel)' {
        $b = [regex]::Match($script:vtext, "(?s)Gate: D8f.*?Invoke-XdrKqlQuery -Query \`$q -Label 'D8f'").Value
        # presence guard + the EMPTY-CONTAINER exclusion set (D8f Fix 2): a genuinely-present, non-empty-container source
        # value only. An empty array [] / array-of-empty [[]] / empty object {} / json null / empty string is LEGIT-empty.
        $b | Should -Match "_src=countif\(isnotnull\(.*and tostring\(.*!in \('','\[\]','\[\[\]\]','\{\}','null'\)"
        $b | Should -Match 'ConvertTo-XdrRawJsonAccessor'
        # A PROMOTED field's RawJson value is the in-column sentinel {"__xdrlr_in_column":true}; D8f must NOT count it
        # as a source value (the COLUMN is the source of truth · <col>_pop checks it) else a legitimately-EMPTY promoted
        # col false-fails (live-caught 2026-06-17 Operations GetTenantContext Irm/Itp/Mdi/Sentinel MtpPermissions).
        $b | Should -Match "!contains '__xdrlr_in_column'"
    }
    It 'D8f parses RawJson ONCE via extend _rj (not per-col · the 76-col scalability fix)' {
        $b = [regex]::Match($script:vtext, "(?s)Gate: D8f.*?Invoke-XdrKqlQuery -Query \`$q -Label 'D8f'").Value
        $b | Should -Match 'extend _rj = parse_json\(RawJson\)'
        $b | Should -Not -Match '_src=countif\(isnotempty\(tostring\(parse_json\(RawJson\)'   # no per-col re-parse
    }
    It 'D8g resolves an op-scoped clause and its KQL uses it' {
        $b = [regex]::Match($script:vtext, "(?s)Gate: D8g.*?Invoke-XdrKqlQuery -Query \`$q -Label 'D8g'").Value
        $b | Should -Match 'Get-XdrOpScopedClause -SinceClause \$sinceClause -Operation \$d8gOp'
        $b | Should -Match 'where \$d8gClause'
        $b | Should -Not -Match 'where \$sinceClause\b'
    }
    It 'D8h resolves an op-scoped clause and its KQL uses it' {
        $b = [regex]::Match($script:vtext, "(?s)Gate: D8h.*?Invoke-XdrKqlQuery -Query \`$q -Label 'D8h'").Value
        $b | Should -Match 'Get-XdrOpScopedClause -SinceClause \$sinceClause -Operation \$d8hOp'
        $b | Should -Match 'where \$d8hClause'
        $b | Should -Not -Match 'where \$sinceClause\b'
    }
    It 'ExactlyOnce resolves an op-scoped clause and its KQL uses it' {
        $b = [regex]::Match($script:vtext, "(?s)Gate: ExactlyOnce.*?Invoke-XdrKqlQuery -Query \`$q -Label 'ExactlyOnce'").Value
        $b | Should -Match 'Get-XdrOpScopedClause -SinceClause \$sinceClause -Operation \$eoOp'
        $b | Should -Match 'where \$eoClause'
        $b | Should -Not -Match 'where \$sinceClause\b'
    }
}

Describe 'WS4.3 · D12 V3-surface matcher requires product AND portal token (no false-pass on stock MS packages)' {
    BeforeAll { $script:vtext = Get-Content $script:Tool -Raw }
    It 'builds a product-token regex AND a portal-token regex' {
        $script:vtext | Should -Match "\`$productRegex = 'XdrLogRaider\|xdrlr'"
        $script:vtext | Should -Match '\$portalRegex  = \[Regex\]::Escape\(\$Portal\)'
    }
    It 'requires BOTH tokens to match (the AND closes the false-pass on Microsoft stock Defender solutions)' {
        $d12 = [regex]::Match($script:vtext, "(?s)Gate: D12.*?Add-XdrGateResult -GateId 'D12'.*?-Detail \`$detail").Value
        $d12 | Should -Match '\(\$n -match \$productRegex\) -and \(\$n -match \$portalRegex\)'
    }
    It 'no longer OR-s the loose derived portal/category tokens into the surface regex' {
        $script:vtext | Should -Not -Match '\$surfaceRegex = "XdrLogRaider\|xdrlr\|\$derivedAlt"'
    }
    It 'queries the ARM surface through the RETRYING helper (transient must not false-fail · live-hit 2026-06-14)' {
        $d12 = [regex]::Match($script:vtext, "(?s)Gate: D12.*?Add-XdrGateResult -GateId 'D12'.*?-Detail \`$detail").Value
        $d12 | Should -Match 'Get-XdrArmRestValue -Uri \$defsUri'
        $d12 | Should -Match 'Get-XdrArmRestValue -Uri \$pkgsUri'
        $d12 | Should -Not -Match '& az rest --method get'   # no bare un-retried az rest in the matcher path
    }
    It 'Get-XdrArmRestValue retries az rest and returns $null only after exhausting attempts' {
        $body = [regex]::Match($script:vtext, '(?s)function Get-XdrArmRestValue.*?\n\}').Value
        $body | Should -Match 'for \(\$a = 1; \$a -le \$attempts'
        $body | Should -Match 'Start-Sleep -Seconds'
        $body | Should -Match 'return \$null'
    }
}

Describe 'WS4.3 · Invoke-XdrKqlQuery retries transient LA errors (no false-fail on a healthy connector)' {
    BeforeAll { $script:vtext = Get-Content $script:Tool -Raw }
    It 'wraps the az query in a bounded retry loop' {
        $body = [regex]::Match($script:vtext, '(?s)function Invoke-XdrKqlQuery.*?\n\}').Value
        $body | Should -Match 'for \(\$a = 1; \$a -le \$attempts'
        $body | Should -Match 'Start-Sleep -Seconds'
    }
    It 'returns a genuine zero-row result immediately (empty window is NOT retried)' {
        $body = [regex]::Match($script:vtext, '(?s)function Invoke-XdrKqlQuery.*?\n\}').Value
        $body | Should -Match 'IsNullOrWhiteSpace\(\$raw\)'
        $body | Should -Match 'genuine zero-row'   # the early-return branch (success-with-empty-Data · not retried)
    }
    It 'reports failure only after exhausting all attempts' {
        $body = [regex]::Match($script:vtext, '(?s)function Invoke-XdrKqlQuery.*?\n\}').Value
        $body | Should -Match 'after \$attempts attempts'
    }
    It 'passes the query via az @file (not inline) so a high-col query cannot overrun the ~8KB command-line limit' {
        $body = [regex]::Match($script:vtext, '(?s)function Invoke-XdrKqlQuery.*?\n\}').Value
        $body | Should -Match 'GetTempFileName'
        $body | Should -Match 'analytics-query "@\$tmp"'
        $body | Should -Match 'Remove-Item \$tmp'                      # temp file is cleaned up
        $body | Should -Not -Match 'analytics-query \$flatQuery'       # no inline pass-through anymore
    }
}

# ── V-M4 (THE KEYSTONE) · D2/D6/MinRows/CorrelationId/D8c ran ONCE category-globally, so under -AllOps a single
#    op landing 0 rows was INVISIBLE (MinRows count()>=1 passed on a SIBLING op's rows · the prior "C6-proven"
#    starved-fan-out-child hole). They are MOVED INTO the per-Op loop + op-scoped, so every deployed op must
#    INDEPENDENTLY land ≥1 row + pass empty/RawJson/CorrelationId/envelope. MinRows gets the D8f LEGIT-NO-DATA
#    tolerance (an op that polled to a terminal Succeeded/OpUnavailable yet legitimately landed 0 rows → PASS,
#    NOT a hard fail; an op with NO terminal poll stays a real FAIL). ─────────────────────────────────────────
Describe 'V-M4 · Test-XdrOpPolledToTerminal (LEGIT-NO-DATA probe · live-az mocked)' {
    AfterEach { Remove-Item function:Invoke-XdrKqlQuery -ErrorAction SilentlyContinue }
    It 'returns $true when the op reached a terminal poll (Succeeded/OpUnavailable count > 0)' {
        function Invoke-XdrKqlQuery { param($Query, $Label) @{ Success = $true; Error = $null; Data = @(@{ n = '3' }) } }
        (Test-XdrOpPolledToTerminal -SinceClause 'T > ago(30m)' -OperationKey 'GetHistory') | Should -BeTrue
    }
    It 'returns $false when the op has NO terminal poll (count = 0 · a genuinely-unobserved op stays a real fail)' {
        function Invoke-XdrKqlQuery { param($Query, $Label) @{ Success = $true; Error = $null; Data = @(@{ n = '0' }) } }
        (Test-XdrOpPolledToTerminal -SinceClause 'T > ago(30m)' -OperationKey 'GetHistory') | Should -BeFalse
    }
    It 'fail-safe: a query error returns $false (does NOT mask a real 0-row fail behind a transient)' {
        function Invoke-XdrKqlQuery { param($Query, $Label) @{ Success = $false; Error = 'az query exit=1'; Data = @() } }
        (Test-XdrOpPolledToTerminal -SinceClause 'T > ago(30m)' -OperationKey 'GetHistory') | Should -BeFalse
    }
    It 'empty op key → $false (cannot probe an unknown op)' {
        function Invoke-XdrKqlQuery { param($Query, $Label) @{ Success = $true; Error = $null; Data = @(@{ n = '9' }) } }
        (Test-XdrOpPolledToTerminal -SinceClause 'T > ago(30m)' -OperationKey '') | Should -BeFalse
    }
    It 'scopes the poll probe to the op key + terminal names (Succeeded/OpUnavailable)' {
        $script:probeQ = $null
        function Invoke-XdrKqlQuery { param($Query, $Label) $script:probeQ = $Query; @{ Success = $true; Error = $null; Data = @(@{ n = '1' }) } }
        $null = Test-XdrOpPolledToTerminal -SinceClause 'T > ago(30m)' -OperationKey 'GetTenantContext'
        $script:probeQ | Should -Match "OperationKey\) == 'GetTenantContext'"
        $script:probeQ | Should -Match 'Entry\.Poll\.Succeeded'
        $script:probeQ | Should -Match 'Capability\.OpUnavailable'
    }
}

Describe 'V-M4 · MinRows op-scoped decision path (0 rows for THIS op is independently caught)' {
    # The pure MinRows fn fails on a 0-row op REGARDLESS of sibling ops' rows — op-scoping (a per-op WHERE) is what
    # makes the row count THIS op's only. This asserts the decision the loop body composes: 0 rows → fail, UNLESS the
    # op polled to a terminal state (LEGIT-NO-DATA → documented PASS).
    It 'an op that landed 0 rows → MinRows FAIL (the starved-op signal · not inconclusive)' {
        $d = Test-XdrGate_MinRows -Row (New-Row @{ Count = '0' })
        $d.Pass         | Should -BeFalse
        $d.Inconclusive | Should -BeFalse
    }
    It 'an op that landed ≥1 row → MinRows PASS' {
        (Test-XdrGate_MinRows -Row (New-Row @{ Count = '1' })).Pass | Should -BeTrue
    }
    # G1 prove-empty: the 0-row decision is the PURE Resolve-XdrZeroRowVerdict (terminal-poll + DIRECT-SOURCE verdict).
    # A 0-row op is GREEN only when the source is genuinely empty; data-at-source + 0-workspace = RED; polled-but-
    # unproven = INCONCLUSIVE (never a silent green). These test the fn directly (no live az).
    It 'prove-empty: 0 rows + polled + direct-source EMPTY → PASS (LEGIT-NO-DATA PROVEN)' {
        $d = Resolve-XdrZeroRowVerdict -Polled $true -LiveVerdict 'EMPTY'
        $d.Pass | Should -BeTrue; $d.Inconclusive | Should -BeFalse
    }
    It 'prove-empty: 0 rows + polled + direct-source CAP-ABSENT → PASS' {
        (Resolve-XdrZeroRowVerdict -Polled $true -LiveVerdict 'CAP-ABSENT').Pass | Should -BeTrue
    }
    It 'prove-empty: 0 workspace rows BUT direct-source returned DATA (PASS) → RED (FA not landing = real gap)' {
        $d = Resolve-XdrZeroRowVerdict -Polled $true -LiveVerdict 'PASS'
        $d.Pass | Should -BeFalse; $d.Inconclusive | Should -BeFalse
    }
    It 'prove-empty: 0 rows + direct-source RED-shape → RED' {
        (Resolve-XdrZeroRowVerdict -Polled $true -LiveVerdict 'RED-shape').Pass | Should -BeFalse
    }
    # POLL-OUTCOME reconcile (Fix 2): the direct-source probe is a SEPARATE sample of the source; the FA's OWN Entry.Poll.*
    # outcome (Get-XdrFaPollLandGap) is the truth for "did the FA receive NEW data it failed to land?". FaGapSignal: 0 = NO
    # gap (exactly-once DEDUP of unchanged/seen data — re-emit would dup-accumulate · OR async-EMPTY poll · OR emits within
    # history); 1 = real gap (NEW data received, never landed); -1 (default · no FA telemetry) preserves the direct-probe verdict.
    It 'poll-outcome: 0 rows + direct-source PASS + FaGapSignal=0 (deduped unchanged / empty / ever-landed) → PASS (exactly-once correct · NOT a gap)' {
        $d = Resolve-XdrZeroRowVerdict -Polled $true -LiveVerdict 'PASS' -FaGapSignal 0
        $d.Pass | Should -BeTrue; $d.Inconclusive | Should -BeFalse
    }
    It 'poll-outcome: 0 rows + direct-source PASS + FaGapSignal=1 (FA received NEW data, never landed) → RED (real gap)' {
        $d = Resolve-XdrZeroRowVerdict -Polled $true -LiveVerdict 'PASS' -FaGapSignal 1
        $d.Pass | Should -BeFalse; $d.Inconclusive | Should -BeFalse
    }
    It 'poll-outcome: 0 rows + direct-source PASS + NO FA telemetry (FaGapSignal=-1 default) → RED (back-compat · original direct-probe verdict)' {
        (Resolve-XdrZeroRowVerdict -Polled $true -LiveVerdict 'PASS' -FaGapSignal -1).Pass | Should -BeFalse
    }
    It 'prove-empty: polled but NO direct-source verdict wired → INCONCLUSIVE (unproven-0 is never a silent green)' {
        $d = Resolve-XdrZeroRowVerdict -Polled $true -LiveVerdict ''
        $d.Pass | Should -BeFalse; $d.Inconclusive | Should -BeTrue
    }
    It 'prove-empty: NO terminal poll → $null (caller keeps the original real-negative un-proven fail)' {
        Resolve-XdrZeroRowVerdict -Polled $false -LiveVerdict '' | Should -BeNullOrEmpty
    }
    # F18 PRODUCT-GATE (Fix 1): an op the engine pre-gates (Entry.RequiresProducts.Skipped · its RequiresProducts product is
    # ABSENT on this tenant, e.g. GetMdcPreviewFeatures needs MDC) lands 0 rows LEGITIMATELY, but the direct-source probe
    # BYPASSES the gate and returns PASS — so MinRows would false-fail "rows=0 BUT direct-source returned DATA". ProductGated
    # is checked FIRST so a stale direct-PASS cannot flip the verdict to RED.
    It 'product-gated: 0 rows + ProductGated → PASS regardless of a misleading direct-source PASS (the direct-probe bypasses the gate)' {
        $d = Resolve-XdrZeroRowVerdict -Polled $true -LiveVerdict 'PASS' -ProductGated $true
        $d.Pass         | Should -BeTrue
        $d.Inconclusive | Should -BeFalse
        $d.Detail       | Should -Match 'LEGIT product-gated'
        $d.Detail       | Should -Match 'Entry\.RequiresProducts\.Skipped'
    }
    It 'product-gated: PASS even when NOT polled and with no direct-source verdict (the product-gate skip is the proof)' {
        (Resolve-XdrZeroRowVerdict -Polled $false -LiveVerdict '' -ProductGated $true).Pass | Should -BeTrue
    }
    It 'NOT product-gated (default $false): the existing prove-empty logic is unchanged (back-compat)' {
        # a misleading direct-source PASS with no product-gate still RED (the FA-not-landing real gap)
        (Resolve-XdrZeroRowVerdict -Polled $true -LiveVerdict 'PASS').Pass | Should -BeFalse
        # genuine EMPTY still PASSes; un-proven still INCONCLUSIVE
        (Resolve-XdrZeroRowVerdict -Polled $true -LiveVerdict 'EMPTY').Pass | Should -BeTrue
        (Resolve-XdrZeroRowVerdict -Polled $true -LiveVerdict '').Inconclusive | Should -BeTrue
    }
}

# F18 PRODUCT-GATE (Fix 1) · Test-XdrOpProductGated mirrors Test-XdrOpPolledToTerminal but queries the engine's
# product-gate telemetry (Entry.RequiresProducts.Skipped). An op whose RequiresProducts product is absent on this tenant
# is pre-gated → 0 rows legitimately. Live-az is mocked via a shadowed Invoke-XdrKqlQuery (fully offline).
Describe 'F18 · Test-XdrOpProductGated (product-gate skip probe · live-az mocked)' {
    AfterEach { Remove-Item function:Invoke-XdrKqlQuery -ErrorAction SilentlyContinue }
    It 'returns $true when the op emitted Entry.RequiresProducts.Skipped (count > 0)' {
        function Invoke-XdrKqlQuery { param($Query, $Label) @{ Success = $true; Error = $null; Data = @(@{ n = '4' }) } }
        (Test-XdrOpProductGated -SinceClause 'T > ago(2h)' -OperationKey 'GetMdcPreviewFeatures') | Should -BeTrue
    }
    It 'returns $false when the op was NOT product-gated (count = 0 · a genuinely-unobserved op stays a real fail)' {
        function Invoke-XdrKqlQuery { param($Query, $Label) @{ Success = $true; Error = $null; Data = @(@{ n = '0' }) } }
        (Test-XdrOpProductGated -SinceClause 'T > ago(2h)' -OperationKey 'GetMdcPreviewFeatures') | Should -BeFalse
    }
    It 'fail-safe: a query error returns $false (does NOT mask a real 0-row fail behind a transient)' {
        function Invoke-XdrKqlQuery { param($Query, $Label) @{ Success = $false; Error = 'az query exit=1'; Data = @() } }
        (Test-XdrOpProductGated -SinceClause 'T > ago(2h)' -OperationKey 'GetMdcPreviewFeatures') | Should -BeFalse
    }
    It 'empty op key → $false (cannot probe an unknown op)' {
        function Invoke-XdrKqlQuery { param($Query, $Label) @{ Success = $true; Error = $null; Data = @(@{ n = '9' }) } }
        (Test-XdrOpProductGated -SinceClause 'T > ago(2h)' -OperationKey '') | Should -BeFalse
    }
    It 'scopes the probe to the op key + the product-gate event name (Entry.RequiresProducts.Skipped)' {
        $script:pgQ = $null
        function Invoke-XdrKqlQuery { param($Query, $Label) $script:pgQ = $Query; @{ Success = $true; Error = $null; Data = @(@{ n = '1' }) } }
        $null = Test-XdrOpProductGated -SinceClause 'T > ago(2h)' -OperationKey 'GetMdcPreviewFeatures'
        $script:pgQ | Should -Match "Name == 'Entry\.RequiresProducts\.Skipped'"
        $script:pgQ | Should -Match "OperationKey\) == 'GetMdcPreviewFeatures'"
    }
}

Describe 'V-M4 · the five moved gates are INSIDE the -AllOps loop, op-scoped, and op-tagged (no global blocks remain)' {
    BeforeAll {
        $script:vtext = Get-Content $script:Tool -Raw
        # the body of the -AllOps per-Op loop (from `foreach ($opKey` to its `# end foreach $opKey` close)
        $script:loopBody = [regex]::Match($script:vtext, '(?s)foreach \(\$opKey in \$opKeysToVerify\) \{.*?# end foreach \$opKey').Value
        $script:loopBody | Should -Not -BeNullOrEmpty
    }
    It 'MinRows is now op-scoped INSIDE the loop (where $opScoped · GateId tagged $opTag) — not a bare-$sinceClause global block' {
        $b = [regex]::Match($script:loopBody, "(?s)Gate: MinRows.*?Label 'MinRows'").Value
        $b | Should -Match 'where \$opScoped'
        $script:loopBody | Should -Match '"MinRows\$opTag"'
        # the prove-empty decision (terminal-poll + DIRECT-SOURCE verdict) is wired into the loop's MinRows decision
        # via the pure Resolve-XdrZeroRowVerdict (G1 · B4: wires existing Verify-XdrLiveContent proof, no new gate)
        $script:loopBody | Should -Match 'Resolve-XdrZeroRowVerdict'
        # the terminal-poll LIVENESS probe uses the WIDER $pollLivenessClause (not the deploy floor): the poll telemetry
        # (Entry.Poll.Succeeded | Capability.OpUnavailable) ingests into AppEvents ~20-40m LATE, so floor-bounding it
        # false-reads 0 polls on a healthy op. The _CL DATA gates stay op-scoped on $sinceClause (via $opScoped above).
        $script:loopBody | Should -Match 'Test-XdrOpPolledToTerminal -SinceClause \$pollLivenessClause -OperationKey \$opKey'
        $script:loopBody | Should -Match 'Get-XdrLiveSourceVerdict -OperationKey \$opKey'
    }
    It 'D2 / D6 / CorrelationId / D8c are op-scoped INSIDE the loop (where $opScoped · GateId tagged $opTag)' {
        foreach ($g in 'D2','D6','CorrelationId','D8c') {
            $b = [regex]::Match($script:loopBody, "(?s)Gate: $g .*?Label '$g'").Value
            $b | Should -Match 'where \$opScoped' -Because "$g must query the op-scoped clause inside the loop"
            $script:loopBody | Should -Match "`"$g`\`$opTag`""  -Because "$g GateId must be tagged with `$opTag so -AllOps ops don't collide"
        }
    }
    It 'the loop resolves the op + its op-scoped clause ONCE near the top ($loopOp + $opScoped)' {
        $script:loopBody | Should -Match '\$loopOp\s*=\s*Get-XdrManifestOperation -Portal \$Portal -Category \$Category -OperationKey \$opKey'
        $script:loopBody | Should -Match '\$opScoped\s*=\s*Get-XdrOpScopedClause -SinceClause \$sinceClause -Operation \$loopOp -FallbackKey \$opKey'
    }
    It 'the OLD category-global blocks are GONE (no top-level `if (''<gate>'' -in $gatesForWindow -and $workspaceTable)` outside the loop)' {
        # everything BEFORE the loop must not contain a global D2/D6/MinRows/CorrelationId/D8c gate block.
        $preLoop = $script:vtext.Substring(0, $script:vtext.IndexOf('foreach ($opKey in $opKeysToVerify)'))
        foreach ($g in 'D2','D6','MinRows','CorrelationId','D8c') {
            $preLoop | Should -Not -Match "if \('$g' -in \`$gatesForWindow -and \`$workspaceTable\)" -Because "$g's global block must have been MOVED into the loop (V-M4)"
        }
    }
    It 'preserves window-gate-list membership (the moved gates still gate on -in $gatesForWindow · lists unchanged)' {
        # Cold still carries MinRows/D2/D6; FirstIteration carries them + CorrelationId + D8c; Sustain carries D2/D6/D8c.
        $cold = [regex]::Match($script:vtext, "'Cold'\s*\{ @\(([^)]*)\) \}").Groups[1].Value
        $cold | Should -Match "'MinRows'"; $cold | Should -Match "'D2'"; $cold | Should -Match "'D6'"
        $fi = [regex]::Match($script:vtext, "'FirstIteration'\s*\{ @\(([^)]*)\) \}").Groups[1].Value
        $fi | Should -Match "'CorrelationId'"; $fi | Should -Match "'D8c'"; $fi | Should -Match "'MinRows'"
        # and the new V-B3/V-B4 gates are wired into Sustain + ConsecutiveSustain
        $sus = [regex]::Match($script:vtext, "'Sustain'\s*\{ @\(([^)]*)\) \}").Groups[1].Value
        $sus | Should -Match "'ChunkedLoss'"; $sus | Should -Match "'Truncation'"
    }
}

# ── V-B1 / V-B2 / V-B3 / V-B4 · the gate-body wiring (the queries are built correctly · az not invoked) ──
Describe 'V-B1/B2/B3/B4 · gate-body query wiring (structural · offline)' {
    BeforeAll { $script:vtext = Get-Content $script:Tool -Raw }
    It 'V-B1 · AppExceptions queries Entry.Fanout.Skipped and splits non-benign vs benign by Reason' {
        $b = [regex]::Match($script:vtext, "(?s)Gate: AppExceptions.*?-FanoutSkipRow \`$rowf\)").Value
        $b | Should -Match "Name == 'Entry\.Fanout\.Skipped'"
        $b | Should -Match "NonBenign=countif\(_reason has 'EntityResolution=' or _reason has 'incomplete DependsOn edge'\)"
        $b | Should -Match 'Benign=countif\(not\('
        $b | Should -Match '-FanoutSkipRow \$rowf'
    }
    It 'V-B2 · Entry.Enumeration.Failed is KEPT in the handled-failure list (verified a real event · NOT a phantom)' {
        $b = [regex]::Match($script:vtext, "(?s)\`$qpf = @`".*?`"@").Value
        $b | Should -Match "'Entry\.Enumeration\.Failed'"
        # all four handled-failure names present (none dropped)
        $b | Should -Match "'Entry\.Poll\.Failed'"
        $b | Should -Match "'Entry\.Fanout\.ParentPollFailed'"
        $b | Should -Match "'Entry\.Fanout\.Error'"
    }
    It 'V-B3 · ChunkedLoss gate queries DCE.Ingest.Chunked AllSucceeded==false and BLOCKS (not advisory)' {
        $b = [regex]::Match($script:vtext, "(?s)Gate: ChunkedLoss.*?Label 'ChunkedLoss'").Value
        $b | Should -Match "Name == 'DCE\.Ingest\.Chunked'"
        $b | Should -Match 'BadBatches=countif\(tobool\(Properties\.AllSucceeded\) == false\)'
        # NOT advisory: the Add-XdrGateDecision call for ChunkedLoss carries no -Advisory
        $call = [regex]::Match($script:vtext, "Add-XdrGateDecision -GateId 'ChunkedLoss'[^\r\n]*").Value
        $call | Should -Not -Match '-Advisory'
    }
    It 'V-B4 · Truncation gate queries Ingest.RowClamped + Ingest.ColumnClamped and is ADVISORY' {
        $b = [regex]::Match($script:vtext, "(?s)Gate: Truncation.*?Label 'Truncation\.Col'").Value
        $b | Should -Match "Name == 'Ingest\.RowClamped'"
        $b | Should -Match "Name == 'Ingest\.ColumnClamped'"
        # advisory: the decision call carries -Advisory $true
        $call = [regex]::Match($script:vtext, "Add-XdrGateDecision -GateId 'Truncation'[^\r\n]*").Value
        $call | Should -Match '-Advisory \$true'
    }
}

# ── V-M1 / V-M2 / V-M3 · gate-body + window-set wiring for the new verifier-hardening signals (structural · offline).
#    V-M1 = D1 must reconcile the LANDED side on the `Operation` envelope column (F2 dropped `OperationKey`); E-BLK2
#    already unified telemetry + the Operation column onto the BASE op key, so reading `Operation` makes fan-out
#    reconcile correctly. V-M2 = DrainStuck (never-completing drain · DrainComplete/CycleBudgetReached · BLOCKING).
#    V-M3 = BreakerSkip (Breaker.SkippedOpen visibility · advisory) + D10 fed a CurrentlyOpen net-open probe.
Describe 'V-M1/V-M2/V-M3 · verifier-hardening gate-body + window-set wiring (structural · offline)' {
    BeforeAll { $script:vtext = Get-Content $script:Tool -Raw }
    It 'V-M1 · D1 reconciles the LANDED side by `Operation` (NOT the F2-dropped key column)' {
        # Anchor on the actual `let rows` landed-side line (not the whole block · the comment narrates the old form).
        $rowsLine = [regex]::Match($script:vtext, 'let rows = \$workspaceTable \| where \$sinceClause\s*\r?\n\s*\| summarize Actual=count\(\) by Op=(\w+), Cid=CorrelationId').Groups[1].Value
        $rowsLine | Should -Be 'Operation'   # the surviving F2 envelope column · NOT OperationKey
        # the EVENT side still keys on the telemetry Properties.OperationKey (= base op key · E-BLK2) — that is correct
        $evtLine = [regex]::Match($script:vtext, "let evt = AppEvents \| where \`$sinceClause and Name == 'Entry\.Poll\.Succeeded'\s*\r?\n\s*\| extend Op=tostring\(Properties\.OperationKey\)").Value
        $evtLine | Should -Not -BeNullOrEmpty
    }
    It 'V-M2 · DrainStuck gate queries DrainComplete + CycleBudgetReached and BLOCKS (not advisory)' {
        $b = [regex]::Match($script:vtext, "(?s)Gate: DrainStuck.*?Label 'DrainStuck'").Value
        # FIX 2 (2026-07-01) split the query into two legs for lag-immunity: the Succeeded/DrainComplete leg over the WIDE
        # $pollLivenessClause, the CycleBudgetReached leg over the NARROW $sinceClause. Both event names are still queried.
        $b | Should -Match "Name == 'Entry\.Poll\.Succeeded'"
        $b | Should -Match "Name == 'Entry\.Poll\.CycleBudgetReached'"
        $b | Should -Match 'tobool\(Properties\.DrainComplete\) == true'
        $b | Should -Match 'StuckOps=countif\(Completes == 0 and Budget > 0\)'
        # BLOCKING: the DrainStuck decision call carries NO -Advisory
        $call = [regex]::Match($script:vtext, "Add-XdrGateDecision -GateId 'DrainStuck'[^\r\n]*").Value
        $call | Should -Not -Match '-Advisory'
    }
    It 'V-M3 · BreakerSkip gate queries Breaker.SkippedOpen and is ADVISORY' {
        $b = [regex]::Match($script:vtext, "(?s)Gate: BreakerSkip.*?Label 'BreakerSkip'").Value
        $b | Should -Match "Name == 'Breaker\.SkippedOpen'"
        $call = [regex]::Match($script:vtext, "Add-XdrGateDecision -GateId 'BreakerSkip'[^\r\n]*").Value
        $call | Should -Match '-Advisory \$true'
    }
    It 'V-M3 · D10 is fed a CurrentlyOpen net-open probe (broader lookback) and BLOCKS on a stuck-open breaker' {
        # Slice from the D10 header through the END of its Add-XdrGateDecision call (to the close paren of -Advisory ...).
        $b = [regex]::Match($script:vtext, "(?s)Gate: D10 Circuit breaker.*?Add-XdrGateDecision -GateId 'D10'[^\r\n]*").Value
        $b | Should -Match 'NetOpen = countif\(Name == .Breaker\.Opened.\) - countif\(Name == .Breaker\.Closed.\)'
        $b | Should -Match 'Test-XdrGate_D10 -Row \$row -CurrentlyOpen \$currentlyOpen'
        # severity routing: a stuck-open detection is BLOCKING (-Advisory only when NOT stuck-open)
        $b | Should -Match '-Advisory \(-not \$d10StuckOpen\)'
    }
    It 'BreakerSkip + DrainStuck are wired into Sustain AND ConsecutiveSustain window sets' {
        foreach ($w in 'Sustain','ConsecutiveSustain') {
            $set = [regex]::Match($script:vtext, "'$w'\s*\{ @\(([^)]*)\) \}").Groups[1].Value
            $set | Should -Match "'BreakerSkip'" -Because "$w must run the V-M3 breaker-skip visibility gate"
            $set | Should -Match "'DrainStuck'"  -Because "$w must run the V-M2 never-completing-drain gate"
        }
    }
    It 'm4 · the D8 gate body passes -SteadyState (Hour/Sustain/ConsecutiveSustain) for the T1-dominance advisory' {
        $script:vtext | Should -Match '\$isSteadyState = \$Window -in @\(.Hour.,.Sustain.,.ConsecutiveSustain.\)'
        $b = [regex]::Match($script:vtext, "(?s)Gate: D8 Auth chain healthy.*?Test-XdrGate_D8 -Row \`$row -SteadyState \`$isSteadyState").Value
        $b | Should -Not -BeNullOrEmpty
    }
    It 'm3 · the Reauth gate body computes poll cycles and passes -PollCycles for the reauth-loop advisory' {
        $b = [regex]::Match($script:vtext, "(?s)Gate: Reauth self-heal.*?Test-XdrGate_Reauth -Row \`$row -PollCycles \`$pollCycles").Value
        $b | Should -Match "Cycles=dcount\(tostring\(Properties\.CorrelationId\)\)"
        $b | Should -Not -BeNullOrEmpty
    }
    It 'm1 · the D8f LEGIT-NO-DATA path uses the loop-wide $legitNoData (single prove-empty signal) + emits an advisory CapabilityRegression gate on an OpUnavailable transition for a previously-populated op' {
        $b = [regex]::Match($script:vtext, "(?s)if \(\`$d8fDec\.Inconclusive -and -not \`$d8fDec\.Pass\) \{.*?Add-XdrGateDecision -GateId .D8f").Value
        $b | Should -Match 'if \(\$legitNoData\)'   # P1-1: the SAME prove-empty signal as MinRows/D2/D6, not a divergent telemetry-only re-probe
        $b | Should -Match "Name == .Capability\.OpUnavailable."
        $b | Should -Match 'Get-XdrCapabilityRegressionVerdict -WentUnavailable'
        $b | Should -Match "Add-XdrGateResult -GateId `"CapabilityRegression\`$opTag`""
        $b | Should -Match 'ago\(30d\)'   # the broader historical lookback for "was it ever populated?"
    }
}

# ════════════════════════════════════════════════════════════════════════════════════════════════
# §4.B TASK A · THROTTLE-BACKOFF · Get-XdrKqlBackoffSeconds (PURE · offline) + the 429-then-200 / persistent-429
# behavior of Invoke-XdrKqlQuery (az + Start-Sleep mocked so it stays fast + fully offline). The defect: a sustained
# LA query throttle SURVIVED the prior LINEAR 5·10·15·20·25s backoff → a HEALTHY connector read INCONCLUSIVE.
# The cure is EXPONENTIAL backoff + jitter + a Retry-After hint, WITHOUT breaking B5 (a truly-unexecutable query
# still ends Success=$false → INCONCLUSIVE, never a silent 0).
# ════════════════════════════════════════════════════════════════════════════════════════════════
Describe '§4.B · Get-XdrKqlBackoffSeconds (exponential backoff + jitter + Retry-After · PURE)' {
    It 'grows EXPONENTIALLY with the attempt (base 2s · attempt n ~ 2^(n-1) · the early floor strictly increases)' {
        # With jitter the value is bounded in [delay/2 , delay] where delay=min(cap, 2^(n-1)*base). Assert the
        # ATTEMPT-2 lower bound exceeds the ATTEMPT-1 upper bound so growth is provable despite jitter
        # (a1 in [1,2]; a2 in [2,4]) — a regression to a constant/linear schedule fails this monotone-floor check.
        $a1max = 0; $a2min = [int]::MaxValue
        1..200 | ForEach-Object {
            $a1 = Get-XdrKqlBackoffSeconds -Attempt 1
            $a2 = Get-XdrKqlBackoffSeconds -Attempt 2
            if ($a1 -gt $a1max) { $a1max = $a1 }
            if ($a2 -lt $a2min) { $a2min = $a2 }
        }
        $a1max | Should -BeLessOrEqual 2      # attempt 1 delay=2 → [1,2]
        $a2min | Should -BeGreaterOrEqual 2   # attempt 2 delay=4 → [2,4] · floor >= attempt-1 ceiling → exponential
    }
    It 'is CAPPED (a high attempt never exceeds the 60s cap · a pathological exponent cannot stall the gate)' {
        1..50 | ForEach-Object { (Get-XdrKqlBackoffSeconds -Attempt 12) | Should -BeLessOrEqual 60 }
    }
    It 'JITTERS (the same attempt yields >1 distinct value across many draws · de-syncs a concurrent -AllOps burst)' {
        $vals = 1..80 | ForEach-Object { Get-XdrKqlBackoffSeconds -Attempt 4 }
        (@($vals | Sort-Object -Unique).Count) | Should -BeGreaterThan 1
    }
    It 'HONORS a Retry-After hint in the az error text when it is LONGER than the computed delay (server pacing wins)' {
        # attempt 1 computed delay <= 2s; a 'Retry-After: 25' header must override upward.
        (Get-XdrKqlBackoffSeconds -Attempt 1 -ErrorText 'az query exit=1: Rate limit. Retry-After: 25 seconds') | Should -Be 25
        # the hyphen-less/though-spaced variant the LA throttle sometimes emits is also parsed.
        (Get-XdrKqlBackoffSeconds -Attempt 1 -ErrorText 'throttled, retry after 30 s') | Should -Be 30
    }
    It 'CLAMPS the Retry-After hint to the cap (a pathological header cannot stall the gate beyond 60s)' {
        (Get-XdrKqlBackoffSeconds -Attempt 1 -ErrorText 'Retry-After: 9999') | Should -Be 60
    }
    It 'never returns < 1 (a sleepable floor)' {
        1..50 | ForEach-Object { (Get-XdrKqlBackoffSeconds -Attempt 1) | Should -BeGreaterOrEqual 1 }
    }
}

Describe '§4.B · Invoke-XdrKqlQuery rides out a throttle then succeeds; persistent-throttle → B5-honest failure (az + Start-Sleep mocked)' {
    BeforeEach {
        # Neutralise the real backoff sleep so the test is instant (the exponential schedule would otherwise wait up to 60s).
        function Start-Sleep { param([int]$Seconds, [int]$Milliseconds) }
        $script:azCalls = 0
    }
    AfterEach {
        Remove-Item function:az          -ErrorAction SilentlyContinue
        Remove-Item function:Start-Sleep -ErrorAction SilentlyContinue
    }
    It '429-then-200 · a throttle on the first attempt then a clean 200 → SUCCESS after backoff (healthy connector NOT false-failed)' {
        # The mock writes its '429' text to the errFile az redirects to (2>$errFile), NOT the real console, so the test
        # output stays clean while Invoke-XdrKqlQuery still reads the throttle reason for the Retry-After parse.
        function az {
            $script:azCalls++
            $ef = $null; for ($i = 0; $i -lt $args.Count; $i++) { if ($args[$i] -eq '2>') { $ef = $args[$i + 1] } }
            if ($script:azCalls -lt 2) { $global:LASTEXITCODE = 1; return '' }
            $global:LASTEXITCODE = 0; '[{"Pass":"True","Bad":"0","Total":"5"}]'
        }
        $r = Invoke-XdrKqlQuery -Query 'AppEvents | summarize n=count()' -Label 'throttle-recover'
        $r.Success | Should -BeTrue -Because 'the retry must survive a single 429 and return the eventual 200'
        $script:azCalls | Should -Be 2 -Because 'one throttled attempt + one successful attempt'
        (@($r.Data) | Select-Object -First 1)['Total'] | Should -Be '5'
    }
    It 'persistent-throttle · every attempt 429 → Success=$false after EXACTLY $attempts tries (B5: INCONCLUSIVE, never a silent 0)' {
        function az { $script:azCalls++; $global:LASTEXITCODE = 1; return '' }
        $r = Invoke-XdrKqlQuery -Query 'AppEvents | summarize n=count()' -Label 'throttle-persistent'
        $r.Success | Should -BeFalse -Because 'an unexecutable query is NEVER a silent success (B5 honesty)'
        $r.Error   | Should -Match 'after \d+ attempts'
        @($r.Data).Count | Should -Be 0
        $script:azCalls | Should -Be 6 -Because 'the hardened loop makes 6 bounded attempts before the B5-honest INCONCLUSIVE'
    }
}

Describe '§4.B · Invoke-XdrKqlQuery source uses exponential backoff + jitter + Retry-After (structural)' {
    BeforeAll { $script:vtext = Get-Content $script:Tool -Raw }
    It 'the retry loop calls the exponential-backoff helper (NOT the old linear Min(30, 5*$a) schedule)' {
        $body = [regex]::Match($script:vtext, '(?s)function Invoke-XdrKqlQuery.*?\n\}').Value
        $body | Should -Match 'Get-XdrKqlBackoffSeconds -Attempt \$a'
        $body | Should -Not -Match '5 \* \$a'   # the dead linear schedule is gone
    }
    It 'the backoff helper exists, is exponential (Math.Pow(2, ...)), jitters (Get-Random), and parses Retry-After' {
        $fn = [regex]::Match($script:vtext, '(?s)function Get-XdrKqlBackoffSeconds.*?\n\}').Value
        $fn | Should -Match '\[Math\]::Pow\(2'
        $fn | Should -Match 'Get-Random'
        $fn | Should -Match 'retry\[\\s-\]\?after'   # the Retry-After regex (single-quoted so \s stays literal)
        $fn | Should -Match 'CapSeconds'               # the 60s cap clamp
    }
}

# ════════════════════════════════════════════════════════════════════════════════════════════════
# §4.B TASK B/D1 · D1/D3/D7 RESET-AWARENESS · the B10 artifact-discrimination pattern ported to D1 (event-row reconcile:
# rows-landed-without-a-terminal-event · Actual>Expected), D3 (poll-completion: stuck/orphan/double-close) and D7 (cadence:
# <30s double-fire / >1.5×tier). A checkpoint reset (Save-XdrCheckpointReset) re-fires every SNAPSHOT op at the reset
# instant AND a cross-reset poll can land rows but lose its terminal Entry.Poll.Succeeded → reset-ADJACENT rows-without-
# event (D1) + orphan/double-close (D3) + <30s re-fire (D7) are EXPECTED churn, NOT defects → INCONCLUSIVE not FAIL. A
# reset-FREE window with a real mismatch/double-fire/orphan STILL FAILs (the gate is not weakened). UNKNOWN reset count
# (-1, the count was unreadable) → strict Mismatched==0 / Bad==0 fallback.
# ════════════════════════════════════════════════════════════════════════════════════════════════
Describe '§4.B · Test-XdrGate_D1 reset-awareness (rows-landed-without-a-terminal-event discrimination)' {
    It 'reset-in-window + reset-adjacent mismatch (all rows-without-event · Actual>Expected) → INCONCLUSIVE (EXPECTED churn · not FAIL)' {
        $d = Test-XdrGate_D1 -Row (New-Row @{ Pass = 'False'; Mismatched = '1'; RowsWithoutEvent = '1'; Total = '9' }) -ResetsInWindow 1
        $d.Inconclusive | Should -BeTrue
        $d.Pass         | Should -BeFalse
        $d.Detail       | Should -Match 'reset'
    }
    It 'NO reset + mismatch>0 → still FAIL (a genuine steady-state reconcile mismatch is NOT excused · gate not weakened)' {
        $d = Test-XdrGate_D1 -Row (New-Row @{ Pass = 'False'; Mismatched = '1'; RowsWithoutEvent = '1'; Total = '9' }) -ResetsInWindow 0
        $d.Pass         | Should -BeFalse
        $d.Inconclusive | Should -BeFalse
    }
    It 'reset-in-window + clean (mismatched==0) → PASS (a reset does not block a clean reconcile)' {
        (Test-XdrGate_D1 -Row (New-Row @{ Pass = 'True'; Mismatched = '0'; RowsWithoutEvent = '0'; Total = '9' }) -ResetsInWindow 2).Pass | Should -BeTrue
    }
    It 'reset-in-window but a genuine-LOSS group is present (Expected>Actual · RowsWithoutEvent<Mismatched) → still FAIL (only the reset-adjacent direction is excused)' {
        $d = Test-XdrGate_D1 -Row (New-Row @{ Pass = 'False'; Mismatched = '2'; RowsWithoutEvent = '1'; Total = '9' }) -ResetsInWindow 1
        $d.Pass         | Should -BeFalse
        $d.Inconclusive | Should -BeFalse
    }
    It 'UNKNOWN reset count (-1) + mismatch>0 → strict FALLBACK = FAIL (never a silent pass on an unknowable reset state · B5)' {
        $d = Test-XdrGate_D1 -Row (New-Row @{ Pass = 'False'; Mismatched = '1'; RowsWithoutEvent = '1'; Total = '9' }) -ResetsInWindow -1
        $d.Pass         | Should -BeFalse
        $d.Inconclusive | Should -BeFalse
    }
    It 'default -ResetsInWindow (omitted = 0) preserves the original strict behavior (back-compat)' {
        (Test-XdrGate_D1 -Row (New-Row @{ Pass = 'False'; Mismatched = '2'; Total = '9' })).Pass | Should -BeFalse
        (Test-XdrGate_D1 -Row (New-Row @{ Pass = 'True';  Mismatched = '0'; Total = '9' })).Pass | Should -BeTrue
        (Test-XdrGate_D1 -Row (New-Row @{ Pass = 'False'; Mismatched = '0'; Total = '0' })).Inconclusive | Should -BeTrue
        (Test-XdrGate_D1 -Row $null).Inconclusive | Should -BeTrue
    }
    # CAP-ABSENT POSTURE (F18 · 2026-07-03): total==0 (0 reconcilable groups) on a FULLY cap-absent cat (all ops 403/404 ·
    # no success/failure) is legit posture → vacuous-PASS, NOT the generic "nothing to reconcile" INCONCLUSIVE. A cat that
    # is NOT fully-cap-absent keeps the strict INCONCLUSIVE (a real 0-groups anomaly is never excused).
    It 'CAP-ABSENT · Test-XdrGate_D1: total==0 + CatFullyCapAbsent → vacuous-PASS · without it → INCONCLUSIVE (unchanged)' {
        $p = Test-XdrGate_D1 -Row (New-Row @{ Pass = 'False'; Mismatched = '0'; Total = '0' }) -CatFullyCapAbsent $true
        $p.Pass         | Should -BeTrue
        $p.Inconclusive | Should -BeFalse
        $p.Detail       | Should -Match 'cap-absent'
        (Test-XdrGate_D1 -Row (New-Row @{ Pass = 'False'; Mismatched = '0'; Total = '0' }) -CatFullyCapAbsent $false).Inconclusive | Should -BeTrue
        (Test-XdrGate_D1 -Row $null -CatFullyCapAbsent $true).Pass | Should -BeTrue
        # M1 · CatFullyCapAbsent NEVER excuses a real mismatch (total>0, mismatched>0 still FAILs)
        (Test-XdrGate_D1 -Row (New-Row @{ Pass = 'False'; Mismatched = '2'; Total = '9' }) -CatFullyCapAbsent $true).Pass | Should -BeFalse
    }
}

Describe '§4.B · Test-XdrGate_D3 reset-awareness (orphan/double-close discrimination)' {
    It 'reset-in-window + bad>0 → INCONCLUSIVE (reset-adjacent orphan/double-close is EXPECTED churn · not FAIL)' {
        $d = Test-XdrGate_D3 -Row (New-Row @{ Pass = 'False'; Bad = '1'; Total = '5' }) -ResetsInWindow 1
        $d.Inconclusive | Should -BeTrue
        $d.Pass         | Should -BeFalse
        $d.Detail       | Should -Match 'reset'
    }
    It 'NO reset + bad>0 → still FAIL (a genuine steady-state stuck/orphan is NOT excused · gate not weakened)' {
        $d = Test-XdrGate_D3 -Row (New-Row @{ Pass = 'False'; Bad = '1'; Total = '5' }) -ResetsInWindow 0
        $d.Pass         | Should -BeFalse
        $d.Inconclusive | Should -BeFalse
    }
    It 'reset-in-window + clean (bad==0) → PASS (a reset does not block a clean window)' {
        (Test-XdrGate_D3 -Row (New-Row @{ Pass = 'True'; Bad = '0'; Total = '5' }) -ResetsInWindow 2).Pass | Should -BeTrue
    }
    It 'UNKNOWN reset count (-1) + bad>0 → strict FALLBACK = FAIL (never a silent pass on an unknowable reset state · B5)' {
        $d = Test-XdrGate_D3 -Row (New-Row @{ Pass = 'False'; Bad = '1'; Total = '5' }) -ResetsInWindow -1
        $d.Pass         | Should -BeFalse
        $d.Inconclusive | Should -BeFalse
    }
    It 'default -ResetsInWindow (omitted = 0) preserves the original strict behavior (back-compat)' {
        (Test-XdrGate_D3 -Row (New-Row @{ Pass = 'False'; Bad = '1'; Total = '5' })).Pass | Should -BeFalse
        (Test-XdrGate_D3 -Row (New-Row @{ Pass = 'True';  Bad = '0'; Total = '5' })).Pass | Should -BeTrue
        (Test-XdrGate_D3 -Row $null).Inconclusive | Should -BeTrue
    }
}

Describe '§4.B · Test-XdrGate_D7 reset-awareness (<30s double-fire discrimination)' {
    It 'reset-in-window + bad>0 → INCONCLUSIVE (reset-adjacent sub-30s re-fire is EXPECTED churn · not FAIL)' {
        $d = Test-XdrGate_D7 -Row (New-Row @{ Pass = 'False'; Bad = '1'; Total = '2' }) -ResetsInWindow 1
        $d.Inconclusive | Should -BeTrue
        $d.Pass         | Should -BeFalse
        $d.Detail       | Should -Match 'reset'
    }
    It 'NO reset + bad>0 → still FAIL (a genuine sub-30s double-fire / over-1.5x-tier gap is NOT excused · gate not weakened)' {
        $d = Test-XdrGate_D7 -Row (New-Row @{ Pass = 'False'; Bad = '1'; Total = '2' }) -ResetsInWindow 0
        $d.Pass         | Should -BeFalse
        $d.Inconclusive | Should -BeFalse
    }
    It 'reset-in-window + clean (bad==0) → PASS' {
        (Test-XdrGate_D7 -Row (New-Row @{ Pass = 'True'; Bad = '0'; Total = '3' }) -ResetsInWindow 2).Pass | Should -BeTrue
    }
    It 'UNKNOWN reset count (-1) + bad>0 → strict FALLBACK = FAIL (B5 · never silent-pass on unknowable reset state)' {
        (Test-XdrGate_D7 -Row (New-Row @{ Pass = 'False'; Bad = '1'; Total = '2' }) -ResetsInWindow -1).Pass | Should -BeFalse
    }
    It 'default -ResetsInWindow (omitted = 0) preserves the original strict behavior (back-compat)' {
        (Test-XdrGate_D7 -Row (New-Row @{ Pass = 'False'; Bad = '1'; Total = '2' })).Pass | Should -BeFalse
        (Test-XdrGate_D7 -Row (New-Row @{ Pass = 'True';  Bad = '0'; Total = '2' })).Pass | Should -BeTrue
        (Test-XdrGate_D7 -Row $null).Inconclusive | Should -BeTrue
    }
    # CAP-ABSENT POSTURE (F18 · 2026-07-03): total==0 (no measurable gap) on a FULLY cap-absent cat (all ops 403/404 · no
    # active op that could be late) is legit posture → vacuous-PASS, NOT the generic "cadence unprovable" INCONCLUSIVE. A
    # cat that is NOT fully-cap-absent (a slow op that just hasn't fired twice) keeps the strict INCONCLUSIVE.
    It 'CAP-ABSENT · Test-XdrGate_D7: total==0 + CatFullyCapAbsent → vacuous-PASS · without it → INCONCLUSIVE (unchanged)' {
        $p = Test-XdrGate_D7 -Row (New-Row @{ Pass = 'True'; Bad = '0'; Total = '0' }) -CatFullyCapAbsent $true
        $p.Pass         | Should -BeTrue
        $p.Inconclusive | Should -BeFalse
        $p.Detail       | Should -Match 'cap-absent'
        (Test-XdrGate_D7 -Row (New-Row @{ Pass = 'True'; Bad = '0'; Total = '0' }) -CatFullyCapAbsent $false).Inconclusive | Should -BeTrue
        (Test-XdrGate_D7 -Row $null -CatFullyCapAbsent $true).Pass | Should -BeTrue
        # M1 · CatFullyCapAbsent NEVER excuses a real cadence defect on an active op (total>0, bad>0 still FAILs)
        (Test-XdrGate_D7 -Row (New-Row @{ Pass = 'False'; Bad = '1'; Total = '2' }) -CatFullyCapAbsent $true).Pass | Should -BeFalse
    }
}

Describe '§4.B · Get-XdrResetAwarenessHours (reset-awareness window floor spans the finalize''s reset→verify gap)' {
    # REGRESSION (2026-07-01): a finalize resets at T0 then runs leg-1 (cold-emit-wait ≤30m + verify-cold over 11 cats) +
    # leg-2 (force + cold-emit-wait + 5×7m sustain retries), so by verify-sustain's D7 the reset is ~2–3.5h old. The old
    # naive ceil(SinceMinutes/60) (=2h for the 120m Sustain window) dropped resets-in-window to 0 → the forced-cycle <30s
    # re-fire false-FAILed D7 as a real double-fire (live-caught: AnalyticsData GetEnrichedOutbreakData min=19s). The 6h
    # floor keeps the finalize's OWN reset counted → reset-churn discriminated (INCONCLUSIVE). Steady-state unaffected: a
    # reset happens ONLY on deploy/finalize, so no reset falls in the last 6h in production → gates stay STRICT.
    It 'floors at 6h for the 120m Sustain window (the finalize reset would otherwise age out at 2h)' {
        Get-XdrResetAwarenessHours -SinceMinutes 120 | Should -Be 6
    }
    It 'floors at 6h for a 60m Hour window too' {
        Get-XdrResetAwarenessHours -SinceMinutes 60 | Should -Be 6
    }
    It 'floors at 6h for any small window (never below 6)' {
        Get-XdrResetAwarenessHours -SinceMinutes 1 | Should -Be 6
        Get-XdrResetAwarenessHours -SinceMinutes 0 | Should -Be 6
    }
    It 'a window WIDER than 6h uses the window span (never under-counts a long window)' {
        Get-XdrResetAwarenessHours -SinceMinutes 480 | Should -Be 8   # ceil(480/60)=8 > 6
        Get-XdrResetAwarenessHours -SinceMinutes 600 | Should -Be 10
    }
}

Describe '§4.B · Get-XdrResetCountInWindow telemetry fallback (durable-row unavailable · Invoke-XdrKqlQuery mocked)' {
    # With no -StorageAccount the durable checkpoint-row read is unavailable (Get-XdrResetCountFromCheckpointRows returns
    # Available=$false because $StorageAccount is empty in the dot-source context), so this exercises the AppEvents
    # Checkpoint.Reset FALLBACK path. B5: a failed fallback query → QueryOk=$false (caller then uses the -1 strict fallback).
    AfterEach { Remove-Item function:Invoke-XdrKqlQuery -ErrorAction SilentlyContinue }
    It 'returns the telemetry reset count when the durable-row source is unavailable (QueryOk=$true · Source=fallback)' {
        function Invoke-XdrKqlQuery { param($Query, $Label) @{ Success = $true; Error = $null; Data = @(@{ n = '3' }) } }
        $info = Get-XdrResetCountInWindow -Hours 2
        $info.QueryOk | Should -BeTrue
        $info.Count   | Should -Be 3
        $info.Source  | Should -Match 'telemetry-event'
    }
    It 'B5: a failed fallback query → QueryOk=$false (the caller maps this to the -1 strict fallback, never assumes 0 resets)' {
        function Invoke-XdrKqlQuery { param($Query, $Label) @{ Success = $false; Error = 'az query exit=1'; Data = @() } }
        $info = Get-XdrResetCountInWindow -Hours 2
        $info.QueryOk | Should -BeFalse
    }
    It 'the fallback query targets the Checkpoint.Reset event (single-quoted · the durable source is the row, this is the lossy backup)' {
        $script:rq = $null
        function Invoke-XdrKqlQuery { param($Query, $Label) $script:rq = $Query; @{ Success = $true; Error = $null; Data = @(@{ n = '0' }) } }
        $null = Get-XdrResetCountInWindow -Hours 6
        $script:rq | Should -Match "Name == 'Checkpoint\.Reset'"
    }
}

Describe '§4.B · D1/D3/D7 gate-body wiring (reset count computed ONCE, shared, passed to all · structural)' {
    BeforeAll { $script:vtext = Get-Content $script:Tool -Raw }
    It 'the connector declares -StorageAccount (the durable checkpoint-row ResetUtc source for D1/D3/D7)' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Tool, [ref]$null, [ref]$null)
        $names = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $names | Should -Contain 'StorageAccount'
    }
    It 'the reset count is computed ONCE (gated to when D1/D3/D7 run) and shared via $resetsForD3D7' {
        $script:vtext | Should -Match '\$resetsForD3D7\s*='
        $script:vtext | Should -Match "\('D1' -in \`$gatesForWindow\) -or \('D3' -in \`$gatesForWindow\) -or \('D7' -in \`$gatesForWindow\)"
        $script:vtext | Should -Match 'Get-XdrResetCountInWindow -Hours \$resetHours'
        # UNKNOWN sentinel = -1 when the DURABLE count could not be read (2026-07-01: the authoritative KnownResetUtc overrides it)
        $script:vtext | Should -Match '\$durableCount = if \(\$resetInfo\.QueryOk\) \{ \[int\]\$resetInfo\.Count \} else \{ -1 \}'
        # AUTHORITATIVE override: a known-reset-in-window forces resets>=1 regardless of the durable/telemetry count (false-0 immune)
        $script:vtext | Should -Match '\$resetsForD3D7 = if \(\$knownInWindow\)'
        $script:vtext | Should -Match 'KnownResetUtc'
    }
    It 'D1 + D3 + D7 all pass -ResetsInWindow $resetsForD3D7 to their pure decision fn' {
        $script:vtext | Should -Match 'Test-XdrGate_D1 -Row \$row -ResetsInWindow \$resetsForD3D7'
        $script:vtext | Should -Match 'Test-XdrGate_D3 -Row \$row -ResetsInWindow \$resetsForD3D7'
        $script:vtext | Should -Match 'Test-XdrGate_D7 -Row \$row -ResetsInWindow \$resetsForD3D7'
    }
    It 'the D1 KQL surfaces the reset-adjacent direction (RowsWithoutEvent = groups Actual>Expected · Delta>0)' {
        $script:vtext | Should -Match 'RowsWithoutEvent = countif\(Delta > 0\)'
        $script:vtext | Should -Match 'project Pass = Mismatched == 0, Mismatched, RowsWithoutEvent, Total'
    }
    It 'the durable-row reader uses the AAD storage data-plane + selects ResetUtc (shared-key OFF · the B10 FIX-3 source)' {
        $fn = [regex]::Match($script:vtext, '(?s)function Get-XdrResetCountFromCheckpointRows.*?\n\}').Value
        $fn | Should -Match 'az account get-access-token --resource https://storage\.azure\.com/'
        $fn | Should -Match '\$select=RowKey,ResetUtc'
        $fn | Should -Match 'XdrCheckpoint\(\)'
        $fn | Should -Not -Match 'allowSharedKeyAccess|account-key|SharedKey'
    }
}
