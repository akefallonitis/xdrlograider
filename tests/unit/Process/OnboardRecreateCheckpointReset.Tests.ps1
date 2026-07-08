#Requires -Version 7.4
# BoundaryDeduped-after-recreate (live-caught 2026-06-25) · tools/Onboard-CategorySurgical.ps1 contract. When the
# -RecreateTableOnSchemaDrift path DROPS+recreates a custom table, the table is now EMPTY but the FA's exactly-once
# checkpoint BOUNDARY is unchanged → the next poll sees the rows as already-sent → Entry.Poll.BoundaryDeduped → ZERO
# rows land in the recreated table (GetTvmRiskScore/List polled OK but 0 rows). FIX-AT-SOURCE: the -Apply tail must
# AUTO-invoke Save-XdrCheckpointReset (Reason=schema-change) so the FA re-emits from a clean baseline into the empty
# table. SOURCE-SCAN (the tool does live Azure ops · not runnable offline): assert the recreate path references the
# reset and that the reset call is GATED by the recreate flag (so it only fires after an actual drop).

BeforeAll {
    $script:repo   = (Resolve-Path "$PSScriptRoot/../../..").Path
    $script:tool   = Join-Path $script:repo 'tools/Onboard-CategorySurgical.ps1'
    $script:exists = Test-Path $script:tool
    $script:src    = if ($script:exists) { Get-Content $script:tool -Raw } else { '' }
}

Describe 'BoundaryDeduped-after-recreate · Onboard-CategorySurgical resets the checkpoint after a table recreate' {
    It 'exists and parses with no errors' {
        $script:exists | Should -BeTrue
        $e = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:tool, [ref]$null, [ref]$e) | Out-Null
        @($e).Count | Should -Be 0
    }
    It 'the recreate-on-drift path references Save-XdrCheckpointReset (re-emit into the empty table)' {
        $script:src | Should -Match 'RecreateTableOnSchemaDrift'
        $script:src | Should -Match 'Save-XdrCheckpointReset'
    }
    It 'tracks the recreate with a flag set right after the table drop' {
        $script:src | Should -Match '\$didRecreateTable\s*=\s*\$false'   # initialized before the drift block (Set-StrictMode)
        $script:src | Should -Match '\$didRecreateTable\s*=\s*\$true'    # flipped after the successful drop
    }
    It 'gates the checkpoint reset behind the recreate flag (only fires after an actual drop)' {
        $script:src | Should -Match 'if\s*\(\s*\$didRecreateTable\s*\)'
    }
    It 'invokes the reset with Reason=schema-change (clean-baseline rewind)' {
        $script:src | Should -Match "schema-change"
    }
    It 'is NON-FATAL — a reset failure WARNS with the manual command, never fails the onboard' {
        $script:src | Should -Match 'Write-Warning .*post-recreate Save-XdrCheckpointReset FAILED'
        $script:src | Should -Match 'NON-FATAL'
    }
}

# DCR-schema-propagation lag (live-caught this session) · when the recreate ADDS ≥1 NEW column, Azure propagation of the
# recreated table's schema to the DCR/DCE INGESTION endpoint lags ~10-15 min, so the FIRST re-emit after the auto-reset can
# land the NEW columns EMPTY (pre-existing cols + id unaffected). That transiently false-negatives the §4.B typed-populated
# gate (D8f) until propagation completes and the op is re-polled. FIX-AT-SOURCE: after the auto-reset, emit a prominent,
# structured PROPAGATION-PENDING notice keyed off the ACTUAL added-column list. SOURCE-SCAN (tool does live Azure ops · not
# runnable offline): assert the PROPAGATION-PENDING notice exists, is keyed off the added-column list, instructs a settle +
# re-poll before judging the new cols, and is GATED on the new-column-added condition (only fires when ≥1 col was added).
Describe 'PROPAGATION-PENDING · Onboard-CategorySurgical warns about the DCR schema-propagation lag for NEW columns after a recreate' {
    It 'emits a PROPAGATION-PENDING notice in the tool output' {
        $script:src | Should -Match 'PROPAGATION-PENDING'
        $script:src | Should -Match 'Write-Host .*PROPAGATION-PENDING'
    }
    It 'captures the NEW-column names from the SAME $drift "ADD ..." list the diff already logs (no recompute)' {
        $script:src | Should -Match '\$addedColumns\s*=\s*@\('          # the captured added-column list
        $script:src | Should -Match "ADD \*"                            # parsed from the $drift 'ADD <name> ...' entries
    }
    It 'initializes $addedColumns BEFORE the drift block (Set-StrictMode-safe · alongside $didRecreateTable)' {
        $script:src | Should -Match '\$addedColumns\s*=\s*@\(\)'        # empty-array init before any read
    }
    It 'gates the PROPAGATION-PENDING notice on the new-column-added condition (only fires when ≥1 NEW column was added)' {
        # The notice block is guarded by a count check on the added-column list — it must NOT fire for a RETYPE-only / no-add recreate.
        $script:src | Should -Match 'if\s*\(\s*\$addedColumns\.Count\s*-gt\s*0\s*\)'
    }
    It 'states the ~10-15 min DCR propagation lag and that the FIRST re-emit may land the new cols EMPTY' {
        $script:src | Should -Match 'PROPAGATION-PENDING[\s\S]*10-15 min'
        $script:src | Should -Match 'PROPAGATION-PENDING[\s\S]*EMPTY'
    }
    It 'instructs the §4.B re-prove to settle ~15 min and RE-POLL the op via Save-XdrCheckpointReset -OperationKey before concluding the new cols are broken' {
        $script:src | Should -Match 'PROPAGATION-PENDING[\s\S]*settle'
        $script:src | Should -Match 'PROPAGATION-PENDING[\s\S]*Save-XdrCheckpointReset[\s\S]*-OperationKey'
        $script:src | Should -Match 'PROPAGATION-PENDING[\s\S]*[Bb]roken'
    }
    It 'references the D8f §4.B gate as the transiently-affected check (correct-but-transient)' {
        $script:src | Should -Match 'PROPAGATION-PENDING[\s\S]*D8f'
    }
    It 'is keyed off the actual added-column list (generic · not hardcoded to ASR/asrConfigurationStatesJson)' {
        $script:src | Should -Match '\$addedList\s*=\s*\(\$addedColumns\s*-join'   # interpolates the real column names
        $script:src | Should -Not -Match "asrConfigurationStatesJson'"             # no category-specific hardcoding in the notice
    }
}
