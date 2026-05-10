#Requires -Modules Pester

# Hot-Fix 23 regression-locker (2026-05-10): pins Hot-Fix 5 drift parser
# refactor in place. Without this test, future drift parser edits could
# silently revert to the pre-Hot-Fix-5 cardinality bug:
#   - NEW entity emitted N field-rows (one per field) → 150x multiplier
#   - REMOVED entity NEVER emitted (leftouter join from current side only)
#
# This test asserts each of the 4 cadence-tier drift parser .kql files
# follows the Hot-Fix 5 three-path structure:
#   (a) modifiedRows path — entities in BOTH snapshots, per-field mv-apply
#   (b) addedRows path — entities ONLY in current, summary 1 row per entity
#       with FieldName='*' + ChangeType='Added'
#   (c) removedRows path — entities ONLY in previous, summary 1 row per entity
#       with FieldName='*' + ChangeType='Removed'
# All three paths unioned at the end via `union modifiedRows, addedRows, removedRows`.

BeforeAll {
    $script:ParsersDir = Join-Path $PSScriptRoot '..' '..' 'sentinel' 'parsers'
    $script:DriftParsers = @(
        'MDE_Drift_Configuration.kql',
        'MDE_Drift_Inventory.kql',
        'MDE_Drift_Exposure.kql',
        'MDE_Drift_Maintenance.kql'
    )
}

Describe 'Hot-Fix 5 drift parser cardinality refinement (regression-locker)' {

    It 'each drift parser exists at sentinel/parsers/<name>.kql' -ForEach @(
        @{ Name = 'MDE_Drift_Configuration.kql' }
        @{ Name = 'MDE_Drift_Inventory.kql' }
        @{ Name = 'MDE_Drift_Exposure.kql' }
        @{ Name = 'MDE_Drift_Maintenance.kql' }
    ) {
        param($Name)
        $path = Join-Path $script:ParsersDir $Name
        Test-Path $path | Should -BeTrue -Because "drift parser '$Name' must exist (Hot-Fix 5)"
    }

    Context 'each drift parser has the 3-path Hot-Fix 5 structure' {
        BeforeAll {
            $script:ParserContents = @{}
            foreach ($p in $script:DriftParsers) {
                $script:ParserContents[$p] = Get-Content (Join-Path $script:ParsersDir $p) -Raw
            }
        }

        It '<_> declares modifiedRows path with inner join + mv-apply per-field expansion' -ForEach @(
            'MDE_Drift_Configuration.kql', 'MDE_Drift_Inventory.kql',
            'MDE_Drift_Exposure.kql', 'MDE_Drift_Maintenance.kql'
        ) {
            $content = $script:ParserContents[$_]
            $content | Should -Match 'let\s+modifiedRows\s*=' -Because 'modifiedRows path required for Hot-Fix 5 per-field mv-apply'
            $content | Should -Match 'join\s+kind=inner\s+previous\s+on\s+SourceName,\s*EntityId' -Because 'modifiedRows MUST use inner join (entities in BOTH snapshots)'
            $content | Should -Match 'mv-apply\s+field\s*=\s*set_union\s*\(\s*CurrentFields,\s*PreviousFields' -Because 'modifiedRows MUST use set_union mv-apply for per-field expansion'
        }

        It '<_> declares addedRows path with leftanti join + summary FieldName=*' -ForEach @(
            'MDE_Drift_Configuration.kql', 'MDE_Drift_Inventory.kql',
            'MDE_Drift_Exposure.kql', 'MDE_Drift_Maintenance.kql'
        ) {
            $content = $script:ParserContents[$_]
            $content | Should -Match 'let\s+addedRows\s*=' -Because 'addedRows path required for Hot-Fix 5 summary cardinality'
            $content | Should -Match 'addedRows\s*=\s*current[\s\S]+?join\s+kind=leftanti\s+previous\s+on\s+SourceName,\s*EntityId' -Because 'addedRows MUST use leftanti join from current (entities ONLY in current snapshot)'
            $content | Should -Match 'FieldName\s*=\s*"\*"[\s\S]+?ChangeType\s*=\s*"Added"' -Because 'addedRows MUST emit FieldName=* summary not per-field rows (regression-locker for 150x multiplier bug)'
        }

        It '<_> declares removedRows path with leftanti join + Removed cardinality' -ForEach @(
            'MDE_Drift_Configuration.kql', 'MDE_Drift_Inventory.kql',
            'MDE_Drift_Exposure.kql', 'MDE_Drift_Maintenance.kql'
        ) {
            $content = $script:ParserContents[$_]
            $content | Should -Match 'let\s+removedRows\s*=' -Because 'removedRows path required for Hot-Fix 5 (was NEVER emitted pre-fix)'
            $content | Should -Match 'removedRows\s*=\s*previous[\s\S]+?join\s+kind=leftanti\s+current\s+on\s+SourceName,\s*EntityId' -Because 'removedRows MUST use leftanti join from previous (entities ONLY in previous snapshot)'
            $content | Should -Match 'FieldName\s*=\s*"\*"[\s\S]+?ChangeType\s*=\s*"Removed"' -Because 'removedRows MUST emit FieldName=* summary'
        }

        It '<_> unions all three paths at the end (modifiedRows + addedRows + removedRows)' -ForEach @(
            'MDE_Drift_Configuration.kql', 'MDE_Drift_Inventory.kql',
            'MDE_Drift_Exposure.kql', 'MDE_Drift_Maintenance.kql'
        ) {
            $content = $script:ParserContents[$_]
            $content | Should -Match 'union\s+modifiedRows,\s*addedRows,\s*removedRows' -Because 'final union MUST combine all 3 paths so output schema is consistent'
        }

        It '<_> includes Hot-Fix 5 reference comment' -ForEach @(
            'MDE_Drift_Configuration.kql', 'MDE_Drift_Inventory.kql',
            'MDE_Drift_Exposure.kql', 'MDE_Drift_Maintenance.kql'
        ) {
            $content = $script:ParserContents[$_]
            $content | Should -Match 'HOT-FIX 5' -Because 'Hot-Fix 5 reference comment must remain so future maintainers see the cardinality refinement rationale'
        }
    }

    Context 'Hot-Fix 5 ANTI-pattern check — no parser emits per-field rows for Added entities' {
        It 'NONE of the 4 drift parsers uses pre-fix leftouter pattern with case() always reaching ChangeType=Added per field' {
            # Pre-fix anti-pattern: `current | join kind=leftouter previous` then
            # `mv-apply set_union` produces N field-rows per NEW entity
            # (FieldInPrevious always false for new entity → all fields look 'Added').
            # The anti-pattern signature is: leftouter join with NO separate addedRows path.
            foreach ($p in $script:DriftParsers) {
                $content = Get-Content (Join-Path $script:ParsersDir $p) -Raw
                # Verify the anti-pattern is NOT present:
                # If file contains 'kind=leftouter previous' AND lacks 'let addedRows', that's the pre-fix bug.
                $hasLeftOuterAntiPattern = $content -match 'current[\s\S]{0,50}\|\s*join\s+kind=leftouter\s+previous'
                $hasAddedRowsPath = $content -match 'let\s+addedRows\s*='
                $isAntiPattern = $hasLeftOuterAntiPattern -and -not $hasAddedRowsPath
                $isAntiPattern | Should -BeFalse -Because "drift parser '$p' MUST NOT use pre-Hot-Fix-5 leftouter-only pattern (causes N-field-rows per new entity); current state must use the 3-path union (modifiedRows + addedRows + removedRows)"
            }
        }
    }
}
