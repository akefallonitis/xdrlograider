#Requires -Modules Pester
<#
.SYNOPSIS
    Fixture-driven contract tests for drift parsers.

.DESCRIPTION
    Loads sample snapshots from tests/fixtures/sample-snapshots/ and verifies that
    each fixture is well-formed AND captures the drift scenario it claims to represent.

    This does NOT execute KQL against a live Kusto engine. It validates:
      1. Fixture JSON parses
      2. Required keys exist (before, after, expectedDrift for scenario files;
         TimeGenerated/SourceStream/EntityId/RawJson for snapshot files)
      3. The expectedDrift field-level semantics match the before/after difference
         (parsed in PowerShell, not KQL)

    When a NuGet-based Kusto.Language validator is added (v1.1+), these fixtures
    become runnable against real KQL — parser query output can be compared against
    expectedDrift. For now these are contract tests that keep fixtures honest.

.NOTES
    Adding a new scenario fixture:
      1. Create tests/fixtures/sample-snapshots/MDE_<Stream>_<scenario>.json
      2. Follow the { description, before, after, expectedDrift } shape
      3. Add a corresponding Describe block here if it needs custom assertions
#>

BeforeAll {
    $script:FixtureDir = Join-Path $PSScriptRoot '..' 'fixtures' 'sample-snapshots'
}

Describe 'Fixture snapshot files — presence and structure' {
    It 'sample-snapshots directory exists' {
        Test-Path $script:FixtureDir | Should -BeTrue
    }

    It 'at least 3 fixture files present' {
        $files = Get-ChildItem -Path $script:FixtureDir -Filter '*.json'
        $files.Count | Should -BeGreaterOrEqual 3
    }

    It 'every fixture file is valid JSON' {
        foreach ($file in Get-ChildItem -Path $script:FixtureDir -Filter '*.json') {
            { Get-Content $file.FullName -Raw | ConvertFrom-Json -ErrorAction Stop } |
                Should -Not -Throw -Because "fixture $($file.Name) must be parseable JSON"
        }
    }
}

Describe 'MDE_AdvancedFeatures before/after snapshot pair' {
    BeforeAll {
        $script:BeforePath = Join-Path $script:FixtureDir 'MDE_AdvancedFeatures_before.json'
        $script:AfterPath  = Join-Path $script:FixtureDir 'MDE_AdvancedFeatures_after.json'
        $script:Before = Get-Content $script:BeforePath -Raw | ConvertFrom-Json
        $script:After  = Get-Content $script:AfterPath  -Raw | ConvertFrom-Json
    }

    It 'both snapshot files exist' {
        Test-Path $script:BeforePath | Should -BeTrue
        Test-Path $script:AfterPath  | Should -BeTrue
    }

    It 'each row has required columns (TimeGenerated, SourceStream, EntityId, RawJson)' {
        $script:Before + $script:After | ForEach-Object {
            $_.TimeGenerated | Should -Not -BeNullOrEmpty
            $_.SourceStream  | Should -Be 'MDE_AdvancedFeatures_CL'
            $_.EntityId      | Should -Not -BeNullOrEmpty
            $_.RawJson       | Should -Not -BeNullOrEmpty
        }
    }

    It 'captures the TamperProtection feature downgrade scenario' {
        $beforeTp = $script:Before | Where-Object EntityId -eq 'TamperProtection'
        $afterTp  = $script:After  | Where-Object EntityId -eq 'TamperProtection'
        $beforeTp.Enabled | Should -BeTrue  -Because 'before state: TamperProtection enabled'
        $afterTp.Enabled  | Should -BeFalse -Because 'after state: TamperProtection disabled (drift event)'
    }

    It 'captures a new-feature-added scenario (Added change-type)' {
        $beforeIds = $script:Before | ForEach-Object EntityId
        $afterIds  = $script:After  | ForEach-Object EntityId
        $added = $afterIds | Where-Object { $_ -notin $beforeIds }
        $added | Should -Contain 'NewFeature' -Because 'after snapshot has a feature not in before'
    }
}

