#Requires -Version 7.4
# F-SNAPSHOT-SIG (plan §B.3 · 2026-06-19) · the keyless-SNAPSHOT cross-cycle dedup. A cursorless SNAPSHOT re-fetches
# the FULL state every cycle; without cross-cycle dedup the EO re-emitted the WHOLE set each cycle (live-caught:
# SecureScore GetInsights 43,200 rows / 2,753 distinct · 16× · systemic across ALL keyless-SNAPSHOT ops · the
# baseline-lock's "verifier must BLOCK dup-accumulation"). These DIRECT table-tests pin the signature contract:
# the helper ($XdrSnapshotSignature), the EO skip-branch (Select-XdrExactlyOnceRows), and the drain-gated frontier
# persist (Get-XdrAdvancedFrontier) — DATA only, no auth/HTTP/DCE/checkpoint mocks.

BeforeAll {
    $script:Repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $psd1s = Get-ChildItem (Join-Path $script:Repo 'src\Modules') -Directory |
        ForEach-Object { Join-Path $_.FullName ($_.Name + '.psd1') } | Where-Object { Test-Path $_ }
    for ($pass = 1; $pass -le 4; $pass++) {
        foreach ($p in $psd1s) { try { Import-Module $p -Force -DisableNameChecking -ErrorAction Stop } catch { } }
    }
    function New-SnapRow([string]$rid) { @{ RecordId = $rid; RawJson = "{""id"":""$rid""}" } }
}

Describe 'F-SNAPSHOT-SIG · $XdrSnapshotSignature helper (pure · hash of the sorted per-row CONTENT hashes)' {
    It 'identical content sets yield an identical signature (order-independent)' {
        InModuleScope Xdr.Common.Runtime {
            $a = @(@{RawJson='{"id":3}'}, @{RawJson='{"id":1}'}, @{RawJson='{"id":2}'})
            $b = @(@{RawJson='{"id":1}'}, @{RawJson='{"id":2}'}, @{RawJson='{"id":3}'})   # same set, different order
            $sigA = & $script:XdrSnapshotSignature $a
            $sigB = & $script:XdrSnapshotSignature $b
            $sigA | Should -Not -BeNullOrEmpty
            $sigA | Should -Be $sigB
        }
    }
    It 'a changed content set (a new record) yields a different signature' {
        InModuleScope Xdr.Common.Runtime {
            $a = @(@{RawJson='{"id":1}'}, @{RawJson='{"id":2}'})
            $c = @(@{RawJson='{"id":1}'}, @{RawJson='{"id":2}'}, @{RawJson='{"id":3}'})   # one new record
            (& $script:XdrSnapshotSignature $a) | Should -Not -Be (& $script:XdrSnapshotSignature $c)
        }
    }
    It 'a VALUE change (same count + same keys, different values) yields a different signature (the keyed-SNAPSHOT data-loss guard)' {
        InModuleScope Xdr.Common.Runtime {
            $before = @(@{RawJson='{"OrgId":"o1","score":50}'}, @{RawJson='{"OrgId":"o2","score":60}'})
            $after  = @(@{RawJson='{"OrgId":"o1","score":99}'}, @{RawJson='{"OrgId":"o2","score":60}'})   # o1 value changed, keys identical
            (& $script:XdrSnapshotSignature $before) | Should -Not -Be (& $script:XdrSnapshotSignature $after)
        }
    }
    It 'empty / no-RawJson rows yield an empty signature (cold · never a false skip)' {
        InModuleScope Xdr.Common.Runtime {
            (& $script:XdrSnapshotSignature @()) | Should -Be ''
            (& $script:XdrSnapshotSignature @(@{RawJson=''}, @{RawJson=$null})) | Should -Be ''
        }
    }
}

Describe 'F-CANON · content-hash is order-INSENSITIVE (an unordered API array must not cause a false re-emit · live GetAppsSecureScoreMetric 2026-06-20)' {
    It 'a re-shuffled array + reordered keys (same content) yields the SAME signature — kills the dup-accumulation' {
        InModuleScope Xdr.Common.Runtime {
            $a = @(@{RawJson='{"id":"x","score":3.1,"recommendations":["mdo_a","mdo_b","AppG_c","exo_d"]}'})
            $b = @(@{RawJson='{"recommendations":["AppG_c","exo_d","mdo_a","mdo_b"],"score":3.1,"id":"x"}'})  # SAME set, array shuffled + keys reordered
            $sig = & $script:XdrSnapshotSignature $a
            $sig | Should -Not -BeNullOrEmpty
            $sig | Should -Be (& $script:XdrSnapshotSignature $b)
        }
    }
    It 'a re-ordered nested array-of-objects yields the SAME content hash (deep canonicalization · the dataHistory class)' {
        InModuleScope Xdr.Common.Runtime {
            $h1 = & $script:XdrContentHash '{"id":"x","dataHistory":[{"date":"2026-06-20","score":3.1},{"date":"2026-06-06","score":3.1}]}'
            $h2 = & $script:XdrContentHash '{"id":"x","dataHistory":[{"score":3.1,"date":"2026-06-06"},{"score":3.1,"date":"2026-06-20"}]}'  # entries swapped, keys reordered
            $h1 | Should -Not -BeNullOrEmpty
            $h1 | Should -Be $h2
        }
    }
    It 'a GENUINE value change still yields a different signature (fail-safe preserved · never a false skip)' {
        InModuleScope Xdr.Common.Runtime {
            $a = @(@{RawJson='{"id":"x","score":3.1,"recommendations":["mdo_a","mdo_b"]}'})
            $c = @(@{RawJson='{"id":"x","score":4.9,"recommendations":["mdo_a","mdo_b"]}'})  # score changed
            (& $script:XdrSnapshotSignature $a) | Should -Not -Be (& $script:XdrSnapshotSignature $c)
        }
    }
    It 'non-JSON RawJson falls back to a raw-string hash (never throws)' {
        InModuleScope Xdr.Common.Runtime {
            (& $script:XdrContentHash 'not-json-at-all') | Should -Not -BeNullOrEmpty
            (& $script:XdrContentHash 'not-json-at-all') | Should -Be (& $script:XdrContentHash 'not-json-at-all')
        }
    }
}