Describe 'MDE_AsrRulesConfig drift scenario' {
    BeforeAll {
        $script:AsrScenarioPath = Join-Path $script:FixtureDir 'MDE_AsrRulesConfig_drift_scenario.json'
        $script:AsrScenario = Get-Content $script:AsrScenarioPath -Raw | ConvertFrom-Json
    }

    It 'scenario file exists and has description + before + after + expectedDrift keys' {
        Test-Path $script:AsrScenarioPath | Should -BeTrue
        foreach ($key in 'description', 'before', 'after', 'expectedDrift') {
            $script:AsrScenario.$key | Should -Not -BeNullOrEmpty -Because "scenario requires '$key' key"
        }
    }

    It 'expectedDrift has at least one Block→Audit transition' {
        $transition = $script:AsrScenario.expectedDrift |
            Where-Object { $_.FieldName -eq 'mode' -and $_.OldValue -eq 'Block' -and $_.NewValue -eq 'Audit' }
        $transition | Should -Not -BeNullOrEmpty
        $transition.ChangeType | Should -Be 'Modified'
    }

    It 'before-state has Block modes; after-state has the Audit downgrade' {
        $ruleId = ($script:AsrScenario.expectedDrift | Select-Object -First 1).EntityId
        $beforeRaw = ($script:AsrScenario.before | Where-Object EntityId -eq $ruleId).RawJson | ConvertFrom-Json
        $afterRaw  = ($script:AsrScenario.after  | Where-Object EntityId -eq $ruleId).RawJson | ConvertFrom-Json
        $beforeRaw.mode | Should -Be 'Block'
        $afterRaw.mode  | Should -Be 'Audit'
    }

    It 'matches MDE_Drift_P0Compliance analytic-rule query semantics' {
        # Rule: MDE_Drift_P0Compliance(2h, 15m) | where StreamName == "MDE_AsrRulesConfig_CL"
        #   | where FieldName == "mode" | where OldValue == "Block" and NewValue in ("Audit", "Off")
        $matching = $script:AsrScenario.expectedDrift |
            Where-Object { $_.StreamName -eq 'MDE_AsrRulesConfig_CL' -and
                           $_.FieldName  -eq 'mode' -and
                           $_.OldValue   -eq 'Block' -and
                           $_.NewValue   -in @('Audit', 'Off') }
        $matching.Count | Should -BeGreaterThan 0 -Because 'analytic rule AsrRuleDowngrade.yaml would fire on this fixture'
    }
}

Describe 'MDE_XspmAttackPaths set-diff drift scenario' {
    BeforeAll {
        $script:XspmScenarioPath = Join-Path $script:FixtureDir 'MDE_XspmAttackPaths_drift_scenario.json'
        $script:XspmScenario = Get-Content $script:XspmScenarioPath -Raw | ConvertFrom-Json
    }

    It 'scenario file exists and has required keys' {
        Test-Path $script:XspmScenarioPath | Should -BeTrue
        foreach ($key in 'description', 'before', 'after', 'expectedDrift') {
            $script:XspmScenario.$key | Should -Not -BeNullOrEmpty
        }
    }

    It 'expectedDrift contains an Added path and a Removed path (set-diff shape)' {
        $added   = $script:XspmScenario.expectedDrift | Where-Object ChangeType -eq 'Added'
        $removed = $script:XspmScenario.expectedDrift | Where-Object ChangeType -eq 'Removed'
        $added.Count   | Should -BeGreaterThan 0 -Because 'P3 parser set-diff must surface Added entities'
        $removed.Count | Should -BeGreaterThan 0 -Because 'P3 parser set-diff must surface Removed entities'
    }

    It 'Added path IDs exist in after but NOT in before' {
        $added = $script:XspmScenario.expectedDrift | Where-Object ChangeType -eq 'Added'
        $beforeIds = $script:XspmScenario.before | ForEach-Object EntityId
        $afterIds  = $script:XspmScenario.after  | ForEach-Object EntityId
        foreach ($a in $added) {
            $a.EntityId | Should -BeIn $afterIds  -Because "Added entity $($a.EntityId) must be in after"
            $a.EntityId | Should -Not -BeIn $beforeIds -Because "Added entity $($a.EntityId) must NOT be in before"
        }
    }

    It 'Removed path IDs exist in before but NOT in after' {
        $removed = $script:XspmScenario.expectedDrift | Where-Object ChangeType -eq 'Removed'
        $beforeIds = $script:XspmScenario.before | ForEach-Object EntityId
        $afterIds  = $script:XspmScenario.after  | ForEach-Object EntityId
        foreach ($r in $removed) {
            $r.EntityId | Should -BeIn $beforeIds -Because "Removed entity $($r.EntityId) must be in before"
            $r.EntityId | Should -Not -BeIn $afterIds -Because "Removed entity $($r.EntityId) must NOT be in after"
        }
    }

    It 'all scenario rows reference the XspmAttackPaths stream' {
        $script:XspmScenario.before + $script:XspmScenario.after | ForEach-Object {
            $_.SourceStream | Should -Be 'MDE_XspmAttackPaths_CL'
        }
    }
}