Describe 'F-VOLATILE-HASH · content-hash STRIPS per-op declared volatile fields BEFORE hashing (2026-06-25 · the genuinely-changing-but-not-identity class · live ListCriticalAssetClassifications.timestamp / CheckAppGovernanceOnboarding.id / GetPostureOversightInitiative.dataHistory)' {
    It 'a DECLARED-volatile field changing yields the SAME hash (the dup-accumulation block · timestamp class)' {
        InModuleScope Xdr.Common.Runtime {
            $r1 = '{"ruleId":"abc","ruleName":"X","timestamp":"2026-06-25T03:30:48Z"}'
            $r2 = '{"ruleId":"abc","ruleName":"X","timestamp":"2026-06-25T04:22:59Z"}'   # ONLY timestamp differs (the live diff)
            $h1 = & $script:XdrContentHash $r1 @('timestamp')
            $h2 = & $script:XdrContentHash $r2 @('timestamp')
            $h1 | Should -Not -BeNullOrEmpty
            $h1 | Should -Be $h2
        }
    }
    It 'WITHOUT the declaration those SAME two records hash DIFFERENTLY (proves the field was the sole diff · the bug pre-fix)' {
        InModuleScope Xdr.Common.Runtime {
            $r1 = '{"ruleId":"abc","ruleName":"X","timestamp":"2026-06-25T03:30:48Z"}'
            $r2 = '{"ruleId":"abc","ruleName":"X","timestamp":"2026-06-25T04:22:59Z"}'
            (& $script:XdrContentHash $r1 @()) | Should -Not -Be (& $script:XdrContentHash $r2 @())
        }
    }
    It 'a REAL identity field changing STILL yields a DIFFERENT hash even WITH the strip (fail-safe · never masks a real change)' {
        InModuleScope Xdr.Common.Runtime {
            $r1 = '{"ruleId":"abc","ruleName":"X","timestamp":"2026-06-25T03:30:48Z"}'
            $r3 = '{"ruleId":"abc","ruleName":"CHANGED","timestamp":"2026-06-25T03:30:48Z"}'   # ruleName (identity) changed
            (& $script:XdrContentHash $r1 @('timestamp')) | Should -Not -Be (& $script:XdrContentHash $r3 @('timestamp'))
        }
    }
    It 'a per-request random id on a SINGLETON (CheckAppGovernanceOnboarding class) strips to one stable identity' {
        InModuleScope Xdr.Common.Runtime {
            $a = '{"id":"514a0fd1-1de3-4cd5-b26f-c79e9b9a0bd7","isTenantOnboarded":false,"toggleStatus":"off"}'
            $b = '{"id":"b865c15c-9e3a-430a-9423-10304ab8d766","isTenantOnboarded":false,"toggleStatus":"off"}'  # only the random id differs
            (& $script:XdrContentHash $a @('id')) | Should -Be (& $script:XdrContentHash $b @('id'))
        }
    }
    It 'a poll-stamped rolling dataHistory (GetPostureOversightInitiative class) strips to a stable identity while a score change is still kept' {
        InModuleScope Xdr.Common.Runtime {
            $c1 = '{"id":"cis_3_0_0","latestScore":0.36,"dataHistory":[{"date":"2026-06-24T21:54:12Z","score":0.36}]}'
            $c2 = '{"id":"cis_3_0_0","latestScore":0.36,"dataHistory":[{"date":"2026-06-25T03:55:41Z","score":0.36}]}'  # only dataHistory date moved
            (& $script:XdrContentHash $c1 @('dataHistory')) | Should -Be (& $script:XdrContentHash $c2 @('dataHistory'))
            $c3 = '{"id":"cis_3_0_0","latestScore":0.99,"dataHistory":[{"date":"2026-06-24T21:54:12Z","score":0.36}]}'  # latestScore (identity) changed
            (& $script:XdrContentHash $c1 @('dataHistory')) | Should -Not -Be (& $script:XdrContentHash $c3 @('dataHistory'))
        }
    }
    It 'the strip is TOP-LEVEL + case-INSENSITIVE · a nested same-named key is NOT stripped (so a nested change is still caught)' {
        InModuleScope Xdr.Common.Runtime {
            $a = '{"Id":"GUID-1","payload":{"id":"keep"}}'
            $b = '{"Id":"GUID-2","payload":{"id":"keep"}}'   # top Id differs (case-insensitive match) · nested id equal
            (& $script:XdrContentHash $a @('id')) | Should -Be (& $script:XdrContentHash $b @('id'))
            $c = '{"Id":"GUID-1","payload":{"id":"CHANGED"}}'  # nested id changed → must differ
            (& $script:XdrContentHash $a @('id')) | Should -Not -Be (& $script:XdrContentHash $c @('id'))
        }
    }
    It 'BACK-COMPAT · the 1-arg call equals the empty-declaration call (every undeclared op is byte-identical to pre-fix)' {
        InModuleScope Xdr.Common.Runtime {
            $r = '{"ruleId":"abc","timestamp":"2026-06-25T03:30:48Z"}'
            (& $script:XdrContentHash $r) | Should -Be (& $script:XdrContentHash $r @())
        }
    }
    It '$XdrSnapshotSignature threads the volatile strip so a volatile-only change does NOT re-emit the snapshot' {
        InModuleScope Xdr.Common.Runtime {
            $before = @(@{RawJson='{"ruleId":"a","timestamp":"2026-06-25T03:30:48Z"}'}, @{RawJson='{"ruleId":"b","timestamp":"2026-06-25T03:30:48Z"}'})
            $after  = @(@{RawJson='{"ruleId":"a","timestamp":"2026-06-25T09:00:00Z"}'}, @{RawJson='{"ruleId":"b","timestamp":"2026-06-25T09:11:11Z"}'})  # only timestamps moved
            (& $script:XdrSnapshotSignature $before @('timestamp')) | Should -Be (& $script:XdrSnapshotSignature $after @('timestamp'))
            # … and a genuine value change to one row STILL changes the signature (fail-safe)
            $changed = @(@{RawJson='{"ruleId":"a","timestamp":"2026-06-25T09:00:00Z","criticalityLevel":9}'}, @{RawJson='{"ruleId":"b","timestamp":"2026-06-25T09:11:11Z"}'})
            (& $script:XdrSnapshotSignature $before @('timestamp')) | Should -Not -Be (& $script:XdrSnapshotSignature $changed @('timestamp'))
        }
    }
}

Describe 'F-VOLATILE-HASH · the manifest declaration is wired end-to-end (manifest VolatileHashFields present for the live-detected ops)' {
    It 'the 3 live-detected ops carry the correct VolatileHashFields in their committed manifests' {
        $repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
        $cases = @(
            @{ Manifest = 'Configuration.psd1';      Op = 'ListCriticalAssetClassifications'; Field = 'timestamp' }
            @{ Manifest = 'ExposureManagement.psd1'; Op = 'GetPostureOversightInitiative';     Field = 'dataHistory' }
            @{ Manifest = 'PortalServices.psd1';     Op = 'CheckAppGovernanceOnboarding';      Field = 'id' }
        )
        foreach ($c in $cases) {
            $man = Import-PowerShellDataFile (Join-Path $repo "manifests/Defender/$($c.Manifest)")
            $op  = @($man.Operations) | Where-Object { $_.OperationKey -eq $c.Op } | Select-Object -First 1
            $op | Should -Not -BeNullOrEmpty -Because "$($c.Op) must exist in $($c.Manifest)"
            @($op.VolatileHashFields) | Should -Contain $c.Field -Because "$($c.Op) must declare '$($c.Field)' as volatile"
        }
    }
    It 'an op WITHOUT a volatile declaration carries NO VolatileHashFields key (the SPARSE invariant)' {
        $repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
        $man = Import-PowerShellDataFile (Join-Path $repo 'manifests/Defender/Configuration.psd1')
        $op  = @($man.Operations) | Where-Object { $_.OperationKey -eq 'GetAssetRules' } | Select-Object -First 1
        $op.ContainsKey('VolatileHashFields') | Should -BeFalse
    }
}

Describe 'F-SNAPSHOT-SIG · Select-XdrExactlyOnceRows SNAPSHOT skip-branch (cursorless)' {
    It 'UNCHANGED snapshot (Current == Prior signature) emits ZERO' {
        $rows = @((New-SnapRow 'h1'), (New-SnapRow 'h2'), (New-SnapRow 'h3'))
        $out = Select-XdrExactlyOnceRows -Rows $rows -HighWaterUtc $null -CursorField '' -NaturalKey @() -CurrentSnapshotSignature 'SIG_ABC' -PriorSnapshotSignature 'SIG_ABC'
        @($out).Count | Should -Be 0
    }
    It 'CHANGED snapshot (Current != Prior) emits ALL' {
        $rows = @((New-SnapRow 'h1'), (New-SnapRow 'h2'))
        $out = Select-XdrExactlyOnceRows -Rows $rows -HighWaterUtc $null -CursorField '' -NaturalKey @() -CurrentSnapshotSignature 'SIG_NEW' -PriorSnapshotSignature 'SIG_OLD'
        @($out).Count | Should -Be 2
    }
    It 'COLD start (no prior signature) emits ALL' {
        $rows = @((New-SnapRow 'h1'), (New-SnapRow 'h2'))
        $out = Select-XdrExactlyOnceRows -Rows $rows -HighWaterUtc $null -CursorField '' -NaturalKey @() -CurrentSnapshotSignature 'SIG_ABC' -PriorSnapshotSignature ''
        @($out).Count | Should -Be 2
    }
    It 'BACK-COMPAT · no signature params at all (legacy caller) emits ALL' {
        $rows = @((New-SnapRow 'h1'), (New-SnapRow 'h2'))
        $out = Select-XdrExactlyOnceRows -Rows $rows -HighWaterUtc $null -CursorField '' -NaturalKey @()
        @($out).Count | Should -Be 2
    }
}

Describe 'F-SNAPSHOT-SIG · Get-XdrAdvancedFrontier signature persist (drain-gated)' {
    It 'COMPLETE cursorless drain promotes the CURRENT signature' {
        $f = Get-XdrAdvancedFrontier -Baseline '' -IngestRows @() -DrainComplete $true -CursorField '' -NaturalKey @() -CurrentSnapshotSignature 'SIG_CUR' -CommittedSnapshotSignature 'SIG_OLD'
        $f['NextSnapshotSignature'] | Should -Be 'SIG_CUR'
    }
    It 'INCOMPLETE cursorless drain KEEPS the committed signature (no partial-snapshot false-skip)' {
        $f = Get-XdrAdvancedFrontier -Baseline '' -IngestRows @() -DrainComplete $false -CursorField '' -NaturalKey @() -CurrentSnapshotSignature 'SIG_PARTIAL' -CommittedSnapshotSignature 'SIG_OLD'
        $f['NextSnapshotSignature'] | Should -Be 'SIG_OLD'
    }
    It 'a CURSOR op yields no signature (empty · cursor ops dedup via the high-water path)' {
        $f = Get-XdrAdvancedFrontier -Baseline '' -IngestRows @() -DrainComplete $true -CursorField 'EventTime' -NaturalKey @('ActionId') -CurrentSnapshotSignature 'SIG_CUR' -CommittedSnapshotSignature ''
        $f['NextSnapshotSignature'] | Should -Be ''
    }
}
